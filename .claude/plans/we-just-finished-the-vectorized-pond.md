# AR-2 Composer — Phase 2b/2c follow-up: close two post-review lifecycle gaps

## Context

The AR-2 Composer Phase 2b/2c work shipped a supervised `JidoClaw.RouteComposer`
GenServer that drives a multi-wave loop backed by a durable `WorkflowRun` event log.
A code review surfaced two correctness gaps in
`lib/jido_claw/route_composer/route_composer.ex`, both **verified against the code**:

1. **A durable cancel can still launch one more wave.** `Cancellation.cancel/2`
   (`cancellation.ex:165-213`) writes `run_cancelled` (flipping the parent terminal) and
   then kills only processes in `RunExecution`/`RunRegistry` (`run_execution.ex:108,138-144`).
   The composer parent registers in a **disjoint** registry (`RouteComposer.Registry`,
   `route_composer.ex:122,214`) and exposes no `handle_cast`/`handle_call`/`terminate`, so a
   cancel never stops it. The loop re-reads terminal status only at `do_rebuild` (start of a
   life) and at `Commit.commit_wave`'s FOR-UPDATE guard (**after** a wave runs,
   `commit.ex:89-94`). Between the tick and `record_wave_start`/`run_reactor` there is no
   check, and the pre-launch `route_composed`/`wave_started` appends are non-status-authority
   kinds that land even on a terminal parent — so the loop can append a wave's start markers
   and create a child run **after** the parent went `:cancelled`.

2. **A supervised terminal-append failure is silently swallowed.** `parent_terminal_notify/4`
   returns `{:terminalize_failed, reason}` on a failed terminal append; `finish/2`
   (`:1004-1010`) hands it to `maybe_notify/2`, whose `%{notify: nil}` clause (`:1012`)
   discards it with no log and returns `{:stop, :normal, …}`. On the **supervised** path this
   leaves the parent `:running` with no visible error, and `:transient` won't restart a
   `:normal` stop. Asymmetric with `terminalize_parent/4` (`:1148-1154`) and
   `retry_rebuild_or_stop/2` (`:596-601`), which log loudly on the leave-for-recovery path.

**Outcome:** "nothing new schedules after a cancel" holds **race-free**, and a stuck
`:running` parent from a failed terminal append becomes operator-visible.

**Scope (confirmed): Finding 1 = the guard only** (defer making the composer directly
cancellable via the `Cancellation` surface — it adds only promptness, not correctness, since
the in-flight `async_nolink` wave survives a kill anyway, and it overlaps the deferred Phase 4
"wave execution → Task" work). **Finding 2 = log loudly + leave for recovery** (do NOT
crash-loop the shared `:transient` supervisor — the `retry_rebuild_or_stop` stance).

**Review correction folded in:** a best-effort *reload-then-append* before launch is **TOCTOU
-racy** — a cancel landing between the reload and the append still leaks markers, and failing
open on a reload error hides a terminal parent. The fix instead uses a **FOR-UPDATE-guarded
transactional append**, the exact `Commit.commit_wave/4` mechanism: the cancel path also locks
the run row FOR UPDATE (to append `run_cancelled` via `Allocate.lock_run`), so the two
serialize — markers can never land on an already-terminal parent, with **no fail-open path**.

Edits land in `commit.ex`, `route_composer.ex`, and one test file; `mix precommit` is the gate.

---

## Fix 1 — FOR-UPDATE-guarded pre-launch append (`Commit.start_wave/3`)

### `lib/jido_claw/route_composer/commit.ex`

Factor the shared FOR-UPDATE + terminal-gate + result-unwrap skeleton out of `commit_wave/4`,
then add `start_wave/3` reusing it (and the existing private `reload_for_update/2` +
`append_each/3` — **no duplication, no clone-check risk**):

```elixir
def commit_wave(%WorkflowRun{} = parent, wave_index, deltas, opts) do
  guarded_wave_txn([WorkflowEvent, WorkflowRun, ComposerArtifact], parent, opts,
    fn locked -> do_commit(locked, wave_index, deltas, opts) end)
end

@doc """
Atomically append a wave's pre-launch markers (`route_composed` + `wave_started`) under
the SAME FOR-UPDATE parent-terminal guard as `commit_wave/4`. `markers` is an ordered
`[{kind, payload}]`. Returns `:ok`, `{:error, :parent_terminal}` (the run ended
externally — stop, do not re-terminalize), or `{:error, reason}` (a leg failed). Closes
the TOCTOU a best-effort reload would leave: the cancel path also locks the run row FOR
UPDATE, so markers never land on an already-terminal parent.
"""
@spec start_wave(WorkflowRun.t(), [{atom(), map()}], keyword()) :: :ok | {:error, term()}
def start_wave(%WorkflowRun{} = parent, markers, opts) do
  guarded_wave_txn([WorkflowEvent, WorkflowRun], parent, opts,
    fn locked -> append_each(locked, markers, opts) end)
end

# commit_wave/4 and start_wave/3 differ only in the resources touched and the work done
# under the lock. Terminal parent → :parent_terminal BEFORE any write (the read-only txn
# commits harmlessly); else run proceed_fun under the held FOR UPDATE lock.
defp guarded_wave_txn(resources, parent, opts, proceed_fun) do
  resources
  |> Ash.transact(fn ->
    with {:ok, locked} <- reload_for_update(parent, opts) do
      if Projection.terminal_status?(locked.status),
        do: :parent_terminal,
        else: proceed_fun.(locked)
    end
  end)
  |> unwrap_transact()
end

# Ash.transact wraps the fn's non-error return as {:ok, _}. The terminal guard travels the
# SUCCESS channel as the bare atom :parent_terminal, remapped here so Ash.transact's
# polymorphic-return analysis can't erase it; a real leg failure stays {:error, reason}.
defp unwrap_transact({:ok, :ok}), do: :ok
defp unwrap_transact({:ok, :parent_terminal}), do: {:error, :parent_terminal}
defp unwrap_transact({:error, reason}), do: {:error, reason}
```

Remove the now-folded `commit_or_halt/4`. `commit_wave/4` stays **behavior-identical**
(same transaction, same remap). Update the moduledoc to name `start_wave/3` as the
guarded pre-launch marker append (same fence as `commit_wave`).

### `lib/jido_claw/route_composer/route_composer.ex`

- **`record_wave_start/3`** (`:818-832`): build the two payloads as before, then delegate to
  `Commit.start_wave/3` (passing `state.parent` + `auth_opts(state)`), translating its result:

  ```elixir
  defp record_wave_start(dispatch, display, state) do
    markers = [
      route_composed: route_composed_payload(display, state),
      wave_started: wave_started_payload(dispatch, display, state)
    ]

    case Commit.start_wave(state.parent, markers, auth_opts(state)) do
      :ok -> :ok
      {:error, :parent_terminal} = halt -> halt
      {:error, reason} -> {:error, {:wave_start_append_failed, reason}}
    end
  end
  ```

- **`run_built_wave/5`** (`:653-663`): add a `{:error, :parent_terminal}` arm to the `with`'s
  `else` that stops cleanly (exactly like the existing `commit_wave` `:parent_terminal` arm at
  `:719-720`), keeping the generic `{:error, reason}` → `finish_failed`:

  ```elixir
  else
    {:error, :parent_terminal} -> {:stop, :normal, state}
    {:error, reason} -> finish_failed(reason, nil, dispatch, display, state)
  end
  ```

- **Remove `append_to_parent/3`** (`:923-929`, incl. its comment) — its sole caller
  (`record_wave_start`) now goes through `Commit.start_wave/3`, so it is dead code and would
  trip the no-warnings gate. `auth_opts/1` stays (still used by the `commit_wave` call).

No separate run-level reload guard is added — `Commit.start_wave/3` is the single
authoritative fence, so there is **no fail-open branch**. (For an already-terminal parent the
loop still runs `WaveBuilder.build_wave` + `ArtifactContext.build` first, then `start_wave`
catches it — wasted but harmless in-memory work, no durable effect, no child run.)

## Fix 2 — log loudly on a supervised terminal-append failure

In `finish/2`, after `maybe_notify/2`, add a supervised-only loud log; keep stopping
`:normal` (do not crash-loop the shared supervisor):

```elixir
defp finish(terminal, state) do
  {kind, reason} = classify_terminal(terminal)
  summary = summary(kind, reason, state)
  payload = parent_terminal_notify(kind, reason, summary, state)
  maybe_notify(state, payload)
  log_supervised_terminal_failure(payload, state)
  {:stop, :normal, %{state | terminal: kind, reason: reason, summary: summary}}
end

# A supervised run (no sync caller) whose durable terminal append FAILED would otherwise
# stop :normal silently — the parent stays :running with no owner and no visible error (the
# sync path surfaces this via maybe_notify/2; a supervised run has nobody to tell). Log
# loudly so the stuck parent is operator-visible (and recoverable by the 2d boot scan).
# Still stop :normal — NOT crash-loop the shared :transient supervisor on a DB blip (the
# retry_rebuild_or_stop stance).
defp log_supervised_terminal_failure({:terminalize_failed, reason}, %{notify: nil} = state) do
  Logger.error(
    "[RouteComposer] terminal append failed for parent #{state.parent_run_id} " <>
      "(#{inspect(reason)}); parent left :running for recovery"
  )
end

defp log_supervised_terminal_failure(_payload, _state), do: :ok
```

The sync path (`notify` set) is unchanged — `maybe_notify/2` already forwards
`{:terminalize_failed, reason}` to `await_terminal/7` (`:425-427`).

## Moduledoc / comment sweep

Per the doc-sweep rule, reconcile every now-affected claim:
- `commit.ex` moduledoc — add `start_wave/3` alongside `commit_wave/4` as a FOR-UPDATE-guarded
  parent write.
- `route_composer.ex` moduledoc **"Durable composer state"** (`:30-47`) — note the pre-launch
  `route_composed`/`wave_started` markers are now appended atomically under the same
  terminal-guarded transaction (`Commit.start_wave`), and **"Driving / notification"**
  (`:62-80`) — a supervised terminal-append failure is now logged loudly (parent left
  `:running` for recovery), not silently swallowed.
- Update the `record_wave_start/3` and `run_built_wave/5` lead comments to describe the
  `:parent_terminal` stop path.

**Wording note (sync-caller, not a code change):** on a `run_sync` composer a `:parent_terminal`
stop returns no notify, so `await_terminal/7` resolves via the timeout — this is the *existing*
behavior already shared with the `commit_wave` `:parent_terminal` arm, not introduced here. It is
not ideal UX (the caller waits out the timeout rather than learning of the cancel promptly);
improving it is out of scope for this follow-up. Word the comment so it reads as "consistent with
the existing arm," not as endorsed UX.

---

## Tests

Add two deterministic tests to `test/jido_claw/route_composer/composer_durable_test.exs` (it
already carries the stub harness, `TenantCase`, `import ExUnit.CaptureLog`, and the `kinds/2`
+ `reload/2` helpers). Add one small state-builder reusing `init/1` so it can't drift:

```elixir
defp loop_state(parent, ctx, overrides) do
  base = [
    catalog: TestFixtures.phase1_catalog(),
    live: TestFixtures.phase1_seed_live(),
    artifacts: TestFixtures.phase1_seed_artifacts(),
    tenant: ctx.tenant, actor: ctx.actor, context: ctx.context, parent_run_id: parent.id
  ]

  {:ok, state, _continue} = RouteComposer.init(Keyword.merge(base, overrides))
  %{state | parent: parent}
end
```

**Test A — Fix 1 (pre-launch guard).** Create a parent, durably `run_cancelled` it (an operator
cancel landing between waves), build a `wave_index: 0` loop state, drive one tick directly:
- `assert {:stop, :normal, _} = RouteComposer.handle_continue(:tick, state)`
- `assert kinds(parent.id, ctx) == before` (no `route_composed`/`wave_started` appended)
- **`child_runs` absence (review point 2 — the finding is "no new *work* schedules"):**
  `{:ok, %{child_runs: kids}} = Ash.load(reload(parent.id, ctx), :child_runs, tenant: ctx.tenant, actor: ctx.actor)` then `assert kids == []`.
- **Prove-fails-without-fix:** temporarily restore the non-guarded append (markers via plain
  `WorkflowLog.append`); the same tick appends both markers (non-authority kinds land on the
  terminal parent) and `run_reactor` creates a child — both the `kinds == before` and the
  `kids == []` assertions fail. (`converging_outputs()` is set so the without-fix wave
  completes rather than hanging; the seed `"request"` is an untagged inline value so
  `ArtifactContext.build` resolves with no DB row.)

**Test B — Fix 2 (supervised terminal-append failure logged).** Create a real `:running`
parent; build a supervised state (`notify: nil`) with a **bogus tenant** (the terminal append's
FOR-UPDATE reload misses → `{:terminalize_failed, _}`, a deterministic stand-in for a transient
terminal-write failure) and **`max_waves: 0`** (the first tick goes straight to a
`budget_exhausted` finish, no wave runs):
- `log = capture_log(fn -> assert {:stop, :normal, _} = RouteComposer.handle_continue(:tick, state) end)`
- `assert log =~ "terminal append failed for parent #{parent.id}"`
- `assert reload(parent.id, ctx).status == :running` (the defect's consequence — now visible).
- **Prove-fails-without-fix:** remove the log call → `log` empty → the `=~` assertion fails.

Existing tests are unaffected: `commit_wave/4` is behavior-identical; `start_wave` appends the
same two markers in the same order on a `:running` parent (the durable-delta-log test's
`route_composed → wave_started → wave_completed` sequence is unchanged); Fix 2's clause only
fires for `{:terminalize_failed, _}` + `notify: nil`.

---

## Verification

1. `mix test test/jido_claw/route_composer/composer_durable_test.exs` — both new tests green,
   all existing composer-durable tests still green.
2. **Prove-fails-without-fix:** revert each fix in turn (Fix 1 → non-guarded append; Fix 2 →
   drop the log) and confirm its test fails, then restore.
3. `mix format --check-formatted`.
4. **`mix precommit`** — the completion gate. Run the full suite (credo + reach/ExSlop kept at
   **zero**; never pipe through `tail`). The commit.ex refactor is DRY (one `guarded_wave_txn/4`
   skeleton, no duplicated transact body → no clone-check risk); the new `Logger.error` uses the
   existing multiline `<>` idiom (no string-building ping-pong); `append_to_parent/3` is removed
   so there is no unused-function warning.
