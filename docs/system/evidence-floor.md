---
type: subsystem
description: Claims vs transcript — the engine cross-checks worker self-reports against durable tool rows and bounded wave filesystem evidence; findings-only, never a gate.
sources:
  - lib/jido_claw/orchestration/verify/evidence.ex
  - lib/jido_claw/orchestration/verify/git.ex
  - lib/jido_claw/orchestration/verify/evidence/reader.ex
  - lib/jido_claw/orchestration/verify/evidence/ac_extractor.ex
  - lib/jido_claw/orchestration/verify/evidence/assertions.ex
  - lib/jido_claw/security/shell_command.ex
  - lib/jido_claw/route_composer/route_composer.ex
  - lib/jido_claw/route_composer/emit/default_mapper.ex
  - lib/jido_claw/route_composer/stage_emission.ex
  - lib/jido_claw/route_composer/projection.ex
  - lib/jido_claw/route_composer/catalog_validator.ex
  - lib/jido_claw/agent/workers/output_schema.ex
  - lib/jido_claw/doctrine.ex
verified: 2026-07-10
verified_sha: "b2cae5cd"
---

# Evidence Floor (claims vs transcript)

## What & why

Worker stages (coder/fixer) self-report through typed envelopes — `status:
:completed`, `files_changed`, an optional advisory `evidence` block — and the
evidence floor is the deterministic cross-check: every claim is classified
against the transcript the engine already stores durably
(`Conversations.Message` tool rows carry every in-process command + exit code)
and against bounded wave filesystem evidence (git status transitions plus
content fingerprints for paths that were already dirty). A fixer that says "tests green" with
no test invocation in its tool rows, or with the invocation piped through a
filter that masks the exit code, is precisely the false-green the review loop
exists to catch — and catching it is a pure fold over data we already
persist. Port of ouroboros's anti-fabrication verifier; semantics map +
sign-off: [PORT-OB1-3](../exploration/ouroboros/PORT-OB1-3.md)
(`Q00/ouroboros @ e905a41c`, MIT), absorbing camus C1-6c (files ↔ porcelain
reconcile) with the OpenHelm OH1-3 rider (breach counting; the compaction
guard folds in as the absent-transcript skip — our rows are
compaction-immune, the Recorder writes from `ai.tool.*` signals regardless of
context compaction).

Two laws govern everything (upstream lesson #1202: as a hard executor gate
this broke layered scaffolds; as verify-stage input it's all upside):

1. **Findings-only, never a gate.** No classification ever fails a wave,
   blocks an emission, or manufactures a validation error.
2. **The conservative override rule.** Only a *positive discrepancy*
   (`:unsupported`) ever becomes a finding; can't-verify skips toward trust,
   and masking (`:form_mismatch`) is findings-only-context in v1 — it never
   flips anything.

## Invariants & contracts

- **Self-report exclusion is structural**: the evidence base is durable
  `:tool_call`/`:tool_result` rows (`Message.by_request`), never assistant
  text — a claim cannot support itself (`evidence.ex`).
- **Verdict partition (ouroboros-verbatim)**: any genuinely-absent claim ⇒
  `:fabrication_suspected`; all-masked ⇒ `:form_mismatch`; nothing checked ⇒
  `:skipped` (trust). Findings are ENGINE-synthesized (trust-boundary law 2 —
  the deterministic verdict never rides an LLM relay) and ride Hook R by
  shape (`build_feedback/4`), never through `decide_rerun`.
- **Three claim kinds** (v1, all classified): `tests_passed` (matching test
  invocation + exit 0 + unmasked provenance + no skip flags ⇒ supported;
  matched + nonzero exit ⇒ unsupported — the false-green catch),
  `commands_run` (recorded-command containment + provenance), and
  `files_touched` — read from the REQUIRED `files_changed` envelope field
  (the advisory block carries only the first two) and supported iff the
  path's git status CHANGED this wave, or an already-dirty path has two
  bounded fingerprints whose content/type/mode identity differs
  (dispatch-time vs fold-time; union across same-wave stages). **Bare
  existence is never support**; missing/unreadable fingerprints add no proof,
  and a missing before-porcelain snapshot (mid-wave crash/recovery) skips the
  kind, never the permissive fallback.
- **Fail-open end to end**: the envelope `evidence` field is
  schema-PERMISSIVE (`Zoi.optional(Zoi.any())` — present-but-malformed must
  never cause repair/infra churn; shape enforcement is `DefaultMapper`'s
  per-key normalization, malformed ⇒ dropped + Trace note); the consumer
  rescues every gather/classify/store fault to a Trace'd no-op.
- **FindingKey stability** (stall detection depends on it): one finding per
  breaching (stage, kind) with a stable title and the stage-scoped location
  `evidence:<stage>:<kind>`; varying detail (exit codes, claim values) rides
  only the description.
- **Record vs re-fire split**: on a breach, the RECORD markers (the three
  encrypted artifacts, the signal pair, the `finding_keys` round, the
  `evidence_classified` ledger) ALWAYS weld — honest breach facts block
  convergence; only the RE-FIRE markers (the fixer feedback + its
  `stages_invalidated`) are gated on `suppress_fix_dispatch?` over the SAME
  fully-keyed temp fold `decide_rerun` reads — a repeated fabrication can
  never buy an extra fixer wave, and a suppressed run terminalizes
  `{:fix_failed, ["evidence", …]}`.
- **Paired signal flips are explicit**: welded markers only union, so every
  flip welds BOTH deltas — breach ⇒ publish `findings:evidence` (+ retract
  `clean:evidence` when live); a clearing re-check (only while
  `findings:evidence` is live) ⇒ publish `clean:evidence` + retract
  `findings:evidence`, with a `keys: []` `finding_keys` round (the round
  must advance). A never-flagged run welds nothing — byte-identical fold.
- **One aggregate per wave**: multi-producer waves classify per stage but
  store ONE artifact set under producer `"evidence"` (active-artifact
  uniqueness is `{parent_run_id, name, producer}`) and weld ONE
  `finding_keys` marker (union of keys) — two markers for one lens in one
  wave would double-shift the projection's finding round.
- **The evidence lens's budget IS the fixer's rerun count** (it has no
  catalog stage or counter; its re-check is deterministic and free):
  `rereview_exhausted_lenses` includes `"evidence"` at `>= rerun_cap`,
  `exhausted_fix_lenses` at `> rerun_cap`, and `Loop.terminal/2` holds a
  live `findings:evidence` at `:not_converged` (the fixer-less-route hole).
- **No masked gates**: `ShellCommand.exit_code_provenance/1` is the codified
  house rule ("pipes mask exit codes and have shipped a false green
  before") — read-side only, never consulted by the approval gate, NOT an
  effect kind (it must never become a gate matcher).
- **`"evidence"`/`"evidence:ac"` are validator-reserved tokens** (stage
  names + the `"evidence"` lens; `CatalogValidator` invariant 12) — nothing
  else bans colons in stage names, so a real stage could otherwise alias
  the floor's synthetic producer/lens/ledger identity.

## Mechanics

Producer side: the `coder`/`fixer` result schemas carry the optional
`evidence` block (`%{"commands_run"/"tests_passed" => [string]}`,
`output_schema.ex`); the `:evidence_reporting` doctrine slice
(`priv/defaults/doctrine/evidence_reporting.md`) is its prose half, scoped to
exactly those two templates. `AgentRunner.run_recorded/6` stamps the
engine-minted `request_id` onto the success `%StepResult{}` on BOTH executor
arms; `DefaultMapper` copies it and normalizes the claims onto the
`%StageEmission{}` rails (`request_id` + `evidence`, serialized
only-when-present by `WaveCollect`, whitelist-decoded fail-closed by
`StageEmission.from_map/1`).

Consumer side (`route_composer.ex`): `run_built_wave` captures the
dispatch-time `porcelain_all` snapshot plus bounded, symlink-safe fingerprints
for the paths already dirty/untracked on producer waves (in-memory only —
recovery loses them and the files kind skips). A rebuild that finds
`wave_started(N)` without `wave_completed(N)` records that open wave index and
deliberately suppresses a replacement baseline during idempotent child rebind;
otherwise a completed child could be compared post-edit→post-edit and falsely
accused. The marker naturally expires when the wave index advances. At the fold, it fingerprints
the union of before/after snapshot paths. `Verify.Git.path_fingerprints/3`
single-sources the verify-authority bounds (1,000 paths, 10 MiB aggregate,
4,096-byte paths), hashes regular content and type/mode, hashes symlink target
text without following it, and omits individually unavailable paths for this
findings-only consumer; a global bound failure yields no added content proof.
Then
`evidence_record_markers/3` classifies each eligible emission (catalog-decided:
`lens: nil` + `unit: {:worker_template, "coder" | "fixer"}`) via
`Evidence.gather/2` (the `reader/0` seam: `config :jido_claw, :evidence,
reader: module`) + `Evidence.classify/2`, aggregates discrepancies, stores
`findings`/`action_needed`/`evidence-report` under producer `"evidence"`
(the VerifyStage precedent), and welds in the pinned order: evidence
`artifacts_produced` → feedback invalidation/production → signals +
`finding_keys` + `evidence_classified` → `stages_invalidated` — all inside
the same `Commit.commit_wave` weld (the crash-window law). The fixer feed
reuses `review_feedback(keyed_fold, ["evidence"])` — the temp fold carries
the fresh artifacts, so `build_feedback` resolves them into
`review-feedback[evidence]`/`review-action[evidence]`; the fixer's
`subscribes: ["findings"]` family-matches `findings:evidence`, so a
never-ran fixer is summoned by the live signal and an already-ran one is
re-fired by `stages_invalidated`.

Review-context threading: `evidence-report` is an optional producerless
input on the four reviewers and the fixer (no catalog producer ⇒ no DAG
edge — the `review-feedback` precedent), so `ArtifactContext` renders the
per-stage diagnosis into the next review wave automatically; the reviewer
and fixer task strings pin it as an engine-verified signal.

Durability: `:evidence_classified` (app-level atom, NOT status-authority)
carries the bounded redaction-posture ledger — per-stage
`{stage, request_id, counts, statuses, breach}`, plus a top-level
`ac: %{total, violated}` section whenever AC assertions were verified on a
welded record (breach AND clear paths, the honest record; uniq'd violated
AC ids only, never assertion text — an AC-less run omits the key, keeping
existing events byte-identical) — never command strings, paths, or log
tails (those live only in the encrypted artifacts). The projection folds
per-stage `evidence_breaches` counters (the OpenHelm "counted,
breach-visible" rider), with AC violations counted under the reserved
synthetic `"evidence:ac"` key (+1 per breaching wave), surfaced in the
terminal summary (and its durable subset) only when nonzero.

## Slice 2 — AC assertions (spec vs tree)

The second half of the ouroboros port (`verification/` package): the run's
acceptance criteria (item 9's typed premises) are converted ONCE at composer
launch into machine-checkable assertions, then deterministically re-verified
against the project tree at every producer-wave fold — violations feed the
SAME discrepancy → findings → Hook R path as the claim kinds.

- **Extraction** (`Evidence.ACExtractor`): one tool-less
  `Jido.AI.generate_object/3` call (temperature 0, the `Clarify.Scorer`
  posture) fed `Premises.criteria_with_ids/1`'s stable `{"AC1", text}` pairs
  — never positional reconstruction. Runs in `create_parent_run/1` BEFORE
  the genesis transact (an LLM call never rides a DB transaction); the
  result persists via `parent_config` `"ac_assertions"` (the
  `verify_override` precedent) and restores through `config_then_opts` —
  restart-safe, the LLM stays out of the per-wave fold (ouroboros's per-seed
  LRU cache, made durable). Assertion shape:
  `%{"ac_id", "assertion", "tier", "file_hint"?, "pattern"?}` — the source's
  `expected_value` is deliberately folded INTO the pattern. Extraction
  failure, an empty extraction, junk tiers (⇒ `T4_UNVERIFIABLE`), and
  assertions citing an invented ac_id (⇒ dropped) are all fail-open: Trace +
  slice 2 off for the run. The fan-out is capped at 50 assertions.
- **Verification** (`Evidence.Assertions`, pure over the injected `:scanner`
  seam): T1_CONSTANT/T2_STRUCTURAL verify by bounded regex scan
  (ported bounds: 50KB/file, 100 files/hint, 200-char pattern); T2 first
  accepts a case-insensitive basename match ("the file exists" is
  structural support). T3/T4 skip. **Every can't-verify branch trusts**
  (verified=true): no hint (deliberately NO default glob — bounded fold
  cost), no matching files, invalid/over-long regex, a nil project dir, a
  timed-out scan (each assertion runs under a bounded `Task` timeout,
  default 2s — decision 8's ReDoS belt-and-suspenders). The ONLY false
  branch: a compiled pattern absent across scanned files that existed
  (`:contradicted`). Traversal hints (`..`) reject; matched paths must
  expand under the project root and symlink entries are dropped unread.
- **Finding identity**: title `"AC<n> assertion failed: <assertion>"`
  (launch-cached ⇒ stable), location = the extractor's `file_hint` (a
  violation always has one — contradiction requires scanned files), with a
  synthetic `evidence:ac:<id>` token as the defensive fallback. Never the
  emitting stage name, which would churn the FindingKey coder→fixer across
  waves (a logged deviation from the plan's "else stage name").
- A violated assertion keeps `findings:evidence` live wave after wave (the
  tree, not a claim, is wrong), so a fixer that never satisfies the AC walks
  the same stall/budget path to `{:fix_failed, ["evidence", …]}`; a
  fixer-less route parks at the honest `:not_converged`. Violations are
  counted in the durable breach ledger under `"evidence:ac"` and tag the
  breach telemetry the same way; the encrypted evidence-report gains an AC
  section listing each violated assertion + reason.

## The vendor-arm asymmetry

Vendor-executed stages (`{:forge, :codex | :claude_code}`) run their tool
calls inside the vendor CLI — those never ride our pipeline, so no
`run_command` rows exist. The transcript kinds then skip
(`{:skip, :no_transcript}` — conservative trust), while `files_touched`
still reconciles against the wave git diff (the snapshots are engine-side).
An in-process worker that ran zero commands is indistinguishable from the
vendor arm by row presence and also skips — an accepted miss. Rows whose
metadata was sensitivity-scrubbed (`%{"redacted" => true}`) are excluded;
an all-scrubbed transcript skips `:redacted` — degraded, never suspicious.

## Masking table (ShellCommand.exit_code_provenance/1)

| Line shape | exit_code | Why |
| --- | --- | --- |
| `mix test` (clean invocation, redirects fine) | `:preserved` | Nothing consumes the exit. |
| `mix test 2>&1 \| tail -20` | `:masked` | Presentation-filter pipe without pipefail — the classic false green. |
| `set -o pipefail && mix test \| tail -5` | `:preserved` | Exactly `["set","-o","pipefail"]`, set BEFORE the pipeline, carried across `&&`/`;`. |
| `mix test \| grep -i pass` (also `wc`, `tee`) | `:masked` | Transforming filters are never peelable — residual pipe is never provable-clean, pipefail or not. |
| `cat x \| mix test` | `:masked` | Upstream feed — conservatively residual (miss, never false finding). |
| `mix test \|\| true` / `\|\| :` / `; true` / `; :` | `:masked` | The explicit exit-swallow idioms, pipefail-immune. |
| `mix test ; echo done` | `:preserved` | General `;`/`&` shadowing is deliberately out of scope (documented miss). |
| `$CMD test`, unrecognized wrapper flags, bounds | `:unknown` | Not provable-clean; classify treats a matched-but-unknown row as `form_mismatch`, never support. |

Runner table: pytest/py.test/tox/nox; npm|pnpm|yarn `test`; `uv run pytest`;
`python -m pytest|unittest`; gradle/gradlew/mvn/mvnw with a
test/check/verify/`:test` task (skip flags — `-DskipTests`,
`-Dmaven.test.skip`, `--define` forms, `-x test`, `--exclude-task test`,
with `=false|0|no|off` NOT skipping — surface as `skipped?: true`, and a
tests_passed claim riding a skip-flagged run is unsupported); house
extension `mix test`. `mix precommit` is deliberately NOT a runner — it is
the Verify authority's command (double-coverage).

## Config & telemetry

- `config :jido_claw, :evidence, reader: module` — the transcript reader
  seam (default `Evidence.Reader`); tests stub it with canned rows (the
  engine-minted request_id is why a raw row-seed would race).
- `:ac_extract_generate` / `:ac_extract_model` app-env seams (slice 2) — the
  extractor's generate fun (default `Jido.AI.generate_object/3`) and model
  (default `:fast`: extraction quality affects recall only — every
  conservative branch downstream trusts, so a cheap model can never
  manufacture a false finding).
- Trace (`:composer`): `evidence_classified` (stage, verdict, counts),
  `evidence_skipped` (half + reason), `evidence_containment`
  (changed-but-unclaimed count — camus C1-6c's Trace-warning-only half),
  `evidence_block_malformed` (the mapper's per-key drop note);
  slice 2 adds `ac_assertions_extracted` (criteria/assertion counts),
  `ac_extract_failed` (bounded reason), `ac_assertion_result`
  (total/violated counts per classified wave).
- Telemetry: `jido_claw.evidence.total` (tags: verdict),
  `jido_claw.evidence.breach.total` (tags: stage — AC violations emit once
  per breaching wave with the synthetic `stage: "evidence:ac"` tag).

## Residuals & accepted risks

- **Transforming-filtered runs land in `form_mismatch`, not fabrication**
  (`mix test | grep pass` claims): ouroboros refuses these into its
  fabrication lane; our provenance-based translation is deliberately kinder
  — a miss, never a false finding (PORT-OB1-3 changed (E)/(F)).
- **Containment is Trace-only** (v1): changed-but-unclaimed paths warn,
  never hold a stage ("held stage later" is explicitly post-v1).
- **Fingerprint proof observes net state, not write history**: an edit restored
  to exactly the same content/type/mode before fold is intentionally
  unprovable. A filesystem change racing between the fold's porcelain and
  fingerprint captures is best-effort fenced per path, not an atomic tree
  snapshot; missing proof leaves the pre-amendment status result unchanged.
- **A clearing re-check trusts skips**: a fixer whose re-do claims are
  unverifiable (vendor arm) clears a live `findings:evidence` — the
  conservative rule; the reviewers and the Verify authority still guard
  actual quality.
- **Claim matching is containment-based** — an echoed command
  (`echo "mix test"`) can back a `commands_run` claim (tests_passed is
  protected by the runner requirement); accepted for v1.
- **The fixer-concurrency wrinkle** (decision 4): `findings:evidence`
  published on the implementer wave lets the fixer run concurrently with
  first-pass reviewers; the loop self-heals via Hook F + the deterministic
  re-check.
- **Mixed producer+reviewer waves can double-bump the fixer's rerun count**
  (evidence re-fire + Hook R in one wave) — conservative (burns budget
  faster, never extends it).
- **Unrelated namesake**: `tools/verify_certificate.ex` has a pre-existing
  `evidence` STRING param (the certificate's free-text evidence field) —
  unrelated to this subsystem, deliberately not renamed.
- **An over-sized (>50KB) or unreadable matched file still counts as
  scanned** (slice 2, source-faithful): its read is skipped, so a pattern
  living only there reads `:contradicted` — a rare false-positive lane the
  source accepts too; the finding's description names the scan bounds.
- **Symlinked intermediate directories are not chased** (slice 2): the
  containment check expands paths and drops symlink FILE entries, but a
  planted in-repo dir-link pointing outside is not resolved — accepted on
  this project's threat model (the scan only ever READS, bounded).
- **Hint-less assertions are never verified** (slice 2, a deliberate
  divergence from the source's `**/*.py` default glob): scanning the whole
  tree per wave is unbounded fold cost; the extractor prompt asks for hints
  and a hint-less assertion trusts.

## Source map

- `lib/jido_claw/orchestration/verify/evidence.ex` — gather/classify/findings
  (the pure classifier + the reader seam)
- `lib/jido_claw/orchestration/verify/evidence/reader.ex` — the default
  `Message.by_request` reader
- `lib/jido_claw/orchestration/verify/evidence/ac_extractor.ex` — the slice-2
  once-at-launch AC → assertion extraction (the `Clarify.Scorer` posture)
- `lib/jido_claw/orchestration/verify/evidence/assertions.ex` — the slice-2
  bounded assertion verifier (+ its default `Scanner`)
- `lib/jido_claw/security/shell_command.ex` — `exit_code_provenance/1`
  (`Provenance`, the masking table, runner recognition)
- `lib/jido_claw/route_composer/route_composer.ex` — the fold consumer
  (`evidence_record_markers/3`, `evidence_refire_markers/2`, the predicates)
- `lib/jido_claw/route_composer/emit/default_mapper.ex` — the fail-open
  claim normalization boundary
- `lib/jido_claw/route_composer/stage_emission.ex` — the `request_id` +
  `evidence` rails
- `lib/jido_claw/route_composer/projection.ex` — the `evidence_classified`
  fold (`evidence_breaches`, incl. the `"evidence:ac"` bump)
- `lib/jido_claw/route_composer/catalog_validator.ex` — invariant 12 (the
  reserved `"evidence"`/`"evidence:ac"` identity tokens)
- `lib/jido_claw/orchestration/verify/git.ex` — `porcelain_all/1` plus the
  shared bounded, race-checked path fingerprint primitive
- `lib/jido_claw/agent/workers/output_schema.ex` — the permissive envelope
  field
- `lib/jido_claw/doctrine.ex` — the `:evidence_reporting` slice scoping
