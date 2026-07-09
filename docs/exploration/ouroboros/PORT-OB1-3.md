# PORT-OB1-3 — Evidence floor: claims vs transcript (semantics map)

Implements [OB1-3 — Transcript-grounded evidence verification](FEATURES-WORTH-BORROWING.md#ob1-3-transcript-grounded-evidence-verification--the-anti-fabrication-floor),
absorbing [camus C1-6(c)](../camus/FEATURES-WORTH-BORROWING.md) (`files_changed`
reconciled against the wave's porcelain delta) with the
[OpenHelm OH1-3](../pms/openhelm/FEATURES-WORTH-BORROWING.md) rider (count
fabrication breaches; compaction guard). Primary source: `Q00/ouroboros @
e905a41c` (MIT, © 2025 Q00). **Drift note**: HEAD has moved to `98d3d66d`,
which refactored the evidence code out of `orchestrator/parallel_executor.py`
into `src/ouroboros/orchestrator/evidence/` (`verification.py`, `claims.py`,
`shell_parsing.py`, `test_detection.py`, `common.py`) — read side-by-side at
both revisions 2026-07-08: the verdict rule, filter allowlist, pipefail
detection, and test-runner table are behavior-identical (HEAD's
`verification.py:127-143` ≡ pin `parallel_executor.py:6182-6198`; HEAD adds
`has_success_contract`/`verify_gate_active` params to the effective-schema
derivation, out of our scope). Shape refs below cite HEAD's split files for
readability; fidelity claims anchor at the pin. The separate `verification/`
package (slice 2) is unchanged between pin and HEAD except #1551's
structured-AC input type (extractor only, behavior intact). Rider sources:
camus @ `9e353a41` (inventory refs, adoption is shape-level); OpenHelm @
`2facabaa` (**BUSL-1.1** — breach-counting + compaction-guard adopted as
*shape/inspiration only*, no code transcription — the PORT-OB1-2 precedent).
Target: jido_radclaw @ `39f1cb41` + this change. Date: 2026-07-08.

Standing posture (operator-ratified 2026-07-08, restated because every row
below bends toward it): **findings-only, never a gate** (upstream #1202: as a
hard executor gate this broke layered scaffolds; as verify-stage input it's
all upside), and the **conservative override rule** — only ever flip a
*claimed pass* on a *positive discrepancy*; can't-verify ⇒ trust the agent.
Findings are **engine-synthesized** riding Hook R (trust-boundary law 2), v1
classifies all three claim kinds, and the classifier lives at
`JidoClaw.Orchestration.Verify.Evidence`.

## What the source actually does

Ouroboros's `fat_harness` mode replaces its trivial default AC success
(`not message.is_error` + a `[TASK_COMPLETE]` prose marker) with a typed
evidence contract. In their terms:

1. **Typed claims**: the leaf agent must emit an `EvidenceRecord`
   (`commands_run` / `files_touched` / `tests_passed`, string lists)
   validated against a per-task-type profile schema; missing required fields
   are themselves `unsupported` entries (pin `:6132-6137`).
2. **Transcript cross-check** (`_verify_atomic_evidence_against_runtime_messages`,
   pin `:6098-6200`): every claim is checked against the actual tool-call
   transcript, **deliberately excluding the agent's final self-report
   message** (`messages[:-1] if messages[-1].is_final`, pin `:6110`) so
   evidence can't support itself. Empty transcript ⇒ `EVIDENCE_MISSING`.
3. **Field narrowing** (`claims.py:163-173`): `commands_run`/`tests_passed`
   consult only Bash-tool messages; `files_touched` consults all messages.
4. **commands_run**: structured command values (`tool_input.command`/`cmd`/
   `command_line` — never prose) matched via normalized alias sets
   (shell-body unwrap, safe setup preambles `cd`/`export`/env-assignments/
   pipefail, plumbing-stripped variants; `shell_parsing.py:433-476`). A claim
   that matches only a run whose output rode an **unprotected filter
   pipeline** is bucketed `evidence_form_mismatch` AND `unsupported`
   (`claims.py:227-254`) — a real-transcript shape that failed the contract,
   distinguished from fabrication.
5. **tests_passed** (`test_detection.py:261-322`): needs a backed test
   command (a proven `commands_run` entry or the Bash message's own recorded
   command, filtered by the test-runner table) whose result chunk shows
   **conservative test success**: failure words / `exit code [1-9]` veto,
   zero-failure phrasing normalized out first, `0 passed`, "no tests
   found/run", and gradle "no-source/skipped" all reject (`:83-114`); an
   integer `exit_code` in message data is rendered into the scanned text
   (`:117-127`). The claim must target the chunk (node-id file part, summary
   echo). Masked variant ⇒ the same form-mismatch bucketing (`:26-73`).
6. **files_touched** (`claims.py:257-337`): transcript path proof —
   Edit/Write/NotebookEdit structured path values, Bash *output* text pairing
   the path with mutation language (command text alone is not proof), or
   explicit shell-write commands (`>`/`touch`/`tee`/`sed -i`) with adjacent
   success evidence — all workspace-scoped (relative-only claims, no `..`,
   absolutes must resolve inside cwd). Bare file existence is deliberately
   insufficient ("a stale file must not prove this run touched it").
7. **Verdict** (pin `:6182-6198` ≡ HEAD `verification.py:127-143`): any
   unsupported claims ⇒ `FABRICATION_SUSPECTED`, **unless every unsupported
   claim is a masking case** (`len(evidence_form_mismatches) ==
   len(unsupported)`) ⇒ `EVIDENCE_FORM_MISMATCH`. Failure classes feed
   per-class recovery policies (`failure_taxonomy.py:74-96`: retry with
   feedback / redispatch).
8. **The shell analyzer** (pin `:994-1412` ≡ HEAD `shell_parsing.py`):
   output-filter allowlist `_OUTPUT_FILTER_COMMANDS = {tail, head, cat,
   less, more}` (pin `:1292`) — `grep`/`egrep`/`fgrep`/`tee`/`wc`
   deliberately excluded (they transform the stream and can hide failures);
   pipefail is **exactly** `["set", "-o", "pipefail"]` (pin `:1408`),
   carried across `&&`/`;` segments and only protective when set *before*
   the filter pipeline (`shell_parsing.py:394-406`); a **residual pipe after
   peeling** presentation filters refuses extraction (`:258-259` — a
   `pytest x | grep passed` is never provable-clean); trailing output
   redirects (`2>&1`, `> log`, `&> out`) peel via regex (`:316-318`);
   test-runner table `{pytest, py.test, tox, nox; npm|pnpm|yarn test;
   uv run pytest; python -m pytest|unittest; gradle|gradlew|mvn|mvnw +
   test|check|verify|*:test}` (`:261-284`) with Gradle/Maven skip-flag
   detection (`-DskipTests`/`-Dmaven.test.skip` — `=false|0|no|off` NOT
   skipping — `--define` forms, `-x test`, `--exclude-task test`;
   `:192-237`) and env-prefix stripping (`:182-189`).
9. **The `verification/` package** (slice 2; 612 LOC, wired in the evolution
   evaluator): `AssertionExtractor` LLM-extracts tiered assertions from ACs
   once (temperature 0, JSON array of `{ac_index, tier, pattern,
   expected_value, file_hint, description}`; invalid tier → T4; parse
   failure → empty, fail-open; cached by seed). `SpecVerifier` checks
   T1_CONSTANT/T2_STRUCTURAL by bounded regex scan (MAX_FILE_SIZE 50KB,
   MAX_FILES_PER_HINT 100, MAX_PATTERN_LENGTH 200 as ReDoS guard;
   `verifier.py:25-27`), skips T3/T4 (`:101-109`); **no files matched /
   invalid regex ⇒ `verified=True`** ("can't verify = trust agent",
   `:122-134`); pattern absent across scanned files ⇒ `verified=False,
   discrepancy=True` (`:169-174`). `has_discrepancy` = `agent_reported_pass
   and not verified_pass` (`models.py:73-75`) — the flip-only rule;
   `override_approval` returns False only on discrepancies (`:95-102`).
10. **Upstream lesson #1202**: as a hard executor gate the evidence contract
    broke layered scaffolds and was rolled back to opt-in. Our translation
    runs it always but **findings-only**.

The camus rider (C1-6c, inventory sketch (c)): worker `files_changed` claims
reconciled against the `git status --porcelain` delta at wave commit;
divergence is a Trace warning first (observe), a held stage later (enforce —
explicitly post-v1 here). The OpenHelm rider is a *shape*: count fabrication
breaches durably and breach-visibly rather than only demoting the run, and
suppress log-count-based demotion on compacted transcripts.

## Side-by-side shapes

| Ouroboros (source) | jido_radclaw (planned) | Divergence note |
| --- | --- | --- |
| `EvidenceRecord` **required** per task-type profile; missing required fields are `unsupported` entries (pin `:6128-6137`) | Optional advisory `evidence` block on `coder_result`/`fixer_result` only: schema-**permissive** (`Zoi.optional(Zoi.any())`), normalized at `DefaultMapper` (only string lists under `commands_run`/`tests_passed` survive; any other shape ⇒ `nil` + Trace note). Absent/malformed ⇒ posture unchanged, never a validation failure | Deliberate: required-fields semantics belongs to their gate mode (#1202 rolled it back); a doctrine-prompted advisory field must never manufacture repair/infra churn. Their "no concrete claim values ⇒ unsupported" is **dropped** — absence here is fine, silence is not a discrepancy. |
| Three-field record: `commands_run`/`files_touched`/`tests_passed` | Evidence block carries `commands_run`/`tests_passed` only; **`files_touched` reads the EXISTING required `files_changed` envelope field** (camus C1-6c's literal target). Internal classifier shape stays 3-kind | Decision 1 (sign-off): no duplicate self-report field; `files_changed` is already required on both schemas, so the files kind is always classifiable even when the advisory block is absent. |
| Self-report exclusion: `messages[:-1] if is_final` (pin `:6110`) | Structural: evidence base = durable `:tool_call`/`:tool_result` rows via `Conversations.Message.by_request(session_id, request_id)` — assistant text never enters | Same property, stronger carrier (the Recorder writes rows from `ai.tool.*` signals; the final self-report is a parsed envelope, never a tool row). |
| Bash-message narrowing for command kinds (`claims.py:163-173`) | Tool rows filtered to `run_command` tool_name; command at `metadata["arguments"]["command"]`, exit at `metadata["result"]["value"]["exit_code"]` (TranscriptEnvelope quirks handled: atoms persisted as `":atom"` strings, tuples as `%{"__tuple__" => [...]}`) | Same narrowing. Rows with redacted/missing command or result (`%{"redacted" => true}` — the sensitive-scrub path, `recorder.ex:776-780`) are EXCLUDED from the evidence base; tool rows present but none readable ⇒ transcript kinds skip with reason `:redacted` — degraded, never suspicious (no source analogue; their transcripts are never redacted). |
| Test success = conservative text scan over the result chunk (`test_detection.py:83-127`; int `exit_code` rendered into text) | **Structured `exit_code == 0`** read directly from the tool row + invocation match + provenance unmasked | Deliberately changed: we own the executor, exit codes are first-class row data — the text heuristics exist because they parse foreign vendor transcripts. Their veto semantics survive as: matched + nonzero exit ⇒ `unsupported` (the false-green catch). |
| Alias normalization: shell-body unwrap, safe preambles, plumbing-stripped variants (`shell_parsing.py:433-476`) | Normalized/substring match tolerant of plumbing (whitespace-collapse + case-fold; peel via `ShellCommand` resolution) — same tolerance goal, our parser | We already parse deeper than their `shlex` (env prefixes, `-C`, `sudo`, `sh -c`, multiline); the alias-set device is theirs, the parsing substrate ours. |
| Masked form = trailing filter pipeline + invocation extractable when plumbing allowed (`claims.py:227-254`) | `ShellCommand.exit_code_provenance/1` → `%Provenance{exit_code: :preserved \| :masked \| :unknown, test_runner: %{tool, skipped?} \| nil}`, derived from the INTERNAL `resolved` `{connector, %Command{}}` list (`shell_command.ex:544-547`) — never from public `%Analysis{}` (loses connector context). NOT a new effect kind, NOT an `%Analysis` field (`analyze/1`, `@effect_kinds`, the `:opaque` floor byte-untouched) | Same allowlist `{tail, head, cat, less, more}`, same pipefail rule (exactly `["set","-o","pipefail"]`, before the pipeline, across `&&`/`;`), same residual-pipe refusal. House extension (decision 6): explicit exit-swallow idioms `\|\| true` / `\|\| :` / `; true` / `; :` ⇒ `:masked`. General `;`-chain shadowing (`mix test ; echo done`) conservatively `:preserved` — miss, never false finding. Any sub-command `:unknown`/parse failure ⇒ `:unknown`. |
| Trailing-redirect peel regex (`shell_parsing.py:316-318`) | **Not ported** — ShellCommand already parses redirects structurally (`strip/1` drops `{:redirect, _}` tokens) | Documented divergence: the regex exists because they work on raw strings. |
| Test-runner table + Gradle/Maven skip flags (`:261-284`, `:192-237`) | Ported table + **house extension: `mix test`**; skip-flag detection per the port table surfaces as `test_runner.skipped?: true` | `mix precommit` deliberately NOT a test-runner (decision 6): it is the Verify authority's command — recognizing it here would double-cover one invocation with two authorities. |
| files_touched: transcript path proof, existence insufficient (`claims.py:257-337`) | **Replaced**: claimed path supported iff its git status CHANGED during this wave — dispatch-time vs fold-time snapshots of a new untracked-inclusive `Verify.Git.porcelain_all/1` (`--untracked-files=all`; existing tracked-only `porcelain/1` byte-untouched — verify-integrity load-bearing). Status-map diff incl. appearing as `??`; rename `a -> b` rows parsed. Per-stage claims reconcile against the WAVE delta (union — a same-wave sibling's change counts; never over-flip). Missing before-snapshot ⇒ files kind skips this wave. Containment (changed∖claimed) Trace-warning-only | Decision 5. Same core invariant preserved: **bare existence is never support** (their "stale file must not prove this run" ⇒ our "pre-existing clean file can't be claimed"). Engine-side git replaces transcript path forensics — we have the working tree; they had foreign vendor transcripts. |
| Verdict rule: form_mismatch only when ALL unsupported are masking; else FABRICATION_SUSPECTED (pin `:6182-6198`) | Per-claim `supported \| unsupported \| form_mismatch \| skipped`; verdict `fabrication_suspected` if any `unsupported`, else `form_mismatch` if any masked, else `clean`/`skipped` | Verbatim rule (their masked claims land in both lists; the len-equality check IS "no genuinely-absent claim" — our per-claim enum encodes the same partition). |
| `EVIDENCE_MISSING` on empty transcript (pin `:6111-6116`) | No transcript ⇒ transcript kinds **skipped** (trust); files kind still reconciles (works on the vendor arm, where in-process tool rows don't exist) | Deliberately changed: their gate mode must fail claims it can't check; our findings-only posture trusts them (conservative rule). The OpenHelm compaction guard folds in here: our rows are compaction-immune (Recorder writes from `ai.tool.*` signals regardless of context compaction), so the guard translates to this absent-transcript skip. |
| Failure classes → recovery policies (`failure_taxonomy.py:74-96`) | **Dropped** — findings ride Hook R (`build_feedback/4` by shape); the fixer loop + stall/cap machinery own routing | Their RETRY/REDISPATCH policies are executor-gate plumbing; #1202 is why we never re-grow it. |
| Masked ⇒ still a failed verdict (gate mode) | Masking is **findings-only-context in v1**: engine findings are synthesized ONLY for `:unsupported` claims; `form_mismatch` rides the classification block + evidence-report artifact (review context), flips nothing | The conservative-override rule outranks the port: a masked-but-real run is not a *positive* discrepancy. |
| `AssertionExtractor` (LLM, temp 0, cached by seed; `extractor.py`) | `Orchestration.Verify.Evidence.ACExtractor`: tool-less `Jido.AI.generate_object/3` behind app-env seams (`:ac_extract_generate`, `:ac_extract_model`, default `:fast`), run ONCE at composer launch when ACs exist, fed `Premises.criteria_with_ids/1` (stable `{"AC1", text}` pairs — never positional reconstruction), persisted via `parent_config` (`verify_override` precedent) — restart-safe. Extraction failure ⇒ Trace + slice 2 off for the run | Decisions 7 + cheap-model rationale: every conservative branch returns verified=true, so a weak model can only lose recall, never manufacture a finding. Their in-memory LRU cache ⇒ our durable parent config (stronger). |
| Assertion schema incl. `expected_value` + value-extraction heuristics (`verifier.py:267-293`) | Schema `%{ac_id, assertion, tier, file_hint?, pattern?}` — **`expected_value` dropped**; the extractor prompt folds the expected value INTO the pattern (`WARMUP\s*=\s*10`) | Deliberately changed: the extraction heuristics only improve the found-vs-expected message; findings-only consumption doesn't need them, and a wrong value ⇒ pattern absent ⇒ same `:contradicted` outcome by a simpler route. |
| `SpecVerifier` bounds + trust branches (`verifier.py:25-27,122-134,169-174,229-254`) | `Evidence.Assertions.verify/3` (pure, injected `:scanner` seam): 50KB/file, 100 files/hint, 200-char pattern cap; `Regex.compile/1` error ⇒ verified=true; bounded glob under project_dir, reject `..`, realpath-containment; noise dirs adapted to Elixir (`_build`, `deps`, `.git`, `node_modules`); no hint/no files ⇒ verified=true; T3/T4 skipped; the ONLY false branch: pattern absent across scanned files that existed (`:contradicted`). Per-assertion scan under a bounded Task timeout | Decision 8 (timeout = belt-and-suspenders their length cap alone carries). Verdict consumption: violated assertions feed the SAME `Evidence.findings` path — title `"AC<n> assertion failed: …"`, location = file_hint (else stage name). *Amended at implementation 2026-07-08: the else-branch is the stable synthetic `evidence:ac:<id>` token, NEVER a stage name — a stage-name location flips coder→fixer across waves and churns the FindingKey, breaking exactly the decision-3 stability this map pins; the branch is defensively unreachable anyway (a violation requires scanned files, which require a hint).* |
| `has_discrepancy = agent_reported_pass and not verified_pass` (`models.py:73-75`) | Flip-only, same rule: a completing producer + a contradicted assertion ⇒ finding; a verified or skipped assertion changes nothing | The rule that governs BOTH slices. |
| OpenHelm: count breaches durably + breach-visibly (shape) | `:evidence_classified` `WorkflowEvent` (app-level atom, aggregate one-per-wave, bounded redaction-posture payload) + projection `evidence_breaches` counters surfaced in the terminal summary | Shape-only (BUSL-1.1): field names/rules re-derived, no code read into the port. |
| OpenHelm: fail-closed never-null evaluator (shape) | **Inapplicable** — we fail toward *trust* (findings-only); the analogous discipline is the loud `:skip` Trace notes | Recorded so the divergence is a decision, not an oversight. |

## Behaviors table

**Preserved exactly**

| Behavior | Source | Reason |
| --- | --- | --- |
| Verdict partition: any genuinely-absent claim ⇒ fabrication_suspected; all-masked ⇒ form_mismatch | pin `:6182-6198` | The headline rule; the len-equality IS the partition. |
| Self-report never supports itself | pin `:6110` | The point of the floor; ours is structural (tool rows only). |
| Filter allowlist `{tail, head, cat, less, more}`; grep/egrep/fgrep/tee/wc excluded | pin `:1292` + comment | The allowlist IS the check; transforming filters hide failures. |
| pipefail = exactly `["set","-o","pipefail"]`, set before the pipeline, carried across `&&`/`;` | pin `:1373-1408` | Sloppy matching (`pipefail` as prose) must not count — their `:1634` test pins it. |
| Residual pipe after peel ⇒ not provable-clean | HEAD `shell_parsing.py:258-259` | `pytest \| grep passed` must never back a clean claim. |
| Test-runner table + skip-flag semantics (`=false\|0\|no\|off` not skipping; `-x test`/`--exclude-task test`) | HEAD `:192-237,261-284` | Table fidelity is the port; skip-flagged runner ⇒ tests_passed claim unsupported. |
| Command evidence is structured (tool args), never prose | `claims.py:68-95` | Narration must not create aliases. |
| tests_passed needs invocation + success + form, not just presence | `test_detection.py:261-322` | Matched + failed ⇒ unsupported — the false-green catch. |
| files: bare existence is never support | `claims.py:263-270` | A stale/pre-existing file can't prove this run touched it. |
| Slice 2: can't-verify ⇒ trust (no files / invalid regex / T3 / T4) | `verifier.py:101-134` | The conservative-override rule, verbatim. |
| Slice 2: flip only on `agent_reported_pass and not verified_pass` | `models.py:73-75` | Only ever downgrade a claimed pass on positive discrepancy. |
| Slice 2 bounds: 50KB / 100 files / 200-char pattern | `verifier.py:25-27` | ReDoS + runaway-scan guards, verbatim numbers. *Amended at implementation 2026-07-09: a skipped read still counts scanned — `_read_file` → `None` → `continue` → final `verified=False` across `len(files)` — so a matched-but-unreadable/over-cap file leans toward `:contradicted` when nothing else matches. Ported faithfully (`assertions_test.exs:205` pins it); documented as the evidence-floor residual, and "unreadable files" is NOT a trust branch despite an earlier moduledoc overclaim (review P3).* |
| Extractor fail-open: parse failure ⇒ no assertions; invalid tier ⇒ T4 | `extractor.py:138-180` | Extraction failure can only lose recall, never block. |

**Deliberately changed**

| Behavior | Source → ours | Reason |
| --- | --- | --- |
| (A) Required evidence record, gate verdict → optional advisory block, findings-only | fat_harness contract | Upstream #1202 rollback is the lesson; the ratified posture. Absent block ⇒ posture unchanged; "missing required field ⇒ unsupported" dropped with it. |
| (B) `EVIDENCE_MISSING` fail → transcript kinds skip (trust); files kind still reconciles | pin `:6111-6116` | Findings-only + conservative rule; also the vendor-arm reality (no in-process tool rows there). OpenHelm's compaction guard folds into the same skip; our rows are compaction-immune. |
| (C) Text-scan test success → structured `exit_code == 0` + provenance | `test_detection.py:83-127` | We own the executor; exit codes are row data. Their text heuristics parse foreign transcripts — porting them would re-introduce prose trust we don't need. |
| (D) files_touched transcript forensics → wave-scoped git before/after status diff (untracked-inclusive), union semantics, containment Trace-only | `claims.py:257-337` | camus C1-6c absorbed: engine-side git is the stronger witness. Same invariant (existence ≠ support); missing before-snapshot ⇒ skip, never a permissive fallback. |
| (E) Masked ⇒ failed verdict → masked ⇒ context-only (`form_mismatch` status, no finding, no flip) | verdict semantics | v1 scope (decision 6): masking is a real-transcript shape, not a positive discrepancy. It still rides the classification ledger + evidence-report so reviewers see it. |
| (F) Their masking scope → + explicit exit-swallow idioms (`\|\| true`/`\|\| :`/`; true`/`; :`); general `;`-shadowing stays `:preserved` | shell analyzer | House no-masked-gates rule codified; the general `;`-chain case is a documented miss (conservative: never a false finding). |
| (G) Trailing-redirect peel regex → structural redirect handling | `shell_parsing.py:316-318` | ShellCommand already strips `{:redirect, _}` tokens at parse level. |
| (H) Per-seed LRU assertion cache → once-at-launch, persisted in parent config | `extractor.py:75-135` | Restart-safe; LLM out of the per-wave fold (decision 7). |
| (I) `expected_value` + extraction heuristics → pattern subsumes the value | `verifier.py:111-174,267-293` | Same outcome (`wrong value ⇒ pattern absent ⇒ contradicted`), simpler port; findings-only consumption doesn't need found-vs-expected prose. |
| (J) Python noise dirs (`__pycache__`, `.venv`, `.tox`…) → Elixir set (`_build`, `deps`, `.git`, `node_modules`) | `verifier.py:244-252` | Ecosystem adaptation of the same guard. |
| (K) Verdict consumed by executor gate → engine findings on Hook R (`build_feedback/4` by shape) + `:evidence_classified` ledger + review-context threading | orchestration | Ratified decision 2; trust-boundary law 2 (deterministic verdict never rides an LLM relay); OpenHelm breach-counting shape lands as the durable ledger + projection counters. |

**Dropped**

| Behavior | Source | Reason |
| --- | --- | --- |
| Per-task-type evidence profiles + effective-schema derivation (validation-only ACs drop `files_touched`, etc.) | pin `:6128-6130`, HEAD `ac_classification.py` | Profile machinery serves their required-fields gate; our block is advisory and uniform. |
| Recovery policies per failure class (RETRY/REDISPATCH/ESCALATE) | `failure_taxonomy.py:74-96` | Hook R + stall/cap machinery own routing; findings-only. |
| Broad-suite pytest → node-id coverage via file mutation evidence | `test_detection.py:246-258` | Rides their files-forensics we replaced; our match is invocation-level (normalized/substring), not node-id resolution. |
| Assistant-text mutation-language proof for files (`updated\|created\|…` regex) | `claims.py:368-389` | Replaced whole-cloth by the git diff (D). |
| `_single_command_after_safe_shell_preamble` sibling-reconciliation aliases | `shell_parsing.py:479-497` | Serves their sibling-AC completion propagation — no analogue here. |
| `EVIDENCE_MISSING` as a distinct failure class | `failure_taxonomy.py:48` | Folded into `:skipped` (B). |
| Unittest "Ran N tests … OK" summary-claim matching | `test_detection.py:76-81,172-209` | Text-scan machinery dropped with (C). |
| Evolution-evaluator wiring of `verification/` (override_approval into their grader) | `models.py:95-102` | Our consumer is the same findings path as slice 1 — one entry point, not a second authority. |

## Edge cases (anchored to source tests)

Source tests at the pin: `tests/unit/orchestrator/test_parallel_executor.py`
(evidence + shell analyzer) and `tests/unit/test_verification.py` (slice 2).
Line refs are at `e905a41c`.

| Ouroboros test | Our planned equivalent | Expected behavior (both sides) |
| --- | --- | --- |
| `test_unprotected_tail_pipe_is_form_mismatch_not_command_proof` (`:1276`) | `ShellCommandTest` provenance: `mix test 2>&1 \| tail -20` ⇒ `:masked`; `EvidenceTest`: claim matching only that run ⇒ `form_mismatch` | Masked plumbing never proves a clean claim; classified as form-mismatch, not fabrication. |
| `test_atomic_verifier_classifies_masked_test_command_as_form_mismatch` (`:1301`) | `EvidenceTest`: tests_passed claim, matched invocation, exit 0, `:masked` provenance | Per-claim `form_mismatch`; verdict `form_mismatch` when nothing else is unsupported; **no finding** (v1 divergence (E) — theirs fails the gate). |
| `test_atomic_verifier_classifies_dependent_masked_test_evidence_as_form_mismatch` (`:1342`) | `EvidenceTest`: commands_run + tests_passed both riding one masked run | Both claims `form_mismatch`; verdict stays `form_mismatch` (all-masked partition). |
| `test_gradle_maven_tests_passed_rejects_skip_test_invocations` (`:1420`) | `ShellCommandTest`: `gradle build -x test` ⇒ `test_runner: %{tool: "gradle", skipped?: true}`; `EvidenceTest`: tests_passed claim matching it ⇒ `unsupported` | Skip-flagged runner contradicts "tests passed" ⇒ finding (fabrication lane, both sides). |
| `test_maven_tests_passed_supports_explicit_false_skip_properties` (`:1453`) | `ShellCommandTest`: `mvn verify -DskipTests=false` ⇒ `skipped?: false` | `=false/0/no/off` does NOT skip. |
| `test_test_invocation_supports_shell_preamble_with_pipefail_output_plumbing` (`:1598`) | `ShellCommandTest`: `set -o pipefail && mix test \| tail -5` ⇒ `:preserved` | Pipefail before the filter pipeline protects it. |
| `test_test_invocation_rejects_pipefail_text_without_shell_option` (`:1634`) | `ShellCommandTest`: `echo pipefail && mix test \| tail -5` ⇒ `:masked` | Prose "pipefail" is not the option; exact argv `["set","-o","pipefail"]` only. |
| `test_test_invocation_rejects_pipefail_set_after_output_pipe` (`:1654`) | `ShellCommandTest`: `mix test \| tail -5; set -o pipefail` ⇒ `:masked` | Pipefail after the pipeline protects nothing. |
| `test_command_claim_rejects_grep_filtered_run_as_tests_passed_claim` (`:1707`) | `ShellCommandTest`: `mix test \| grep -i pass` ⇒ `:masked` (grep not on the allowlist ⇒ residual transforming pipe) | Transforming filters are never presentation plumbing. |
| `test_fat_harness_mode_rejects_unbacked_typed_evidence` (`:4282`) | `EvidenceTest`: tests_passed claim, NO matching invocation in tool rows | `unsupported` ⇒ verdict `fabrication_suspected` ⇒ engine finding (stable key `evidence:<stage>:tests_passed`). |
| `test_fat_harness_verifier_rejects_targeted_failed_test_command` (`:6366`) | `EvidenceTest`: matched invocation, `exit_code: 1` | `unsupported` — the false-green catch (their text veto ≡ our nonzero exit). |
| `test_fat_harness_verifier_accepts_codex_runtime_evidence_shape` (`:3636`) | `EvidenceTest` decode matrix: TranscriptEnvelope quirks (`":atom"` strings, `__tuple__` maps, string vs atom keys) | Decode tolerance is the port of their multi-adapter tolerance. |
| (no source analogue — redaction) | `EvidenceTest`: rows with `%{"redacted" => true}` metadata | Excluded from the base; all-unreadable ⇒ transcript kinds skip `:redacted` — degraded, never suspicious. |
| (no source analogue — vendor arm) | Composer test: zero tool rows, files claims present | tests/commands skip; files still reconcile against the wave git diff. |
| (no source analogue — wave union) | `EvidenceTest`: stage A claims a path stage B changed same-wave | `supported` (union semantics — never over-flip). |
| (no source analogue — missing snapshot) | `EvidenceTest`/composer test: no before-snapshot (mid-wave recovery) | files kind `skipped`, never the permissive fallback. |
| `test_t1_constant_found_wrong_value` (`test_verification.py:183`) | `AssertionsTest`: pattern `WARMUP\s*=\s*10`, file has `WARMUP = 5` | Source: found-but-mismatched ⇒ discrepancy. Ours: pattern absent in existing files ⇒ `:contradicted` — same flip by route (I). |
| `test_t1_pattern_not_found` (`:204`) | `AssertionsTest`: pattern matches nothing, files existed | `:contradicted` ⇒ finding when the producer claimed completion. |
| `test_t2_structural_class_found` / `_missing` (`:223,:241`) | `AssertionsTest`: structural pattern present/absent | Present ⇒ verified; absent-in-existing-files ⇒ contradicted. |
| `test_t3_t4_skipped` (`:260`) | `AssertionsTest`: T3/T4 assertions | Skipped, never verified=false. |
| `test_no_files_match_hint` (`:272`) | `AssertionsTest`: hint matches nothing | verified=true (trust). |
| `test_ac_report_no_results_trusts_agent` (`:85`) | `AssertionsTest`: AC with zero extractable assertions | No finding possible. |
| `test_pycache_excluded` (`:316`) | `AssertionsTest`: match only inside `_build`/`deps` | Not scanned (J). |
| `test_invalid_json_returns_empty` / `test_invalid_tier_defaults_to_t4` / `test_llm_failure_returns_error` (`:420,:438,:402`) | `ACExtractorTest`: garbled LLM output / unknown tier / seam failure | Fail-open: no assertions (slice 2 off for the run) / T4 / Trace + off. |
| `test_caches_by_seed_id` (`:380`) | Composer test: extraction once at launch, restored from parent config after restart | One LLM call per run, restart-safe (H). |

## Sign-off gate

Decisions this map pins (ratifying the reviewed plan; flagging any reopens
it). Context already operator-ratified 2026-07-08 and not re-asked:
engine-synthesized findings on Hook R, all three claim kinds in v1, module at
`JidoClaw.Orchestration.Verify.Evidence`, slice 2 in scope, findings-only
posture, conservative override rule.

1. **files_touched source**: read the EXISTING required `files_changed`
   envelope field; the advisory `evidence` block carries only
   `commands_run`/`tests_passed`. Divergence from ouroboros's 3-field record
   — recorded above.
2. **Consumer entry point**: direct-weld fold consumer + reserved
   `"evidence"` lens; Hook R reused by *shape* (`build_feedback/4`), never
   entered through `decide_rerun` (catalog-driven; a synthetic non-catalog
   emission would be invisible to stall/budget predicates and break
   durable-`ran` equivalence).
3. **FindingKey identity for non-file claims**: stable STAGE-SCOPED
   synthetic location token (`"evidence:<stage>:tests_passed"`) + stable
   title phrase; varying detail (exit codes) only in `description` — keys
   must not churn across waves or stall detection breaks.
4. **Fixer-concurrency wrinkle**: publishing `findings:evidence` on the
   implementer wave lets the fixer run concurrently with first-pass
   reviewers. Accepted for v1 (the loop self-heals via Hook F + the
   deterministic re-check).
5. **files reconcile is before/after wave-scoped**: supported iff the path's
   git status CHANGED this wave (untracked-inclusive `porcelain_all/1`
   snapshots at dispatch/fold; union across same-wave stages). Bare
   existence is NOT support. Missing before-snapshot ⇒ the kind skips
   (never the permissive fallback). Containment Trace-warning-only in v1.
6. **Masking scope v1**: trailing transforming pipe w/o pipefail + ONLY the
   explicit exit-swallow idioms (`|| true` / `|| :` / `; true` / `; :`);
   general `;`-chain shadowing conservatively `:preserved` (documented
   miss). `mix precommit` NOT a test-runner (Verify authority owns it).
   Masking is findings-only-context — it never flips anything in v1.
7. **Slice-2 extraction point**: once at composer launch when ACs exist,
   persisted in parent config (`verify_override` precedent) — LLM out of
   the per-wave fold, restart-safe.
8. **Slice-2 ReDoS belt-and-suspenders**: per-assertion scan under a bounded
   Task timeout, in v1 (cheap), atop the ported 200-char pattern cap.

Sign-off: **granted by the operator 2026-07-08** (explicit sign-off act on
this map, separate from implementation-plan approval, ratifying decisions
1–8 above). Code follows this map. After shipping,
`docs/system/evidence-floor.md` cites this map as port provenance.
