defmodule JidoClaw.Tools.Handoff do
  @moduledoc """
  Hand off conversation ownership to a specialized worker template.

  When invoked, the next user turn for the current session will be routed
  to the named worker template (one of `coder`, `reviewer`, `researcher`,
  `refactorer`, `verifier`, `test_runner`, `docs_writer`). The new owner
  receives a bounded handoff preamble — message + summary + a slice of
  recent conversation history — on its first turn. Subsequent turns are
  plain. The user can return ownership to main with the `/reset` REPL
  command (or `JidoClaw.reset_handoff/4` programmatically).

  The Registry mutation is the only state change that matters for
  routing. The metadata mirror on `Conversations.Session` and the
  durable `:system` message in `Conversations.Message` are best-effort —
  they make handoffs survive process restarts and show up in history,
  but their failure does not block the handoff.
  """

  use JidoClaw.Tools.Action,
    name: "handoff",
    description:
      "Hand off conversation ownership to a specialized worker template. This is the LAST action of your turn — after calling, respond with a brief acknowledgement only. The next user turn will be handled by the named template.",
    category: "handoff",
    tags: ["handoff", "swarm", "write"],
    output_schema: [
      status: [type: :string, required: true],
      to_template: [type: :string, required: true],
      message: [type: :string, required: true],
      conversation_id: [type: :string, required: false]
    ],
    schema: [
      to_template: [
        type: :string,
        required: true,
        doc:
          "Target worker template (coder, test_runner, reviewer, docs_writer, researcher, refactorer, verifier). 'main' is not a valid target — use /reset to return ownership to main."
      ],
      message: [
        type: :string,
        required: true,
        doc:
          "Rationale visible to the next worker — what you've established and what they should do next."
      ],
      summary: [
        type: :string,
        required: false,
        doc: "Optional one-line summary of the conversation so far."
      ],
      reason: [
        type: :string,
        required: false,
        doc: "Optional explanation for why this handoff is needed."
      ]
    ]

  require Logger

  # Ash CRUD + Postgrex faults the best-effort metadata-mirror can hit when
  # writing the `current_agent_template` mirror — narrowed so a real bug
  # surfaces rather than being logged-and-swallowed.
  @db_errors JidoClaw.Core.AshErrors.db_errors()

  alias JidoClaw.Agent.Handoff
  alias JidoClaw.Agent.Handoff.Registry, as: HandoffRegistry
  alias JidoClaw.Agent.Handoff.Router, as: HandoffRouter
  alias JidoClaw.Agent.Templates
  alias JidoClaw.Authorization.Actor
  alias JidoClaw.Conversations.Session, as: ConversationsSession
  alias JidoClaw.Session.Worker, as: SessionWorker

  @impl Jido.Action
  def run(params, context) do
    started_mono = System.monotonic_time()

    case do_run(params, context) do
      {:ok, payload, ctx_fields, handoff} ->
        emit_applied(payload, ctx_fields, handoff, started_mono)
        {:ok, payload}

      {:error, reason} = err ->
        emit_failed(reason, params, base_telemetry(context), started_mono)
        err
    end
  end

  defp do_run(params, context) do
    with {:ok, to_template} <- validate_required(Map.get(params, :to_template), "to_template"),
         :ok <- reject_main(to_template),
         {:ok, message} <- validate_required(Map.get(params, :message), "message"),
         {:ok, template} <- Templates.get(to_template),
         :ok <- reject_composer_private(to_template),
         {:ok, ctx_fields} <- extract_context(context) do
      summary = optional_trimmed(Map.get(params, :summary))
      reason = optional_trimmed(Map.get(params, :reason))

      handoff =
        Handoff.new(%{
          tenant_id: ctx_fields.tenant_id,
          runtime_session_id: ctx_fields.runtime_session_id,
          session_uuid: ctx_fields.session_uuid,
          from_template: ctx_fields.from_template,
          to_template: to_template,
          to_module: template.module,
          message: message,
          summary: summary,
          reason: reason,
          request_id: ctx_fields.request_id
        })

      :ok =
        HandoffRegistry.put_owner(ctx_fields.tenant_id, ctx_fields.runtime_session_id, handoff)

      _ = mirror_metadata(ctx_fields, to_template)
      _ = write_system_message(ctx_fields, handoff)

      payload = %{
        status: "handed_off",
        to_template: to_template,
        message: message,
        conversation_id: ctx_fields.session_uuid
      }

      {:ok, payload, ctx_fields, handoff}
    end
  end

  defp validate_required(value, field_name) do
    case required_trimmed_string(value) do
      {:ok, trimmed} -> {:ok, trimmed}
      {:error, :required} -> {:error, "#{field_name} is required"}
    end
  end

  # ---- Context shape: nested OR flat ----
  #
  # Jido ReAct may pass tool_context either nested under `context.tool_context`
  # (the helper shape) or merged flat into the call context. Read from both,
  # preferring nested.
  defp extract_context(context) do
    tc = Map.get(context, :tool_context) || context

    raw = %{
      tenant_id: lookup(tc, context, :tenant_id),
      runtime_session_id: lookup(tc, context, :session_id),
      session_uuid: lookup(tc, context, :session_uuid),
      request_id: lookup(context, tc, :request_id),
      agent_template: lookup(tc, context, :agent_template),
      agent_id: lookup(tc, context, :agent_id),
      actor_in: lookup(tc, context, :actor)
    }

    case validate_required_ids(raw) do
      :ok ->
        actor = raw.actor_in || Actor.system(raw.tenant_id)

        {:ok,
         %{
           tenant_id: raw.tenant_id,
           runtime_session_id: raw.runtime_session_id,
           session_uuid: raw.session_uuid,
           request_id: raw.request_id,
           actor: actor,
           agent_id: raw.agent_id,
           from_template: raw.agent_template || "main"
         }}

      :missing ->
        {:error, "handoff requires an active session"}
    end
  end

  # Best-effort context for the failure path. Mirrors `extract_context/1`'s
  # nested-or-flat lookup but never fails — any field may be `nil`. `context`
  # is always a map here: the shared `Tools.Action` wrapper enriches it
  # (`ToolContext.ensure_nested/1` + `MCPScope.wrap/4`) before invoking `run/2`.
  defp base_telemetry(context) do
    tc = Map.get(context, :tool_context) || context

    %{
      request_id: lookup(context, tc, :request_id),
      tenant_id: lookup(tc, context, :tenant_id),
      conversation_id: lookup(tc, context, :session_uuid),
      agent_id: lookup(tc, context, :agent_id),
      from_template: lookup(tc, context, :agent_template) || "main"
    }
  end

  defp lookup(primary, fallback, key) do
    Map.get(primary, key) || Map.get(fallback, key)
  end

  defp validate_required_ids(%{
         tenant_id: tenant_id,
         runtime_session_id: runtime_session_id,
         session_uuid: session_uuid
       })
       when is_binary(tenant_id) and is_binary(runtime_session_id) and is_binary(session_uuid) do
    :ok
  end

  defp validate_required_ids(_raw), do: :missing

  # ---- Validators ----

  defp required_trimmed_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, :required}
      trimmed -> {:ok, trimmed}
    end
  end

  defp required_trimmed_string(_), do: {:error, :required}

  defp optional_trimmed(nil), do: nil

  defp optional_trimmed(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp optional_trimmed(_), do: nil

  defp reject_main("main"), do: {:error, "Cannot hand off to 'main'; use /reset instead."}
  defp reject_main(_), do: :ok

  # AR-8b / AR-8b-2 F2 / AR-8c: a composer-private template — sandboxed
  # (`:prototype`/`:docker`) OR the explicit AR-8c `system_*` flag — must never
  # own a session: a handoff would make it the session owner with no
  # `.prototypes/` scope (sandboxed) or bypassing the safety gate (system). Gated
  # through the single `Templates.composer_private?/1` predicate (string reason —
  # see `error_to_string/1`).
  defp reject_composer_private(to_template) do
    if Templates.composer_private?(to_template) do
      {:error, "Template '#{to_template}' is composer-private and cannot own a session."}
    else
      :ok
    end
  end

  # ---- Best-effort side-effects ----

  defp mirror_metadata(ctx, to_template) do
    case ConversationsSession.by_id(ctx.session_uuid,
           tenant: ctx.tenant_id,
           actor: ctx.actor
         ) do
      {:ok, session} ->
        case ConversationsSession.set_current_agent_template(session, to_template,
               tenant: ctx.tenant_id,
               actor: ctx.actor
             ) do
          {:ok, _} ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "[handoff] metadata mirror failed for session #{ctx.session_uuid}: #{inspect(reason)}"
            )

            :ok
        end

      {:error, reason} ->
        Logger.warning(
          "[handoff] session lookup failed for #{ctx.session_uuid}: #{inspect(reason)}"
        )

        :ok
    end
  rescue
    e in @db_errors ->
      # credo:disable-for-previous-line ExSlop.Check.Warning.RescueWithoutReraise
      Logger.warning("[handoff] metadata mirror raised: #{Exception.message(e)}")
      :ok
  end

  # The handoff `:system` row is written during the *main* agent's turn, so
  # `ctx.request_id` resolves to main's compaction identity. Override the
  # row's identity to the *target worker's* (`"handoff:<uuid>:<tpl>"`, the
  # same id the router stamps on the worker) so the worker's durable slice
  # includes its own handoff context — and enrich the body with the reason
  # + summary so that context survives into the summarized source on
  # re-compaction.
  defp write_system_message(ctx, %Handoff{} = handoff) do
    body = system_message_body(handoff)
    identity = system_row_identity(ctx, handoff)

    case SessionWorker.add_message(
           ctx.tenant_id,
           ctx.runtime_session_id,
           :system,
           body,
           ctx.request_id,
           identity
         ) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[handoff] system message write failed for #{ctx.runtime_session_id}: #{inspect(reason)}"
        )

        :ok
    end
  rescue
    # Best-effort durable system row: a SessionWorker hiccup must not block
    # the handoff (the Registry mutation is the only routing-critical state
    # change). Paired with `catch :exit` for non-existent worker GenServer.
    # reach:disable-next-line bare_rescue
    e ->
      Logger.warning("[handoff] system message write raised: #{Exception.message(e)}")
      :ok
  catch
    :exit, reason ->
      Logger.warning("[handoff] system message write exited: #{inspect(reason)}")
      :ok
  end

  defp system_message_body(%Handoff{} = handoff) do
    # `handoff.message` is `String.t()` (non-nil per the struct's type);
    # `reason`/`summary`/`from_template` are nilable, so they keep fallbacks.
    body = """
    [HANDOFF #{handoff.from_template || "main"} → #{handoff.to_template}]
    Reason: #{handoff.reason || "not provided"}
    Summary: #{handoff.summary || "not provided"}
    Message: #{handoff.message}
    """

    String.trim_trailing(body)
  end

  # Stamp the row with the target worker's compaction identity when the
  # session UUID is known (the normal path). Without a UUID the worker can't
  # be routed either, so fall back to the default (main) attribution.
  defp system_row_identity(%{session_uuid: uuid}, %Handoff{to_template: to_template})
       when is_binary(uuid) do
    [agent_id: HandoffRouter.worker_agent_id(uuid, to_template), subagent: false]
  end

  defp system_row_identity(_ctx, _handoff), do: [subagent: false]

  # ---- Telemetry ----

  defp emit_applied(payload, ctx_fields, %Handoff{} = handoff, started_mono) do
    duration_ms = duration_ms_since(started_mono)

    metadata = %{
      event: :applied,
      status: :completed,
      handoff: payload.to_template,
      name: "handoff",
      to_template: payload.to_template,
      from_template: handoff.from_template,
      conversation_id: payload.conversation_id,
      request_id: ctx_fields.request_id,
      tenant_id: ctx_fields.tenant_id,
      agent_id: ctx_fields.agent_id
    }

    JidoClaw.Trace.emit(:handoff, metadata, %{duration_ms: duration_ms})
  end

  defp emit_failed(reason, params, base, started_mono) do
    duration_ms = duration_ms_since(started_mono)

    metadata = %{
      event: :error,
      status: :failed,
      name: "handoff",
      error: error_to_string(reason),
      request_id: base.request_id,
      tenant_id: base.tenant_id,
      conversation_id: base.conversation_id,
      agent_id: base.agent_id,
      from_template: base.from_template,
      to_template: attempted_to_template(params)
    }

    JidoClaw.Trace.emit(:handoff, metadata, %{duration_ms: duration_ms})
  end

  defp attempted_to_template(params) when is_map(params) do
    case Map.get(params, :to_template) do
      v when is_binary(v) -> v
      _ -> nil
    end
  end

  defp duration_ms_since(started_mono) do
    System.convert_time_unit(System.monotonic_time() - started_mono, :native, :millisecond)
  end

  defp error_to_string(reason) when is_binary(reason), do: reason
end
