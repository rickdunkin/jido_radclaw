defmodule JidoClaw.Orchestration.Replay.EventReader do
  @moduledoc """
  Single swappable indirection for the workflow-events read shared by the replay
  irreversible gate (`Replay.check_irreversible/4`) and the preflight
  diagnostics (`Diagnostics.diagnose_irreversible/3`) — single-sourced so the
  two read sites never drift and a test can force a read failure without Mox.

  Defaults to `JidoClaw.Orchestration.WorkflowEvent.for_run/2` (the Ash code
  interface), swappable via `config :jido_claw, :replay_event_reader` — the same
  backend-swap pattern as `:mcp_client` / `:search_web_backend`. Captures the
  existing arity-2 call byte-for-byte: `for_run(run_id, tenant: tenant, actor:
  actor)`.
  """

  alias JidoClaw.Orchestration.WorkflowEvent

  @doc "Read a run's events in seq order via the configured reader."
  @spec for_run(String.t(), keyword()) :: {:ok, [WorkflowEvent.t()]} | {:error, term()}
  def for_run(run_id, opts) do
    reader().(run_id, opts)
  end

  defp reader do
    Application.get_env(:jido_claw, :replay_event_reader, &WorkflowEvent.for_run/2)
  end
end
