# Plan: next-ten item 5 — Deterministic verify authority + sealed heads (camus C1-2 + C1-6a)

## Context

Item 5 of `docs/plans/unadopted-next-ten/README.md`. Today verification never gates on an
exit code: verifier *agents* run `mix test` and self-report, the loop authority reads the
LLM's interpretation (`system-verifier` reverse-verify loop, `IterativeStep`), and nothing
head-binds a green or detects the tree changing around a verification — the camus "run-6
cover-up" class (a verifier edits the code under verification to turn red green) is
undetectable. We hold the structural advantage camus lacks: our engine can run the command
and read the exit code itself. `Verdict`'s `{:inconclusive, _}` lane was pre-built for
this item (`verdict.ex:14-16` — "No producer emits this yet"); this plan adds the
producer.

Acceptance frame: `docs/TRUST-BOUNDARIES.md` — esp. law 2 (engine reads exit codes
itself, never trusts a relay), law 3 (durability checklist), law 4 ("every green proves
exactly what state it certified" — this item is that law's named worked example).

Attribution for ported material: `mateodaza/camus @ 53da91b3 (MIT)` — verified against
the local checkout at `~/workspace/research/camus` (classification table + envelope from
`verify.py`, commit facts from `commit.sh`, `VERIFY_OATH` from
`camus-loop.workflow.js:32-35`). Rider sources (orca OR2-2, OpenHelm OH1-3) are pattern
fold-ins fully specified by our own inventories — no code lifted, no clones needed.

Hard constraints (user): plan is complete only when `mix precommit` passes (run directly,
exit code + counts verbatim, never piped); greenfield — no migration/compat concerns;
commit NOTHING (all work stays unstaged; the "2 commits" in the README becomes two work
*phases*); pre-existing working-tree changes (`docs/exploration/argus/*`) must not be
touched or swept.

## Locked design decisions (user-ratified)

1. **Two-mode verify.** `:sealed` = camus-verbatim (dirty-tracked-tree before checks →
   `uncommitted_state`, tampered RED, checks never run) — active when the run has an
   engine-observed `sealed_head`. `:working_tree` = default for today's non-committing
   routes: dirty-before recorded as an envelope *fact*, mid-verify integrity via HEAD
   stability + a content-addressed tracked-tree digest, green binds `{head, tree_digest}`.
   Digest command: `git diff --no-ext-diff --no-textconv --binary HEAD`
   (config-insensitive — `--no-ext-diff` alone doesn't cover textconv diff drivers —
   and sees binary content; porcelain/status lines can't see content edits to
   already-dirty files). Mode auto-selected per run: `sealed_head` present → `:sealed`.
2. **verify_cmd resolution**: per-run override → `.jido/config.yaml` (`verify_cmd:`
   scalar or `verify:` block) → minimal Elixir auto-detect (`mix.exs` with a `precommit`
   alias → `["mix","precommit"]`; `mix.exs` without → `["mix","test"]`) → loud
   `no_verifier` **inconclusive envelope** (camus shape: `pass:false, inconclusive:true`,
   remedy in `log_tail`) — never a pass, never a silent skip. No tenant-level defaults in
   v1; code-path routes only — pinned in the design note.
   **Command shape (no shell, ever)**: canonical `cmd` is an **argv list**
   (`["mix", "precommit"]`) — `Core.OsCmd` spawns an executable + args, not a shell. A
   scalar string is a convenience parsed by whitespace-split ONLY when it contains no
   shell metacharacters (conservative set: `| & ; < > $ ` \ " ' ( ) { } [ ] * ? ~ #`)
   AND no leading env-assignment token (`^[A-Za-z_][A-Za-z0-9_]*=` — `MIX_ENV=prod mix
   test` is shell syntax, not a confusing `missing_tool`); either → loud validation
   error with remedy ("use an argv list / the `env:` map / a script"). Checks accept an
   optional **`env:` map** (string⇒string, validated, overlaid onto
   `Env.scrubbed_cmd_env()` — the MCP stdio endpoint `env:` override precedent). No
   `sh -c` — shell plumbing masks exit codes (the house no-masked-gates rule).
   Auto-detect emits argv lists directly.
3. **Registry-lite named checks** (orca OR2-2 fold-in): scalar `verify_cmd:` ≡ one named
   check; or ordered list `verify: checks: [{name, cmd, timeout_ms?}]`; run sequentially,
   collect-all into ONE envelope (camus semantics, incl. timeout ⇒ inconclusive — camus
   wins over orca's timeout ⇒ failed); per-run override persisted via the parent-config
   triple; an override naming an unknown check → loud refusal (orca's silent-skip
   inverted). First-fail-stops-progression is inherent (red verify blocks convergence).
4. **Tampered → new distinct terminal `:verify_tampered`** (`:route_verify_tampered` →
   status `:failed`, `result.disposition: "verify_tampered"`). Never auto-retried, never
   fed to the fixer (VERIFY_OATH: remediation destroys the evidence a human needs).
   Item 6's `review_stall` may later park it as a human decision.

Derived decisions: red-verify exhaustion terminalizes `:verify_failed` (extend
`exhausted_verify_lenses/1` to cover `{:verify,_}`-unit lens stages; exclude them from
`exhausted_fix_lenses/1`); inconclusive rides the existing infra lane (Lane A,
`infra_cap`, exhaustion → `review_infra_failed`); sealed head is **engine-observed**
(`git rev-parse HEAD` at wave boundaries), never relayed from tool/worker output;
envelope `log_tails` pass the redaction root on the FULL output before tailing.

## Design overview

**Envelope** (camus `verify.py` full shape + our extensions, JSONB-safe string
keys/enums, fail-closed decode):
`%Verify.Envelope{pass, inconclusive, tampered, failures: [%{stage, kind, log_tail,
exit?}], checks: [%{name, cmd, exit}], head, integrity_note, mode, tree_digest,
sealed_head}`. Classification: exit 127 → `missing_tool`; runner-minted timeout sentinel
(124) → `timeout` (+ config-lever hint in tail); output-limit → inconclusive kind +
lever hint; env-tail heuristics adapted for mix; else `failed`.
`INCONCLUSIVE_KINDS = missing_tool | no_tests | timeout | output_limit |
integrity_unavailable`; integrity RED kinds
(`uncommitted_state`/`tracked_mutation`/`head_moved`) are never inconclusive;
misclassification policy: err toward inconclusive, never false red, never a pass.

**Integrity capture failures (law-4 override of camus's degrade-open)**: our stage
targets a git repo by definition (code-path runs), so a git-seam failure never yields a
green that can't name what it certified — a would-be PASS with a failed capture (`head`
nil; `tree_digest` nil in working-tree mode; porcelain nil in sealed mode) downgrades to
**inconclusive** (`integrity_unavailable`, remedy attached). A RED stays RED (failing
checks are failing regardless; `integrity_note` records the unasserted invariant — err
toward reporting the red, never a false green). Camus's degrade-open is documented as
upstream behavior for non-git targets; noted as a deliberate correction in the docs
sweep.

**Missing-tool detection (Port semantics + argv0 resolution)**: `Core.OsCmd.run/3` is
`Port.open({:spawn_executable, _}, ...)` (`os_cmd.ex:100-108`) — a missing executable
RAISES (`:enoent`), it never returns 127. The runner resolves argv0 with execvp-style
semantics: a PATH-bearing argv0 (contains `/`, e.g. `./scripts/verify` — the very
"wrap it in a script" remedy our validation messages point to;
`System.find_executable/1` returns nil for these) is expanded against the check's cwd
(the project_dir) and required to exist + be executable, passing the ABSOLUTE path to
`OsCmd`; a bare argv0 is resolved against the EFFECTIVE child PATH — the scrubbed base
env merged with the check's `env:` override — via a small path-probe helper
(`System.find_executable/1` consults only the parent's PATH, so an `env:` PATH
override exposing a verifier binary would otherwise misresolve). Either miss →
`missing_tool` without spawning; the Port `:enoent` raise is rescued to the same kind.
The exit-127 row remains for commands that themselves exit 127 (a script whose
interior tool is missing).

**Composer stage** — new non-agent unit `{:verify, "default"}`, stage `"verify"`,
`lens: "verify"`, `routes: ["code"]`, `subscribes: ["code-written"]`,
`publishes: ["clean:verify", "findings:verify", "scope-shift"]` (the validator requires
`scope-shift` on every stage — `catalog_validator.ex:243`). Dispatched as a NON-halting
module reactor (the gate precedent minus the park): `VerifyReactors` name→module seam
(mirror `GateReactors.@gates` + the compile-time catalog guard), `WaveBuilder`
`{:verify,_}` branch, `run_verify_wave/5` (the `run_gate_wave/5` shape minus
artifact-input resolution — the reactor needs no store inputs; cwd from
`state.context[:project_dir]`), completing into the generic `handle_wave_result` →
`handle_wave_value` fold with a WaveCollect-identical envelope (the `EmitApprovedPlan`
precedent). **`Loop.defer_solo_verify/2` is the INVERSE of `split_solo_gate/2`** (which
peels the gate to run FIRST, `loop.ex:59-69`): a cohort mixing verify + others returns
the NON-verify stages (verify deferred to a later tick); verify dispatches solo only
when it is the sole remaining dispatchable stage; a multi-verify cohort hits a
`{:verify_must_be_solo_wave, names}` WaveBuilder backstop. Kahn leveling alone puts
verify in the reviewers' cohort, so this peel is what makes it run last.

**Verdict mapping** (computed inside the reactor): `clean:verify` iff
`pass ∧ ¬tampered ∧ captures-succeeded ∧ (sealed_head == nil ∨ head == sealed_head)`;
red → `findings:verify` + a `findings` artifact (list of finding maps:
`severity: "error"`, `title`, `location` = check name, `description` = redacted tail)
riding the existing Hook R fixer re-fire **unchanged** (forward-lens mechanics,
source-verified); inconclusive → emission `outcome: {:inconclusive, reason}` riding the
pre-built infra lane. Laundered-green guard: verify subscribed to `code-written` makes it
`domain_touched` by every fixer run → Hook F auto-invalidates it; additionally retract a
live `clean:verify` in the same welded marker batch (no stale green visible between the
fixer wave and re-verify).

**Tampered flow (evidence-preserving, crash-safe)** — tampered rides an EXPLICIT
parent-log delta, because the normal delta build only sees `:ok` emissions
(`wave_deltas` is fed from `Fold.fold` over the verdict emissions —
`route_composer.ex:1708,2034` — so a non-`:ok` emission would publish nothing and
rebuild nothing; the child `WorkflowRun.result` is NOT recovery input,
`ComposerProjection` rebuilds from parent events only):
- The reactor's tampered emission: `signals: []`, `artifacts: %{"verify-report" => ref}`
  (the full envelope, encrypted), `outcome: {:tampered, reason}` (bounded: integrity
  kind + check names — tails only inside the encrypted report). `{:tampered, _}` joins
  `StageEmission`'s recognized outcomes (`stage_emission.ex:33,74-94` — unknown shapes
  still fail closed to infra) and `wave_collect.ex:119` encoding.
- `handle_wave_value` extracts tampered BEFORE the `:ok`/infra split (it must not bump
  `infra_counts`), then commits via **`commit_wave`** (`commit.ex:100` — pending→active
  promotion is wave-scoped, so the report row activates) with `wave_completed` (which
  durably stores only `wave_index` + `stages`, `commit.ex:238` — the tampered stage
  excluded from `stages`; the emission/outcome detail is in-memory history, and durable
  tamper recovery rides the marker) and a new welded **`:stage_tampered` marker**
  (payload `%{stage, reason, report_ref}` — bounded, the `:stage_infra` sibling; the
  report ref rides the marker, NEVER `artifacts_produced`, which would make a tamper
  report look routable via `Fold.available/1`) instead of hook markers (no Hook R/F).
  Tampered stages are ALSO excluded from `wave_completed.stages`: `wave_deltas/4`
  today subtracts only `infra_stages` from the dispatch (`route_composer.ex:2034`), so
  without a separate `non_completed_stages = infra_stages ++ tampered_stages` the
  rebuild would fold the tampered stage into `ran` — only `infra_stages` get
  `:stage_infra` markers, but both sets are withheld from the completed-stage list.
- `ComposerProjection.apply_event(:stage_tampered)` folds `tampered_stages[stage] =
  {reason, report_ref}`; the in-memory mirror applies the same marker through
  `apply_markers` (projection mirrors fold — law 3). The TICK checks `tampered_stages`
  **before every other terminal branch** — insertion point is the top of
  `handle_continue(:tick, state)`'s decision (`route_composer.ex:1140-1159`), ahead of
  the `is_nil(dispatch) → Loop.terminal` and `over_budget? → budget_terminal` arms — so
  `:not_converged`/deadlock/max-wave/deadline logic can never outrank tamper →
  `finish({:verify_tampered, reason}, ...)`; the terminal event's `result` carries the
  disposition, bounded integrity detail, and the `verify-report` ref — evidence
  reachable from the parent.
- Crash between the wave commit and the terminal append → rebuild re-folds
  `:stage_tampered` FROM PARENT EVENTS ALONE → the tick terminalizes
  `:verify_tampered` again (idempotent). The restart test asserts the rebuild path
  never consults the child result and the report artifact is active + ref-reachable.

**Sealed heads (C1-6a+b)** — two independent halves, both engine-derived:
(a) `Tools.GitCommit` gains engine facts in its tool output: `git rev-parse HEAD`
before/after, `committed?` ⇔ head moved, staged-empty → explicit `no_changes` SUCCESS
outcome (never an error, never silently done), distinct `add_failed`/`commit_failed`
reasons, full sha never `--short`.
(b) The composer observes HEAD itself at wave boundaries (code-path runs with a
project_dir only): new non-status-authority event kind **`:head_observed`** (payload
`%{head: sha}`) welded into the wave-commit txn markers on the FIRST observation
(durable baseline — an in-memory-only baseline could be laundered by a crash + external
move before recovery) AND on every observed change; the fold derives
`observed_head`/`sealed_head` (first marker = baseline; a subsequent differing sha =
seal) in `ComposerProjection` AND the in-memory mirror. A head move while
`clean:verify` is live welds `signals_retracted` + `stages_invalidated` for the verify
stage into the same txn (re-verify forced). A green verify's wave commit also welds a
compact **`:verify_certified` marker** (`%{stage, head, tree_digest, mode}` — shas and
digests are not secrets; the `:stage_tampered` sibling for the green case), folded to
`state.verified_integrity`, so the tick can check what the green certified without
decrypting the report. **Data path**: the cert tuple rides the emission itself as a new
bounded optional field — `StageEmission.certification: %{head, tree_digest, mode}`
(encode/decode in `stage_emission.ex` + the WaveCollect emission map; whitelist-decoded,
malformed → nil = no certification), populated by the verify reactor on a clean result.
**Fail closed BEFORE the durable green** (`Fold.fold` publishes emission signals
blindly, `fold.ex:47`): in `handle_wave_value`, a verify emission carrying
`clean:verify` with nil/invalid certification is RECLASSIFIED to
`outcome: {:inconclusive, "uncertified_green"}` (infra lane; string reason — the
emission boundary decodes binary reasons only) before the `:ok` split —
the committed invariant is `clean:verify` ∈ signals ⇔ a `:verify_certified` marker in
the SAME wave commit; an uncertified green never reaches the parent log. And
`stages_invalidated` covering the verify stage CLEARS `verified_integrity` in the fold
+ mirror (`projection.ex:146` today only trims `ran`/counts) — a stale certificate can
never back a later green. The re-check's no-`verified_integrity` arm (retract +
re-verify) remains as the defensive backstop.
**Artifact-reference invariant (no orphans, no phantom routability)**: `commit_wave`
promotes ALL of a wave's pending artifacts (`commit.ex:213`), and `artifacts_produced`
folds into `state.artifacts` → `Fold.available/1` — so a non-`:ok` report must be
parent-referenced WITHOUT `artifacts_produced` (a tampered/inconclusive report must
never look routable; a RED report is a usable verdict on an `:ok` emission and routes
normally). Rules: reactor-known inconclusive outcomes (`no_verifier`,
`missing_tool`, `timeout`, …) store NO report artifact (bounded reason + remedy ride
the emission outcome and Trace, the `:stage_infra` posture); the composer-detected
`"uncertified_green"` reclassification (report already stored pending) welds a
NON-ROUTING **`:verify_report_recorded` marker** (`%{stage, report_ref, reason}`) —
promotion is wave-scoped so the row activates, and the marker carries reachability;
tampered's report ref likewise rides ONLY its `:stage_tampered` marker (no
`artifacts_produced` delta). Every stored report ref is parent-log-referenced via a
marker, or is never stored; only green/red reports enter `artifacts_produced`.
**Boundary values are strings** (the JSONB string-enum house rule):
`StageEmission.from_map/1` decodes only binary reasons and `WaveCollect` writes reasons
as-is — the reclassification reason crosses as `"uncertified_green"` (via
`Verdict.format_reason/1`), and `certification.mode` crosses as a whitelisted string
(`"working_tree"`/`"sealed"`); atoms live only in the in-memory structs. **Convergence-time re-check**: before `finish(:converged)` on a
code-path run holding a live `clean:verify`, the engine re-derives the MODE-SPECIFIC
integrity tuple and compares against `verified_integrity` — working-tree mode: current
`diff_digest` (+ HEAD) vs the certified `tree_digest`/`head` (a tracked edit with HEAD
unchanged must not converge); sealed mode: HEAD match + clean tracked porcelain. Any
mismatch (external edit/move mid-run OR during post-crash downtime) retracts +
re-verifies instead of converging; an UNREADABLE capture at the re-check is treated
like `integrity_unavailable` — no convergence, no retained `clean:verify`: retract +
re-verify, whose own capture failure then yields the inconclusive envelope (infra lane;
persistent → `review_infra_failed`). A green never outlives — or outruns the
verifiability of — the state it certified (law 4). The verify reactor receives
`state.sealed_head` as input and the envelope echoes what it certified against.

**LLM demotion + riders**: `VERIFY_OATH` lands verbatim as doctrine slice
`priv/defaults/doctrine/verify_oath.md` (attribution header), appended to
`@template_slices` for `"verifier"`, `"system_verifier"`, `"test_runner"`; those three
workers gain `Tools.LuaQuery` + `Tools.LuaDocs` (OH1-3: judge gets read-only
deterministic evidence — sandboxed, lexical-only, tenant-scoped, capped by `Lua.Policy`
`max_calls`). The engine envelope is always the verdict on the code path; LLM verifiers
diagnose reds. OH1-3's forced-verdict-at-cap is satisfied engine-side (cap exhaustion
always terminalizes a named disposition — never a silent failure); documented in the
design note rather than new machinery.

**Observability**: telemetry counter `jido_claw.verify.total` (tags: `[:result]`) +
`emit_verify` helper; `:composer` Trace events on verify completion and on
tampered/no_verifier (bounded: stage name, result kind, check names — when a report
artifact exists, log_tails live only inside it; artifact-less inconclusive outcomes
carry bounded reason/remedy on the emission outcome + Trace only; durable event
payloads carry names/shas/digests only, per the `:stage_infra` redaction posture).

**Trust residuals (documented in the design note, not built)**: `verify_cmd` is
operator-owned config — the fix loop editing `.jido/config.yaml` mid-run is the known
camus C2-7 freeze gap, deliberately parked; engine verify runs outside the tool pipeline
(no approval gate / loop guard — law 1: it's engine/gate code; redaction called
explicitly); untracked-file mutation during verify is invisible to tracked-only
integrity (camus-consistent accepted residual).

## Implementation steps

### Phase 1 — verify core + stage wiring + terminals + doctrine + config

1. **Verify core** — create `lib/jido_claw/orchestration/verify.ex` + `verify/` subdir
   (mirrors `verdict.ex` + `verdict/`):
   - `Verify` — pure `build_result(checks, opts)` with injected seams (`runner`,
     `porcelain`, `head`, `diff_digest` funs — the camus test-seam shape);
     classification table; two-mode integrity incl. the would-be-green-with-failed-
     capture → `integrity_unavailable` inconclusive rule. No subprocess.
   - `Verify.Envelope` — struct + `to_map/1`/`from_map/1` (string keys/enums, whitelist
     decode, fail-closed to a never-pass sentinel).
   - `Verify.Git` — `head/1`, `porcelain/1` (`--untracked-files=no
     --ignore-submodules=all`), `diff_digest/1` (`git diff --no-ext-diff --no-textconv
     --binary HEAD` → sha256); `System.cmd` git idiom (`git_status.ex:23`), nil on
     failure. Single-source the git seam here (reach duplicate-clone hazard —
     `git_commit.ex` calls these helpers in Phase 2).
   - `Verify.OsCmdRunner` — real runner over `Core.OsCmd.run/3` (`os_cmd.ex:88-90`):
     execvp-style argv0 resolution (path-bearing argv0 → expand against the check cwd,
     require exists+executable, pass absolute; bare argv0 → path-probe against the
     EFFECTIVE child PATH (scrubbed base merged with the check's `env:` override —
     `System.find_executable/1` only sees the parent PATH); either miss =
     `missing_tool` without spawning; rescue
     the Port `:enoent` raise → `missing_tool`); maps `{out, :timeout}` → 124 sentinel
     + lever hint (the `host_shell.ex:146-162` idiom), `{out, :output_limit}` →
     inconclusive + lever hint; redact-full-then-tail via the redaction root.
   - `Verify.Config` — resolution chain + EndpointConfig-style validation
     (`endpoint_config.ex:55-68,95-103`): accessor on `JidoClaw.Config`
     (`core/config.ex:109-118`); argv-list canonical cmd + conservative scalar
     whitespace-split refusing metacharacters AND leading env-assignment tokens (loud
     error + remedy); optional per-check `env:` map overlaid on
     `Env.scrubbed_cmd_env()`; scalar/block/checks-list shapes; unknown-check override
     → loud refusal; mix auto-detect emitting argv lists. Moduledoc carries the **OQ-4
     design note** (source of truth, chain, no-shell rule, no tenant defaults,
     code-path only, C2-7 residual).
2. **Reactor** — create `lib/jido_claw/orchestration/reactors/verify_stage.ex`
   (`PlanGate` structure: `Ash.Reactor` + middleware + one `RunVerify` step): resolve
   config → run checks (runner from `:verify` app env, default `OsCmdRunner`) → build
   envelope → store the `verify-report` encrypted artifact ONLY for green/red/tampered
   results (`store_wave_artifact` idiom; inconclusive stores nothing) → derive
   `findings`/`action_needed` artifacts on red → return the WaveCollect envelope
   (`%{"wave_index", "emissions": [%{"stage", "signals", "artifacts", "outcome"?}]}`).
   **Every config-resolution failure** (invalid shape, metachar/env-assignment scalar,
   unknown-check override, no_verifier) is caught INSIDE the step and returned as the
   planned inconclusive envelope + `outcome: {:inconclusive, reason}` emission — never
   a raw reactor/action error, so config mistakes ride the infra lane with a remedy,
   not the wave-execution-error (Lane B / `route_failed`) lane. **Inconclusive results
   store NO report artifact** (reason + remedy ride the emission outcome/Trace) — only
   green, red, and tampered results store `verify-report`; non-`:ok` report refs are
   parent-referenced via NON-ROUTING markers only (`:stage_tampered` /
   `:verify_report_recorded` for the composer-side `"uncertified_green"`
   reclassification — never `artifacts_produced`, which feeds `Fold.available/1`).
   Outcome reasons and `certification.mode` cross the emission boundary as whitelisted
   STRINGS (atoms in-memory only).
3. **Seam + dispatch** — create `lib/jido_claw/route_composer/verify_reactors.ex`
   (`resolve/1`, `known?/1`); modify `wave_builder.ex:82-110` (`verify?/1`, classify →
   verify-reactor build, `{:verify_must_be_solo_wave, names}` backstop for mixed/multi
   verify); `loop.ex` add `defer_solo_verify/2` — the INVERSE peel (mixed cohort →
   return non-verify stages; solo verify passes) — wired into the tick
   (`route_composer.ex:1157`); `route_composer.ex:1423` add the verify clause →
   `run_verify_wave/5` (+ `run_verify_reactor`, `async?: false`, idempotency key
   `composer:<parent>:<wave_index>`, inputs incl. `sealed_head`, `verify_override`).
4. **Tampered terminal (marker-based)** — `workflow_event.ex:100-172` add
   `:route_verify_tampered` plus the non-status-authority `:stage_tampered` and
   `:verify_report_recorded` (all text-stored, no migration);
   `workflow_event/projection.ex` add the terminal to `@route_terminal_kinds` +
   `next_status/2` + `status_attrs/3` (`terminal_lifting_error_and_result` shape :274);
   `stage_emission.ex:33,74-94` add the `{:tampered, reason}` recognized outcome;
   `wave_collect.ex:119` encode it; `handle_wave_value` (:1706) extracts tampered
   before the `:ok`/infra split and commits via `commit_wave` (`wave_completed` + the
   welded `stage_tampered: %{stage, reason, report_ref}` marker — report ref on the
   marker, never `artifacts_produced`; no hook/infra markers; `wave_deltas/4` (:2034)
   subtracts `non_completed_stages = infra_stages ++ tampered_stages` from the
   completed-stage list so the rebuild never folds a tampered stage into `ran`, while
   only `infra_stages` get `:stage_infra`);
   `ComposerProjection.apply_event(:stage_tampered)` folds `tampered_stages`
   (in-memory mirror via `apply_markers`); tick terminal path checks `tampered_stages`
   first → `finish({:verify_tampered, reason}, ...)` with the report ref + bounded
   integrity detail in the terminal `result`; `route_composer.ex` `@type terminal`,
   `terminal_event/3`, `classify_terminal`, `format_terminal_error`, scrubbable kinds.
5. **Loop/budget wiring** — `exhausted_verify_lenses/1` (:3793) covers `{:verify,_}`
   lens stages; `exhausted_fix_lenses/1` (:3807) excludes them; Hook F
   (`hook_f_markers/2` :2801) folds ran verify stages into the invalidation set +
   retracts a live `clean:verify` (welded `signals_retracted` marker); Hook R untouched
   (automatic for a forward lens).
6. **Catalog** — add the `:verify` unit across ALL declaration points: `stage.ex` type
   (:27), moduledoc unit docs (:70), `@unit_tags` whitelist (:147);
   `catalog_validator.ex:64` `@unit_tags`; then the `"verify"` stage in `catalog.ex`
   (shape above — `publishes` includes `scope-shift`; confirm `diff`/`fix`
   input-producer names against implementer/fixer outputs — invariants 2/3/4/8/10) +
   compile-time `VerifyReactors.known?/1` guard (mirror :489-492). MCP catalog
   resources pick it up via `Stage.to_map/1` automatically; sweep tests pinning the
   catalog surface — pins must compare NAME SETS, never counts (drift-guard house
   rule).
7. **Config plumbing** — `config/config.exs` `:verify` block (`timeout_ms: 900_000`,
   `max_output_bytes`, `tail_lines`; NO `enabled?` — the `:lua` "registration is the
   switch" posture); `config/test.exs` sets `runner:` to a test stub so any
   full-catalog launch stays hermetic; parent-config triple for the per-run override
   (`parent_config/3` :476 `maybe_put` — present-nil rule; `build_start_opts/2` :843;
   `init/1` :1061); test exec seam `:route_composer_verify_stub` (counter-driven results
   list, the `SystemLoopWorker`/`StubStore` pattern).
8. **Doctrine + judge tools** — create `priv/defaults/doctrine/verify_oath.md`
   (verbatim 4-line oath + attribution); `doctrine.ex` `@verify_oath_priv` +
   `@external_resource` + `@slices` + `@template_slices` for
   verifier/system_verifier/test_runner; add `Tools.LuaQuery`/`Tools.LuaDocs` to those
   three workers' `tools:` lists; update `doctrine_test.exs:35` slice-set pin.
9. **Telemetry/Trace** — `core/telemetry.ex` counter `jido_claw.verify.total` +
   `emit_verify` helper; `:composer` Trace emissions from the reactor/composer
   (tampered + no_verifier are loud).

### Phase 2 — GitCommit facts + engine sealed heads

10. **GitCommit facts** — `tools/git_commit.ex:26-45`: rev-parse before/after via
    `Verify.Git.head/1`; staged-empty (`git diff --cached --quiet`) → `{:ok, %{status:
    "no_changes", sha: <live head>, ...}}`; success carries `committed: true`, full
    `sha`, `head_before`; distinct `add_failed`/`commit_failed` errors kept;
    `output_schema` extended.
11. **Engine head observation** — `workflow_event.ex` add `:head_observed` AND
    `:verify_certified` (both non-status-authority); observation in the wave-commit
    path for code-path runs with a `project_dir`, welded into `commit_wave` markers on
    the FIRST observation (durable baseline — P2: an in-memory baseline is laundered by
    crash + external move) and on every change; the verify reactor stamps a bounded
    `certification: %{head, tree_digest, mode}` field on its clean emission
    (`stage_emission.ex` optional field + whitelist decode, malformed → nil;
    WaveCollect-map encode), from which `handle_wave_value` welds
    `verify_certified: %{stage, head, tree_digest, mode}` — and RECLASSIFIES a
    clean-with-nil-certification emission to `{:inconclusive, "uncertified_green"}`
    (string reason; report ref preserved via the non-routing
    `:verify_report_recorded` marker) BEFORE the `:ok` split, so `clean:verify` and
    `:verify_certified` land in the same commit or not at all; `ComposerProjection` + `apply_markers` + seed state fold
    `observed_head`/`sealed_head`/`verified_integrity`, and the `stages_invalidated`
    clause clears `verified_integrity` when it covers the verify stage (no stale
    certificate reuse); head move with `clean:verify` live → weld retraction markers
    (same txn); **convergence-time re-check** before `finish(:converged)` compares the
    MODE-SPECIFIC tuple against `verified_integrity` (working-tree: current
    `diff_digest` + HEAD vs certified; sealed: HEAD + clean porcelain; mismatch OR
    unreadable → retract + re-verify, never converge); verify reactor consumes
    `state.sealed_head` (mode auto-select + head-match certification).

### Phase 3 — docs reconciliation + gate

12. **Docs sweep** (the item's own closing requirement):
    - `docs/exploration/camus/FEATURES-WORTH-BORROWING.md`: C1-2 + C1-6 Status lines
      (✅ ADOPTED, scoped a+b) with corrections — envelope richer than the summary
      (`checks[]`, `integrity_note`, `exit`, `reason`); classification 5 rules adapted
      for mix; "refuse loudly" = loud inconclusive envelope, not a raise; two-mode
      adaptation (`uncommitted_state` RED holds in sealed mode; working-tree mode is our
      divergence for non-committing routes, content-digest integrity); degrade-open
      corrected to inconclusive-on-capture-failure for would-be greens (law 4); "runs
      last" needed the inverse defer peel; OQ-4 entry gets its answer.
    - `docs/exploration/pms/orca/FEATURES-WORTH-BORROWING.md` OR2-2 +
      `docs/exploration/pms/openhelm/FEATURES-WORTH-BORROWING.md` OH1-3 +
      `OH-FIRST-WAVE.md`: rider Status stamps (what folded in, what was satisfied
      engine-side, camus-over-orca timeout/log_tail choices).
    - `docs/plans/unadopted-next-ten/README.md`: item 5 → ✅ DONE + corrections block
      (house habit).
    - `AGENTS.md`: new architecture bullet (Deterministic Verify Authority) + amend the
      Verdict bullet's "producer-less until #5".
    - `lib/jido_claw/orchestration/verdict.ex:14-16`: moduledoc "No producer emits this
      yet" → names the Verify producer (false-invariant sweep: rg remaining
      "producer-less"/"item 5" restatements and reconcile).
13. **Gate** — `mix format`, then `mix precommit` run directly (no pipes); report exact
    exit code + test counts verbatim. Known flake posture: one unrelated timing test
    (MemoryExport/collector/:pg) may flake per full run — rerun, don't treat as
    regression.
14. **Post-approval housekeeping** — write the review-feedback memories once out of
    plan mode (dedupe against existing files first): OsCmd Port/:enoent semantics +
    argv-not-shell + env-assignment-token trap; terminal/fold paths must not orphan
    pending artifacts (`Fold.fold` sees only `:ok` emissions — non-`:ok` evidence needs
    explicit deltas/markers); in-memory baselines that gate convergence must be durable
    (crash + external change launders them).

## Test matrix (all new/extended, red-first where behavioral)

- `test/jido_claw/orchestration/verify_test.exs` — table-driven classification (every
  camus rule + mix adaptations + collect-all multi-check), two-mode integrity via
  injected seams (sealed dirty-before RED w/ `checks: []` + head named; working-tree
  dirty-before = fact; tracked_mutation via porcelain (sealed) and via diff-digest on an
  already-dirty file (working-tree); head_moved; **would-be-green with failed
  head/digest/porcelain capture → `integrity_unavailable` inconclusive, never
  `clean`**; red-with-failed-capture stays red + `integrity_note`), no_verifier
  loud-inconclusive, envelope round-trip + fail-closed decode (garbage never decodes to
  a pass).
- `test/jido_claw/orchestration/verify/os_cmd_runner_test.exs` — scratch git repo +
  tiny scripts: exit 0/1/127; **missing executable via both paths (bare argv0
  unresolvable; Port `:enoent` rescue) → `missing_tool`**; **relative script
  argv0 (`./scripts/verify.sh`) resolves against the check cwd and RUNS (never
  misclassified `missing_tool`); a missing relative script → `missing_tool`; a bare
  argv0 findable only via the check's `env:` PATH override resolves + runs (and →
  `missing_tool` without the override)**;
  sleep > timeout → 124 + lever hint;
  tamper-during-verify scripts (edit tracked file → tracked_mutation; commit →
  head_moved); redaction-before-tail (a fake secret in output never reaches the
  envelope).
- `test/jido_claw/orchestration/verify/config_test.exs` — every resolution branch;
  unknown-check override → loud refusal; **scalar-with-shell-metacharacters AND
  scalar-with-leading-env-assignment (`MIX_ENV=prod mix test`) → loud validation
  errors, never a confusing `missing_tool`**; argv-list passthrough; `env:` map
  validated + overlaid on the scrubbed base; malformed YAML warn+skip shapes.
- `test/jido_claw/route_composer/verify_stage_test.exs` (fixture catalog + counter
  stub): green converge (clean:verify + sealed-head echo); red → Hook R fixer feedback
  (assert `review-feedback` carries the verify findings) → deferred solo re-verify →
  green; red exhaustion → `:verify_failed` (and `exhausted_fix_lenses` excludes verify);
  inconclusive past `infra_cap` → `review_infra_failed`; tampered → `:verify_tampered` +
  NO fixer re-fire + **the `verify-report` artifact is ACTIVE and reachable via the
  `:stage_tampered` marker + the parent terminal result, but appears in NEITHER
  `artifacts_produced` NOR `Fold.available/1`**; **restart after the tampered wave
  commit but before the terminal → rebuild (from PARENT events alone — never the child
  result) re-terminalizes `:verify_tampered` with evidence intact AND the tampered
  stage absent from the rebuilt `ran`** (the crash-window test);
  **laundered-green regression**: verify green while another lens still open → fixer
  wave → assert `clean:verify` retracted + re-verify before any `:converged` (must fail
  without the Hook F handling); **defer-order**: a mixed reviewer+verify cohort
  dispatches the reviewers first, verify solo after; restart mid-verify → dedupe +
  observe (not re-run); **tamper precedence** — tampered + an otherwise-terminal state
  (budget/max-wave exhaustion or would-be `:not_converged`) → `:verify_tampered` wins;
  **config-error channeling** — an invalid `verify_cmd`/unknown-check run resolves to
  the inconclusive emission (infra lane), never a Lane-B wave-execution `route_failed`.
  Phase-2 additions: **durable-baseline regression** — clean verify, kill the composer,
  move HEAD externally (scratch-repo commit), resume → rebuild reads the durable
  `:head_observed` baseline, retracts the stale `clean:verify`, re-verifies, and does
  NOT converge on the laundered green (must fail with an in-memory-only baseline);
  **convergence-time re-check** — external HEAD move after a green verify with no
  further waves → tick refuses `:converged`, retracts + re-verifies; **external tracked
  EDIT with HEAD unchanged after a green working-tree verify → digest mismatch vs
  `verified_integrity` → likewise refuses convergence** (the P1 tuple test); an
  UNREADABLE capture at the re-check likewise refuses convergence and routes the
  re-verify's `integrity_unavailable` through the infra lane; **certification decode**
  — `StageEmission.certification` round-trips through the WaveCollect map, malformed
  certification decodes to nil, and a clean-with-nil-certification verify emission is
  reclassified `{:inconclusive, "uncertified_green"}` BEFORE the fold (assert the
  parent log holds NO `clean:verify` without a same-commit `:verify_certified`; the
  infra lane handles the retry; the string reason + string `mode` round-trip the
  emission boundary); **no-orphan invariant** — after a `no_verifier` wave (nothing
  stored) and after an `uncertified_green` wave (stored + referenced via the
  non-routing `:verify_report_recorded` marker), no ComposerArtifact row for the wave
  is active-but-parent-unreferenced AND the report never appears in
  `Fold.available/1`;
  **invalidation clears the certificate** — fixer-driven `stages_invalidated` covering
  verify → `verified_integrity == nil` in projection AND mirror until the next
  certified green (no stale-certificate reuse); a live `clean:verify` with no
  `verified_integrity` still fails the re-check closed (defensive backstop).
- `test/jido_claw/tools/git_commit_test.exs` (extend) — commit facts (`committed:
  true`, full sha, heads differ); empty-stage `no_changes` + live sha; add-failure
  distinct.
- Doctrine drift/pin updates (`doctrine_test.exs`); oath anchor asserted in the three
  templates' prompts. Optional: one eval `:composer` seed case pinning the green
  envelope.
- Composer tests stay ms-fast (stub runner); only the runner-integration file touches
  real git (scratch repos; never `mix precommit` recursively).

## Verification

1. Targeted suites as each phase lands: `mix test test/jido_claw/orchestration/verify*`
   `test/jido_claw/route_composer/verify_stage_test.exs`
   `test/jido_claw/tools/git_commit_test.exs test/jido_claw/doctrine_test.exs`.
2. Behavioral regression tests written red-first (laundered-green retraction; tampered
   evidence reachability + crash-window; no_changes).
3. Full gate: `mix precommit` run directly — exit code + counts reported verbatim. Plan
   is complete only on a passing gate (zero credo/reach findings kept).
4. Nothing committed; `git status` at the end shows only this item's files (argus doc
   edits untouched).

## Risks / gate hazards

- **reach --strict**: single-source the git `System.cmd` seam in `Verify.Git` (no
  clone into GitCommit); one app-env read seam (`Verify.Config.opt/1`) — no trivial
  forwarders left behind if helpers move.
- **dialyzer**: keep custom error atoms out of `Ash.transact` error channels (route via
  success channel + literal remap — the `unwrap_transact` precedent); Zoi schemas (if
  any) map-form only.
- **Composer GenServer.call answers only when parked** (test-support memory note) —
  drive composer assertions via `run_sync` + reloaded parent, not calls mid-wave.
- **Present-nil trap** on the config triple (`maybe_put` conditional-put; coerce on
  read).
- **Sizing**: this is a full M (two phases + docs). Phase 1 is independently green
  (sealed_head simply stays nil → working-tree mode); Phase 2 is additive. If it proves
  too large mid-flight, the pause point is after Phase 1's gate — but the plan targets
  landing both.
