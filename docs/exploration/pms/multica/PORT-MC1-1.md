# PORT-MC1-1 — Native CLI session resume for Forge runners (semantics map)

Implements [MC1-1 — Native CLI session resume for Forge runners](FEATURES-WORTH-BORROWING.md#mc1-1-native-cli-session-resume-for-forge-runners--the-full-resume-stack)
(BORROW-PATTERN + BORROW-REFERENCE — their edge-case list is the spec), carrying
the recorded riders: chorus CH2-6/CH3-2 (anchor-ownership axis + group
teardown), symphony SY3-3 (continuation turns send guidance only), bosun BO2-3
(the poisoned-resume error inventory — its taxonomy half already shipped in
`RunFailure`), herdr HD2-2 (`session_start_source` vocabulary), cmux CM2-3
(restore-argv sanitizer invariants as contract tests), myrlin (rejections:
`--continue`, probe-from-disk), emdash EM3-3 (transcript honesty + loud
resume failure). Source: multica-ai/multica @ `129efb768` (modified
Apache-2.0; patterns only, no code transcription — Go → Elixir). Target:
jido_radclaw @ `6e252a40` + the Wave A #1 RunFailure build (uncommitted).
All source cites below re-read firsthand at the pin on 2026-07-11.
Date: 2026-07-11.

Standing posture (operator decisions, 2026-07-11 interview): fullest scope —
runner machinery + crash-recovery + `apply_input` continuation + the memory
consolidator converted to a true multi-iteration driver; `kill_tree/1` stays
the house kill mechanism with a graceful window + VM-shutdown ChildTracker
(never `setsid`); executor PR-3's fresh-session-per-review-wave pin is
untouchable (the executor never arms).

## What the source actually does (their terms)

1. **Flag-driven resume, no transcript probing** (`claude.go:594-596`): a
   recorded `session_id` becomes `--resume <id>` on the next spawn. Codex
   goes through its app-server protocol: `thread/resume` with the prior
   thread id, falling back to `thread/start` on *recoverable protocol*
   errors (unknown thread, schema mismatch) but failing fast on *transport*
   errors (`codex.go:1076-1133`).
2. **Eager pinning** (`daemon.go:4245-4262`): the daemon persists
   `session_id` + `work_dir` server-side the moment the backend's FIRST
   status message reveals them (`sessionPinned.Swap(true)` one-shot latch,
   fire-and-forget goroutine with 5s timeout) — a daemon crash mid-run still
   leaves a resumable anchor.
3. **Silent-mint detection** (`resolveSessionID`, `claude.go:634-646`): when
   the caller requested `--resume` but claude emitted a DIFFERENT session id
   AND the run failed, the resume did not land (claude prints "No
   conversation found with session ID: …", mints fresh, exits). Reporting
   `""` keeps the daemon's fresh-retry fallback able to trigger instead of
   silently persisting the freshly-minted id as if resume succeeded.
4. **cwd-gate** (`gateResumeToReusedWorkdir`, `daemon.go:3248-3270`): the
   prior session is cleared unless the task runs in the EXACT workdir the
   session was recorded against — CLI session stores key to cwd
   (`~/.claude/projects/<encoded-cwd>/`), so a foreign-workdir resume fails
   within a second, permanently (the failed run records no session; the next
   claim serves the same stale pointer).
5. **Retry-once-fresh** (`daemon.go:3910-3932`): `result.Status == "failed"
   AND PriorSessionID != "" AND result.SessionID == ""` (resume failed
   before establishing a session — distinguished from a failure DURING
   execution) ⇒ one retry with `ResumeSessionID = ""`, usage merged across
   both attempts.
6. **Poisoned-session taxonomy** (`poisoned.go:40-134`): three classifiers
   exclude sessions from the `(agent_id, issue_id)` resume lookup —
   (a) fallback-marker outputs, ≤320 chars only (real fallbacks are
   one-sentence; long outputs QUOTING a marker are real conclusions — the
   cap errs toward NOT classifying); (b) the Anthropic
   `400` + `invalid_request_error` pair (BOTH substrings required — bad
   content is baked into history, every resume replays it; 429/5xx stay
   resumable); (c) codex semantic-inactivity markers, provider-gated.
7. **Env scrub** (`isFilteredChildEnvKey`, `claude.go:665-696`): exact-name
   denylist `CLAUDECODE`, `CLAUDE_CODE_ENTRYPOINT/EXECPATH/SESSION_ID/
   SSE_PORT` + the `CLAUDECODE_*` prefix — deliberately NOT the whole
   `CLAUDE_CODE_*` namespace (blanket-stripping broke Windows by removing
   `CLAUDE_CODE_GIT_BASH_PATH`).
8. **Deadlock discipline** (`claude.go:100-150`): the prompt writes to stdin
   in its OWN goroutine while a reader drains stdout (with `--verbose
   --output-format stream-json` the CLI banners before reading stdin; an
   undrained stdout blocks the CLI, which never reads stdin, which blocks
   the writer until the kill); stdin stays open for `control_request`
   frames; `cmd.WaitDelay` backstop; stderr tailed into errors.
9. **Runtime pinning** (`handler/daemon.go:1616,1663-1670`): resume is
   machine-pinned — a prior session on another runtime is never offered.

## Side-by-side shapes (load-bearing pairs)

| # | multica shape | jido_radclaw shape | divergence, why |
| --- | --- | --- | --- |
| 1 | `--resume <id>` appended to argv when `ResumeSessionID != ""` (`claude.go:594-596`) | `resolve_mode/…` per turn: `:continuation` ⇒ `--resume <anchor-id>` + GUIDANCE-ONLY prompt, no `--session-id`, never `--continue` (myrlin rejection); default-off ⇒ today's argv byte-identical (PR-3 pin) | Same flag mechanism; our prompt swaps to guidance-only on continuation (SY3-3 — their daemon re-sends task deltas; we never restate the task) |
| 2 | Anchor captured from the CLI's first emitted status event, pinned server-side mid-run (`daemon.go:4245-4262`) | **Claude: client-minted** — `--session-id <Ecto.UUID.generate()>` on fresh-armed spawns, anchor persisted BEFORE spawn; the parser then VERIFIES the CLI's `system` init event echoes the minted id | MORE eager than theirs (pre-spawn beats first-event). Enabled by our batch parsing: we cannot pin mid-stream (no streaming reader today), so client-minting is the only way to get crash-safe eager anchoring. Verification replaces capture. |
| 3 | Codex `thread/resume` protocol call, `thread.started` id extraction | **Codex: anchor only-after-clean-exit** — capture `thread.started` (currently dropped, `codex.ex:279-280`), hold `:provisional`, promote to `:anchored` only on a clean `:done` exit (CH2-6 backend-trust rule); fresh-armed drops `--ephemeral` so the session persists under the per-run `CODEX_HOME` | Codex cannot client-mint (backend-owned ids) and a dirty exit may leave a corrupt rollout — provisional-until-clean is the CH2-6 ownership axis (client-owned claude vs backend-owned codex) |
| 4 | Retry-once-fresh decided daemon-side on `SessionID == ""` (`daemon.go:3917-3932`) | **Driver-side retry authorization against a server-authoritative effect ledger**: ONE fresh attempt iff the runner tagged `resume_rejected` (→ `RunFailure` `agent_session_poisoned`, retryable) AND the closed attempt's ledger shows zero mutations + no commit marker AND deadline floor AND per-anchor latch unset. Runners NEVER auto-retry. | Their tasks are idempotent-ish issue turns; our consolidator attempt can have PUBLISHED memory mutations through the scoped MCP endpoint — a blind re-send double-applies. The ledger (attempt-bound endpoint capability tokens, close-then-evaluate) is the evidence law 2 demands. |
| 5 | No fencing — one daemon owns one runtime's tasks | **Epoch/token incarnation fencing** in `metadata["forge_recovery"]`: locked select+mint CAS per Harness incarnation, token-authorized writes (`:stale_resume_write` on mismatch), `current_checkpoint_id` pointer as the single checkpoint-selection authority | No multica equivalent to port — forced by OUR races: iteration Tasks run under the global Task.Supervisor and can outlive their Harness; Manager recovery can start incarnation N+1 while N's task still holds writes. |
| 6 | Daemon owns recovery for all tasks | **Recovery owner = RunServer for consolidations** (retains lock/MCP endpoint/`run_forge_home` across a harness crash; close-token-then-evaluate-ledger; the crash-replay policy table); Manager recovery restores process+state only, NEVER replays | Our Manager is generic Forge machinery; replay is exclusively the driver's decision (their daemon conflates both roles safely because tasks are single-writer) |
| 7 | Poisoned classifiers return their `failure_reason` strings (`poisoned.go`) | Shipped in Wave A #1: `RunFailure.classify/1` string rules + the `{:fallback_marker, output}` tuple arm; runners tag ≤320-char marker shapes and `resume_rejected`; `resume_unsafe?/1` drives anchor poisoning | Same semantics, one vocabulary earlier than theirs (they map at task-row persist; we classify at the runner terminal) |
| 8 | Env scrub inside the backend's `mergeEnv` (`claude.go:671-696`) | FIRST clause in `Security.Redaction.Env.inheritable?/4` + override-map rejection in `scrubbed_cmd_env/1` + docker `inject_env` rejection — operator `extra_allowed_env_vars` can NEVER re-open a denylisted key | Ours sits in the central redaction module (every spawn path: port env, cmd env, MCP stdio patch, `.forge_env`) — their per-backend placement would miss our docker path |
| 9 | Writer-goroutine ≠ reader + stderr tail (`claude.go:100-150`) | Satisfied BY CONSTRUCTION: prompt rides argv (never stdin), stdin `</dev/null` (host_shell.ex:212, docker :506), stderr merged via `:stderr_to_stdout` (os_cmd.ex:103) so error output already carries the tail. Pin test on the redirect; NO new code. | Their deadlock geometry requires stdin-protocol writes; ours has none. Merged-not-tailed stderr is a documented divergence (we get the whole tail in output). |
| 10 | `setsid` + process-group kill | `OsCmd.terminate_tree/2`: pre-TERM fixpoint descendant snapshot → SIGTERM all → bounded grace window with re-discovery → SIGSTOP-fixpoint + SIGKILL survivors; birth-identity (`ps -o lstart=`) PID-reuse guard; ChildTracker VM-shutdown sweep | `os_cmd.ex:14-17` rejects process-group semantics deliberately (macOS portability). Preserved-set walk + tracker is the equivalent-strength substitute; the orphan-between-snapshots residual is documented and bounded by the boot reaper. |

## Behaviors table

### Preserved exactly

| Behavior | Source | Notes |
| --- | --- | --- |
| Flag-driven resume; never transcript/disk probing | `claude.go:594-596` | myrlin's probe-from-disk explicitly rejected; the Session row is the anchor store |
| Eager anchor persistence (crash mid-run leaves a resumable anchor) | `daemon.go:4245-4262` | via pre-spawn client mint (shape #2) — strictly earlier than theirs |
| Silent-mint detection: emitted id ≠ requested id on a failed resume clears the anchor | `resolveSessionID` | our parser verifies the `system` init event id against the minted/requested id; mismatch ⇒ anchor cleared + loud signal, NO runner retry |
| cwd-gate: anchor dropped when the workdir isn't the one it was recorded against | `daemon.go:3248-3270` | armed-only `pwd` capture; recovered sandbox ⇒ new workdir ⇒ fresh (source `:new`) |
| Poisoned ≤320-char fallback-marker cap (long outputs quoting markers are real results) | `poisonedOutputMaxLen` | tuple arm `{:fallback_marker, output}` → `agent_fallback_message`, ¬retryable |
| `400`+`invalid_request_error` BOTH-substrings rule; 429/5xx stay resumable | `classifyPoisonedError` | shipped in `RunFailure` string rules (Wave A #1) |
| Poisoned ids excluded from resume lookup; a poisoned anchor id is never reused | `agent.sql:501-503` | `ResumeState.poison/…` — poisoned ∧ anchored impossible by construction; a later clean fresh run MAY establish a NEW anchor |
| Exact-name env denylist + `CLAUDECODE_` prefix; NOT the whole `CLAUDE_CODE_*` namespace | `claude.go:665-696` | same five names + prefix; the Windows lesson recorded in the module |
| Codex resume protocol-error ⇒ fresh-capable, transport-error ⇒ fail fast | `codex.go:1076-1133` | mapped onto exec-CLI: recognized invalid-anchor rejection class ⇒ `resume_rejected` (driver may authorize ONE fresh attempt); transport/process failures ⇒ plain error, no retry |
| Retry-once semantics: at most ONE fresh retry per failed resume | `daemon.go:3917-3932` | per-anchor latch; plus our extra ledger/deadline conditions (shape #4) |

### Deliberately changed

| Behavior | Theirs | Ours | Why |
| --- | --- | --- | --- |
| Claude anchor establishment | First-event capture, mid-run pin | Client-minted `--session-id` pre-spawn; parser verifies the echo | Batch parsing can't pin mid-stream; pre-spawn minting is MORE crash-safe and makes the anchor deterministic |
| Codex anchor establishment | `thread/resume` app-server protocol | `codex exec` + capture `thread.started`, `:provisional` until clean `:done` exit promotes (CH2-6) | We drive the exec CLI, not the app-server; a dirty exit may corrupt the rollout — backend-owned ids get backend-trust rules |
| Retry authorization | Daemon-side, condition = no session established | Driver-side, condition = `resume_rejected` ∧ zero-effect ledger ∧ deadline floor ∧ latch; ledger-less callers (run_loop, plain harness) NEVER auto-retry | Effects: our attempts can publish memory mutations mid-attempt; "no session established" is not evidence of "no effects" here |
| Recovery ownership | One daemon, monolithic | RunServer owns consolidation recovery end-to-end (lock/endpoint/home retention, crash-replay policy); Manager restores process state only | Two-owner architecture already exists; replay is a driver decision (trust-boundary law 3) |
| Incarnation safety | None needed (single-writer) | Epoch/token CAS fencing, pointer authority, `:stale_resume_write` | Our global-Task + recovery races demand it; no source analogue |
| Continuation prompt | Daemon re-sends task delta text | Guidance-only continuation prompt; the original task NEVER re-rides a continuation argv (CM2-3 sanitizer contract test) | SY3-3; token cost and drift — the CLI session already holds the task |
| Env-scrub placement | Per-backend `mergeEnv` | Central `Security.Redaction.Env` first-clause + override rejection + docker `.forge_env` filter | One choke point covers every spawn path incl. docker; operator allowlists can't re-open |
| stderr | Bounded tail appended to errors | Merged (`:stderr_to_stdout`) — already in output | Existing house plumbing; strictly more information; pin test documents it |
| Group teardown | `setsid` + group SIGKILL | `kill_tree/1` + preserved-set graceful TERM window + ChildTracker VM-shutdown sweep + birth-identity guard | `os_cmd.ex:14-17` rejects setsid for macOS portability (operator decision 3) |
| Session-store location | Host `~/.claude/projects/<cwd>` implicit | Codex sessions live under per-run `CODEX_HOME=run_forge_home` (0700, retained for the run's life; final teardown is the LAST deleter after the session-wide ChildTracker barrier) | Our per-run isolation already owns the home dir; retention across harness crash is what makes crash-resume possible |
| Crash-native-resume scope | Any runtime restart on the same machine | `:local` (HostShell) sandboxes only; docker-armed sessions get in-run resume + post-crash fresh via the cwd-gate, Trace'd honestly | Docker recovery provisions a NEW microVM/workspace (docker.ex:91) and `run_forge_home` isn't mounted — the stable 0700 host-mounted session-dir design is the named trigger if docker crash-resume becomes wanted |

### Dropped

| Behavior | Source | Why |
| --- | --- | --- |
| Runtime pinning (machine-scoped resume offers) | `handler/daemon.go:1616` | Single-node Forge execution today; the DB lease/ownership layer already fences multi-node run ownership — a machine-affinity layer on session anchors has no consumer |
| Stdin writer-goroutine deadlock machinery | `claude.go:100-150` | No stdin protocol on our path (prompt rides argv; stdin `</dev/null`) — satisfied by construction, pin-tested, no code |
| `prepare-lease` provisioning heartbeats | `daemon.go:3389` | Multica-daemon liveness concern; our Harness phases + run deadline already bound provisioning |
| Coalesced re-registration / authoritative-replace | `daemon.go:305-597` | Daemon-fleet machinery with no equivalent surface |
| `thread/resume` model/effort override params (MUL-2339) | `codex.go:1081-1092` | Our argv rebuilds model/effort fresh EVERY turn (CM2-3 invariant) — the stale-config bug their override fixes cannot occur |

## Edge cases (their tests ↔ ours)

| Their test | Our planned equivalent | Expected behavior both sides |
| --- | --- | --- |
| `TestResolveSessionID` (`claude_test.go:663`) | claude id-verify rows: minted id echoed ⇒ anchored; mismatch + failure ⇒ anchor cleared, loud `ResumeSignal`, no retry | A silently-minted fresh session is never persisted as a successful resume |
| `TestGateResumeToReusedWorkdir` (`daemon_test.go:981`) | cwd-gate rows: workdir match ⇒ `:continuation`; mismatch/missing ⇒ `:fresh_armed`, anchor dropped, source `:new` | Foreign-workdir anchors never reach argv |
| `TestExecuteAndDrain_ResumeFailureFallback` (`daemon_test.go:1046`) | driver retry rows: `resume_rejected` + zero-effect ledger ⇒ exactly one fresh attempt; effectful ledger ⇒ terminal, no retry | One fresh retry, ever; ours adds the effect fence |
| `TestClassifyPoisonedOutput` (`poisoned_test.go:10`) | `RunFailure` fallback-marker rows (shipped) + runner tagging rows: ≤320-char marker ⇒ `agent_fallback_message`; long output quoting a marker ⇒ NOT classified | The cap errs toward not-poisoned |
| `TestClassifyPoisonedError` (`poisoned_test.go:90`) | `RunFailure` string rows (shipped): both substrings ⇒ `api_invalid_request`; 429/5xx ⇒ rate/server kinds, resumable | Narrow both-markers match |
| `TestClassifyResumeUnsafeTimeout` (`poisoned_test.go:175`) | `agent_semantic_inactivity` kind reserved (producer-pending — no semantic-inactivity probe in this build); documented in run-failure.md | Provider-gated; never fires for non-codex |
| `TestMergeEnvFiltersClaudeCodeVars` (`claude_test.go:521`) | env denylist truth table: five exact names + `CLAUDECODE_` prefix stripped; `CLAUDE_CODE_GIT_BASH_PATH`-class user config SURVIVES; operator allowlist/override cannot re-open | The Windows lesson is a positive test row |
| `TestClaudeExecuteDoesNotDeadlockOnStartupStdoutBurst` (`claude_deadlock_test.go:160`) | pin test: runner spawn path carries stdin `</dev/null` + `:stderr_to_stdout` (no equivalent deadlock geometry to exercise) | Documented-by-construction, not machinery |
| `TestBuildClaudeArgsIncludesStrictMCPConfig` / blocked-args family (`claude_test.go:310+`) | CM2-3 sanitizer contract tests: continuation argv never contains the original task; permission/trust flags derive ONLY from `state.access`; `--continue`/`--last` never appear; `--session-id` only fresh-armed claude; resume selectors only on continuations; model/mcp/effort rebuilt fresh each turn | The restore-argv sanitizer invariants |
| (no source analogue) | fencing/ledger/publish-certificate suites (stale-cannot-mint, token rotation, close-then-evaluate races, commit-then-hang, three-outcome reconciliation) | Ours alone — the divergences in shapes #4/#5/#6 |

## Sign-off gate

**Status: explicitly signed off by the operator 2026-07-11** — all four open
divergences confirmed as mapped (1: claude client-minted pre-spawn anchor;
2: codex provisional-until-clean-exit; 3: driver-side ledger-gated retry;
4: `:local`-only crash-native-resume), question 5 restated from the earlier
operator decision. Implementation of #2 is cleared.

Open questions for the operator — the load-bearing divergences above, restated
as decisions. Everything else in this map follows the source or a
previously-ratified rider.

1. **Claude client-minted pre-spawn anchor** (shape #2) — more eager than
   multica's first-event capture; the parser verifies the echo instead of
   capturing. Alternative: batch-parse capture at iteration end (their
   fidelity, but a mid-iteration crash loses the first turn's anchor).
2. **Codex provisional-until-clean-exit** (shape #3, CH2-6) — a codex anchor
   is trusted only after a clean `:done` exit. Alternative: anchor at
   `thread.started` like claude (risks resuming a corrupt rollout after a
   dirty exit — bosun's poisoned inventory says this is the dominant codex
   failure).
3. **Driver-side ledger-gated retry** (shape #4) — replaces their daemon-side
   retry-once-fresh; ledger-less callers never auto-retry. Alternative:
   port their rule verbatim at the harness layer (unsafe: cannot see
   mid-attempt MCP mutations).
4. **Crash-native-resume scoped `:local`** — docker-armed sessions resume
   in-run only, go fresh after a crash (cwd-gate), honestly Trace'd; the
   0700 host-mounted session-dir design is the recorded trigger for docker
   crash-resume. Alternative: build the docker mount now (scope growth).
5. **Group teardown = `kill_tree` + graceful window + ChildTracker** (already
   operator-decided 2026-07-11; restated for the record since it diverges
   from the source's `setsid`).

Implementation of #2 starts only after explicit sign-off on this map.
After shipping, `docs/system/forge-session-resume.md` cites this map as port
provenance and the inventory entry reconciles per the lifecycle.
