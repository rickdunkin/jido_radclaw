# Post-review fixes: park-deadline decision race (P1) + replay gate unbounded read (P2)

## Context

The synchronous-cascade remediation plan (`.claude/plans/please-review-the-changes-synchronous-cascade.md`) shipped; a follow-up code review of the unstaged diff surfaced two findings plus one test-hygiene note. **All validated against the code — both findings are real:**

- **P1 (confirmed)** — `route_composer.ex`'s sensitive-park deadline handler (O-M2) can lose an operator gate approval. `Cases.decide(:approve)` commits case `:pending → :approved` + child `:awaiting_approval → :running` in one transaction (`cases.ex:373`) *then* broadcasts; a `{:park_deadline, …}` timer message already in the composer mailbox wins the race, sees no pending case (`terminalize_deadline_child`, `route_composer.ex:2182`), falls to the direct-abandon fallback, attempts an illegal `run_abandoned` on the `:running` child (projection guard refuses; result ignored), and still abandons the PARENT (`dispose_park_deadline`, `:2171`). Approval lost. Same root cause mis-terminalizes a raced reject (`route_abandoned` instead of `route_rejected`), and a second-order race exists even in the pending-case branch (`Cases.abandon` refuses `:not_pending`; result ignored → parent still abandoned).
- **P2 (confirmed)** — the actual replay gate still does the unbounded event read O-M1 was meant to remove: `Replay.check_irreversible/4` calls `EventReader.for_run/2` with no `query:` filter (`replay.ex:226`), while `diagnostics.ex:350` already filters to the three step kinds `Safety.irreversible_executed?/1` inspects (`@irreversible_kinds`, `safety.ex:24`).
- **Note (confirmed)** — three test helpers still mint 6-byte `art_` refs instead of routing through `JidoClaw.Refs.mint/1` (O-L2 entropy centralization): `composer_durable_test.exs:1392`, `composer_artifact_test.exs:22`, `reactors/plan_gate_test.exs:113`. No ref-length assertions exist in those files, so the swap is safe.

Fix design for P1 was pressure-tested by a dedicated planning pass against the live code (return shapes, `finish/2` fencing, recovery re-arm, test-harness feasibility); corrections from that pass are baked in below.

**Done criterion: `mise exec -- mix precommit` succeeds.**

## Fix 1 — P1: reload-first, outcome-checked park-deadline disposal

All in `lib/jido_claw/route_composer/route_composer.ex` (sensitive-park deadline section, ~`:2116-2208`).

Restructure `dispose_park_deadline/3` to branch on the child's durable status FIRST, and respect the fenced primitives' refusals:

```elixir
defp dispose_park_deadline(state, child_run_id, case_id) do
  case WorkflowRun.by_id(child_run_id, tenant: state.tenant, actor: state.actor) do
    {:ok, %WorkflowRun{status: :awaiting_approval}} ->
      abandon_parked_child(state, child_run_id, case_id)   # genuinely parked — deadline stands

    {:ok, %WorkflowRun{}} ->
      # A decision won the mailbox race (approve → :running/:completed,
      # reject → :cancelled, abandon → :abandoned): the fire is STALE —
      # route through the normal gate-resolution path, never bulldoze the parent.
      resolve_parked_gate(state)

    other ->
      # Read blip at the deadline: the sensitive-retention TTL wins — parent
      # still terminalizes (documented best-effort; child cleanup skipped + warned).
      finish({:abandoned, {:child_abandoned, child_run_id}}, clear_park(state))
  end
end
```

- `abandon_parked_child/3` = today's `terminalize_deadline_child` body (pending case → `Cases.abandon`; case-less → `append_child_abandoned`) **but outcome-checked**: `{:ok, _}` → `finish({:abandoned, …}, clear_park(state))`; `{:error, _}` (the FOR-UPDATE fence / projection guard refused — a decision raced in after our reload) → re-reload the child once: no longer `:awaiting_approval` → `resolve_parked_gate(state)`; still `:awaiting_approval` (genuine blip) → warn + `finish(:abandoned)` (TTL wins, unchanged best-effort semantics).
- **Normalize `append_child_abandoned/2` returns** (`:2192`): success arm already yields `WorkflowLog.append`'s `{:ok, event}`; illegal transition yields `{:error, _}` (rolled back, not a raise); but the reload-failed arm currently returns `Logger.warning`'s bare `:ok` — return a tuple (e.g. `{:error, {:child_reload_failed, other}}`) or the outcome `case` will `CaseClauseError`.
- **Keep it flat** (credo `max_nesting: 3`): one `case` per function, pattern-matched helper heads for the outcome/re-reload branches — mirror `resolve_parked_gate`'s style. Pass the **un-cleared** state to `resolve_parked_gate` (its fold/terminalize paths destructure `%{parked: park}` and each runs `clear_park` themselves — verified `:2046`, `:2096-2106`).
- Return shapes are already handle_info-proven: the `{:gate_resolved, …}` handler (`:1135`) returns `resolve_parked_gate(state)` directly, including `{:noreply, _, {:continue, :tick}}`. `finish/2` is fenced and safe (already-terminal parent → no double-write; fenced append → logged, `{:stop, :normal, _}`). Recovery re-park (`resolve_recovered_gate` → `arm_park_deadline`) is untouched; stale fires stay guarded by `park_deadline_match?` (fresh `deadline_ref` per re-arm).
- Update the handler comment block (`:2155-2181`) — "no pending case" no longer implies "case-less park".
- `case_id` stays in the message tuple (avoids churn across 4 test send-sites); it remains unused by lookup (pending is keyed by `child_run_id`).

**Deadline semantics for a delayed timer (decided — document explicitly in the handler comment + O-M2 section comment):** the deadline is a hard bound on the **run**, not a retroactive invalidator of committed gate decisions. A decision that durably committed before the timer message is processed wins the *gate* (fold/reject path); the *run* still terminates at the very next tick, because the tick loop's `over_budget?/1` (`:3384`) includes `past_deadline?` and `budget_reason/1` (`:3402`) yields `{:deadline, deadline_at_ms}` — so the retention bound holds to within one fold. Retroactively discarding a committed approval (comparing the decision event timestamp to `deadline_at_ms`) is rejected by design: it would abandon a parent whose approved child is legitimately running/resuming (the C-H1 orphan shape) and mix timestamp authorities, buying only one tick of earlier termination.

### Tests — `test/jido_claw/route_composer/composer_durable_test.exs`, describe "sensitive-park deadline (O-M2)" (`:1171`)

**Harness trap (from the validation pass):** `parked_deadline_state/5` builds state via `loop_state/3`, which defaults `catalog: TestFixtures.phase1_catalog()` — that catalog has **no `"plan-gate"` key**, so any decided-child path (`Map.fetch!(state.catalog, hd(park.dispatch))` at `:2086`; fold path `:1375`/`:1402`) raises `KeyError`. The new race tests must thread `catalog: TestFixtures.gate_fixture_catalog()` (+ matching seed `live:`/`artifacts:`) into the state — extend `parked_deadline_state` with a catalog parameter or build via `loop_state` opts directly.

New tests (crafted children carry a dummy checkpoint via `WorkflowRun.set_checkpoint` in `craft_gate_child`, so `guard_resumable` passes but real resume would crash — craft decisions durably instead of `Cases.decide(:approve)` with resume):

1. **Approve-raced (THE P1 case)**: craft gate child + case; simulate a committed approval decided-to-completion — `AgentCase.approve(gate, %{}, tenant:, actor:)` + `append_event(child, :approval_resolved, %{agent_case_id: gate.id, decision: :approve})` + drive to `:completed` via `append_event(child, :run_completed, %{result: envelope})` where the envelope matches the real plan-gate shape: `%{"wave_index" => 0, "emissions" => [%{"stage" => "plan-gate", "signals" => ["plan-approved"], "artifacts" => %{"approved-plan" => plan_ref}}]}` with `plan_ref` stored via `ComposerArtifact.store_wave_artifact` (the `commit_wave0/3` pattern, `fixtures.ex:878`). Deliver the stale `{:park_deadline, ref, child.id, gate.id}`. Assert `{:noreply, next, {:continue, :tick}}`, `refute :route_abandoned in kinds(parent)`, `:wave_resumed in kinds(parent)`, child stays `:completed`. (Do NOT leave the child `:running` — `observe_then_resolve` would poll to `wave_timeout_ms` and finish `route_failed`.) **Then assert the run-level backstop**: drive the returned state through the tick (`RouteComposer.handle_continue(:tick, next)`, same direct-callback style the suite already uses for `handle_info`) and assert the parent terminalizes via the deadline budget path (`over_budget?` → `budget_reason` `{:deadline, _}` — the budget terminal, not `route_abandoned`), proving the documented semantics: gate decision honored, run still bounded.
2. **Reject-raced**: `Cases.decide(gate.id, :reject, %{}, tenant:, actor:)` works directly on crafted children (reject never resumes) → child `:cancelled`. Deliver the stale deadline. With `gate_fixture_catalog` the plan-gate publishes `plan-rejected` but nothing subscribes it, so no replan: assert parent `route_rejected` / `result["disposition"] == "rejected"` — **not** `route_abandoned` — and child stays `:cancelled` (no `run_abandoned` after `run_cancelled`).
3. Existing four deadline tests stay green unchanged (they exercise only the still-`:awaiting_approval` and stale-ref paths, which never read `state.catalog`).

## Fix 2 — P2: kind-filter the replay gate read, single-source the kinds

- `lib/jido_claw/orchestration/replay/safety.ex`: expose the existing private `@irreversible_kinds [:step_started, :step_completed, :step_failed]` as public `irreversible_kinds/0` (with `@doc`/`@spec` — credo strict requires specs) so the gate and the preflight cannot drift (the module's own stated purpose).
- `lib/jido_claw/orchestration/replay.ex` `check_irreversible/4` (`:226`): add `query: [filter: [kind: [in: Safety.irreversible_kinds()]]]` to the `EventReader.for_run` call, mirroring the O-M1 comment from diagnostics (bounded by step count; no `kind` index — the win is fewer rows decoded/folded).
- `lib/jido_claw/orchestration/replay/diagnostics.ex` (`:350`): replace the literal kind list with `Safety.irreversible_kinds()`.
- Behavior-preserving (the filter only excludes events `irreversible_step?/1` already returns `false` for): the existing `replay_test.exs` "irreversible gate" describe (`:208` — refusal + `allow_irreversible: true` override) proves the boolean behavior.
- **New regression test for the bounded-read CONTRACT** (behavior tests won't fail if someone later drops the `query:`): the reader is swappable — `EventReader.for_run` resolves `Application.get_env(:jido_claw, :replay_event_reader, &WorkflowEvent.for_run/2)` per call (`event_reader.ex:43`), and `test/support/replay_fixtures.ex:69-78` is the existing install/restore precedent. In `replay_test.exs`: install a capturing reader `fn run_id, opts -> send(test_pid, {:reader_opts, run_id, opts}); {:error, :injected} end` (the error return makes replay refuse `{:not_replayable, :irreversible_check_failed}` deterministically — no launch), drive a replay with `allow_irreversible` unset, then `assert_receive {:reader_opts, _, opts}` and assert `opts[:query][:filter] == [kind: [in: Safety.irreversible_kinds()]]`. Follow the fixture's prior-env restore pattern (app-env mutation — keep it in the non-async replay suite alongside the existing failure-injection tests).

## Fix 3 — test-ref hygiene: route the three lagging 6-byte mints through `JidoClaw.Refs.mint/1`

Replace `"art_" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)` with `JidoClaw.Refs.mint("art_")` (the established fully-qualified idiom, as in `commit_test.exs:18`):

- `test/jido_claw/route_composer/composer_durable_test.exs:1392` (`generate_ref/0`)
- `test/jido_claw/orchestration/composer_artifact_test.exs:22` (`ref/0`)
- `test/jido_claw/orchestration/reactors/plan_gate_test.exs:113` (`gen_ref/0`)

## Verification

Run bare, never piped (exit code must surface); background the long ones and read the output tail:

1. Targeted suites first:
   - `mise exec -- mix test test/jido_claw/route_composer/composer_durable_test.exs` (deadline describe + full file)
   - `mise exec -- mix test test/jido_claw/orchestration/replay_test.exs test/jido_claw/orchestration/replay/diagnostics_test.exs`
   - `mise exec -- mix test test/jido_claw/orchestration/composer_artifact_test.exs test/jido_claw/orchestration/reactors/plan_gate_test.exs`
2. **`mise exec -- mix precommit`** (format, compile_check, credo --strict, dialyzer, reach/ExSlop, tests) — the done criterion.
3. Known flaky async:false singletons (MCPServer, Prompt, PipelineStore, MultiSandbox): re-verify any failure in ISOLATION before blaming these changes.

## Commit slicing (user stages and commits, per git policy)

1. `fix: close the park-deadline vs gate-decision mailbox race in the route composer` — `lib/jido_claw/route_composer/route_composer.ex`, `test/jido_claw/route_composer/composer_durable_test.exs` (+ `test/support/jido_claw/route_composer/fixtures.ex` only if the catalog threading needs a helper tweak)
2. `fix: kind-filter the replay irreversible-gate read (O-M1 completion); 12-byte test ref mints` — `lib/jido_claw/orchestration/replay.ex`, `lib/jido_claw/orchestration/replay/safety.ex`, `lib/jido_claw/orchestration/replay/diagnostics.ex`, the three test files from Fix 3

## Out of scope

- The dropped-`case_id` cleanup in the `:park_deadline` message tuple (optional churn).
- Everything already tracked in the parent plan's out-of-scope list (WS6 harness, per-step idempotency keys, etc.).
