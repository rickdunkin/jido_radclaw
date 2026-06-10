# Fix Phase 5 Review Findings (tick window · collect edges · dedupe ordering)

## Context

Post-Phase-5 code review surfaced three findings. All three are **validated against the code**:

1. **[P1] Duplicate ticks can launch a second run.** Timers are armed as plain `:tick` (`worker.ex:205/210/226`) and `handle_info(:tick, …)` (`worker.ex:116-120`) stamps provenance from `state.next_run` *at delivery time*, then `schedule_next/1` advances it. A second queued tick for the same due window stamps the **newly computed future window** → different idempotency key → a second run launches early, and the real future tick then dedupes against it. This defeats T2-3's done-bar ("a double cron tick yields one run") — the dedupe key must be bound to the window the timer was armed for, not to mutable state.
2. **[P2] Named sequential skills render a star, not a chain.** `Compiler.add_collect/3` (`compiler.ex:430-452`) stamps `depends_on: <named steps>` on the collect step in **every** mode, while only the `:dag` clause stamps agent-step edges. `StepGraph.edges/1` (`step_graph.ex:59-67`) disables the sequence-chain fallback when *any* declared edge exists. A sequential skill with **named** steps (named-but-no-deps → `execution_mode` = `:sequential`) therefore renders `step1→collect, step2→collect, …` instead of `step1→step2→…→collect`. (The existing `sequential_skill` test fixture is unnamed, which is why no test caught it.)
3. **[P2] Dedupe is checked after skill/reactor work.** `WorkflowRunner.run/1` (`workflow_runner.ex:54-55`) resolves + compiles the skill before the key reaches the runner, and `ReactorRunner.run/3`'s `with` (`reactor_runner.ex:203-206`) runs `build_runnable` before `existing_for_key`. A duplicate scheduled tick whose skill was since removed/broken returns `{:error, …}` instead of short-circuiting to the existing run — and that error feeds the cron worker's failure counter (3 strikes → job auto-disabled).

**Definition of done:** all three fixed + test-pinned, and `mise exec -- mix precommit` passes (run bare in background, read the tail — never piped).

No schema changes, no migrations, greenfield (no compat shims for the old `:tick` message shape).

---

## Fix 1 — Carry the scheduled window in the timer message

`lib/jido_claw/platform/cron/worker.ex`

- All three `schedule_next/1` arms send `{:tick, window}` where `window` is the **same `%DateTime{}` struct** stored in `next_run`:
  - `{:at, dt}` → `Process.send_after(self(), {:tick, dt}, delay)`.
  - `{:every, ms}` → compute `next = DateTime.add(DateTime.utc_now(), ms, :millisecond)` **before** `send_after`, use it in both the message and `next_run`.
  - `{:cron, expr}` → `{:tick, dt}` (error branch unchanged).
- Replace both `handle_info(:tick, …)` clauses:
  ```elixir
  def handle_info({:tick, window}, %{status: :active, next_run: window} = state) do
    state = execute_job(state, {:scheduled, window})
    {:noreply, schedule_next(state)}
  end

  # Stale/duplicate window, or a disabled worker: swallow WITHOUT executing
  # or re-arming — the matching-tick clause is the only re-arm point, so the
  # timer for the current next_run (if active) is already in flight.
  def handle_info({:tick, _window}, state), do: {:noreply, state}
  ```
  The repeated `window` variable is the equality constraint (message window must equal current `next_run`); pattern equality on identical DateTime structs holds because the message carries the very struct stored in state. Invariant after the change: an active worker has exactly one armed timer — matching ticks always re-arm, stale ticks never re-arm.
- Moduledoc + the `fire:` struct comment: note that ticks carry their armed window and stale windows are swallowed.

**Tests** — `test/jido_claw/cron/worker_fire_provenance_test.exs` (only place that sends `:tick`). Keep the existing `@far_future {:every, 86_400_000}` schedule style for all cases — never `:at`, whose re-fire loop is deliberately out of scope:
- Update the existing tick test: `send(pid, {:tick, window})` (window already read from `get_state`).
- New: **duplicate window swallowed** — send `{:tick, window}` twice; exactly one `{:runner_ran, %{fire: {:scheduled, window}}}`, `refute_receive` a second; worker alive, `next_run` advanced past `window`.
- New: **stale window ignored** — send `{:tick, DateTime.add(window, 3600)}`; `refute_receive {:runner_ran, _}`; `get_state` shows `next_run` unchanged.

## Fix 2 — Collect `depends_on` becomes mode-aware (`:dag` only)

`lib/jido_claw/skills/compiler.ex`

- `add_collect/3` → `add_collect/4` taking `mode`; `collect_deps` = named display names only when `mode == :dag`, else `[]`. **Execution wiring is untouched:** the collect step's `args` (`result_arg/1` from every step) and `order:` stay exactly as today in every mode — only the metadata `depends_on:` opt changes. Keep passing `depends_on:` in the `CollectStep` impl opts (`CollectStep` never reads it; `ReactorMiddleware.depends_on/1` already maps `[]` → omitted payload field, so projected rows keep the `[]` column default).
- `build_graph/3` passes its `mode`; `build_iterative/1` passes `:iterative` (today's `[{nil, 1}]` already nil-filtered to `[]` — behavior unchanged there).
- Update the comment at the stamping site (`compiler.ex:434-437`) — fallback-eligibility for sequential runs is the point.

Result: a named sequential run has **zero** declared edges → `StepGraph` falls back to the sequence chain, which includes the collect row ranked last (`collect_rank/1`) → honest `step1→…→stepN→collect`. DAG behavior unchanged (the `workflow_step_projection_test.exs:86` pin on the dag fixture stays green).

**Doc honesty** (both currently say the collect stamping is unconditional): adjust the T3-1 shipped notes — `docs/exploration/squidie/FEATURES-WORTH-BORROWING.md:241` and `docs/exploration/squidie/REACTOR-ADOPTION.md:114-117` — to say the collect's named-step list is stamped **in dag mode only**; sequential runs (named or not) take the sequence-chain fallback.

**Tests:**
- `test/jido_claw/skills/compiler_test.exs`: new named-sequential fixture (the existing `sequential_skill` steps + `"name"` keys, still no `depends_on`/`consumes` so `execution_mode` stays `:sequential`) → the `:__collect__` impl opts carry `depends_on: []`; existing dag pin (collect deps = named steps) unchanged.
- `test/jido_claw/web/components/step_graph_test.exs`: named sequential rows **plus** a collect row, all with empty `depends_on` → fallback chain `step1→step2→…→collect` (pins the user-visible rendering this finding is about).

## Fix 3 — Dedupe lookup before compile/build work

`lib/jido_claw/orchestration/reactor_runner.ex`
- Reorder the `with` in `run/3`: `Keyword.fetch(:tenant)` → `Keyword.fetch(:actor)` → `existing_for_key` → `build_runnable` → `create_run`. Else-clause shapes don't overlap, so the else block is unchanged. Scope the moduledoc claim precisely: a key hit skips **runnable build/middleware wiring, run creation, replay-inputs encoding, and execution** — the cheap pure opt reads before the `with` (`Keyword.get`s, identity/name derivation) still run; don't claim "zero work" beyond that.

`lib/jido_claw/orchestration/workflow_runner.ex`
- Hoist key derivation: `key = idempotency_key(state)` at the top of `run/1`; when non-nil, read `WorkflowRun.by_idempotency_key(key, tenant: tenant_id, actor: Actor.system(tenant_id))` **before** `Skills.get`/`Compiler.compile`. Hit → `:ok` immediately (with a `Logger.debug`; add `require Logger`). Miss / nil key / read error → proceed exactly as today (ReactorRunner's read-first + unique-violation backstop still owns the race; this early read is an optimization + failure-isolation, not the correctness mechanism). Update the "Tick idempotency" moduledoc section.

**Tests:**
- `test/jido_claw/orchestration/reactor_runner_test.exs` (in the existing "launch idempotency (T2-3)" describe): seed a run with a key, then call `ReactorRunner.run(<junk arg, e.g. 42>, %{}, idempotency_key: key, …)` → `{:ok, {:existing_run, id}, run}`, **not** `{:error, {:not_a_reactor, _}, nil}` — pins lookup-before-build.
- `test/jido_claw/orchestration/workflow_runner_test.exs` (in the existing "tick idempotency (T2-3)" describe): seed a `WorkflowRun.create` with `idempotency_key: "cron:<job_id>:<iso8601>"`, then `WorkflowRunner.run` with `workflow_name: "does_not_exist_skill"` and `fire: {:scheduled, <same window>}` → `:ok`, **and exactly one run carries that exact idempotency key** (assert on the full key string, not just "no new runs" / the prefix-filtering `runs_for_job/2` helper) — pins the review's exact scenario (duplicate tick + vanished skill must not error / feed the failure counter) and that the dedupe resolved to the seeded run. No templates seam needed (nothing executes).

---

## Out of scope (observed, flag separately)

`{:at, dt}` schedules re-arm after firing with an unchanged `next_run` and a clamped-to-0 delay (`worker.ex:203-207`), i.e. an `:at` job appears to re-fire in a tight loop unless something external unschedules it. Pre-existing, untouched by Fix 1 (the window always matches), and not part of this review — worth its own look.

## Risks / gate watch-items

- The provenance test round-trips the window through `get_state`, pinning the DateTime pattern-equality assumption.
- No new rescues, no new map-shape smells expected; both touched runner files already carry the `bare_rescue` file pragma. Worker/compiler/step_graph changes are shape-preserving.
- Flaky-suite memory applies: `worker_fire_provenance_test` is `async: false` — verify any failure in isolation before blaming the change.

## Verification

1. Targeted: `mise exec -- mix test test/jido_claw/cron/worker_fire_provenance_test.exs test/jido_claw/skills/compiler_test.exs test/jido_claw/web/components/step_graph_test.exs test/jido_claw/orchestration/workflow_runner_test.exs test/jido_claw/orchestration/reactor_runner_test.exs test/jido_claw/orchestration/workflow_step_projection_test.exs`
2. **Gate (required for done):** `mise exec -- mix precommit` — bare, in background, read the output tail.
