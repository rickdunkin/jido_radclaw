---
type: subsystem
description: Engine-run deterministic verify — exit-code verdicts, head-bound integrity certificates, tamper fencing, the VERIFY_OATH.
sources:
  - lib/jido_claw/orchestration/verify.ex
  - lib/jido_claw/orchestration/verify/git.ex
  - lib/jido_claw/orchestration/verify/config.ex
  - lib/jido_claw/route_composer/verify_reactors.ex
  - lib/jido_claw/route_composer/loop.ex
  - lib/jido_claw/tools/git_commit.ex
  - lib/jido_claw/agent/templates.ex
  - lib/jido_claw/agent/workers/system_verifier.ex
  - lib/jido_claw/application.ex
verified: 2026-07-10
verified_sha: "b2cae5cd"
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
- The code-route LLM verification workers (`verifier`/`test_runner`) carry the
  verbatim `verify_oath` doctrine slice + read-only `lua_query`/`lua_docs` evidence
  (OpenHelm OH1-3) — they diagnose reds, never hold the deterministic code verdict.
  `system_verifier` belongs to the separate reverse-verify system route, where its
  verdict is authoritative; every real-host `run_command` there is therefore bound
  to an exact, single-use operator approval by the template overlay.

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
  - **sealed** keeps the camus committed-state posture with the signed
    [C1-2 audit hardening](../exploration/camus/PORT-C1-2-AUDIT.md): tracked dirt
    **or any nonignored untracked path** before checks ⇒ RED
    `uncommitted_state`, checks never run; HEAD≠seal ⇒ `head_moved`. Gitignored
    paths remain outside the authority.
  - **working_tree** (today's non-committing default) records dirty-before as an
    envelope FACT and fences mid-verify integrity via HEAD stability + a
    domain-separated sha256 over the tracked
    `git diff --no-ext-diff --no-textconv --binary HEAD` plus a sorted manifest
    from `git ls-files --others --exclude-standard -z`. The manifest binds each
    exact path, lstat type/mode, and regular-file content or symlink target text;
    symlink targets are never read through. Regular reads are streamed under an
    open-descriptor + pre/post-lstat race fence (device/inode/type/size/mode/
    mtime/ctime; atime deliberately excluded), and two full-length bounded
    reads must produce the same hash.
  - Any positive digest/porcelain change during checks is RED tampering kind
    `working_tree_mutation` (the digest is opaque over tracked diff plus untracked
    manifest, so it does not claim which component moved). This includes a verify
    command creating a nonignored output artifact; capture failure remains the
    separate INCONCLUSIVE `integrity_unavailable` branch.
- **Untracked capture bounds** are 1,000 paths, 10 MiB aggregate regular content
  plus link-target bytes, and 4,096 bytes per path. A crossed bound, unsafe path,
  unsupported type, read failure, or detected race returns no digest, which maps
  toward `integrity_unavailable`/INCONCLUSIVE rather than green. The public
  `Verify.Git.path_fingerprint/3`, `path_fingerprints/3`, and
  `fingerprint_limits/0` keep other engine evidence on the same policy. Git
  manifest output is capped before collection; NUL parsing and arbitrary path
  enumeration stop at max+1 and sort only an accepted bounded set.
- **Capture liveness is VM-bounded**: `path_fingerprint/3`,
  `path_fingerprints/3`, and `diff_digest/2` run under the dedicated
  `VerifyCaptureTaskSupervisor` (default two children, hard-clamped to four) with
  a 10-second caller deadline. A FIFO swapped into the lstat→open gap can leave
  the dirty-I/O syscall alive even after its BEAM owner is killed, so timeout
  deliberately `Task.ignore`s the still-supervised task instead. It continues to
  occupy one bounded child slot until the syscall unwinds; the caller gets `nil`
  immediately and capacity exhaustion makes later captures fail closed rather
  than accumulating blocked I/O workers across verifies.
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
Filesystem capture containment uses `config :jido_claw, :verify_capture`:
`timeout_ms` (10,000) and `max_concurrency` (2, clamped to 4). Runner output is
redacted-in-full (ANSI-strip → patterns) BEFORE tailing. Telemetry counter
`jido_claw.verify.total` + `:composer` Trace events (bounded — log tails live only
inside the encrypted `verify-report`); capture timeouts emit
`[:jido_claw, :orchestration, :verify_capture_timeout]` with count 1 and the
configured timeout, never a path.

## Residuals & accepted risks

- `verify_cmd` is operator-owned config a mid-run fix loop could edit (camus C2-7,
  parked).
- The repeated-read + lstat/open-descriptor/lstat fence detects ordinary path
  replacement and mutation races but is not an atomic filesystem snapshot. A
  deliberately timed same-content ABA write can evade finite sampling; closing
  that requires a filesystem snapshot, mandatory writer cooperation, or a
  change journal rather than finer timestamps alone.
- Engine verify runs outside the tool pipeline (no approval gate / loop guard — it is
  engine code, law 1).
- Verify commands must not create nonignored repository artifacts. Such an artifact
  is a positively observed working-tree mutation and therefore terminal tampering,
  not an inconclusive result: retrying could otherwise launder the artifact into the
  next run's before-state and certify unreviewed bytes. Put expected outputs outside
  the repository or add their paths to the repository's ignore policy.

## Source map

- `lib/jido_claw/orchestration/verify.ex` — runner, integrity modes, verdict mapping
- `lib/jido_claw/orchestration/verify/git.ex` — untracked-inclusive porcelain,
  bounded/supervised path fingerprints, and the domain-separated working-tree digest
- `lib/jido_claw/application.ex` — the capture supervisor and VM-wide child ceiling
- `lib/jido_claw/orchestration/verify/config.ex` — the resolution chain, named
  `checks:`, argv discipline
- `lib/jido_claw/route_composer/verify_reactors.ex` — `VerifyStage`, the closed
  name→module seam
- `lib/jido_claw/route_composer/loop.ex` — `defer_solo_verify/2`
- `lib/jido_claw/route_composer/catalog_validator.ex` — invariant 10
- `lib/jido_claw/tools/git_commit.ex` — engine facts: rev-parse before/after,
  `no_changes`
- `lib/jido_claw/agent/templates.ex` — the system reverse-verifier's additive
  `run_command` approval policy
- `lib/jido_claw/agent/workers/system_verifier.ex` — authoritative system-route
  verifier contract and operator-approved command posture
