# AR-2 Composer Phase 4 — CONTROL-FLOW slice (park / wake / reject-abandon / retraction / recovery)

Design for how the composer loop parks on a gate, wakes on the operator decision, folds the
outcome, handles reject/abandon/retraction, and recovers from a crash while parked. This is the
**control** slice; the **data** slice (the gate-wave producer that makes a wave return
`{:ok, {:paused, case_id}, run}`) is a hard prerequisite and is treated as an assumed contract —
see "Prerequisite" below.

All `path:line` are verified against the working tree.

---

## 0. The prerequisite that bounds this whole design (FLAG — scope boundary)

The control side assumes a **gate wave** exists whose `ReactorRunner.run/3` returns
`{:ok, {:paused, case_id}, run}` with the child `:awaiting_approval`. That contract is real and
shipped at the runner level — `ReactorRunner.handle_gate_pause/3` returns exactly that envelope
(`reactor_runner.ex:676`) after persisting the checkpoint, and `GateResume.resume/2` returns the
same shape on a re-pause. BUT the composer cannot **produce** such a wave today:

- `WaveBuilder.validate_units/1` (`wave_builder.ex:45-50`) REJECTS any non-`{:worker_template,_}`
  unit; a `{:gate,_}` unit returns `{:error, {:unsupported_unit, name, unit}}`.
- There is no `{:gate, "plan"}` → reactor-module resolution anywhere (grep: none), no
  `Reactors.PlanGate` module, and `WaveCollect` only maps worker `%StepResult{}` emissions
  (`wave_collect.ex:71-76`).
- The starter catalog already DESCRIBES the gate: `"plan-gate" => %Stage{unit: {:gate, "plan"},
  subscribes: ["plan-ready"], output: ["approved-plan"], publishes: ["plan-approved", ...]}`
  (`catalog.ex:71-79`), and the `implementer` is held by `lock: [%{while: "plan-ready", until:
  "plan-approved"}]` (`catalog.ex:99-102`). The existing passing loop test
  (`composer_loop_test.exs:131-160`) confirms the gap directly: against the REAL catalog the run
  ends `:failed` with `reason == {:unsupported_unit, "plan-gate", {:gate, "plan"}}`; the
  "converges clean" test (`:163-211`) instead uses a **worker stand-in** named `"approver"` that
  emits `signals: ["plan-approved"]` + `approved-plan` (fixture `phase1_stub_outputs`,
  `fixtures.ex:259-264`).

So Phase 4's **data slice** must, before any control wiring runs end-to-end:
(a) add `Reactors.PlanGate` under `JidoClaw.Orchestration.Reactors.*` (GateStep + a downstream
    idempotent emit step that reads `context[:approval]` and returns the `%StageEmission{}` shape
    `signals: ["plan-approved"]`, `artifacts: %{"approved-plan" => ref}`) — exactly §9
    (`AR-2-COMPOSER-PLAN.md:806-820`);
(b) teach `WaveBuilder` to build a **single-gate wave** from a `{:gate, name}` stage by resolving
    the module and wiring its reactor (the §9 "the gate-producer runs as a wave" rule;
    `AR-2-COMPOSER-PLAN.md:798-801`), keyed so the checkpoint's `reactor_module` is the named
    module (required by `safe_encode_checkpoint`'s `Keyword.fetch!(:reactor_module)`,
    `reactor_runner.ex:698`, and `GateResume`'s `@allowed_module_prefix` fence,
    `gate_resume.ex:84`).

**The control-side design below is written against that contract** and is correct the moment the
data slice lands. Where the control logic can be unit-tested without the real gate wave (by
driving `handle_wave_result`/`handle_info` directly with a synthesized `{:ok, {:paused, …}, run}`
and a stub `AgentCase`/child run), I note it. **This split mirrors how Phase 2c shipped the
vocabulary with no producers** (`workflow_event.ex:118-148`, `projection.ex:107-110`).

---

## 1. Park-via-`{:noreply}` vs the full Task rearchitecture — RECOMMENDATION

**Recommendation: park-via-`{:noreply}` + `handle_info` is sufficient. Do NOT do the Task
rearchitecture for Phase 4.** Argued:

The composer moduledoc (`route_composer.ex:90-93`) says "Phase 4 moves wave execution to a `Task`
+ `handle_info` so the GenServer stays live across a gate park." That framing presumes wave
execution **blocks for a long time** at the gate. It does not. A gate wave's reactor is
`PrepareStep`(none today) + `GateStep`, and `GateStep.run/3` does exactly one fast DB transaction
(`WorkflowLog.gate_open/3`) then returns `{:halt, agent_case_id}` (`gate_step.ex:62-68`) — **no
LLM, no subagent, no long I/O**. `Reactor.run` returns `{:halted, reactor}` promptly;
`ReactorRunner.finalize/3`'s halt clause persists the checkpoint and returns `{:ok, {:paused,
case_id}, run}` (`reactor_runner.ex:649-676`). So the synchronous `run_reactor` (`:1142-1163`)
call **returns within a wave-build + two-DB-write window**, not a human-decision window.

Therefore the composer can park simply by **not continuing**: the gate-pause clause of
`handle_wave_result` returns `{:noreply, parked_state}` (no `{:continue, :tick}`, no `finish`).
The GenServer is then idle and live, able to receive the `{:gate_resolved, …}` `handle_info`.
The "stays live across a gate park" property is achieved without moving execution off-process,
because nothing is executing during the park — by construction (§6: "the suspended composer
GenServer is alive and heartbeating even while the loop waits", `AR-2-COMPOSER-PLAN.md:894`; §4:
"records the block (`wave_paused`, parent `:running`), suspends", `AR-2-COMPOSER-PLAN.md:62-63`).

The Task rearchitecture would only be needed if a **worker** wave (a long LLM wave) had to be
interruptible while parked — but worker waves don't park, only gate waves do, and gate waves are
fast. The §14 Phase 4 done-when (`AR-2-COMPOSER-PLAN.md:1043-1049`) never mentions concurrency; it
is entirely about park/resume/reject/abandon/retract semantics, all of which `{:noreply}` +
`handle_info` deliver.

**Caveat to flag:** during the (short) synchronous gate-wave run the GenServer is briefly
unresponsive to a concurrent `{:gate_resolved}` — but that broadcast cannot land until the gate's
`AgentCase` exists, which is created *inside* that same synchronous run (`GateStep` →
`gate_open`), and a decision cannot be made until the operator sees the case. So there is no real
race: by the time any `{:gate_resolved}` can be sent, `run_reactor` has already returned and the
park clause has run. (Recovery + the dedupe-hit machinery cover the degenerate
decided-during-the-window case anyway — §4d.)

I therefore recommend **updating the moduledoc** (`:90-93`) to state the park mechanism is
`{:noreply}` + `handle_info`, not a Task — the current text mis-describes the chosen design.

---

## Sub-phase 4b — Park, wake, approve (the happy path)

### 4b.1 — State: add a `parked` field

`init/1` builds the state map (`route_composer.ex:831-864`). Add one field:

```
parked: nil   # nil when running; else %{wave_index:, case_id:, child_run_id:, dispatch:, display:}
```

- `wave_index` / `case_id` / `child_run_id` are the durable identity of the park.
- `dispatch` (the cohort stage list) and `display` (the merged route) are carried so the wake path
  can call `record_wave/6` / `finish_failed/5` with the same arguments the park clause had —
  matching how every other wave-handling helper threads `dispatch, display` (e.g.
  `handle_wave_value/5` `:1102`, `observe_existing_child/4` `:1337`). They are in-memory only (the
  durable `wave_paused` carries the identity triple — §4d).

`parked` is NOT projected from the log by `ComposerProjection.project/2` — it is reconstructed at
restart from the durable `wave_paused`/decision events (§4d), exactly as `prev_route`/`wave_index`
are reconstructed today. The `summary/3` (`:1492-1504`) and history machinery are untouched.

### 4b.2 — The missing `{:ok, {:paused, case_id}, run}` clause of `handle_wave_result`

Today `handle_wave_result/4` has three heads (`:1049`, `:1086`, `:1092`). A gate pause currently
falls into the generic `{:ok, value, run}` head (`:1086`) → `decode_emissions({:paused, case_id})`
→ the catch-all `{:error, {:bad_wave_return, _}}` (`:1172`) → `finish_failed`. That is the bug:
a legitimate park is mis-terminated as a failed wave.

**Add a new clause BEFORE the generic `{:ok, value, run}` head** (`:1086`) — ordering is
load-bearing, the existing-run dedupe clause (`:1049`) already relies on clause order, and
`{:ok, {:paused, _}, _}` would otherwise match the generic head:

```
defp handle_wave_result({:ok, {:paused, case_id}, run}, dispatch, display, state) do
  park_on_gate(case_id, run, dispatch, display, state)
end
```

`park_on_gate/5` does, in order:

1. **Ensure gates subscription.** Subscribe to `RunPubSub.subscribe_gates()` (the "orchestration:gates"
   topic, `run_pubsub.ex:34-37`). **WHEN: on first park, idempotently — not at init.** Rationale:
   - Subscribing at `init/1` would have every supervised composer (including ones that never reach
     a gate) listening to the global gates topic for the whole route, receiving and discarding
     every other run's `{:gate_requested}`/`{:gate_resolved}` — needless fan-out.
   - Subscribing on first park is exactly when the composer needs it. Phoenix.PubSub `subscribe/2`
     is idempotent per-process per-topic, but a re-park after a retract (§4c.3) would call it again
     — so guard with a `subscribed_gates: false` boolean in state flipped on first subscribe, or
     rely on PubSub's de-dup (it tolerates a double subscribe but a tracking boolean is cleaner and
     testable). Recommend the boolean.
   - **UNSURE — verify:** Phoenix.PubSub delivers to the subscribed PID; the composer's PID is the
     GenServer. Confirm the GenServer process itself calls `subscribe_gates()` (so messages arrive
     as `handle_info`), not a child task. It does — `park_on_gate` runs in the GenServer callback.

2. **Append `wave_paused` durably (the missing producer).** This is the first `wave_paused`
   producer in the codebase (projection folds it as a no-op, `projection.ex:109`; no producer
   exists — grep confirms). Payload (§4d specifies it must carry the identity for restart
   re-derivation):
   ```
   %{wave_index: state.wave_index, agent_case_id: case_id, child_run_id: run.id}
   ```
   Append via the parent-terminal-guarded path. `wave_paused` is a **non-status-authority**
   composer delta (`workflow_event.ex:132`, not in `@status_authority_kinds`
   `workflow_event/projection.ex:53-63`), so the parent stays `:running` — but it can still land
   on an already-terminal parent (e.g. a between-wave cancel), so it MUST go through the same
   FOR-UPDATE fence the other markers use. **Reuse `Commit.start_wave/3`** (`commit.ex:101-109`),
   which appends an ordered `[{kind, payload}]` under the parent-terminal guard:
   ```
   Commit.start_wave(state.parent, [wave_paused: wave_paused_payload(...)], auth_opts(state))
   ```
   Branch its return exactly like `record_wave_start/3` does (`:1230-1234`):
   - `:ok` → proceed to step 3;
   - `{:error, :parent_terminal}` → `{:stop, :normal, state}` (the run already ended — e.g. an
     operator abandoned/cancelled the parent between `wave_started` and the pause; do not park);
   - `{:error, reason}` → `finish_failed({:wave_pause_append_failed, reason}, run, dispatch,
     display, state)` (a durable write we depend on for restart re-derivation failed — fail the
     wave rather than park into an unrecoverable state).

   **NOTE — do NOT re-append `route_composed`/`wave_started`.** `record_wave_start/3` already
   appended both BEFORE `run_reactor` (`run_built_wave/5` `:1023-1029` → `record_wave_start`
   `:1026`). The gate-pause clause is reached *after* that. So `wave_paused` is the ONLY pre-park
   durable write; on resume we likewise do NOT re-append the start markers (§4b.4).

3. **Store the parked context + return `{:noreply}`:**
   ```
   parked = %{wave_index: state.wave_index, case_id: case_id, child_run_id: run.id,
              dispatch: dispatch, display: display}
   {:noreply, %{state | parked: parked, subscribed_gates: true}}
   ```
   No `{:continue, :tick}` (would re-dispatch the gate), no `finish` (the run is live, not
   terminal). The composer is now an idle, subscribed, live GenServer.

   **`wave_index` is NOT advanced here.** `record_wave/6` (which bumps `wave_index`) runs only on
   the *resume* path when the wave completes (§4b.4). A parked wave is in-flight, not done — its
   `wave_completed`/history entry land on resolution. This keeps the `wave_index ==
   length(history)` invariant (`:1183`) intact across the park.

### 4b.3 — `handle_info({:gate_resolved, run_id, info}, state)` — the wake

Add a new `handle_info` head (the composer has only `:rebuild_retry` today, `:894`). The gates
topic carries BOTH `{:gate_requested, …}` and `{:gate_resolved, …}` (`run_pubsub.ex:28-37`), and
the composer is subscribed globally, so it will receive resolutions for OTHER runs too. Guard
hard:

```
def handle_info({:gate_resolved, run_id, _info}, %{parked: %{child_run_id: cid}} = state)
    when run_id == cid do
  wake_on_resolution(state)
end

# Not parked, or a resolution for a different run's child → ignore.
def handle_info({:gate_resolved, _run_id, _info}, state), do: {:noreply, state}
def handle_info({:gate_requested, _run_id, _info}, state), do: {:noreply, state}
```

**Ignore by `child_run_id`, never by the broadcast's `decision`.** The broadcast payload carries
`%{tenant_id, agent_case_id, decision}` (`cases.ex:628-633`); we deliberately do NOT trust
`info.decision`. (We *may* also assert `info.agent_case_id == state.parked.case_id` as
defence-in-depth, since one run has one gate this slice — `agent_case.ex:34-37` "single gate per
run" — but `run_id == child_run_id` is the load-bearing fence.)

`wake_on_resolution/1` is the heart of the broadcast-vs-resume-race handling. It **reloads the
child run and branches on STATUS, not on the broadcast** (the §9 step-4 invariant,
`AR-2-COMPOSER-PLAN.md:833-840`):

```
defp wake_on_resolution(%{parked: parked} = state) do
  %{child_run_id: cid, dispatch: dispatch, display: display} = parked
  # state.parked is consumed by the branches; clear it as we transition out of "parked".
  case WorkflowRun.by_id(cid, tenant: state.tenant, actor: state.actor) do
    {:ok, %WorkflowRun{} = child} -> branch_resolved_child(child, dispatch, display, state)
    {:ok, nil}     -> finish_failed({:gate_child_missing, cid}, nil, dispatch, display, %{state | parked: nil})
    {:error, reason} -> finish_failed({:gate_child_reload_failed, reason}, nil, dispatch, display, %{state | parked: nil})
  end
end
```

`branch_resolved_child/4` — the four status branches (mirroring the dedupe-hit clause `:1050-1080`
and `observe_existing_child` `:1337-1354`):

- **`:completed`** (approve resolved AND resumed — the gate child re-ran, its downstream emit step
  emitted `plan-approved` + `approved-plan`, and `run_completed` landed):
  → append `wave_resumed` (the missing producer, §4b.4), then fold the gate emission via the
  EXISTING completed-wave path:
  ```
  handle_wave_value(decode_emissions(child.result), child, dispatch, display, %{state | parked: nil})
  ```
  `decode_emissions/1` (`:1168`) reads `child.result["emissions"]` — the gate reactor's downstream
  step returns the same `WaveCollect`-shaped map a worker wave does (§9 contract,
  `AR-2-COMPOSER-PLAN.md:811-813`), so this path is byte-identical to a worker wave's fold:
  `Fold.fold` unions `plan-approved` into `live` and stores the `approved-plan` ref;
  `Commit.commit_wave/4` (`commit.ex:82-89`) writes `wave_completed` + `signals_published` +
  `artifacts_produced` atomically; `record_wave/6` bumps `wave_index` and appends history; then
  `{:noreply, next, {:continue, :tick}}` (`handle_wave_value` `:1108-1109`). **The next
  `compose_route` is what releases the held implementer** — `plan-approved` is now live, so the
  implementer's `lock: %{while: "plan-ready", until: "plan-approved"}` (`catalog.ex:99-102`) is no
  longer active, `Router.active_locks/2` (`router.ex:194-198`) drops it from `held`, and
  `dispatch_cohort` returns the implementer. (See the `wave_resumed`-ordering note in 4b.4 —
  `wave_resumed` is appended just before re-entering `handle_wave_value`.)

- **`:running` / `:pending` / `:awaiting_approval`** (the broadcast arrived but resume is not yet
  done — the §9 step-4 race: `Cases.decide` APPROVE broadcasts BEFORE `finalize_approve →
  GateResume.resume`, `cases.ex:281-284`; OR a re-park after a retract whose new gate is still
  open): the child is not yet `:completed`. **Reuse the dedupe-hit observe machinery** — call
  `observe_existing_child/4` (`:1337`), which bounded-polls (`poll_existing_child/3` `:1360`,
  `@observe_poll_ms` 50ms up to `wave_timeout_ms`) until the child reaches a terminal, then
  re-branches: `:completed` → fold (the resume finished while we polled); any other terminal or
  timeout → `finish_failed`. **BUT** `observe_existing_child`'s non-completed terminal arm
  currently treats `:cancelled`/`:abandoned` as `{:existing_run_not_completed, status}` failures
  (`:1342-1349`) — which is WRONG for a gate (a reject IS `:cancelled`, an abandon IS
  `:abandoned`, and those must drive the `route_rejected`/`route_abandoned` disposition terminals,
  not a generic `route_failed`). So §4c.4 specifies a small refactor of the
  poll-then-terminal-classification so reject/abandon route to the disposition path, shared by both
  the live wake and the dedupe-hit. Pass `%{state | parked: nil}`.

  **Why poll at all on approve, given §9 says fold from `:completed`?** Because the broadcast can
  legitimately land while resume is mid-flight (`GateResume.resume` runs the downstream reactor
  synchronously inside `finalize_approve`, `cases.ex:569-574`, which can take a beat). Polling the
  child to `:completed` is exactly "key on the gate child's `:completed` status (the §5
  status-branch — `:running` → observe/await, `:completed` → fold)" (`AR-2-COMPOSER-PLAN.md:838-840`).
  The poll is read-only and bounded; on a slow resume it converges to the `:completed` fold.

- **`:cancelled`** (reject — `Cases.reject` committed `run_cancelled` and reloaded the child to
  `:cancelled` BEFORE broadcasting, `cases.ex:291-296`, so the child is already terminal when the
  broadcast lands): → §4c (fold `plan-rejected`, then `finish({:rejected, …})`).

- **`:abandoned`** (abandon — `Cases.abandon` committed `run_abandoned` and reloaded BEFORE
  broadcasting, `cases.ex:178-198`): → §4c (fold `plan-abandoned`, then `finish({:abandoned, …})`).

### 4b.4 — `wave_resumed` producer + the no-double-append rule

`wave_resumed` (folds as a no-op, `projection.ex:110`; no producer — grep confirms) is the second
missing producer. Append it on the **`:completed` approve branch only**, just before re-entering
`handle_wave_value`. Payload:
```
%{wave_index: state.parked.wave_index, agent_case_id: state.parked.case_id, child_run_id: child.id}
```

**Ordering / atomicity question (UNSURE — decide):** `wave_resumed` is provenance-only (no routing
effect). Two options:
- **(A) Append `wave_resumed` separately via `Commit.start_wave/3` BEFORE `handle_wave_value`**,
  branching its return like §4b.2 (`:parent_terminal` → `{:stop, :normal}`; error → `finish_failed`).
  Then `handle_wave_value` independently appends `wave_completed` + content via `commit_wave`.
  Simpler; two transactions; a crash between them leaves `wave_resumed` without `wave_completed`
  (harmless — both are no-op folds / the dedupe-hit re-derives on restart).
- **(B) Fold `wave_resumed` INTO the `commit_wave` transaction** by extending `Commit.do_commit/4`
  (`commit.ex:138-150`) to optionally prepend a `wave_resumed` marker. One atomic transaction;
  requires threading a flag/extra-marker into `commit_wave/4`'s `deltas` or a new arg.

  **Recommend (A)** for this slice — it is the minimal change, reuses `start_wave/3` unmodified,
  and `wave_resumed` being a no-op fold means the non-atomicity is immaterial to projection
  equivalence (a restart re-derives the completed wave from `wave_completed`, and `wave_resumed`
  carries no state). Flag (B) as a tidy-up if the audit story wants strict atomicity.

**The no-re-append rule (load-bearing):** on resume we do NOT re-append `route_composed` /
`wave_started` — `record_wave_start/3` appended them before the park (§4b.2). The resume path's
only NEW durable writes are `wave_resumed` (this section) + the `wave_completed`/content that
`handle_wave_value → commit_wave` writes for the FIRST time (the parked wave never wrote them —
§4b.2 step 3 deliberately deferred `record_wave`). So the durable log for a gated wave is:
`route_composed` → `wave_started` → `wave_paused` → `wave_resumed` → `wave_completed` +
`signals_published`(`plan-approved`) + `artifacts_produced`(`approved-plan`). The projection folds
this to exactly the same `live`/`ran`/`artifacts`/`wave_index` a worker `approver` wave produces
(the `wave_paused`/`wave_resumed` no-ops drop out) — preserving the §6 equivalence invariant
(`projection.ex:17-26`).

### 4b.5 — Race conditions closed in 4b

| Race | How closed |
|---|---|
| Approve broadcast lands before `GateResume` finishes (child still `:running`) | Branch on STATUS not broadcast; `:running`→`observe_existing_child` bounded-poll to `:completed` then fold. Folding the broadcast would release the implementer against an unwritten `plan-approved` (§9 step 4, `AR-2-COMPOSER-PLAN.md:833-837`). |
| A `{:gate_resolved}` for a DIFFERENT run's child (global topic) | `when run_id == cid` guard; non-matching head returns `{:noreply, state}`. |
| Decision committed during the brief synchronous gate-wave run (before we parked) | Can't happen: the `AgentCase` is created *inside* that run (`GateStep`→`gate_open`), and a decision needs the operator to see the case — by then `run_reactor` returned and `park_on_gate` ran. Degenerate "decided before subscribe" is caught by 4d (restart re-derivation) and the dedupe-hit. |
| Parent cancelled between `wave_started` and the pause | `wave_paused` via `Commit.start_wave/3` FOR-UPDATE fence → `{:error, :parent_terminal}` → `{:stop, :normal}`; never parks onto a terminal parent (`commit.ex:115-125`). |
| Duplicate `{:gate_resolved}` (PubSub at-least-once / a retract+re-approve) | First wake clears `state.parked`; a second `{:gate_resolved}` then matches the not-parked head → `{:noreply}`. (If the first wake already `{:continue, :tick}`'d and finished, the GenServer has stopped — no second delivery.) |

---

## Sub-phase 4c — Reject / abandon (live coupling) + stale-approval retraction

### 4c.1 — Fold `plan-rejected` / `plan-abandoned`, then the disposition terminal

The gate child carries NO `%StageEmission{}` on reject/abandon (reject cancels the reactor before
the downstream emit step; abandon never resumes — §9 step 5/6, `AR-2-COMPOSER-PLAN.md:843-867`). So
the composer **synthesizes** the rejection/abandon effect itself. On the `:cancelled` / `:abandoned`
branches of `branch_resolved_child/4` (§4b.3):

```
defp branch_resolved_child(%WorkflowRun{status: :cancelled} = child, dispatch, display, state) do
  reject_route(:rejected, "plan-rejected", child, dispatch, display, state)
end
defp branch_resolved_child(%WorkflowRun{status: :abandoned} = child, dispatch, display, state) do
  reject_route(:abandoned, "plan-abandoned", child, dispatch, display, state)
end
```

`reject_route/6` does:
1. **Fold the synthetic signal into `live`** so the held implementer's `until: plan-approved`
   never lands and the route drops. Build a one-emission `%StageEmission{stage: "plan-gate",
   signals: ["plan-rejected" | "plan-abandoned"], artifacts: %{}}` and fold via the SAME
   commit path used for a completed wave — `handle_wave_value({:ok, [emission]}, child, …)` →
   `Fold.fold` + `Commit.commit_wave` (`signals_published: ["plan-rejected"]`) + `record_wave`.
   **BUT** that path ends in `{:continue, :tick}`, whereas reject/abandon must go **terminal**, not
   tick. So do NOT route through `handle_wave_value`'s tail; instead:
   - either (A) fold+commit the synthetic signal, THEN immediately `finish({:rejected, …})`
     (two steps), or
   - (B) skip the durable `signals_published` of `plan-rejected` entirely and go straight to
     `finish` — because the **committed default takes the parent terminal regardless**
     (`AR-2-COMPOSER-PLAN.md:850-854`), the held route drops as a *consequence of the parent
     terminalizing*, NOT because `plan-rejected` re-routes anything.

   **DECISION (FLAG):** §9 says "folds `plan-rejected` into `live`, and applies the rejection
   effect. The committed default takes the parent terminal as `:cancelled`"
   (`AR-2-COMPOSER-PLAN.md:849-853`). The committed default does NOT re-plan, so `plan-rejected`
   in `live` has **no router consumer** in the base catalog (nothing `subscribes:
   ["plan-rejected"]`). So for **base Phase 4, option (B) is correct and minimal**: the parent goes
   terminal on the disposition; folding `plan-rejected` durably is only meaningful for the §15
   re-plan opt-in (a planner subscribing to it). Recommend (B) for base, and note that the §15
   re-plan opt-in would switch to (A) (fold `plan-rejected`, then re-tick instead of finish — see
   §4c.5). This keeps the base path a clean `observe → finish(disposition)`.

2. **Go terminal via the EXISTING `finish/2` disposition path:**
   ```
   finish({:rejected, {:child_cancelled, child.id}}, %{state | parked: nil})
   # or
   finish({:abandoned, {:child_abandoned, child.id}}, %{state | parked: nil})
   ```
   These `{:rejected, _}` / `{:abandoned, _}` terminals are ALREADY fully wired and ALREADY USED —
   but only by the crash-recovery dedupe-hit synthesis today (`handle_wave_result` `:1075-1079`).
   `classify_terminal/1` handles them (`:1488-1489`); `parent_terminal_notify/4` appends
   `route_rejected`/`route_abandoned` with `%{result: %{disposition: "rejected"|"abandoned"}}`
   (`:1447-1457`); `route_cancelled_kind/1` maps them (`:1479-1480`); the status projection lifts
   `route_*` → `:cancelled` + `result.disposition` via `@route_cancelled_kinds` +
   `terminal_lifting_result(:cancelled, …)` (`workflow_event/projection.ex:40,140-141,212-213`).
   **So 4c "wires the LIVE path" by reusing the exact same `finish` calls the crash-synthesis
   already makes** — the live wake and the recovery dedupe-hit converge on identical `finish`
   terminals. No new terminal code.

### 4c.2 — Live ↔ crash-recovery convergence (the reconciliation the prompt asks for)

The dedupe-hit clause `handle_wave_result({:ok, {:existing_run, _id}, run}, …)` already has
`:cancelled → finish({:rejected, {:child_cancelled, run.id}})` and `:abandoned → finish({:abandoned,
{:child_abandoned, run.id}})` (`:1075-1079`). The LIVE wake (`branch_resolved_child`'s
`:cancelled`/`:abandoned` arms, §4c.1) produces the **identical** `finish({:rejected,
{:child_cancelled, child.id}})` / `finish({:abandoned, {:child_abandoned, child.id}})`. So:

- A reject observed **live** (composer was parked, `{:gate_resolved}` arrives) → wake →
  `finish({:rejected, …})`.
- A reject that happened **while the composer was down** (crash-during-park, restart re-dispatches
  the gate wave → dedupe-hit on the now-`:cancelled` child) → `handle_wave_result` `:1075` →
  `finish({:rejected, …})`.

Both land the same `route_rejected` event and the same parent `:cancelled` + disposition. **This
is the single convergence point** — extract a shared helper if desired
(`reject_route/abandon_route` could be called from BOTH the live wake and the dedupe-hit clause),
but it is not required since both already call `finish` with the same tuple. **Recommend
extracting** `terminalize_gate_disposition(status, child_id, state)` and calling it from both
`branch_resolved_child` and the dedupe-hit clause, so the two paths can never drift.

### 4c.3 — Stale-approval retraction (the trigger + the three producers)

This is the §4 "Stale-approval retraction: a `live`-set removal of `plan-approved` on a
pre-implementation re-plan, so the revised plan re-earns it — durably a `signals_retracted` event"
(`AR-2-COMPOSER-PLAN.md:78-80`).

**The mechanism has three coordinated effects:**
1. Retract the stale `plan-approved` from `live` — durably a `signals_retracted` event (the
   PRODUCER). `signals_retracted` is folded as a `live` difference (`projection.ex:89-91`); the
   ONLY producer today is the paired-verdict flip captured by `wave_deltas/3`'s `signals_retracted:
   signals_diff(state.live, next_fold.live)` (`:1269`). A stale-approval retraction needs an
   EXPLICIT `signals_retracted` producer (not a fold diff): append `signals_retracted` with
   `%{signals: ["plan-approved"]}` and remove it from in-memory `live`.
2. Call `Cases.retract/3` on the gate (`cases.ex:216-236`) — flips the `AgentCase` `:approved →
   :pending`, appends `approval_retracted` (`:running → :awaiting_approval`,
   `workflow_event/projection.ex:126`), race-fenced to the pre-resume window (refuses
   `:already_resumed`). This re-opens the gate so the operator must re-decide. The broadcast it
   sends is `{:gate_requested, run.id, …}` (`cases.ex:230-232`) — which the composer ignores
   (§4b.3's `:gate_requested` head).
3. Re-fire the planner + plan-gate so a revised plan is derived and re-gated — durably
   `stages_invalidated` removing them from `ran` (the PRODUCER), folded as a `ran` difference
   (`projection.ex:103-105`); no producer today.

**THE TRIGGER — what live signal drives the re-plan?** The natural signal is `scope-shift`:
- Every stage publishes `scope-shift` (`catalog.ex` — `planner`/`plan-gate`/`implementer`/all
  reviewers, e.g. `:69,78,98,115`); it is the universal "the ask/plan changed scope" signal triage
  and workers emit (`triage/prompt.ex:64` "the ask has shifted scope from the prior turn").
- **CRITICAL FINDING: nothing in the catalog `subscribes` to `scope-shift`** (grep: only
  publishers). So `scope-shift` is currently INERT — it lands in `live` and triggers no stage. The
  retraction trigger is therefore NOT plumbed in the base catalog; wiring it is genuinely new work.

This forces the central scope decision below.

### 4c.4 — Refactor `observe_existing_child` terminal classification (shared by live + recovery)

`observe_existing_child/4` (`:1337-1354`) currently maps any non-`:completed` terminal to
`finish_failed({:existing_run_not_completed, status}, …)` (`:1342-1349`). For a GATE child that is
wrong: `:cancelled`/`:abandoned` must route to the disposition terminal (§4c.1), not a generic
`route_failed`. Change the non-completed arm to re-use `branch_resolved_child`'s terminal
classification:
- `:completed` → fold (unchanged);
- `:cancelled` → `terminalize_gate_disposition(:rejected, child.id, state)`;
- `:abandoned` → `terminalize_gate_disposition(:abandoned, child.id, state)`;
- `:failed` or observe-timeout → `finish_failed` (unchanged — a genuinely failed gate wave, e.g.
  `GateResume` fail-with-audit, IS a route failure).

**UNSURE — verify the blast radius:** `observe_existing_child` is also called by the dedupe-hit
clause for a still-`:running` child on a restart re-dispatch (`:1054-1055`). For a NON-gate worker
wave, a `:cancelled`/`:abandoned` child should still be... actually a worker wave can't be
`:cancelled`/`:abandoned` by an operator gate decision (no gate), so in practice a worker child is
only ever `:completed`/`:failed` there. But to be safe, gate the disposition routing on "this wave
was a gate wave" — which we know from `state.parked` (live path) or from the child carrying an
`approval_*` event (recovery path). **Simplest:** keep `observe_existing_child` generic and have
the GATE callers (the live `:running` wake branch + the recovery re-park) pass a flag or call a
gate-specific `observe_existing_gate_child` variant. Recommend a small `gate?: true`-parameterized
classification so a worker wave's `:cancelled` (which shouldn't happen) still fails loudly while a
gate wave's `:cancelled` becomes the disposition. FLAG this as a point to verify against the
worker-wave dedupe-hit tests.

### 4c.5 — SCOPE DECISION (the trickiest part — FLAG explicitly for the user)

**The tension.** §14 Phase 4 done-when (`AR-2-COMPOSER-PLAN.md:1047-1048`) lists "**resume
re-earns approval on re-plan**" as a done criterion. But:
- §9 step 5 says the reject-driven **re-plan is catalog-opt-in (§15)** — "a planner stage that
  `subscribes: ["plan-rejected"]` is removed from `ran`" (`AR-2-COMPOSER-PLAN.md:854-858`) — and
  the base catalog's planner subscribes to `plan-needed`, not `plan-rejected`/`scope-shift`.
- §15 lists the re-plan as an open decision (`AR-2-COMPOSER-PLAN.md:1063-1065` and the §15 re-plan
  alternative).
- AR-8c says the `stages_invalidated` rerun primitive's "**first real use** is the reverse-verify
  loop … **Depends on Phase 4 (gates) landing first**" (`AR-8c-SYSTEM-PATH.md:13-14,25-27`) —
  i.e. `stages_invalidated`'s first PRODUCER is intended to be AR-8c, AFTER Phase 4, not within it.

**The reconciliation I recommend (minimal vs deferred):**

- **MINIMAL (belongs in base Phase 4) — the RETRACTION PRIMITIVE alone satisfies "re-earns
  approval on re-plan":** "resume re-earns approval on re-plan" is most faithfully read as the
  **stale-approval retraction** (§4 line 78-80, §9's `Cases.retract`), NOT the reject-driven
  re-plan. The done-when verb is "re-earns approval" — which is exactly what retraction forces: a
  recorded `plan-approved` is withdrawn (the `signals_retracted` producer + `Cases.retract`) so the
  gate re-opens `:pending` and the operator must approve again. **This needs only:**
  (1) the `signals_retracted` explicit producer (retract `plan-approved` from `live`);
  (2) `Cases.retract/3` (already exists, `cases.ex:216-236`);
  (3) the gate re-park: after retraction the gate child is `:awaiting_approval` again, so the
      composer must re-park on it (re-subscribe is already done; append a fresh `wave_paused`; wait
      for the next `{:gate_resolved}`). This is the same park machinery (§4b) re-entered.
  The done-when "resume re-earns approval on re-plan" is met: a retracted approval re-parks, and the
  next decision re-runs the gate (`GateResume`) — approval is genuinely re-earned. **No
  `stages_invalidated` producer is required for this** — retraction operates on `live`
  (`plan-approved`), not on `ran` (the planner stays `ran`; only the GATE re-opens).

- **DEFERRED (NOT base Phase 4) — the full re-plan re-fire (the `stages_invalidated` producer +
  the `scope-shift`/`plan-rejected` trigger wiring):** removing `planner`/`plan-gate` from `ran` so
  the route RE-DERIVES a revised plan is the heavier path. It needs: a `stages_invalidated`
  producer, a catalog change (a planner that `subscribes: ["scope-shift"]` or `["plan-rejected"]`),
  AND the §4 oscillation guard + per-stage rerun cap to bound it. AR-8c explicitly claims this
  primitive's first real use is AR-8c (post-Phase-4). So **defer the `stages_invalidated` producer
  and the re-plan trigger to the §15 catalog-opt-in / AR-8c**, and meet the base Phase 4 done-when
  with the retraction primitive alone.

- **WHAT TRIGGERS THE RETRACTION in base Phase 4?** Here is the honest gap: the §4/§9 retraction is
  described as firing "on a pre-implementation re-plan", but the *detector* of "the plan changed
  while the gate was approved-but-not-resumed" is itself part of the re-plan machinery. In the base
  catalog, with no `scope-shift` consumer, **there is no automatic live trigger for retraction
  either.** So strictly, base Phase 4 can ship the **retraction MECHANISM** (the three coordinated
  effects as composer capabilities + the `signals_retracted` producer) and prove it via a
  **driven** test (the same way `Cases` proves retract today: "the live trigger arrives with the
  future plan-gate producer; today the window is opened deliberately via `decide(…, resume:
  false)`", `cases.ex:62-69`). The AUTOMATIC trigger (a `scope-shift` landing in `live` while
  parked-approved → retract) is the §15/AR-8c wiring.

  **RECOMMENDATION to the user (the scope call):** Ship in base Phase 4:
  (i) park/wake/approve (§4b) — fully;
  (ii) reject/abandon disposition terminals (§4c.1–4c.4) — fully;
  (iii) the **retraction mechanism** — the `signals_retracted` explicit producer + the re-park on
       `Cases.retract`-induced `approval_retracted` — proven by a driven test, satisfying "resume
       re-earns approval on re-plan" via retraction;
  (iv) recovery wake-after-gate (§4d) — fully.
  **Defer to §15/AR-8c:** the `stages_invalidated` producer, the `scope-shift`/`plan-rejected`
  catalog trigger that AUTOMATICALLY fires re-plan/retraction, and the oscillation guard + per-stage
  rerun cap (those bound the re-fire, which isn't in base). This matches §9's "catalog-opt-in (§15)"
  and AR-8c's "depends on Phase 4 landing first."

  If the user instead wants the AUTOMATIC re-plan in base Phase 4, that pulls in: a
  `stages_invalidated` producer, a catalog edit (planner subscribes `scope-shift` or
  `plan-rejected`), the oscillation guard (an exact-repeat re-fire is surfaced not retried,
  `AR-2-COMPOSER-PLAN.md:67-68`), and the per-stage rerun cap (`AR-2-COMPOSER-PLAN.md:71-72`) —
  a materially larger slice that overlaps AR-8c's charter. **This is the decision to make.**

### 4c.6 — Oscillation guard (only if the re-fire is in scope)

If (and only if) the re-plan re-fire is pulled into base Phase 4, bound it per §4: a re-fire that
does not change the plan is **surfaced, not retried** (`AR-2-COMPOSER-PLAN.md:67-68`). Mechanism:
compare the new `approved-plan`/plan artifact ref (or a content hash) against the prior generation;
if identical after a re-fire, terminate `route_not_converged`/a dedicated "stalled re-plan"
terminal rather than re-gating again. Plus the deterministic per-stage rerun cap (count of times
`planner` was removed from `ran` via `stages_invalidated`), tracked in state and checked before
each re-fire; hitting it → `finish({:budget_exhausted, {:rerun_cap, "planner"}})` via the existing
`route_budget_exhausted` path (`:1474`). **Defer with the re-fire.**

---

## Sub-phase 4d — Recovery wake-after-gate

### 4d.1 — The gap, precisely

`WorkflowRecovery.resume_composer/1` (`workflow_recovery.ex:319-344`) restarts the supervised
composer via `start_recovered_composer → RouteComposer.ensure_started/2` **only when
`all_children_terminal?/3`** (`:324`). A PARKED gate child is `:awaiting_approval` → non-terminal
(`workflow_event/projection.ex:65,77`), so `all_children_terminal?` is false → the composer is NOT
restarted, the parent is left `:running` for the next boot (`:335-341`, moduledoc `:333-334`: "The
durable wake-after-gate-decision story is Phase 4 gate-in-composer wiring"). That is the gap: a
composer parked on a gate, after a crash, is never re-animated — so a later decision has no live
GenServer to wake.

Note `reconcile_children/3` (`:351-364`) reconciles each non-terminal child through the reactor
branches: a parked `:awaiting_approval` gate child with a pending case hits `reconcile_branch(:parked,
…)` (`:195-216`) → `emit(run, :parked)` no-op (correctly leaves the human in control). So the child
stays parked; the problem is purely that the PARENT composer isn't restarted to listen.

### 4d.2 — The change to `resume_composer/1` / `all_children_terminal?/3`

**Make a composer with a PARKED gate child RESTARTABLE.** A composer whose only non-terminal child
is a legitimately-parked gate (`:awaiting_approval` + pending case + a recorded `wave_paused` in the
parent log) is NOT "mid-wave with an executorless corpse" — it is a valid suspended composer that
must be brought back to life to listen for the decision. The danger
`all_children_terminal?` was guarding against (`:331-334`) — "a restarted composer would
re-dispatch that wave, hit the still-non-terminal child, and `observe_existing_child` would poll the
now-executorless child until `wave_timeout_ms` then fail the parent" — is exactly what the NEW
gate-aware restart path must AVOID by re-deriving "I was parked" from the log instead of
re-dispatching.

Concretely, split the children into (a) **parked gate children** and (b) **other non-terminal
children**, and gate the restart on (b) only:

```
defp resume_composer(run) do
  ...
  handled = reconcile_children(run, tenant, actor)
  cond do
    not non_parked_children_terminal?(run, tenant, actor) ->
      # a genuinely non-terminal NON-gate child (still-running wave, transient blip): leave :running, retry next boot (unchanged behavior)
      Logger.info(...); emit(run, :composer)
    parked_gate_child?(run, tenant, actor) ->
      # the ONLY non-terminal child is a parked gate → restart the composer so it re-parks and listens (NEW)
      start_recovered_composer(run, tenant, actor)
    true ->
      # all children terminal (incl. a decided-while-down gate) → restart (existing path)
      start_recovered_composer(run, tenant, actor)
  end
  handled
end
```

- `non_parked_children_terminal?/3` = the old `all_children_terminal?/3` but ignoring children that
  are `:awaiting_approval` with a pending case (a parked gate). A still-running WORKER child still
  blocks the restart (correct — that's the executorless-corpse danger).
- `parked_gate_child?/3` = at least one child is `:awaiting_approval` with a pending `AgentCase`.

**Why restarting is now SAFE even with the parked child non-terminal:** because the restarted
composer's `init`/`do_rebuild` re-derives "I was parked on wave N, case X" from the durable
`wave_paused` event (§4d.3) and **re-parks WITHOUT re-dispatching the gate wave** — it does NOT
call `run_wave`/`run_reactor` for the parked wave (which would create a second child / poll a
corpse). The §4d.3 re-derivation is what makes the old guard unnecessary for the gate case.

**UNSURE — verify the `reconcile_partitioned` interaction:** `resume_composer` returns `handled`
(the child ids it reconciled) which are excluded from the `others` loop (`:135-146`). A parked gate
child is in `handled` (reconciled by `reconcile_children`), so it won't be double-reconciled.
Confirm a restarted composer that re-parks does not RE-reconcile the child (it doesn't — the
composer reads the log, it doesn't run recovery). OK.

### 4d.3 — How the restarted composer re-derives "I was parked on wave N, case X"

The restarted composer's `init/1` → `do_rebuild/1` (`:896-911`) loads the parent + events and folds
via `ComposerProjection.project/2`. Today the projection folds `wave_paused`/`wave_resumed` as
no-ops (`projection.ex:109-110`) — so the rebuilt state has the right `live`/`ran`/`artifacts`/
`wave_index` but `parked: nil`. We must reconstruct `parked` from the log.

**`wave_paused` MUST carry the identity (this is why §4b.2 specified its payload):**
`%{wave_index:, agent_case_id:, child_run_id:}`. Re-derivation rule (computed AFTER the
projection fold, in `do_rebuild` or a post-fold step):

> Scan the parent's events for the LAST `wave_paused`. If a `wave_resumed`,
> `signals_published`(of the gate's wave), or any parent-terminal event postdates it (by `seq`),
> the park was already resolved/superseded → `parked: nil` (proceed to `:tick` normally). If the
> last `wave_paused` is NOT postdated by a resolution marker, the composer was parked when it
> crashed → reconstruct `parked` from that event's payload and re-enter the park flow.

This is the SAME "latest-relevant-event" discipline `Cases.ensure_not_resumed/3` uses
(`cases.ex:536-558`: find the max `approval_resolved` seq, check for a later `run_resumed`).

Then, **re-park or wake based on the child's CURRENT status** (decided-while-down vs still-parked) —
reusing the §4b/§4c wake path:

```
# in do_rebuild, after project/2:
case derive_park(events) do
  nil ->
    {:noreply, rebuilt, {:continue, :tick}}            # not parked (or already resolved) — normal resume
  %{child_run_id: cid} = parked ->
    re_enter_park(%{rebuilt | parked: parked}, events)
end
```

`re_enter_park/2` reloads the child and branches on status — **identical to `wake_on_resolution`/
`branch_resolved_child` (§4b.3/§4c.1)**:
- `:awaiting_approval` (still parked — the decision hasn't happened): **re-subscribe to gates**
  (set `subscribed_gates: true`, call `subscribe_gates()`), append a FRESH `wave_paused` (so the
  durable log records the re-park; OR skip re-appending since the original `wave_paused` is still
  the latest — **recommend skip**, the original `wave_paused` is sufficient and re-appending would
  bloat the log; the in-memory `parked` is what matters), and `{:noreply, parked_state}` — now a
  live, subscribed, parked composer that a later `{:gate_resolved}` wakes via §4b.3.
- `:completed` (approved + resumed while down) → `wave_resumed` + fold via `handle_wave_value`
  (§4b.3 `:completed` arm) → `{:continue, :tick}`.
- `:cancelled` (rejected while down) → `terminalize_gate_disposition(:rejected, …)` (§4c.1).
- `:abandoned` (abandoned while down) → `terminalize_gate_disposition(:abandoned, …)`.
- `:running`/`:pending` (decided, resume mid-flight at crash — rare) → `observe_existing_child`
  (§4c.4 gate variant).

**This is precisely "Reuse the dedupe-hit machinery":** the decided-while-down branches are the
same `finish`/fold the dedupe-hit clause (`:1050-1080`) and the live wake (§4b/§4c) use. The ONLY
new recovery-specific code is `derive_park/1` (the last-`wave_paused`-not-postdated scan) and the
re-subscribe on the still-`:awaiting_approval` arm.

**Reconcile with the dedupe-hit path (alternative re-derivation — FLAG a choice):** there are TWO
ways a restarted composer could rediscover the parked gate:
- **(P) Park re-derivation from `wave_paused`** (above) — the composer reads `wave_paused`, does NOT
  re-dispatch, re-parks/wakes directly. Clean; no risk of a second child.
- **(D) Dedupe-hit** — let the composer `{:continue, :tick}` normally; the re-tick re-composes the
  same route (the gate wave's `wave_started`/`route_composed` are in the log but the wave never
  wrote `wave_completed`, so `ran` lacks the gate stage → it re-composes the gate cohort),
  re-dispatches `composer:<parent>:<wave_index>` → **dedupe HIT** on the existing parked child →
  `handle_wave_result({:ok, {:existing_run, _}, run}, …)` → its `:awaiting_approval` arm
  (`:1054`) → `observe_existing_child`.
  BUT (D) is WRONG for a still-parked gate: `observe_existing_child` would bounded-POLL the
  `:awaiting_approval` child up to `wave_timeout_ms` and then FAIL (the child won't terminalize
  while the human deliberates) — exactly the corpse-poll the old recovery guard feared
  (`workflow_recovery.ex:331-334`). So the dedupe-hit's `:awaiting_approval` arm must EITHER be
  taught to "re-park instead of poll" when the parent log shows a `wave_paused` for this wave, OR
  recovery must use path (P) and never re-dispatch a parked wave.
  **RECOMMEND (P)** — re-derive from `wave_paused` and re-park directly, never re-dispatch a parked
  wave. It is unambiguous and avoids touching the dedupe-hit's `:awaiting_approval` semantics (which
  exist for the restart-redispatch-of-a-running-WORKER-wave case, `:1046-1047`). As a belt:
  ALSO change the dedupe-hit `:awaiting_approval` arm so that if `derive_park` says this wave is a
  parked gate, it re-parks rather than polls — closing the corner where a re-tick reaches it before
  `re_enter_park`. FLAG: decide whether (P) alone suffices or (P)+the dedupe-hit guard is needed;
  (P) alone is correct IF `do_rebuild` re-enters the park BEFORE any `:tick` — and it does, since
  `re_enter_park` returns `{:noreply, parked_state}` without a `:tick`.

### 4d.4 — Recovery race conditions closed

| Race | How closed |
|---|---|
| Decision lands AFTER recovery reads the child status but BEFORE the composer subscribes | The composer re-subscribes to gates as part of `re_enter_park` (still-`:awaiting_approval` arm) BEFORE returning `{:noreply}`. A decision in the gap is durable on the child; the next boot OR — if the composer is up — the missed `{:gate_resolved}` is recovered because the composer re-reads the child status on the NEXT relevant event... **UNSURE — gap:** a decision landing between the status-read and the subscribe is NOT delivered to this process (it subscribed after the broadcast). MITIGATION: read the child status AGAIN immediately AFTER subscribing (subscribe → re-read → if now terminal, wake directly; if still `:awaiting_approval`, park). This subscribe-then-reread closes the window (the same pattern as a "subscribe before checking" idiom). RECOMMEND adding the post-subscribe re-read. FLAG to verify. |
| Two nodes both restart the composer | The `Registry`-keyed single-owner (`@registry`, `via_tuple/1` `:254`) + `ensure_started/2` collapsing `{:already_started, pid}` (`:574-577`) — a second start is an observe, not a fork (§4 lifecycle, `AR-2-COMPOSER-PLAN.md:84-89`). Recovery is single-node anyway (`owns_recovery?` `:449-453`). |
| Composer restarted, re-parks, but the gate `AgentCase` was deleted while down | `reconcile_branch(:parked, …)` already cancels a parked run whose pending case is missing (`:203-209` → `run_cancelled`), driving the child terminal BEFORE the composer restarts → the composer sees `:cancelled` and terminalizes via the disposition path. (Confirm ordering: `reconcile_children` runs before `start_recovered_composer` in `resume_composer` — yes, `:322` then `:324`.) |
| `wave_paused` written but parent terminal also written (cancel during park) | `derive_park` sees the parent-terminal postdates `wave_paused` → `parked: nil`; and `do_rebuild`'s `{:terminal, _parent}` guard (`:899-900`) stops `:normal` before even folding if the parent is already terminal. |

---

## 5. Summary of every change (file · function/clause · logic · reused code)

**`lib/jido_claw/route_composer/route_composer.ex`** (the bulk):
- `init/1` (`:831-864`): add `parked: nil` + `subscribed_gates: false` to state.
- Moduledoc (`:90-93`): correct "Task + handle_info" → "`{:noreply}` + `handle_info` park".
- NEW `handle_wave_result({:ok, {:paused, case_id}, run}, …)` clause BEFORE `:1086` → `park_on_gate/5`.
  - `park_on_gate/5`: subscribe-once to gates (`RunPubSub.subscribe_gates/0`, `run_pubsub.ex:34`);
    append `wave_paused` via `Commit.start_wave/3` (`commit.ex:101`), branch return like
    `record_wave_start/3` (`:1230-1234`); store `parked`; `{:noreply}`.
- NEW `handle_info({:gate_resolved, run_id, info}, state)` (matching `child_run_id`) → `wake_on_resolution/1`;
  + non-matching `{:gate_resolved}`/`{:gate_requested}` heads → `{:noreply, state}`. (Beside `:894`.)
  - `wake_on_resolution/1`: reload child (`WorkflowRun.by_id`, as `poll_existing_child` `:1361`),
    `branch_resolved_child/4`.
  - `branch_resolved_child/4`: `:completed`→`wave_resumed` (via `start_wave/3`) + `handle_wave_value(decode_emissions(child.result), …)`
    (reuse `:1102`); `:running/:pending/:awaiting_approval`→gate-variant `observe_existing_child` (reuse `:1337`);
    `:cancelled`→`terminalize_gate_disposition(:rejected,…)`; `:abandoned`→`terminalize_gate_disposition(:abandoned,…)`.
  - NEW `terminalize_gate_disposition(status, child_id, state)` → `finish({:rejected|:abandoned, {…, child_id}}, %{state|parked: nil})`
    (reuse the EXISTING `finish` disposition path `:1399`, `:1447-1457`, `:1488-1489`); call from BOTH the live wake AND the dedupe-hit clause `:1075-1079` (convergence).
- `observe_existing_child/4` (`:1337`): parameterize terminal classification so a GATE child's
  `:cancelled`/`:abandoned` → `terminalize_gate_disposition` (§4c.4), worker child unchanged.
- `do_rebuild/1` (`:896`): after `project/2`, call `derive_park/1`; if parked, `re_enter_park/2`
  (re-subscribe + reload child + branch as §4d.3) instead of `{:continue, :tick}`.
  - NEW `derive_park/1`: last `wave_paused` not postdated by a resolution marker →
    `%{wave_index, case_id, child_run_id, …}` (the §4d.3 scan; mirror `ensure_not_resumed/3`
    `cases.ex:536-558`).
- (Optional) extract `reject_route` shared by live + dedupe-hit (§4c.2).

**`lib/jido_claw/orchestration/workflow_recovery.ex`**:
- `resume_composer/1` (`:319-344`): split children into parked-gate vs other-non-terminal; restart
  the composer when the only non-terminal child is a parked gate (§4d.2). Reuse `start_recovered_composer/3` (`:376`).
- `all_children_terminal?/3` (`:369-374`) → `non_parked_children_terminal?/3` + `parked_gate_child?/3`.
- Moduledoc (`:333-334`): the wake-after-gate gap is now closed; update.

**`lib/jido_claw/route_composer/projection.ex`**: NO change to the no-op folds (`:109-110`) — the
park re-derivation reads the raw events, not the folded state. (Confirm `derive_park` gets the raw
`events`, which `do_rebuild` already has, `:902-906`.)

**No change** to: `Commit` (reuse `start_wave/3` + `commit_wave/4` as-is), `Cases` (reuse
`decide`/`reject`/`abandon`/`retract` as-is), `WorkflowEvent` (vocabulary already complete,
`:118-148`), `WorkflowEvent.Projection` (terminals already wired, `:135-141,206-213`), `Fold`,
`Loop`, `Router`, `GateResume`, `ReactorRunner` (the `{:ok, {:paused, …}, run}` contract already
exists, `reactor_runner.ex:676`).

**Retraction producers (scope-gated — §4c.5):**
- `signals_retracted` explicit producer: a composer function that appends `signals_retracted
  %{signals: ["plan-approved"]}` (via `start_wave/3` or a small commit helper) + removes from
  in-memory `live` + calls `Cases.retract/3` + re-parks. Belongs in base Phase 4 (the retraction
  mechanism).
- `stages_invalidated` producer + `scope-shift`/`plan-rejected` catalog trigger + oscillation
  guard + per-stage rerun cap: **DEFER to §15/AR-8c** unless the user pulls the automatic re-plan
  into base Phase 4.

**Data-slice prerequisite (NOT this control design, but required for end-to-end):**
`Reactors.PlanGate` module + `WaveBuilder` single-gate-wave support + `{:gate, name}`→module
resolution (§0).

---

## 6. Every UNSURE point, gathered (what to verify)

1. **Gate subscription PID** — confirm the GenServer process itself calls `subscribe_gates/0` so
   `{:gate_resolved}` arrives as a `handle_info` on the composer (it does — `park_on_gate` runs in
   the GenServer). Verify Phoenix.PubSub double-subscribe tolerance vs the `subscribed_gates`
   boolean guard.
2. **`wave_resumed` atomicity** — (A) separate `start_wave/3` append vs (B) folded into
   `commit_wave`. Recommend (A); verify the non-atomicity is immaterial (it is — no-op fold).
3. **`observe_existing_child` blast radius** — parameterizing its terminal classification for gate
   vs worker; verify the worker-wave dedupe-hit tests still expect `:cancelled`/`:abandoned`→fail
   (a worker child realistically can't be operator-cancelled/abandoned). Gate the disposition
   routing on "is a gate wave."
4. **Recovery re-derivation vs dedupe-hit** — (P) re-derive from `wave_paused` and never
   re-dispatch a parked wave, vs (D) let the dedupe-hit poll. Recommend (P); verify `do_rebuild`
   re-enters the park BEFORE any `:tick`, and decide whether the dedupe-hit `:awaiting_approval`
   arm also needs a "re-park not poll" guard as a belt.
5. **Recovery subscribe-then-reread window** (§4d.4) — a decision landing between the status-read
   and the gates-subscribe is not delivered to this process. Recommend subscribe → re-read child →
   wake-or-park. Verify this closes the window.
6. **`scope-shift` as the retraction/re-plan trigger** — confirmed INERT in the base catalog (no
   subscriber). The automatic trigger is genuinely unplumbed; the scope call (§4c.5) decides
   whether to plumb it in base Phase 4 or defer.
7. **The §14 done-when "resume re-earns approval on re-plan"** — confirm with the user that the
   RETRACTION reading (re-earn via `Cases.retract` + `signals_retracted`) satisfies it for base
   Phase 4, with the `stages_invalidated` re-fire deferred to §15/AR-8c (per §9 "catalog-opt-in"
   and AR-8c "depends on Phase 4 landing first").

---

## Critical Files for Implementation
- /Users/rickdunkin/workspace/claws/jido_radclaw/lib/jido_claw/route_composer/route_composer.ex
- /Users/rickdunkin/workspace/claws/jido_radclaw/lib/jido_claw/orchestration/workflow_recovery.ex
- /Users/rickdunkin/workspace/claws/jido_radclaw/lib/jido_claw/route_composer/commit.ex
- /Users/rickdunkin/workspace/claws/jido_radclaw/lib/jido_claw/orchestration/cases.ex
- /Users/rickdunkin/workspace/claws/jido_radclaw/lib/jido_claw/route_composer/wave_builder.ex
