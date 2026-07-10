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
  `approval_resolved` event (→ `:running`) + a rotated live resume lease + the
  case's `:approved` timeline event. After commit: the gate's `after_approved/1` hook is dispatched to an
  isolated, timed supervised task (best-effort, logged — Decision 8); the
  dispatch returns immediately, so a slow, hung, or crashing hook can never
  block or strand the synchronous `GateResume.resume/2` that follows and
  re-runs the reactor's durable downstream steps. Pass `resume: false` to
  commit the decision **without** resuming — the seam tests and the future
  plan-gate producer's approve-then-batch-resume flow use; the run stays
  `:running` with its checkpoint and an expiring, reclaimable resume claim until
  something resumes it.

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
  `:abandoned` (clearing the checkpoint). After commit the run-lifecycle
  terminal `{:run_abandoned, …}` is broadcast on the runs topic (dashboard
  refresh) alongside the gates-topic `{:gate_resolved, …}`. Abandoning a
  `:running` run is refused — the projection's transition guard rolls the
  whole transaction back. In-flight runs are stopped by
  `JidoClaw.Orchestration.Cancellation.cancel/2`, which kills the live
  executor and delegates *parked* runs here. Distinct from reject (a decision
  about the gate) and from recovery's cancel (crash-reaped).

  ## Idempotency / concurrency

  Every decision commit reloads the `AgentCase` row `FOR UPDATE` inside its
  transaction and re-checks the status on that fresh, locked struct before
  deciding on it (`lock_case/3` + `ensure_case_pending/1` — the house
  reload-and-recheck idiom, mirroring `lock_run/3`). That is the fence: a
  duplicate or concurrent `decide` blocks on the row lock, reads the winner's
  committed status, and rolls back `{:error, :not_pending}`, so exactly one
  writer flips the row and no second status event is appended. The
  `change filter(expr(status == :pending))` on the `AgentCase` decision actions
  is an **in-memory precondition** (defence-in-depth, and the cheap masking of
  a sequential duplicate), NOT a DB-side `WHERE` for record updates in
  ash_postgres 2.9 — so on its own it cannot fence a concurrent stale-loaded
  decider. Workflow commits take the run lock first, so the global lock order
  is run -> case -> (events).

  ## Tool-call cases (run-less)

  `decide/4` also resolves conversation-axis tool-call cases
  (`workflow_run_id == nil`, opened by `JidoClaw.Orchestration.ToolApprovals`).
  Those have no checkpoint and no reactor: `load/3` returns a `nil` run,
  `decide/4` skips `guard_resumable`, flips the case + appends its `:approved`/
  `:rejected` timeline event in **one transaction** (no `WorkflowEvent` — there
  is no run), fires the gate's best-effort hook with a `%GateContext{run: nil}`,
  broadcasts `{:gate_resolved, nil, …}`, and returns `{:ok, %AgentCase{}}` (the
  decided case, not a run — callers branch on the struct). `abandon/3` is
  workflow-only and refuses a tool-call case with
  `{:error, :not_workflow_case}` (there is no run to abandon).

  ## Needs-input cases (item 7 PR-4 — kind-dispatched, run-bound OR run-less)

  A `:needs_input` case (opened by `JidoClaw.Orchestration.NeedsInput`) is
  dispatched on its KIND before the run-less shape branch — it may carry
  `workflow_run_id: nil`, and the tool-call catch-all would otherwise eat it
  and bypass the answer guard. Approve requires a non-blank
  `decision_comment` (the comment IS the answer, claimed single-use by the
  stage's next attempt) — a blank one is refused `{:error, :answer_required}`.
  The commit reuses the run-less tool-call path (flip + timeline event, no
  `WorkflowEvent`, no resume, no run terminal — a run-bound case is
  provenance only; its run already errored the step). `abandon/3` refuses the
  kind outright (`{:error, :not_abandonable}` — reject instead), checked
  BEFORE the workflow-case guard.

  ## Review-stall cases (run-bound, parent stays `:running` — camus C1-4)

  A `:review_stall` case is run-bound to a composer PARENT that stays
  `:running` (no checkpoint, no `approval_requested` — the pending case row is
  the composer's durable stall park). `decide/4` dispatches on the kind BEFORE
  `guard_resumable` (there is nothing to resume): approve additionally
  requires **waive completeness** — `attrs[:waive_records]` (`[%{key,
  severity, note}]`) must cover every key in the case's
  `details["finding_keys"]`, else the decision is refused loudly with
  `{:error, :incomplete_waiver}` (never auto-converted to reject). The commit
  is `lock_run` (global run → case order) + `lock_case` +
  `ensure_case_pending` + the case flip + the `:approved`/`:rejected` timeline
  event carrying the waive records (the BO2-6 debt-ledger rows) — **no
  `WorkflowEvent` in either arm** (`approval_resolved` is only legal from
  `:awaiting_approval`); the COMPOSER is the single status-authority writer
  (approve → `:route_done_with_findings`, reject → `:route_fix_failed`).
  Post-commit the resolution broadcasts with the PARENT's id, which wakes the
  parked composer. Returns `{:ok, %AgentCase{}}` — run-terminal assertions
  are ASYNC (await the composer's wake/recovery), never read off this return.
  `abandon/3` gains the same kind dispatch: flip + timeline event + broadcast,
  **skipping** `run_abandoned` (illegal from `:running`) and
  `broadcast_run_terminal`; it too returns `{:ok, %AgentCase{}}` — the
  composer appends `:route_abandoned` itself.
  """

  require Ash.Query, as: Query
  require Logger

  alias JidoClaw.Orchestration.AgentCase
  alias JidoClaw.Orchestration.AgentCaseEvent
  alias JidoClaw.Orchestration.GateContext
  alias JidoClaw.Orchestration.GateDisposition
  alias JidoClaw.Orchestration.GateResume
  alias JidoClaw.Orchestration.RunPubSub
  alias JidoClaw.Orchestration.WorkflowEvent
  alias JidoClaw.Orchestration.WorkflowLease
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
  checkpoint is not yet persisted, `:not_pending` when the case has already
  been decided (the duplicate/concurrent loser, fenced by the in-transaction
  `FOR UPDATE` reload-and-recheck), `:parent_terminal` when an **approve**
  targets a gate whose composer parent already ended (nothing can ever fold
  the resumed child's output — reject/abandon stay allowed, they converge the
  pair), and `:parent_state_unknown` when the parent's state could not be read
  (approve fails closed — retry).

  Tool-call and review-stall cases return `{:ok, %AgentCase{}}` (the decided
  case, never a run) — callers branch on the struct. A review-stall approve
  additionally requires `attrs[:waive_records]` to cover every key in the
  case's `details["finding_keys"]`, else `{:error, :incomplete_waiver}`; the
  run reaches its terminal ASYNCHRONOUSLY when the parked composer wakes, so
  never read run state off this return.
  """
  @spec decide(Ecto.UUID.t(), decision(), map(), keyword()) ::
          {:ok, WorkflowRun.t() | AgentCase.t()} | {:error, term()}
  def decide(case_id, decision, attrs \\ %{}, opts \\ [])
      when decision in [:approve, :reject] do
    tenant = Keyword.fetch!(opts, :tenant)
    actor = Keyword.fetch!(opts, :actor)
    resume? = Keyword.get(opts, :resume, true)

    with {:ok, agent_case, run} <- load(case_id, tenant, actor) do
      decide_loaded(decision, agent_case, run, attrs, tenant, actor, resume?)
    end
  end

  # Needs-input case (item 7 PR-4): kind-dispatched FIRST — BEFORE the
  # run-less shape-dispatch below, which would otherwise eat a run-LESS
  # needs-input case (`workflow_run_id: nil`) and bypass the answer guard.
  # The kind is the discriminator; run nil-ness is not. Approve requires a
  # non-blank `decision_comment` (it IS the answer — approving blank would
  # be approved-then-consumed-empty); the commit reuses the run-less
  # tool-call path: flip + timeline event, no WorkflowEvent (run-bound cases
  # are provenance-only — the run already errored its step), no resume, no
  # run terminal.
  defp decide_loaded(
         decision,
         %AgentCase{kind: :needs_input} = agent_case,
         _run,
         attrs,
         tenant,
         actor,
         _resume?
       ) do
    with :ok <- ensure_answer(decision, attrs) do
      decide_tool_call(decision, agent_case, attrs, tenant, actor)
    end
  end

  # Run-less tool-call case: no checkpoint to guard, no reactor to resume.
  defp decide_loaded(decision, agent_case, nil, attrs, tenant, actor, _resume?) do
    decide_tool_call(decision, agent_case, attrs, tenant, actor)
  end

  # Review-stall case (camus C1-4): run present but the composer PARENT stays
  # `:running` with no checkpoint — dispatched BEFORE `guard_resumable`, which
  # would refuse it as `:not_yet_resumable` forever.
  defp decide_loaded(
         decision,
         %AgentCase{kind: :review_stall} = agent_case,
         run,
         attrs,
         tenant,
         actor,
         _resume?
       ) do
    decide_review_stall(decision, agent_case, run, attrs, tenant, actor)
  end

  defp decide_loaded(decision, agent_case, run, attrs, tenant, actor, resume?) do
    with :ok <- guard_resumable(run) do
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

  A `:review_stall` case takes the kind-dispatched branch instead: flip THAT
  case + its `:abandoned` timeline event + the resolution broadcast, with NO
  `run_abandoned` append (illegal from `:running` — the parked composer
  appends its own `:route_abandoned` on wake) and no run-terminal broadcast.
  That branch returns `{:ok, %AgentCase{}}` (the abandoned case, not a run) —
  callers branch on the struct, like `decide/4`'s run-less shape.

  A `:needs_input` case is refused outright with `{:error, :not_abandonable}`
  — reject it instead: there is no parked run behind it (the step already
  errored), and the kind is checked BEFORE the workflow-case guard because a
  run-less needs-input case would otherwise read as `:not_workflow_case`.
  """
  @spec abandon(Ecto.UUID.t(), map(), keyword()) ::
          {:ok, WorkflowRun.t() | AgentCase.t()} | {:error, term()}
  def abandon(case_id, attrs \\ %{}, opts \\ []) do
    tenant = Keyword.fetch!(opts, :tenant)
    actor = Keyword.fetch!(opts, :actor)

    with {:ok, agent_case, run} <- load(case_id, tenant, actor),
         # Needs-input cases are never abandonable — kind-dispatched BEFORE
         # the workflow-case guard (a run-less needs-input case would
         # otherwise be masked as :not_workflow_case, and a run-bound one
         # would wrongly reach the run-abandon path).
         :ok <- refuse_needs_input_abandon(agent_case),
         # Tool-call cases have no run to abandon — refuse deterministically.
         :ok <- ensure_workflow_case(run),
         # Pre-transaction guard for the deterministic refusal (clean atom —
         # Ash.transact wraps in-transaction errors); the in-transaction
         # pending fence below stays as the race guard.
         :ok <- ensure_case_pending(agent_case) do
      abandon_loaded(agent_case, run, attrs, tenant, actor)
    end
  end

  defp refuse_needs_input_abandon(%AgentCase{kind: :needs_input}),
    do: {:error, :not_abandonable}

  defp refuse_needs_input_abandon(%AgentCase{}), do: :ok

  # A needs-input approve's `decision_comment` IS the payload — a blank or
  # missing answer must be refused (never approved-then-consumed-empty), the
  # `{:error, :incomplete_waiver}` precedent. Reject needs no comment.
  defp ensure_answer(:reject, _attrs), do: :ok

  defp ensure_answer(:approve, attrs) do
    comment = attrs[:decision_comment]

    if is_binary(comment) and String.trim(comment) != "" do
      :ok
    else
      {:error, :answer_required}
    end
  end

  # Review-stall abandon (camus C1-4): flip the case + timeline event +
  # broadcast only — the run stays `:running` for the composer to terminalize
  # (`run_abandoned` is only legal from `:awaiting_approval`).
  defp abandon_loaded(%AgentCase{kind: :review_stall} = agent_case, run, attrs, tenant, actor) do
    with {:ok, gate} <- commit_review_stall_abandon(agent_case, run, attrs, tenant, actor) do
      broadcast_resolved(run, gate, :abandon)
      {:ok, gate}
    end
  end

  defp abandon_loaded(agent_case, run, attrs, tenant, actor) do
    with {:ok, gate} <- commit_abandon(agent_case, run, attrs, tenant, actor),
         {:ok, abandoned_run} <- WorkflowRun.by_id(run.id, tenant: tenant, actor: actor) do
      broadcast_resolved(run, gate, :abandon)

      # Run-lifecycle terminal on the runs topic (the dashboard refresh),
      # alongside the gates-topic resolution above. Payload from the RELOADED
      # run — the decision-time snapshot predates the terminal flip, so its
      # completed_at is still nil.
      RunPubSub.broadcast_run_terminal(abandoned_run, :run_abandoned, :abandoned)

      {:ok, abandoned_run}
    end
  end

  @doc """
  The BO2-6 deferred-findings debt ledger: every approved `:review_stall`
  case (newest decision first) joined with the waive records its `:approved`
  timeline event carries, plus the per-tenant severity rollup.

  Returns `{:ok, %{cases: [row], severity_counts: %{severity => count},
  total_waived: n}}` — each row `%{case_id, workflow_run_id, step_name,
  decided_at, decided_by_id, decision_comment, waive_records}`. A case whose
  timeline read fails contributes `waive_records: []` with
  `waive_records_available: false` (honest degradation, never a silent
  empty). No new table — the records live on `AgentCaseEvent.data`.
  """
  @spec waived_findings_ledger(String.t(), term()) :: {:ok, map()} | {:error, term()}
  def waived_findings_ledger(tenant, actor) do
    with {:ok, cases} <- AgentCase.approved_review_stalls(tenant: tenant, actor: actor) do
      rows = Enum.map(cases, &ledger_row(&1, tenant, actor))
      waived = Enum.flat_map(rows, & &1.waive_records)

      {:ok,
       %{
         cases: rows,
         severity_counts: Enum.frequencies_by(waived, &(&1["severity"] || "unknown")),
         total_waived: length(waived)
       }}
    end
  end

  defp ledger_row(agent_case, tenant, actor) do
    base = %{
      case_id: agent_case.id,
      workflow_run_id: agent_case.workflow_run_id,
      step_name: agent_case.step_name,
      decided_at: agent_case.decided_at,
      decided_by_id: agent_case.decided_by_id,
      decision_comment: agent_case.decision_comment
    }

    case AgentCaseEvent.for_case(agent_case.id, tenant: tenant, actor: actor) do
      {:ok, events} ->
        Map.put(base, :waive_records, approved_waive_records(events))

      {:error, _reason} ->
        base
        |> Map.put(:waive_records, [])
        |> Map.put(:waive_records_available, false)
    end
  end

  defp approved_waive_records(events) do
    Enum.find_value(events, [], fn
      %AgentCaseEvent{type: :approved, data: %{"waive_records" => records}}
      when is_list(records) ->
        Enum.filter(records, &is_map/1)

      _event ->
        nil
    end)
  end

  # -- Internal --

  defp load(case_id, tenant, actor) do
    case AgentCase.by_id(case_id, tenant: tenant, actor: actor) do
      {:ok, %AgentCase{} = agent_case} -> load_run(agent_case, tenant, actor)
      {:ok, nil} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  # Tool-call cases carry no run — the run-less branch loads `nil`. The workflow
  # path unconditionally loads the run (a missing run is `:not_found`).
  defp load_run(%AgentCase{workflow_run_id: nil} = agent_case, _tenant, _actor) do
    {:ok, agent_case, nil}
  end

  defp load_run(%AgentCase{} = agent_case, tenant, actor) do
    case WorkflowRun.by_id(agent_case.workflow_run_id, tenant: tenant, actor: actor) do
      {:ok, %WorkflowRun{} = run} -> {:ok, agent_case, run}
      {:ok, nil} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_workflow_case(%WorkflowRun{}), do: :ok
  defp ensure_workflow_case(nil), do: {:error, :not_workflow_case}

  # Consumer-side defence of the approve-before-checkpoint race: the runner
  # only broadcasts the gate after persisting the checkpoint, but a decision
  # arriving before that is rejected here rather than resuming an unwritable
  # run. Presence is the ENCRYPTED column — the `resume_checkpoint`
  # calculation is `%Ash.NotLoaded{}` on a plain read and would never match.
  defp guard_resumable(%WorkflowRun{encrypted_resume_checkpoint: nil}),
    do: {:error, :not_yet_resumable}

  defp guard_resumable(%WorkflowRun{}), do: :ok

  # APPROVE ONLY: a gate child under a TERMINAL composer parent must not be
  # approved — approve synchronously resumes the child's side-effectful steps,
  # and with the route already ended nothing can ever fold its output
  # (`fold_resumed_gate` stops clean at `:parent_terminal`). Reject/abandon
  # deliberately stay allowed: they converge the pair, which the composer's
  # teardown and recovery's janitor want. Pre-transaction (like the abandon
  # guard above — an in-transaction `{:error, atom}` is wrapped opaque by
  # `Ash.transact`) and UNLOCKED — no path co-locks parent + child today, so
  # the residual approve-vs-parent-terminal race is converged downstream
  # (`teardown_parked_gate`'s raced-child cancel; recovery's
  # `:orphaned_terminal_parent` branches). Fail CLOSED on uncertain parent
  # state: refusing a retriable approve is cheap; resuming a gate nobody can
  # fold is not.
  defp refuse_orphaned_by_terminal_parent(run, tenant, actor) do
    case GateDisposition.terminal_composer_parent(run, tenant, actor) do
      :not_terminal -> :ok
      :terminal -> {:error, :parent_terminal}
      {:error, _reason} -> {:error, :parent_state_unknown}
    end
  end

  defp dispatch(:approve, agent_case, run, attrs, tenant, actor, resume?) do
    with :ok <- refuse_orphaned_by_terminal_parent(run, tenant, actor),
         {:ok, {gate, resume_token}} <-
           commit_approve(agent_case, run, attrs, tenant, actor) do
      # `run` is the decision-time snapshot — fine for the best-effort hook and
      # the id-only broadcast; the authoritative post-resume run is returned by
      # GateResume (which reloads internally).
      dispatch_hook(gate, :after_approved, run, :approve, tenant, actor)
      broadcast_resolved(run, gate, :approve)

      if resume? do
        finalize_approve(run, resume_token, tenant, actor)
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

  # The run-less decision: flip the case + append its timeline event in one
  # transaction (no `WorkflowEvent` — there is no run), fire the gate's
  # best-effort hook with a run-less `%GateContext{run: nil}`, broadcast the
  # resolution, and return the decided `AgentCase`. The `:approve` path does
  # NOT resume anything — the agent re-issues the identical tool call, which
  # `ToolApprovals.request/3` matches to the now-approved case and consumes.
  defp decide_tool_call(decision, agent_case, attrs, tenant, actor) do
    # Pre-transaction early-out: a run-less case has no `guard_resumable` (which
    # masks a duplicate decide on the workflow path post-resume), so guard the
    # loaded status explicitly — the same pre-transaction guard `abandon/3`
    # uses. This is cheap masking of a SEQUENTIAL duplicate only; it is NOT the
    # concurrency fence (a stale-loaded racer passes this check). The real fence
    # is the `FOR UPDATE` reload-and-recheck inside `commit_tool_call_decision`.
    with :ok <- ensure_case_pending(agent_case),
         {:ok, gate} <- commit_tool_call_decision(decision, agent_case, attrs, tenant, actor) do
      dispatch_hook(gate, hook_for(decision), nil, decision, tenant, actor)
      broadcast_resolved_runless(gate, decision)
      {:ok, gate}
    end
  end

  # Run-less, so case lock only (no run to serialize on) — consistent with the
  # producer, which also locks `agent_cases` first. The `FOR UPDATE` reload +
  # `ensure_case_pending` on the locked struct is the fence: a concurrent
  # decider that loaded the same `:pending` struct blocks here, reads the
  # winner's status, and rolls back `{:error, :not_pending}`.
  defp commit_tool_call_decision(:approve, agent_case, attrs, tenant, actor) do
    Ash.transact([AgentCase, AgentCaseEvent], fn ->
      with {:ok, locked} <- lock_case(agent_case.id, tenant, actor),
           :ok <- ensure_case_pending(locked),
           {:ok, gate} <- AgentCase.approve(locked, attrs, tenant: tenant, actor: actor),
           {:ok, _case_event} <-
             WorkflowLog.case_event(gate, :approved, decision_data(gate), tenant, actor) do
        gate
      end
    end)
  end

  defp commit_tool_call_decision(:reject, agent_case, attrs, tenant, actor) do
    Ash.transact([AgentCase, AgentCaseEvent], fn ->
      with {:ok, locked} <- lock_case(agent_case.id, tenant, actor),
           :ok <- ensure_case_pending(locked),
           {:ok, gate} <- AgentCase.reject(locked, attrs, tenant: tenant, actor: actor),
           {:ok, _case_event} <-
             WorkflowLog.case_event(gate, :rejected, decision_data(gate), tenant, actor) do
        gate
      end
    end)
  end

  defp hook_for(:approve), do: :after_approved
  defp hook_for(:reject), do: :after_rejected

  # -- Review-stall decisions (camus C1-4) --

  # The kind-dispatched decision: waive completeness is validated
  # PRE-transaction on the loaded case (`details` is immutable after open, so
  # there is no stale-read hazard, and an in-transaction `{:error, atom}`
  # would be wrapped opaque by `Ash.transact` — the `abandon/3` guard
  # precedent). The in-transaction `lock_run` + `lock_case` +
  # `ensure_case_pending` re-check stays the concurrency fence.
  defp decide_review_stall(decision, agent_case, run, attrs, tenant, actor) do
    waive_records = normalize_waive_records(waive_field(attrs, :waive_records))
    case_attrs = Map.take(attrs, [:decision_comment, :decided_by_id])

    with :ok <- ensure_case_pending(agent_case),
         :ok <- ensure_complete_waiver(decision, agent_case, waive_records),
         {:ok, gate} <-
           commit_review_stall_decision(
             decision,
             agent_case,
             run,
             case_attrs,
             waive_records,
             tenant,
             actor
           ) do
      dispatch_hook(gate, hook_for(decision), run, decision, tenant, actor)
      # The PARENT's id — this is what wakes the stall-parked composer.
      broadcast_resolved(run, gate, decision)
      {:ok, gate}
    end
  end

  # Waive records arrive atom-keyed (REPL) or string-keyed (web params);
  # normalize to the string-keyed jsonb shape the timeline event stores and
  # the ledger reads. Non-map entries collapse to `%{}` (no key ⇒ they can
  # never satisfy completeness).
  defp normalize_waive_records(records) when is_list(records) do
    Enum.map(records, fn
      record when is_map(record) ->
        %{
          "key" => waive_field(record, :key),
          "severity" => waive_field(record, :severity),
          "note" => waive_field(record, :note)
        }

      _other ->
        %{}
    end)
  end

  defp normalize_waive_records(_records), do: []

  defp waive_field(record, key) do
    case Map.get(record, key) do
      nil -> Map.get(record, Atom.to_string(key))
      value -> value
    end
  end

  # Approve is all-or-reject (orca OQ-1 as decided): every key in the case's
  # `details["finding_keys"]` must be covered by a waive record — anything
  # less is refused loudly, never auto-converted to a reject. Reject needs no
  # waives.
  defp ensure_complete_waiver(:reject, _agent_case, _waive_records), do: :ok

  defp ensure_complete_waiver(:approve, agent_case, waive_records) do
    required = required_finding_keys(agent_case)

    provided =
      waive_records
      |> Enum.map(& &1["key"])
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    if Enum.all?(required, &MapSet.member?(provided, &1)) do
      :ok
    else
      {:error, :incomplete_waiver}
    end
  end

  defp required_finding_keys(%AgentCase{details: %{"finding_keys" => keys}}) when is_list(keys),
    do: Enum.filter(keys, &is_binary/1)

  defp required_finding_keys(%AgentCase{}), do: []

  # One transaction, the tool-call commit shape PLUS the run lock FIRST
  # (global run → case → events order): case flip + the timeline event
  # carrying the waive records (the BO2-6 debt-ledger rows). Deliberately NO
  # `WorkflowEvent` — `approval_resolved` is only legal from
  # `:awaiting_approval`, and the composer parent is `:running`; the composer
  # is the single status-authority writer for the terminal.
  defp commit_review_stall_decision(
         decision,
         agent_case,
         run,
         case_attrs,
         waive_records,
         tenant,
         actor
       ) do
    Ash.transact([AgentCase, AgentCaseEvent], fn ->
      with {:ok, _locked_run} <- lock_run(run.id, tenant, actor),
           {:ok, locked} <- lock_case(agent_case.id, tenant, actor),
           :ok <- ensure_case_pending(locked),
           {:ok, gate} <- review_stall_flip(decision, locked, case_attrs, tenant, actor),
           {:ok, _case_event} <-
             WorkflowLog.case_event(
               gate,
               case_event_type(decision),
               review_stall_decision_data(decision, gate, waive_records),
               tenant,
               actor
             ) do
        gate
      end
    end)
  end

  defp review_stall_flip(:approve, locked, attrs, tenant, actor),
    do: AgentCase.approve(locked, attrs, tenant: tenant, actor: actor)

  defp review_stall_flip(:reject, locked, attrs, tenant, actor),
    do: AgentCase.reject(locked, attrs, tenant: tenant, actor: actor)

  defp case_event_type(:approve), do: :approved
  defp case_event_type(:reject), do: :rejected

  # Approve's timeline event carries the waive records (the debt ledger's
  # source rows); reject's is the plain decision audit.
  defp review_stall_decision_data(:approve, gate, waive_records),
    do: Map.put(decision_data(gate), :waive_records, waive_records)

  defp review_stall_decision_data(:reject, gate, _waive_records), do: decision_data(gate)

  # Review-stall abandon commit: the tool-call shape + the run lock, flipping
  # ONLY the named case (a review-stall parent can have exactly one pending
  # stall case per fingerprint; the fingerprint fence collapses duplicates).
  defp commit_review_stall_abandon(agent_case, run, attrs, tenant, actor) do
    reason = Map.get(attrs, :cancellation_reason) || "abandoned by operator"
    attrs = Map.put(attrs, :cancellation_reason, reason)

    Ash.transact([AgentCase, AgentCaseEvent], fn ->
      with {:ok, _locked_run} <- lock_run(run.id, tenant, actor),
           {:ok, locked} <- lock_case(agent_case.id, tenant, actor),
           :ok <- ensure_case_pending(locked),
           {:ok, gate} <- AgentCase.abandon(locked, attrs, tenant: tenant, actor: actor),
           {:ok, _case_event} <-
             WorkflowLog.case_event(gate, :abandoned, %{reason: reason}, tenant, actor) do
        gate
      end
    end)
  end

  defp broadcast_resolved_runless(gate, decision) do
    RunPubSub.broadcast_gate_resolved(nil, gate.tenant_id, gate.id, decision)
  end

  # P1: case decision, status event, and case timeline event commit together
  # or not at all. The `with` returns the bare gate on success (transact wraps
  # `{:ok, _}`); any `{:error, _}` rolls back. The concurrency fence is the
  # `FOR UPDATE` reload-and-recheck: reload the case row inside the transaction
  # and re-check its status on that fresh, locked struct (`lock_case` +
  # `ensure_case_pending`), then decide on the LOCKED struct — never the
  # pre-transaction `load`. A concurrent decider blocks on the case-row lock,
  # reads the winner's committed status, and rolls back `{:error, :not_pending}`
  # (the `change filter` on the action is in-memory defence-in-depth, NOT the DB
  # fence — see `AgentCase`). Locks are taken in one global order
  # (run -> case -> events): every workflow commit takes the RUN lock first —
  # a commit that took the case-row UPDATE before the run lock would invert
  # that order and open a deadlock window.
  defp commit_approve(agent_case, run, attrs, tenant, actor) do
    resume_token = Ash.UUID.generate()

    Ash.transact([AgentCase, AgentCaseEvent, WorkflowEvent], fn ->
      with {:ok, locked_run} <- lock_run(run.id, tenant, actor),
           {:ok, locked} <- lock_case(agent_case.id, tenant, actor),
           :ok <- ensure_case_pending(locked),
           {:ok, gate} <- AgentCase.approve(locked, attrs, tenant: tenant, actor: actor),
           {:ok, _event} <-
             WorkflowLog.append(
               locked_run,
               :approval_resolved,
               %{agent_case_id: gate.id, decision: :approve},
               tenant: tenant,
               actor: actor
             ),
           :ok <- claim_approved_resume(locked_run, resume_token),
           {:ok, _case_event} <-
             WorkflowLog.case_event(gate, :approved, decision_data(gate), tenant, actor) do
        {gate, resume_token}
      end
    end)
  end

  defp claim_approved_resume(run, resume_token) do
    case WorkflowLease.claim_resume(run.id, resume_token, run.claim_token) do
      {:ok, :claimed} -> :ok
      {:ok, :lost} -> {:error, :resume_claim_lost}
      {:error, reason} -> {:error, {:resume_claim_failed, reason}}
    end
  end

  defp commit_reject(agent_case, run, attrs, tenant, actor) do
    reason = Map.get(attrs, :decision_comment) || "rejected by operator"

    Ash.transact([AgentCase, AgentCaseEvent, WorkflowEvent], fn ->
      with {:ok, _locked_run} <- lock_run(run.id, tenant, actor),
           {:ok, locked} <- lock_case(agent_case.id, tenant, actor),
           :ok <- ensure_case_pending(locked),
           {:ok, gate} <- AgentCase.reject(locked, attrs, tenant: tenant, actor: actor),
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
      with {:ok, _locked_run} <- lock_run(run.id, tenant, actor),
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

  # The same per-run FOR UPDATE the event allocator takes — holding it for the
  # rest of the transaction means a concurrent resume's `run_resumed` append
  # (which must take this lock) serializes strictly before or after this
  # commit, never interleaved.
  defp lock_run(run_id, tenant, actor) do
    WorkflowRun
    |> Query.filter(id == ^run_id)
    |> Query.lock("FOR UPDATE")
    |> Ash.read_one(tenant: tenant, actor: actor)
    |> case do
      {:ok, %WorkflowRun{} = locked} -> {:ok, locked}
      _ -> {:error, :not_found}
    end
  end

  # The decision-race fence (P1): reload the case row `FOR UPDATE` inside the
  # commit transaction so the status re-check runs on a fresh, locked struct —
  # never the pre-transaction `load`. A concurrent decider that loaded the same
  # `:pending` struct blocks here until the winner commits, then reads the
  # winner's status and rolls back at `ensure_case_pending`.
  # The house row-lock idiom, mirroring `lock_run/3` (and `Allocate.lock_case/3`,
  # `ToolApprovals.lock_by_fingerprint/3`).
  defp lock_case(case_id, tenant, actor) do
    AgentCase
    |> Query.filter(id == ^case_id)
    |> Query.lock("FOR UPDATE")
    |> Ash.read_one(tenant: tenant, actor: actor)
    |> case do
      {:ok, %AgentCase{} = locked} -> {:ok, locked}
      _ -> {:error, :not_found}
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

  defp finalize_approve(run, resume_token, tenant, actor) do
    case GateResume.resume(run,
           tenant: tenant,
           actor: actor,
           claim_mode: {:reuse, resume_token}
         ) do
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
    RunPubSub.broadcast_gate_resolved(run.id, run.tenant_id, gate.id, decision)
  end
end
