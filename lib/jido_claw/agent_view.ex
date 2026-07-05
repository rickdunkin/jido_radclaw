defmodule JidoClaw.AgentView do
  @moduledoc """
  Read-only session-axis projection of "what is this agent doing right now".

  A `%JidoClaw.AgentView{}` is the unified shape that LiveView, the REPL,
  and the MCP server consume to render an agent's current state. It
  aggregates four sources — `JidoClaw.Trace`, `JidoClaw.Session.Worker`,
  `JidoClaw.Agent.Handoff.Registry`, and (optionally)
  `JidoClaw.Reasoning.Compactor.Storage` — into one stable struct so
  individual surfaces don't re-derive the projection.

  ## Identity vocabulary

  Two ids on the struct, easy to confuse:

    * `:session_id` — runtime session id, i.e. the string used by the live
      OTP layer. Matches `Conversations.Session.external_id`. Keys for
      `Session.Worker` registration and `Handoff.Registry`.
    * `:session_uuid` — `Conversations.Session.id`, the Postgres UUID used
      for FKs (Messages, RequestCorrelation, compaction snapshots).

  Both ids are carried because cold-read callers may have one but not the
  other; durable Ash reads need the UUID, but the live worker/registry
  layer is keyed on the runtime id.

  ## Status enum

  `:idle | :running | :awaiting_handoff | :awaiting_approval | :error |
  :hibernated | :agent_lost`. Note: completed traces map to `:idle` — a
  long-lived session whose last trace finished is "doing nothing right now"
  from the user's perspective. `:awaiting_approval` means the session has a
  pending tool-call approval case (the agent relayed an `approval_pending`
  error and is waiting on the operator). Consumers that want the terminal-state
  nuance read `:trace_status`, which carries
  `:completed | :cancelled | :interrupted` separately.
  """

  alias JidoClaw.Agent.Handoff.Registry, as: HandoffRegistry
  alias JidoClaw.Authorization.Actor
  alias JidoClaw.Conversations.Message, as: ConversationsMessage
  alias JidoClaw.Conversations.Session, as: ConversationsSession
  alias JidoClaw.Core.JsonSafe
  alias JidoClaw.Orchestration.AgentCase
  alias JidoClaw.Reasoning.Compactor.Identity, as: CompactionIdentity
  alias JidoClaw.Reasoning.Compactor.Storage, as: CompactorStorage
  alias JidoClaw.Session.Worker, as: SessionWorker
  alias JidoClaw.Trace
  alias JidoClaw.Trace.Event

  # Ash CRUD + Postgrex faults the cold-read paths can hit; narrowed so a
  # genuine bug surfaces instead of being swallowed as "session not found"
  # or an empty projection.
  @db_errors JidoClaw.Core.AshErrors.db_errors()

  @default_events_categories [:request, :model, :tool, :output, :handoff, :reasoning]
  @default_events_limit 100
  @default_messages_limit 50

  @type status ::
          :idle
          | :running
          | :awaiting_handoff
          | :awaiting_approval
          | :error
          | :hibernated
          | :agent_lost

  @type message :: %{role: String.t(), content: String.t(), timestamp: integer()}

  @type handoff_owner :: %{
          template: String.t(),
          module: module(),
          preamble_consumed?: boolean(),
          prompt_injected?: boolean(),
          updated_at_ms: integer()
        }

  @type t :: %__MODULE__{
          tenant_id: String.t(),
          session_id: String.t(),
          session_uuid: String.t() | nil,
          workspace_id: String.t() | nil,
          agent_id: String.t() | nil,
          agent_template: String.t() | nil,
          agent_module: module() | nil,
          status: status(),
          request_id: String.t() | nil,
          handoff_owner: handoff_owner() | nil,
          started_at: DateTime.t() | nil,
          last_active: DateTime.t() | nil,
          error: %{message: String.t() | nil, details: map()} | nil,
          messages: [message()],
          message_count: non_neg_integer(),
          streaming_message: nil,
          trace_id: String.t() | nil,
          run_id: String.t() | nil,
          trace_status: atom() | nil,
          events: [Event.t()],
          summary: map(),
          outcome: map() | nil,
          compaction: map() | nil,
          metadata: map()
        }

  defstruct tenant_id: nil,
            session_id: nil,
            session_uuid: nil,
            workspace_id: nil,
            agent_id: nil,
            agent_template: nil,
            agent_module: nil,
            status: :idle,
            request_id: nil,
            handoff_owner: nil,
            started_at: nil,
            last_active: nil,
            error: nil,
            messages: [],
            message_count: 0,
            streaming_message: nil,
            trace_id: nil,
            run_id: nil,
            trace_status: nil,
            events: [],
            summary: %{},
            outcome: nil,
            compaction: nil,
            metadata: %{}

  @type input ::
          %{required(:tenant_id) => String.t(), required(:session_id) => String.t()}
          | %ConversationsSession{}
          | %SessionWorker{}

  @type opts :: [
          events_limit: pos_integer() | :infinity,
          messages_limit: pos_integer() | :infinity,
          events_categories: [atom()] | :all,
          actor: map() | nil,
          include_compaction?: boolean()
        ]

  @doc """
  Build a `%JidoClaw.AgentView{}` snapshot for the given session input.

  See module doc for the identity vocabulary and supported input shapes.

  Returns `{:error, :tenant_required}` when a map input omits `tenant_id`,
  `{:error, :session_not_resolved}` when a map input neither finds a live
  worker nor resolves a `session_uuid`, `{:error, :session_id_mismatch}`
  when the supplied `session_id` does not match the resolved session's
  `external_id`, and `{:error, :session_not_found}` when a supplied
  `session_uuid` cannot be resolved under the supplied tenant.
  """
  @spec snapshot(input(), opts()) :: {:ok, t()} | {:error, term()}
  def snapshot(input, opts \\ []) do
    with {:ok, base} <- normalize_input(input, opts) do
      build_snapshot(base, opts)
    end
  end

  @doc """
  List live session-axis snapshots for a tenant.

  This keeps UI consumers from knowing how session workers are enumerated.
  Failed or racing sessions are omitted from the collection; callers that need
  a specific error should use `snapshot/2`.
  """
  @spec list(String.t(), opts()) :: [t()]
  def list(tenant_id, opts \\ []) when is_binary(tenant_id) do
    tenant_id
    |> JidoClaw.Session.Supervisor.list_sessions()
    |> Enum.flat_map(fn {session_id, _pid} ->
      case snapshot(%{tenant_id: tenant_id, session_id: session_id}, opts) do
        {:ok, view} -> [view]
        {:error, _} -> []
      end
    end)
  end

  @doc """
  Project an `%AgentView{}` into a JSON-safe map suitable for MCP output.

  Atoms become strings, `DateTime` / `NaiveDateTime` become ISO-8601
  strings, `MapSet` becomes a list, and modules / pids / refs are dropped.
  `Trace.Event` rows are slimmed to a small public shape.
  """
  @spec to_mcp_map(t()) :: map()
  def to_mcp_map(%__MODULE__{} = view) do
    view
    |> Map.from_struct()
    |> Map.delete(:agent_module)
    |> Map.update!(:events, fn events -> Enum.map(events, &event_to_map/1) end)
    |> JsonSafe.encode()
  end

  # ---------------------------------------------------------------------------
  # Input normalization
  # ---------------------------------------------------------------------------

  defp normalize_input(%ConversationsSession{} = session, opts) do
    tenant_id = session.tenant_id
    actor = Keyword.get(opts, :actor) || Actor.system(tenant_id)

    {:ok,
     %{
       tenant_id: tenant_id,
       session_id: session.external_id,
       session_uuid: session.id,
       workspace_id: session.workspace_id,
       session_record: session,
       actor: actor,
       strict?: false
     }}
  end

  defp normalize_input(%SessionWorker{tenant_id: tenant_id} = worker, opts)
       when is_binary(tenant_id) do
    actor = Keyword.get(opts, :actor) || worker.actor || Actor.system(tenant_id)

    {:ok,
     %{
       tenant_id: tenant_id,
       session_id: worker.id,
       session_uuid: worker.session_uuid,
       workspace_id: nil,
       session_record: nil,
       actor: actor,
       strict?: false
     }}
  end

  defp normalize_input(%{tenant_id: tenant_id, session_id: session_id} = map, opts)
       when is_binary(tenant_id) and is_binary(session_id) do
    actor = Keyword.get(opts, :actor) || Actor.system(tenant_id)
    supplied_uuid = Map.get(map, :session_uuid)

    case resolve_supplied_uuid(supplied_uuid, tenant_id, session_id, actor) do
      {:ok, session_record, session_uuid} ->
        {:ok,
         %{
           tenant_id: tenant_id,
           session_id: session_id,
           session_uuid: session_uuid,
           workspace_id: workspace_id_from(session_record),
           session_record: session_record,
           actor: actor,
           strict?: true
         }}

      :no_uuid_supplied ->
        {:ok,
         %{
           tenant_id: tenant_id,
           session_id: session_id,
           session_uuid: nil,
           workspace_id: nil,
           session_record: nil,
           actor: actor,
           strict?: true
         }}

      {:error, _} = err ->
        err
    end
  end

  defp normalize_input(%{session_id: _}, _opts), do: {:error, :tenant_required}
  defp normalize_input(_, _opts), do: {:error, :tenant_required}

  defp resolve_supplied_uuid(nil, _tenant_id, _session_id, _actor), do: :no_uuid_supplied

  defp resolve_supplied_uuid(session_uuid, tenant_id, session_id, actor)
       when is_binary(session_uuid) do
    case ConversationsSession.by_id(session_uuid, tenant: tenant_id, actor: actor) do
      {:ok, %ConversationsSession{external_id: ^session_id} = session} ->
        {:ok, session, session_uuid}

      {:ok, %ConversationsSession{}} ->
        {:error, :session_id_mismatch}

      {:ok, nil} ->
        {:error, :session_not_found}

      {:error, _} ->
        {:error, :session_not_found}
    end
  rescue
    _ in @db_errors ->
      # credo:disable-for-previous-line ExSlop.Check.Warning.RescueWithoutReraise
      {:error, :session_not_found}
  end

  defp workspace_id_from(%ConversationsSession{workspace_id: id}), do: id

  # ---------------------------------------------------------------------------
  # Snapshot assembly
  # ---------------------------------------------------------------------------

  defp build_snapshot(base, opts) do
    worker_info = safe_worker_info(base.tenant_id, base.session_id)
    base = adopt_worker_uuid(base, worker_info)

    case enforce_strict_contract(base, worker_info) do
      :ok ->
        assemble_view(base, worker_info, opts)

      {:error, _} = err ->
        err
    end
  end

  defp adopt_worker_uuid(%{session_uuid: nil} = base, {:ok, %{session_uuid: uuid}})
       when is_binary(uuid) do
    %{base | session_uuid: uuid}
  end

  defp adopt_worker_uuid(base, _), do: base

  defp enforce_strict_contract(%{strict?: true, session_uuid: nil}, :no_worker),
    do: {:error, :session_not_resolved}

  defp enforce_strict_contract(_, _), do: :ok

  defp safe_worker_info(tenant_id, session_id) do
    info = SessionWorker.get_info(tenant_id, session_id)
    {:ok, info}
  catch
    :exit, _ -> :no_worker
  end

  defp safe_worker_messages(tenant_id, session_id) do
    messages = SessionWorker.get_messages(tenant_id, session_id)
    {:ok, messages}
  catch
    :exit, _ -> :no_worker
  end

  defp assemble_view(base, worker_info, opts) do
    owner = safe_handoff_owner(base.tenant_id, base.session_id)
    {agent_template, agent_module} = template_module_for(owner)

    agent_id = pick_agent_id(base, worker_info, owner)
    trace = fetch_trace(agent_id, base.tenant_id)

    {events, summary} = trace_events_and_summary(trace, opts)

    {messages, message_count} = messages_and_count(base, worker_info, opts)

    status = derive_status(trace, owner, worker_info, base)
    error = if status == :error, do: derive_error_payload(trace), else: nil
    started_at = derive_started_at(worker_info, base.session_record)
    last_active = derive_last_active(worker_info, base.session_record)

    compaction = maybe_compaction(base, owner, opts)
    outcome = derive_outcome(trace)

    view = %__MODULE__{
      tenant_id: base.tenant_id,
      session_id: base.session_id,
      session_uuid: base.session_uuid,
      workspace_id: base.workspace_id,
      agent_id: agent_id_to_string(agent_id),
      agent_template: agent_template,
      agent_module: agent_module,
      status: status,
      request_id: trace_field(trace, :request_id),
      handoff_owner: owner_view(owner),
      started_at: started_at,
      last_active: last_active,
      error: error,
      messages: messages,
      message_count: message_count,
      streaming_message: nil,
      trace_id: trace_field(trace, :trace_id),
      run_id: trace_field(trace, :run_id),
      trace_status: trace_field(trace, :status),
      events: events,
      summary: summary,
      outcome: outcome,
      compaction: compaction,
      metadata: %{}
    }

    {:ok, view}
  end

  defp safe_handoff_owner(tenant_id, session_id) do
    HandoffRegistry.owner(tenant_id, session_id)
  catch
    :exit, _ -> nil
  end

  defp template_module_for(nil), do: {"main", JidoClaw.Agent}

  defp template_module_for(%{template: template, module: module}),
    do: {template, module}

  # Trace-id picker:
  #   1. Handoff owner: "handoff:<session_uuid>:<template>"; falls back to
  #      owner.handoff.session_uuid when the input lacks the resolved UUID.
  #   2. Live worker pid → use the pid directly (Trace.target_ref handles it).
  #   3. Otherwise: the runtime session_id (default routed_agent_id).
  defp pick_agent_id(base, _worker_info, owner) when not is_nil(owner) do
    uuid =
      base.session_uuid ||
        get_in(Map.from_struct(owner.handoff), [:session_uuid])

    "handoff:#{inspect_or(uuid)}:#{owner.template}"
  end

  defp pick_agent_id(base, {:ok, %{agent_pid: pid}}, _owner) when is_pid(pid) do
    # A dead pid falls through to the runtime session_id (still a valid trace
    # key per clause 3) rather than nil, so the snapshot doesn't drop
    # trace/events in the small race before Session.Worker processes the
    # agent's :DOWN.
    if Process.alive?(pid), do: pid, else: base.session_id
  end

  defp pick_agent_id(base, _worker_info, _owner), do: base.session_id

  defp inspect_or(nil), do: "nil"
  defp inspect_or(value) when is_binary(value), do: value

  defp agent_id_to_string(nil), do: nil
  defp agent_id_to_string(id) when is_binary(id), do: id
  defp agent_id_to_string(pid) when is_pid(pid), do: inspect(pid)

  defp fetch_trace(nil, _tenant_id), do: nil

  defp fetch_trace(target, tenant_id) do
    case Trace.latest(target, tenant_id: tenant_id) do
      {:ok, trace} -> trace
      {:error, _} -> nil
    end
  rescue
    # Read-only projection: a Trace lookup hiccup must not crash the
    # snapshot. Paired with `catch :exit, _` for non-existent target pids.
    # reach:disable-next-line bare_rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp trace_field(nil, _key), do: nil
  defp trace_field(%Trace{} = trace, key), do: Map.get(trace, key)

  defp trace_events_and_summary(nil, _opts), do: {[], %{}}

  defp trace_events_and_summary(%Trace{events: events, summary: summary}, opts) do
    categories = Keyword.get(opts, :events_categories, @default_events_categories)
    limit = Keyword.get(opts, :events_limit, @default_events_limit)

    filtered =
      case categories do
        :all -> events
        list when is_list(list) -> Enum.filter(events, &(&1.category in list))
      end

    capped =
      case limit do
        :infinity -> filtered
        n when is_integer(n) and n > 0 -> Enum.take(filtered, -n)
      end

    {capped, summary}
  end

  # Warm/mixed paths are unchanged; a cold snapshot runs the unlimited
  # `for_session_primary` read ONCE — count from the PRE-cap filtered rows
  # (`cold_messages/1` already restricts to chat roles), never `length` of
  # the capped list.
  defp messages_and_count(base, {:ok, _} = worker_info, opts),
    do: {fetch_messages(base, worker_info, opts), total_message_count(worker_info, base)}

  defp messages_and_count(base, :no_worker, opts) do
    rows = cold_messages(base)
    limit = Keyword.get(opts, :messages_limit, @default_messages_limit)
    {cap_messages(rows, limit), length(rows)}
  end

  defp fetch_messages(base, worker_info, opts) do
    limit = Keyword.get(opts, :messages_limit, @default_messages_limit)
    raw = raw_messages(base, worker_info)
    cap_messages(raw, limit)
  end

  defp raw_messages(base, {:ok, _info}) do
    case safe_worker_messages(base.tenant_id, base.session_id) do
      {:ok, messages} when is_list(messages) -> messages
      _ -> cold_messages(base)
    end
  end

  defp cold_messages(%{session_uuid: nil}), do: []

  defp cold_messages(%{session_uuid: session_uuid, tenant_id: tenant_id, actor: actor}) do
    # Primary view only — sub-agent rows belong to their own slices and are
    # never part of the chat-visible conversation.
    case ConversationsMessage.for_session_primary(session_uuid, tenant: tenant_id, actor: actor) do
      {:ok, rows} ->
        rows
        |> Enum.filter(&(&1.role in [:user, :assistant, :system]))
        |> Enum.map(&cold_message_view/1)

      _ ->
        []
    end
  rescue
    _ in @db_errors ->
      # credo:disable-for-previous-line ExSlop.Check.Warning.RescueWithoutReraise
      []
  end

  defp cold_message_view(%{role: role, content: content, inserted_at: inserted_at}) do
    %{
      role: Atom.to_string(role),
      content: content,
      timestamp: DateTime.to_unix(inserted_at, :millisecond)
    }
  end

  defp cap_messages(messages, :infinity), do: messages
  defp cap_messages(messages, n) when is_integer(n) and n > 0, do: Enum.take(messages, -n)

  defp total_message_count({:ok, %{message_count: count}}, _base) when is_integer(count),
    do: count

  defp derive_status(trace, owner, worker_info, base) do
    cond do
      trace_field(trace, :status) == :failed -> :error
      trace_field(trace, :status) == :running -> :running
      awaiting_handoff?(owner) -> :awaiting_handoff
      awaiting_tool_approval?(base.session_uuid, base.tenant_id, base.actor) -> :awaiting_approval
      worker_status(worker_info) == :hibernated -> :hibernated
      worker_status(worker_info) == :agent_lost -> :agent_lost
      true -> :idle
    end
  end

  defp awaiting_handoff?(%{preamble_consumed?: false}), do: true
  defp awaiting_handoff?(_), do: false

  # A session with a pending tool-call approval case is "awaiting approval".
  # Guard on a non-empty `session_uuid` — a worker can briefly exist before its
  # durable session UUID is wired (`Session.Worker`), so `pending_for_session`
  # must never be issued with `nil`. A DB fault degrades to `false`.
  defp awaiting_tool_approval?(session_uuid, tenant_id, actor)
       when is_binary(session_uuid) and session_uuid != "" do
    match?(
      {:ok, [_ | _]},
      AgentCase.pending_for_session(session_uuid, tenant: tenant_id, actor: actor)
    )
  rescue
    _ in @db_errors ->
      # credo:disable-for-previous-line ExSlop.Check.Warning.RescueWithoutReraise
      false
  end

  defp awaiting_tool_approval?(_session_uuid, _tenant_id, _actor), do: false

  defp worker_status({:ok, %{status: status}}), do: status
  defp worker_status(_), do: nil

  defp derive_error_payload(nil), do: nil

  defp derive_error_payload(%Trace{events: events}) do
    error_event =
      events
      |> Enum.reverse()
      |> Enum.find(&(&1.status == :failed))

    case error_event do
      nil ->
        nil

      %Event{} = ev ->
        meta = ev.metadata || %{}
        message = meta[:error] || meta[:message] || ev.name || Atom.to_string(ev.event)
        %{message: to_string_safe(message), details: meta}
    end
  end

  defp to_string_safe(value) when is_binary(value), do: value
  defp to_string_safe(value) when is_atom(value), do: Atom.to_string(value)
  defp to_string_safe(value), do: inspect(value)

  defp derive_started_at({:ok, %{created_at: %DateTime{} = created_at}}, _),
    do: created_at

  defp derive_started_at(_, %ConversationsSession{started_at: %DateTime{} = started_at}),
    do: started_at

  defp derive_started_at(_, _), do: nil

  defp derive_last_active({:ok, %{last_active: %DateTime{} = last_active}}, _),
    do: last_active

  defp derive_last_active(_, %ConversationsSession{last_active_at: %DateTime{} = la}),
    do: la

  defp derive_last_active(_, _), do: nil

  defp owner_view(nil), do: nil

  defp owner_view(owner) do
    %{
      template: owner.template,
      module: owner.module,
      preamble_consumed?: Map.get(owner, :preamble_consumed?, false),
      # The registry stores the injected worker's pid (so a recreated worker
      # re-injects); the view exposes only the derived boolean — pids are
      # in-node runtime detail, not serialization-safe presentation data.
      prompt_injected?: is_pid(Map.get(owner, :prompt_injected_pid)),
      updated_at_ms: Map.get(owner, :updated_at_ms)
    }
  end

  defp maybe_compaction(base, owner, opts) do
    if Keyword.get(opts, :include_compaction?, true) and is_binary(base.session_uuid) do
      load_compaction(base, compaction_key_for(base, owner))
    end
  end

  defp load_compaction(%{session_uuid: session_uuid, tenant_id: tenant_id, actor: actor}, key) do
    case CompactorStorage.latest(session_uuid, tenant: tenant_id, actor: actor, key: key) do
      {:ok, nil} -> nil
      {:ok, snapshot} -> snapshot_to_map(snapshot)
      _ -> nil
    end
  rescue
    # Read-only projection: compaction storage hiccup must not crash the
    # snapshot. Paired with `catch :exit, _` for storage-GenServer non-exists.
    # reach:disable-next-line bare_rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  # The snapshot key for the conversation's current owner: the handoff
  # worker's identity when a handoff is active, else `"main"`. Run through
  # the shared helper so the main case normalizes to `"main"` regardless of
  # surface.
  defp compaction_key_for(_base, nil), do: "#{CompactionIdentity.main()}::default"

  defp compaction_key_for(base, owner) do
    uuid = base.session_uuid || get_in(Map.from_struct(owner.handoff), [:session_uuid])
    worker_id = "handoff:#{inspect_or(uuid)}:#{owner.template}"

    identity =
      CompactionIdentity.resolve(owner.template, worker_id, base.session_id) ||
        CompactionIdentity.main()

    "#{identity}::default"
  end

  defp snapshot_to_map(%_{} = snap), do: Map.from_struct(snap)

  defp derive_outcome(nil), do: nil

  defp derive_outcome(%Trace{events: events}) do
    case events
         |> Enum.reverse()
         |> Enum.find(&(&1.category == :output and &1.status == :completed)) do
      nil ->
        nil

      %Event{} = ev ->
        %{
          event: ev.event,
          status: ev.status,
          measurements: ev.measurements || %{},
          metadata: ev.metadata || %{},
          at_ms: ev.at_ms
        }
    end
  end

  # ---------------------------------------------------------------------------
  # MCP projection helpers
  # ---------------------------------------------------------------------------

  defp event_to_map(%Event{} = ev) do
    %{
      seq: ev.seq,
      at_ms: ev.at_ms,
      category: ev.category,
      event: ev.event,
      status: ev.status,
      phase: ev.phase,
      name: ev.name,
      duration_ms: ev.duration_ms,
      measurements: ev.measurements || %{},
      metadata: ev.metadata || %{}
    }
  end
end
