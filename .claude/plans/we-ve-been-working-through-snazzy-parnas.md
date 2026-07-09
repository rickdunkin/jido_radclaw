# Evidence-floor review remediation (OB1-3 post-review P2 + P3)

## Context

Item 10 (evidence floor, plan `please-review-docs-plans-unadopted-next-hashed-bear.md`) is
code-complete in the working tree, all unstaged. The post-implementation code review found
two issues; **both validated against the code and the ouroboros source** — see verdicts
below. This plan fixes them. **Done criterion: `mise exec -- mix precommit` green.**

## Validation verdicts

**P2 — CONFIRMED (behavior gap, code fix).** AC assertion failures ride the breach path —
`classify_evidence` (route_composer.ex:2393) appends `ac_assertion_discrepancies/1` into
`discrepancies`, so findings/`findings:evidence`/`finding_keys`/fixer-feed all work — but
every durable/observability breach surface derives ONLY from worker-claim statuses:

- `evidence_classified_payload` (route_composer.ex:2669): per-stage `breach` =
  `Enum.any?(classification.claims, &(&1.status == :unsupported))` — AC failures invisible.
- `Projection.apply_event(:evidence_classified)` (projection.ex:214–230): bumps
  `evidence_breaches` only from that flag → AC-only breach folds as a TRUE no-op.
- Breach telemetry (route_composer.ex:2728): same worker-claims check.
- `evidence_report/1` (route_composer.ex:2683): per-emission sections only — no AC section.

Net: an AC-only failure keeps `findings:evidence` live (can terminalize
`{:fix_failed, ["evidence"]}` or `:not_converged`) while `evidence_breaches` reports
nothing, no breach telemetry fires, and the reviewer-facing evidence-report omits the
cause. The eval case `composer_ac_assertions_case_test.exs` asserts terminal + artifact
only — the gap has no coverage.

**P3 — CONFIRMED (docs-only drift).** `assertions.ex:9–14` moduledoc lists "unreadable
files" among the trust branches; the implementation treats a matched-but-unreadable/
oversized file as scanned-with-no-match (`content_match?` :176–181 → `Scanner.read` nil →
false), so if nothing else matches the assertion contradicts. This is **deliberate and
source-faithful**: verified against `~/workspace/research/ouroboros`
`src/ouroboros/verification/verifier.py` (`_read_file` → `None` → `continue` → final
`verified=False` across `len(files)`); pinned by `assertions_test.exs:205`, the
`evidence-floor.md:280` residual, and the queue README done-note deviation (d). Fix the
docs, not the code. The `Scanner` moduledoc ("Any fault reads as 'nothing found' — toward
trust", assertions.ex:47–53) has the same overclaim for the `read/2` half.

---

## P2 fix — AC violations join the durable breach ledger

### Design decisions (repo-derived, stated for the record)

- **Same ledger, RESERVED synthetic key `"evidence:ac"`** in the existing
  `evidence_breaches` map — the OpenHelm rider wants ONE breach-visible rollup; the key
  matches the existing `evidence:ac:<id>` finding-location namespace. Precedent: the
  evidence `finding_keys` marker already uses a synthetic stage token
  (`finding_keys_payload("evidence", …)`). **+1 per breaching wave** (consistent with
  per-stage granularity — a breaching stage bumps once per wave, not per claim).
  `CatalogValidator` does NOT currently ban colons in stage names, so the reservation
  must be enforced, not assumed (operator review point 1) — see the new invariant below.
- **Payload shape**: top-level `ac: %{total: n, violated: [ac_ids]}` on the
  `evidence_classified` payload, present whenever AC assertions were verified on a welded
  record (breach AND clear paths — the honest record, mirroring how `breach: false`
  classifications are already recorded). `total` = assertions verified; `violated` =
  **uniq'd** violated ac_ids (the extractor may emit several assertions per AC). Ids only
  ("AC1"), never assertion text — redaction posture; text lives in the encrypted
  artifacts. Runs without ACs omit the key entirely → existing events byte-identical.
- **Telemetry**: reuse `jido_claw.evidence.breach.total` (tags: `[:stage]`) with
  `stage: "evidence:ac"`, once per wave with violations, emitted post-commit with the
  rest of `emit_evidence_observability`.
- **evidence-report**: gains an AC section when violated ≠ [] (artifact is encrypted —
  full assertion text + reason are fine there).

### Code changes — `lib/jido_claw/route_composer/route_composer.ex`

1. Restructure `ac_assertion_discrepancies/1` (:2419) into `ac_verification/1` returning
   `nil` (no assertions) | `%{total: n, violated: [result]}`; keep the
   `:ac_assertion_result` Trace inside and `ac_discrepancy/1` unchanged.
2. `classify_evidence/3` (:2379): `ac = ac_verification(state)`;
   `discrepancies = worker ++ Enum.map(ac_violated, &ac_discrepancy/1)`; thread `ac` into
   both record arms.
3. `evidence_record/4` (:2353): add an `ac:` field (nil in `evidence_no_record/0`) — the
   one-construction-site discipline holds.
4. `evidence_classified_payload/1` (:2660) → `/2`: maybe-put the `ac` section (both call
   sites: `evidence_breach_routing` :2522, `evidence_clear_record` :2542).
5. `evidence_report/1` (:2683) → `/2`: append
   `## evidence: acceptance criteria — <v> of <t> assertions violated (engine-verified against the project tree)`
   + per-assertion `- [violated] AC<n>: <assertion> — <reason>` lines when violated ≠ [].
6. `emit_evidence_observability/2` (:2712): after the per-classification loop, when
   `record.ac` has violations, execute the breach counter with `stage: "evidence:ac"`.

Watch: new map-literal sites may trip reach `fixed_shape_map` — follow the existing
`# reach:disable-next-line fixed_shape_map` wire-shape precedents in this file.

### Code changes — `lib/jido_claw/route_composer/catalog_validator.ex` (reserve the tokens)

6b. New invariant 12 — **reserved evidence identity**: no catalog stage may be NAMED
    `"evidence"` or `"evidence:ac"`, and no stage may carry `lens: "evidence"` (the
    evidence floor's synthetic producer/lens tokens: artifact producer `"evidence"`,
    `finding_rounds["evidence"]`, and the `"evidence:ac"` breach-ledger key would all
    silently conflate with a real stage). Small `reserved_evidence/1` check appended in
    `validate/1`'s clean branch beside `single_verify/1`; add it to the moduledoc
    invariant list; pin in `test/jido_claw/route_composer/catalog_validator_test.exs`.
    Before landing, grep fixtures/catalogs for `lens: "evidence"` and stages named
    `evidence` to confirm nothing legitimate trips it (none expected — reviewers use
    correctness/security/etc.).

### Code changes — `lib/jido_claw/route_composer/projection.ex`

7. `apply_event(:evidence_classified)` (:214): tolerantly read
   `EventPayload.get(payload, :ac)`; **filter its `violated` list
   (`EventPayload.list/2` — total, but it returns junk lists as-is) to binary ids**, and
   only when THAT filtered list is nonempty append `"evidence:ac"` to the `bump_counts`
   list (operator review point 2). Preserve the TRUE-no-op property for breach-less +
   AC-less events (guard `is_map` on the `ac` value).

### Docs — `docs/system/evidence-floor.md`

8. Durability paragraph (:148–154): document the payload's `ac` section + the
   `"evidence:ac"` ledger key. Slice-2 section (:156–199): one sentence — violations are
   counted in the breach ledger under `"evidence:ac"` and tag the breach telemetry the
   same way. Telemetry bullet (:252–253): note the synthetic stage tag. Invariants
   section: one line — `"evidence"`/`"evidence:ac"` are validator-reserved tokens
   (stage names + the `"evidence"` lens; CatalogValidator invariant 12). Bump
   `verified: 2026-07-09` (sources changed ⇒ `system_docs.check` requires it; keep
   `verified_sha` at current HEAD `39f1cb41` — nothing is committed yet).

### Tests

9. `test/jido_claw/route_composer/projection_test.exs`: unit pins — `ac.violated`
   nonempty bumps `"evidence:ac"` (alongside stage breaches: both bump); `ac` with
   `violated: []`, absent `ac`, and malformed `ac` all fold as no-ops — including the
   non-binary-id case `%{ac: %{violated: [1]}}` (operator review point 2) and a non-map
   `ac`.
10. `test/jido_claw/eval/composer_ac_assertions_case_test.exs` (violated lane): assert
    `run.result.summary.evidence_breaches == %{"evidence:ac" => 1}` (the composer summary
    lives under `run.result.summary` — operator review point 3; in-memory because
    `:not_converged` is failure-family, whose durable result carries disposition+error;
    the event stream is the durable authority, the established `fix_failed` pattern);
    read the run's `:evidence_classified` event and assert
    `payload["ac"]["violated"] == ["AC1"]` + per-stage `breach` all false; add
    `{"evidence-report", "evidence", "AC1"}` to `artifact_contains`.
11. `test/jido_claw/route_composer/evidence_floor_test.exs` (AC-less breach test, ~:208):
    one-line byte-shape pin — `refute Map.has_key?(first.payload, "ac")`.

---

## P3 fix — docs match the pinned oversized/unreadable residual (no code change)

12. `lib/jido_claw/orchestration/verify/evidence/assertions.ex` moduledoc (:9–14): remove
    "unreadable files" from the trust-branch list; add the explicit residual sentence — a
    matched file that is unreadable or over the 50KB cap still counts as scanned (its
    read contributes no match; if nothing else matches, the assertion contradicts) —
    source-faithful (verifier.py skips the read but keeps the file in the scanned count);
    point at the evidence-floor residuals.
13. Same file, `Scanner` moduledoc (:47–53): split the fault claim — a `find/2` fault
    reads as "no files" (trust); a `read/2` fault or over-cap reads as nil (that file
    contributes no match — toward contradiction when nothing else matches).
14. `test/jido_claw/orchestration/verify/evidence/assertions_test.exs` moduledoc (:2–9):
    add the caveat clause ("a matched-but-unreadable/oversized file still counts scanned —
    the pinned residual").
15. `docs/system/evidence-floor.md` residual (:280): widen "over-sized (>50KB) matched
    file" → "over-sized (>50KB) **or unreadable** matched file".
16. `docs/exploration/ouroboros/PORT-OB1-3.md`: add an *Amended at implementation* note
    (the :141-row precedent) on the SpecVerifier bounds row (:163) pinning
    skipped-read-still-counts-scanned (`_read_file` → None → continue → final
    `verified=False` across `len(files)`), since `assertions_test.exs:205` cites this row.

---

## Close-out

17. `docs/plans/unadopted-next-ten/README.md` item-10 done-note: append entry (e) —
    post-review remediation: AC violations joined the durable breach ledger under the
    validator-reserved `"evidence:ac"` key (+ telemetry + report section + CatalogValidator
    invariant 12) [review P2]; assertions moduledoc drift corrected to the pinned
    scanned-counts residual [review P3].
18. `reach_report/` (untracked `mix reach.check` HTML byproduct, one 842KB `index.html`,
    regenerable): **operator cleanup — the agent does NOT delete it** (operator review
    point 4: untracked-file deletions stay explicit/operator-approved). Just never
    staged.
19. `mise exec -- mix format`.

## Verification

1. Targeted: `mise exec -- mix test test/jido_claw/eval/composer_ac_assertions_case_test.exs test/jido_claw/route_composer/projection_test.exs test/jido_claw/route_composer/evidence_floor_test.exs test/jido_claw/route_composer/catalog_validator_test.exs test/jido_claw/orchestration/verify/evidence/assertions_test.exs`
2. Sweep: `mise exec -- mix test test/jido_claw/route_composer/ test/jido_claw/orchestration/`
3. Style gates on touched lib files: `mise exec -- mix credo --strict` +
   `mise exec -- mix reach.check --arch --smells --strict` (route_composer's new
   cond/map-literal shapes are the usual tripwires; ExSlop step-comment wrap trap).
4. **Gate: `mise exec -- mix precommit` — bare, in background, read the output tail
   (never pipe).** Known flaky async:false singletons (MCPServer/Prompt/PipelineStore/
   MultiSandbox) move under load — verify in isolation before blaming the change.
   **The plan is done only when precommit is green.**

## Files touched + staging guidance

`route_composer.ex`, `projection.ex`, `evidence-floor.md`, `assertions.ex`,
`projection_test.exs`, `composer_ac_assertions_case_test.exs`, `evidence_floor_test.exs`,
`assertions_test.exs`, `PORT-OB1-3.md`, queue README — all already on the feature plan's
3-commit staging lists — **plus two files NEW to those lists**:
`lib/jido_claw/route_composer/catalog_validator.ex` and
`test/jido_claw/route_composer/catalog_validator_test.exs` (the reserved-token
invariant; slice-2/commit-3 material). The rest of the remediation folds into the
existing commits. If a visible remediation commit is preferred instead:
`fix: evidence floor review remediation — AC breaches join the durable ledger; assertions doc drift (OB1-3 review P2/P3)`.
No git mutations by the agent; the operator stages and commits.
