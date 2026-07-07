---
type: subsystem
description: Engine-run deterministic verify — exit-code verdicts, head-bound integrity certificates, tamper fencing, the VERIFY_OATH.
sources:
  - lib/jido_claw/orchestration/verify.ex
  - lib/jido_claw/orchestration/verify/config.ex
  - lib/jido_claw/route_composer/verify_reactors.ex
  - lib/jido_claw/route_composer/loop.ex
  - lib/jido_claw/tools/git_commit.ex
verified: 2026-07-07
verified_sha: "a1fa5215"
---

# Deterministic Verify Authority (engine-run, head-bound, tamper-fenced)

## What & why

`JidoClaw.Orchestration.Verify` is the engine-side verifier: the composer runs the
repo's verify command itself and reads the **exit code** — law 2 of
`docs/TRUST-BOUNDARIES.md`, the verdict never rides an LLM relay. Port provenance:
camus C1-2 + C1-6a @ `53da91b3` (MIT), next-ten #5.

## Invariants & contracts

- Dispatched as the catalog's `{:verify, "default"}` stage (`Reactors.VerifyStage`, the
  gate-reactor shape minus the park; `VerifyReactors` is the closed name→module seam),
  which `Loop.defer_solo_verify/2` — the INVERSE of the gate peel — makes run LAST in
  its Kahn level, solo.
- A catalog holds **at most one** verify stage (`CatalogValidator` invariant 10 —
  `verified_integrity` is a single latest-wins certificate, so a second verify
  authority would ping-pong retract/re-verify at convergence; multi-check needs belong
  in one stage's named `checks:`).
- Command resolution never passes silently and never skips silently: per-run
  `verify_override` → `.jido/config.yaml` → mix auto-detect → a loud INCONCLUSIVE
  envelope. **No shell, ever**: argv lists via `Core.OsCmd`.
- **The committed invariant**: `clean:verify` and its certificate land in the same
  commit or not at all — an uncertified green is reclassified
  `{:inconclusive, "uncertified_green"}` BEFORE the fold.
- **VERIFY_OATH**: a tampered verify is never retried and never fed to the fixer —
  remediation destroys the evidence. The tick checks `tampered_stages` AHEAD of every
  other terminal branch.
- The three LLM verification judges (`verifier`/`system_verifier`/`test_runner`) carry
  the verbatim `verify_oath` doctrine slice + read-only `lua_query`/`lua_docs` evidence
  (OpenHelm OH1-3) — they diagnose reds, never hold the verdict.

## Mechanics

- **Command resolution** (`Verify.Config`, the OQ-4 design note of record): per-run
  `verify_override` (persisted in parent config) → `.jido/config.yaml`
  `verify_cmd:`/`verify:` (incl. the orca OR2-2 registry-lite named `checks:`; an
  override naming an unknown check refuses loudly, and a non-map `verify:` value
  refuses loudly too — never a silent fall-through to autodetect) → mix auto-detect
  (`precommit` alias ⇒ `mix precommit`, else `mix test`). Argv0 resolves execvp-style;
  scalars are whitespace-split only when metacharacter-free and not
  env-assignment-led; config errors ride the infra lane, never a wave failure.
- **Integrity modes**, auto-selected by the engine-observed `sealed_head` (C1-6b: the
  composer welds `:head_observed` markers at wave boundaries — first = durable
  baseline, a change = seal — and `Tools.GitCommit` returns engine facts: rev-parse
  before/after, `committed` ⇔ head moved, staged-empty ⇒ explicit `no_changes`
  success):
  - **sealed** is camus-verbatim: dirty tracked tree before checks ⇒ RED
    `uncommitted_state`, checks never run; HEAD≠seal ⇒ `head_moved`.
  - **working_tree** (today's non-committing default) records dirty-before as an
    envelope FACT and fences mid-verify integrity via HEAD stability + a
    content-addressed `git diff --no-ext-diff --no-textconv --binary` sha256 digest
    (porcelain can't see content edits to already-dirty files).
- **Verdict mapping**: green ⇒ `clean:verify` + a welded `:verify_certified` marker
  (`{head, tree_digest, mode}`; the report is preserved via the non-routing
  `:verify_report_recorded` marker on reclassification). Red ⇒ `findings:verify` +
  `findings`/`action_needed` artifacts riding the existing Hook R fixer re-fire
  (exhaustion ⇒ `:route_verify_failed`). Inconclusive
  (`missing_tool`/`no_tests`/`timeout`/`output_limit`/`integrity_unavailable` — a
  would-be green with a FAILED git capture downgrades here, the law-4 correction of
  camus's degrade-open) rides the verdict-normalizer infra lane and stores NO report.
  Tampered ⇒ the `:route_verify_tampered` terminal via a welded `:stage_tampered`
  marker — report ref on the marker, NEVER `artifacts_produced` (a tamper report must
  not look routable).
- **Convergence** re-derives the MODE-SPECIFIC integrity tuple against the folded
  `verified_integrity` before `:converged` (mismatch or unreadable capture ⇒ retract +
  re-verify; `stages_invalidated` covering the verify stage clears the certificate;
  Hook F retracts a live `clean:verify` in the same welded batch when a fixer runs).

## Config & telemetry

Config under `:verify` (`timeout_ms`/`max_output_bytes`/`tail_lines`; NO `enabled?` —
registration is the switch; test.exs points `runner:`/`git:` at the hermetic stub).
Runner output is redacted-in-full (ANSI-strip → patterns) BEFORE tailing. Telemetry
counter `jido_claw.verify.total` + `:composer` Trace events (bounded — log tails live
only inside the encrypted `verify-report`).

## Residuals & accepted risks

- `verify_cmd` is operator-owned config a mid-run fix loop could edit (camus C2-7,
  parked).
- Untracked-file mutation is invisible to tracked-only integrity (camus-consistent).
- Engine verify runs outside the tool pipeline (no approval gate / loop guard — it is
  engine code, law 1).

## Source map

- `lib/jido_claw/orchestration/verify.ex` — runner, integrity modes, verdict mapping
- `lib/jido_claw/orchestration/verify/config.ex` — the resolution chain, named
  `checks:`, argv discipline
- `lib/jido_claw/route_composer/verify_reactors.ex` — `VerifyStage`, the closed
  name→module seam
- `lib/jido_claw/route_composer/loop.ex` — `defer_solo_verify/2`
- `lib/jido_claw/route_composer/catalog_validator.ex` — invariant 10
- `lib/jido_claw/tools/git_commit.ex` — engine facts: rev-parse before/after,
  `no_changes`
