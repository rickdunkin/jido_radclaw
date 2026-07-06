# Plan: next-ten item 6 — honest terminal statuses + stall detection (camus C1-4 + C1-5, + PD1-1 fold-in)

## Context

Item 6 of `docs/plans/unadopted-next-ten/README.md` (Wave B; #4 and #5 are done, so this is next).
Today every composer disposition projects into the `:failed` family — a run whose fix loop capped
out with a **green, certified verify** is indistinguishable in kind from one that never compiled
(`route_fix_failed` → `:failed`, `workflow_event/projection.ex`). And findings have no cross-wave
identity: a stale reviewer flag or a genuine impasse consumes every rerun before terminalizing,
with no signal it was the same finding all along. The squidie gate/case machinery is the right
substrate; what's missing is one gate kind, one completed-family disposition, and a fingerprint.

Two source-doc claims were **falsified by exploration** (to be mirrored into the camus entries at
reconciliation, per the queue's habit):

- *"seen_keys/prior_keys are derivable from wave artifacts already in the event log, so resume-safe
  for free"* — FALSE here: findings persist as **encrypted `ComposerArtifact` rows**; only opaque
  refs ride `artifacts_produced`, and `ComposerProjection.project/2` never decrypts. Finding keys
  must ride a **new bounded durable marker** welded into the wave commit (the `:verify_certified`
  precedent) and folded by `apply_event/2`.
- *"rides the squidie T2-5 Spark DSL"* understates the novelty: the composer parent is a GenServer
  (`workflow_type: "composer"`, no ReactorMiddleware, no checkpoint), so `review_stall` cannot use
  `GateStep`/`GateResume`/the run-bound `Cases.decide` resume path. It needs a **parent-bound,
  child-less park variant** and a kind-dispatched `Cases.decide` branch.

**Done means `mix precommit` passes** (run directly, exit code + counts verbatim, never piped).
Nothing gets committed; everything stays unstaged. Greenfield — no data/back-compat concerns.

## Decisions (user-ratified 2026-07-05)

1. **Finding identity carrier**: add a required short `title` field to the shared
   `OutputSchema.reviewer_verdict/0` finding schema (reviewer / sketch_reviewer / system_verifier
   + doctrine prose + 2 eval pins + worker description strings). Fingerprint = versioned canonical
   term over (normalized location-file, normalized title) — line numbers dropped — hashed via the
   `ToolApprovals.canonical/1` recipe (deterministic ETF → SHA-256 → hex). Never a rendered string
   (`Solutions.Fingerprint.signature` is the named anti-pattern). Un-keyable findings are excluded
   from stall detection (camus-verbatim fail-safe).
2. **orca OQ-1 (decided once, for `review_stall` + future argus `:review`)**: severity stays
   descriptive (`info|warning|error`, findings-win conservatism intact); the release decision lives
   on the gate as **per-finding waive/ack records, all-or-reject**: approve requires every
   surviving finding explicitly waived (key + severity + optional note recorded — the BO2-6 debt
   ledger rows); anything less = reject → `fix_failed` as today. No loop re-entry / budget re-grant
   (named as camus-C2-1 territory, not built). Surfaces: web `/approvals` gets per-finding waive
   controls; REPL `/gates` prints the finding list and `approve` records waive-all (derived
   per-finding records still land). `Cases.decide/4` carries structured records from any surface.
3. **PD1-1 folded in** (supersedes the traycer TR1-2a rider as its own commit here), **including
   the PD2-1 slim `jido://bootstrap` rider**.
4. **rerun_cap persistence gap closed**: `"rerun_cap"` joins `parent_config/3` +
   `build_start_opts/2` beside `infra_cap` (conditional-put), with a restart-keeps-override test —
   the stall/exhaustion trigger reads it, so the boundary must be restart-stable.

Standing design constraints: `docs/TRUST-BOUNDARIES.md` five laws + the event-sourced durability
checklist govern every composer/gate change here. Stall detection covers **forward review lenses
only** (`exhausted_fix_lenses` set; verify-authority stages excluded). The gate fires only on a
**green and certified** verify (live `clean:<verify-lens>` + `verified_integrity_holds?`); routes
without a verify stage keep today's terminals (a C1-5 stall still early-halts them, with the stall
recorded durably). Headless CLI exit code for `done_with_findings` stays **0** (the OQ-4 0/1/2/3
contract is pinned); text + JSON get the disposition marker.

**Park shape (pinned by recovery evidence)**: the composer parent **stays `:running`** during the
stall park. `WorkflowRecovery.classify/1` (workflow_recovery.ex:242-279) rebuilds only
`workflow_type: "composer"` + `:running`; an `:awaiting_approval` composer row falls through to
the dangling-gate arm and gets failed-with-audit on boot. So: raise = case-only open (AgentCase
run-bound to the parent + `case_event(:opened)`, **no** `approval_requested` append — not
`WorkflowLog.gate_open`); the pending case row is the durable park representation; the
review_stall `Cases.decide`/abandon arms are kind-dispatched and append **no run event**
(`approval_resolved` is only legal from `:awaiting_approval`, `run_abandoned` likewise); the
composer is the single status-authority writer (approve → `:route_done_with_findings`
`:running→:completed`; reject → `:route_fix_failed`; abandon → `:route_abandoned`). Rebuild
re-derives stall/exhaustion from folded state and resolves the case by fingerprint through the
same function the live `{:gate_resolved, run_id, info}` broadcast path uses (run-bound decide
broadcasts the parent's id; handle_info gains a stall-park match arm). Surfaces: nothing is
`:awaiting_approval`, so the gate-block/snapshot must also reflect a parent-bound pending
review_stall case (`pending_for_run` on the parent); the headless exit-3 probe already matches
(`pending_for_run_tree` covers `workflow_run_id == run_id`).

## Shape

Three commit-sized phases (working tree only — no commits):

- **Phase 1 (C1-5)**: finding `title` + engine-side fingerprints + per-lens seen/prior keys via a
  new durable marker + stuck/oscillation predicates + the no-fix-without-re-review-budget rule +
  rerun_cap persistence.
- **Phase 2 (C1-4 + riders)**: `:review_stall` gate kind + parent-bound park + kind-dispatched
  decide branch with per-finding waives + `:route_done_with_findings` → `:completed` with
  `result.disposition` + every status surface marked + `resume_hint` (C3-2) + debt-ledger view
  (BO2-6) + transition-table test (OH1-3) + vocabulary doc notes (TR3-2, PD3-3, bosun, orca OQ-1).
- **Phase 3 (PD1-1 + PD2-1 slim)**: MCP serverInfo version fix, `SurfaceVersion` constant,
  `jido://_meta/version` + `jido://bootstrap` resources, served-surface golden test,
  `project_info.app_version`.

**Design adjudications (pinned during planning — deliberate, do not re-open):**
- **No migration anywhere.** `WorkflowEvent.kind`, `AgentCase.kind` (via `Gate.Kinds.all()`), and
  `AgentCaseEvent.type` are app-level `one_of` stored as text; `AgentCase.fingerprint`/`details`
  columns exist; waive records ride `AgentCaseEvent.data` (jsonb); `title` is a Zoi-only change.
- **Terminal result carries keys + counts, never finding bodies**: `result.disposition` +
  `finding_keys` (hex) + `findings_deferred_count` + `severity_counts` + `lenses` +
  `certified_head` + `stall` + `trend`. Bounded-redacted finding BODIES live only on
  `AgentCase.details` (+ the ledger). Redaction-safe by construction —
  `:route_done_with_findings` stays OUT of `@scrubbable_error_kinds` like `:route_converged`.
  (Deviation from camus's "findings in the result" — record at reconciliation.)
- **Fingerprint normalization downcases the TITLE only, never the file path** (case-sensitive
  filesystems; camus downcases both — deliberate deviation, record it).
- **Stall is enforced at Hook R + terminal classification, not a separate tick branch** (review
  correction): the stall/no-re-review predicate is consulted where the fixer re-fire is decided
  (`decide_rerun`/Hook R skips the `stages_invalidated: [fixer]` weld when stalled OR
  unreviewable — the invalidation is never even recorded), and the next tick's `dispatch == nil`
  → `finish_terminal(:not_converged, …)` reclassifies to the fix-exhaustion/stall path. Tick
  order stays `dispatch==nil → over_budget? → run_wave`; `infra_capped?` (inside
  `budget_terminal`) keeps outranking the stall gate. Verify-less routes early-halt through the
  same reclassification (no wasted fixer wave, no burned rerun count).
- **Incomplete approve is refused loudly** (`{:error, :incomplete_waiver}`), never auto-converted
  to reject. A `:cancelled` review_stall case resolves defensively to `fix_failed` (findings-win).
- **Raise-time decrypt** of surviving findings (`ComposerArtifact.resolve_value/2` → redact →
  bound) is a new, documented controlled decrypt site; add the moduledoc caveat to
  `ArtifactContext`'s "only place" claim.

## Phase 1 — C1-5: finding identity + stall detection (+ rerun_cap persistence)

1. **`title` schema ripple** — `OutputSchema.reviewer_verdict/0`
   (`lib/jido_claw/agent/workers/output_schema.ex:134-145`): add `title: Zoi.string()` (MAP form;
   required by default; workers' `on_validation_error: :repair` recovers omissions) + moduledoc
   `:106`. `Verdict.Review` moduledoc `:13-15` adds `title` to the pass-through list (NO code
   change — findings pass verbatim). Doctrine `priv/defaults/doctrine/reviewer_contract.md:12`:
   "four fields" → five, `title` bullet first (the fingerprint headline). Worker description
   strings: `reviewer.ex:8`, `system_verifier.ex:20`, `sketch_reviewer.ex:19`. Eval pins:
   `@reviewer_finding_fields` in `test/jido_claw/eval/prompt_cases_test.exs:18` +
   `schema_coherence_cases_test.exs:19` (invalid-sample count auto-adjusts; confirm the fixture
   tolerates `title`). Verify-stage findings already carry `"title"` (`verify_stage.ex:146`).
2. **`JidoClaw.Core.CanonicalHash`** (new, review correction): extract the deterministic-term
   hash core — `sha256_term(term) :: lowercase-hex` (`:erlang.term_to_binary(term,
   [:deterministic])` → SHA-256 → `Base.encode16(case: :lower)`) — and migrate
   `ToolApprovals.fingerprint/3` (tool_approvals.ex:104-114) onto it, deleting its private
   duplicate (migrate ALL call sites — the reach trivial-forwarder/clone pair pulls opposite
   ways; a shared public helper with two real callers satisfies both). Domain canonicalization
   (ToolApprovals' `canonical/1`, FindingKey's normalization) stays with each domain.
   `LoopGuard.args_digest/1` returns a raw binary (different contract) — leave it, note the
   sibling.
   **`JidoClaw.RouteComposer.FindingKey`** (new `lib/jido_claw/route_composer/finding_key.ex`):
   `key/1` → hex digest | nil, `keyable?/1`; term `{:v1, normalized_file, normalized_title}`
   through `CanonicalHash.sha256_term/1`. File: strip leading `./`, drop trailing
   `:line`/`:line:col`, collapse whitespace, NO downcase. Title: downcase + collapse + trim.
   Blank/missing title or location ⇒ `nil` (excluded from stall — camus fail-safe). Never a
   rendered string.
3. **`StageEmission.finding_marks`** (new optional field, the `certification` precedent,
   stage_emission.ex:45-55,116-139): `%{lens, keys: [hex], marks: [%{key, severity, confidence}]}
   | nil`; fail-closed whitelist decode in `from_map/1` (malformed ⇒ nil); nil on non-reviewer
   emissions. **Serialization boundary (review High finding)**: `WaveCollect.to_map/2`
   (route_composer/steps/wave_collect.ex:103) currently encodes only
   stage/signals/artifacts/outcome — reviewer emissions cross the child-result boundary through
   it and are rehydrated by `from_map/1` (route_composer.ex:2312), so `to_map/2` MUST also encode
   `finding_marks` or the marks silently vanish. (The `certification` field never needed this
   because verify emissions are built by `Reactors.VerifyStage`, bypassing WaveCollect — state
   this in the code so the asymmetry is legible.) Round-trip test at this exact boundary.
4. **Compute in `DefaultMapper.verdict/2`** (default_mapper.ex:129-141 — the raw-values boundary):
   findings branch builds keys+marks (non-nil, deduped); **clean branch sets
   `%{lens, keys: [], marks: []}`** (a clean round must advance the round — oscillation needs it);
   infra branch stays nil. Thread through `build_emission`.
5. **Weld + fold `:finding_keys`**: `finding_keys_markers(verdict_emissions)` joins the marker
   assembly (route_composer.ex:1916-1923) → rides `Commit.commit_wave` welded; in-memory mirror
   via the existing `apply_markers` call (:1937). Register `:finding_keys` in the
   `WorkflowEvent.kind` one_of (NOT status-authority; document in the projection moduledoc).
   Fold clause in `route_composer/projection.ex`: per-lens `finding_rounds` map —
   `%{round, prior_keys, current_keys, seen_prior, current_marks, prior_marks}` where
   `seen_prior` = union of rounds BEFORE current (computed before the shift — the oscillation
   set), tolerant `Map.update` seeding; state seed `finding_rounds: %{}` in `init/1`.
6. **Pure stall predicates** (route_composer.ex, the `over_budget?` pattern): `stall_evidence/1`
   over `finding_rounds` restricted to **forward review lenses** (exclude
   `verify_authority_stage?` :4244): per lens with `round >= 2`, `stuck = current ∩ prior`,
   `oscillating = current ∩ (seen_prior \ prior)`; `trend` per key from marks
   (`likely→unsure = :falling` "lean ACCEPT — probably stale", else `:steady` "lean REFINE") —
   advisory only. `review_stalled?/1` = any stuck/oscillating key.
7. **Fix-wave suppression** — one shared pure `suppress_fix_dispatch?/1`-style predicate
   combining BOTH stop reasons: (a) `rereview_exhausted_lenses/1` (forward lens,
   `findings:<lens>` live, fixer on live route, reviewer `rerun_counts >= rerun_cap` — the next
   Hook-F invalidation would trip `count > cap`; distinct from `exhausted_fix_lenses/1`'s
   `> cap`, :4257) and (b) `review_stalled?/1` (step 6). Consumed by BOTH sides so they cannot
   disagree: Hook R (`fixer_reinvalidation_markers/1` :3234-3244 skips the
   `stages_invalidated: [fixer]` weld — the invalidation is never recorded, no rerun count
   burned, no wasted fixer wave) AND the tick (`finish_terminal(:not_converged, …)` reclassifies
   to the fix-exhaustion/stall path instead of a mislabeled `:not_converged` — review
   correction: the tick terminalizes immediately on `dispatch == nil` via `Loop.terminal`
   :114-120, so this reclassification IS where verify-less routes early-halt on stall). Exact
   boundaries pinned by red-first tests.
8. **rerun_cap persistence**: `parent_config/3` (:482-499) conditional-put `"rerun_cap"` beside
   `infra_cap`; `build_start_opts/2` (:853-881) reads `config["rerun_cap"] || opts || default`;
   update the :490-491 gap comment; restart-keeps-override test (the infra_cap pattern).
9. **Observability**: register `counter("jido_claw.composer.stall.total", tags: [:kind, :lens])`
   + `emit_composer_stall/2` in `core/telemetry.ex` (emission fires in Phase 2's stall stop);
   bounded `:composer` Trace event (hex keys only, tenant-stamped — the `emit_infra_observability`
   precedent :2261-2280, durable-then-notify).

**Phase 1 tests (red-first)**: `finding_key_test.exs` (determinism, suffix drop, `./` strip,
downcase rules, un-keyable ⇒ nil, distinct-findings-never-collide); output_schema `title`
required + repair; eval-pin updates; `stage_emission_test.exs` fail-closed `finding_marks`
decode; `projection_test.exs` `:finding_keys` fold + `project(seed,log) == apply_markers`
equivalence over a multi-round log + clean-round advances; stall fixtures (stuck vs oscillating
vs verify-lens-excluded; trend falling/steady); mechanism-7 red test (all flagged reviewers at
boundary ⇒ terminalizes `:fix_failed` not `:not_converged` AND no extra fixer wave); rerun_cap
restart test; telemetry/trace assertions.

## Phase 2 — C1-4: `review_stall` gate + `done_with_findings` + waives + surfaces

1. **Kind**: add `:review_stall` to `Gate.Kinds.@kinds` (gate/kinds.ex:15 — widens DSL enum +
   `AgentCase.kind` one_of together).
2. **`JidoClaw.Gates.ReviewStallGate`** (new `lib/jido_claw/gates/review_stall_gate.ex`,
   `use HumanGate`, model plan_gate.ex): `kind(:review_stall)`, title/description, a `:comment`
   textarea field; no reactor, no hook overrides (composer terminalization is the must-happen
   work). Per-finding waive controls are surface-rendered from `details["findings"]`, not DSL
   fields.
3. **Terminal wiring**: `@type terminal` + `classify_terminal/1` + `terminal_event/3` gain
   `:done_with_findings` → `{:route_done_with_findings, %{result: %{disposition:
   "done_with_findings", finding_keys, lenses, certified_head, stall, findings_deferred_count,
   severity_counts, trend}}}` (keys+counts only — pinned adjudication). Forge teardown: the
   `:done_with_findings` arm joins `:converged`'s `complete_session` (NOT the default
   `stop_session`). Register the kind in workflow_event.ex.
4. **Run-status projection** (`orchestration/workflow_event/projection.ex`): add to
   `@route_terminal_kinds`; explicit `next_status(:running, :route_done_with_findings) →
   {:ok, :completed}` (keep OUT of `@route_failed_kinds` — shadowing note :41-49);
   `status_attrs` → `terminal_lifting_result(:completed, …)` (first completed-with-disposition).
5. **Tick gating + stall park** (route_composer.ex): tick order stays
   `dispatch==nil → over_budget? → run_wave` (no new cond branch — pinned adjudication);
   `finish_budget({:fix_failed, lenses}) → finish_fixish`; `finish_terminal(:not_converged)`
   reclassifies through the Phase-1.7 shared predicate (this is where BOTH the stall early-halt
   and the unreviewable-fix stop land, since Hook R suppressed the fixer weld and the route ran
   dry); `finish_fixish` → `verify_green_certified?` (= has-verify-stage ∧
   `live_verify_cleans != []` ∧ `stale_verified_cleans == []`, reusing :2203-2208 + :1229-1260)
   → `enter_or_resolve_review_stall`, else `finish({:fix_failed, …})` (verify-less routes:
   early stop, evidence durable, stall emission fires here). New SIBLING state
   `stall_parked: nil` (`%{case_id, fingerprint, lenses, evidence, certified_head}` — do NOT
   overload `parked`; all child-based consumers untouched).
   `enter_or_resolve_review_stall/3`: fingerprint = recipe-hash of `{:review_stall_v1,
   parent_run_id, sorted stalled finding keys}`; `AgentCase.by_fingerprint` → decided ⇒
   `resolve_review_stall/1` now; pending ⇒ re-park (no re-open/re-decrypt); none ⇒ open via
   `WorkflowLog.case_open_runbound` (step 7), materialize details (raise-time decrypt →
   `Transcript.redact` → bound with explicit `overflow_count`; `resume_hint` C3-2 string) —
   **merged over `Gate.Presentation.details(Gates.ReviewStallGate)`** (review correction: this
   path bypasses `GateStep`, so it must merge `gate_title`/`gate_description`/`fields` itself,
   the gate_step.ex:59 / tool_approvals.ex:269 posture — otherwise the DSL `:comment` field is
   dead and web renders lose title/description). **Pinned coupling (review clarification)**:
   details carry BOTH the top-level `"finding_keys"` list (what the decide validator checks
   waive completeness against) AND the per-finding `"key"` field on each entry of
   `"findings"` (what the waive UI derives records from) — same open, same source; the
   top-level list is exactly the per-finding keys (un-keyable findings, excluded from stall,
   are not waive-required), asserted by a test. Then park,
   `ensure_gates_subscribed`, arm the sensitive-run stall-park deadline (new parallel
   `arm_stall_park_deadline` + `dispose_stall_park_deadline` → kind-aware abandon →
   `route_abandoned`; a parked composer is idle and never reaches `past_deadline?` on its own);
   read error ⇒ fail-safe `finish({:fix_failed, lenses})`.
   Wake: `handle_info({:gate_resolved, run_id, _})` (:1310) gains a
   `stall_parked != nil and run_id == parent_run_id` arm → `resolve_review_stall/1`, which
   reloads the case and branches on DURABLE case status: approved ⇒
   `finish({:done_with_findings, evidence})`; rejected ⇒ `finish({:fix_failed, lenses})`;
   abandoned ⇒ `finish({:abandoned, …})`; cancelled ⇒ defensively `fix_failed`; pending/reload
   error ⇒ stay parked. Recovery: ZERO changes — rebuild ends in a tick, re-derives, resolves by
   fingerprint (same shared function).
6. **`Cases.decide/4` kind dispatch** (cases.ex:132-140, BEFORE `guard_resumable` — the parent is
   `:running` with no checkpoint): `decide_review_stall/6` — approve txn = `lock_run` + `lock_case`
   + `ensure_case_pending` + **waive-completeness validation** against `details["finding_keys"]`
   (missing any ⇒ `{:error, :incomplete_waiver}`) + `AgentCase.approve` +
   `case_event(:approved, %{waive_records: [%{key, severity, note}], …})`; reject mirror (no
   waives required); **NO WorkflowEvent in either arm** (`approval_resolved` illegal from
   `:running`; reject must NOT cancel the parent); broadcast
   `RunPubSub.broadcast_gate_resolved(parent_id, …)` post-commit. **Return shape (review
   correction)**: `{:ok, %AgentCase{}}` — the run-less-branch shape, distinct from the
   run-bound `{:ok, run}`; document it on `decide/4` and make callers/tests treat run-terminal
   assertions as ASYNC (await the composer wake/recovery to observe `:completed`/`fix_failed`,
   never read them off decide's return). `Cases.abandon/3` gains the review_stall
   kind-dispatch: flip + case_event + broadcast, SKIP `run_abandoned` — and the SAME
   return-shape treatment (review correction): it returns `{:ok, %AgentCase{}}`, not the
   `{:ok, %WorkflowRun{}}` existing callers expect (approvals_live.ex:170, cli/commands/
   approvals.ex:99) — update both callers' handling/copy, the `abandon/3` spec/docs, and tests
   (the run reaches `:cancelled` only when the composer terminalizes `route_abandoned` — async,
   like decide).
7. **Case open**: new `AgentCase` create action `:open_review_stall` (mirror `:open_tool_call`
   :134-153 — accepts workflow_run_id/details/fingerprint, sets kind/gate_module/status/
   step_name; code-interface define) with **explicit validations** (review correction):
   `validate(present(:workflow_run_id))` AND `validate(present(:fingerprint))` — the
   `fingerprint` column is nullable (agent_case.ex:361), so a nil/blank fingerprint would
   silently bypass the pending-case partial-unique fence (agent_case.ex:71-75) that makes the
   raise idempotent; `:open_tool_call` already validates its fingerprint (:145). Test: the
   action refuses nil AND blank fingerprints. Plus `WorkflowLog.case_open_runbound/3` (one txn:
   case create + `case_event(:opened)`; deliberately NO `approval_requested` — the pending case
   IS the durable park). **Broadcast (review correction)**: AFTER the open txn commits, the raiser broadcasts
   the gate-requested notification the live `/approvals` LiveView subscribes to
   (approvals_live.ex:185) — existing gate opens rely on `reactor_runner.ex:774-786`'s
   post-checkpoint broadcast and tool approvals broadcast in `tool_approvals.ex:294`; the stall
   opener has no runner, so it owns this (durable-then-notify: broadcast only after `:ok`
   commit; a skipped notify never skips the write — recovery still resolves by fingerprint).
   Since this is the THIRD `{:gate_requested, …}` producer, add
   `RunPubSub.broadcast_gate_requested/3` beside `broadcast_gate_resolved/4`
   (run_pubsub.ex:47-57) and migrate the two raw emitters onto it — one helper keeps the tuple
   shape from drifting.
8. **BO2-6 debt ledger** (no new table): `Cases.waived_findings_ledger(tenant, actor)` reading
   approved `:review_stall` cases + their `:approved` `AgentCaseEvent.data["waive_records"]` →
   per-tenant severity counts + per-case rows (needs a new `AgentCase` read for decided
   review_stall cases — pending_* reads only cover pending). **Lua exposure (review
   correction)**: `jido.cases` reads PENDING cases only (bindings.ex:473), so the ledger needs
   an explicit read-only surface — extend the `jido.cases` binding with a deliberate
   ledger/decided-review-stall mode (validated statuses via the existing enum-introspection
   pattern, `case_view` fixed-field projection already carries decision fields) OR a dedicated
   `jido.debt` binding; either way it joins the Bindings table (lua_docs single-source) and
   keeps `assert_read_only!`. Plus a `findings_deferred` count in `workflow_status`'s rollup.
9. **Surfaces** (the "never plain green" rule):
   - `Visibility.run_view/3` (visibility.ex:54-74): add `disposition` +
     `findings_deferred_count` (safe string-key extraction from `run.result`; nil otherwise) —
     everything downstream inherits.
   - `status_badge/1` (core_components.ex:58-75): new optional `disposition` attr;
     `:completed` + `"done_with_findings"` ⇒ distinct badge (amber / "completed · findings").
     Callers: workflows_live.ex:226,360 (+ revealed result already shows full result),
     dashboard_live.ex:54-60 (mind the `:completed` default), workflow_graph :134.
   - `WorkflowView`: `run_to_map` inherits; `put_gate_block/4` (:288-308) ALSO reflects a
     parent-bound pending review_stall case (`pending_for_run(parent)` filtered by kind ⇒
     `review_stall_pending: true` + `awaiting_approval: true`); headless exit-3 probe already
     matches via `pending_for_run_tree`.
   - `workflow_status`: recent_completions carry disposition; tenant rollup gains
     `findings_deferred` count. `inspect_workflow` (:89-101): `put_present(:disposition, …)` +
     `findings_deferred_count` (never a `status` key — Tools.Error would promote it).
   - Headless CLI (run_command.ex:421-423): exit 0 preserved; text `run_line` + JSON envelope
     marked with disposition + findings count.
   - Lua bindings: returns-doc strings for `jido.runs`/`jido.run` mention disposition (lua_docs
     single-sources from the table); `jido.cases` details passthrough already carries findings +
     resume_hint.
   - REPL `/gates` (approvals.ex:137-144): kind-aware legible finding-list render for
     review_stall; `approve` records waive-all (derived per-finding records still land via
     `Cases.decide` attrs).
   - Web `/approvals` (approvals_live.ex): kind-aware section — findings list with per-finding
     waive checkbox + note, Approve disabled until all addressed; `"decide"` event collects
     records into `Cases.decide` attrs. Render `resume_hint` explicitly (+ in inspect_workflow's
     gate block). **Review correction**: the post-decide flash/copy around :211 treats a
     returned `%AgentCase{}` as tool-call-ish ("re-issue the tool call") — add review_stall
     copy ("recorded; the run completes/fails when the composer resumes"), since decide's
     return is the case, not the run outcome.
10. **OH1-3 transition-table test**: exhaustive `@terminal × @status_authority_kinds ⇒ :illegal`
    (terminals are absorbing — this system's `:completed` accepts no further transitions,
    OpenHelm's "`succeeded` accepts none" translated) + the new happy-path clause.
11. **Vocabulary doc note** (Gate.Kinds moduledoc or short docs section): NAME traycer TR3-2
    `superseded` (future terminal, argus `:review` joins this list), pad PD3-3 lineage badges
    (display-only), bosun BO2-6 retry vocabulary + attempt-cap escalation (reference-only), and
    orca OQ-1's decision as made.

**Phase 2 tests (red-first)**: projection (`next_status`, `status_attrs`, OH1-3 exhaustive);
gate trigger matrix (fix_failed + green-certified verify ⇒ park, parent STAYS `:running`, case
run-bound, no `approval_requested`; verify-red / no-verify / infra-capped / deadline / max_waves ⇒
NOT gated); decide paths (decide returns `{:ok, %AgentCase{}}`; approve-all-waived ⇒ composer wake drives
the run to `:completed` + disposition — AWAITED via composer resolve, never read off decide's
return — + waive records on the case event; incomplete ⇒ refused; reject ⇒ `fix_failed`, parent
never `:cancelled`; abandon ⇒ no `run_abandoned` event); idempotent raise-or-resolve (pending ⇒ re-park, no duplicate case —
fingerprint fence; decided-while-down ⇒ terminalize once; crash between decide and terminal ⇒
rebuild terminalizes); sensitive-run stall-park deadline ⇒ abandon; surfaces (Visibility fields,
badge, put_gate_block review_stall_pending, headless exit codes + marked output, inspect_workflow
fields, ledger severity counts). Composer call-probe tests need a PARKED composer (project
memory).

## Phase 3 — PD1-1 served-surface stability contract + PD2-1 slim `jido://bootstrap`

Independent of Phases 1–2 (may be implemented first). Verified facts this rests on: the hardcoded
`version: "0.2.0"` is `lib/jido_claw/core/mcp_server.ex:14` vs `@version "0.6.4"` in `mix.exs:4`;
anubis bakes `version:` at compile (`is_binary` validated) but **skips its generated
`server_info/0` + validation when the module defines its own** (`deps/anubis_mcp/lib/anubis/
server.ex:518-524,630-650`); the app-vsn idiom to copy is `to_string(Application.spec(:jido_claw,
:vsn) || "dev")` (`mcp/endpoint_config.ex:264`). Static fixed-URI resources implement
`Jido.MCP.Server.Resource` and join `publish: resources:` (mirror
`core/mcp_server/resources/workflow_catalog.ex`). Tenant under `:mcp` = the boot scope
(`MCPScope.Initializer` → `Tools.MCPScope.with_default(%{})`; tenant-wide `"default"`, the
fetch_output S-M2 doctrine); the catalog resource is tenant-independent by design, so bootstrap is
the **first tenant-scoped resource and owns the honesty rule**. Neither `jidoclaw.jido_md.check`
nor `jidoclaw.system_prompt.check` is affected — both compare the in-REPL agent's 35 tools /
templates / skills / app vsn, never MCP resources (proven against `Platform.JidoMd.Check.problems/2`
and the system_prompt checker), and `mix.exs` version does not change.

1. **`JidoClaw.MCPServer.SurfaceVersion`** (new `lib/jido_claw/core/mcp_server/surface_version.ex`):
   `@current "1.0"`, `current/0`; moduledoc = the doctrine line (surface prose lives next to the
   constant — the pad rot lesson), bump rules (MAJOR = remove/rename/retype served tool, resource,
   or output field; MINOR = additive; a bump lands in the same diff as the golden regen), and an
   in-file changelog (`## v1.0 (2026-07-05) — 26 tools; catalog + {name} template + _meta/version
   + bootstrap`).
2. **Version fix (red-first)**: tighten `test/jido_claw/mcp_server_test.exs` `server_info/0` test
   from `is_binary` to `== to_string(Application.spec(:jido_claw, :vsn))` → RED against `"0.2.0"`.
   Then in `core/mcp_server.ex`: hand-define `server_info/0` (`%{"name" => "jido_claw",
   "version" => app_version()}`; `@impl Anubis.Server`), demote `use ... version:` to an inert
   documented literal (`"0"` + comment — anubis needs a non-nil binary at compile; the override
   wins at runtime), and add the shared single-source accessor `served_tool_names/0`
   (`__publish__().tools |> Enum.map(& &1.name()) |> Enum.sort()`) → GREEN. *Spike note*: compile +
   this test IS the spike for the dep-macro skip; if anubis unexpectedly double-defines, stop and
   reassess (agent-verified read says it holds).
3. **`Resources.MetaVersion`** (new, mirror WorkflowCatalog): `jido://_meta/version` →
   `{:ok, %{"app_version", "surface_version", "tool_count"}}`; unknown URI `{:error, :not_found}`.
   Register in `publish: resources:`.
4. **`project_info` gains `app_version`** (`lib/jido_claw/tools/project_info.ex`: output_schema +
   result map; pinned by test, schema is advisory).
5. **`Resources.Bootstrap`** (new): `jido://bootstrap`, cap `@recent_runs_cap 5`. Always returns
   tenant-independent facts (`app_version`, `surface_version`, `tool_names` via
   `served_tool_names/0`, `tool_count`) + a `"tenant"` block from `MCPScope.with_default(%{})`:
   resolved scope → `available: true`, tenant/workspace identity, `pending_gates_count`
   (`AgentCase.pending_for_tenant`), `active_runs`/`recent_completions` capped at 5 with
   `*_overflow_count` fields (counted **relative to the already-bounded window** — documented in
   the moduledoc; no new COUNT queries); unresolved scope → `available: false,
   reason: "mcp_scope_unavailable"` with version/tool facts still present — **never a silent
   empty**. **Query path (review corrections)**: a new small honest helper —
   `WorkflowView.runs_summary(scope, statuses:, sort:, cap:)`-style — built on the
   `{:error, :runs_unavailable}` read path (workflow_view.ex:80), NOT `WorkflowView.list/1`
   (swallows read errors into `[]`, :187-216). It must (a) sort completions by
   `completed_at: :desc` (the dashboard rollup precedent :192 — `runs/2` alone always sorts
   `started_at: :desc`, wrong for recent completions) and (b) fetch `cap + 1` so
   `*_overflow_count = max(0, fetched - cap)` is knowable from a bounded read — documented as
   "≥1 means more exist beyond the cap, not a total" (no COUNT query). One call with active
   statuses, one with `Projection.terminal_statuses()`. View-read fault with tenant present →
   per-block availability flag, never a misleading `0`/`[]` (the `put_gate_block` precedent) —
   and this honesty rule covers `pending_gates_count` too (review correction): an
   `AgentCase.pending_for_tenant` read fault yields `pending_gates_available: false`, never
   `0`. Payload through `JsonSafe.encode/1`. Register in `publish:`.
6. **Golden test** (new `test/jido_claw/core/mcp_server/served_surface_golden_test.exs` + committed
   fixture `test/fixtures/mcp_surface/served_surface.json`): fixture holds
   `{surface_version, tool_names (sorted 26), static_resource_uris (sorted, incl. the 2 new),
   resource_templates (["jido://workflows/{name}"])}`. Test force-loads MCPServer
   (`Code.ensure_loaded/1` precedent), derives live sets, **set-compares names per enumeration
   surface** (missing/extra, never counts — the drift-guard house rule), asserts the version
   string, and on mismatch prints ready-to-commit pretty JSON (regen-by-diff, no mix task).
   Red-first: run against absent fixture → RED; commit derived fixture → GREEN.
7. **Resource unit tests** (mirror `workflow_stage_test.exs` harness): MetaVersion (uri/name/mime,
   payload values, not_found); Bootstrap (tenant-unavailable honesty in the default test env —
   red-first; tenant-available shape via `Application.put_env(:jido_claw,
   :jido_claw_mcp_default_scope, ...)` + `on_exit` restore; overflow behavior; not_found). Extend
   `mcp_server_test.exs` published-resources describe with the two new modules.
8. **reach/credo watchpoints**: keep the bootstrap pending-count fold a single inline expression
   (clone risk vs `RuntimeOverview.snapshot/1` — if the clone detector fires, route through
   RuntimeOverview and project a subset instead); no `default_scope/0` trivial forwarder (use
   `with_default(%{})`); expect `# reach:disable-next-line fixed_shape_map` on the wire-shaped
   payload maps only if flagged (the `endpoint_config.ex:263` precedent); `@moduledoc`/`@spec`/
   `@impl` on all new modules.

## Doc reconciliation (the queue's closing habit — part of this change)

- `docs/plans/unadopted-next-ten/README.md` item 6 → ✅ DONE + corrections blockquote (the
  falsified claims below, the decisions as made, scope grown by operator decision: per-finding
  waives, PD1-1+PD2-1 fold-in, rerun_cap gap closed).
- `docs/exploration/camus/FEATURES-WORTH-BORROWING.md`: C1-4, C1-5, C3-2 Status lines with these
  claim corrections: (a) C1-5's "seen/prior keys derivable from wave artifacts in the event log,
  resume-safe for free" is false here — findings are encrypted artifact refs; keys ride the new
  welded `:finding_keys` marker; (b) C1-4's "rides the squidie T2-5 gate machinery" understated
  it — the composer parent has no checkpoint and an `:awaiting_approval` composer is recovery's
  dangling-gate arm, so this shipped a parent-stays-`:running` child-less park + kind-dispatched
  decide/abandon branches; (c) "findings attached to the result" shipped as keys + counts +
  severity histogram on the result, verbatim bodies on the gate case only (redaction posture);
  (d) C1-5's "lowercased file" fingerprint downcases the title only (case-sensitive
  filesystems). OQ-2 note: disposition-first answer implemented as specified.
- `docs/exploration/pms/orca/FEATURES-WORTH-BORROWING.md`: OQ-1 decision recorded.
- `docs/exploration/pms/bosun/FEATURES-WORTH-BORROWING.md`: BO2-6 Status (folded into #6).
- `docs/exploration/pms/openhelm/FEATURES-WORTH-BORROWING.md` (+ OH-FIRST-WAVE.md): OH1-3 #6 rider
  folded (transition-table test; forced-verdict-at-cap already engine-side).
- `docs/exploration/pms/pad/FEATURES-WORTH-BORROWING.md` + `PD-FIRST-WAVE.md`: PD1-1 + PD2-1
  (slim) Status lines; PD3-3 named in the vocabulary note.
- `docs/exploration/ades/traycer/FEATURES-WORTH-BORROWING.md`: TR1-2 slice (a) Status PARTIAL
  (MCP surface; SDL/Channels goldens stay argus-bound); TR3-2 named in the vocabulary note.
- `AGENTS.md`: architecture bullet for the new machinery + "Exposed resources" gains the two new
  resource URIs.

## Verification

- Red-first tests at each phase (named per phase above); then the full gate:
  `mix precommit` — run directly, never piped; report exit code + test counts verbatim.
  (Known rotating full-suite flakes: MemoryExport / collector crash-recovery / clustering `:pg` —
  one unrelated timing flake ⇒ re-run, per project memory.)
- **No migration expected anywhere** (pinned by design: app-level one_of kinds, existing
  jsonb/fingerprint columns, waive records on `AgentCaseEvent.data`). If implementation
  discovers otherwise, `mix ash.codegen --dev` while iterating, squash to one named codegen
  before precommit.
- Precommit-specific watchpoints: `jidoclaw.system_prompt.check`/`jidoclaw.jido_md.check` are
  unaffected by resources/output-fields (proven against their comparison surfaces) but WILL
  fail if any tool/template name drifts; reach `--smells --strict` clone/forwarder risks are
  called out inline (bootstrap fold, no `default_scope/0` forwarder); every new module needs
  `@moduledoc`/`@spec`/`@impl`; Zoi map-form only; string enums in persisted payloads.
