# Human Approval Gates — Code-Review Fixes (P1 + 2×P2)

## Context

Phase 2 (durable human approval gates) is implemented and its "done" matrix passes. A
follow-up code review surfaced three consistency/robustness defects in the
halt → persist → resume machinery. All three are **validated against the current code**
(read directly, not just the line cites). None require a schema change, so there is **no
migration** — the fixes reuse existing Ash actions (`AgentCase.cancel`, `pending_for_run`,
`destroy`), `WorkflowLog.append`, `Ash.transact`, and the running `JidoClaw.TaskSupervisor`.

The completion bar is **`mix precommit` must pass** (run via `mise exec -- mix precommit`).

The three defects:

1. **[P1] `cases.ex` — best-effort hook on the resume critical path.** `decide(:approve)`
   runs the gate's `after_approved` hook *synchronously before* `GateResume.resume/2`
   (`cases.ex:102` before `:104`). `run_hook/6`'s isolation is a single bare `rescue`
   (`:183-185`) — it catches `raise` but **not** `throw`, `exit`, or a hang. A hung hook
   blocks `decide` forever; a `throw`/`exit` propagates out *before* resume runs. Either way
   the decision is committed (`:running` + checkpoint) but the durable downstream steps never
   resume — stranded until the next boot's recovery.

2. **[P2] `workflow_recovery.ex:119` — `:parked` branch never verifies the pending case
   exists.** `reconcile_branch(:parked, run)` is a bare `emit(run, :parked)` no-op. If the
   `AgentCase` is missing/deleted/corrupt, the run sits `:awaiting_approval` + checkpoint
   **forever**: no inbox row → no decision possible → no terminal, on every boot.

3. **[P2] `reactor_runner.ex:273-278` — gate-pause failure leaves a stale `:pending` case.**
   `gate_open` commits the `AgentCase` (`:pending`) + `approval_requested` *before* `finalize`
   persists the checkpoint. If `set_checkpoint` or the pending-case lookup then fails,
   `handle_gate_pause` calls `ensure_failed` (which only appends `run_failed`) — leaving a
   `:failed` run with a stale `:pending` case lingering in the operator inbox.

These compose: fix 3's rare double-failure (checkpoint committed, then a failed cleanup
transaction) can leave a `:awaiting_approval`-+-checkpoint run with no case — exactly the
orphan that **fix 2** reaps on the next boot.

---

## Fix 1 — Isolate the gate hook off the resume critical path (`orchestration/cases.ex`)

Dispatch the hook to the existing `JidoClaw.TaskSupervisor` so it can never block or crash
the decision/resume path, bounded by a timeout and with crashes captured — no bare `rescue`
needed (`Task.yield`/`shutdown` handle raise/throw/exit/hang uniformly). This satisfies the
finding's "isolated supervised task with timeout/catch handling" directly.

**Changes:**

- Add `@task_supervisor JidoClaw.TaskSupervisor`. Resolve the timeout at call time via a
  private `hook_timeout/0` reading `Application.get_env(:jido_claw, :gate_hook_timeout, 30_000)`
  — configurable so tests can shrink it (a hung hook then leaves a short-lived task, not 30s).
- Replace the synchronous `run_hook/6` (lines 160-185) with a non-blocking `dispatch_hook/6`
  that spawns the work (logging a spawn failure — `start_child/2` can return `{:error, _}`),
  plus a `bounded_hook/6` that runs the hook under a monitored, timed sub-task:

  ```elixir
  defp dispatch_hook(%AgentCase{gate_module: nil}, _f, _r, _d, _t, _a), do: :ok

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

  defp bounded_hook(agent_case, fun, run, decision, tenant, actor) do
    ctx = %GateContext{run: run, agent_case: agent_case, decision: decision,
                       tenant: tenant, actor: actor}
    %{gate_module: mod} = agent_case
    task = Task.Supervisor.async_nolink(@task_supervisor, fn -> apply(mod, fun, [ctx]) end)

    case Task.yield(task, hook_timeout()) || Task.shutdown(task) do
      {:ok, :ok} -> :ok
      {:ok, {:error, reason}} -> Logger.warning("[Cases] #{fun} hook errored: #{inspect(reason)}")
      {:ok, other} -> Logger.warning("[Cases] #{fun} hook returned #{inspect(other)}")
      {:exit, reason} -> Logger.warning("[Cases] #{fun} hook crashed: #{inspect(reason)}")
      nil -> Logger.warning("[Cases] #{fun} hook timed out")
    end
  end
  ```

  `async_nolink` + `Task.yield`/`shutdown` captures **raise, `throw`, and `exit`** (all surface
  as `{:exit, reason}`) and a hang (→ `nil` after the timeout) — the failure modes the old bare
  `rescue` missed.

- In `dispatch(:approve, …)` (line 102) and `dispatch(:reject, …)` (line 111), swap
  `run_hook(…)` → `dispatch_hook(…)`. Source order is unchanged, but because the spawn returns
  instantly, `finalize_approve` (resume) is no longer gated behind the hook. The reject path's
  `{:ok, cancelled_run}` return can no longer be swallowed by a `throw`/`exit`.
- **Remove the now-unused `# reach:disable-for-this-file bare_rescue` pragma + its comment
  block (lines 36-40)** — `bounded_hook` uses no bare `rescue` (verify it's the only rescue in
  the file; it is). If `reach.check` does not flag an unused suppression, this is harmless
  either way; removing it keeps the file honest.
- Update the moduledoc (lines 13-26) to state the hook is dispatched to an isolated,
  timed supervised task (still best-effort, post-commit, logged), so it never blocks resume.

**Why this and not a plain reorder:** moving the hook *after* a synchronous resume still lets
a hung hook block the operator's `decide` call. Async dispatch removes the hook from the
critical path entirely while preserving the "best-effort, post-commit, recovery-path-skipped"
contract (recovery never routes through `Cases.decide`, so it still never fires the hook).

---

## Fix 2 — `:parked` branch verifies a pending case exists (`orchestration/workflow_recovery.ex`)

Keep `classify/1` pure (status + checkpoint only); do the DB existence check in the branch
handler, mirroring how `cancel_pending_cases` already queries.

**Changes:**

- Add `@parked_orphan_reason "recovered: parked gate, pending case missing"`.
- Rewrite `reconcile_branch(:parked, run)` (line 119):

  ```elixir
  defp reconcile_branch(:parked, run) do
    tenant = run.tenant_id
    actor = Actor.system(tenant)

    case AgentCase.pending_for_run(run.id, tenant: tenant, actor: actor) do
      {:ok, [_ | _]} ->
        emit(run, :parked)                      # case open — correctly waiting

      {:ok, []} ->                              # orphaned park — can never be decided
        run
        |> WorkflowLog.append(:run_cancelled, %{reason: @parked_orphan_reason},
             tenant: tenant, actor: actor)
        |> finish(run, :parked_orphaned)

      {:error, reason} ->                       # transient read error — retry next boot
        Logger.warning(
          "[WorkflowRecovery] parked-case lookup failed for run #{run.id}: #{inspect(reason)}"
        )
    end
  end
  ```

  A single `:run_cancelled` append flips the run `:cancelled` and clears the checkpoint via
  the projection (Decision 7) — no transaction needed (nothing to cancel). `finish/3` already
  handles `{:ok, _}` / `{:error, _}` and the `:parked_orphaned` telemetry branch tag is
  consistent with the existing tags.

- Existing **"parked gate survives recovery untouched"** test still passes: the pending case
  exists → `{:ok, [_ | _]}` → `emit(:parked)` → run untouched.

> Note: after Fix 3 refactors the dangling-gate branch (below), the `WorkflowEvent` alias and
> the private `cancel_pending_cases/3` in this module become unused — remove them to avoid
> compile warnings (`compile_check` is warning-strict). `AgentCase` stays (used here),
> `Actor`/`GateResume`/`WorkflowLog`/`WorkflowRun` stay.

---

## Fix 3 — Gate-pause failure cancels the pending case, atomically (`reactor_runner.ex` + shared helper in `workflow_log.ex`)

The cancellation **must** be in the same transaction as the terminal append: failing the run
alone (terminal) while leaving the case `:pending` is *strictly worse* than today, because a
terminal run is never re-scanned by recovery → permanent orphan. So extract the
"cancel pending cases + append terminal, atomically" choreography (today inlined in recovery's
dangling-gate branch) into a shared `WorkflowLog` helper and call it from both sites.

**`workflow_log.ex` — new shared helper** (next to `append_all/3`, `gate_open/3`):

```elixir
@doc """
Terminate `run` AND cancel its pending `AgentCase`(s) in one transaction: cancel
every pending case with `case_reason`, then append `kind` (a terminal event the
projection folds to a terminal status, clearing the checkpoint per Decision 7).
Either both persist or neither does, so run status and the operator inbox never
disagree. Shared by the runner's gate-pause failure path and recovery's
dangling-gate branch.
"""
@spec terminate_cancelling_cases(WorkflowRun.t(), atom(), map(), String.t(), keyword()) ::
        {:ok, WorkflowEvent.t()} | {:error, term()}
def terminate_cancelling_cases(run, kind, payload, case_reason, opts \\ []) do
  tenant = tenant(run, opts)
  actor = actor(run, opts)

  Ash.transact([AgentCase, WorkflowEvent], fn ->
    with {:ok, _} <- cancel_pending_cases(run, case_reason, tenant, actor),
         {:ok, event} <- append(run, kind, payload, tenant: tenant, actor: actor) do
      event
    end
  end)
end

defp cancel_pending_cases(run, reason, tenant, actor) do
  case AgentCase.pending_for_run(run.id, tenant: tenant, actor: actor) do
    {:ok, cases} ->
      Enum.reduce_while(cases, {:ok, :done}, fn agent_case, _acc ->
        case AgentCase.cancel(agent_case, %{cancellation_reason: reason},
               tenant: tenant, actor: actor) do
          {:ok, _} -> {:cont, {:ok, :done}}
          {:error, r} -> {:halt, {:error, r}}
        end
      end)

    {:error, reason} ->
      {:error, reason}
  end
end
```

(The `with` body returns the bare `event`; `Ash.transact` wraps it `{:ok, event}` and rolls
back on any `{:error, _}` — same idiom as `gate_open/3`.)

**Also harden `WorkflowLog`'s private resolvers** so the cleanup helper (and every other
caller) isn't brittle when called without an actor on the public `finalize/3` path. Change
`tenant/2` and `actor/2` (lines 119-120) from `Keyword.get(opts, key, default)` to
`Keyword.get(opts, key) || default`: the 3-arg form only applies the default when the key is
*absent*, so an explicit `actor: nil` (which the runner passes via `Keyword.get(opts, :actor)`)
would defeat the `Actor.system/1` fallback. The `|| default` form falls back on `nil` too.

**`workflow_recovery.ex` — refactor dangling-gate to use the helper** (behaviour-preserving):

```elixir
defp reconcile_branch(:dangling_gate, run) do
  run
  |> WorkflowLog.terminate_cancelling_cases(:run_cancelled,
       %{reason: @dangling_gate_reason}, @dangling_gate_reason,
       tenant: run.tenant_id, actor: Actor.system(run.tenant_id))
  |> finish(run, :dangling_gate)
end
```

The existing **"dangling gate is cancelled on recovery"** test passes unchanged (same
`:run_cancelled` event + case `:cancelled` with `cancellation_reason =~ "dangling gate"`).
Delete the module-local `cancel_pending_cases/3` and the `WorkflowEvent` alias (now unused).

**`reactor_runner.ex` — route all gate-pause failures through the helper:**

- Add `@gate_pause_reason "gate pause failed"`.
- Fold the `encode_checkpoint` call into the `with` via a small rescue-wrapped helper so a
  serialization raise (the 4th, currently-leaking failure path — it escapes to `execute/6`'s
  rescue → `ensure_failed` → stale case) takes the same cancellation path. The new `rescue` is
  covered by the file-level `# reach:disable-for-this-file bare_rescue` pragma (`:81`).

  ```elixir
  defp handle_gate_pause(reactor, run, opts) do
    with {:ok, checkpoint} <- safe_encode_checkpoint(reactor, opts),
         {:ok, updated} <-
           WorkflowRun.set_checkpoint(run, %{resume_checkpoint: checkpoint},
             tenant: Keyword.get(opts, :tenant, run.tenant_id),
             actor: Keyword.get(opts, :actor)),
         {:ok, case_id} <- pending_case_id(updated, opts) do
      RunPubSub.broadcast_gate(
        {:gate_requested, updated.id, %{tenant_id: updated.tenant_id, agent_case_id: case_id}}
      )
      {:ok, {:paused, case_id}, updated}
    else
      {:error, reason} ->
        cancel_pending_and_fail(run, reason, opts)
        {:error, {:gate_pause_failed, reason}, reload(run, opts)}
    end
  end

  defp safe_encode_checkpoint(reactor, opts) do
    {:ok, encode_checkpoint(reactor, Keyword.get(opts, :inputs, %{}),
                            Keyword.fetch!(opts, :reactor_module))}
  rescue
    error -> {:error, {:encode_failed, Exception.message(error)}}
  end

  defp cancel_pending_and_fail(run, reason, opts) do
    case WorkflowLog.terminate_cancelling_cases(run, :run_failed,
           %{error: Reason.format({:gate_pause_failed, reason})}, @gate_pause_reason,
           tenant: Keyword.get(opts, :tenant, run.tenant_id),
           actor: Keyword.get(opts, :actor)) do
      {:ok, _} ->
        :ok

      {:error, cleanup_error} ->
        # Cleanup transaction rolled back. Do NOT fall back to a run-only
        # ensure_failed — a terminal run + still-:pending case is never re-scanned.
        # Leaving the run :awaiting_approval (no checkpoint, or checkpoint-but-no-case)
        # lets recovery's dangling-gate / parked-orphan (Fix 2) branch reap it next boot.
        Logger.warning(
          "[ReactorRunner] gate-pause cleanup failed for run #{run.id}: " <>
            "#{inspect(cleanup_error)} — leaving for recovery"
        )
        :ok
    end
  end
  ```

On success: run `:failed`, pending case `:cancelled`, checkpoint cleared — all in one
transaction. On the (rare) cleanup-transaction failure: the run is left non-terminal so
recovery reaps it, rather than stranding a `:pending` case behind a terminal run.

---

## Test plan (`test/jido_claw/orchestration/human_gates_test.exs` + test gate)

All new tests reuse the existing helpers (`run_gated/2`, `open_gate_without_checkpoint/2`,
`reload/2`, `kinds/2`, `scope/1`) and `JidoClaw.TenantCase`.

**Fix 1 — async hook:**
- Add a private poll helper `eventually(fun, timeout \\ 1_000)` (poll with `Process.sleep`).
  Change the two marker assertions that now race the async hook:
  - happy-path (line 62): `assert eventually(fn -> TestIrreversibleWrite.approved?(case_id) end)`
  - reject (line 80): `assert eventually(fn -> TestIrreversibleWrite.rejected?(case_id) end)`
  - The recovery `refute … approved?` (line 138) stays — that path never spawns the hook.
- Extend the test gate `test/support/jido_claw/gates/test_irreversible_write.ex` with a
  `set_behavior(:ok | :throw | :exit | :hang)` flag (stored in its ETS table; default `:ok`),
  consulted by `after_approved` (`:throw` → `throw(:boom)`, `:exit` → `exit(:boom)`, `:hang` →
  `Process.sleep(:infinity)`).
- **New regression test (the load-bearing one):** set the hook to `:exit` (or `:throw`) — **not
  `:raise`**, since the *old* bare `rescue` already caught `raise`, so a `:raise` test passes
  before the fix and proves nothing. With `:exit`/`:throw`, the old synchronous hook propagates
  out of `dispatch(:approve)` and resume never runs; the new async path captures it. Run the
  happy path, assert `Cases.decide(:approve)` still returns `{:ok, completed}` with
  `completed.status == :completed` and `resume_checkpoint == nil`. Deterministic (asserts the
  synchronous resume result; does not poll the marker) — proves a crashing hook no longer
  strands the run. This test **fails on the current code, passes after the fix.**
- **Optional hang test:** in a test that sets `:gate_hook_timeout` small (e.g. `100`) via
  `Application.put_env` with an `on_exit` restore, set the hook to `:hang`, and assert
  `Cases.decide(:approve)` still returns `{:ok, completed}` promptly — the bounded timeout
  shuts the hung task down rather than blocking the decision.

**Fix 2 — parked-orphan:**
- **New test "parked gate with a missing pending case is cancelled on recovery":**
  `run_gated` → `{:paused, case_id}` → `Ash.destroy!(case, scope)` (use `authorize?: false` if
  policy blocks) → `WorkflowRecovery.reconcile_all()` → assert run `:cancelled`,
  `:run_cancelled in kinds`, `resume_checkpoint == nil`.

**Fix 3 — gate-pause cleanup:**
- **New helper unit test:** `open_gate_without_checkpoint` (pending case, `:awaiting_approval`)
  → `WorkflowLog.terminate_cancelling_cases(run, :run_failed, %{error: "boom"}, "gate pause
  failed", scope)` → assert run `:failed`, case `:cancelled` with `cancellation_reason ==
  "gate pause failed"`, checkpoint nil.
- **New runner-wiring test:** `open_gate_without_checkpoint` → `Ash.destroy!` the case →
  `ReactorRunner.finalize({:halted, %{stub: true}}, run, [tenant:, actor:, inputs: %{},
  reactor_module: GatedTestReactor])` → assert `{:error, {:gate_pause_failed,
  :pending_case_missing}, failed}`, `failed.status == :failed`, and
  `AgentCase.pending_for_run(run.id, …) == {:ok, []}` (no stale inbox row). (`finalize/3` is
  `@doc false` but public and already called externally by `GateResume`; the stub map
  serializes fine through `encode_checkpoint`.)

---

## Critical files

- **Modify:** `lib/jido_claw/orchestration/cases.ex` (Fix 1),
  `lib/jido_claw/orchestration/workflow_recovery.ex` (Fix 2 + Fix 3 refactor),
  `lib/jido_claw/orchestration/reactor_runner.ex` (Fix 3),
  `lib/jido_claw/orchestration/workflow_log.ex` (Fix 3 shared helper),
  `test/jido_claw/orchestration/human_gates_test.exs`,
  `test/support/jido_claw/gates/test_irreversible_write.ex`.
- **Reuse:** `JidoClaw.TaskSupervisor` (application.ex:135), `AgentCase.cancel` /
  `pending_for_run` / `destroy` (agent_case.ex), `WorkflowLog.append`, `Ash.transact`,
  `Projection` terminal checkpoint-clear (Decision 7), `Actor.system/1`, `RunPubSub`,
  the existing `finish/3` + `emit/2` telemetry shims.
- **No migration, no new resource/attribute/action, no CLI command** (so
  `jidoclaw.system_prompt.check` needs no doc update).

## Verification

Run incrementally, then the full gate (toolchain is mise latest — prefix `mise exec --`):

1. `mise exec -- mix compile --warnings-as-errors`
2. `mise exec -- mix test test/jido_claw/orchestration/human_gates_test.exs` — the full gate
   matrix plus the new tests. Then `…/reactor_runner_test.exs` and
   `…/workflow_recovery_test.exs` for regressions.
3. **`mise exec -- mix precommit`** (the bar). Watch specifically:
   - `jidoclaw.compile_check` — no new warnings (esp. the removed `WorkflowEvent` alias /
     `cancel_pending_cases` in recovery).
   - `reach.check --arch --smells --strict` — new code smell-free; confirm the runner's
     file-level `bare_rescue` pragma covers `safe_encode_checkpoint`, and that removing the
     `cases.ex` pragma doesn't trip an unused-suppression error (re-add only if it does).
   - `dialyzer` — the new `WorkflowLog.terminate_cancelling_cases/5` `@spec`.
   - `credo --strict` — if it flags `Process.sleep` in the `eventually/2` test helper, switch
     to a monitor-based drain of `JidoClaw.TaskSupervisor` children.

**Manual smoke (optional):** `iex -S mix`, run `GatedTestReactor` via `ReactorRunner.run/3`,
`/gates approve <id>`, confirm completion and `resume_checkpoint == nil`. A raising
`after_approved` hook should log but not block completion.
