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
        Ash.create!(JidoClaw.Forge.Resources.Session, %{
          name: session_id,
          runner_type: to_string(Map.get(spec, :runner, :shell)),
          runner_config: Map.get(spec, :runner_config, %{}),
          spec: redact_map(spec),
          started_at: DateTime.utc_now()
        }, action: :start, authorize?: false)
      rescue
        e -> Logger.warning("[Forge.Persistence] Failed to record session: #{inspect(e)}")
      end
    end
  end

  def record_execution_complete(session_id, output, exit_code, sequence) do
    if enabled?() do
      try do
        session = find_session(session_id)
        if session do
          # Two-step flow: create with :start, then update with :complete
          exec_session = Ash.create!(JidoClaw.Forge.Resources.ExecSession, %{
            session_id: session.id,
            sequence: sequence,
            command: "iteration"
          }, authorize?: false)

          result_status = if exit_code == 0, do: :completed, else: :failed

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

  def log_event(session_id, event_type, data \\ %{}) do
    if enabled?() do
      try do
        session = find_session(session_id)
        if session do
          Ash.create!(JidoClaw.Forge.Resources.Event, %{
            session_id: session.id,
            event_type: to_string(event_type),
            data: redact_map(data)
          }, authorize?: false)
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
      pair -> pair
    end)
  end

  defp redact_map(other), do: other

  defp truncate(str, max) when byte_size(str) > max do
    binary_part(str, byte_size(str) - max, max)
  end

  defp truncate(str, _max), do: str
end
