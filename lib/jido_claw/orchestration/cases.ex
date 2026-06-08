defmodule JidoClaw.Orchestration.Cases do
  @moduledoc """
  The single decision point for human approval gates.

  `decide/4` is the one path the code API, the CLI (`/gates`), and the web
  dashboard (`/approvals`) all funnel through, so a decision is recorded
  exactly once. It loads the `AgentCase` + its run, guards that the run carries
  a resume checkpoint (the consumer-side defence of the
  approve-before-checkpoint race), commits the decision in **one transaction**
  (case decision + status event — never split), dispatches the gate's
  best-effort notification hook to an isolated, timed supervised task, and —
  for approve — resumes the persisted reactor.

  ## Approve

  One transaction: `AgentCase.approve` (pending-guarded) + an
  `approval_resolved` event (→ `:running`). After commit: the gate's
  `after_approved/1` hook is dispatched to an isolated, timed supervised task
  (best-effort, logged — Decision 8); the dispatch returns immediately, so a
  slow, hung, or crashing hook can never block or strand the synchronous
  `GateResume.resume/2` that follows and re-runs the reactor's durable
  downstream steps.

  ## Reject

  One transaction: `AgentCase.reject` (pending-guarded) + a `run_cancelled`
  event (→ `:cancelled`, which clears the checkpoint via the projection —
  Decision 7). After commit: `after_rejected/1` is dispatched the same way
  (best-effort, isolated task). No resume, and **no upstream undo** — a gate
  sits before the irreversible write, so reject simply prevents the downstream
  steps; place gates accordingly (Decision 9).

  ## Idempotency / concurrency

  The pending-only `change filter(expr(status == :pending))` fence on the
  decision actions makes a duplicate or concurrent `decide` a clean
  `{:error, _}`: exactly one writer flips the row, and no second status event
  is appended (the whole transaction rolls back on the loser).
  """

  require Logger

  alias JidoClaw.Orchestration.AgentCase
  alias JidoClaw.Orchestration.GateContext
  alias JidoClaw.Orchestration.GateResume
  alias JidoClaw.Orchestration.RunPubSub
  alias JidoClaw.Orchestration.WorkflowEvent
  alias JidoClaw.Orchestration.WorkflowLog
  alias JidoClaw.Orchestration.WorkflowRun

  # Gate hooks run on this supervisor so they are isolated from the decision/
  # resume path (see `dispatch_hook/6`).
  @task_supervisor JidoClaw.TaskSupervisor

  @type decision :: :approve | :reject

  @doc """
  Approve or reject the pending `AgentCase` identified by `case_id`.

  `attrs` are decision metadata forwarded to the `AgentCase` action
  (`:decision_comment`, `:decided_by_id`). `opts` must carry `:tenant` and
  `:actor`. Returns `{:ok, run}` with the run's resulting state on success, or
  `{:error, reason}` — including `:not_yet_resumable` when the checkpoint is not
  yet persisted, and a stale-record error for a non-pending (already-decided)
  case.
  """
  @spec decide(Ecto.UUID.t(), decision(), map(), keyword()) ::
          {:ok, WorkflowRun.t()} | {:error, term()}
  def decide(case_id, decision, attrs \\ %{}, opts \\ [])
      when decision in [:approve, :reject] do
    tenant = Keyword.fetch!(opts, :tenant)
    actor = Keyword.fetch!(opts, :actor)

    with {:ok, agent_case, run} <- load(case_id, tenant, actor),
         :ok <- guard_resumable(run) do
      dispatch(decision, agent_case, run, attrs, tenant, actor)
    end
  end

  # -- Internal --

  defp load(case_id, tenant, actor) do
    with {:ok, %AgentCase{} = agent_case} <-
           AgentCase.by_id(case_id, tenant: tenant, actor: actor),
         {:ok, %WorkflowRun{} = run} <-
           WorkflowRun.by_id(agent_case.workflow_run_id, tenant: tenant, actor: actor) do
      {:ok, agent_case, run}
    else
      {:ok, nil} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  # Consumer-side defence of the approve-before-checkpoint race: the runner
  # only broadcasts the gate after persisting the checkpoint, but a decision
  # arriving before that is rejected here rather than resuming an unwritable run.
  defp guard_resumable(%WorkflowRun{resume_checkpoint: nil}), do: {:error, :not_yet_resumable}
  defp guard_resumable(%WorkflowRun{}), do: :ok

  defp dispatch(:approve, agent_case, run, attrs, tenant, actor) do
    with {:ok, gate} <- commit_approve(agent_case, run, attrs, tenant, actor) do
      # `run` is the decision-time snapshot — fine for the best-effort hook and
      # the id-only broadcast; the authoritative post-resume run is returned by
      # GateResume (which reloads internally).
      dispatch_hook(gate, :after_approved, run, :approve, tenant, actor)
      broadcast_resolved(run, gate, :approve)
      finalize_approve(run, tenant, actor)
    end
  end

  defp dispatch(:reject, agent_case, run, attrs, tenant, actor) do
    with {:ok, gate} <- commit_reject(agent_case, run, attrs, tenant, actor),
         {:ok, cancelled_run} <- WorkflowRun.by_id(run.id, tenant: tenant, actor: actor) do
      dispatch_hook(gate, :after_rejected, run, :reject, tenant, actor)
      broadcast_resolved(run, gate, :reject)
      {:ok, cancelled_run}
    end
  end

  # P1: case decision and the status event commit together or not at all. The
  # `with` returns the bare gate on success (transact wraps `{:ok, _}`); any
  # `{:error, _}` (incl. the pending-guard stale-record loss) rolls back.
  defp commit_approve(agent_case, run, attrs, tenant, actor) do
    Ash.transact([AgentCase, WorkflowEvent], fn ->
      with {:ok, gate} <- AgentCase.approve(agent_case, attrs, tenant: tenant, actor: actor),
           {:ok, _event} <-
             WorkflowLog.append(
               run,
               :approval_resolved,
               %{agent_case_id: gate.id, decision: :approve},
               tenant: tenant,
               actor: actor
             ) do
        gate
      end
    end)
  end

  defp commit_reject(agent_case, run, attrs, tenant, actor) do
    reason = Map.get(attrs, :decision_comment) || "rejected by operator"

    Ash.transact([AgentCase, WorkflowEvent], fn ->
      with {:ok, gate} <- AgentCase.reject(agent_case, attrs, tenant: tenant, actor: actor),
           {:ok, _event} <-
             WorkflowLog.append(run, :run_cancelled, %{agent_case_id: gate.id, reason: reason},
               tenant: tenant,
               actor: actor
             ) do
        gate
      end
    end)
  end

  defp finalize_approve(run, tenant, actor) do
    case GateResume.resume(run, tenant: tenant, actor: actor) do
      {:ok, _value, resumed_run} -> {:ok, resumed_run}
      {:error, reason, _run} -> {:error, reason}
    end
  end

  # Best-effort notification (Decision 8), dispatched off the decision/resume
  # critical path: the hook runs on an isolated supervised task, so a hung,
  # throwing, exiting, or raising hook can never block `decide` or strand the
  # downstream resume. The decision has already committed; the hook's outcome is
  # only ever logged. `start_child/2` returns instantly, so the caller never
  # waits on the hook — even spawn failures are logged and swallowed.
  defp dispatch_hook(%AgentCase{gate_module: nil}, _fun, _run, _decision, _tenant, _actor),
    do: :ok

  defp dispatch_hook(agent_case, fun, run, decision, tenant, actor) do
    case Task.Supervisor.start_child(@task_supervisor, fn ->
           bounded_hook(agent_case, fun, run, decision, tenant, actor)
         end) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        Logger.warning("[Cases] #{fun} hook failed to spawn: #{inspect(reason)}")
        :ok
    end
  end

  # Runs the user hook under a monitored, timed sub-task. `async_nolink` +
  # `Task.yield`/`shutdown` captures raise, `throw`, and `exit` (all surface as
  # `{:exit, reason}`) and a hang (→ `nil` after the timeout) uniformly — the
  # failure modes a bare `rescue` would miss.
  defp bounded_hook(agent_case, fun, run, decision, tenant, actor) do
    %{gate_module: mod} = agent_case

    ctx = %GateContext{
      run: run,
      agent_case: agent_case,
      decision: decision,
      tenant: tenant,
      actor: actor
    }

    task = Task.Supervisor.async_nolink(@task_supervisor, fn -> apply(mod, fun, [ctx]) end)

    case Task.yield(task, hook_timeout()) || Task.shutdown(task) do
      {:ok, :ok} -> :ok
      {:ok, {:error, reason}} -> Logger.warning("[Cases] #{fun} hook errored: #{inspect(reason)}")
      {:ok, other} -> Logger.warning("[Cases] #{fun} hook returned #{inspect(other)}")
      {:exit, reason} -> Logger.warning("[Cases] #{fun} hook crashed: #{inspect(reason)}")
      nil -> Logger.warning("[Cases] #{fun} hook timed out")
    end
  end

  # Resolved at call time so tests can shrink it (a hung hook then leaves a
  # short-lived task, not a 30s one).
  defp hook_timeout, do: Application.get_env(:jido_claw, :gate_hook_timeout, 30_000)

  defp broadcast_resolved(run, gate, decision) do
    RunPubSub.broadcast_gate(
      {:gate_resolved, run.id,
       %{tenant_id: run.tenant_id, agent_case_id: gate.id, decision: decision}}
    )
  end
end
