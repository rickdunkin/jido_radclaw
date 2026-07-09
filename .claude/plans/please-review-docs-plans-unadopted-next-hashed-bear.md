# Item 10 — Evidence floor (claims vs transcript)

Queue: `docs/plans/unadopted-next-ten/README.md` item 10 (ouroboros OB1-3, absorbing camus
C1-6c, with the OpenHelm OH1-3 rider). Last item of the queue.

---

## HANDOVER (2026-07-08, session interrupted mid-commit-2 verification)

**Status: Step 0 ✅ · Commit 1 ✅ complete · Commit 2 ~95% (code + docs + tests done; ONE
diagnosed regression to fix) · Commit 3 not started · precommit not run.** Everything is
in the working tree, unstaged (per house git policy). Read this section, fix the one
regression below, then resume at "What's next".

### The immediate problem (diagnosed, fix is one line)

Full sweep `mise exec -- mix test test/jido_claw/route_composer/ test/jido_claw/orchestration/`
= **1164/1169**. Five failures, all one root cause, **confirmed reproducible in isolation**
(`composer_loop_test.exs:617` fails alone — NOT the known flaky-suite issue):

1–3. `ComposerLoopTest` AR-9 armed e2e ×3 (`:617` etc.) — `summary.terminal == :failed`
4. `ComposerReviewIndependenceTest` "fresh session per re-review round … TWO vendor sessions"
5. `ComposerDurableTest` "AR-9 armed reject: the rerun set is exactly [planner]"

**Confirmed causal chain**: this session added `porcelain_all/1` to
`test/support/jido_claw/verify_stub.ex` with unscripted default `""` (clean tree). The AR-9
armed fixture's coder output carries `"files_changed" => ["lib/feature.ex"]`
(`test/support/jido_claw/route_composer/fixtures.ex:1052`; review-independence test has its
own at `composer_review_independence_test.exs:354,361`). With `""` snapshots the wave
changed-set is validly EMPTY (not a skip) → the files claim classifies `:unsupported` →
**spurious evidence breach** → `findings:evidence` summons the fixer → the AR-9 fixture has
no `"fixer"` canned output → `StubWorker`'s `Map.fetch!` **raises** → step crash → wave
failure → `:failed`. (Same mechanism perturbs the vendor-session count in #4 and the rerun
set in #5.) Before this session's change the stub lacked `porcelain_all/1`, so
`capture_wave_porcelain`'s rescue → nil → files kind SKIPPED → green (that's why the
composer dir was 518/519 green at the mid-session checkpoint).

**The fix**: change `VerifyStub.porcelain_all/1`'s unscripted default from `""` to `nil`
(capture unavailable ⇒ files kind skips ⇒ trust — matches the floor's conservative rule and
keeps every legacy fixture carrying `files_changed` behaviorally byte-identical):
`def porcelain_all(_repo), do: scripted(:porcelain_all, nil, :verify_stub_porcelain_all_calls)`
— and update its comment (unscripted = "no snapshot", NOT "clean tree"). The
`evidence_floor_test.exs` "zero tool rows" test scripts `:porcelain_all` explicitly, so it
stays valid; the other evidence tests deliberately omit `files_changed`. After the fix,
re-run the five named tests, then the full composer+orchestration sweep.

### What's done (chronological)

**Step 0** — `docs/exploration/ouroboros/PORT-OB1-3.md` written (pins `Q00/ouroboros @
e905a41c` MIT + HEAD `98d3d66d` drift note; side-by-side, behaviors, edge cases anchored to
source tests; the 8 sign-off decisions). **Operator sign-off granted 2026-07-08** via
AskUserQuestion ("Sign off (ratify 1–8)") — recorded in the doc's Sign-off line.

**Commit 1 (substrate) — complete, all suites green:**
- 1a `lib/jido_claw/agent/workers/output_schema.ex`: optional schema-PERMISSIVE
  `evidence: Zoi.optional(Zoi.any())` on `coder_result/0` + `fixer_result/0` (+ moduledoc
  contract). `builder_fields/0` untouched.
- **Unplanned but required** `lib/jido_claw/core/zoi_any_json_schema.ex`: protocol impl
  `Zoi.JSONSchema.Encoder for Zoi.Types.Any` → `%{}`. zoi 0.18.4 has NO encoder for Any
  (its `for: Any` fallback raises) and `ReqLLM.Schema.zoi_to_json_with_metadata/1` encodes
  worker schemas on EVERY structured-output request (in-process AND vendor deposit) —
  `Zoi.any()` broke 18 forge/agent-runner tests until this landed. `Zoi.json()` is NOT a
  substitute (recursive `Zoi.lazy` loops the encoder). **Deviation logged** in the queue
  README under item 10 ("Deviations (running…)" block, entry (a)).
- 1b `priv/defaults/doctrine/evidence_reporting.md` (new slice) + `lib/jido_claw/doctrine.ex`
  (`@evidence_reporting_priv`, `@external_resource`, `@slices`, `@template_slices` — coder +
  fixer ONLY). `system_prompt.check` + `jido_md.check` both green (doctrine is
  runtime-assembled).
- 1c `lib/jido_claw/security/shell_command.ex`: nested `Provenance` struct + public
  `exit_code_provenance/1` — its own `resolve_for_provenance` twin of the parse pipeline
  (reads the INTERNAL `{connector, %Command{}}` list), exit-swallow idioms
  (`||`/`;` into `true`/`:` anywhere), pipe masking (peel trailing presentation filters
  `{tail,head,cat,less,more}`; peeled-unprotected ⇒ masked; ANY residual pipe ⇒ masked even
  under pipefail; pipefail = exactly `["set","-o","pipefail"]` BEFORE the pipeline, walked
  left-to-right across `&&`/`;`), runner table (+`mix test` house extension; gradle/maven
  skip flags surface `skipped?: true` — recognized-with-skip, a documented divergence),
  moduledoc section + attribution. `analyze/1`/`@effect_kinds`/`:opaque` floor byte-untouched
  (regression-pinned).
- 1d rails: `workflows/step_result.ex` `request_id` field;
  `skills/steps/agent_runner.ex` `stamp_request_id/2` inside `run_recorded/6` (covers BOTH
  executor arms); `route_composer/stage_emission.ex` `request_id` + `evidence` fields with
  whitelist fail-closed decode (per-key); `route_composer/emit/default_mapper.ex` evidence
  normalization (per-key fail-open, `files_touched` from REQUIRED `files_changed`,
  advisory kinds from the optional block, one bounded Trace note `:evidence_block_malformed`
  on drops, mapper does NOT filter by template) + `request_id` copy;
  `route_composer/steps/wave_collect.ex` only-when-present serialization
  (`put_present`/`put_evidence`).
- 1e `lib/jido_claw/orchestration/verify/evidence.ex` (the pure classifier: `reader/0` seam
  via `config :jido_claw, :evidence, reader:`; `gather/2`; `decode_rows/1` with
  TranscriptEnvelope quirks + `%{"redacted" => true}` exclusion + the
  `:no_transcript`/`:redacted` skip split; `changed_paths/2` porcelain diff incl. renames +
  quoted paths; `classify/2` total with the ouroboros verdict partition;
  `discrepancies/2` one-per-(stage,kind) with stable titles + `evidence:<stage>:<kind>`
  locations; `findings/1` VerifyStage-shaped; `action_needed/1`) +
  `orchestration/verify/evidence/reader.ex` (default `Message.by_request` reader).
- Tests (all green): `shell_command_test.exs` (+~200 lines, 80 total),
  `orchestration/verify/evidence_test.exs` (new, 54), `doctrine_test.exs`,
  `worker_output_schemas_test.exs`, `default_mapper_test.exs`, `stage_emission_test.exs`.
  Credo --strict + `reach.check --arch --smells --strict` green on all commit-1 files.

**Commit 2 (consumer + docs) — code/docs/tests written; blocked only on the regression above:**
- 2a `orchestration/workflow_event.ex`: `:evidence_classified` in the `one_of` (after
  `:finding_keys`, NOT status-authority). `route_composer/projection.ex`:
  `apply_event(:evidence_classified)` bumps per-stage `evidence_breaches` (breach-only,
  TRUE no-op on breach-less/malformed — pinned in projection_test).
- 2b `route_composer/route_composer.ex` (the big one):
  - seed state fields `evidence_breaches: %{}` + `wave_porcelain: nil`;
  - `maybe_capture_wave_porcelain/2` in `run_built_wave/5` (producer-wave-gated via
    `evidence_producer_stage?`, rescue→nil, clears on non-producer waves);
  - `handle_wave_value` weave: `evidence_record_markers/3` (rescued fail-open) → temp
    `keyed_fold = apply_markers(next_fold, finding_markers ++ evidence_record.markers)` →
    `evidence_refire_markers/2` gated on `suppress_fix_dispatch?(keyed_fold)` →
    `decide_rerun(keyed_fold, …)` → `evidence_weld_markers/2` in the PINNED order
    (produced → feedback → signals+finding_keys+ledger → stages_invalidated), all inside
    the same `Commit.commit_wave`; `emit_evidence_observability` post-commit;
  - the consumer section (~350 lines, after `finding_keys_markers/1`):
    `@evidence_producer_templates ["coder","fixer"]`, catalog-decided eligibility
    (`lens: nil` + `unit: {:worker_template, t}`), ONE aggregate artifact set per wave
    under producer `"evidence"` (findings union / action_needed / evidence-report via
    `store_wave_artifact` with the CHILD run), explicit signal pairs on both flips,
    breach `finding_keys` (marks severity=error/confidence=likely) + clearing `keys: []`
    round, `evidence_classified_payload` (bounded: stage/request_id/counts/statuses/breach),
    clear-on-no-breach-while-live (skips clear too — deliberate, documented), containment
    Trace (count-only), fixer feed via `review_feedback(keyed_fold, ["evidence"])`;
  - predicates: `review_lenses/1` (forward ∪ "evidence" iff `finding_rounds["evidence"]`),
    `stall_evidence` reads it; `rereview_exhausted_lenses` + `evidence_rereview_exhausted`
    (fixer count `>=` cap — the evidence lens's budget IS the fixer's rerun count);
    `exhausted_fix_lenses` + `evidence_exhausted_fix` (`>` cap); `fixer_rerun_count/1`;
  - `summary/3` + `terminal_summary_subset/1` carry `evidence_breaches` only-when-nonzero
    (NOTE: only the CONVERGED result carries the subset — failure terminals keep
    disposition+error; the fix_failed test asserts the in-memory summary + ledger events).
- 2c `route_composer/loop.ex`: live `findings:evidence` ⇒ `:not_converged` (before the
  `lenses_clean?` check — closes the fixer-less-route hole).
- 2d `route_composer/catalog.ex`: `"evidence-report"` in `input.optional` of the 4
  reviewers + fixer, one engine-verified-signal sentence appended to those 5 task strings.
  `core/telemetry.ex`: `jido_claw.evidence.total` (tags [:verdict]) +
  `jido_claw.evidence.breach.total` (tags [:stage]).
- 2e `docs/system/evidence-floor.md` (new page: invariants, mechanics, vendor asymmetry,
  masking table, config/telemetry, residuals, source map) + `docs/system/README.md` index
  row + the AGENTS.md Key Patterns bullet (before the Executor Seam bullet).
  `mix jidoclaw.system_docs.check` green.
- 2f tests: `route_composer/evidence_floor_test.exs` (new, 9 tests, ALL GREEN in
  isolation): breach→feed→clear→converge with full durable-marker asserts;
  evidence-report in the next review wave's task (via `:route_composer_capture_task`);
  always-red → stall → `{:fix_failed, ["evidence"]}`; rerun_cap 0 temp-fold suppression
  proof (no feedback/invalidation ever welds, record still welds); vendor-arm zero-rows
  (tests skip, files reconcile AND can breach — scripted `:porcelain_all`); redacted skip;
  never-flagged byte-identical; multi-producer ONE-aggregate (uses `catalog:` opt — note
  the `run/2` helper uses `Keyword.merge`, first-wins bit me once); projection recovery
  equivalence (`ComposerProjection.project(seed, events)`).
  Support edits: `verify_stub.ex` `porcelain_all/1` (THE REGRESSION — fix per above);
  `fixtures.ex` self-heal catalog reviewers/fixer `opt:` lists gained `"evidence-report"`
  (lines ~382–419 only; other catalogs untouched); `loop_test.exs` + `projection_test.exs`
  unit pins; `catalog_test.exs` fixer-input assertion updated.

### Key decisions/answers discovered during implementation (beyond the plan text)

- **Clear-on-skip**: a classified wave with NO breach while `findings:evidence` is live
  clears the lens even if all claims skipped (vendor-arm fixer redo) — can't-verify ⇒
  trust; documented in evidence-floor.md residuals.
- **Grep-filtered runs land `form_mismatch`, not fabrication** (ouroboros puts them in the
  fabrication lane) — deliberately kinder; pinned in PORT map edge-case rows.
- **`cat x | mix test` conservatively masks** (residual pipe) — miss-only.
- Failure terminals (`fix_failed` etc.) do NOT carry `evidence_breaches` in the durable
  result — only `:route_converged`'s subset does; the ledger events are the durable
  authority elsewhere.
- The fixer is SUMMONED by `findings:evidence` via its `subscribes: ["findings"]` family
  match on first breach (suppression only gates RE-fires) — the rerun_cap-0 test pins the
  resulting shape.
- `mvn install -DskipTests` / `gradle build --exclude-task=test` are NOT runners (no
  test-family task word) — faithful to source; test rows adjusted accordingly.

### What's next (in order)

1. **Fix the VerifyStub.porcelain_all default** (`""` → `nil`, comment update) and re-run:
   the 5 named tests → `mix test test/jido_claw/route_composer/ test/jido_claw/orchestration/`
   (expect green; the flaky async:false singletons — MCPServer/Prompt/PipelineStore/
   MultiSandbox — are NOT in these dirs).
2. **Commit-2 gates not yet run**: `mise exec -- mix credo --strict` +
   `mise exec -- mix reach.check --arch --smells --strict` over the commit-2 lib files
   (route_composer.ex, projection.ex, loop.ex, workflow_event.ex, catalog.ex, verify/git.ex,
   telemetry.ex) and the new test/support files; dialyzer only via the final precommit.
   Watch: route_composer.ex's new `Enum.reduce` in `classify_evidence`/`evidence_report`
   and the multi-clause conds are the usual credo/reach tripwires (commit-1 needed 7 fixes).
3. **Commit 3** (not started — plan sections 3a/3b/3c below are the spec):
   - 3a `orchestration/verify/evidence/ac_extractor.ex` — `Clarify.Scorer` pattern
     (tool-less `Jido.AI.generate_object/3` behind `:ac_extract_generate`/`:ac_extract_model`
     app-env seams, default `:fast`), Zoi schema (`assertions[]` of ac_id/assertion/tier/
     file_hint?/pattern?, pattern length-capped 200, NO expected_value — folded into
     pattern, recorded in PORT map), runs ONCE at composer launch when
     `Premises.criteria_with_ids/1` (premises.ex:54) is nonempty, persisted via
     `parent_config` `maybe_put "ac_assertions"` (the `verify_override` precedent ~:525) +
     restored via `config_then_opts` (~:908); failure ⇒ Trace + slice 2 off.
   - 3b `orchestration/verify/evidence/assertions.ex` — pure `verify/3`, ported bounds
     (50KB/100 files/200 chars), Elixir noise dirs (`_build`,`deps`,`.git`,`node_modules`),
     realpath containment + `..` reject, T3/T4 skip, no-files/invalid-regex ⇒ verified=true,
     ONLY false branch = pattern absent across scanned existing files (`:contradicted`),
     per-assertion bounded Task timeout, injected `:scanner` seam. Fold wiring at the SAME
     `evidence_consumer` point (violated assertions → `Evidence.findings` path, title
     `"AC<n> assertion failed: <assertion>"`, location file_hint || stage). Trace events +
     the eval seed `:composer` case (`composer_vendor_case_test.exs` shape).
   - 3c close-out: ouroboros FEATURES-WORTH-BORROWING OB1-3 Status ADOPTED + corrections;
     camus C1-6 (c) shipped note; OpenHelm OH1-3 #10 rider FOLDED IN + OH-FIRST-WAVE;
     queue README item-10 done-note (fold the existing "Deviations (running)" block into
     it — one deviation logged so far: the Zoi Any encoder).
4. **Gate**: `mise exec -- mix precommit` — bare, in background, read the tail (never
   pipe). Plan complete only when green.
5. Deliver the files-to-stage list + suggested commit messages (bottom of this plan; add
   `core/zoi_any_json_schema.ex` to the commit-1 list and `verify_stub.ex`/`fixtures.ex`/
   `loop_test.exs`/`projection_test.exs`/`catalog_test.exs` to the commit-2 list).

### Working-tree inventory (everything modified/created this session, all unstaged)

Commit-1 shaped: `docs/exploration/ouroboros/PORT-OB1-3.md` (new),
`lib/jido_claw/agent/workers/output_schema.ex`, `lib/jido_claw/core/zoi_any_json_schema.ex`
(new), `priv/defaults/doctrine/evidence_reporting.md` (new), `lib/jido_claw/doctrine.ex`,
`lib/jido_claw/security/shell_command.ex`, `lib/jido_claw/workflows/step_result.ex`,
`lib/jido_claw/skills/steps/agent_runner.ex`, `lib/jido_claw/route_composer/stage_emission.ex`,
`lib/jido_claw/route_composer/emit/default_mapper.ex`,
`lib/jido_claw/route_composer/steps/wave_collect.ex`,
`lib/jido_claw/orchestration/verify/evidence.ex` (new),
`lib/jido_claw/orchestration/verify/evidence/reader.ex` (new) + tests:
`test/jido_claw/security/shell_command_test.exs`,
`test/jido_claw/orchestration/verify/evidence_test.exs` (new),
`test/jido_claw/doctrine_test.exs`, `test/jido_claw/agent/workers/worker_output_schemas_test.exs`,
`test/jido_claw/route_composer/default_mapper_test.exs`,
`test/jido_claw/route_composer/stage_emission_test.exs`.

Commit-2 shaped: `lib/jido_claw/orchestration/workflow_event.ex`,
`lib/jido_claw/route_composer/projection.ex`, `lib/jido_claw/route_composer/route_composer.ex`,
`lib/jido_claw/route_composer/loop.ex`, `lib/jido_claw/route_composer/catalog.ex`,
`lib/jido_claw/orchestration/verify/git.ex` (`porcelain_all/1`),
`lib/jido_claw/core/telemetry.ex`, `docs/system/evidence-floor.md` (new),
`docs/system/README.md`, `AGENTS.md` + tests/support:
`test/jido_claw/route_composer/evidence_floor_test.exs` (new),
`test/support/jido_claw/verify_stub.ex` (REGRESSION FIX PENDING),
`test/support/jido_claw/route_composer/fixtures.ex`,
`test/jido_claw/route_composer/loop_test.exs`,
`test/jido_claw/route_composer/projection_test.exs`,
`test/jido_claw/route_composer/catalog_test.exs`.

Also: `docs/plans/unadopted-next-ten/README.md` (the running deviations block under the
item-10 heading — extend it as commit 3 lands).

Scratch (not for staging): ouroboros source extracts under the session scratchpad
(`/private/tmp/claude-501/...-jido-radclaw/.../scratchpad/ouroboros/`).

---

## Context

Worker stages (coder/fixer) self-report through typed envelopes — `status: :completed`,
`files_changed`, prose — and **nothing cross-checks the claims against the transcript we
already store durably**. A fixer that says "tests green" without a test invocation in its
tool rows, or with the invocation piped through a filter that masks the exit code, is
precisely the false-green the review loop exists to catch — and catching it is a pure fold
over data we already persist (`Conversations.Message` tool rows carry every in-process
command + exit code; `Verify.Git` gives engine-side porcelain). The house no-masked-gates
rule ("pipes mask exit codes and have shipped a false green before") exists only as memory;
ouroboros codified it as an analyzer. Upstream lesson (#1202): as a hard executor gate this
broke layered scaffolds; as verify-stage input it's all upside — so everything here is
findings-only, never a gate.

**Ratified decisions (operator, 2026-07-08):**
1. Slice 2 (extract-assertions-from-ACs, ouroboros `verification/` package) IS in scope — commit 3.
2. Findings are **engine-synthesized**, riding Hook R (trust-boundary law 2: the deterministic
   verdict never rides an LLM relay); the classification block also threads into the next
   review wave's context for diagnosis.
3. v1 classifies **all three claim kinds** (tests_passed, commands_run, files_touched).
4. Classifier lives at **`JidoClaw.Orchestration.Verify.Evidence`**.

Conservative override rule governs everything: only ever flip a **claimed pass** on a
**positive discrepancy**; can't-verify ⇒ trust the agent. Masking (`form_mismatch`) is
findings-only-context in v1 — it never flips anything.

---

## Step 0 — PORT-OB1-3.md + sign-off (BEFORE any code)

House rule (docs/exploration/README.md): BORROW-PATTERN with fidelity-critical semantics ⇒
write `docs/exploration/ouroboros/PORT-OB1-3.md`, get an **explicit, dated sign-off act**
(plan approval does NOT count). Follow the PORT-OB1-2 template: header pins
`Q00/ouroboros @ e905a41c` (MIT) **plus a drift note** — HEAD `98d3d66d` refactored the
evidence code out of `parallel_executor.py` into `src/ouroboros/orchestrator/evidence/`
(`verification.py`, `claims.py`, `shell_parsing.py`) + `failure_taxonomy.py` +
`verification/{verifier,models,extractor}.py`, behavior intact — read shapes at HEAD,
anchor fidelity claims at the pin. OpenHelm rider is **BUSL-1.1 ⇒ shape/inspiration only,
no code transcription** (the PORT-OB1-2 precedent).

Source semantics the map must pin verbatim:
- Per-claim classification `supported | unsupported | form_mismatch`; verdict-level
  `EVIDENCE_FORM_MISMATCH` **only when every unsupported claim is a masking case**
  (`len(evidence_form_mismatches) == len(unsupported)`); one genuinely-absent claim ⇒
  `FABRICATION_SUSPECTED` (evidence/verification.py:127-143).
- Self-report exclusion (`messages[:-1] if is_final`) — structural for us: we read only
  durable `:tool_call`/`:tool_result` rows, never assistant text.
- Output-filter allowlist `{tail, head, cat, less, more}`; `grep/egrep/fgrep/tee/wc`
  deliberately excluded. pipefail = exactly `["set","-o","pipefail"]` before the filter
  pipeline, carried across `&&`/`;`. Residual pipe after peel ⇒ not provable-clean.
  Gradle/Maven skip flags (`-DskipTests`/`-Dmaven.test.skip` with `=false|0|no|off` not
  skipping; `-x test`/`--exclude-task test`).
- Test-runner table {pytest, py.test, tox, nox; npm|pnpm|yarn test; uv run pytest;
  python -m pytest|unittest; gradle/mvn + test|check|verify} — **house extension: `mix test`**.
- `verification/` package: tiers T1_CONSTANT/T2_STRUCTURAL verified, T3/T4 skipped;
  bounds MAX_FILE_SIZE 50KB, MAX_FILES_PER_HINT 100, MAX_PATTERN_LENGTH 200; no-files/
  invalid-regex ⇒ `verified=true` ("can't verify = trust agent"); discrepancy only when
  `agent_reported_pass and not verified_pass` (models.py).
- OpenHelm shapes (inspiration): count fabrication breaches durably + breach-visibly;
  compaction guard translates to our **absent-transcript skip** (our DB rows are
  compaction-immune — the Recorder writes from `ai.tool.*` signals regardless of context
  compaction); fail-closed never-null is inapplicable (we fail toward *trust*, findings-only).

Decisions the sign-off gate pins (each with my recommendation):
1. **files_touched source**: read the EXISTING required `files_changed` envelope field
   (camus C1-6c's literal target); the evidence block carries only
   `commands_run`/`tests_passed`. Divergence from ouroboros's 3-field record — recorded.
2. **Consumer entry point**: direct-weld fold consumer + reserved `"evidence"` lens (see
   commit 2) — Hook R reused by shape (`build_feedback/4`), not entered through
   `decide_rerun` (which is catalog-driven; a synthetic non-catalog emission is invisible
   to every stall/budget predicate and would break durable-`ran` equivalence).
3. **FindingKey identity for non-file claims**: stable STAGE-SCOPED synthetic location
   token (`"evidence:<stage>:tests_passed"` — keys are location+title, so an unscoped
   token would collapse two same-wave stages' findings into one key under aggregation),
   stable title phrase; varying detail (exit codes) only in `description` — keys must
   not churn across waves or stall detection breaks.
4. **Fixer-concurrency wrinkle**: publishing `findings:evidence` on the implementer wave
   lets the fixer run concurrently with first-pass reviewers. Correct (loop self-heals via
   Hook F + deterministic re-check); accept for v1.
5. **files reconcile is before/after wave-scoped** (operator review finding): a claimed
   path is supported iff its git status CHANGED during this wave — dispatch-time vs
   fold-time snapshots of an untracked-INCLUSIVE porcelain (new `Verify.Git.porcelain_all/1`,
   `--untracked-files=all`; the existing tracked-only `porcelain/1` stays byte-untouched —
   it is verify-integrity load-bearing). Bare `path_exists?` is NOT support (it would let a
   worker claim any pre-existing clean file). Missing before-snapshot (mid-wave
   crash/recovery) ⇒ the files kind is skipped that wave (can't verify ⇒ trust), never the
   permissive fallback. Containment (changed-but-not-claimed = after∖before∖claimed) rides
   the same snapshots, Trace-warning-only in v1.
6. **Masking scope v1**: trailing transforming pipe w/o pipefail, plus ONLY the explicit
   exit-swallow idioms `|| true` / `|| :` / `; true` / `; :`. GENERAL `;`-chain exit
   shadowing — any OTHER trailing command after `;`/`&`, e.g. `mix test ; echo done` —
   is conservatively `:preserved` and out of scope (miss, never false finding).
   `mix precommit` NOT a test-runner (it's the Verify authority's command — double-coverage).
7. **Slice-2 extraction point**: once at launch when ACs exist, persisted in parent config
   (the `verify_override` precedent) — LLM out of the per-wave fold, restart-safe.
8. **Slice-2 ReDoS belt-and-suspenders**: per-assertion scan under a bounded Task timeout
   (in v1; cheap).

---

## Commit 1 — substrate (all inert; nothing consumes it yet)

### 1a. Producer envelope — `lib/jido_claw/agent/workers/output_schema.ex`
- New optional `evidence` field on the two schemas — **schema-PERMISSIVE, mapper-normalized**
  (operator review finding: `Zoi.optional/1` only tolerates ABSENCE — a present-but-malformed
  typed object would fail child parsing and turn an otherwise-valid coder/fixer result into
  repair/infra churn, exactly what a doctrine-prompted advisory field must never do). So:
  `evidence: Zoi.optional(Zoi.any())` (or Zoi's permissive-map equivalent), with the
  expected shape (`%{"commands_run"/"tests_passed" => [string]}`) documented in the
  moduledoc + doctrine slice, and **normalization owned by `DefaultMapper`** (1d): only
  string lists under the known keys survive; any other shape ⇒ `nil` + Trace note ⇒
  posture unchanged. Fail-open end to end — evidence can never manufacture a validation
  failure. All-string surviving values ⇒ inert under `ComposerArtifact.Envelope.normalize/1`
  (the :113-127 round-trip rule). **No `files_touched` field** — decision 1 above.
- Wire into `coder_result/0` (beside optional `signals`, :41-43) and `fixer_result/0`
  (:79-89) ONLY. `builder_fields/0` untouched ⇒ no leak into SystemExecutor/others.
- Absent block ⇒ Zoi drops the key ⇒ parsed map byte-identical to today (the #9
  absent-criteria discipline, satisfied structurally). Vendor deposit path
  (`forge_executor/deposit.ex` → `Jido.AI.Output.parse`) needs no change — a malformed
  vendor-deposited block also sails through the permissive schema and is dropped at the
  mapper (same fail-open). Test pins in `worker_output_schemas_test.exs` (absent /
  present-valid / present-malformed all parse) + a `default_mapper` normalization matrix
  (valid lists survive, malformed ⇒ nil).
- Note (not resolve): unrelated `evidence` string param on `tools/verify_certificate.ex:34-39`.

### 1b. Doctrine slice — `priv/defaults/doctrine/evidence_reporting.md` + `lib/jido_claw/doctrine.ex`
- New slice text (short, `emit_signals.md`-shaped — the prose half of a typed field):
  instruct filling `evidence.commands_run`/`tests_passed` with EXACT invocations run /
  test commands that exited green, and keeping `files_changed` accurate (paths created or
  edited); honesty framing — absent block is fine, fabricated entries are engine-checked;
  never list a test as passed if skipped/filtered/plumbing-swallowed.
- `doctrine.ex`: `@evidence_reporting_priv` + `@external_resource` (the :104-126 pattern),
  `@slices` entry (:128-142), `@template_slices` — coder (:196) + fixer (:202) only.
- `test/jido_claw/doctrine_test.exs`: add to slice/list assertions; coder/fixer
  `=~ "Evidence reporting"`; scope-pin test (refactorer/reviewer/researcher/system_executor
  `refute`). Neither `system_prompt.check` nor `jido_md.check` trips (verified: they compare
  tools/template-names/spawnable/skills; doctrine is runtime-assembled).

### 1c. ShellCommand exit-code provenance — `lib/jido_claw/security/shell_command.ex`
- New nested `Provenance` struct + public `exit_code_provenance/1` (same file — derives
  from the INTERNAL `resolved` `{connector, %Command{}}` list built by the private
  `tokenize`/`coalesce`/`split`/`strip` path, NEVER from public `%Analysis{}`, which loses
  the pipe/`&&`/`;` connector context the plumbing walk needs): returns
  `%Provenance{exit_code: :preserved | :masked | :unknown, test_runner: %{tool, skipped?} | nil}`.
- Deliberately NOT a new effect kind (would become a valid gate matcher via
  `ToolApproval.valid_matcher?/1` → `effect_kinds()`), NOT an `%Analysis` field, NOT new
  structure atoms. `analyze/1`, `@effect_kinds`, the `:opaque` floor: byte-untouched.
- Algorithm: resolve sub-commands (any `:unknown`/parse failure ⇒ `:unknown`); detect
  pipefail-before-pipeline; trailing `:or`/`:semi` into `true`/`:` ⇒ `:masked`; peel
  trailing presentation filters `{tail, head, cat, less, more}` — residual pipe without
  pipefail ⇒ `:masked`; else `:preserved`. Trailing-redirect regex NOT ported — ShellCommand
  already parses redirects structurally (documented divergence).
- Test-runner recognition lives HERE (mechanical shell fact; Evidence owns the claim
  verdict): ported table + `mix test`; skip-flag detection per the port table.
- Attribution line in the moduledoc: `Q00/ouroboros @ e905a41c, MIT`.
- Tests: new `describe` in `test/jido_claw/security/shell_command_test.exs`, table-driven
  (existing style): preserved/masked/unknown matrices + runner recognition + a regression
  block pinning `analyze/1` output unchanged for the same inputs.

### 1d. Threading rails (request_id + evidence to the emission)
- `lib/jido_claw/workflows/step_result.ex`: nilable `request_id` field.
- `lib/jido_claw/skills/steps/agent_runner.ex` `run_recorded/6` (:434): attach the
  engine-minted `request_id` (from `register_child_correlation`) to the success
  `%StepResult{}` — both arms (in-process :420, forge :224). Engine data, never
  agent-relayable.
- `lib/jido_claw/route_composer/stage_emission.ex`: nilable `request_id` + `evidence`
  fields; `from_map/1` reads both tolerantly, fail-closed (malformed ⇒ nil ⇒ posture
  unchanged).
- `lib/jido_claw/route_composer/emit/default_mapper.ex`: set `request_id` from StepResult;
  normalize `evidence` = `%{commands_run, tests_passed, files_touched}` (the internal
  3-kind shape) using the mapper's EXISTING atom/string-tolerant field helpers
  (default_mapper.ex:267 — parsed in-process output is atom-keyed, deposits string-keyed;
  never a literal `typed_output["files_changed"]` read): advisory lists from the optional
  `evidence` block, `files_touched` from the REQUIRED `files_changed` field. Normalization
  is the fail-open boundary (1a) and is **per-key** (operator review finding): a malformed
  advisory block drops only `commands_run`/`tests_passed` — `files_touched` comes from
  `files_changed` and stays populated regardless. Malformed shapes ⇒ dropped with a Trace
  note — never an error.
- `lib/jido_claw/route_composer/steps/wave_collect.ex` `to_map/2`: serialize both
  **only when present** (the `put_outcome` asymmetry — existing persisted maps stay
  byte-identical).
- `VerifyStage.RunVerify.emission/5` sets neither.

### 1e. The pure classifier — `lib/jido_claw/orchestration/verify/evidence.ex` (new)
- **Impure gather** behind a stubbable reader seam (`Evidence.reader()`, config
  `:jido_claw, :evidence` — the `Verify.git()` precedent):
  `gather(request_id, ctx) :: {:ok, observations} | :skip` — decodes
  `Message.by_request(session_id, request_id)` tool rows (command at
  `metadata["arguments"]["command"]`, exit_code at `metadata["result"]["value"]["exit_code"]`,
  handling `TranscriptEnvelope` quirks) plus the wave-scoped changed-path set = the
  status-map diff of the dispatch-time vs fold-time `Verify.Git.porcelain_all/1`
  snapshots (untracked-inclusive; a path counts as changed when its XY status differs,
  including appearing as `??` — parse rename `a -> b` rows). nil request_id / read error
  ⇒ `:skip` (Trace note). Empty tool rows is NOT a skip — files still reconcile (works on
  the vendor arm). **Redaction residual** (operator review finding): sensitive turns
  persist metadata as `%{"redacted" => true}` (recorder.ex:497 path,
  recorder_test.exs:405) — rows with redacted/missing command or result fields are
  EXCLUDED from the evidence base, and if tool rows exist but none are readable the
  transcript kinds skip with reason `:redacted` (Trace note, test-pinned) — degraded,
  never suspicious.
- **Pure classify(claims, observations)** — per-kind:
  - `tests_passed`: matching test invocation in tool rows (normalized match) + exit 0 +
    `exit_code_provenance` unmasked ⇒ supported; matched-but-masked/unanalyzable ⇒
    form_mismatch; matched + nonzero exit ⇒ unsupported (the false-green catch); no
    transcript ⇒ skipped (divergence from ouroboros gate mode — conservative trust).
  - `commands_run`: presence (normalized/substring match tolerant of plumbing) + masking.
  - `files_touched`: `path ∈ wave_changed_set` (the before/after status diff — decision 5)
    ⇒ supported; else unsupported. Per-stage claims reconcile against the WAVE delta
    (union semantics — a file another same-wave stage changed counts as supported; never
    over-flip). No before-snapshot ⇒ this kind skips.
  - Verdict: ouroboros rule — form_mismatch only if ALL unsupported are masking cases;
    any genuine absence ⇒ fabrication_suspected; nothing checked (or `:redacted`) ⇒ skipped.
- **Pure findings(classification)** — the ONE entry point both slices share: synthesize
  `VerifyStage`-shaped finding maps (`%{"severity" => "error", "title", "location",
  "description"}`) ONLY for positive discrepancies (`:unsupported`); stable
  titles/locations (decision 3); plus an `action_needed` summary line.
- Exhaustive unit tests (pure): per-kind matrices, verdict rule, key stability across
  waves, envelope-decode quirks, masked-exit-0 detection.

---

## Commit 2 — the composer consumer + docs

### 2a. Durable vocabulary
- `lib/jido_claw/orchestration/workflow_event.ex`: add `:evidence_classified` to the
  `one_of` (app-level atom stored as text — NO migration; NOT status-authority).
  Bounded redaction-posture payload, AGGREGATE to match the one-event-per-wave shape:
  `%{classifications: [%{stage, request_id, counts, statuses (per-kind
  supported/unsupported/form_mismatch/skipped), breach}], keys}` — never command
  strings/paths/log tails (those live only in the encrypted artifact).
- `lib/jido_claw/route_composer/projection.ex`: `apply_event(:evidence_classified)` folds
  per-stage `evidence_breaches` counts (the `bump_counts` pattern) — the OpenHelm
  "counted, breach-visible" rider. Surface the count in the terminal summary subset.

### 2b. The fold consumer — `lib/jido_claw/route_composer/route_composer.ex`
- New `evidence_consumer/4` called in `handle_wave_value/5` **BEFORE `decide_rerun`**
  (operator review finding — suppression ordering): sequence becomes reviewer
  `finding_keys_markers` (:2046) → evidence classification → `keyed_fold =
  ComposerProjection.apply_markers(next_fold, reviewer_markers ++ evidence
  finding_keys marker ++ evidence signals_published/signals_retracted markers)` →
  `decide_rerun(keyed_fold, …)` AND the evidence re-fire gate read the SAME fully-keyed
  fold. The signal markers MUST be in the temp fold too (operator review finding):
  `rereview_exhausted_lenses` reads `state.live` for `findings:<lens>`, so a FIRST
  breach with the fixer already rerun-capped would otherwise miss cap suppression
  (`findings:evidence` not yet live). This makes THIS wave's evidence round AND live
  signals visible to `suppress_fix_dispatch?` (the camus C1-5 fold-first discipline,
  and #6's whole-Hook-R-suppression-on-a-stop rule) — a repeated evidence fabrication
  can never buy one extra fixer/reviewer wave. All
  evidence markers are appended to the `markers` list (:2050-2057) inside the SAME
  `Commit.commit_wave` weld (crash-window law: breach ledger + publish + re-fire never
  land split from `wave_completed`). Fail-open: any gather/store error ⇒ Trace + no
  markers, never a wave failure.
- Classify each producer emission (lens == nil) whose stage is coder/fixer-templated —
  **eligibility classified from `state.catalog`** (stage name → catalog stage → its
  unit/template), NOT from `WaveBuilder.meta/1` (which passes only
  name/emit/lens/output/publishes; operator review finding — the mapper stays dumb and
  copies fields, the consumer filters) — then **AGGREGATE the whole wave into ONE
  artifact set under producer `"evidence"`** (operator review finding: active-artifact
  uniqueness is `{parent_run_id, name, producer}` and `activate_for_wave` doesn't
  re-index as it walks pending rows — per-emission stores would collide in a
  multi-producer wave; and two `finding_keys` markers for lens `"evidence"` in one wave
  would double-shift the projection's finding round, corrupting stall detection). On any
  breach, store THREE encrypted `ComposerArtifact`s (`store_wave_artifact`, the
  VerifyStage precedent): `findings` (union across breaching stages — per-stage
  attribution in each finding's location/description), `action_needed`,
  `evidence-report` (per-stage sections). One classification pass ⇒ one signal pair ⇒
  one `finding_keys` marker (union of keys) per wave.
- Welded markers (existing kinds + the new ledger): `artifacts_produced` triples;
  **fixer feed via `review_feedback(state', ["evidence"])`** — reuse `build_feedback/4`
  (:4074) unchanged, where **`state'` is explicitly the temp fold with the evidence
  `artifacts_produced` markers already applied** (`build_feedback` reads
  `state.artifacts`, so the freshly stored `findings`/`action_needed` refs must be
  folded in first — the same apply-markers-to-a-temp-fold device as `keyed_fold`),
  producing `review-feedback[evidence]`/`review-action[evidence]`. **Marker append
  order pinned**: evidence `artifacts_produced` → feedback invalidation/production →
  signals + `finding_keys` → `stages_invalidated`;
  **paired signals via EXPLICIT retraction markers** (operator review finding: the
  clean↔findings pairing is `Fold.add_signal/2` behavior for normal `%StageEmission{}`
  signals — welded `signals_published` markers only UNION in
  `Projection.apply_event(:signals_published)`, no automatic pair deletion). So every
  flip welds BOTH deltas: breach ⇒ `signals_published: ["findings:evidence"]` +
  `signals_retracted: ["clean:evidence"]` (when live); a clean re-check (only when a
  prior `findings:evidence` is live) ⇒ `signals_published: ["clean:evidence"]` +
  `signals_retracted: ["findings:evidence"]`. A never-flagged run welds neither, so
  evidence-clean runs stay byte-identical; `stages_invalidated: [fixer]` on a re-flag
  (mirror `fixer_reinvalidation_markers/1`); `{:finding_keys, %{stage: "evidence",
  lens: "evidence", keys, marks}}` — welded on breach AND on the clearing re-check
  (`keys: []`, the round must advance), only while the lens is active (never on
  never-flagged runs); `{:evidence_classified, …}`. **Record vs re-fire split**: the
  RECORD (artifacts, `evidence_classified` ledger, `finding_keys`, the signal pair —
  the honest breach facts that block convergence) always welds; only the RE-FIRE
  markers (feedback production + `stages_invalidated`) are gated on
  `not suppress_fix_dispatch?(keyed_fold)` — #6's discipline: on a stop, suppress the
  fix dispatch, but the findings still stand and the run terminalizes via
  `fix_stop_lenses`. `keyed_fold` already carries THIS wave's evidence round + live
  signals (the 2b ordering) — identical gate to Hook R.
- Porcelain snapshots (decision 5): capture the untracked-inclusive
  `Verify.Git.porcelain_all/1` before-snapshot beside `record_wave_start` in
  `run_built_wave/5` (:1841) on a new state field; at fold take the after-snapshot,
  status-map diff ⇒ the wave changed-set feeding the files reconcile; containment
  (`after ∖ before ∖ claimed`) ⇒ Trace warning only. Missing before-snapshot ⇒ files
  kind skips this wave.

### 2c. Reserved lens predicates (the "re-review is free" answer)
Evidence re-checks deterministically every wave, so the evidence lens itself costs no
budget; **the evidence lens's budget IS the fixer stage's existing rerun count — no
dedicated evidence counter** (operator review finding; the existing predicates are
catalog-stage-based and evidence has no stage counter to scan). Single
`review_lenses(state)` helper = catalog forward lenses ∪ (`"evidence"` iff active in
`finding_rounds`), used by:
- `forward_review_lenses/1` (:2281) + `stall_evidence/1` (:2258) — stuck/oscillating
  fabrication keys stall;
- `rereview_exhausted_lenses/1` (:2232) — include `"evidence"` when `findings:evidence`
  is live AND the fixer stage is rerun-capped (suppresses the doomed re-fire);
- `exhausted_fix_lenses/1` (:4958) — include `"evidence"` on the same fixer-capped
  condition: terminal precision `{:fix_failed, ["evidence", …]}`.
- `lib/jido_claw/route_composer/loop.ex` `terminal/2`: live `findings:evidence` ⇒
  `:not_converged` (closes the fixer-less-route hole).

### 2d. Review-context threading + telemetry
- `lib/jido_claw/route_composer/catalog.ex`: add `"evidence-report"` to `input.optional`
  of the reviewer stages + fixer (optional inputs with no catalog producer are not
  validated and add no DAG edge — the `review-feedback` precedent). `ArtifactContext`
  then renders `### evidence-report` into the next review wave automatically. One
  sentence in the reviewer/fixer task strings: an evidence-report block is an
  engine-verified signal — treat as ground truth, diagnose the cause.
- `Trace.emit(:composer, %{event: :evidence_classified | :evidence_skipped, …})` (the
  `VerifyStage.observe` shape); telemetry counters `jido_claw.evidence.total` (by verdict)
  + `jido_claw.evidence.breach.total` via `lib/jido_claw/telemetry.ex`.

### 2e. Docs (same change — `system_docs.check` enforces the pairing)
- New `docs/system/evidence-floor.md` (mechanics, config, the vendor-arm asymmetry,
  masking table, residuals) + index row in `docs/system/README.md`.
- New AGENTS.md Key Patterns bullet (load-bearing contract inline, pointer to the page).

### 2f. Composer integration tests
`test/jido_claw/route_composer/evidence_floor_test.exs` (non-async TenantCase, the
`verify_stage_test.exs` template): stub workers whose coder emission carries an evidence
block + stub the `Evidence.reader()` seam (canned tool rows — the runtime-minted
request_id is why a raw row-seed races). Assert: breach path (artifacts stored, feedback
welded, `findings:evidence` published, markers in the WorkflowLog, fixer re-fires,
evidence-report in the next review wave's context, breach count projected); clean
re-check retracts and converges; unfixable fabrication → stall/cap →
`{:fix_failed, ["evidence"]}`; vendor-arm zero-tool-rows → tests skipped, files still
reconciled; redacted-metadata rows → transcript kinds skip `:redacted`, never
suspicious; never-flagged run publishes no evidence signals (byte-identical fold);
**multi-producer wave** (two eligible producers, both breaching) → ONE aggregated
artifact set + ONE `finding_keys` marker, commit succeeds, both stages attributed;
**first evidence breach with the fixer already at rerun cap** → the temp-folded
`findings:evidence` triggers cap suppression (no feedback/`stages_invalidated` welded,
record markers still land) and the run terminalizes cleanly as
`{:fix_failed, ["evidence", …]}`;
recovery — project the log, assert `project == in-memory`.

---

## Commit 3 — slice 2 (AC assertions) + item close-out

### 3a. Extractor — `lib/jido_claw/orchestration/verify/evidence/ac_extractor.ex` (new)
- The `Clarify.Scorer` pattern: tool-less `Jido.AI.generate_object/3` behind app-env seams
  (`:ac_extract_generate`, `:ac_extract_model`, default `:fast` — extraction quality
  affects recall only; every conservative branch returns verified=true, so a cheap model
  can never manufacture a false finding). Never-raises.
- Zoi schema: `assertions[]` of `%{ac_id ("AC1"…), assertion, tier (string enum
  T1_CONSTANT/T2_STRUCTURAL/T3_BEHAVIORAL/T4_UNVERIFIABLE), file_hint?, pattern?}` —
  pattern is a regex STRING, length-capped 200.
- Runs ONCE at composer launch when ACs exist — feed the extractor
  `Premises.criteria_with_ids/1` (premises.ex:48, already returns the stable
  `{"AC1", text}` pairs; never reconstruct ids positionally — operator review finding);
  persisted via `parent_config/3` `maybe_put "ac_assertions"`
  (:525 `verify_override` precedent) + restored via `config_then_opts` (:908) — LLM out
  of the per-wave fold, restart-safe. Extraction failure ⇒ Trace + slice 2 off for the
  run (fail-open, the #8 scorer-failure precedent).

### 3b. Verifier — `lib/jido_claw/orchestration/verify/evidence/assertions.ex` (new, pure)
- `verify(assertions, project_dir, opts)` → per-assertion
  `%{ac_id, tier, verified, reason}`. Ported bounds: 50KB/file, 100 files/hint, 200-char
  pattern. `Regex.compile/1` (handle errors ⇒ verified=true); bounded glob under
  project_dir, reject `..`; no hint/no files ⇒ verified=true; T3/T4 skipped; the ONLY
  false branch: pattern absent across scanned files that existed (`:contradicted`).
  Per-assertion scan under a bounded Task timeout (decision 8). Injected `:scanner` seam
  for hermetic tests.
- Fold-point wiring: at the same `evidence_consumer` point, when `state.ac_assertions`
  present and a producer completed, verify; violated assertions feed the SAME
  `Evidence.findings` path — title `"AC<n> assertion failed: <assertion>"`, location =
  file_hint (else stage name) ⇒ keyable, stable across waves (assertions cached once).
- Trace `:ac_assertions_extracted` / `:ac_assertion_result`; extend the eval seed with a
  `:composer` case (the #9 `composer_vendor_case_test.exs` shape): premises with an AC +
  a tree violating a T1 assertion + a completing producer ⇒ the finding appears and rides
  Hook R; extractor-seam failure ⇒ run converges, no finding.

### 3c. Item close-out (the queue habit — each item ends by reconciling its sources)
- `docs/exploration/ouroboros/FEATURES-WORTH-BORROWING.md`: OB1-3 Status ADOPTED line +
  corrections (files_touched reads the existing `files_changed`; the vendor-arm
  asymmetry; the skip-not-fail divergence); answer OQ-3 inline.
- `docs/exploration/camus/FEATURES-WORTH-BORROWING.md`: C1-6 Status — (c) now shipped
  here (flip direction + Trace-only containment).
- `docs/exploration/pms/openhelm/FEATURES-WORTH-BORROWING.md` + `OH-FIRST-WAVE.md`:
  the #10 rider FOLDED IN (breach counting = the marker + projection counter; compaction
  guard = the absent-transcript skip).
- `docs/plans/unadopted-next-ten/README.md`: item 10 done-note with corrections to the
  entry's claims (e.g. "JidoClaw.Verify.Evidence" → `Orchestration.Verify.Evidence`;
  the C1-6c files source) — the queue's standing habit.

---

## What is deliberately OUT (documented, not built)

- Held-stage enforcement for files divergence ("Trace warning first, held stage later" —
  the later half is explicitly post-v1 in the item text).
- General `;`-chain/background exit shadowing beyond the explicit `; true`/`; :` idioms
  (which ARE detected), subshell exit semantics, `--no-verify`-class flags beyond the
  Maven/Gradle table (git `--no-verify` is already a gate-side effect).
- `mix precommit` as a recognized test runner (Verify authority owns it).
- Sketch routes: evidence applies to coder/fixer-template producers on code routes.

## Verification

- Per-piece: `mise exec -- mix test test/jido_claw/orchestration/verify/evidence_test.exs`
  (+ shell_command_test.exs, doctrine_test.exs, worker_output_schemas_test.exs,
  evidence_floor_test.exs, the eval case).
- End-to-end (the composer integration test IS the drive — it runs the real composer
  through breach → fixer re-fire → clean → converge); optionally a live REPL route with a
  deliberately fabricated tests_passed claim.
- Gate: `mise exec -- mix precommit` — run BARE in background and read the output tail
  (never pipe the gate; pipes mask exit codes). Flaky-suite caveat: the known async:false
  singletons (MCPServer/Prompt/PipelineStore/MultiSandbox) move under load — verify in
  isolation before blaming the change.
- The plan is complete only when `mix precommit` passes.

## Deviations log

Record every deviation as it happens in the item-10 done-note territory of
`docs/plans/unadopted-next-ten/README.md` (the queue's convention) — what the plan
assumed, what the code revealed, what was chosen and why.

## Files to stage (by commit) + suggested messages

1. `feat: evidence floor substrate — envelope block, doctrine slice, shell provenance, emission rails (OB1-3 commit 1)`
   — output_schema.ex, doctrine.ex + priv/defaults/doctrine/evidence_reporting.md,
   shell_command.ex, step_result.ex, agent_runner.ex, stage_emission.ex,
   default_mapper.ex, wave_collect.ex, orchestration/verify/evidence.ex + tests +
   docs/exploration/ouroboros/PORT-OB1-3.md.
2. `feat: evidence floor consumer — fold classification, engine findings on Hook R, breach ledger (OB1-3 commit 2)`
   — route_composer.ex, loop.ex, projection.ex, workflow_event.ex, catalog.ex,
   orchestration/verify/git.ex (`porcelain_all/1`), telemetry.ex,
   docs/system/evidence-floor.md, docs/system/README.md, AGENTS.md + tests.
3. `feat: evidence floor slice 2 — AC assertion extraction + verification (OB1-3 commit 3)`
   — ac_extractor.ex, assertions.ex, route_composer.ex (launch threading + fold wiring),
   eval case + tests, inventory reconciliations + queue done-note.

No git mutations by the agent — files land unstaged; the operator stages and commits.
