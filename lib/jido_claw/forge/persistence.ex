defmodule JidoClaw.Forge.Persistence do
  require Logger
  require Ash.Query

  alias JidoClaw.Security.Redaction.Patterns

  def enabled? do
    Application.get_env(:jido_claw, __MODULE__, [])
    |> Keyword.get(:enabled, true)
  end

  def record_session_started(session_id, spec) do
    if enabled?() do
      try do
        Ash.create!(
          JidoClaw.Forge.Resources.Session,
          %{
            name: session_id,
            runner_type: to_string(Map.get(spec, :runner, :shell)),
            runner_config: Map.get(spec, :runner_config, %{}),
            spec: redact_map(spec),
            started_at: DateTime.utc_now()
          },
          action: :start,
          authorize?: false
        )
      rescue
        e -> Logger.warning("[Forge.Persistence] Failed to record session: #{inspect(e)}")
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

  Returns `:ok` or `{:error, :already_claimed}`.
  When persistence is disabled (tests), returns `:ok` unconditionally.
  """
  def claim_session(session_id, spec, opts \\ []) do
    if enabled?() do
      recovery? = Keyword.get(opts, :recovery, false)
      attrs = session_attrs(session_id, spec)

      Ash.transaction(JidoClaw.Forge.Resources.Session, fn ->
        # Advisory lock serializes all claim attempts for this session_id
        # across every node connected to the same database.
        JidoClaw.Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [session_id])

        case find_session(session_id) do
          nil ->
            # No existing row — create fresh
            claim_create(attrs)

          %{phase: phase} when phase in @terminal_phases ->
            # Terminal session — reuse the name via upsert (preserves row
            # ID so FK relationships to events/checkpoints are maintained)
            claim_upsert(attrs)

          %{phase: phase} when recovery? and phase in @recoverable_phases ->
            # Recovery: stale active phase from a crashed process.
            # The advisory lock prevents two recovery attempts from both
            # succeeding. :created is excluded — it means another node
            # just claimed in this cycle.
            claim_upsert(attrs)

          %{} ->
            # Either a fresh start seeing an active row, or recovery
            # seeing :created (another node just claimed). Reject.
            Ash.DataLayer.rollback(JidoClaw.Forge.Resources.Session, :already_claimed)
        end
      end)
      |> case do
        {:ok, :ok} -> :ok
        {:error, :already_claimed} -> {:error, :already_claimed}
        {:error, _} -> {:error, :already_claimed}
      end
    else
      :ok
    end
  rescue
    e ->
      Logger.warning("[Forge.Persistence] claim_session failed: #{inspect(e)}")
      {:error, :already_claimed}
  end

  defp claim_create(attrs) do
    case Ash.create(JidoClaw.Forge.Resources.Session, attrs, action: :create, authorize?: false) do
      {:ok, _} -> :ok
      {:error, e} -> Ash.DataLayer.rollback(JidoClaw.Forge.Resources.Session, {:create_failed, e})
    end
  end

  defp claim_upsert(attrs) do
    case Ash.create(JidoClaw.Forge.Resources.Session, attrs, action: :start, authorize?: false) do
      {:ok, _} -> :ok
      {:error, e} -> Ash.DataLayer.rollback(JidoClaw.Forge.Resources.Session, {:upsert_failed, e})
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

  def record_execution_complete(session_id, output, exit_code, sequence, runner_status \\ nil) do
    if enabled?() do
      try do
        session = find_session(session_id)

        if session do
          # Two-step flow: create with :start, then update with :complete
          exec_session =
            Ash.create!(
              JidoClaw.Forge.Resources.ExecSession,
              %{
                session_id: session.id,
                sequence: sequence,
                command: "iteration"
              },
              authorize?: false
            )

          result_status =
            case runner_status do
              :error -> :failed
              _ -> if exit_code == 0, do: :completed, else: :failed
            end

          exec_session
          |> Ash.Changeset.for_update(:complete, %{
            result_status: result_status,
            output: truncate(Patterns.redact(output || ""), 10_000),
            exit_code: exit_code
          })
          |> Ash.update!(authorize?: false)
        end
      rescue
        e -> Logger.warning("[Forge.Persistence] Failed to record execution: #{inspect(e)}")
      end
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

          Ash.create!(JidoClaw.Forge.Resources.Event, attrs, authorize?: false)
        end
      rescue
        e -> Logger.warning("[Forge.Persistence] Failed to log event: #{inspect(e)}")
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
          |> Ash.update!(authorize?: false)
        end
      rescue
        e -> Logger.warning("[Forge.Persistence] Failed to update session phase: #{inspect(e)}")
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
          |> Ash.update!(authorize?: false)
        end
      rescue
        e -> Logger.warning("[Forge.Persistence] Failed to record sandbox_id: #{inspect(e)}")
      end
    end
  end

  def save_checkpoint(session_id, sequence, runner_state_snapshot, metadata \\ %{}) do
    if enabled?() do
      try do
        session = find_session(session_id)

        if session do
          Ash.create!(
            JidoClaw.Forge.Resources.Checkpoint,
            %{
              session_id: session.id,
              exec_session_sequence: sequence,
              runner_state_snapshot: runner_state_snapshot,
              metadata: metadata
            },
            authorize?: false
          )
        end
      rescue
        e -> Logger.warning("[Forge.Persistence] Failed to save checkpoint: #{inspect(e)}")
      end
    end
  end

  def latest_checkpoint(session_id) do
    if enabled?() do
      try do
        session = find_session(session_id)

        if session do
          JidoClaw.Forge.Resources.Checkpoint
          |> Ash.Query.for_read(:latest_for_session, %{session_id: session.id})
          |> Ash.read!(authorize?: false)
          |> List.first()
        end
      rescue
        e ->
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

          JidoClaw.Forge.Resources.Event
          |> Ash.Query.for_read(:for_session, args)
          |> Ash.read!(authorize?: false)
        else
          []
        end
      rescue
        e ->
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
        e ->
          Logger.warning("[Forge.Persistence] Failed to build context_for_resume: #{inspect(e)}")
          nil
      end
    end
  end

  def find_session(session_id) do
    try do
      JidoClaw.Forge.Resources.Session
      |> Ash.Query.filter(name == ^session_id)
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.Query.limit(1)
      |> Ash.read!(authorize?: false)
      |> List.first()
    rescue
      _ -> nil
    end
  end

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
    |> Ash.Query.filter(session_id == ^session.id)
    |> Ash.Query.sort(sequence: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read!(authorize?: false)
    |> case do
      [exec] ->
        %{
          output: exec.output,
          exit_code: exec.exit_code,
          status: exec.status,
          sequence: exec.sequence
        }

      [] ->
        nil
    end
  rescue
    _ -> nil
  end

  defp iteration_error?(%{event_type: "iteration.completed", data: data}) do
    status = Map.get(data, "status") || Map.get(data, :status)
    status in [:error, "error"]
  end

  defp iteration_error?(_), do: false
end
