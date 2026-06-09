defmodule JidoClaw.Orchestration.Cases do
  @moduledoc """
  The single decision point for human approval gates.

  `decide/4` is the one path the code API, the CLI (`/gates`), and the web
  dashboard (`/approvals`) all funnel through, so a decision is recorded
  exactly once. It loads the `AgentCase` + its run, guards that the run carries
  a resume checkpoint (the consumer-side defence of the
  approve-before-checkpoint race), commits the decision in **one transaction**
  (case decision + status event + `AgentCaseEvent` timeline row — never
  split), dispatches the gate's best-effort notification hook to an isolated,
  timed supervised task, and — for approve — resumes the persisted reactor.

  ## Approve

  One transaction: `AgentCase.approve` (pending-guarded) + an
  `approval_resolved` event (→ `:running`) + the case's `:approved` timeline
  event. After commit: the gate's `after_approved/1` hook is dispatched to an
  isolated, timed supervised task (best-effort, logged — Decision 8); the
  dispatch returns immediately, so a slow, hung, or crashing hook can never
  block or strand the synchronous `GateResume.resume/2` that follows and
  re-runs the reactor's durable downstream steps. Pass `resume: false` to
  commit the decision **without** resuming — the seam tests and the future
  plan-gate producer's approve-then-batch-resume flow use; the run stays
  `:running` with its checkpoint intact until something resumes it (or the
  approval is retracted).

  ## Reject

  One transaction: `AgentCase.reject` (pending-guarded) + a `run_cancelled`
  event (→ `:cancelled`, which clears the checkpoint via the projection —
  Decision 7) + the case's `:rejected` timeline event. After commit:
  `after_rejected/1` is dispatched the same way (best-effort, isolated task).
  No resume, and **no upstream undo** — a gate sits before the irreversible
  write, so reject simply prevents the downstream steps; place gates
  accordingly (Decision 9).

  ## Abandon (AR-1)

  `abandon/3` is the operator deliberately giving up on a **parked** run —
  legal only from `:awaiting_approval`, the state where nothing is executing
  by construction (the reactor halted at the gate and returned). One
  transaction: every pending case flips to `:abandoned` (+ its `:abandoned`
  timeline event) and a `run_abandoned` event folds the run to the terminal
  `:abandoned` (clearing the checkpoint). Abandoning a `:running` run is
  refused — the projection's transition guard rolls the whole transaction
  back. Widening to in-flight runs is future work gated on lease/cancellation
  semantics (§4.11). Distinct from reject (a decision about the gate) and
  from recovery's cancel (crash-reaped).

  ## Stale-approval retraction (AR-1)

  `retract/3` withdraws a recorded-but-not-yet-acted approval so a revised
  plan must re-earn it: `:running --approval_retracted--> :awaiting_approval`,
  the `AgentCase` flips back to `:pending` with **all decision data cleared**
  (`decision`, `decided_at`, `decision_comment`, `decided_by_id`), and a
  `:retracted` timeline event records it. Race-fenced to the pre-resume
  window: (a) the case flip is DB-fenced on `status == :approved`, and (b)
  inside the same transaction — under the per-run `FOR UPDATE` lock every
  event append takes — the run's log is checked for a `run_resumed` **after**
  the `approval_resolved`; if one exists the reactor is live and retraction is
  refused with `{:error, :already_resumed}`. The live trigger (re-plan
  detection) arrives with the future plan-gate producer; today the window is
  opened deliberately via `decide(..., resume: false)`.

  ## Idempotency / concurrency

  The pending-only `change filter(expr(status == :pending))` fence on the
  decision actions makes a duplicate or concurrent `decide` a clean
  `{:error, _}`: exactly one writer flips the row, and no second status event
  is appended (the whole transaction rolls back on the loser).
  """

  require Ash.Query, as: Query
  require Logger

  alias JidoClaw.Orchestration.AgentCase
  alias JidoClaw.Orchestration.AgentCaseEvent
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
  `:actor`; `resume: false` (approve only) commits the decision without
  resuming the reactor. Returns `{:ok, run}` with the run's resulting state on
  success, or `{:error, reason}` — including `:not_yet_resumable` when the
  checkpoint is not yet persisted, and a stale-record error for a non-pending
  (already-decided) case.
  """
  @spec decide(Ecto.UUID.t(), decision(), map(), keyword()) ::
          {:ok, WorkflowRun.t()} | {:error, term()}
  def decide(case_id, decision, attrs \\ %{}, opts \\ [])
      when decision in [:approve, :reject] do
    tenant = Keyword.fetch!(opts, :tenant)
    actor = Keyword.fetch!(opts, :actor)
    resume? = Keyword.get(opts, :resume, true)

    with {:ok, agent_case, run} <- load(case_id, tenant, actor),
         :ok <- guard_resumable(run) do
      dispatch(decision, agent_case, run, attrs, tenant, actor, resume?)
    end
  end

  @doc """
  Abandon the parked run behind the pending `AgentCase` identified by
  `case_id` — the operator deliberately giving up (AR-1).

  Legal **only** while the run is `:awaiting_approval` (parked at the gate);
  any other state is refused by the projection's transition guard and the
  whole transaction rolls back. Drops **every** pending case for the run.
  `attrs` may carry `:cancellation_reason` and `:decided_by_id`. Returns
  `{:ok, run}` (now `:abandoned`) or `{:error, reason}`.
  """
  @spec abandon(Ecto.UUID.t(), map(), keyword()) ::
          {:ok, WorkflowRun.t()} | {:error, term()}
  def abandon(case_id, attrs \\ %{}, opts \\ []) do
    tenant = Keyword.fetch!(opts, :tenant)
    actor = Keyword.fetch!(opts, :actor)

    with {:ok, agent_case, run} <- load(case_id, tenant, actor),
         # Pre-transaction guard for the deterministic refusal (clean atom —
         # Ash.transact wraps in-transaction errors); the in-transaction
         # pending fence below stays as the race guard.
         :ok <- ensure_case_pending(agent_case),
         {:ok, gate} <- commit_abandon(agent_case, run, attrs, tenant, actor),
         {:ok, abandoned_run} <- WorkflowRun.by_id(run.id, tenant: tenant, actor: actor) do
      broadcast_resolved(run, gate, :abandon)
      {:ok, abandoned_run}
    end
  end

  @doc """
  Retract the recorded-but-not-yet-acted approval on the `AgentCase`
  identified by `case_id` (AR-1 stale-approval retraction).

  Only legal in the pre-resume window: the case must still be `:approved` and
  the run `:running` with **no** `run_resumed` event after the
  `approval_resolved` (checked under the per-run `FOR UPDATE` event lock).
  A reactor already resuming refuses with `{:error, :already_resumed}`. On
  success the run parks back at `:awaiting_approval` (checkpoint intact), the
  case reopens `:pending` with all decision data cleared, and `{:ok, run}` is
  returned.
  """
  @spec retract(Ecto.UUID.t(), map(), keyword()) ::
          {:ok, WorkflowRun.t()} | {:error, term()}
  def retract(case_id, attrs \\ %{}, opts \\ []) do
    tenant = Keyword.fetch!(opts, :tenant)
    actor = Keyword.fetch!(opts, :actor)

    with {:ok, agent_case, run} <- load(case_id, tenant, actor),
         # Pre-transaction guards for the deterministic refusals (clean atoms
         # — Ash.transact wraps in-transaction errors); the same checks
         # re-run inside the transaction under the run lock as the race fence.
         :ok <- ensure_case_approved(agent_case),
         :ok <- ensure_not_resumed(run.id, tenant, actor),
         {:ok, gate} <- commit_retract(agent_case, run, attrs, tenant, actor),
         {:ok, parked_run} <- WorkflowRun.by_id(run.id, tenant: tenant, actor: actor) do
      RunPubSub.broadcast_gate(
        {:gate_requested, run.id, %{tenant_id: run.tenant_id, agent_case_id: gate.id}}
      )

      {:ok, parked_run}
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
  # arriving before that is rejected here rather than resuming an unwritable
  # run. Presence is the ENCRYPTED column — the `resume_checkpoint`
  # calculation is `%Ash.NotLoaded{}` on a plain read and would never match.
  defp guard_resumable(%WorkflowRun{encrypted_resume_checkpoint: nil}),
    do: {:error, :not_yet_resumable}

  defp guard_resumable(%WorkflowRun{}), do: :ok

  defp dispatch(:approve, agent_case, run, attrs, tenant, actor, resume?) do
    with {:ok, gate} <- commit_approve(agent_case, run, attrs, tenant, actor) do
      # `run` is the decision-time snapshot — fine for the best-effort hook and
      # the id-only broadcast; the authoritative post-resume run is returned by
      # GateResume (which reloads internally).
      dispatch_hook(gate, :after_approved, run, :approve, tenant, actor)
      broadcast_resolved(run, gate, :approve)

      if resume? do
        finalize_approve(run, tenant, actor)
      else
        WorkflowRun.by_id(run.id, tenant: tenant, actor: actor)
      end
    end
  end

  defp dispatch(:reject, agent_case, run, attrs, tenant, actor, _resume?) do
    with {:ok, gate} <- commit_reject(agent_case, run, attrs, tenant, actor),
         {:ok, cancelled_run} <- WorkflowRun.by_id(run.id, tenant: tenant, actor: actor) do
      dispatch_hook(gate, :after_rejected, run, :reject, tenant, actor)
      broadcast_resolved(run, gate, :reject)
      {:ok, cancelled_run}
    end
  end

  # P1: case decision, status event, and case timeline event commit together
  # or not at all. The `with` returns the bare gate on success (transact wraps
  # `{:ok, _}`); any `{:error, _}` (incl. the pending-guard stale-record loss)
  # rolls back. Every commit takes the RUN lock first (`lock_run/2`) so all
  # case transactions acquire locks in one global order (run -> case) — the
  # case-row UPDATE before the run-row event lock would otherwise invert
  # `commit_retract`'s order and open a deadlock window.
  defp commit_approve(agent_case, run, attrs, tenant, actor) do
    Ash.transact([AgentCase, AgentCaseEvent, WorkflowEvent], fn ->
      with {:ok, _locked_run} <- lock_run(run.id, tenant),
           {:ok, gate} <- AgentCase.approve(agent_case, attrs, tenant: tenant, actor: actor),
           {:ok, _event} <-
             WorkflowLog.append(
               run,
               :approval_resolved,
               %{agent_case_id: gate.id, decision: :approve},
               tenant: tenant,
               actor: actor
             ),
           {:ok, _case_event} <-
             WorkflowLog.case_event(gate, :approved, decision_data(gate), tenant, actor) do
        gate
      end
    end)
  end

  defp commit_reject(agent_case, run, attrs, tenant, actor) do
    reason = Map.get(attrs, :decision_comment) || "rejected by operator"

    Ash.transact([AgentCase, AgentCaseEvent, WorkflowEvent], fn ->
      with {:ok, _locked_run} <- lock_run(run.id, tenant),
           {:ok, gate} <- AgentCase.reject(agent_case, attrs, tenant: tenant, actor: actor),
           {:ok, _event} <-
             WorkflowLog.append(run, :run_cancelled, %{agent_case_id: gate.id, reason: reason},
               tenant: tenant,
               actor: actor
             ),
           {:ok, _case_event} <-
             WorkflowLog.case_event(gate, :rejected, decision_data(gate), tenant, actor) do
        gate
      end
    end)
  end

  # Abandon every pending case for the run (each + its timeline event), then
  # the run_abandoned terminal — whose transition guard (`:awaiting_approval`
  # only) rolls the WHOLE transaction back for a live run.
  defp commit_abandon(agent_case, run, attrs, tenant, actor) do
    reason = Map.get(attrs, :cancellation_reason) || "abandoned by operator"
    attrs = Map.put(attrs, :cancellation_reason, reason)

    Ash.transact([AgentCase, AgentCaseEvent, WorkflowEvent], fn ->
      with {:ok, _locked_run} <- lock_run(run.id, tenant),
           {:ok, cases} <- AgentCase.pending_for_run(run.id, tenant: tenant, actor: actor),
           :ok <- ensure_pending_present(cases, agent_case),
           {:ok, _} <- abandon_cases(cases, attrs, reason, tenant, actor),
           {:ok, _event} <-
             WorkflowLog.append(
               run,
               :run_abandoned,
               %{agent_case_id: agent_case.id, reason: reason},
               tenant: tenant,
               actor: actor
             ) do
        agent_case
      end
    end)
  end

  # The named case must itself still be pending — a decided case cannot be
  # the handle for abandoning the run.
  defp ensure_pending_present(cases, agent_case) do
    if Enum.any?(cases, &(&1.id == agent_case.id)) do
      :ok
    else
      {:error, :not_pending}
    end
  end

  defp ensure_case_pending(%AgentCase{status: :pending}), do: :ok
  defp ensure_case_pending(%AgentCase{}), do: {:error, :not_pending}

  defp ensure_case_approved(%AgentCase{status: :approved}), do: :ok
  defp ensure_case_approved(%AgentCase{}), do: {:error, :not_approved}

  defp abandon_cases(cases, attrs, reason, tenant, actor) do
    Enum.reduce_while(cases, {:ok, :done}, fn pending_case, _acc ->
      with {:ok, abandoned} <-
             AgentCase.abandon(pending_case, attrs, tenant: tenant, actor: actor),
           {:ok, _case_event} <-
             WorkflowLog.case_event(abandoned, :abandoned, %{reason: reason}, tenant, actor) do
        {:cont, {:ok, :done}}
      else
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  # The retract commit: (1) take the same per-run FOR UPDATE lock every event
  # append takes, serializing against any in-flight resume's `run_resumed`;
  # (2) under that lock, verify no `run_resumed` postdates the
  # `approval_resolved`; (3) reopen the case (DB-fenced on `:approved`,
  # clearing all decision data); (4) append `approval_retracted`
  # (`:running -> :awaiting_approval`); (5) the `:retracted` timeline event.
  defp commit_retract(agent_case, run, attrs, tenant, actor) do
    comment = Map.get(attrs, :decision_comment)

    Ash.transact([AgentCase, AgentCaseEvent, WorkflowEvent], fn ->
      with {:ok, _locked_run} <- lock_run(run.id, tenant),
           :ok <- ensure_not_resumed(run.id, tenant, actor),
           {:ok, gate} <- AgentCase.reopen(agent_case, %{}, tenant: tenant, actor: actor),
           {:ok, _event} <-
             WorkflowLog.append(
               run,
               :approval_retracted,
               %{agent_case_id: gate.id, reason: comment},
               tenant: tenant,
               actor: actor
             ),
           {:ok, _case_event} <-
             WorkflowLog.case_event(gate, :retracted, %{reason: comment}, tenant, actor) do
        gate
      end
    end)
  end

  # The same per-run FOR UPDATE the event allocator takes — holding it for the
  # rest of the transaction means a concurrent resume's `run_resumed` append
  # (which must take this lock) serializes strictly before or after this
  # retraction, never interleaved.
  defp lock_run(run_id, tenant) do
    WorkflowRun
    |> Query.filter(id == ^run_id)
    |> Query.lock("FOR UPDATE")
    |> Ash.read_one(tenant: tenant, authorize?: false)
    |> case do
      {:ok, %WorkflowRun{} = locked} -> {:ok, locked}
      _ -> {:error, :not_found}
    end
  end

  # Under the held lock: a `run_resumed` after the latest `approval_resolved`
  # means the reactor is (or was) live past the decision — refuse.
  defp ensure_not_resumed(run_id, tenant, actor) do
    case WorkflowEvent.for_run(run_id, tenant: tenant, actor: actor) do
      {:ok, events} ->
        resolved_seq =
          events
          |> Enum.filter(&(&1.kind == :approval_resolved))
          |> Enum.map(& &1.seq)
          |> Enum.max(fn -> nil end)

        resumed_after? =
          is_integer(resolved_seq) and
            Enum.any?(events, &(&1.kind == :run_resumed and &1.seq > resolved_seq))

        cond do
          is_nil(resolved_seq) -> {:error, :no_recorded_approval}
          resumed_after? -> {:error, :already_resumed}
          true -> :ok
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Redactor-safe decision audit data for the case timeline.
  defp decision_data(gate) do
    %{
      decision: gate.decision,
      decided_by_id: gate.decided_by_id,
      comment: gate.decision_comment
    }
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
