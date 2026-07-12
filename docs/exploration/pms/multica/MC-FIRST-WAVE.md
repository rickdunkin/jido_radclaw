# MC first wave — the adoptable-now queue

*A sequenced grab-list, not new design. Extracted 2026-07-04 from the
[multica inventory](FEATURES-WORTH-BORROWING.md)'s "suggested first wave" — the
three entries whose trigger is satisfied by the act of deciding to work (no argus
slice required). Everything else in the inventory is argus-slice-bound and stays
there; this doc exists so these three don't wait on argus by association. Refs
inherited from the inventory (verified there 2026-07-04 @ jido_radclaw `a9629f01`,
multica `129efb768`); re-verify at build time.*

**Queue discipline** (the next-five/next-ten habit): each item ends by reconciling
its source entry — add the dated Status line (the inventory carries none yet;
this queue is multica's first adoption pass), correct any claims the
implementation falsified, and update cross-refs the same session.

**Effort legend**: XS ≤ 2h · S ≤ 1 day · M 2–4 days.

| # | Item | Source | Effort | Shape |
| --- | --- | --- | --- | --- |
| 1 | Run-failure taxonomy (retryable / resume-unsafe subsets) | [MC1-4](FEATURES-WORTH-BORROWING.md#mc1-4-run-failure-taxonomy-with-retryable--resume-unsafe-subsets) | S | One module + two consumers |
| 2 | Native CLI session resume for Forge runners | [MC1-1](FEATURES-WORTH-BORROWING.md#mc1-1-native-cli-session-resume-for-forge-runners--the-full-resume-stack) | M | Two runners + Session metadata + contract tests |
| 3 | Exit-code tiering for `mix jidoclaw run` | [MC3-4](FEATURES-WORTH-BORROWING.md#mc3-4-cli-exit-code-tiering--error-translation-layer) | XS | One mapping table + tests |

Sequencing is load-bearing for 1 → 2 (item 2's `resume_unsafe?/1` consumes item
1's taxonomy); item 3 is independent, slot it anywhere.

---

## 1. MC1-4 — Run-failure taxonomy (S)

**What**: `JidoClaw.Orchestration.RunFailure` (land it in/beside
`Orchestration.Verdict`'s namespace so infra ≠ verdict ≠ failure stays one
vocabulary — camus C2-8's trust-boundary doc gets a section): a closed enum of
agent-run failure reasons with platform-vs-agent provenance in the name (multica's
7 + 14 split, `server/pkg/taskfailure/failure.go:19-175`, minus daemon-specific
members), an ordered most-specific-first `classify/1` for raw runner/provider
errors, and the two derived sets as functions — `retryable?/1` and
`resume_unsafe?/1` are **independent decisions** (their sharpest idea:
retry-the-work ≠ reuse-the-conversation).

**Consumers in the first cut**: Forge runner terminal results
(`forge/runner.ex:15-22`'s free-form `:blocked | :error` reasons get classified),
the composer's Lane-B infra decisions (today's scattered `retry: false` envelope
flags), and telemetry — pre-warm the reason labels the way their `AllReasons()`
does (`failure.go:234-247`) so dashboards don't discover values lazily.

**Done when**: the enum + classifier + both sets exist with table-driven tests;
Forge terminal results carry a classified reason; no decision site
string-sniffs an error to choose retry behavior; source entry MC1-4 gets its
Status line.

**Rider (2026-07-04, orca dig)**: this build also lands
[OR-FIRST-WAVE item 3's MC1-4 rider](../orca/OR-FIRST-WAVE.md) — the
silence-vs-wall-clock timeout split as distinct kinds (`stalled_no_output` vs
`stalled_wall_clock`), `user_cancelled` as a first-class non-failure kind, and
the group-kill discipline (`setsid` + kill the process group + a shutdown
ChildTracker) — [orca OR3-2](../orca/FEATURES-WORTH-BORROWING.md#or3-2-subprocess-failure-kind--dual-timeout-split--rider-on-mc1-4).
Reconcile that entry with MC1-4's.

**Riders (2026-07-04, connective pass — bosun + OpenHelm digs)**: two later digs
fold into this same build:
[bosun BO2-3](../bosun/FEATURES-WORTH-BORROWING.md) — the executor-boundary
infra-vs-session split (infra errors trigger failover/breakers and never count
against the task); and [OpenHelm OH1-1](../openhelm/FEATURES-WORTH-BORROWING.md) —
whose cron-health first-wave slice classifies dispatch results with exactly this
taxonomy split (retryable / rate-limited / infra / terminal) before counting
breaker strikes. Reconcile both entries with MC1-4's.

**Status (2026-07-11)**: ADOPTED — pre-argus Wave A #1.
`JidoClaw.Orchestration.RunFailure` beside `Verdict` as specified: 22 closed
kinds (multica's 21 minus the daemon members and their producer-less
`agent_blocked`, plus this queue's riders), total `classify/1` with an
order-invariant Splode-container precedence rank, `retryable?/1` /
`resume_unsafe?/1` as independent sets, `all_kinds/0` pre-warm export,
whitelist `decode/1`, `error_details/2` with reserved-key stripping.
Consumers: the Forge harness `:error` arm (broadcast `kind` + telemetry +
`failure_kind` event metadata), the composer Lane-B non-durable Trace, and
`counter("jido_claw.run_failure.total")`. Done-when met: table-driven tests
(producer table, Normalize-integration rows, totality over
raisers/throwers/exiters, permutation invariance); no decision site
string-sniffs retry behavior — the OR3-2 kinds ship as documented
producer-pending slots (`stalled_no_output` awaits Wave B #8's stall clock;
group-kill discipline lands with Wave A #2's ChildTracker). Deep truth:
`docs/system/run-failure.md` + the `docs/TRUST-BOUNDARIES.md` "Retry ≠
resume" section. OH1-1 reconciles when Wave B #5 builds on this split.

## 2. MC1-1 — Native CLI session resume for Forge runners (M)

**What**: stop re-sending accumulated prompts. `Runners.ClaudeCode` /
`Runners.Codex` (`forge/runners/claude_code.ex:61-88`, `codex.ex:90-132`) capture
`session_id` + workdir from the first stream-json `system` event, then pass
`--resume <id>` (claude) / `thread/resume` (codex) on subsequent iterations —
the `Runner` behaviour already has the seam (`serialize_state/restore_state`,
`forge/runner.ex:24-33`).

**The edge-case list is the spec** (all from the inventory's MC1-1 cites):

- **Eager anchoring** — persist the anchor into the Forge `Session` row's
  `metadata` at first event, not at completion (crash mid-run must leave a
  resumable anchor).
- **cwd-gate** — drop the resume pointer whenever the sandbox workdir changed
  (CLI session stores key to cwd; our sandboxes recreate paths, so this check is
  load-bearing).
- **Clear-and-retry-once** — a resume that silently minted a new session (emitted
  id ≠ requested id on failure) clears the anchor and retries fresh, once.
- **Poisoned classification** — port the three classifiers
  (`daemon/poisoned.go:52-134`: fallback-marker outputs ≤320 chars, the Anthropic
  `400 invalid_request_error` baked-into-history shape, semantic-inactivity
  timeouts) as producers into item 1's `resume_unsafe?/1`; fresh-vs-resume
  decisions route through it.
- **Env scrub at spawn** — exact-name denylist (`CLAUDECODE`,
  `CLAUDE_CODE_ENTRYPOINT/EXECPATH/SESSION_ID/SSE_PORT`, `CLAUDECODE_*` prefix),
  deliberately NOT the whole `CLAUDE_CODE_*` namespace. Matters on the dev box,
  where jidoclaw itself often runs under Claude Code and a child `claude`
  inherits the parent's session markers (today only MCP stdio scrubs —
  `core/mcp_stdio_transport_patch.ex`).
- **Deadlock discipline** — stdin writer separate from the stdout reader; bounded
  stderr tail appended to errors (their `claude_deadlock_test.go` fake-CLI
  re-exec pattern is the test shape).

**Done when**: a multi-iteration consolidator run resumes instead of re-sending
(observable: per-iteration input tokens stop growing quadratically); failed-resume
retry and poisoned-exclusion have contract tests; accumulated-prompt path remains
as the fallback; source entry MC1-1 reconciled. First beneficiary: the memory
consolidator; camus C1-1's executor seam inherits it (sequence this first — resume
is a property of the runner, the seam then inherits it).

**Riders (2026-07-04, Chorus dig)**: this build also lands
[CH-FIRST-WAVE item 3](../chorus/CH-FIRST-WAVE.md) — the
`anchor_ownership: :client | :backend` axis on runner resume state (claude anchors
are client-deterministic; codex anchors are backend-minted from `thread.started`
and trustworthy only after a clean fresh exit — persist on the Forge `Session`
row, never a dotfile), plus group-scoped teardown for host-tier runner children
(CH2-6 / CH3-2). Reconcile those two entries with MC1-1's.

**Rider (2026-07-04, connective pass — bosun dig)**: bosun's Codex poisoned-thread
inventory joins the poisoned-classification bullet's producers —
`invalid_encrypted_content`, the missing-rollout-path shape, and the
tool_call_id/400 baked-into-history family force fresh-not-resume
([bosun BO2-3](../bosun/FEATURES-WORTH-BORROWING.md); the poisoned-resume error
inventory is deliberately seeded from bosun + multica together).

**Riders (2026-07-04, connective pass — symphony + myrlin digs)**: two more
declarations name this build as their landing site, recorded here so the
builder sees them: [symphony SY3-3](../symphony/FEATURES-WORTH-BORROWING.md) —
continuation-turn prompt discipline (first turn sends the full rendered prompt;
continuation turns send **only guidance**, never re-send the task — the
session's own memory carries context; exactly the accumulated-context re-send
this item removes), declared in SY-FIRST-WAVE as shipping inside this item; and
the [myrlin dig](../myrlin-workbook/FEATURES-WORTH-BORROWING.md)'s resume-probe
hazards — the `--continue` shared-cwd hazard and probe-and-own mechanics,
myrlin's probe-from-disk variant on CH2-6's anchor-ownership axis. Reconcile
both entries with MC1-1's.

**Riders (2026-07-06, ades late-addition digs — herdr + cmux)**: two more
declarations name this build as their landing site:
[herdr HD2-2](../../ades/herdr/FEATURES-WORTH-BORROWING.md) — the corpus's
widest per-vendor resume argv table (14 CLIs: flag vs `=` vs subcommand vs
`--thread` vs path-kind refs vs the renamed `cursor-agent` binary) plus the
`session_start_source` change-reason vocabulary
(`startup | resume | clear | compact | new | fork`) that names *why* a session
id changed and gates whether a same-owner replacement is honored; and
[cmux CM2-3](../../ades/cmux/FEATURES-WORTH-BORROWING.md) — the restore-argv
sanitizer as acceptance criteria: a resumed launch is a replayed argv with
history, so prompts never replay, trust bypasses
(`--dangerously-skip-permissions`-class) never persist into restore,
resume/fork selectors are stripped before re-resume, and model/config flags are
the explicit recovery allowlist. Both are riders, not second builds — reconcile
with MC1-1's entry.

**Status (2026-07-11)**: ADOPTED — pre-argus Wave A #2 (semantics map
[PORT-MC1-1](PORT-MC1-1.md), explicitly signed off; deep truth
[docs/system/forge-session-resume.md](../../../system/forge-session-resume.md)).
One PREMISE CORRECTION: this entry's done-when assumed a multi-iteration
consolidator run existed to observe — falsified at HEAD (the consolidator was
single-shot, `run_server.ex:465`); the build CONVERTED it to a true
multi-iteration driver (turn 1 full prompt, guidance-only continuations, bound
+ deadline), so the observable now exists. Deliberate divergences from the
multica shapes, all recorded in the signed-off map: claude anchors are
CLIENT-minted pre-spawn via `--session-id` (more eager than their first-event
capture); codex anchors are provisional-until-clean-exit (CH2-6); their
daemon-side "failed resume with no established session → retry once fresh"
became a DRIVER-side retry gated on a server-authoritative effect ledger; an
epoch/token incarnation fence (no multica equivalent) fences every durable
write; crash-native resume is scoped to `:local` sandboxes (docker = in-run
continuations + cwd-gated fresh after a crash); `kill_tree`+grace-window
graceful teardown instead of setsid; runtime-pinning dropped. The edge-case
list landed: eager anchoring (pre-spawn persist through the fenced writer),
cwd-gate (structural via `resolve_mode/2`), clear-and-retry-once (the
ledger-gated `retry_fresh` + the id-verify anchor drop), poisoned
classification through `RunFailure.resume_unsafe?/1` (two producer-exact
live-probed rejection strings added), the env denylist (operator allowlists
can never re-open it), and deadlock discipline (held by construction — argv
prompts, `</dev/null` stdin, merged stderr). The myrlin rider's dispositions:
`--continue` is NEVER used (contract-pinned), probe-from-disk REJECTED —
anchors live fenced on the Session row, not dotfiles. Riders CH2-6/CH3-2,
SY3-3, BO2-3 (poisoned half), HD2-2, CM2-3, EM3-3 all landed — see each
entry's own Status line.

## 3. MC3-4 — Exit-code tiering for `mix jidoclaw run` (XS)

**What**: `cli/run_command.ex` (osa OS1-5) — *stale-claim correction
(2026-07-09/11): it never shipped "0/1 only"; HEAD carried the pinned OQ-4
contract `0 | 1 | 2 | 3` before this item* — is explicitly built for
scripting/agent callers. Adopt multica's tier table adapted, not verbatim
(`server/internal/cli/errors.go` + CLI_AND_DAEMON.md §Error-Messages — their
2=network/3=auth collide with our taken meanings, so new tiers get NEW codes).
Map from our existing error classes — this is one mapping table.

**Done when**: exit codes documented in the task's moduledoc + `--help`, covered
by tests (the `if [ $? -eq 4 ]` script case), and MC3-4 gets its Status line.

**Rider (2026-07-04, connective pass — pad dig)**: the tier mapping should
consume [pad PD1-2](../pad/FEATURES-WORTH-BORROWING.md)'s boundary error-code
registry (PD-FIRST-WAVE item 2) rather than re-sniffing envelopes — the pad
first wave carries the same cross-queue note from its side; whichever build
lands second adds the Status cross-ref.

**Status (2026-07-11)**: ADOPTED (pre-argus Wave A #4, operator-decided
table) — the pinned 0–3 contract extended with **4 = not-found** (well-formed
`--session` UUID with no row; `--continue` with no open CLI session — both
resolver branches discriminate a genuine `Ash.Error.Query.NotFound`-class
miss from infrastructure failures via `AshErrors.not_found?/1`, which keep
exit 1), **5 = provider-unreachable** and **6 = provider-auth** (classified
at the generic turn-error arm via `RunFailure.classify/1` — item 1's
taxonomy, consumed instead of PD1-2's registry, which remains pending; the
cross-ref lands when PD1-2 builds). Malformed UUIDs and foreign-workspace
sessions stay exit 2 (caller mistakes, not misses); launched-run failures
stay exit 1 (provenance lives in run telemetry). No `--help` flag exists —
the mix-task/escript moduledocs ARE the help and carry the table. The
`$? -eq 4` script case is pinned in `run_command_test.exs`.

---

**Collision notes**: none with `docs/plans/unadopted-next-ten/` (its items 4–10
are composer/judgment work); item 2 touches the same runner files as camus C1-1's
executor seam — run item 2 first if both are in flight. Items 1+2 together are
the "fix the Forge runners' fake resume" bottom-line from the inventory; item 3
is a standalone hour.
