defmodule JidoClaw.Reasoning.Compactor do
  @moduledoc """
  Summary-based context compaction for the main `JidoClaw.Agent`.

  Live-thread compactor that runs once per user turn on `:ai_react_start`
  (via the `on_before_cmd/2` override injected by
  `JidoClaw.Agent.Defaults`). When the projected message budget crosses a
  configurable threshold, the Compactor:

    1. Loads the slice of `Conversations.Message` rows that have NOT yet
       been summarized (sequence > previous watermark).
    2. Groups them into turns (by `request_id`), preserves the head
       (`protect_first_n_turns`) and tail (`keep_last_turns`), summarizes
       the middle via the bounded `Summarizer`.
    3. Persists a `%Snapshot{}` in `Session.metadata["compaction"]`.
    4. Installs `Compactor.RequestTransformer` on the `:ai_react_start`
       params and stuffs the snapshot into `params[:tool_context]`.

  The transformer is what actually shapes the LLM-facing request: it drops
  messages whose `refs.request_id` is in the snapshot's cumulative
  `summarized_request_ids` set and prepends a single delimited summary
  message after any leading system messages.

  ## Always best-effort

  `maybe_compact/3` is non-fatal: failures (storage errors, summarizer
  timeouts, missing tool_context) are logged + emitted via Trace and the
  caller is handed back either the original action or an action with a
  transformer that still applies the *previous* snapshot. The macro hook
  treats `{:error, _}` returns by falling through to the original action.

  ## Scope (v1)

  Main agent only. Worker agents (`Coder`, `Reviewer`, `Researcher`,
  `TestRunner`, `DocsWriter`, `Refactorer`, `Verifier`) carry
  `compaction: [mode: :off]` so the macro emits a no-op override. Per-agent
  snapshot keying is deferred to v2.

  ## Public surface

    * `maybe_compact/3` — per-turn entry point used by the `Defaults`
      macro. Best-effort.
    * `compact/3` — force a compaction for a session regardless of
      threshold. Returns `{:ok, %Snapshot{}} | {:error, exception}`.
    * `latest/2` — read the last persisted snapshot for a session.
    * `runtime_context_key/0` — the key under which the snapshot is
      threaded through `runtime_context`.
  """

  require Logger

  alias Jido.Signal.ID, as: SignalID
  alias JidoClaw.Conversations.Message

  alias JidoClaw.Reasoning.Compactor.{
    Config,
    Prompt,
    RequestTransformer,
    Snapshot,
    Storage,
    Summarizer,
    Telemetry,
    TurnGrouping
  }

  @runtime_context_key :__jido_claw_compaction__

  @type action :: {:ai_react_start, map()}

  defmodule Ctx do
    @moduledoc false
    defstruct [
      :config,
      :tenant_id,
      :session_uuid,
      :actor,
      :agent_id,
      :request_id,
      :storage_opts,
      :base_metadata
    ]
  end

  @doc """
  Returns the runtime_context key under which the snapshot is threaded
  through the ReAct request transformer.
  """
  @spec runtime_context_key() :: atom()
  def runtime_context_key, do: @runtime_context_key

  @doc """
  Best-effort per-turn compaction. Returns `{:ok, mutated_action}` for the
  caller to dispatch.

  Returns `{:error, :existing_request_transformer}` when the caller has
  already set a non-Compactor `request_transformer` on the action — the
  macro hook treats this by falling through to the original action.

  Other errors (Storage, Summarizer) are swallowed: emitted via Trace and
  logged, but `{:ok, _}` is still returned with the transformer (and
  prior snapshot, if any) installed so the live turn still benefits from
  the previous compaction.
  """
  @spec maybe_compact(term(), action(), Config.t()) ::
          {:ok, action()} | {:error, term()}
  def maybe_compact(_agent, {:ai_react_start, _params} = action, %Config{mode: :off}),
    do: {:ok, action}

  def maybe_compact(_agent, {:ai_react_start, params} = action, %Config{mode: :manual}) do
    ctx = Map.get(params, :tool_context) || %{}
    tenant_id = Map.get(ctx, :tenant_id)
    session_uuid = Map.get(ctx, :session_uuid)
    actor = Map.get(ctx, :actor)
    agent_id = Map.get(ctx, :agent_id)
    request_id = Map.get(params, :request_id) || generate_request_id()

    cond do
      is_nil(tenant_id) or is_nil(session_uuid) ->
        emit_skipped(:missing_context, agent_id, tenant_id, session_uuid, request_id)
        {:ok, action}

      existing_transformer_collision?(params) ->
        emit_skipped(:existing_request_transformer, agent_id, tenant_id, session_uuid, request_id)

        Logger.warning(
          "[Compactor] skipping :manual install for session #{session_uuid}: " <>
            "caller pre-set params[:request_transformer]"
        )

        {:error, :existing_request_transformer}

      true ->
        manual_install(action, params, %{
          tenant_id: tenant_id,
          session_uuid: session_uuid,
          actor: actor,
          agent_id: agent_id,
          request_id: request_id
        })
    end
  end

  def maybe_compact(_agent, {:ai_react_start, params} = action, %Config{} = config) do
    ctx = Map.get(params, :tool_context) || %{}
    tenant_id = Map.get(ctx, :tenant_id)
    session_uuid = Map.get(ctx, :session_uuid)
    actor = Map.get(ctx, :actor)
    agent_id = Map.get(ctx, :agent_id)

    cond do
      is_nil(tenant_id) or is_nil(session_uuid) ->
        emit_skipped(:missing_context, agent_id, tenant_id, session_uuid, nil)
        {:ok, action}

      existing_transformer_collision?(params) ->
        request_id = Map.get(params, :request_id)
        emit_skipped(:existing_request_transformer, agent_id, tenant_id, session_uuid, request_id)

        Logger.warning(
          "[Compactor] skipping compaction for session #{session_uuid}: " <>
            "caller pre-set params[:request_transformer] to " <>
            inspect(Map.get(params, :request_transformer))
        )

        {:error, :existing_request_transformer}

      true ->
        request_id = Map.get(params, :request_id) || generate_request_id()

        compactor_ctx = %Ctx{
          config: config,
          tenant_id: tenant_id,
          session_uuid: session_uuid,
          actor: actor,
          agent_id: agent_id,
          request_id: request_id,
          storage_opts: [tenant: tenant_id, actor: actor],
          base_metadata: %{
            tenant_id: tenant_id,
            session_uuid: session_uuid,
            agent_id: agent_id,
            request_id: request_id
          }
        }

        run(action, params, compactor_ctx)
    end
  end

  defp manual_install(action, params, %{
         tenant_id: tenant_id,
         session_uuid: session_uuid,
         actor: actor,
         agent_id: agent_id,
         request_id: request_id
       }) do
    base_metadata = %{
      tenant_id: tenant_id,
      session_uuid: session_uuid,
      agent_id: agent_id,
      request_id: request_id
    }

    case Storage.latest(session_uuid, tenant: tenant_id, actor: actor) do
      {:ok, snap} ->
        emit_skipped(:manual_mode, agent_id, tenant_id, session_uuid, request_id)
        {:ok, install_overrides(action, params, snap, request_id)}

      {:error, reason} ->
        Logger.warning(
          "[Compactor] (:manual) could not load snapshot for session " <>
            "#{session_uuid}: #{inspect(reason)}"
        )

        emit_error(:load_snapshot, reason, base_metadata)
        {:ok, install_overrides(action, params, nil, request_id)}
    end
  end

  defp run(action, params, %Ctx{} = ctx) do
    case Storage.latest(ctx.session_uuid, ctx.storage_opts) do
      {:ok, existing_snapshot} ->
        evaluate_and_run(action, params, ctx, existing_snapshot)

      {:error, reason} ->
        Logger.warning(
          "[Compactor] could not load snapshot for session #{ctx.session_uuid}: " <>
            inspect(reason)
        )

        emit_error(:load_snapshot, reason, ctx.base_metadata)
        {:ok, install_overrides(action, params, nil, ctx.request_id)}
    end
  end

  defp evaluate_and_run(action, params, %Ctx{} = ctx, existing_snapshot) do
    case load_slice_count(ctx.session_uuid, existing_snapshot, ctx.storage_opts) do
      {:ok, _, 0} ->
        emit_skipped(
          :no_source_messages,
          ctx.agent_id,
          ctx.tenant_id,
          ctx.session_uuid,
          ctx.request_id
        )

        {:ok, install_overrides(action, params, existing_snapshot, ctx.request_id)}

      {:ok, slice, slice_count} ->
        threshold = threshold_for(ctx.config, existing_snapshot)
        decide_and_run(action, params, ctx, existing_snapshot, slice, slice_count, threshold)

      {:error, reason} ->
        Logger.warning(
          "[Compactor] could not load message slice for session #{ctx.session_uuid}: " <>
            inspect(reason)
        )

        emit_error(:load_slice, reason, ctx.base_metadata)
        {:ok, install_overrides(action, params, existing_snapshot, ctx.request_id)}
    end
  end

  defp decide_and_run(action, params, %Ctx{} = ctx, existing, _slice, slice_count, threshold)
       when slice_count <= threshold do
    emit_skipped(
      :below_threshold,
      ctx.agent_id,
      ctx.tenant_id,
      ctx.session_uuid,
      ctx.request_id
    )

    {:ok, install_overrides(action, params, existing, ctx.request_id)}
  end

  defp decide_and_run(action, params, %Ctx{} = ctx, existing, slice, _slice_count, _threshold) do
    execute(action, params, ctx, existing, slice)
  end

  defp execute(action, params, %Ctx{} = ctx, existing_snapshot, slice) do
    Telemetry.with_compaction(
      "summary",
      ctx.base_metadata,
      fn -> do_execute(ctx, existing_snapshot, slice) end
    )
    |> handle_result(action, params, existing_snapshot, ctx.request_id)
  end

  defp do_execute(%Ctx{} = ctx, existing_snapshot, slice) do
    is_first? = is_nil(existing_snapshot)
    turns = TurnGrouping.group(slice)
    {protected, source, retained} = TurnGrouping.split(turns, ctx.config, is_first?)
    started_at_ms = System.system_time(:millisecond)

    case source do
      [] ->
        {:ok, :skipped, existing_snapshot, %{reason: :no_source_messages}}

      [_ | _] ->
        run_and_persist(ctx, existing_snapshot, source, protected, retained, started_at_ms)
    end
  end

  defp run_and_persist(
         %Ctx{} = ctx,
         existing_snapshot,
         source,
         protected,
         retained,
         started_at_ms
       ) do
    case run_summarizer(ctx, existing_snapshot, source) do
      {:ok, summary} ->
        snapshot =
          build_snapshot(ctx, existing_snapshot, summary, protected, source, retained,
            started_at_ms: started_at_ms
          )

        persist_or_error(ctx, snapshot)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp persist_or_error(%Ctx{} = ctx, %Snapshot{} = snapshot) do
    case Storage.persist(ctx.session_uuid, snapshot, ctx.storage_opts) do
      {:ok, _} ->
        {:ok, :summarized, snapshot, summarized_extras(snapshot)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp summarized_extras(%Snapshot{summary: summary} = snapshot) when is_binary(summary) do
    %{
      compaction_id: snapshot.id,
      status: :summarized,
      summary_chars: byte_size(summary),
      source_message_count: snapshot.source_message_count,
      retained_message_count: snapshot.retained_message_count,
      last_summarized_sequence: snapshot.last_summarized_sequence,
      summarized_request_id_count: length(snapshot.summarized_request_ids)
    }
  end

  defp handle_result(
         {:ok, :summarized, %Snapshot{} = snapshot, _extras},
         action,
         params,
         _previous,
         request_id
       ) do
    {:ok, install_overrides(action, params, snapshot, request_id)}
  end

  defp handle_result(
         {:ok, :skipped, snapshot_or_nil, _extras},
         action,
         params,
         previous,
         request_id
       ) do
    {:ok, install_overrides(action, params, snapshot_or_nil || previous, request_id)}
  end

  defp handle_result({:error, reason}, action, params, previous, request_id) do
    Logger.warning("[Compactor] summarization failed: #{inspect(reason)}")
    {:ok, install_overrides(action, params, previous, request_id)}
  end

  defp run_summarizer(%Ctx{} = ctx, existing_snapshot, source_turns) do
    prior_summary = existing_snapshot && existing_snapshot.summary
    transcript = build_transcript(source_turns)
    prompt = Prompt.build(transcript, prior_summary, ctx.config.max_summary_chars)

    Summarizer.summarize(prompt, ctx.config,
      request_id: ctx.request_id,
      agent_id: ctx.agent_id,
      tenant_id: ctx.tenant_id
    )
  end

  defp build_transcript(turns) do
    turns
    |> Enum.flat_map(& &1.messages)
    |> Enum.map_join("\n", &format_message_line/1)
  end

  @tool_payload_byte_budget 800

  defp format_message_line(msg) do
    role = normalize_role(Map.get(msg, :role))
    seq = Map.get(msg, :sequence)
    seq_label = if is_integer(seq), do: "##{seq} ", else: ""
    body = format_body(role, msg)
    "[#{seq_label}#{role_label(role)}] #{body}"
  end

  defp format_body(:tool_call, msg) do
    content = Map.get(msg, :content) || ""
    payload = format_tool_payload(msg, [:arguments, "arguments"])
    if payload == "", do: content, else: content <> "\n  args: " <> payload
  end

  defp format_body(:tool_result, msg) do
    content = Map.get(msg, :content) || ""
    payload = format_tool_payload(msg, [:result, "result"])
    if payload == "", do: content, else: content <> "\n  result: " <> payload
  end

  defp format_body(_role, msg), do: Map.get(msg, :content) || ""

  defp format_tool_payload(msg, keys) do
    case Map.get(msg, :metadata) do
      md when is_map(md) ->
        Enum.find_value(keys, "", fn k ->
          case Map.get(md, k) do
            nil -> nil
            val -> render_envelope(val)
          end
        end)

      _ ->
        ""
    end
  end

  defp render_envelope(value) do
    encoded =
      case Jason.encode(value) do
        {:ok, json} ->
          json

        {:error, _} ->
          inspect(value, limit: :infinity, printable_limit: @tool_payload_byte_budget)
      end

    truncate(encoded, @tool_payload_byte_budget)
  end

  defp truncate(text, max_bytes) when is_binary(text) do
    if byte_size(text) <= max_bytes do
      text
    else
      head = utf8_safe_prefix(text, max_bytes)
      extra = byte_size(text) - byte_size(head)
      head <> "… (truncated, #{extra} more bytes)"
    end
  end

  defp utf8_safe_prefix(text, max_bytes) when is_binary(text) and is_integer(max_bytes) do
    bounded = min(max_bytes, byte_size(text))
    do_utf8_safe_prefix(text, bounded)
  end

  defp do_utf8_safe_prefix(_text, n) when n <= 0, do: ""

  defp do_utf8_safe_prefix(text, n) do
    candidate = binary_part(text, 0, n)

    if String.valid?(candidate) do
      candidate
    else
      do_utf8_safe_prefix(text, n - 1)
    end
  end

  defp normalize_role(role) when is_atom(role), do: role

  defp normalize_role(role) when is_binary(role) do
    case role do
      "user" -> :user
      "assistant" -> :assistant
      "tool_call" -> :tool_call
      "tool_result" -> :tool_result
      "system" -> :system
      "reasoning" -> :reasoning
      _ -> :unknown
    end
  end

  defp normalize_role(_), do: :unknown

  defp role_label(:unknown), do: "msg"
  defp role_label(role), do: Atom.to_string(role)

  defp build_snapshot(
         %Ctx{} = ctx,
         existing,
         summary,
         protected,
         source,
         retained,
         opts
       ) do
    completed_at_ms = System.system_time(:millisecond)
    source_msgs = Enum.flat_map(source, & &1.messages)
    protected_msgs = Enum.flat_map(protected, & &1.messages)
    retained_msgs = Enum.flat_map(retained, & &1.messages)

    %Snapshot{
      id: generate_snapshot_id(),
      session_id: ctx.session_uuid,
      tenant_id: ctx.tenant_id,
      agent_id: ctx.agent_id,
      status: :summarized,
      strategy: ctx.config.strategy,
      summary: summary,
      summary_preview: Snapshot.preview(summary, 200),
      source_message_count: length(source_msgs),
      retained_message_count: length(retained_msgs),
      protected_message_count: length(protected_msgs),
      protected_turn_count: length(protected),
      last_summarized_sequence: max_sequence(source_msgs),
      summarized_request_ids: cumulative_ids(existing, source_msgs),
      last_summarized_request_id: last_request_id(source),
      last_summarized_at_ms: completed_at_ms,
      started_at_ms: Keyword.get(opts, :started_at_ms, completed_at_ms),
      completed_at_ms: completed_at_ms,
      error: nil,
      metadata: %{}
    }
  end

  defp cumulative_ids(existing, source_msgs) do
    new_source_request_ids =
      source_msgs
      |> Enum.map(&Map.get(&1, :request_id))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    ((existing && existing.summarized_request_ids) || [])
    |> Kernel.++(new_source_request_ids)
    |> Enum.uniq()
    |> Enum.reject(&is_nil/1)
  end

  defp max_sequence(messages) do
    messages
    |> Enum.map(&Map.get(&1, :sequence))
    |> Enum.filter(&is_integer/1)
    |> Enum.max(fn -> nil end)
  end

  defp last_request_id([_ | _] = turns) do
    turns |> Enum.reverse() |> hd() |> Map.get(:request_id)
  end

  defp threshold_for(%Config{max_messages: m}, nil), do: m

  defp threshold_for(%Config{recompact_delta_threshold: d}, %Snapshot{}),
    do: d

  defp load_slice_count(session_uuid, nil, storage_opts) do
    case Message.for_session(session_uuid,
           tenant: storage_opts[:tenant],
           actor: storage_opts[:actor]
         ) do
      {:ok, messages} -> {:ok, messages, length(messages)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp load_slice_count(session_uuid, %Snapshot{last_summarized_sequence: nil}, storage_opts) do
    load_slice_count(session_uuid, nil, storage_opts)
  end

  defp load_slice_count(
         session_uuid,
         %Snapshot{last_summarized_sequence: watermark},
         storage_opts
       ) do
    case Message.since_watermark(session_uuid, watermark,
           tenant: storage_opts[:tenant],
           actor: storage_opts[:actor]
         ) do
      {:ok, messages} -> {:ok, messages, length(messages)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp existing_transformer_collision?(params) do
    case Map.get(params, :request_transformer) do
      nil -> false
      RequestTransformer -> false
      _other -> true
    end
  end

  defp install_overrides(action, params, snapshot_or_nil, request_id) do
    new_params =
      params
      |> Map.put(:request_id, request_id)
      |> Map.put(:request_transformer, RequestTransformer)
      |> put_in_tool_context(snapshot_or_nil)
      |> put_extra_refs(request_id)

    put_elem(action, 1, new_params)
  end

  defp put_in_tool_context(params, nil) do
    Map.update(params, :tool_context, %{}, & &1)
  end

  defp put_in_tool_context(params, snapshot) do
    tc = Map.get(params, :tool_context) || %{}
    Map.put(params, :tool_context, Map.put(tc, @runtime_context_key, snapshot))
  end

  defp put_extra_refs(params, request_id) do
    extras = Map.get(params, :extra_refs) || %{}
    Map.put(params, :extra_refs, Map.put(extras, :request_id, request_id))
  end

  defp emit_skipped(reason, agent_id, tenant_id, session_uuid, request_id) do
    JidoClaw.Trace.emit(
      :compaction,
      %{
        event: :skipped,
        phase: :compaction,
        name: "summary",
        compaction: "summary",
        status: :skipped,
        reason: reason,
        agent_id: agent_id,
        tenant_id: tenant_id,
        session_uuid: session_uuid,
        request_id: request_id
      },
      %{system_time: System.system_time()}
    )

    :ok
  end

  defp emit_error(stage, reason, base_metadata) do
    JidoClaw.Trace.emit(
      :compaction,
      Map.merge(base_metadata, %{
        event: :error,
        phase: :compaction,
        name: "summary",
        compaction: "summary",
        status: :error,
        stage: stage,
        reason: inspect(reason)
      }),
      %{system_time: System.system_time()}
    )

    :ok
  end

  defp generate_request_id do
    SignalID.generate!()
  end

  defp generate_snapshot_id do
    "cpct_" <> SignalID.generate!()
  end

  @doc """
  Force a compaction for the given session, regardless of threshold.

  Returns `{:ok, %Snapshot{}}` on success or `{:error, exception}`. This is
  the API for manual compaction (REPL command, scheduled job). It loads
  the unsummarized slice exactly the way `maybe_compact/3` does, runs the
  bounded summarizer, persists the snapshot, and returns it.

  ## Options

    * `:tenant` (required) — tenant string for Ash policy.
    * `:actor` — Ash actor map; nil for system paths.
    * `:agent_id` — optional agent label for telemetry.
    * `:config` — `%Config{}` to use; defaults to `Config.default/0`.
  """
  @spec compact(String.t(), String.t(), keyword()) ::
          {:ok, Snapshot.t()} | {:error, Exception.t()}
  def compact(session_uuid, tenant_id, opts \\ [])
      when is_binary(session_uuid) and is_binary(tenant_id) and is_list(opts) do
    ctx = build_manual_ctx(session_uuid, tenant_id, opts)

    with {:ok, existing} <- Storage.latest(session_uuid, ctx.storage_opts),
         {:ok, slice, slice_count} <- load_slice_count(session_uuid, existing, ctx.storage_opts) do
      run_manual(ctx, existing, slice, slice_count)
    end
  end

  defp build_manual_ctx(session_uuid, tenant_id, opts) do
    config = Keyword.get(opts, :config) || Config.default()
    actor = Keyword.get(opts, :actor)
    agent_id = Keyword.get(opts, :agent_id)
    request_id = Keyword.get(opts, :request_id) || generate_request_id()

    %Ctx{
      config: config,
      tenant_id: tenant_id,
      session_uuid: session_uuid,
      actor: actor,
      agent_id: agent_id,
      request_id: request_id,
      storage_opts: [tenant: tenant_id, actor: actor],
      base_metadata: %{
        tenant_id: tenant_id,
        session_uuid: session_uuid,
        agent_id: agent_id,
        request_id: request_id,
        trigger: :manual
      }
    }
  end

  defp run_manual(%Ctx{} = ctx, existing, _slice, 0) do
    emit_skipped(
      :no_source_messages,
      ctx.agent_id,
      ctx.tenant_id,
      ctx.session_uuid,
      ctx.request_id
    )

    {:ok, existing || empty_snapshot(ctx)}
  end

  defp run_manual(%Ctx{} = ctx, existing, slice, _slice_count) do
    result =
      Telemetry.with_compaction(
        "summary",
        ctx.base_metadata,
        fn -> do_execute(ctx, existing, slice) end
      )

    case result do
      {:ok, :summarized, snapshot, _} -> {:ok, snapshot}
      {:ok, :skipped, snapshot, _} -> {:ok, snapshot || existing || empty_snapshot(ctx)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Return the latest persisted snapshot for `session_uuid`, or nil if none
  has been stored. Tenant-aware.
  """
  @spec latest(String.t(), keyword()) :: {:ok, Snapshot.t() | nil} | {:error, Exception.t()}
  def latest(session_uuid, opts) when is_binary(session_uuid) and is_list(opts) do
    Storage.latest(session_uuid, opts)
  end

  defp empty_snapshot(%Ctx{} = ctx) do
    now = System.system_time(:millisecond)

    %Snapshot{
      id: generate_snapshot_id(),
      session_id: ctx.session_uuid,
      tenant_id: ctx.tenant_id,
      agent_id: ctx.agent_id,
      status: :skipped,
      strategy: :summary,
      summary: nil,
      summary_preview: nil,
      source_message_count: 0,
      retained_message_count: 0,
      protected_message_count: 0,
      protected_turn_count: 0,
      last_summarized_sequence: nil,
      summarized_request_ids: [],
      last_summarized_request_id: nil,
      last_summarized_at_ms: nil,
      started_at_ms: now,
      completed_at_ms: now,
      error: nil,
      metadata: %{}
    }
  end
end
