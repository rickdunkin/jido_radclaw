# P1 fix — terminal-parent gate orphan: refuse + converge raced approvals

## Context

The post-review remediation work (`.claude/plans/please-review-the-changes-synchronous-cascade.md`, ~41 modified files + new `GateDisposition`) got a follow-up code review with **one P1 finding**, now **validated as real** against the working tree:

> `workflow_recovery.ex:424` treats every `{:decided, status}` from `GateDisposition` as "closed elsewhere." Correct for the deadline path; not safe for terminal-parent cleanup. A raced operator approve returns `{:decided, :running}` with nothing written; `teardown_parked_gate` ignores it. The child resumes under an already-terminal composer parent with no live composer to fold its output.

Validation found the defect is **broader than the cited race** — three doors let a gate child execute under a terminal composer parent:

1. **No-race door** — parent cancellation never closes the *child's* case (`terminate_cancelling_cases` is parent-run-scoped), so after a parent cancel the child gate stays approvable. `Cases.decide(:approve)` (`cases.ex:265`) and `GateResume.resume` never consult the parent; approve synchronously executes the child's side-effectful steps to `:completed`, and nothing can fold it (`fold_resumed_gate`'s `:parent_terminal` arm stops clean, `route_composer.ex:2071`).
2. **Race door** (the review's finding) — `teardown_parked_gate` (`route_composer.ex:1965`) discards the disposition result; recovery's `finish_disposition` (`workflow_recovery.ex:430`) maps `{:decided, :running}` to telemetry-only `:decided_elsewhere`. A child that raced to `:running` is left resuming with no owner.
3. **Re-resume door** — recovery classifies a `:running`+checkpoint child as `:decision_recorded` (`workflow_recovery.ex:271`) and re-resumes it with no parent check — so ReclaimPooler/boot would **re-execute** the orphan, undoing any race handling.

Why both reviewer remedies (not "or"): refusal alone can't close the race (approve can commit between its parent read and the parent-terminal commit — no common lock, and in-txn parent locking would surface wrapped `Ash.Error`s and invert no-lock conventions); caller-handling alone leaves door 1 wide open. Key projection fact: `run_abandoned` is legal only from `:awaiting_approval`; a raced-to-`:running` child must converge via `run_cancelled`/`run_failed` (`projection.ex:129-131`).

**Done-criterion: `mise exec -- mix precommit` succeeds** (whole working tree — the base work's suite state is unverified; the reviewer did not rerun tests).

## Fix (one commit-ready unit)

New symbols: error atoms **`:parent_terminal`** / **`:parent_state_unknown`**, telemetry branch **`:orphaned_terminal_parent`**, tri-state helper **`GateDisposition.terminal_composer_parent/3`**. No migrations, no new modules.

### 1. Shared predicate → `GateDisposition`, as a **tri-state** (`lib/jido_claw/orchestration/gate_disposition.ex`)

A plain boolean can't serve both consumers: recovery must **not act** on uncertainty, but approve must **fail closed** on it (a read blip returning `false` would reopen the no-race door). Replace the recovery defp (`workflow_recovery.ex:442-453`) with a public tri-state:

```elixir
@spec terminal_composer_parent(WorkflowRun.t(), String.t(), term()) ::
        :terminal | :not_terminal | {:error, term()}
def terminal_composer_parent(%WorkflowRun{parent_run_id: nil}, _tenant, _actor), do: :not_terminal

def terminal_composer_parent(run, tenant, actor) do
  case WorkflowRun.by_id(run.parent_run_id, tenant: tenant, actor: actor) do
    {:ok, %WorkflowRun{workflow_type: "composer", status: status}} ->
      if Projection.terminal_status?(status), do: :terminal, else: :not_terminal
    {:ok, %WorkflowRun{}} -> :not_terminal          # non-composer parent
    {:ok, nil} -> {:error, :parent_missing}          # FK-set but unreadable — uncertain
    {:error, reason} -> {:error, reason}             # read blip — uncertain
  end
end
```

- `@doc` states the consumer contract: recovery/janitor acts only on `:terminal` (no-ops on `{:error, _}`); approve refuses on `:terminal` AND fails closed on `{:error, _}`.
- Add `alias JidoClaw.Orchestration.WorkflowEvent.Projection`.
- Moduledoc bullet (lines 29-31): `{:decided, :running}` specifically means a raced approve is resuming — terminal-parent callers must **converge** (cancel/fail), not no-op. (Home chosen over `WorkflowRecovery` to avoid the cycle `Cases → WorkflowRecovery → Cancellation → Cases`; `.reach.exs` layers only constrain web/data — verified green.)

### 2. Seam A — refuse approve at the source (`lib/jido_claw/orchestration/cases.ex`)

- `alias JidoClaw.Orchestration.GateDisposition`.
- In `dispatch(:approve, ...)` (`:265`), prepend a **pre-transaction** guard (in-txn `{:error, atom}` gets wrapped opaque by `Ash.transact` — same idiom as the abandon guard comment at `:174-177`):

```elixir
defp dispatch(:approve, agent_case, run, attrs, tenant, actor, resume?) do
  with :ok <- refuse_orphaned_by_terminal_parent(run, tenant, actor),
       {:ok, gate} <- commit_approve(agent_case, run, attrs, tenant, actor) do
    ...unchanged...
```

```elixir
# Fail CLOSED on uncertain parent state: refusing a retriable approve is cheap;
# resuming a gate nobody can fold is not.
defp refuse_orphaned_by_terminal_parent(run, tenant, actor) do
  case GateDisposition.terminal_composer_parent(run, tenant, actor) do
    :not_terminal -> :ok
    :terminal -> {:error, :parent_terminal}
    {:error, _reason} -> {:error, :parent_state_unknown}
  end
end
```

- **Approve only** — reject/abandon deliberately stay allowed (they converge the pair, which teardown/recovery want). Parent read stays **unlocked** (no path co-locks parent+child today; Seams B/C cover the residual window). Add `:parent_terminal` + `:parent_state_unknown` to `decide/4`'s `@doc` error list (`:125-129`).

### 3. Seam B — teardown converges the raced child (`lib/jido_claw/route_composer/route_composer.ex`)

- `alias JidoClaw.Orchestration.Cancellation` (verified acyclic: `cancellation.ex` never references RouteComposer).
- Rewrite `teardown_parked_gate/1` (`:1965-1973`) to pipe the disposition result through a new helper; still always `{:stop, :normal, state}`:

```elixir
defp teardown_parked_gate(%{parked: park} = state) do
  park.child_run_id
  |> GateDisposition.fail_orphaned_parked_child(
    "composer parent terminal during gate park", auth_opts(state))
  |> converge_raced_teardown(park.child_run_id, state)

  {:stop, :normal, state}
end

defp converge_raced_teardown({:error, {:decided, :running}}, child_run_id, state) do
  case Cancellation.cancel(child_run_id, auth_opts(state)) do
    {:ok, _run} -> :ok
    {:error, :already_terminal} -> :ok   # resume finished on its own — accepted residual
    {:error, reason} -> Logger.warning("[RouteComposer] teardown cancel of raced child #{child_run_id} failed: #{inspect(reason)}")
  end
end

defp converge_raced_teardown(_other, _child_run_id, _state), do: :ok
```

- `Cancellation.cancel/2` is the centralized stop-a-running-run producer: kills the mid-resume executor (incl. cross-node WS5 routing), post-terminal reload races already handled. Rewrite the now-false comment at `:1958-1964` ("`{:decided, _}` means the decision closed the pair itself" → describe the convergence; recovery stays the backstop for cancel failures).
- **Unchanged**: `dispose_park_deadline` (`:2217`, parent alive — `{:decided,_}` → `resolve_parked_gate` is correct), `:parent_fenced` arm, `fold_resumed_gate`'s `:parent_terminal` arm (child already terminal there; dropped output under a cancelled parent is the accepted semantic).

### 4. Seam C + raced clause in recovery (`lib/jido_claw/orchestration/workflow_recovery.ex`)

- Delete the local `orphaned_by_terminal_composer_parent?/3` defp (`:442-453`). Both recovery consumers act **only on `:terminal`** — uncertainty never closes or resumes anything:
  - `reconcile_parked_with_case` (`:411-422`): `case GateDisposition.terminal_composer_parent(run, tenant, actor) do :terminal -> <dispose as today>; _not_terminal_or_error -> emit(run, :parked) end` — today's semantics preserved exactly (stays parked, next boot retries).
  - Keep the `Projection` alias (used elsewhere in the module).
- **Seam C** — in `reconcile_branch(:decision_recorded, run)` (`:331-352`), guard the `{:ok, true}` arm:

```elixir
{:ok, true} ->
  case GateDisposition.terminal_composer_parent(run, tenant, actor) do
    :terminal ->
      fail_stranded(run, :orphaned_terminal_parent)

    :not_terminal ->
      resume_recorded_decision(run)

    {:error, reason} ->
      # Uncertain parent state: neither fail nor resume — log and leave for
      # the next boot/reclaim pass (the branch's existing transient idiom).
      Logger.warning("[WorkflowRecovery] parent lookup failed for run #{run.id}: #{inspect(reason)}")
  end
```

  Disposition is `run_failed` via the existing `fail_stranded/2` writer (`:722`, → `append_recovery`: `run_recovered` + `run_failed`), **not** `Cancellation.cancel`: recovery's stated convention reserves `run_cancelled` for deliberate operator decisions; the non-raced sibling path (`fail_orphaned_parked_child`) already lands `:failed` (test 7f asserts it); no live executor to kill here (boot has none; the reclaim path already `cast_kill`s the prior owner); and it reuses the existing writer instead of adding a second one for the same pair.
- **Raced clause** — insert **before** the `{:decided, _status}` catch-all at `:430`:

```elixir
defp finish_disposition({:error, {:decided, :running}}, run, _branch),
  do: fail_stranded(run, :orphaned_terminal_parent)
```

  (Reachable only from the `:parked` branch — a checkpoint-less `:dangling_gate` child can't be approved past `guard_resumable`; say so in the comment.) Update the `:424-427` comment and the `reconcile_parked_with_case` doc (`:397-410`) to describe the convergence.

### 5. Operator surfacing

- `lib/jido_claw/cli/commands/approvals.ex` `decide/4` (`:55-72`) — two clauses before the catch-all: `{:error, :parent_terminal} →` "The parent route has already ended — this gate can no longer be approved (reject or abandon to close it)."; `{:error, :parent_state_unknown} →` "Could not verify the parent route's state — try again."
- `lib/jido_claw/web/live/approvals_live.ex` `decide/4` (`:204-219`) — matching flash clauses. (Only two production approve doors exist — verified: no MCP approve tool; `tool_call_gate` cases are run-less and never reach `dispatch(:approve, ...)`.)

## Tests

All `use JidoClaw.TenantCase, async: false`.

**`test/jido_claw/orchestration/gate_disposition_test.exs`** (new file from the base work — extend): add `composer_parent(ctx, opts)` (`WorkflowRun.create(%{workflow_type: "composer", ...})` + `run_started` + optional `:route_abandoned` terminal) and `parked_pair_under(parent, ctx)` (existing `parked_pair/1` with `parent_run_id: parent.id`). Two describes:
- `terminal_composer_parent/3` tri-state: `:terminal` under a terminal composer parent; `:not_terminal` for nil parent, a live (`:running`) composer parent, and a non-composer parent; `{:error, :parent_missing}` via an **in-memory struct override** (`%{child | parent_run_id: Ecto.UUID.generate()}` — the helper only reads by that id; the FK `workflow_runs_parent_run_id_fkey` makes a *persisted* dangling ref impossible, so this is the deterministic error-arm seam).
- Seam A: approve → `{:error, :parent_terminal}`, child stays `:awaiting_approval`, case stays `:pending`; then reject on the same pair → `{:ok, _}`, child `:cancelled` (converging decisions still allowed). The `{:error, _} → :parent_state_unknown` fail-closed mapping is covered by the tri-state helper test — end-to-end it's unreachable with real rows (FK), and the mapping itself is a three-clause pattern match.

**`test/jido_claw/route_composer/composer_durable_test.exs`** (reuse `gate_recoverable_parent/1`, `craft_gate_child/3`, `loop_state/3`, `append_event/4`, `kinds/2`, `reload/2`; mirror the crafted-committed-decision pattern of the O-M2 tests at `:1298-1430`):
- **Seam B**: craft parent + parked child; commit the raced approve durably (`AgentCase.approve` + `approval_resolved` append → child `:running`); terminalize the parent (`:route_abandoned`); build state with `parked` set; drive the public seam `RouteComposer.handle_info({:retry_wave_paused, child.id, 1}, state)` (`:1149` — guard matches, `attempt_wave_paused` → `Commit.append_markers` → `{:error, :parent_terminal}` → teardown). Assert `{:stop, :normal, _}`, child `:cancelled`, `:run_cancelled` in kinds (pre-fix: child stayed `:running`).
- **Seam C** (mirror 7f as "7g"): same crafted `:running`+approved child under a terminal parent, `WorkflowRecovery.reconcile_all()` → child `:failed` **and `:run_recovered` in kinds** — the load-bearing non-resume discriminator (a real resume attempt appends only `run_failed`, never `run_recovered`; status alone is ambiguous).

**Punted deterministic test** (documented in the raced-clause comment): the `finish_disposition` `{:decided, :running}` TOCTOU needs a mid-scan interleave (child flips between classify and lock) — not reproducible without a race-injection seam; its reaction is the identical `fail_stranded(:orphaned_terminal_parent)` exercised by 7g.

**Accepted residuals** (comment-documented, not fixed): `async_nolink` steps already in flight before the Seam B kill run to completion (the known orphaned-async limitation; full fix = per-step idempotency keys, tracked out of scope); the sub-millisecond window where a raced resume completes before B/C observe it (side effects already ran — Seam A minimizes entry).

## Verification

Per the no-pipe rule: run gates **bare in background**, read the output tail. All via `mise exec -- mix ...`.

1. After code changes: `mise exec -- mix format`, then `mise exec -- mix jidoclaw.compile_check`.
2. Targeted suites: `test/jido_claw/orchestration/gate_disposition_test.exs test/jido_claw/orchestration/human_gates_test.exs test/jido_claw/orchestration/workflow_recovery_test.exs test/jido_claw/route_composer/composer_durable_test.exs test/jido_claw/orchestration/cancellation_test.exs test/jido_claw/orchestration/reactors/plan_gate_test.exs` (the last two prove genuine approve/resume + cancel paths unaffected — happy-path gates have `parent_run_id: nil` → predicate false).
3. **`mise exec -- mix precommit`** (background, bare) — the done-criterion, covering the whole ~45-file working tree. Any failure from the *base* work gets fixed too; known flaky async:false singletons (MCPServer, Prompt, PipelineStore, MultiSandbox) re-verified in **isolation** before blaming a change.

## Commit-ready ending (no commit — user stages)

Stage: `lib/jido_claw/orchestration/{cases,gate_disposition,workflow_recovery}.ex`, `lib/jido_claw/route_composer/route_composer.ex`, `lib/jido_claw/cli/commands/approvals.ex`, `lib/jido_claw/web/live/approvals_live.ex`, `test/jido_claw/orchestration/gate_disposition_test.exs`, `test/jido_claw/route_composer/composer_durable_test.exs`.

Suggested message:

```
fix(gates): refuse + converge approvals orphaned by a terminal composer parent (P1)

Three doors let a gate child execute under a terminal composer parent with
nobody to fold its output:
- Cases.decide(:approve) now refuses when the child's composer parent is
  terminal ({:error, :parent_terminal}) and fails CLOSED on an unreadable
  parent ({:error, :parent_state_unknown}); reject/abandon stay allowed —
  they converge the pair. New tri-state
  GateDisposition.terminal_composer_parent/3 serves both consumers: approve
  fails closed on uncertainty, recovery acts only on :terminal.
- RouteComposer.teardown_parked_gate now cancels a child that raced to
  :running (Cancellation.cancel kills the mid-resume executor) instead of
  discarding the {:decided, :running} outcome.
- WorkflowRecovery fails an orphaned :running+checkpoint child
  (run_recovered + run_failed, branch :orphaned_terminal_parent) instead of
  re-resuming it; finish_disposition converges the same-scan raced case.

Refusal surfaced in CLI /gates and web /approvals.
```
