# Post-review remediation — verdict-normalizer (camus C1-3) findings

## Context

The camus C1-3 verdict-normalizer plan (`please-review-docs-plans-unadopted-next-eager-wren.md`) shipped and a code review found two issues. **Both are verified real** by direct code read:

**P1 — the dedupe-hit *observe* path bypasses Lane B (VERIFIED).** `observe_existing_child/4` (`route_composer.ex:3236-3255`) sends every non-completed worker terminal and every observe error through `finish_failed/5` unconditionally. But Lane B's three shipped entry points each gate on `lens_only_dispatch?/2` first: the live wave error (`:1671-1677`), the decode failure (`:1757-1763`), and the recovered-already-`:failed` dedupe arm (`:1639-1644`). Missed scenario: composer restarts → dedupes onto a *still-running* lens-only (reviewer) child (`:1618-1619` routes to observe) → the child then fails or the observe times out → `finish_failed` → generic `:route_failed`. No `stage_infra`, no infra retry, no `review_infra_failed` terminal — the exact conflation C1-3 exists to prevent, reachable purely by failure *timing* relative to the restart.

**P2 — composer Trace events are dropped (VERIFIED).** `emit_infra_observability/3` (`route_composer.ex:1841-1859`) calls `Trace.emit(:composer, …)` → telemetry event `[:jido_claw, :composer, :event]` (`trace.ex:121`). The collector attaches only `@base_jido_ai_events ++ @jido_claw_events` (`collector.ex:263-273`), and `@jido_claw_events` (`collector.ex:100-112`) has 11 categories — no `:composer`. Every composer trace event is silently dropped; the "per-run timeline" claimed in AGENTS.md and `telemetry.ex:58-62` doesn't exist. Secondary gap found while verifying: even once attached, the composer emit carries no `agent_id`/`request_id`/`tenant_id`, and the `by_run` index it lands in has **no public reader** — the collected trace would be unreachable by any read API (`Trace.latest/list` targets are agent/request/tenant only). So the fix stamps `tenant_id` too (one line), making the timeline actually retrievable via `Trace.list({:tenant, …})` and tenant-scoped in the durable sink.

Done = both fixes landed with red→green regression tests and `mix precommit` passes (zero findings). Nothing committed/staged; all C1-3 work is still uncommitted in the working tree.

---

## Fix 1 — route the observe arms through Lane B (`lib/jido_claw/route_composer/route_composer.ex`)

1. **Extract the shared gate** — new `defp wave_failed(reason, run, dispatch, display, state)` next to `wave_infra_failed/5` (`:1791`), holding the existing branch verbatim:
   ```elixir
   if lens_only_dispatch?(dispatch, state.catalog),
     do: wave_infra_failed(reason, run, dispatch, display, state),
     else: finish_failed(reason, run, dispatch, display, state)
   ```
   Rewire the two existing duplicates to call it: `handle_wave_result({:error, reason, run}, …)` (`:1671-1677`) and `handle_wave_value({:error, reason}, …)` (`:1757-1763`). This also pre-empts the ExSlop 3rd-contiguous-clone trip the two new call sites would otherwise create. Not a trivial forwarder (it contains the branch), so reach is safe. The recovered-`:failed` dedupe arm (`:1639-1644`) keeps its own `if` — its else is the plain wave-index bump, not `finish_failed`.

2. **Fix the observe branches** (`observe_existing_child/4`, `:3244-3254`):
   - `{:ok, %WorkflowRun{} = other}` (observed just-now-`:failed`) → `wave_failed({:existing_run_not_completed, other.status}, other, dispatch, display, state)` — pass the *reloaded* child so the failed history entry carries the right `child_run_id`.
   - `{:error, reason}` (observe timeout / reload failure) → `wave_failed(reason, run, dispatch, display, state)`.
   - Mixed/producer cohorts keep byte-identical behavior (same reasons, same `finish_failed`).
   - **Document the policy in-code** (on `wave_failed/5` or the observe branches): lens-only observe/reload failures are *deliberately* review infra — the composer still has no trustworthy verdict for the lens even though the immediate failure came from observation/recovery machinery, matching the fail-closed posture in `docs/TRUST-BOUNDARIES.md`.
   - **Unchanged on purpose**: `observe_terminal`'s worker `:cancelled`/`:abandoned` → `finish_failed` (`:3261-3267`). Those are operator decisions, not judge infra — retrying would override the operator. The review finding prescribed only the non-completed and observe-error branches.

3. **Comment sweep** (false-invariant rule — every restatement):
   - `observe_existing_child` doc comment (`:3228-3235`): the re-branch description now says lens-only non-completed/observe-error terminals ride Lane B.
   - The H8 note in the dedupe arm (`:1629-1631`): "there a `:failed` … must fail the route" is no longer true for lens-only cohorts; narrow the deliberate difference to mixed/producer cohorts + the re-dispatch-vs-fail distinction.
   - `wave_infra_failed`'s "shared by three entry points" comment (`:1777-1780`): now five (add the two observe arms).

4. **Doc sweep**:
   - `AGENTS.md` Verdict Normalizer bullet: extend "Lane B (a **lens-only** cohort's wave-execution error, incl. the recovered-failed-child dedupe arm)" with the observe arms (observed-failed / observe-timeout / observe-reload).
   - `docs/plans/unadopted-next-ten/README.md:285` Done-blockquote: same one-clause extension, plus note the post-review P1 fix.

## Fix 2 — attach + reach the composer Trace channel

1. **`lib/jido_claw/trace/collector.ex`**: add `[:jido_claw, :composer, :event]` to `@jido_claw_events` (`:100-112`). `event_shape/2` (`:403-405`) already handles any `[:jido_claw, category, :event]` generically; `trace_key` gives the event its own `{:run, run_id}` trace. No summary `count_category` entry — `:hook`/`:mcp` set the attached-but-uncounted precedent.
2. **`route_composer.ex` `emit_infra_observability/3`** (`:1845-1857`): add `tenant_id: state.tenant` to the emit metadata. Rationale above (reachability via `{:tenant, …}` + tenant-scoped durable sink rows); tenant ids already ride trace metadata by design (`by_tenant` index, `backfill_tenant`). Verify at implementation time `state.tenant` is the binary tenant id (it's passed as the `tenant:` Ash option throughout the composer; if it's ever a struct, stamp the id).
3. `telemetry.ex:58-62` comment ("The Trace `:composer` events carry the per-run timeline") needs no edit — the fix makes it true.

---

## Tests (regression tests written RED first, then the fix)

All composer tests join the existing `describe "camus C1-3 durable infra (crash recovery)"` in `test/jido_claw/route_composer/composer_durable_test.exs` (`:1308`), reusing its fixtures (`lens_first_recoverable_parent/2`, `arm_lens_first_worker/0`, `append_wave_started/4` at `:1862`, `craft_child/4`, `recovery_opts/1`, `await_status/4`, `kinds/2`).

**Test A (the P1 red-first regression — deterministic, latch-free).** Name it for the policy, e.g. `"observe failure on a lens-only corpse child is review infra (no trustworthy verdict) — retries and converges"`. A lens-only *corpse* child forces the observe path deterministically: craft a `:running` child at the wave-0 dedupe key with **no live runner** (nothing can complete or fail it except the observe deadline), short `wave_timeout_ms`. The regression depends on `ensure_started/2` taking the recovery/observe path, so the setup **deliberately constructs and asserts** the exact recoverable `:running` parent state — no conditional fallback:
```
arm_lens_first_worker()
parent = lens_first_recoverable_parent(ctx, wave_timeout_ms: 1_000)   # persisted in parent config (:482/:858)
{:ok, _} = append_event(parent, :run_started, %{}, ctx)               # explicit: the recoverable :running state
append_wave_started(parent, 0, ["quality-reviewer"], ctx)
_corpse = craft_child(parent, ctx, 0, :running)
parent = reload(parent.id, ctx)
assert parent.status == :running                                      # pin the precondition the test rides on
{:ok, _pid} = RouteComposer.ensure_started(recovery_opts(ctx), parent)  # NOT reconcile_all — recovery
                                                                        # would flip the corpse :failed and
                                                                        # take the already-tested dedupe arm
assert :completed = await_status(parent.id, ctx, :completed, 30_000)
ks = kinds(parent.id, ctx)
assert :route_converged in ks
assert Enum.count(ks, &(&1 == :stage_infra)) == 1                      # observe-timeout infra closed wave 0
refute :route_failed in ks
```
Flow: rebuild sees in-flight wave 0 → re-dispatch dedupe-hits the `:running` corpse → observe → deadline (`@observe_poll_ms` 50) → `{:error, {:observe_timeout, :running}}` → (post-fix) Lane B: `stage_infra` with `closed_wave_index: 0` → re-tick → wave 1 under a fresh key runs the reviewer for real → clean verdict → `:route_converged`. **RED pre-fix**: parent goes `:failed` with `:route_failed`.

**Test B (scope pin — producer cohorts stay loud).** Same explicit setup shape (incl. `run_started` + `:running` assertion) against the phase-1 catalog (wave 0 = `planner`, lens nil, via `recoverable_parent(ctx, wave_timeout_ms: 1_000)` + `append_wave_started(parent, 0, ["planner"], ctx)`): observe timeout must still `finish_failed` → parent `:failed`, `:route_failed` in kinds, **no** `:stage_infra`. Green before and after; pins that the fix didn't widen infra to producer cohorts.

**Branch-coverage note (state in the test comment):** the observed-just-now-`:failed` branch (`{:ok, %WorkflowRun{status: :failed}}`) is the *same* `wave_failed` call one clause above the tested one; a deterministic integration test for it would need a new production seam to order the child's failure after the dedupe read (without one it's a coin-flip which arm runs — pre-fix sometimes green — and house rule forbids probabilistic race tests). Covered by Test A (observe `{:error, …}` arm) + the existing dedupe-arm test (`:1378`) on either side of the same helper.

**Test C (the P2 red-first regression)** — new describe in `test/jido_claw/trace/collector_test.exs`, mirroring the `by_tenant` test pattern (`:34-65`):
1. Attach pin: `assert :telemetry.list_handlers([:jido_claw, :composer, :event]) != []` — the direct assertion of the missed attach.
2. End-to-end, collision-proof against prior in-memory entries from other trace tests: generate a **unique** `tenant_id` and a **unique** `run_id` (`"composer-run-#{System.unique_integer([:positive])}"`-style), emit the production shape post-fix — `JidoClaw.Trace.emit(:composer, %{event: :review_infra, run_id: run_id, parent_run_id: run_id, stage: "quality-reviewer", reason: "…", wave_index: 0, lane: :output, tenant_id: tenant_id}, %{count: 1})` — then `H.sync_collector()` → `Trace.list({:tenant, tenant_id})` → **filter** the returned traces' events by `category == :composer and event == :review_infra and run_id == run_id` and assert exactly that event is found (never bare list-shape assertions). **RED pre-fix**: nothing collected.

## Verification

1. RED: run Tests A + C against the current tree, show both fail for the expected reasons (A: parent `:failed`/`:route_failed`; C: no handler, empty tenant list).
2. Apply fixes; targeted green: `mix test test/jido_claw/route_composer/composer_durable_test.exs test/jido_claw/trace/collector_test.exs`, then the wider touched suites `mix test test/jido_claw/route_composer test/jido_claw/trace`.
3. Full gate: `mix precommit` — run bare (never piped), report exit code + counts verbatim; zero credo/reach findings. Known flake: `MemoryExportTest` in full suite (passes in isolation — not a regression).
4. Watchpoints: `wave_failed` holds the branch (no trivial-forwarder smell); the extraction *removes* two existing duplicates (clone check); no `String.to_atom` on input; `assert match?` where an assert carries a message.

## Files touched

- `lib/jido_claw/route_composer/route_composer.ex` — `wave_failed/5` extraction, two observe-branch rewires, `tenant_id` stamp, comment sweep
- `lib/jido_claw/trace/collector.ex` — `@jido_claw_events` += `[:jido_claw, :composer, :event]`
- `test/jido_claw/route_composer/composer_durable_test.exs` — Tests A + B
- `test/jido_claw/trace/collector_test.exs` — Test C
- `AGENTS.md`, `docs/plans/unadopted-next-ten/README.md` — Lane B entry-point claim updates

## Out of scope

- Observed worker `:cancelled`/`:abandoned` → infra (operator decisions; also the pre-existing dedupe-arm vs `observe_terminal` gate/worker asymmetry at `:1651-1655`).
- A public `by_run` trace read API (the tenant stamp makes composer traces reachable; a run-scoped reader is a separate feature).
- A `count_category` summary entry for `:composer` (`:hook`/`:mcp` precedent).
