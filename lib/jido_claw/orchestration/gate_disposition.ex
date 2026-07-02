defmodule JidoClaw.Orchestration.GateDisposition do
  @moduledoc """
  The single transaction-fenced writer for DISPOSING a parked gate's child-run +
  `AgentCase` aggregate outside an operator decision.

  A parked gate's pending `AgentCase` and its child `WorkflowRun` are ONE
  aggregate. The operator surface (`Cases.decide/4`, `Cases.abandon/3`)
  commits the pair under the global **run → case → events**
  lock order (`cases.ex`), so every OTHER writer that terminalizes the same pair
  — the composer's sensitive-park deadline (O-M2), its terminal-parent teardown,
  recovery's dangling-gate and orphaned-park branches — must serialize on the
  SAME fence, or it can deadlock against a live decision (lock-order inversion:
  the case-first `AgentCase` writes take the run lock last, inside the event
  allocator) or silently overwrite one (the `AgentCase` status `change` filters
  are in-memory only in ash_postgres 2.9, never a DB fence).

  The choreography mirrors `Cases`' decision commits: **lock the CHILD RUN row**
  (`FOR UPDATE` — the aggregate's first lock in the global order), **re-check
  the run's status on the locked struct** (still `:awaiting_approval`, i.e.
  genuinely parked), then reload the pending case(s) under the held lock and
  write the case cancellations (+ `:cancelled` timeline events) and the child's
  terminal events — all in one transaction. A concurrent `Cases.decide/4`
  serializes on the same run lock: whichever commits first wins, and the loser
  reads the winner's committed state and backs off cleanly.

  Callers get classified outcomes instead of hand-rolling reload/re-check logic:

    * `{:ok, :disposed}` — the pair is closed (cases cancelled, child terminal).
    * `{:error, {:decided, status}}` — a fenced operator decision (or resume
      outcome) won the race: the locked child is no longer `:awaiting_approval`.
      Nothing was written. A terminal status routes through the caller's
      decided-child path; `{:decided, :running}` specifically means a raced
      APPROVE is resuming the child — a terminal-parent caller (the composer's
      teardown, recovery's janitor) must CONVERGE it (cancel/fail —
      `run_abandoned` is illegal from `:running`), never no-op, or the child
      executes with no live composer to fold its output.
    * `{:error, :not_found}` — the child row could not be read.
    * `{:error, reason}` — a transient failure; the transaction rolled back and
      nothing persisted.
  """

  require Ash.Query, as: Query

  alias JidoClaw.Orchestration.AgentCase
  alias JidoClaw.Orchestration.AgentCaseEvent
  alias JidoClaw.Orchestration.RunPubSub
  alias JidoClaw.Orchestration.WorkflowEvent
  alias JidoClaw.Orchestration.WorkflowEvent.Projection
  alias JidoClaw.Orchestration.WorkflowLog
  alias JidoClaw.Orchestration.WorkflowRun

  @type outcome :: {:ok, :disposed} | {:error, {:decided, atom()} | :not_found | term()}

  @doc """
  Abandon a still-parked child at its sensitive-park deadline (O-M2): cancel the
  pending case(s) with `reason` and append `run_abandoned` (→ `:abandoned`, the
  same terminal an operator abandon produces). On success, broadcast the
  resolution exactly like `Cases.abandon/3` (`{:gate_resolved, …, decision:
  :abandon}` per cancelled case + the run-lifecycle `{:run_abandoned, …}`), so
  operator surfaces refresh identically. A park with NO pending case (the
  recovered case-less edge) still gets its child terminal.
  """
  @spec deadline_abandon_parked_child(Ecto.UUID.t(), String.t(), keyword()) :: outcome()
  def deadline_abandon_parked_child(child_run_id, reason, opts) do
    child_run_id
    |> dispose(fn _locked -> [{:run_abandoned, %{reason: reason}}] end, reason, opts)
    |> broadcast_abandoned(opts)
  end

  @doc """
  Fail a parked child whose gate can never be folded — its composer parent is
  already terminal (the O-M2 TTL-wins residue, `teardown_parked_gate`'s shape,
  recovery's orphaned-park branch): cancel the pending case(s) and append the
  `run_recovered` (provenance, with the locked `prior_status`) + `run_failed`
  audit pair. No broadcasts — the reconciling caller is not an operator surface.
  """
  @spec fail_orphaned_parked_child(Ecto.UUID.t(), String.t(), keyword()) :: outcome()
  def fail_orphaned_parked_child(child_run_id, reason, opts) do
    normalize(dispose(child_run_id, orphan_events(reason), reason, opts))
  end

  @doc """
  Close a dangling gate (recovery: `:awaiting_approval` with NO checkpoint — the
  park never finished establishing, so it can never be decided-and-resumed):
  same fenced choreography and `run_recovered` + `run_failed` audit pair as
  `fail_orphaned_parked_child/3`, named for the distinct intent.
  """
  @spec cancel_dangling_gate(Ecto.UUID.t(), String.t(), keyword()) :: outcome()
  def cancel_dangling_gate(child_run_id, reason, opts) do
    normalize(dispose(child_run_id, orphan_events(reason), reason, opts))
  end

  @doc """
  Classify whether `run`'s parent is a TERMINAL composer — the "nothing can
  ever fold this gate's output" condition shared by the approve refusal
  (`Cases.decide/4`) and the terminal-parent janitors (`WorkflowRecovery`'s
  parked/decision-recorded branches, the composer's teardown).

  Tri-state because the consumers must disagree about uncertainty: recovery /
  janitor callers act only on `:terminal` (an `{:error, _}` read blip must
  never close or resume anything — leave the pair for the next pass), while
  approve refuses on `:terminal` AND fails CLOSED on `{:error, _}` (refusing a
  retriable approve is cheap; resuming a gate nobody can fold is not).

  A nil `parent_run_id` and a non-composer parent are both `:not_terminal`;
  a set-but-unreadable parent ref is `{:error, _}` (uncertain — `by_id`
  surfaces not-found as an error).
  """
  @spec terminal_composer_parent(WorkflowRun.t(), String.t(), term()) ::
          :terminal | :not_terminal | {:error, term()}
  def terminal_composer_parent(%WorkflowRun{parent_run_id: nil}, _tenant, _actor),
    do: :not_terminal

  def terminal_composer_parent(run, tenant, actor) do
    case WorkflowRun.by_id(run.parent_run_id, tenant: tenant, actor: actor) do
      {:ok, %WorkflowRun{workflow_type: "composer", status: status}} ->
        if Projection.terminal_status?(status), do: :terminal, else: :not_terminal

      # A non-composer parent never orphans its gate this way.
      {:ok, %WorkflowRun{}} ->
        :not_terminal

      # FK-set but unreadable — uncertain, never a definite :not_terminal.
      {:ok, nil} ->
        {:error, :parent_missing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize({:ok, {_locked, _cancelled}}), do: {:ok, :disposed}
  defp normalize(error), do: error

  defp orphan_events(reason) do
    fn locked ->
      [
        {:run_recovered, %{reason: reason, prior_status: locked.status}},
        {:run_failed, %{error: reason}}
      ]
    end
  end

  # The fenced core. `events_fun` receives the LOCKED child and returns the
  # `{kind, payload}` list whose final element must fold to a terminal status
  # (clearing the checkpoint per Decision 7). Success returns the cancelled
  # cases so the operator-parity broadcast can name them.
  #
  # Refusals (`:not_found`, `{:decided, status}`) write NOTHING, so they leave
  # the transaction fun as tagged SUCCESS values and are classified after the
  # commit — an in-transaction `{:error, _}` return would be wrapped into an
  # opaque `Ash.Error` by `Ash.transact` (the documented behavior `Cases` works
  # around with pre-transaction guards) and the classification lost. Only a
  # genuine write failure flows out as `{:error, _}`, rolling everything back.
  defp dispose(child_run_id, events_fun, case_reason, opts) do
    tenant = Keyword.fetch!(opts, :tenant)
    actor = Keyword.fetch!(opts, :actor)

    result =
      Ash.transact([WorkflowRun, AgentCase, AgentCaseEvent, WorkflowEvent], fn ->
        dispose_in_txn(child_run_id, events_fun, case_reason, tenant, actor)
      end)

    classify(result)
  end

  defp dispose_in_txn(child_run_id, events_fun, case_reason, tenant, actor) do
    case lock_child(child_run_id, tenant, actor) do
      # The status re-check runs on the fresh, LOCKED struct — never a
      # pre-transaction read. Still parked → dispose.
      {:ok, %WorkflowRun{status: :awaiting_approval} = locked} ->
        write_disposition(locked, events_fun, case_reason, tenant, actor)

      # Anything else means a fenced decision (or the resume it triggered)
      # already moved the child: back off, write nothing.
      {:ok, %WorkflowRun{status: status}} ->
        {:refused, {:decided, status}}

      {:error, :not_found} ->
        {:refused, :not_found}
    end
  end

  # Case cancellations first, then the terminal appends via the shared
  # `WorkflowLog.append_all/3` (each append re-takes the already-held run lock —
  # a same-transaction no-op).
  defp write_disposition(locked, events_fun, case_reason, tenant, actor) do
    with {:ok, cancelled} <- cancel_pending_cases(locked, case_reason, tenant, actor),
         {:ok, _event} <-
           WorkflowLog.append_all(locked, events_fun.(locked), tenant: tenant, actor: actor) do
      {:disposed, locked, cancelled}
    end
  end

  defp classify({:ok, {:disposed, locked, cancelled}}), do: {:ok, {locked, cancelled}}
  defp classify({:ok, {:refused, reason}}), do: {:error, reason}
  defp classify({:error, reason}), do: {:error, reason}

  # The house per-run FOR UPDATE idiom (mirroring `Cases.lock_run/3` /
  # `WorkflowEvent.Changes.Allocate`): the aggregate's FIRST lock, taken before
  # any case read/write so this disposition and a live `Cases.decide/4` (which
  # locks the run first too) strictly serialize instead of deadlocking.
  defp lock_child(child_run_id, tenant, actor) do
    WorkflowRun
    |> Query.filter(id == ^child_run_id)
    |> Query.lock("FOR UPDATE")
    |> Ash.read_one(tenant: tenant, actor: actor)
    |> case do
      {:ok, %WorkflowRun{} = locked} -> {:ok, locked}
      {:ok, nil} -> {:error, :not_found}
      {:error, _reason} -> {:error, :not_found}
    end
  end

  # Pending cases re-read UNDER the held run lock (a raced decider is either
  # already committed — caught by `ensure_still_parked` — or blocked on the run
  # lock behind us), then each cancelled + its `:cancelled` timeline event.
  defp cancel_pending_cases(locked, reason, tenant, actor) do
    with {:ok, cases} <- AgentCase.pending_for_run(locked.id, tenant: tenant, actor: actor) do
      Enum.reduce_while(cases, {:ok, []}, fn agent_case, {:ok, acc} ->
        case cancel_case(agent_case, reason, tenant, actor) do
          {:ok, cancelled} -> {:cont, {:ok, [cancelled | acc]}}
          {:error, error} -> {:halt, {:error, error}}
        end
      end)
    end
  end

  defp cancel_case(agent_case, reason, tenant, actor) do
    with {:ok, cancelled} <-
           AgentCase.cancel(agent_case, %{cancellation_reason: reason},
             tenant: tenant,
             actor: actor
           ),
         {:ok, _case_event} <-
           WorkflowLog.case_event(cancelled, :cancelled, %{reason: reason}, tenant, actor) do
      {:ok, cancelled}
    end
  end

  # Operator-parity broadcasts for the deadline abandon (matching
  # `Cases.abandon/3`): one `{:gate_resolved, …}` per cancelled case, then the
  # run-lifecycle `{:run_abandoned, …}` from the RELOADED terminal run (the
  # locked snapshot predates the terminal flip, so its completed_at is stale).
  # Best-effort — the durable disposition is already committed.
  defp broadcast_abandoned({:ok, {locked, cancelled}}, opts) do
    Enum.each(cancelled, fn agent_case ->
      RunPubSub.broadcast_gate_resolved(locked.id, locked.tenant_id, agent_case.id, :abandon)
    end)

    broadcast_run_abandoned(locked, opts)
    {:ok, :disposed}
  end

  defp broadcast_abandoned(error, _opts), do: error

  defp broadcast_run_abandoned(locked, opts) do
    case WorkflowRun.by_id(locked.id, tenant: opts[:tenant], actor: opts[:actor]) do
      {:ok, abandoned} ->
        RunPubSub.broadcast_run_terminal(abandoned, :run_abandoned, :abandoned)

      {:error, _reason} ->
        :ok
    end
  end
end
