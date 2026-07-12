defmodule JidoClaw.Orchestration.RunPubSub do
  @moduledoc false

  alias JidoClaw.Orchestration.WorkflowRun

  # The canonical run-lifecycle kind inventory riding `orchestration:run:<id>`
  # / `orchestration:runs` — every producer (reactor_middleware, reactor_runner,
  # cancellation, cases, gate_disposition, route_composer) broadcasts one of
  # these five, and `WorkflowsChannel` sources its allowlist from here so the
  # producer set and the wire allowlist can never drift.
  @lifecycle_kinds [:run_started, :run_completed, :run_failed, :run_cancelled, :run_abandoned]

  @doc """
  The five run-lifecycle event kinds. Composer `route_*` terminals never ride
  the topics as their durable kind — they map onto this family by the status
  they committed (completed/failed/cancelled); the disposition detail lives on
  the run row, refetched by subscribers.
  """
  @spec lifecycle_kinds() :: [atom()]
  def lifecycle_kinds, do: @lifecycle_kinds

  @spec run_topic(term()) :: String.t()
  def run_topic(run_id), do: "orchestration:run:#{run_id}"

  @spec runs_topic() :: String.t()
  def runs_topic, do: "orchestration:runs"

  @spec gates_topic() :: String.t()
  def gates_topic, do: "orchestration:gates"

  @spec subscribe(term()) :: :ok | {:error, term()}
  def subscribe(run_id) do
    Phoenix.PubSub.subscribe(JidoClaw.PubSub, run_topic(run_id))
  end

  @spec subscribe_all() :: :ok | {:error, term()}
  def subscribe_all do
    Phoenix.PubSub.subscribe(JidoClaw.PubSub, runs_topic())
  end

  @spec broadcast(term(), term()) :: :ok | {:error, term()}
  def broadcast(run_id, event) do
    Phoenix.PubSub.broadcast(JidoClaw.PubSub, run_topic(run_id), event)
    Phoenix.PubSub.broadcast(JidoClaw.PubSub, runs_topic(), event)
  end

  @doc """
  The human-gate inbox channel. `{:gate_requested, run_id, info}` is broadcast
  by `ReactorRunner` **after** a run's resume checkpoint persists (so the gate
  is never announced before it can be acted on); `{:gate_resolved, run_id,
  info}` by `Cases.decide/4` after a decision commits.
  """
  @spec subscribe_gates() :: :ok | {:error, term()}
  def subscribe_gates do
    Phoenix.PubSub.subscribe(JidoClaw.PubSub, gates_topic())
  end

  @spec broadcast_gate(term()) :: :ok | {:error, term()}
  def broadcast_gate(event) do
    Phoenix.PubSub.broadcast(JidoClaw.PubSub, gates_topic(), event)
  end

  @doc """
  Broadcast a gate-opened notification on the gates topic — the ONE
  construction site for the `{:gate_requested, run_id, info}` payload (shared
  by `ReactorRunner`'s post-checkpoint announce, `ToolApprovals`' run-less
  open, and the composer's review-stall raise, so the shape can never drift).
  `run_id` is nil for a run-less tool-call case; the review-stall raiser
  passes the composer PARENT's id.
  """
  @spec broadcast_gate_requested(term() | nil, String.t(), Ecto.UUID.t()) ::
          :ok | {:error, term()}
  def broadcast_gate_requested(run_id, tenant_id, agent_case_id) do
    broadcast_gate(
      {:gate_requested, run_id, %{tenant_id: tenant_id, agent_case_id: agent_case_id}}
    )
  end

  @doc """
  Broadcast a gate resolution on the gates topic — the ONE construction site for
  the `{:gate_resolved, run_id, info}` payload (shared by `Cases`' operator
  decisions and `GateDisposition`'s deadline abandon, so the shape can never
  drift). `run_id` is nil for a run-less tool-call case.
  """
  @spec broadcast_gate_resolved(term() | nil, String.t(), Ecto.UUID.t(), atom()) ::
          :ok | {:error, term()}
  def broadcast_gate_resolved(run_id, tenant_id, agent_case_id, decision) do
    broadcast_gate(
      {:gate_resolved, run_id,
       %{tenant_id: tenant_id, agent_case_id: agent_case_id, decision: decision}}
    )
  end

  @doc """
  Broadcast a run-lifecycle terminal on the run + runs topics — the ONE
  construction site for the dashboard-refresh payload (shared by
  `Cases.abandon/3`, `Cancellation`, `GateDisposition`, and the composer's
  post-append terminal announce). Pass the RELOADED terminal run (a
  pre-terminal snapshot's `completed_at` is still nil) and the terminal
  `status` explicitly — a degraded reload may hand back a pre-terminal
  snapshot, and the event must still carry the status that durably committed.
  """
  @spec broadcast_run_terminal(WorkflowRun.t(), atom(), atom()) :: :ok | {:error, term()}
  def broadcast_run_terminal(%WorkflowRun{} = run, event_kind, status) do
    broadcast(
      run.id,
      {event_kind, run.id,
       %{
         tenant_id: run.tenant_id,
         name: run.name,
         workflow_type: run.workflow_type,
         status: status,
         completed_at: run.completed_at
       }}
    )
  end

  @doc """
  Broadcast a run-lifecycle start on the run + runs topics — the
  `broadcast_run_terminal/3` construction-site sibling for `{:run_started,
  run_id, info}`. Used by the composer, whose parent never rides
  `ReactorMiddleware` (the reactor-run start announcer): call it only after
  the mint transaction commits, with the reloaded `:running` row.
  """
  @spec broadcast_run_started(WorkflowRun.t()) :: :ok | {:error, term()}
  def broadcast_run_started(%WorkflowRun{} = run) do
    broadcast(
      run.id,
      {:run_started, run.id,
       %{
         tenant_id: run.tenant_id,
         name: run.name,
         workflow_type: run.workflow_type,
         status: :running,
         completed_at: nil
       }}
    )
  end
end
