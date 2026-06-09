defmodule JidoClaw.Forge.Persistence do
  @moduledoc false
  require Logger
  require Ash.Query

  # Ash CRUD + Postgrex faults this best-effort persistence layer can hit;
  # rescues narrow to these so an unexpected error (a real bug) surfaces
  # instead of being logged-and-swallowed.
  @db_errors [
    Ash.Error.Invalid,
    Ash.Error.Unknown,
    Ash.Error.Query.NotFound,
    DBConnection.ConnectionError,
    DBConnection.OwnershipError,
    Postgrex.Error
  ]

  alias Ash.Query
  alias JidoClaw.Authorization.Actor
  alias JidoClaw.Core.MapKeys
  alias JidoClaw.Forge.Resources.Checkpoint
  alias JidoClaw.Forge.Resources.Event
  alias JidoClaw.Forge.Resources.Session
  alias JidoClaw.Security.Redaction.Patterns

  def enabled? do
    Application.get_env(:jido_claw, __MODULE__, [])
    |> Keyword.get(:enabled, true)
  end

  def record_session_started(session_id, spec) do
    if enabled?() do
      with {:ok, scope} <- scope_from_spec(spec) do
        attrs =
          session_attrs(session_id, spec)
          |> Map.put(:workspace_id, scope.workspace_id)

        try do
          case Ash.create(Session, attrs,
                 action: :start,
                 tenant: scope.tenant_id,
                 actor: scope.actor
               ) do
            {:ok, session} ->
              session

            {:error, e} ->
              Logger.warning("[Forge.Persistence] Failed to record session: #{inspect(e)}")
              nil
          end
        rescue
          e in @db_errors ->
            # credo:disable-for-previous-line ExSlop.Check.Warning.RescueWithoutReraise
            Logger.warning("[Forge.Persistence] Failed to record session: #{inspect(e)}")
        end
      else
        {:error, reason} ->
          Logger.warning("[Forge.Persistence] Missing Forge session scope: #{inspect(reason)}")
          nil
      end
    end
  end

  @terminal_phases [:completed, :cancelled, :failed]
  # Phases left by a crashed process — reclaimable during recovery.
  # Excludes :created (means another node just claimed it in this cycle).
  @recoverable_phases [:running, :ready, :needs_input, :provisioning, :bootstrapping, :resuming]

  @doc """
  Atomically claim ownership of a session_id across the cluster.

  Uses a PostgreSQL advisory lock (`pg_advisory_xact_lock`) inside a
  transaction to serialize all claim attempts for the same session_id.
  This makes every path — new names, terminal reuse, and recovery —
  fully atomic across nodes.

  Options:
    - `recovery: true` — allows claiming a session whose DB row is in
      an active phase (the process crashed, leaving stale state).
      Without this flag, active-phase rows are rejected as a safety net.

  Returns `:ok`, `{:error, :already_claimed}`, or `{:error, :scope_required}`
  when the spec carries no tenant/workspace scope (callers must handle the
  latter — see `JidoClaw.Forge.Harness.stop_unclaimed_session/2`).
  When persistence is disabled (tests), returns `:ok` unconditionally.
  """
  def claim_session(session_id, spec, opts \\ []) do
    if enabled?(), do: do_claim_session(session_id, spec, opts), else: :ok
  rescue
    e in @db_errors ->
      # credo:disable-for-previous-line ExSlop.Check.Warning.RescueWithoutReraise
      Logger.warning("[Forge.Persistence] claim_session failed: #{inspect(e)}")
      {:error, :already_claimed}
  end

  defp do_claim_session(session_id, spec, opts) do
    with {:ok, scope} <- scope_from_spec(spec) do
      recovery? = Keyword.get(opts, :recovery, false)

      attrs =
        session_attrs(session_id, spec)
        |> Map.put(:workspace_id, scope.workspace_id)

      session_id
      |> claim_transaction(attrs, scope, recovery?)
      |> normalize_claim_result()
    end
  end

  defp claim_transaction(session_id, attrs, scope, recovery?) do
    Ash.transaction(Session, fn ->
      JidoClaw.Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [session_id])
      claim_after_lock(find_session(session_id, scope), attrs, scope, recovery?)
    end)
  end

  defp normalize_claim_result({:ok, :ok}), do: :ok
  defp normalize_claim_result({:error, _}), do: {:error, :already_claimed}

  # No existing row — create fresh. Upsert just inserts when no matching row
  # exists, so :start is safe for both paths.
  defp claim_after_lock(nil, attrs, scope, _recovery?), do: claim_via_start(attrs, scope)

  # Terminal session — reuse the name via upsert, preserving the row ID so FK
  # relationships to events/checkpoints are maintained.
  defp claim_after_lock(%{phase: phase}, attrs, scope, _recovery?)
       when phase in @terminal_phases do
    claim_via_start(attrs, scope)
  end

  # Recovery: stale active phase from a crashed process. :created is excluded
  # from @recoverable_phases because it means another node just claimed.
  defp claim_after_lock(%{phase: phase}, attrs, scope, true)
       when phase in @recoverable_phases do
    claim_via_start(attrs, scope)
  end

  # Either a fresh start seeing an active row, or recovery seeing :created.
  defp claim_after_lock(%{}, _attrs, _scope, _recovery?) do
    Ash.DataLayer.rollback(Session, :already_claimed)
  end

  defp claim_via_start(attrs, scope) do
    case Ash.create(Session, attrs,
           action: :start,
           tenant: scope.tenant_id,
           actor: scope.actor
         ) do
      {:ok, _} -> :ok
      {:error, e} -> Ash.DataLayer.rollback(Session, {:start_failed, e})
    end
  end

  defp session_attrs(session_id, spec) do
    %{
      name: session_id,
      runner_type: to_string(Map.get(spec, :runner, :shell)),
      runner_config: Map.get(spec, :runner_config, %{}),
      spec: redact_map(spec),
      started_at: DateTime.utc_now()
    }
  end

  def record_execution_complete(
        session_id,
        output,
        exit_code,
        sequence,
        runner_status \\ nil,
        started_at \\ nil
      ) do
    if enabled?() do
      try do
        session = find_session(session_id)

        if session do
          start_attrs = %{
            session_id: session.id,
            sequence: sequence,
            command: "iteration"
          }

          start_attrs =
            if started_at,
              do: Map.put(start_attrs, :started_at, started_at),
              else: start_attrs

          case Ash.create(JidoClaw.Forge.Resources.ExecSession, start_attrs) do
            {:ok, exec_session} ->
              finish_execution(exec_session, output, exit_code, runner_status)

            {:error, e} ->
              Logger.warning("[Forge.Persistence] Failed to start exec session: #{inspect(e)}")
              nil
          end
        end
      rescue
        e in @db_errors ->
          # credo:disable-for-previous-line ExSlop.Check.Warning.RescueWithoutReraise
          Logger.warning("[Forge.Persistence] Failed to record execution: #{inspect(e)}")
      end
    end
  end

  defp finish_execution(exec_session, output, exit_code, runner_status) do
    result_status =
      case runner_status do
        :error -> :failed
        _ -> if exit_code == 0, do: :completed, else: :failed
      end

    raw_output_bytes = byte_size(output || "")

    exec_session
    |> Ash.Changeset.for_update(:complete, %{
      result_status: result_status,
      output: truncate(Patterns.redact(output || ""), 10_000),
      exit_code: exit_code,
      raw_output_bytes: raw_output_bytes
    })
    |> Ash.update()
    |> case do
      {:ok, exec} ->
        exec

      {:error, e} ->
        Logger.warning("[Forge.Persistence] Failed to complete exec session: #{inspect(e)}")
        nil
    end
  end

  def log_event(session_id, event_type, data \\ %{}, exec_session_sequence \\ nil) do
    if enabled?() do
      try do
        session = find_session(session_id)

        if session do
          attrs = %{
            session_id: session.id,
            event_type: to_string(event_type),
            data: redact_map(data)
          }

          attrs =
            if exec_session_sequence,
              do: Map.put(attrs, :exec_session_sequence, exec_session_sequence),
              else: attrs

          case Ash.create(JidoClaw.Forge.Resources.Event, attrs) do
            {:ok, event} ->
              event

            {:error, e} ->
              Logger.warning("[Forge.Persistence] Failed to log event: #{inspect(e)}")
              nil
          end
        end
      rescue
        e in @db_errors ->
          # credo:disable-for-previous-line ExSlop.Check.Warning.RescueWithoutReraise
          Logger.warning("[Forge.Persistence] Failed to log event: #{inspect(e)}")
      end
    end
  end

  def update_session_phase(session_id, phase) do
    if enabled?() do
      try do
        session = find_session(session_id)

        if session do
          session
          |> Ash.Changeset.for_update(:update_phase, %{phase: phase})
          |> Ash.update(session_action_opts(session))
          |> case do
            {:ok, updated} ->
              updated

            {:error, e} ->
              Logger.warning("[Forge.Persistence] Failed to update session phase: #{inspect(e)}")
              nil
          end
        end
      rescue
        e in @db_errors ->
          # credo:disable-for-previous-line ExSlop.Check.Warning.RescueWithoutReraise
          Logger.warning("[Forge.Persistence] Failed to update session phase: #{inspect(e)}")
      end
    end
  end

  def record_sandbox_id(session_id, sandbox_id) do
    if enabled?() do
      try do
        session = find_session(session_id)

        if session do
          session
          |> Ash.Changeset.for_update(:set_sandbox_id, %{sandbox_id: sandbox_id})
          |> Ash.update(session_action_opts(session))
          |> case do
            {:ok, updated} ->
              updated

            {:error, e} ->
              Logger.warning("[Forge.Persistence] Failed to record sandbox_id: #{inspect(e)}")
              nil
          end
        end
      rescue
        e in @db_errors ->
          # credo:disable-for-previous-line ExSlop.Check.Warning.RescueWithoutReraise
          Logger.warning("[Forge.Persistence] Failed to record sandbox_id: #{inspect(e)}")
      end
    end
  end

  def save_checkpoint(session_id, sequence, runner_state_snapshot, metadata \\ %{}) do
    if enabled?() do
      try do
        session = find_session(session_id)

        if session do
          attrs = %{
            session_id: session.id,
            exec_session_sequence: sequence,
            runner_state_snapshot: runner_state_snapshot,
            metadata: metadata
          }

          case Ash.create(JidoClaw.Forge.Resources.Checkpoint, attrs) do
            {:ok, checkpoint} ->
              checkpoint

            {:error, e} ->
              Logger.warning("[Forge.Persistence] Failed to save checkpoint: #{inspect(e)}")
              nil
          end
        end
      rescue
        e in @db_errors ->
          # credo:disable-for-previous-line ExSlop.Check.Warning.RescueWithoutReraise
          Logger.warning("[Forge.Persistence] Failed to save checkpoint: #{inspect(e)}")
      end
    end
  end

  def latest_checkpoint(session_id) do
    if enabled?() do
      try do
        session = find_session(session_id)

        if session do
          Checkpoint.query_to_latest_for_session(%{session_id: session.id})
          |> Ash.read()
          |> case do
            {:ok, checkpoints} ->
              List.first(checkpoints)

            {:error, e} ->
              Logger.warning("[Forge.Persistence] Failed to get latest checkpoint: #{inspect(e)}")
              nil
          end
        end
      rescue
        e in [
          Ash.Error.Invalid,
          Ash.Error.Unknown,
          Ash.Error.Query.NotFound,
          DBConnection.ConnectionError,
          DBConnection.OwnershipError,
          Postgrex.Error
        ] ->
          # credo:disable-for-previous-line ExSlop.Check.Warning.RescueWithoutReraise
          Logger.warning("[Forge.Persistence] Failed to get latest checkpoint: #{inspect(e)}")
          nil
      end
    end
  end

  def get_events(session_id, opts \\ []) do
    if enabled?() do
      try do
        session = find_session(session_id)

        if session do
          args = %{session_id: session.id}

          args =
            if opts[:after_timestamp],
              do: Map.put(args, :after, opts[:after_timestamp]),
              else: args

          args =
            if opts[:after_sequence],
              do: Map.put(args, :after_sequence, opts[:after_sequence]),
              else: args

          args =
            if opts[:event_types], do: Map.put(args, :event_types, opts[:event_types]), else: args

          args = if opts[:limit], do: Map.put(args, :limit, opts[:limit]), else: args

          Event.query_to_list_for_session(args)
          |> Ash.read()
          |> case do
            {:ok, events} ->
              events

            {:error, e} ->
              Logger.warning("[Forge.Persistence] Failed to get events: #{inspect(e)}")
              []
          end
        else
          []
        end
      rescue
        e in @db_errors ->
          # credo:disable-for-previous-line ExSlop.Check.Warning.RescueWithoutReraise
          Logger.warning("[Forge.Persistence] Failed to get events: #{inspect(e)}")
          []
      end
    else
      []
    end
  end

  def context_for_resume(session_id) do
    if enabled?() do
      try do
        session = find_session(session_id)

        if session do
          checkpoint = latest_checkpoint(session_id)

          events_since =
            case checkpoint do
              %{created_at: ts} ->
                get_events(session_id, after_timestamp: ts)

              _ ->
                get_events(session_id)
            end

          all_events = get_events(session_id)

          last_output = latest_exec_output(session)

          error_events =
            Enum.filter(all_events, fn e ->
              String.contains?(e.event_type, "failed") or
                iteration_error?(e)
            end)

          iteration_count =
            Enum.count(all_events, &(&1.event_type == "iteration.completed"))

          %{
            session: session,
            last_checkpoint: checkpoint,
            events_since_checkpoint: events_since,
            iteration_count: iteration_count,
            last_output: last_output,
            error_history: error_events
          }
        end
      rescue
        e in [
          Ash.Error.Invalid,
          Ash.Error.Unknown,
          Ash.Error.Query.NotFound,
          DBConnection.ConnectionError,
          DBConnection.OwnershipError,
          Postgrex.Error
        ] ->
          # credo:disable-for-previous-line ExSlop.Check.Warning.RescueWithoutReraise
          Logger.warning("[Forge.Persistence] Failed to build context_for_resume: #{inspect(e)}")
          nil
      end
    end
  end

  def find_session(session_id) do
    find_session_global(session_id)
  end

  def find_session(session_id, %{tenant_id: tenant_id, actor: actor})
      when is_binary(tenant_id) do
    Session
    |> Query.filter(name == ^session_id)
    |> Query.sort(inserted_at: :desc)
    |> Query.limit(1)
    |> Ash.read(tenant: tenant_id, actor: actor)
    |> case do
      {:ok, sessions} -> List.first(sessions)
      {:error, _} -> nil
    end
  rescue
    _ in [
      Ash.Error.Invalid,
      Ash.Error.Unknown,
      Ash.Error.Query.NotFound,
      DBConnection.ConnectionError,
      DBConnection.OwnershipError,
      Postgrex.Error
    ] ->
      nil
  end

  def find_session(session_id, opts) when is_list(opts) do
    with {:ok, scope} <- scope_from_opts(opts) do
      find_session(session_id, scope)
    else
      _ -> nil
    end
  end

  defp find_session_global(session_id) do
    case Session.by_name_global(session_id) do
      {:ok, session} -> session
      {:error, _} -> nil
    end
  rescue
    _ in [
      Ash.Error.Invalid,
      Ash.Error.Unknown,
      Ash.Error.Query.NotFound,
      DBConnection.ConnectionError,
      DBConnection.OwnershipError,
      Postgrex.Error
    ] ->
      nil
  end

  defp scope_from_spec(spec) when is_map(spec) do
    tenant_id = Map.get(spec, :tenant_id) || get_in(spec, [:tool_context, :tenant_id])

    workspace_id =
      Map.get(spec, :workspace_id) ||
        Map.get(spec, :workspace_uuid) ||
        get_in(spec, [:tool_context, :workspace_uuid])

    scope_from_values(tenant_id, workspace_id)
  end

  defp scope_from_spec(_), do: {:error, :scope_required}

  defp scope_from_opts(opts) when is_list(opts) do
    scope_from_values(Keyword.get(opts, :tenant_id), Keyword.get(opts, :workspace_id))
  end

  defp scope_from_values(tenant_id, workspace_id)
       when is_binary(tenant_id) and tenant_id != "" and is_binary(workspace_id) and
              workspace_id != "" do
    {:ok, %{tenant_id: tenant_id, workspace_id: workspace_id, actor: Actor.system(tenant_id)}}
  end

  defp scope_from_values(_tenant_id, _workspace_id), do: {:error, :scope_required}

  defp redact_map(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_binary(v) -> {k, Patterns.redact(v)}
      {k, v} when is_map(v) -> {k, redact_map(v)}
      {k, v} when is_list(v) -> {k, redact_list(v)}
      pair -> pair
    end)
  end

  defp redact_map(other), do: other

  defp redact_list(list) when is_list(list) do
    Enum.map(list, fn
      v when is_map(v) -> redact_map(v)
      v when is_binary(v) -> Patterns.redact(v)
      v when is_list(v) -> redact_list(v)
      v -> v
    end)
  end

  defp truncate(str, max) when byte_size(str) > max do
    binary_part(str, byte_size(str) - max, max)
  end

  defp truncate(str, _max), do: str

  defp latest_exec_output(session) do
    JidoClaw.Forge.Resources.ExecSession
    |> Query.filter(session_id == ^session.id)
    |> Query.sort(sequence: :desc)
    |> Query.limit(1)
    |> Ash.read()
    |> case do
      {:ok, [exec]} ->
        %{
          output: exec.output,
          exit_code: exec.exit_code,
          status: exec.status,
          sequence: exec.sequence
        }

      {:ok, []} ->
        nil

      {:error, _} ->
        nil
    end
  rescue
    _ in @db_errors -> nil
  end

  defp iteration_error?(%{event_type: "iteration.completed", data: data}) do
    status = MapKeys.coalesce_field(data, "status")
    status in [:error, "error"]
  end

  defp iteration_error?(_), do: false

  defp session_action_opts(%Session{tenant_id: tenant_id}) when is_binary(tenant_id) do
    [tenant: tenant_id, actor: Actor.system(tenant_id)]
  end
end
