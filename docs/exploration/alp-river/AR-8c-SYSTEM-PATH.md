# AR-8c — The System Path (verified machine change)

*Architecture direction — extends AR-2 §8 / AR-8. Not a commitment.*

**Status — SHIPPED (2026-06-25; reconciled 2026-07-02).** The system path is live end-to-end:
`triage → planner → safety-gate → system-executor → system-verifier` with the reverse-verify
loop and its own terminal. How the forks resolved:

- **A** — both workers shipped (`system_executor` producer, `system_verifier` judge); the
  verifier fork resolved to **(i) verdict-family** (the recommendation): `lens: "system"` on
  the stage, `clean:system` / `findings:system` driving the shared lens-clean convergence.
- **B** — `Reactors.SafetyGate` + `Gates.SafetyGate` shipped; the kind fork resolved to
  **`:irreversible_write`** (the recommendation — `Kinds.@kinds` unchanged). One deliberate
  deviation from the design below: the gate is **always-on**, subscribing `plan-ready` — not
  triggered by the risk signals — matching the source's "the system path always confirms"; the
  `destructive-op`/`irreversible` topics remain consumer-less in the catalog (the always-on
  gate makes them unnecessary as triggers).
- **The two-gates question folded**: `plan-gate` is now `routes: ["code"]` only — the system
  path runs the **single** safety checkpoint (the skeleton's matured shape), and the executor's
  lock shipped as `%{while: "plan-ready", until: "safety-approved"}` (no `plan-approved` exists
  on the path to subscribe to).
- **C** — the reverse-verify loop shipped as the third `stages_invalidated` consumer (kept on
  its own exact-payload emitter beside the shared `invalidate_stages` helper AR-4 uses).
- **D** — resolved to **(ii)** (the recommendation): a distinct `:route_verify_failed` composer
  kind projecting onto `:failed` with `result.disposition: "verify_failed"`.
- The "what does *verified* mean" open question resolved as the suggested doctrine slice:
  `system_verify` (idempotent re-check / state assertion / exit code; cite the evidence),
  reaching `system_verifier` via AR-5.

*(Write-time status, kept for the record:)* The substrate this needs has all shipped (AR-2
Composer Phases 0–5): the durable composer loop, human gates in the composer (Phase 4), and the
`stages_invalidated` rerun primitive (Phase 4e). This doc is the design for the system-specific
stages that ride that substrate; nothing here is blocked on further engine work.

## Context

AR-8 triage classifies OS-level work as `system` — "update configs, troubleshoot, run CLI
tooling, change the environment" (Alp River `agents/triage.md`); a path defined by leaving "a
verified change to the machine." A `system` verdict is a composer verdict
(`Triage.Verdict.composer?/1` is true for `:code` and `:system`), so `FrontDoor.decide/2` starts
a composer run seeded `live: ["request-received", "system", "plan-needed", …]` plus the mapped
risk signals (`front_door.ex`).

But the route it then composes is **shared with `code` and stops early**. The only non-`triage`
stages carrying `routes: ["code", "system"]` are `planner` (`{:worker_template, "researcher"}`,
subscribes `plan-needed`) and `plan-gate` (`{:gate, "plan"}`, subscribes `plan-ready`) —
`catalog.ex:65-93`. Every downstream stage (`implementer`, the four reviewers, `fixer`) is
`routes: ["code"]` only. So a `system` turn runs `triage → planner → plan-gate`, and once
`plan-approved` lands **no further stage triggers**: dispatch empties, `held` is empty, no lens
ran, and `Loop.terminal/2` returns `:converged` → the parent goes `:completed` (`loop.ex:82-99`).
**Net: the user asked the machine to do something, approved a plan, and the composer executed
nothing.** The system-specific stages do not exist. This doc designs them.

The risk signals the front door already maps from the verdict — `destructive-op`, `irreversible`,
`perms-change`, `secrets` (`front_door.ex` `@signal_topics`; triage's `publishes`,
`catalog.ex:42-63`) — currently have **no consumer** on the system path. They are exactly what the
safety gate (Phase B) subscribes to.

## Why separate

It needs new safety-critical worker templates, a **safety gate** (a gate-producer modeled on
`Reactors.PlanGate`), and the **reverse-verify loop** (a new consumer of the `stages_invalidated`
rerun primitive). It is independent of AR-8b (sketch). It depends on Phase 4 (gates) and the rerun
primitive — both shipped — so it is unblocked.

## What it reuses (substrate that already exists)

- **The gate-producer pattern is fully shipped.** `Reactors.PlanGate`
  (`orchestration/reactors/plan_gate.ex`) is the exact template to copy: a named `Ash.Reactor`
  under `JidoClaw.Orchestration.Reactors.` (mandatory — `GateResume` only re-materializes modules
  under that prefix, `gate_resume.ex:84`), a `GateStep` that halts + opens an `AgentCase`, and an
  **idempotent downstream emit step** (`wait_for` the gate) that reads `context[:approval]`,
  writes the artifact ref, and returns the `WaveCollect` emission map. The name→`{module, signal}`
  binding is one line in `GateReactors.@gates` (`gate_reactors.ex:26`). The decision-kind comes
  from a DSL declaration module (`JidoClaw.Gates.PlanGate`) drawing on `Gate.Kinds`
  (`kinds.ex:12`, `[:tool_call, :plan, :irreversible_write]`).
- **The rerun primitive is live, not dormant.** `stages_invalidated` (durable event, folded by
  `Projection`, `projection.ex:122-139`) already has consumers: the plan-gate re-plan
  (reject + stale-approval, `route_composer.ex:1865-2003`). The per-stage rerun cap
  (`@default_rerun_cap 2`, strictly-greater-than trip, `route_composer.ex:159`) already bounds
  re-fires and is rebuilt from the log on crash. AR-8c's reverse-verify is a *third* consumer of
  the same mechanism — structurally a sibling of the AR-4 self-heal loop (whose `fixer` stage
  exists but whose re-review loop is not yet closed).
- **A near-analog worker already exists.** The `verifier` template
  (`agent/workers/verifier.ex`: `verdict: :pass | :fail`, `confidence`, `reasoning`) is close to
  the `system-verifier` shape; `coder` (full mutating tools) is close to `system-executor`. The
  5-surface worker-add pattern (worker module via `JidoClaw.Agent.Defaults` → `Templates` registry
  → `Doctrine` slice map → `spawn_agent` advertisement → catalog stage) is established.

## Phases

### A — `system-executor` + `system-verifier` workers + catalog stages

The route to build (all `routes: ["system"]`): `planner → safety-gate → system-executor →
system-verifier` — with the open question of whether the shared `plan-gate` is *also* kept ahead
of the safety gate (see Open questions). No validator change is needed — `"system"` is already a
member of `@paths` (`catalog_validator.ex`), so the new stages just satisfy the existing coherence
invariants (every subscribed signal and required input traces to a producer or the seed), keeping
the catalog validator-clean.

- **`system-executor`** — a producer worker with the mutating system toolset (`RunCommand`, file
  tools, etc.), the system-flavored analog of `coder`; reuses `OutputSchema.artifacts()`. It must
  be **held behind the safety gate**: it subscribes to its trigger (e.g. `plan-approved`) but
  carries a `lock %{while: <risk-signal>, until: "safety-approved"}` so the irreversible work
  cannot dispatch until the human clears it (the lock-holds / gate-produces split, AR-2 §9). It
  publishes a completion signal (e.g. `system-applied`) — note the default emit mapper's
  explicit-signal path reads a `signals` field off the typed output (`emit/default_mapper.ex`), so
  the worker's output schema must declare one (or the signal is derived another way).
- **`system-verifier`** — a judge that confirms the change took. **Decision (surface it):**
  - *(i) Verdict-family.* Give it a reviewer-shaped `overall` enum + a `lens: "system"` on the
    stage → the default mapper derives `clean:system` / `findings:system`, and convergence reuses
    the existing per-lens machinery (`loop.ex` `lenses_clean?`). Cheapest reuse; the re-fire then
    looks exactly like the AR-4 fixer (open `findings:system` → invalidate the executor).
  - *(ii) Explicit verify signal.* A `verify-passed` / `verify-failed` pair (closer to the
    skeleton's wording), needing a `signals` field or a custom `{:mapper, _}`. More legible as a
    "machine verified" signal, but it does not ride the lens-clean convergence for free.
  Recommend (i) unless the system path wants a verify signal in its own right.

### B — `Reactors.SafetyGate` gate-producer (`unit: {:gate, "safety"}`)

Mirror `Reactors.PlanGate`: a `JidoClaw.Orchestration.Reactors.SafetyGate` producer + a
`JidoClaw.Gates.SafetyGate` DSL declaration, registered `"safety" => {SafetyGate,
"safety-approved"}` in `GateReactors.@gates`. It gates the system-flavored risk signals
(`destructive-op` / `irreversible`) triage already emits. As with plan, the composer
**synthesizes** `safety-rejected` / `safety-abandoned` from the gate child's terminal status
(declared in the stage `publishes` for catalog coherence) — the reactor itself only emits
`safety-approved`. Depends on Phase 4 (shipped).

- **Kind decision (surface it):** reuse `:irreversible_write` (zero migration, semantically fits a
  pre-write checkpoint) vs a new `:safety` kind (one line in `Kinds.@kinds`, no DB migration —
  `AgentCase.kind` is an Ash `one_of` constraint, not a PG enum — buying distinct inbox
  filtering/presentation). Recommend `:irreversible_write` for the personal/tailnet threat model
  unless distinct safety UX is wanted.
- **Input-slot note:** the gate's single required-input ref is threaded through a **hardcoded
  `:plan_ref` slot** today (`route_composer.ex` resolve + `wave_builder.ex` pack). A safety gate
  over a different artifact (the plan, or a dry-run preview) reuses that slot as-is, or that key is
  generalized — a small decision to make when the safety gate's required input is chosen.

### C — Reverse-verify loop

`system-verifier` re-fires `system-executor` on a failed verification by removing it from `ran`
via a durable `stages_invalidated` event (AR-2 §4/§6). This is the third emitter call alongside
the two plan-gate re-plan paths (`route_composer.ex:1865-2003`); it is structurally the
**stale-approval** variant (no `closed_wave_index` — the executor's wave *completed*, unlike a
parked-but-cancelled gate), removing `{system-executor}` from `ran` so the next `compose_route`
re-triggers it. The per-stage `rerun_cap` bounds it automatically; `rerun_counts` survives a crash
via the projection.

- The same fork as Phase A surfaces here: verdict-family (open `findings:system` drives the
  re-fire, identical to the AR-4 fixer) vs an explicit `verify-failed` signal edge.
- **Provenance:** the verifier's feedback should reach the executor's next task (so the re-fire is
  informed, not blind) — carried as an artifact the executor consumes, mirroring how the fixer
  reads `findings`.
- This and AR-4 are the **first two real consumers** of an otherwise gate-only rerun mechanism;
  they should share the emitter helper rather than duplicate it.

### D — System terminal semantics

A machine change that **won't** verify (re-fires exhausted at `rerun_cap`) today surfaces as
`route_budget_exhausted → :failed`, which conflates "verification never passed" with "spent too
much." It should be a distinct failure from `:not_converged`. Options:

- *(i)* accept `route_budget_exhausted` as the terminal (cheapest, no new kind);
- *(ii)* a distinct `Loop.terminal/2` classification (e.g. `:verify_failed`) + a new `route_*`
  composer event kind projecting onto `:failed` with a disposition — the same "new terminal kind
  projecting onto the existing `WorkflowRun` status set" pattern AR-2 §6 used for `route_rejected`
  / `route_abandoned → :cancelled + disposition`.

Recommend (ii): "the machine change could not be verified" is a distinct, honest operator signal
worth distinguishing from a generic budget stop.

## Open questions / decisions

- **What "verified" means per system op** — idempotent re-check, state assertion, or a command
  exit code. Encoded in the verifier's `task` per op; a `system` doctrine slice (AR-5) could
  standardize the discipline (what counts as evidence the change took).
- **Does `system` keep the plan-gate *and* a safety-gate, or fold them?** Plan-approval gates the
  *plan*; safety-approval gates the *irreversible apply*. The skeleton's Phase A drew the matured
  path as `planner → safety-gate → …` (no plan-gate), so folding to a single checkpoint is a live
  option; two checkpoints is the conservative alternative.
- **Reconciling environmental artifacts with the store** — a system change is not a git `diff`;
  the executor's artifact is a *description of machine state* (or a reversible trace), not a patch.
  Squidie §4.8's reconcile-from-trace idea applies (a side-effecting stage reconciles from its
  durable trace rather than re-running blind). Storage/encryption (AR-2 §15.3) matters here —
  system artifacts may carry secrets (perms, configs).
- **Safety-gate UX for irreversible ops** — feeds the `:irreversible_write` vs `:safety` kind
  decision above.
