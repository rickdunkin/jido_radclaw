defmodule JidoClaw.Agent.Handoff.Router do
  @moduledoc """
  Dispatch-time routing for the handoff system.

  `resolve_session_owner/6` is called from every entry point (REPL,
  `JidoClaw.run_chat_turn/8`) before a turn is dispatched. It returns
  the pid, template name, agent id, and first-post-handoff flag the
  dispatcher should use. When no handoff is active, the caller's
  default pid/agent id are returned unchanged.

  `build_preamble/3` constructs the bounded handoff preamble that the
  dispatcher prepends to the user message on the first turn after a
  handoff. It MUST be called before `Session.Worker.add_message(:user, …)`
  so the recent-history slice reflects history-before-this-turn.
  """

  require Logger

  # Ash CRUD + Postgrex faults the metadata-read/clear paths can hit; the
  # rescues narrow to these so an unexpected error surfaces instead of
  # being swallowed.
  @db_errors JidoClaw.Core.AshErrors.db_errors()

  alias JidoClaw.Agent.Handoff
  alias JidoClaw.Agent.Handoff.Registry, as: HandoffRegistry
  alias JidoClaw.Agent.Templates
  alias JidoClaw.Authorization.Actor
  alias JidoClaw.Conversations.Session, as: ConversationsSession
  alias JidoClaw.Session.Worker, as: SessionWorker
  alias JidoClaw.Tools.OutputLimit

  @type resolve_opts :: [
          project_dir: String.t() | nil,
          session_record: JidoClaw.Conversations.Session.t() | nil,
          default_agent_id: String.t()
        ]

  @max_preamble_bytes 4_000
  @max_handoff_message_bytes 1_500
  @max_handoff_summary_bytes 1_000
  @max_handoff_reason_bytes 800
  @max_handoff_template_bytes 128
  @history_window 10

  @doc """
  Maximum total byte size of a built preamble. Exposed so tests can
  assert against the canonical bound rather than a magic literal.
  """
  @spec max_preamble_bytes() :: pos_integer()
  def max_preamble_bytes, do: @max_preamble_bytes

  @doc """
  The runtime/compaction agent id for a handoff-routed worker:
  `"handoff:<session_uuid>:<template>"`.

  Defined once here and reused by the handoff `:system`-row writer
  (`JidoClaw.Tools.Handoff`) so the row the *main* turn writes carries the
  *target worker's* identity — the same id this router stamps on the
  worker's own correlation rows. Reader-reconstructable from
  `(session_uuid, template)`, so no extra plumbing is needed across boots.
  """
  @spec worker_agent_id(String.t(), String.t()) :: String.t()
  def worker_agent_id(session_uuid, template_name)
      when is_binary(session_uuid) and is_binary(template_name) do
    "handoff:#{session_uuid}:#{template_name}"
  end

  # Internal struct that bundles the immutable per-call inputs (tenant,
  # session ids, default fallback, actor, project context). Threading
  # this instead of 8 positional args keeps cyclomatic-complexity /
  # function-arity checks happy and makes the recursion in
  # `cold_start_or_default/2 -> route_with_owner/2` readable.
  defmodule Ctx do
    @moduledoc false
    defstruct [
      :tenant_id,
      :runtime_session_id,
      :effective_uuid,
      :default_pid,
      :default_agent_id,
      :actor,
      :project_dir,
      :session_record
    ]
  end

  @doc """
  Resolve the worker pid that should handle the current turn.

  Returns:

    * `routed_pid` — pid of the worker (default or routed)
    * `routed_template` — template name (e.g. `"main"` or `"reviewer"`)
    * `routed_agent_id` — opaque runtime identity to thread through tool_context
    * `first_post_handoff?` — true if this is the first turn after a handoff
      and the preamble should be prepended
    * `owner` — the registry owner record, or `nil` for the default path

  `default_agent_id` is required in `opts` so the call site (REPL,
  `run_chat_turn/8`) supplies its caller-specific value (`state.agent_id`
  for the REPL, `session_id` for `run_chat_turn/8`).
  """
  @spec resolve_session_owner(
          tenant_id :: String.t(),
          runtime_session_id :: String.t(),
          session_uuid :: String.t() | nil,
          default_pid :: pid(),
          actor :: map() | nil,
          resolve_opts()
        ) ::
          {routed_pid :: pid(), routed_template :: String.t(), routed_agent_id :: String.t(),
           first_post_handoff? :: boolean(), owner :: HandoffRegistry.owner() | nil}
  def resolve_session_owner(
        tenant_id,
        runtime_session_id,
        session_uuid,
        default_pid,
        actor,
        opts
      )
      when is_binary(tenant_id) and is_binary(runtime_session_id) and is_pid(default_pid) do
    default_agent_id = Keyword.fetch!(opts, :default_agent_id)
    project_dir = Keyword.get(opts, :project_dir)
    session_record = Keyword.get(opts, :session_record)
    actor = actor || Actor.system(tenant_id)

    effective_uuid =
      session_uuid ||
        case HandoffRegistry.owner(tenant_id, runtime_session_id) do
          %{handoff: %Handoff{session_uuid: uuid}} when is_binary(uuid) -> uuid
          _ -> nil
        end

    ctx = %Ctx{
      tenant_id: tenant_id,
      runtime_session_id: runtime_session_id,
      effective_uuid: effective_uuid,
      default_pid: default_pid,
      default_agent_id: default_agent_id,
      actor: actor,
      project_dir: project_dir,
      session_record: session_record
    }

    case HandoffRegistry.owner(tenant_id, runtime_session_id) do
      nil -> cold_start_or_default(ctx)
      %{} = owner -> route_with_owner(owner, ctx)
    end
  end

  @doc """
  Build the bounded handoff preamble for the first post-handoff turn.

  Pure over the registry owner + Session.Worker history. Called BEFORE
  the dispatcher writes the current user message to Session.Worker, so
  the recent-history slice excludes the in-flight turn.

  Returns an empty string when `owner` is `nil` or carries no
  `%Handoff{}`.
  """
  @spec build_preamble(
          tenant_id :: String.t(),
          runtime_session_id :: String.t(),
          owner :: HandoffRegistry.owner() | nil
        ) :: String.t()
  def build_preamble(_tenant_id, _runtime_session_id, nil), do: ""

  def build_preamble(tenant_id, runtime_session_id, %{handoff: %Handoff{} = handoff})
      when is_binary(tenant_id) and is_binary(runtime_session_id) do
    history = recent_history(tenant_id, runtime_session_id)

    message = truncate(handoff.message || "<no message>", @max_handoff_message_bytes)
    summary = truncate(handoff.summary || "not provided", @max_handoff_summary_bytes)
    reason = truncate(handoff.reason || "not provided", @max_handoff_reason_bytes)
    from_template = truncate(handoff.from_template || "main", @max_handoff_template_bytes)

    base = """
    [HANDOFF CONTEXT — you have just been assigned this conversation.
    Handoff reason: #{reason}
    Handoff summary: #{summary}
    Previous turn from handing-off agent (#{from_template}): #{message}

    Recent conversation history (most recent last):
    """

    closing = "END HANDOFF CONTEXT]\n\n"
    history_budget = max(@max_preamble_bytes - byte_size(base) - byte_size(closing), 0)
    history_block = clamp_history(format_history(history, history_budget), base, closing)

    base <> history_block <> closing
  end

  def build_preamble(_tenant_id, _runtime_session_id, _owner), do: ""

  @doc """
  Mark the handoff preamble as consumed when a first-post-handoff turn
  has dispatched successfully AND the registry still points at the
  routed template.

  Used by the REPL dispatcher and `JidoClaw.run_chat_turn/8`. If the
  dispatch failed, timed out, or the registry has since flipped to a
  different template (concurrent handoff), the preamble flag is left
  alone so the next user turn re-prepends.
  """
  @spec mark_preamble_consumed_on_success(
          tenant_id :: String.t(),
          runtime_session_id :: String.t(),
          routed_template :: String.t(),
          first_post_handoff? :: boolean(),
          result :: {:ok, term()} | {:error, term()} | term()
        ) :: :ok
  def mark_preamble_consumed_on_success(
        tenant_id,
        runtime_session_id,
        routed_template,
        true,
        {:ok, _}
      )
      when is_binary(tenant_id) and is_binary(runtime_session_id) and is_binary(routed_template) do
    case HandoffRegistry.owner(tenant_id, runtime_session_id) do
      %{template: ^routed_template} ->
        HandoffRegistry.mark_preamble_consumed(tenant_id, runtime_session_id)

      _ ->
        :ok
    end
  end

  def mark_preamble_consumed_on_success(_, _, _, _, _), do: :ok

  # ---- Default-path & cold-start synthesis ----

  defp cold_start_or_default(%Ctx{} = ctx) do
    case fetch_metadata_template(ctx.effective_uuid, ctx.tenant_id, ctx.actor) do
      {:ok, template_name, template} ->
        case synthesize_owner(
               ctx.tenant_id,
               ctx.runtime_session_id,
               ctx.effective_uuid,
               template_name,
               template
             ) do
          :ok ->
            # Recurse once — the registry now has the owner.
            owner = HandoffRegistry.owner(ctx.tenant_id, ctx.runtime_session_id)
            route_with_owner(owner, ctx)

          :error ->
            default_tuple(ctx)
        end

      :none ->
        default_tuple(ctx)

      :stale ->
        clear_stale_metadata(ctx.effective_uuid, ctx.tenant_id, ctx.actor)
        default_tuple(ctx)
    end
  end

  defp default_tuple(%Ctx{default_pid: pid, default_agent_id: agent_id}) do
    {pid, "main", agent_id, false, nil}
  end

  defp fetch_metadata_template(nil, _tenant_id, _actor), do: :none

  defp fetch_metadata_template(session_uuid, tenant_id, actor) do
    case ConversationsSession.by_id(session_uuid, tenant: tenant_id, actor: actor) do
      {:ok, %{metadata: metadata}} when is_map(metadata) ->
        case Map.get(metadata, "current_agent_template") do
          name when is_binary(name) -> resolve_metadata_template(name)
          _ -> :none
        end

      _ ->
        :none
    end
  rescue
    e in @db_errors ->
      # credo:disable-for-previous-line ExSlop.Check.Warning.RescueWithoutReraise
      Logger.warning(
        "[handoff.router] metadata read raised for #{inspect(session_uuid)}: #{Exception.message(e)}"
      )

      :none
  end

  # AR-8b / AR-8b-2 F2 / AR-8c: a composer-private owner (sandboxed OR the
  # explicit `system_*` flag) in the metadata mirror is treated as stale →
  # cleared by `cold_start_or_default/1`. Gated through the single
  # `Templates.composer_private?/1` predicate. An unresolvable template is also
  # stale.
  defp resolve_metadata_template(name) do
    with {:ok, template} <- Templates.get(name),
         false <- Templates.composer_private?(name) do
      {:ok, name, template}
    else
      _ -> :stale
    end
  end

  defp synthesize_owner(tenant_id, runtime_session_id, session_uuid, template_name, template) do
    handoff =
      Handoff.new(%{
        tenant_id: tenant_id,
        runtime_session_id: runtime_session_id,
        session_uuid: session_uuid,
        from_template: Handoff.rehydrated_marker(),
        to_template: template_name,
        to_module: template.module,
        message: Handoff.rehydrated_marker()
      })

    :ok =
      HandoffRegistry.put_owner(tenant_id, runtime_session_id, handoff, preamble_consumed?: true)

    :ok
  rescue
    # Registry/Handoff struct construction is in-process; a crash here must
    # not take down the cold-start path — log and fall back to the default.
    # reach:disable-next-line bare_rescue
    e ->
      Logger.warning(
        "[handoff.router] synthesize_owner raised for #{template_name}: #{Exception.message(e)}"
      )

      :error
  end

  defp clear_stale_metadata(nil, _tenant_id, _actor), do: :ok

  defp clear_stale_metadata(session_uuid, tenant_id, actor) do
    case ConversationsSession.by_id(session_uuid, tenant: tenant_id, actor: actor) do
      {:ok, session} ->
        _ =
          ConversationsSession.set_current_agent_template(session, nil,
            tenant: tenant_id,
            actor: actor
          )

        Logger.warning(
          "[handoff.router] cleared stale current_agent_template metadata for session #{session_uuid}"
        )

        :ok

      _ ->
        :ok
    end
  rescue
    _ in @db_errors ->
      # credo:disable-for-previous-line ExSlop.Check.Warning.RescueWithoutReraise
      :ok
  end

  # ---- Routed path ----

  defp route_with_owner(%{template: template_name, module: module} = owner, %Ctx{} = ctx) do
    case Templates.get(template_name) do
      # AR-8b / AR-8b-2 F2 / AR-8c: a composer-private template (sandboxed OR the
      # explicit `system_*` flag) must never own a session — a stale/externally-
      # mutated owner pointing at one is treated like a stale owner (clear the
      # registry + metadata mirror, fall back to main). Gated through the single
      # `Templates.composer_private?/1` predicate.
      {:ok, _template} ->
        if Templates.composer_private?(template_name) do
          Logger.warning(
            "[handoff.router] composer-private template '#{template_name}' cannot own a session — clearing"
          )

          HandoffRegistry.clear(ctx.tenant_id, ctx.runtime_session_id)
          clear_stale_metadata(ctx.effective_uuid, ctx.tenant_id, ctx.actor)
          default_tuple(ctx)
        else
          route_known_template(owner, module, template_name, ctx)
        end

      {:error, _reason} ->
        Logger.warning(
          "[handoff.router] stale template '#{template_name}' for session #{ctx.runtime_session_id} — clearing"
        )

        HandoffRegistry.clear(ctx.tenant_id, ctx.runtime_session_id)
        clear_stale_metadata(ctx.effective_uuid, ctx.tenant_id, ctx.actor)
        default_tuple(ctx)
    end
  end

  defp route_known_template(_owner, _module, template_name, %Ctx{effective_uuid: nil} = ctx) do
    Logger.warning(
      "[handoff.router] effective_uuid unavailable for #{template_name} — falling back to main"
    )

    default_tuple(ctx)
  end

  defp route_known_template(owner, module, template_name, %Ctx{} = ctx) do
    agent_id = worker_agent_id(ctx.effective_uuid, template_name)

    case ensure_worker_pid(module, agent_id) do
      {:ok, pid} ->
        maybe_inject_prompt(
          pid,
          owner,
          ctx.tenant_id,
          ctx.runtime_session_id,
          ctx.project_dir,
          ctx.session_record
        )

        first_post_handoff? = not Map.get(owner, :preamble_consumed?, false)
        {pid, template_name, agent_id, first_post_handoff?, owner}

      {:error, reason} ->
        Logger.warning(
          "[handoff.router] worker start failed for #{agent_id}: #{inspect(reason)} — falling back to main for this turn"
        )

        default_tuple(ctx)
    end
  end

  defp ensure_worker_pid(module, agent_id) do
    case jido_whereis(agent_id) do
      pid when is_pid(pid) ->
        {:ok, pid}

      nil ->
        case jido_start_agent(module, id: agent_id) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, {:already_registered, pid}} -> {:ok, pid}
          {:error, _} = err -> err
        end
    end
  end

  defp jido_whereis(agent_id) do
    runtime = Application.get_env(:jido_claw, :jido_runtime, JidoClaw.Jido)
    runtime.whereis(agent_id)
  rescue
    # Test seam: configurable runtime module may be a stub raising anything.
    # reach:disable-next-line bare_rescue
    _ -> nil
  end

  # Handoff workers are short-lived sub-agents: `start_subagent` starts them
  # `:temporary`, so a crashed worker is not resurrected as an untracked
  # orphan — `ensure_worker_pid/2` lazily recreates it on the next turn.
  defp jido_start_agent(module, opts) do
    runtime = Application.get_env(:jido_claw, :jido_runtime, JidoClaw.Jido)
    runtime.start_subagent(module, opts)
  end

  # Skip only when THIS worker pid is the one already primed — a recreated
  # worker (fresh pid, empty state) falls through and gets injected again.
  defp maybe_inject_prompt(pid, %{prompt_injected_pid: pid}, _tenant, _session, _dir, _record),
    do: :ok

  defp maybe_inject_prompt(_pid, _owner, _tenant, _session, nil, _session_record) do
    Logger.warning("[handoff.router] skipping system-prompt injection: project_dir not supplied")

    :ok
  end

  defp maybe_inject_prompt(
         pid,
         owner,
         tenant_id,
         runtime_session_id,
         project_dir,
         session_record
       ) do
    case inject_prompt_for(pid, owner, project_dir, session_record) do
      :ok ->
        HandoffRegistry.mark_prompt_injected(tenant_id, runtime_session_id, pid)
        :ok

      {:error, reason} ->
        Logger.warning(
          "[handoff.router] system-prompt injection failed for #{runtime_session_id}: #{inspect(reason)} — will retry next turn"
        )

        :ok
    end
  end

  # When the handoff carries a reason/summary, inject the base prompt PLUS an
  # additive handoff-context block (always kept by the compaction
  # transformer). Otherwise — a contextless or rehydrated handoff — inject
  # just the base session prompt.
  defp inject_prompt_for(pid, owner, project_dir, session_record) do
    case handoff_context_from_owner(owner) do
      ctx when map_size(ctx) == 0 ->
        JidoClaw.Startup.inject_system_prompt(pid, project_dir, session_record)

      ctx ->
        JidoClaw.Startup.inject_handoff_prompt(pid, project_dir, session_record, ctx)
    end
  end

  # A routed owner always carries a `%Handoff{}`. Returns the additive
  # handoff-context block's fields (message + reason + summary + handing-off
  # template) when any of them is present, or an empty map for a contextless
  # handoff. A rehydrated placeholder short-circuits to `%{}`: its sentinel
  # `:message` is non-empty but must NOT surface as handoff context, so a
  # rehydrated owner stays on the base prompt only.
  defp handoff_context_from_owner(%{handoff: %Handoff{} = handoff}) do
    cond do
      Handoff.rehydrated?(handoff) ->
        %{}

      present?(handoff.message) or present?(handoff.reason) or present?(handoff.summary) ->
        %{
          message: handoff.message,
          reason: handoff.reason,
          summary: handoff.summary,
          from_template: handoff.from_template
        }

      true ->
        %{}
    end
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  # ---- Preamble helpers ----

  defp recent_history(tenant_id, runtime_session_id) do
    SessionWorker.get_messages(tenant_id, runtime_session_id)
    |> List.wrap()
    |> Enum.filter(fn
      %{role: role} when role in ["user", "assistant", "system"] -> true
      _ -> false
    end)
    |> Enum.take(-@history_window)
  rescue
    # Best-effort preamble history: a SessionWorker hiccup must not crash the
    # turn dispatcher. Paired with `catch :exit, _` for GenServer non-exists.
    # reach:disable-next-line bare_rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  # Defense-in-depth: per-field caps make this branch unreachable under
  # normal data, but if `base` scaffolding ever grows past the budget,
  # clamp the history block (only) so `closing` is always preserved
  # intact. Truncating the final preamble as a whole could cut off
  # "END HANDOFF CONTEXT]" and produce an unparseable marker.
  defp clamp_history(history_block, base, closing) do
    allowed = @max_preamble_bytes - byte_size(base) - byte_size(closing)

    cond do
      allowed <= 0 -> ""
      byte_size(history_block) > allowed -> binary_part(history_block, 0, allowed)
      true -> history_block
    end
  end

  defp format_history([], _budget), do: ""

  defp format_history(messages, budget) do
    {lines, _remaining} =
      messages
      |> Enum.reverse()
      |> Enum.reduce({[], budget}, fn msg, {acc, remaining} ->
        line = "#{msg.role}: #{msg.content}\n"

        case remaining - byte_size(line) do
          left when left >= 0 -> {[line | acc], left}
          _ -> {acc, 0}
        end
      end)

    Enum.join(lines)
  end

  @truncation_marker "… (truncated)"
  @truncation_marker_bytes byte_size(@truncation_marker)

  defp truncate(value, limit) when is_binary(value) and limit > 0 do
    if byte_size(value) > limit do
      prefix_bytes = max(limit - @truncation_marker_bytes, 0)

      value
      |> binary_part(0, prefix_bytes)
      |> OutputLimit.valid_utf8_prefix()
      |> Kernel.<>(@truncation_marker)
    else
      value
    end
  end

  defp truncate(_, _), do: ""
end
