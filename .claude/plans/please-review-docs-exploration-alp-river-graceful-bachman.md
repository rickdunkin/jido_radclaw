# AR-8c — The System Path (verified machine change)

## Context

AR-8 triage already classifies OS-level work ("update configs, run CLI tooling, change the
environment") as the **`system`** path, and `FrontDoor.decide/2` already starts a composer run for
it — seeded `live: ["request-received", "system", "plan-needed", <risk signals>]`. But the route the
composer then builds is **shared with `code` and stops early**: the only stages carrying
`routes: ["code", "system"]` are `planner` and `plan-gate`. Every downstream stage (`implementer`,
reviewers, `fixer`) is `code`-only. So a `system` turn runs `triage → planner → plan-gate`, and once
`plan-approved` lands **nothing else triggers** → `Loop.terminal` returns `:converged` → the parent
goes `:completed`. **Net: the user asked the machine to do something, approved a plan, and the
composer executed nothing.** The system-specific stages don't exist.

AR-8c builds them: two safety-critical workers (`system-executor`, `system-verifier`), a **safety
gate** (a gate-producer modeled on `PlanGate`), a **reverse-verify loop** (re-fire the executor when
verification fails, via the shipped `stages_invalidated` rerun primitive), and a distinct
**`verify_failed`** terminal so "the machine change could not be verified" is an honest operator
signal. All substrate (durable composer loop, human gates, the rerun primitive) has shipped (AR-2
Phases 0–5); nothing here is blocked on engine work.

This is a personal/tailnet tool — the threat model weights toward **LLM-misbehavior**, which is why
the locked decisions below favor "gate every machine change" over risk-proportional friction.

## Locked decisions

1. **Gate topology: single always-on safety-gate.** Every `system` op runs
   `triage → planner → safety-gate (human approves) → system-executor → system-verifier`. The
   plan-gate is **dropped from the system path** (becomes `routes: ["code"]`). Consequence:
   `plan-approved` is never live on `system`, so the composer's `stale_approval?` guard is provably
   false on `system` and **no change to `implementer_ran?` is needed** (the highest-risk part of the
   alternatives is avoided entirely).
2. **Terminal: distinct `verify_failed`.** A machine change that won't verify (reruns exhausted with
   an open `findings:system`) terminates as a new `:route_verify_failed` event → `WorkflowRun.status
   :failed` **with `result.disposition: "verify_failed"`**, distinct from a generic
   `route_budget_exhausted`.
3. **Gate kind: reuse `:irreversible_write`** (per the doc's threat-model recommendation). Zero
   migration, no new approval-UI surface. A dedicated `:safety` kind remains a one-line option
   (`Gate.Kinds.@kinds`) if distinct inbox labeling is later wanted.
4. **Verifier shape: reviewer-shaped + `lens: "system"`** (the `SketchReviewer` precedent). Reusing
   `OutputSchema.reviewer_verdict/0` + a stage `lens` makes `DefaultMapper.reviewer_verdict/3` derive
   `clean:system` / `findings:system` with **no mapper change**, and convergence rides the existing
   `Loop.lenses_clean?/3` machinery for free.

## Two corrections to the AR-8c doc (verified against current code)

These change the design vs. what the doc literally says; both are confirmed by reading the code:

- **The doc's provenance mechanism would not compile.** The doc says carry the verifier's findings to
  the executor "as an artifact the executor consumes" (i.e. `optional: ["findings"]`). But the
  data-precedence graph (`Graph.kahn`, used by **both** `CatalogValidator.cycle/1` and the router
  toposort) builds edges from `req ++ opt` (`graph.ex:70`). Since the verifier `required: ["system-change"]`
  (produced by the executor) and the executor would then `optional: ["findings"]` (produced by the
  verifier), that's an **executor⇄verifier cycle** → the compile-time `CatalogValidator` rejects the
  catalog. **Fix (this plan): out-of-band `verify-feedback`** — an optional executor input with **no
  catalog producer** (so it adds no graph edge), which the composer writes on re-fire. Details in
  Phase C.
- **The reverse-verify loop must invalidate BOTH executor and verifier, not just the executor.** The
  doc says "remove `{system-executor}` from `ran`." But a signal already live (the executor's
  trigger) does **not** re-fire a verifier still in `ran` (triggers key on `ran`+`live` membership,
  not edge transitions — `router.ex:122-141`). If only the executor leaves `ran`, the verifier never
  re-checks and the run converges `:not_converged` with the stale verdict. The rerun set must be
  `{system-verifier, system-executor} ∩ ran` — exactly what `replan_rerun_set/2` already computes for
  the stale-approval case ({planner, plan-gate}). Details in Phase C.

Two smaller notes: the executor needs **no completion signal / `signals` output field** (the verifier
is ordered after it by the `system-change` data edge + a path-signal subscribe — the `sketch-review`
pattern), and `:failed`-with-disposition is a **new projection combination** (today only the
`:cancelled` family lifts a disposition). All file paths in the doc are stale — the composer lives at
`lib/jido_claw/route_composer/` (not `reasoning/composer/` or `orchestration/`).

## Review findings folded in

**Third-round review**: P3 — the hardcoded template-count tests (`templates_test.exs:140`, `:167`)
grow `10 → 12`; add `exists?/1` coverage for the two system templates (Phase A verification). Plus an
impl note: `composer_private?/1` must be defined standalone so `external_tools?/1 → not
composer_private?/1` cannot recurse (Phase A4).

**Second-round review** surfaced three, all incorporated:

- **P1 — `verify_failed` could never fire**: scoping `budget_terminal` to `ran` was wrong — the
  cap-tripping invalidation removes the verifier from `ran`, so the check is false at the trip tick.
  Now keyed on `rerun_counts[name] > rerun_cap` **and** `findings:<lens>` live (Phase D1).
- **P2 — seventh privacy surface**: `seed_handoff_from_metadata/4` (`worker.ex:426`) rehydrates a
  template from session metadata with no privacy check (Phase A4).
- **P3 — artifact ref shape**: the `artifacts_produced` marker uses the **bare** ref (`bare_ref/1`);
  the in-memory mirror stores the **tagged** `{:ref, ref}` shape (Phase C3).

**First-round review** surfaced five issues, all incorporated:

- **P1 — status authority** (`projection.ex:63`): `:route_verify_failed` must be added to
  `@route_terminal_kinds` (which feeds `@status_authority_kinds`), else the terminal event appends
  while the parent `WorkflowRun` stays `:running`. → Phase D3.
- **P1 — privacy across all surfaces**: composer-privacy is enforced at **six** surfaces, not one; a
  `:none`-sandboxed private worker leaks unless they share a central `Templates.composer_private?/1`
  predicate. → Phase A4.
- **P1 — safety-gate reject re-plans**: the reject→re-plan condition is catalog-global
  (`route_composer.ex:1717`), so a rejected safety-gate would re-fire the planner; narrow it to the
  gate that publishes the re-plan signal. → Phase B6.
- **P2 — `reverse_verify` invariant**: require **exactly one** required input (the rerun helper reads
  only `[name | _]`). → Phase B2.
- **P2 — `budget_terminal` over-broad**: classify `verify_failed` only for an open **reverse_verify**
  lens, not any dirty lens. → Phase D1.

## Design overview — the system route

```
triage ──► planner ──► safety-gate ──► system-executor ──► system-verifier
 (seed)   (researcher)   (gate)          (executor)          (verifier, lens:system)
                          │                  ▲                     │
                          │ safety-approved  │ verify-feedback     │ findings:system
                          └─ releases lock ──┘ (out-of-band) ◄─────┘ re-fire loop
```

- **planner** (existing `researcher` worker) stays `routes: ["code", "system"]`, produces `plan`.
- **safety-gate** (new gate) subscribes `plan-ready`, gates the `plan` (`:plan_ref` slot reused
  as-is), publishes `safety-approved`. Always fires on `system`.
- **system-executor** subscribes `plan-ready`, **held** by `lock %{while: "plan-ready", until:
  "safety-approved"}` until the human approves, then runs (full mutating tools), produces
  `system-change`. On re-fire it also reads the out-of-band `verify-feedback` (the prior findings).
- **system-verifier** (`lens: "system"`, `reverse_verify: true`) subscribes the `system` path signal
  (always live) and `required: ["system-change"]` (the data edge that orders it after the executor —
  the `sketch-review` pattern). Emits `clean:system` (pass) or `findings:system` (fail).
- **reverse-verify loop**: a `findings:system` re-fires `{executor, verifier}` (bounded by the
  per-stage `rerun_cap`); exhaustion with findings still open → `verify_failed`.

---

## Phase A — `system-executor` + `system-verifier` workers (5-surface add)

Two new workers via the established worker-add pattern. No catalog stages yet (those come in Phase B,
which the compile-time catalog guard requires the templates to already exist for).

**A1. Worker modules** (`use JidoClaw.Agent.Defaults`):
- `lib/jido_claw/agent/workers/system_executor.ex` — copy `coder.ex`. Mutating toolset centered on
  `RunCommand` (`ReadFile, WriteFile, EditFile, ListDirectory, SearchCode, RunCommand, FetchOutput,
  GitStatus, GitDiff`), `model: :fast`, `tool_timeout_ms: 60_000` (it runs commands, like
  `Verifier`), `compaction: [mode: :auto]`. Output schema = coder's
  (`status/summary/files_changed/notes` + `artifacts: OutputSchema.artifacts()`). **No `signals`
  field** (the verifier is ordered by the data edge, not a signal). The `summary`/`notes`/`artifacts`
  are the machine-state description the verifier checks (addresses the doc's "environmental artifacts"
  open question; secrets are encrypted at rest by the existing `ComposerArtifact` store — no new
  work).
- `lib/jido_claw/agent/workers/system_verifier.ex` — reviewer-shaped output but verifier-style tools.
  `output: %{schema: OutputSchema.reviewer_verdict(), retries: 1, on_validation_error: :repair}`,
  tools `ReadFile, SearchCode, ListDirectory, RunCommand, FetchOutput, GitStatus, GitDiff` (it
  inspects the real machine to confirm the change took), `model: :fast`, `max_iterations: 20`,
  `tool_timeout_ms: 60_000`, `compaction: [mode: :auto]`.

**A2. `Templates` registry** (`lib/jido_claw/agent/templates.ex` `@templates`): add `"system_executor"`
and `"system_verifier"` ⇒ `%{module:, description:, model: :fast, composer_private: true}`. (Template
**keys are snake_case** by convention — `coder`, `test_runner`; the kebab `system-executor` is the
**catalog stage name**, whose `unit` is `{:worker_template, "system_executor"}`.)

**A3. Doctrine slice map** (`lib/jido_claw/doctrine.ex`): `"system_executor" => [:base, :artifacts]`
(producer), `"system_verifier" => [:base, :reviewer_min, :system_verify]` (judge). Add a new
`:system_verify` slice — a short `priv/defaults/doctrine/system_verify.md` defining the verification
evidence discipline (**idempotent re-check / state assertion / command exit code; cite the
evidence**) registered in `@slices`. This directly answers the doc's "what does verified mean" open
question via the AR-5 doctrine seam. *(Gate: `doctrine_test.exs` asserts
`Doctrine.template_names() == Templates.names()` — both registries must move in lockstep.)*

**A4. Composer-private hardening — a single central predicate** *(P1: privacy must hold across every
reachability surface, not just `spawn_agent`)*. The system workers are `sandbox: :none` (they run on
the real machine — that is the point), so the existing `sandbox in [:prototype, :docker]` privacy
checks do **not** cover them, and that privacy is currently enforced ad-hoc at each surface — a new
unsandboxed-but-private template would leak through any surface left unpatched. Fix: add one source of
truth `Templates.composer_private?(name)` (`true` when `sandbox/1 in [:prototype, :docker]` **or** the
new `:composer_private` registry flag is set; default `false`, hydrated in `hydrate_template/1`).
**Define it standalone** — read `sandbox/1` + the flag directly, **not** in terms of `external_tools?/1`
— so the `external_tools?/1 → not composer_private?/1` redefinition below cannot recurse;
`main`/unknown templates resolve `:none` + no flag → `false`. Route **every** reachability/augmentation
surface through it:
- `tools/spawn_agent.ex:62` (direct spawn) — `if Templates.composer_private?(template_name)` →
  `composer_private_error`.
- `tools/send_to_agent.ex:176` (follow-up turn) — same.
- `tools/handoff.ex:233` (`reject_sandbox/2` → generalize to a `composer_private?` check).
- `agent/handoff/router.ex:276` **and** `:360` (handoff routing + recovery — a private target is
  `:stale`/refused).
- `agent/templates.ex:210` `external_tools?/1` → `not composer_private?(name)`, so the system workers
  (like sandboxed ones) get **zero** external MCP tools — a fixed, auditable toolset (consumed at
  `mcp/consumer.ex:641`).
- `platform/session/worker.ex:426` `seed_handoff_from_metadata/4` *(P2)* — it rehydrates a handoff
  owner from `session.metadata["current_agent_template"]` via `Templates.get` with no privacy check.
  Treat a `composer_private?` template as **stale** (the existing "stale templates clear metadata +
  log" branch at L425), so a private template can't be transiently re-installed into the registry
  from durable metadata.

Leave the **functional** sandbox-root checks alone (`vfs/sandbox.ex:132`, `tools/real_tree.ex:39`,
`templates.ex:285` — these resolve the actual sandbox filesystem, not reachability; system workers
correctly resolve as `:none`/real-tree). Register both templates with `composer_private: true` and
**do not** add them to `spawn_agent`'s two hardcoded advertised lists. Rationale (threat model): the
composer drives these workers through the wave-builder path (unaffected), but a misbehaving main agent
must not reach the mutating `system_executor` directly, bypassing the safety gate.

**A5. Worker output-schema test** (`test/jido_claw/agent/workers/worker_output_schemas_test.exs`): add
a `describe` block per new worker (alias + parse a valid sample), following the existing pattern.

---

## Phase B — `Reactors.SafetyGate` + the `reverse_verify` Stage field + catalog stages

**B1. `Stage` struct field `reverse_verify`** (`lib/jido_claw/route_composer/stage.ex`): add
`reverse_verify: false` to the defstruct + `@type`, and to `to_map/1` / `from_map/1` (a JSON-safe,
atom-safe boolean, default `false`). It marks a verifier stage whose open findings re-fire its
upstream producer.

**B2. `CatalogValidator`** (`lib/jido_claw/route_composer/catalog_validator.ex`): add a group-0
structural check (`reverse_verify` is boolean) and an invariant: a `reverse_verify: true` stage must
carry a `lens` (it emits `findings:<lens>`) **and exactly one** `input.required` artifact. *(P2:
"exactly one", not "non-empty" — the reused `replan_rerun_set/2` → `gate_input_producers/2` inspects
only the first required artifact (`[name | _]`, route_composer.ex:1968), so a multi-required
reverse_verify stage would silently re-fire only the first producer.)* Catches authoring errors at
compile time.

**B3. `SafetyGate` gate-producer** — copy `plan_gate.ex` near-verbatim:
- `lib/jido_claw/orchestration/reactors/safety_gate.ex` — `JidoClaw.Orchestration.Reactors.SafetyGate`
  (**must** be under that prefix — `GateResume`'s `@allowed_module_prefix` fence, `gate_resume.ex:84`)
  + an idempotent `EmitApprovedChange` emit step (the `ensure_pending` reuse-by-lineage idempotency,
  the `WaveCollect`-shaped envelope). `gate_module: JidoClaw.Gates.SafetyGate`, `step_name:
  "safety-gate"`, `details: %{summary: "Approve this system change before it is applied to the
  machine."}`. Inputs `plan_ref/wave_index/stage_name/artifact_name/signal_name` (unchanged).
- `lib/jido_claw/gates/safety_gate.ex` — `JidoClaw.Gates.SafetyGate` DSL: `use
  JidoClaw.Orchestration.HumanGate; gate do kind(:irreversible_write); title("Approve system change");
  description(...); fields do field(:comment, type: :textarea, ...) end end`.

**B4. Gate registration** (`lib/jido_claw/route_composer/gate_reactors.ex`): one line —
`@gates %{"plan" => {PlanGate, "plan-approved"}, "safety" => {SafetyGate, "safety-approved"}}` + the
alias.

**B5. Catalog** (`lib/jido_claw/route_composer/catalog.ex`):
- `plan-gate`: change `routes: ["code", "system"]` → `routes: ["code"]` (drop system — decision 1).
  `planner` stays `["code", "system"]`.
- Add three stages:

```elixir
"safety-gate" => %Stage{
  name: "safety-gate",
  unit: {:gate, "safety"},
  routes: ["system"],
  subscribes: ["plan-ready"],
  input: %{required: ["plan"], optional: []},
  output: ["approved-change"],
  publishes: ["safety-approved", "scope-shift"]
},
"system-executor" => %Stage{
  name: "system-executor",
  unit: {:worker_template, "system_executor"},
  task: "Apply the approved change to the machine/environment; report what changed.",
  routes: ["system"],
  subscribes: ["plan-ready"],
  input: %{required: ["plan"], optional: ["verify-feedback"]},   # verify-feedback: NO catalog producer
  output: ["system-change"],
  publishes: ["scope-shift"],
  lock: [%{while: "plan-ready", until: "safety-approved"}]
},
"system-verifier" => %Stage{
  name: "system-verifier",
  unit: {:worker_template, "system_verifier"},
  lens: "system",
  reverse_verify: true,
  task: "Verify the change actually took on the machine (idempotent re-check / state assertion / " <>
          "exit code); emit clean:system, else findings:system with what to fix.",
  routes: ["system"],
  subscribes: ["system"],                                        # path signal (always live); ordered after executor by the data edge
  input: %{required: ["system-change"], optional: []},
  output: ["findings"],
  publishes: ["findings:system", "clean:system", "scope-shift"]
}
```

Coherence (all confirmed against `catalog_validator.ex` + `graph.ex`): every `subscribes` has a
producer (`plan-ready`←planner, `system`←triage); every `required` input is produced
(`plan`←planner, `system-change`←executor); `verify-feedback` is **optional** so it's not
producer-checked (inv 4) and adds **no graph edge** (no producer → no cycle); the lock `while`/`until`
have producers (inv 6); the lens stage declares both `clean:system`+`findings:system` (inv 8); every
stage publishes `scope-shift` (inv 2); the graph stays acyclic (inv 9: `planner→{safety-gate,
executor}`, `executor→verifier`).

**B6. Narrow the gate reject→re-plan to the plan-gate** *(P1: the reject-replan condition is
catalog-global)*. `terminalize_gate_disposition(:rejected, …)` (`route_composer.ex:1713-1722`) re-plans
when `any_subscriber?(state.catalog, "plan-rejected")` — and that helper scans the **whole catalog**
(`route_composer.ex:2031-2033`), where the planner always subscribes `plan-rejected`. So a rejected
**safety**-gate would re-fire the planner instead of cancelling the run. Narrow the condition to also
require the *parked gate* to publish the re-plan signal:

```elixir
# was: if any_subscriber?(state.catalog, "plan-rejected") do
if "plan-rejected" in gate_stage.publishes and any_subscriber?(state.catalog, "plan-rejected") do
```

`gate_stage` is already bound (line 1715). The plan-gate publishes `plan-rejected` → unchanged
behavior; the safety-gate does not → its reject takes the `else` branch (`finish({:rejected, …})` →
`route_rejected → :cancelled` + disposition: the user declined the change, so the run **cancels**, it
does not loop back to planning). Backward-compatible for the plan-gate and for a no-subscriber catalog.

At the end of Phase B a `system` run already executes and verifies (terminating `:converged` on pass
or `:not_converged` on fail) — strictly better than today. Phases C/D add the retry loop and the
honest terminal.

---

## Phase C — the reverse-verify loop

**C1. Detection hook.** Replace the `maybe_retract_stale_approval(next, emissions)` call on the `:ok`
arm of the wave-fold path (`route_composer.ex:1295`) with a dispatcher:

```elixir
defp maybe_rerun_after_findings(state, emissions) do
  cond do
    open_verify_loop?(state, emissions) -> rerun_verify_loop(state, emissions)
    stale_approval?(state, emissions)   -> retract_stale_approval(state)   # unchanged; provably false on system
    true                                -> {:noreply, state, {:continue, :tick}}
  end
end

# A reverse_verify stage that just emitted an open finding.
defp open_verify_loop?(state, emissions) do
  Enum.any?(emissions, fn %StageEmission{stage: name, signals: sigs} ->
    match?(%Stage{reverse_verify: true}, Map.get(state.catalog, name)) and
      Enum.any?(sigs, &String.starts_with?(&1, "findings:"))
  end)
end
```

`open_verify_loop?` keys on the **`reverse_verify` flag**, so `sketch-review` / code reviewers (no
flag) keep their forward-only `:not_converged` behavior — this is what keeps `composer_loop_test.exs`
green.

**C2. Re-fire — invalidate BOTH stages (the correction above).** The rerun set is exactly
`replan_rerun_set(state, verifier_stage)` = `{verifier} ∪ {producers of the verifier's required
input} ∩ ran` = `{system-verifier, system-executor} ∩ ran`. Both leave `ran`; on the next tick the
executor re-triggers on its still-live `plan-ready` (lock stays released — `safety-approved` is never
retracted, so **the human is not re-gated on retry**, confirmed `router.ex:194-198`), re-produces
`system-change`, and the verifier (ordered after by the data edge) re-checks.

**C3. Informed re-fire via out-of-band `verify-feedback`.** In the same fenced transaction as
`stages_invalidated`, copy the verifier's just-produced `findings` ref into `verify-feedback`
(producer key = verifier name) via an `artifacts_produced` marker, and mirror it into
`state.artifacts`. **Ref-shape discipline** *(P3)*: `state.artifacts["findings"][<verifier>]` is the
**tagged** `{:ref, ref}` shape after fold (`fold.ex:88`). The `artifacts_produced` **marker payload**
must carry the **bare** ref — extract it with `bare_ref/1` (`route_composer.ex:1474`, exactly as the
existing wave-artifact marker does at `route_composer.ex:1470`) — while the **in-memory mirror** must
store the **tagged** `{:ref, ref}` shape (what `Fold.fold_artifacts/3` produces), so
`Projection.project == in-memory` holds. Because `verify-feedback` has no catalog producer it never
appears in the precedence graph; because `ArtifactContext.wanted_names/1` unions `required ∪ optional`
(`artifact_context.ex:88-92`), the executor's `optional: ["verify-feedback"]` surfaces the prior
findings in its task on re-fire — informed, not blind, and cycle-free.

**C4. Shared emitter helper.** Add a reusable `invalidate_stages(state, rerun_set, opts)` that emits
`stages_invalidated` (+ `opts[:extra_markers]`, e.g. the `artifacts_produced` for `verify-feedback`)
under the parent-terminal fence (`Commit.append_markers`) and mirrors in memory (`ran` difference +
`bump_rerun_counts` + `opts[:artifacts_put]`; **no** `closed_wave_index` for the verify loop). Route
**only the new verify-loop path** through it; leave the two existing plan-gate emitters
(`replan_after_reject`, `retract_stale_approval`) untouched (they have exact-payload tests —
refactoring them onto the helper is an optional, separate cleanup). The in-memory mirror must match
`Projection.apply_event(:stages_invalidated)` + the `artifacts_produced` fold **exactly** (the
projection-equivalence invariant) — covered by a new projection test.

**C5. Bounding.** The existing per-stage `@default_rerun_cap 2` + `rerun_capped?` (strictly-greater
trip, `route_composer.ex:159, 2434`) bound the loop automatically; `rerun_counts` is rebuilt from the
log on crash (`projection.ex:122-139`). No new bounding code.

---

## Phase D — the `verify_failed` terminal

**D1. Classify at the tick** (`route_composer.ex`, the `over_budget?` arm ~L925): a rerun-cap trip on
a reverse-verify stage **whose findings are still live** is a verification failure, not a generic
budget stop. The check is **`rerun_counts` + `live` based, NOT `ran` based** — critical, because the
cap trips *via* the same invalidation that just removed the verifier from `ran`, so any `ran`
membership check is false at the trip tick *(this was the bug in the first revision)*.

```elixir
over_budget?(state) -> finish(budget_terminal(state), state)

defp budget_terminal(state) do
  if rerun_capped?(state) and verify_exhausted?(state) do
    {:verify_failed, exhausted_verify_lenses(state)}
  else
    {:budget_exhausted, budget_reason(state)}
  end
end

# A reverse_verify stage that hit its rerun cap with findings:<lens> STILL live — the loop gave up
# while verification was still failing. Keyed on rerun_counts + live (NOT ran: the cap-tripping
# invalidation just removed the stage from ran). If it had passed, clean:<lens> would have replaced
# findings:<lens> and the loop would have converged, so it would not be capped with findings live.
defp verify_exhausted?(state) do
  Enum.any?(state.catalog, fn
    {name, %Stage{reverse_verify: true, lens: lens}} when is_binary(lens) ->
      Map.get(state.rerun_counts, name, 0) > state.rerun_cap and
        MapSet.member?(state.live, "findings:#{lens}")

    _ -> false
  end)
end
# exhausted_verify_lenses/1: the lenses meeting the same condition (for the error string).
```

*(P1/P2: scope to `reverse_verify: true` stages — not any open lens — AND key on `rerun_counts`+`live`
rather than `ran`. `rerun_capped? and not Loop.lenses_clean?` over `ran` both over-fires on unrelated
loops and under-fires here because the trip removes the stage from `ran`.)* `budget_reason/1` stays
pure (it classifies the *cause*); the
verify-vs-budget split is the orthogonal "is a reverse-verify lens open?" axis and belongs here. A
future loop that wants this terminal opts in by marking its judge stage `reverse_verify: true`.

**D2. New event kind + composer terminal:**
- `lib/jido_claw/orchestration/workflow_event.ex` — add `:route_verify_failed` to the `one_of` list
  (app-level, **no migration**).
- `route_composer.ex` — add `| :verify_failed` to `@type terminal`;
  `classify_terminal({:verify_failed, r}) -> {:verify_failed, r}`; a dedicated
  `parent_terminal_notify(:verify_failed, ...)` clause (placed **before** the generic failure
  catch-all) that appends `:route_verify_failed` with `%{error: format_terminal_error(:verify_failed,
  reason), result: %{disposition: "verify_failed"}}`; a `format_terminal_error(:verify_failed,
  lenses)` clause; and add `:route_verify_failed` to `@scrubbable_error_kinds` (~L194) so a sensitive
  run's findings-derived error string is scrubbed (the `result.disposition` is non-sensitive and
  survives). `maybe_teardown_forge_session` already handles every non-`:converged` terminal — no
  change.

**D3. Projection — `:failed` WITH a disposition (the new combination):**
`lib/jido_claw/orchestration/workflow_event/projection.ex`:
- **Add `:route_verify_failed` to `@route_terminal_kinds`** (line 41) *(P1)*. That set feeds
  `@status_authority_kinds` (line 63), so without it the event would append while the parent
  `WorkflowRun` stays `:running`. It makes the kind status-authority **and** terminal; the explicit
  clauses below handle projection. **Keep it OUT of `@route_failed_kinds` and `@route_cancelled_kinds`**
  (those drive the guard clauses in `next_status`/`status_attrs` — membership there would shadow the
  explicit clauses).
- `next_status(status, :route_verify_failed) when status in @non_terminal, do: {:ok, :failed}` (an
  explicit clause).
- `status_attrs(:route_verify_failed, payload, occurred_at)` (placed **before** the
  `@route_failed_kinds` guard) → a new `terminal_lifting_verify_failed/2` that sets `status: :failed,
  completed_at, error: fetch(payload, :error), result: fetch(payload, :result), clear_checkpoint:
  true`. `WorkflowRun.status` stays in its existing set (`:completed/:failed/:cancelled/:abandoned`);
  the operator query is `status == :failed AND result.disposition == "verify_failed"`.

---

## Critical files

| File | Change |
| --- | --- |
| `lib/jido_claw/agent/workers/system_executor.ex` *(new)* | Coder-shaped mutating worker |
| `lib/jido_claw/agent/workers/system_verifier.ex` *(new)* | Reviewer-shaped judge w/ run tools |
| `priv/defaults/doctrine/system_verify.md` *(new)* | Verification evidence discipline slice |
| `lib/jido_claw/agent/templates.ex` | Register both templates (`composer_private: true`) + `:composer_private` key; **`composer_private?/1` central predicate**; `external_tools?/1` → `not composer_private?` |
| `lib/jido_claw/doctrine.ex` | `@template_slices` + `:system_verify` in `@slices` |
| `lib/jido_claw/tools/spawn_agent.ex` · `send_to_agent.ex` · `handoff.ex` | Route privacy checks through `composer_private?/1` (was `sandbox in [:prototype,:docker]`) |
| `lib/jido_claw/agent/handoff/router.ex` | Handoff routing + recovery (`:276`, `:360`) through `composer_private?/1` |
| `lib/jido_claw/platform/session/worker.ex` | `seed_handoff_from_metadata/4` (`:426`): treat a `composer_private?` metadata template as stale |
| `lib/jido_claw/orchestration/reactors/safety_gate.ex` *(new)* | Gate-producer (copy `plan_gate.ex`) |
| `lib/jido_claw/gates/safety_gate.ex` *(new)* | Gate DSL (`kind :irreversible_write`) |
| `lib/jido_claw/route_composer/gate_reactors.ex` | One-line `@gates` registration |
| `lib/jido_claw/route_composer/stage.ex` | `reverse_verify` field + `to_map`/`from_map`/`@type` |
| `lib/jido_claw/route_composer/catalog_validator.ex` | `reverse_verify` structural + coherence checks |
| `lib/jido_claw/route_composer/catalog.ex` | plan-gate→`["code"]`; +3 system stages |
| `lib/jido_claw/route_composer/route_composer.ex` | B6: narrow reject-replan to plan-gate (`:1717`). C: dispatcher + `open_verify_loop?` + `rerun_verify_loop` + `invalidate_stages`. D: `budget_terminal` (reverse-verify-scoped) + `:verify_failed` terminal/notify/format/scrub |
| `lib/jido_claw/orchestration/workflow_event.ex` | `:route_verify_failed` in `one_of` |
| `lib/jido_claw/orchestration/workflow_event/projection.ex` | `:route_verify_failed` in `@route_terminal_kinds` (authority) + `next_status` + `status_attrs` + `terminal_lifting_verify_failed` |

**Reused (do not reinvent):** `replan_rerun_set/2`, `bump_rerun_counts/2`, `Commit.append_markers`
(route_composer.ex); `Loop.lenses_clean?/3` (loop.ex); `DefaultMapper.reviewer_verdict/3`
(default_mapper.ex); `OutputSchema.artifacts/0` + `reviewer_verdict/0` (output_schema.ex);
`ArtifactContext.wanted_names/1` (artifact_context.ex); `GateStep`/`GateReactors`/`HumanGate`/`Gate.Kinds`;
`terminal_lifting_result/error` (projection.ex) as the shape model for `terminal_lifting_verify_failed`.

## Verification

**Unit / integration tests to add:**
- Phase A: worker-schema describes; **update the hardcoded template-count assertions
  `10 → 12`** (`templates_test.exs:140` `list/0` + `:167` `names/0`, and their comments) and add
  `system_executor`/`system_verifier` to `@valid_names` + explicit `Templates.exists?/1` coverage for
  both. **`Templates.composer_private?/1` unit tests** (incl. `main`/unknown → `false`, and `:none`
  + flag-set → `true`) + a test per privacy surface (`spawn_agent`, `send_to_agent`, `handoff`,
  `handoff/router`, **and `session/worker.ex` metadata rehydration** — a metadata template pointing at
  a `composer_private` template is treated stale) asserting a `composer_private` template is refused,
  and that `external_tools?/1` is `false` for it. (`doctrine_test` + recorder-coverage pass
  automatically once both registries match and both workers `use Defaults`.)
- Phase B: `Stage.to_map/from_map` roundtrip incl. `reverse_verify`; a `CatalogValidator` test for the
  new invariant (lens + **exactly one** required input); the built-in `Catalog` compiles (its three
  compile-time guards). **A reject test: a parked safety-gate reject terminates `:cancelled`
  (disposition "rejected") and does NOT re-fire the planner** (the existing plan-gate reject-replan
  test must stay green). Update any test that snapshots the catalog stage-name set.
- Phase C: a `projection_test` case — `stages_invalidated %{stages: ["system-executor",
  "system-verifier"]}` (no `closed_wave_index`) drops both from `ran`, bumps both counts, leaves
  `wave_index`; plus the equivalence invariant with the `artifacts_produced(verify-feedback)` marker.
  Confirm `composer_loop_test.exs` (forward-only sketch/code reviewers) stays green.
- Phase D: `workflow_event_projection_test` — assert `status_authority?(:route_verify_failed)` is
  **true** (the P1 fix — it must fold into the status column); `next_status(_, :route_verify_failed)
  == {:ok, :failed}`; `status_attrs(:route_verify_failed, %{error: ..., result: %{disposition:
  "verify_failed"}}, at)` (atom- and string-keyed); the real append-txn case asserting `status ==
  :failed` **and** `result["disposition"] == "verify_failed"`. Confirm the existing rerun-cap →
  `route_budget_exhausted` test stays green (its fixture has no reverse_verify lens stage). Update any
  test enumerating the route-terminal kind set.
- New fixture `system_verify_loop_fixture_catalog` (`test/support/jido_claw/route_composer/fixtures.ex`)
  + two e2e composer tests (modeled on the Phase-4e re-plan tests): **(1) loop converges** — verifier
  emits `findings:system` once then `clean:system` → assert both stages invalidated (no
  `closed_wave_index`) then `route_converged → :completed`; **(2) verify-failed** — `rerun_cap: 1`,
  verifier always fails → the terminal is `:route_verify_failed` (**not**
  `:route_budget_exhausted` — this directly guards the P1 trip-after-exhaustion fix, where the
  verifier is no longer in `ran` at the trip tick), `reload(parent).status == :failed`,
  `result["disposition"] == "verify_failed"`.

**End-to-end (manual / MCP):** drive a `system` request through the composer; observe
`triage → planner → safety-gate` (parks for approval), approve via `/gates` (REPL) or `/approvals`
(web), then `system-executor → system-verifier → :converged`. Use the `inspect_workflow` /
`workflow_status` MCP tools to watch route/waves/held/live signals; use Tidewave
(`execute_sql_query` / `get_ash_resources`) to confirm the `route_verify_failed` event +
`status`/`result.disposition` on a forced failure.

**Completion gate (required): `mix precommit` must pass.** Mind the known new-code gotchas:
credo-strict (`@spec` on public fns, `AliasUsage`, `Credo.Check.Readability.ImplTrue`, ExSlop's
step-comment trap — don't start a comment/wrap with "step"), dialyzer (`Zoi.schema` not `Zoi.t` in
specs), and that `test/support` is linted. The precommit compile gate is `mix jidoclaw.compile_check`
(clean recompile, empty warning allowlist) — keep it warning-free.

## Implementation sequencing

`A → B → D → C → integration`. A before B (the catalog's compile-time guard requires the templates
and the `safety` gate to already exist). **D before C**: Phase D is additive vocabulary — landing and
unit-testing the new `:route_verify_failed` projection (the novel `:failed`-with-disposition
combination) in isolation de-risks it before Phase C wires the loop that exercises it. Each phase
compiles + tests green on its own.

## Out of scope (not deferrals — beyond AR-8c's four phases)

- The doc's "reconcile-from-trace" recovery idea (Squidie §4.8) — a recovery optimization, not part of
  the execute/verify loop. The executor's `system-change` artifact + the encrypted `ComposerArtifact`
  store cover AR-8c's needs.
- AR-4's code-path review→fix→re-review loop. AR-8c builds the **shared** `invalidate_stages` helper
  and the generalized `verify_failed` terminal so AR-4 can reuse both, but does not wire AR-4 itself.
- Dynamic risk-signal surfacing in the safety-gate's approval `details` (static summary for v1; the
  live risk signals are already visible via `inspect_workflow` / the dashboard).
