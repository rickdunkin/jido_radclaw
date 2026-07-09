# Plan: The pre-argus do-now queue (argus-corpus first waves, merged + recovered)

*A sequenced work queue — not new design. Compiled 2026-07-09 from the three
rollups the argus program left behind — the
[ades combined first wave](../../exploration/ades/README.md) (2026-07-03, updated
2026-07-05), the [pms combined first wave](../../exploration/pms/README.md)
(2026-07-04), and the merged set in
[argus SYNTHESIS §7](../../exploration/argus/SYNTHESIS.md) — plus a four-reader
deep sweep (2026-07-09) over all 17 corpus inventories and the four argus design
docs, which recovered three items the rollups never carried (termic **TM1-2**,
emdash **EM3-3**, the cmux subscription-lane **Lane A**) and two adjacent-corpus
defects the ades digs re-flagged (crabbox **CB1-1**/**CB1-2**). Every item's
status was re-verified against HEAD on 2026-07-09.*

**Selection principle.** Every item is argus-independent *by construction* — the
corpus admission rule was "trigger satisfied by the act of deciding to work, no
argus slice required." Nothing here blocks on, or is wasted by, the argus
program; conversely, several items (the attention read-model, the health
producers, the resume stack) are the substrate argus slice 1/6 later consume.

**Already done — excluded from this queue** (verified in tree + docs):
**PD1-1** (+ the PD2-1 slim `jido://bootstrap` rider) shipped 2026-07-06 inside
next-ten #6, superseding traycer TR1-2a; the four **OH1-3 riders** landed inside
next-ten #5/#6/#9/#10 (2026-07-05 → 07-08). Two partials are noted on their
items: OH1-1's listing-visibility slice and CH1-2a's reply plumbing.

**Queue discipline** (the next-five/next-ten habit): each item ends by
reconciling its source entry — add the dated Status line, correct any claims the
implementation falsified (three stale claims are already flagged inline below),
and update cross-refs the same session. Per-item done-when criteria live in the
six first-wave queue docs where they exist
([MC](../../exploration/pms/multica/MC-FIRST-WAVE.md) ·
[SY](../../exploration/pms/symphony/SY-FIRST-WAVE.md) ·
[CH](../../exploration/pms/chorus/CH-FIRST-WAVE.md) ·
[PD](../../exploration/pms/pad/PD-FIRST-WAVE.md) ·
[OH](../../exploration/pms/openhelm/OH-FIRST-WAVE.md) ·
[OR](../../exploration/pms/orca/OR-FIRST-WAVE.md)); this doc does not duplicate
them — it records sequencing, status corrections, and the sketches for items
that never got a queue doc. File:line refs inherited from the sources
(2026-07-03/04) unless marked re-verified; re-verify at build time.

**Effort legend**: XS ≤ 2h · S ≤ 1 day · M 2–4 days.

| # | Wave | Item | Source | Effort | Shape |
| --- | --- | --- | --- | --- | --- |
| 1 | A | Run-failure taxonomy (retryable ≠ resume-unsafe) | multica MC1-4 (+ OR3-2, BO2-3 riders) | S | One module + two consumers |
| 2 | A | Native CLI session resume for Forge runners | multica MC1-1 (+ 6 digs' riders) | M | Two runners + Session metadata + contract tests |
| 3 | A | Forge transcript resume-honesty (replay flag + loud failure) | emdash EM3-3 | XS | Rides #2's session |
| 4 | A | Exit-code tiering for `mix jidoclaw run` | multica MC3-4 | XS | Extends the pinned OQ-4 contract |
| 5 | B | Cron failure provenance + circuit breaker | OpenHelm OH1-1 | S | Two commits (provenance / breaker) |
| 6 | B | Scheduled provider credential canary | symphony SY1-4 (probe half; closes XA2-3) | S | One cron system job + transition alerts |
| 7 | B | `.jido/config.yaml` fail-closed boot + last-known-good re-read | symphony SY1-3 (near-term half) | S | One `load/1` rework + tests |
| 8 | B | Composer wave inactivity clock (`:stage_stalled`) | symphony SY1-2 (sketch b) | M | Activity source + poll check; ship disabled |
| 9 | C | Attention surface + Forge needs-input reply loop | CCC CC1-2a + chorus CH1-2a | S | Attention view + LiveView affordance |
| 10 | C | Emit the work-done protocol (OSC) from the REPL | termic TM1-1 | S | ~100 lines, emit-side only |
| 11 | C | Prose soft-block detector (`ended_blocked`) | CCC CC1-1 (+ MX3-1, HD2-3 method) | S–M | Rubric port + fixture corpus |
| 12 | C | ManagedDoc for `system_prompt.md` | CCC CC2-2 (+ XA3-1, HD2-5, CM2-4 refs) | S | Marker-owned blocks + refuse-not-clobber |
| 13 | D | Approval TTL/sweeper + hard-block tier | Xantham XA2-1 + XA2-2 (BO2-5 ref) | S | One gate-hardening session, shadow-first |
| 14 | D | Shell-gate `git worktree` mutations | emdash EM2-3 | XS–S | Analyzer effect + require-pattern |
| 15 | D | Forge/security hardening session | crabbox CB1-1 + CB1-2 + termic TM1-2 | S–M | Provenance guard / reaper proof / cage rules |
| 16 | E | Boundary error-code registry (served MCP) | pad PD1-2 | S | Registry + subset test + hint fields |
| 17 | E | `/setup` as a state-derived doctor | pad PD3-1 | S | Per-step live checks + `--check` |
| 18 | E | `mix jidoclaw.api_key` mint/list/revoke | myrlin MY1-4a (+ t3code scopes rider) | S | One mix task + scopes schema room |
| 19 | E | `mix jidoclaw.reproject_steps` | orca OR2-4a | S | Maintenance entry point + fold reuse |
| 20 | E | Non-interactive subprocess env floor | orca OR3-1 | XS | One constant map + merge point |
| 21 | E | Headless-contract prompt fragment + env marker | chorus CH2-5 | XS | One fragment + spawn env + test |
| 22 | F | Subscription-lane hedge: Spike 1 + Lane A | cmux [CM-SUBSCRIPTION-LANE-PLAN](../../exploration/ades/cmux/CM-SUBSCRIPTION-LANE-PLAN.md) | M | Mailbox-mapping spike, then the interactive runner |

**Sequencing.** Wave A's chain is the only load-bearing order in the queue:
**1 → 2 → 4**, with #3 riding #2's session (same files, same honesty theme).
Wave B consumes #1's taxonomy (#5 reuses its classify-before-counting split;
#8's stall reason registers as a taxonomy member), and B's producers (#5's
breaker rows, #6's canary transitions) are the first feeds for #9's attention
read-model — so **A → B → C** is the natural spine. Waves D and E are fully
independent filler — #13 and #15 are each a single self-contained session, and
E's six items are the classic standalone-day/hour set; slot them anywhere,
including interleaved with A–C. Wave F goes **after #2** (Lane A wants the
anchor/resume machinery, and its acceptance criteria are already recorded as
MC1-1 riders). Cross-item rule carried from the queues: #4 and #16
cross-consume — whichever lands second adds the cross-ref. Rough total: three
M items, the rest S/XS — comparable to the next-ten program's weight.

---

## Wave A — execution substrate

### 1. MC1-4 — Run-failure taxonomy (S)

`JidoClaw.Orchestration.RunFailure` beside `Verdict` so infra ≠ verdict ≠
failure stays one vocabulary: a closed enum with platform-vs-agent provenance
in the name, ordered most-specific-first `classify/1`, and `retryable?/1` /
`resume_unsafe?/1` as **independent** derived sets (retry-the-work ≠
reuse-the-conversation). First consumers: Forge runner terminal results, the
composer's Lane-B infra decisions, telemetry with pre-warmed reason labels.
Riders recorded in [MC-FIRST-WAVE item 1](../../exploration/pms/multica/MC-FIRST-WAVE.md):
orca OR3-2 (the `stalled_no_output` vs `stalled_wall_clock` split,
`user_cancelled` as a first-class non-failure, group-kill discipline) and bosun
BO2-3 (the executor-boundary infra-vs-session split). Done-when lives there.

### 2. MC1-1 — Native CLI session resume for Forge runners (M)

Stop re-sending accumulated prompts: capture `session_id` at first stream-json
event (eager anchoring into Session metadata), then `--resume` (claude) /
`thread/resume` (codex). The edge-case list in
[MC-FIRST-WAVE item 2](../../exploration/pms/multica/MC-FIRST-WAVE.md) is the
spec: cwd-gate, clear-and-retry-once, poisoned classification through #1's
`resume_unsafe?/1`, env scrub at spawn, deadlock discipline. Six digs attached
riders — Chorus CH2-6/CH3-2 (anchor-ownership axis + group teardown), symphony
SY3-3 (continuation turns send guidance only), bosun's Codex poisoned-resume
inventory, herdr HD2-2 (14-vendor resume argv table + `session_start_source`
vocabulary), cmux CM2-3 (restore-argv sanitizer: prompts and trust bypasses
never replay) — all recorded in that doc; land them inside this build.

**Status corrections (2026-07-09):** the queue's collision note ("run this
before the executor seam if both in flight") is moot — the seam shipped
2026-07-07 *without* resume, so this retrofits onto the shipped runners and the
seam inherits it. **Scope pin:** executor PR-3 deliberately pinned
fresh-session-per-review-wave with no-resume argv (review independence); this
item must not loosen that pin — resume targets multi-iteration
single-conversation flows (the consolidator, #22's interactive sessions),
never the review re-review waves. First beneficiary: the memory consolidator.

### 3. EM3-3 — Forge transcript resume-honesty (XS, rides #2)

The recovered garnish
([emdash EM3-3](../../exploration/ades/emdash/FEATURES-WORTH-BORROWING.md) —
never rolled up; Tier 3, "one flag + one anti-pattern"): stamp resumed
transcript slices `source: live | replay` (`SubagentTranscript` closes slices
but has no replayed-vs-live marking), and make Forge resume-failure **loud** —
never emdash's silent fresh-session fallback. Same files and same session as
#2; done-when: a resumed run's transcript slices carry the flag, and a failed
resume produces a visible typed event before any fresh-session retry.

### 4. MC3-4 — Exit-code tiering for `mix jidoclaw run` (XS)

**Stale-claim correction (2026-07-09):** the queue doc says the runner "exits
0/1 only" — false at HEAD; `cli/run_command.ex` ships the pinned OQ-4 contract
`0 | 1 | 2 | 3` (success / error / usage-config / gate-pending, with 3 also
carrying `:clarify_pending`). So this item **extends the pinned contract**
rather than adopting multica's 0–5 table verbatim (their 2=network / 3=auth
collide with our taken meanings — new tiers get new codes, e.g. 4 not-found /
5 validation, with network/auth folded where the envelope classes point).
Consume #16's registry rather than re-sniffing envelopes; whichever lands
second adds the cross-ref. Reconcile the MC3-4 entry's claim when this lands.

## Wave B — health & scheduling

### 5. OH1-1 — Cron failure provenance + circuit breaker (S)

Per [OH-FIRST-WAVE item 1](../../exploration/pms/openhelm/OH-FIRST-WAVE.md),
two commits (provenance / breaker): `Cron.Job` gains `consecutive_failures`,
`last_error_class`, `last_failure_at`, `paused_until` (distinct from
`disabled_at`); the worker classifies dispatch results **before** counting
(#1's split — rate-limited and infra never increment); `status` tag on
`cron.job.stop`; first producer for the dormant `:schedule` Trace channel;
threshold trips set `paused_until` + emit an attention row, and Owner reconcile
re-arms expired pauses. **Partial (2026-07-09 re-verified):** the visibility
slice landed 2026-07-06 (`for_tenant_all` + `/cron` disabled-row icons,
pull-only) — the resource still auto-disables off an in-memory counter, so
everything else stands. Open decision at pickup: OQ-3 (columns on `Cron.Job`
vs a per-job health resource).

### 6. SY1-4 (probe half) — Scheduled provider credential canary (S)

Closes ades XA2-3: `Config.check_provider/1` still has exactly two callers
(REPL banner, setup wizard) — schedule it as a leader-owned cron **system job**
(~15 min), **transition-edge-only** alerting (`ok → unreachable`,
`unauthorized → ok`; never per-tick), notifier scheduler-side never
agent-path, durable Trace `:infra`/`:guardrail` + telemetry counter. Becomes a
first producer for #9's read-model. Done-when in
[SY-FIRST-WAVE item 1](../../exploration/pms/symphony/SY-FIRST-WAVE.md).
The optional second cut (symphony's unified-ratelimit probe, ~26-token
`POST /v1/messages` parsing `anthropic-ratelimit-unified-*` headers) becomes
live-relevant the day #22 puts interactive sessions on subscription auth —
note it there, build it then.

### 7. SY1-3 (near-term half) — Config fail-closed boot + last-known-good (S)

Split `Config.load/1`'s silent-`%{}` collapse into three arms: missing file →
defaults (unchanged); present-but-unparseable **at boot** → refuse to start
with the YAML error; present-but-unparseable **at runtime re-read** → serve
last known good (`:persistent_term`) with a loud warning — never silently
degrade a live session to defaults. Deliberately out of scope: content schema
validation (slice-bound) and any file watcher. Done-when in
[SY-FIRST-WAVE item 2](../../exploration/pms/symphony/SY-FIRST-WAVE.md).

### 8. SY1-2 (sketch b) — Composer wave inactivity clock (M)

Distinguish a **wedged** agent from a working one: no *activity* for
`stall_timeout_ms` → cancel the wave child with typed `:stage_stalled`
(inactivity ≠ deadline — distinct from `:observe_timeout`). Activity source is
agent-level liveness (the `[:jido, :ai, :tool, :execute, :*]` stream
AgentTracker already consumes), **not** WorkflowEvent appends (healthy long
steps are legitimately silent). Ship **disabled** (`stall_timeout_ms: 0`);
document beside `wave_timeout_ms`. Register the reason in #1's taxonomy if
landed (a stall is retry-eligible). Done-when in
[SY-FIRST-WAVE item 3](../../exploration/pms/symphony/SY-FIRST-WAVE.md).

## Wave C — attention & reply

### 9. CC1-2a + CH1-2a — Attention surface + needs-input reply loop (S)

The merged "surface the invisible signals + wire the reply" item: an
`Attention` view module (pure reads: pending `AgentCase`s, `:awaiting_approval`
runs, LoopGuard halted keys, failed/tripped cron jobs, Forge `:needs_input`
sessions) surfaced as an `attention_status` MCP tool + dashboard card, folding
in muxara's two sharpenings (a `:failed` Forge session drops off `/forge`
entirely; `/forge` never live-refreshes `:needs_input` transitions) — plus the
reply half per [CH-FIRST-WAVE item 1](../../exploration/pms/chorus/CH-FIRST-WAVE.md):
render the parked question, submit through `Forge.apply_input/2`, typed error
for non-parked sessions, clear the park on termination, bound input size,
replies only via authenticated non-model surfaces. **Partial (2026-07-09
re-verified):** the reply *plumbing* shipped with the executor seam
(`85cbe9f2` gave every runner a real `apply_input` callback) — but there are
still zero operator-surface callers, so the CH done-when stands whole. Build
as a plain LiveView affordance now; argus slice 1 absorbs it later.

### 10. TM1-1 — Emit the work-done protocol from the REPL (S)

The inverted termic trick
([termic TM1-1](../../exploration/ades/termic/FEATURES-WORTH-BORROWING.md)):
our REPL knows its own turn state authoritatively — emit OSC 9 / 9;4 / 133
(+ title) on turn start/end/needs-input so every cockpit (iTerm badges, tmux,
termic itself) tracks JidoClaw for free. ~a hundred lines, emit-side only;
gate on TERM capability claims the way the CLIs do. AGPL discipline: we speak
the public protocol from our own state — no code lift. Done-when: a REPL turn
completing in an OSC-capable terminal produces the notification/badge, pinned
by a capture test.

### 11. CC1-1 — Prose soft-block detector (S–M)

Port CCC's soft-block rubric (MIT) — the "asked a question / awaiting
confirmation" detector producing `ended_blocked` items for #9's feed — with
the rules shipped as **bounded, versioned, fixture-tested data** (herdr
HD2-3's shape, minus the remote update channel) and muxara MX3-1's
fixture-corpus method for the test set. Sequenced after #9 (its consumer).
Sketch in [CCC CC1-1](../../exploration/ades/claude-command-center/FEATURES-WORTH-BORROWING.md).

### 12. CC2-2 — ManagedDoc for `system_prompt.md` (S)

Today `mix jidoclaw.system_prompt.check` requires `.jido/system_prompt.md`
byte-identical to the default — operator customization is impossible and every
default change is a manual copy chore. Adopt the managed-block pattern
(marker-owned surgical edits, **refuse-not-clobber** on missing/mangled
markers): the check verifies managed blocks only, operator text survives
upgrades. References: Xantham XA3-1, herdr HD2-5, cmux CM2-4 (prefer
per-invocation injection where a surface accepts config as flags). Sketch in
[CCC CC2-2](../../exploration/ades/claude-command-center/FEATURES-WORTH-BORROWING.md).

## Wave D — gates & security

### 13. XA2-1 + XA2-2 — Approval TTL/sweeper + hard-block tier (S, one session)

Two queue-independent gate hardenings
([Xantham](../../exploration/ades/Xantham-system-blueprint/FEATURES-WORTH-BORROWING.md)),
three-subject convergence (Xantham, bosun BO2-5 — the reference
implementation: expiry + reconcilers — and OpenHelm shipping the same
never-expire gap): **XA2-1** — unconsumed `AgentCase` approvals never age out;
add `expires_at` + a sweeper (PR-4's `needs_input` answers already carry a 24h
claim TTL — generalize the precedent to the approval family). **XA2-2** — a
hard-block never-grantable tier: today everything dangerous is approvable;
some command classes should refuse without a gate. Both live in
`ToolApproval`/`ShellCommand`/`AgentCase`. Roll out **shadow-first** per
termic TM2-3 (log would-have-blocked before enforcing).

### 14. EM2-3 — Shell-gate `git worktree` mutations (XS–S)

Close the live gap in `run_command` before any worktree feature exists: the
shell analyzer (`security/shell_command/git.ex`) + `@require_patterns` gain
worktree-mutation coverage (add/remove/prune/move mutate repo state and
filesystem outside the jail's mental model). Prerequisite for the
preview-worktree line (termic TM1-3/TM2-4); independently validated by CCC's
delegate-teardown anti-pattern and Xantham's own gate. Sketch in
[emdash EM2-3](../../exploration/ades/emdash/FEATURES-WORTH-BORROWING.md).

### 15. CB1-1 + CB1-2 + TM1-2 — Forge/security hardening session (S–M)

The recovered security cluster — the ades digs deliberately parked it outside
the argus rollup as "Forge/security territory, threat-model center," and both
crabbox defects re-verified live at HEAD 2026-07-09:

- **(a) CB1-1 — credential-destination provenance guard**
  ([crabbox](../../exploration/sandboxes/crabbox/FEATURES-WORTH-BORROWING.md)): the live
  exploit shape — `Shell.ServerRegistry` reads an SSH password from the host
  env named by `password_env` and hands it to an `entry.host` loaded from
  agent-writable `.jido/config.yaml`; an LLM that edits the config redirects
  the secret. Tag config-sourced values with origin trust; refuse
  *destination-from-agent-writable-config* × *secret-from-higher-trust-source*
  fail-closed with an approvable error riding the `ToolApproval` seam. MCP
  `endpoint_config` env-override path as the follow-up (OQ-1 scope decision at
  pickup).
- **(b) CB1-2 — ownership proof before the reaper destroys**: both reap paths
  (`Forge.SandboxInit.do_cleanup_orphaned_sandboxes` on `sbx ls` names, and
  `reap_orphaned_workspace_dirs` on `/tmp/jidoclaw_forge/forge-*` dirs holding
  live `.forge_env` secrets, re-verified `sandbox_init.ex:180-183`) key on
  name-prefix alone — two instances sharing a Docker host reap each other
  mid-run, and clustering shipping raises the stakes. Stamp an owner token at
  create (instance ID in the name, or an `sbx` label) and reap only what's
  provably ours; Xantham XA3-3's never-kill-live-work rules are the acceptance
  criteria. OQ-2 (token grain) at pickup.
- **(c) TM1-2 — the cage trust rules**
  ([termic](../../exploration/ades/termic/FEATURES-WORTH-BORROWING.md), AGPL
  patterns-only): first step is the named do-now — **audit what env Forge
  HostShell's OsCmd ports actually inherit** (the dig never audited it); then
  the rc-delta withholding rule for caged spawns, cage-gating config resolved
  from outside the agent's write reach (the CB1-1 guard is that rule's
  enforcement for the SSH case), and the per-agent credential-dir isolation
  doctrine line — partially realized already on the executor vendor arm
  (PR-2's per-run `CLAUDE_CONFIG_DIR`); the doctrine + consolidator-runner
  parity remain.

## Wave E — contract, surface & enrollment

### 16. PD1-2 — Boundary error-code registry (S)

Camus C1-3's posture applied to the tool surface: enumerate the served-surface
code families in one module (~25 atoms), a subset test asserting emitted codes
⊆ registry (a new code joins in the same diff as its docs), a stability
sentence in served tool descriptions, and typed hint fields (`expected`/`got`,
`available`) generalizing the LoopGuard-directive precedent. Served MCP only —
no global internal enum. Done-when in
[PD-FIRST-WAVE item 2](../../exploration/pms/pad/PD-FIRST-WAVE.md). #4
consumes this registry.

### 17. PD3-1 — `/setup` as a state-derived doctor (S)

Re-running setup today replaces `config.yaml` wholesale. Rework to per-step
live checks (config present, provider key valid via `Config.check_provider/1`
— giving #6's probe a manual surface — voyage key, model reachable, DB
migrated), act-only-on-gaps, and a `--check` mode that prints the derivation
and changes nothing. Done-when in
[PD-FIRST-WAVE item 3](../../exploration/pms/pad/PD-FIRST-WAVE.md).

### 18. MY1-4a — `mix jidoclaw.api_key` mint/list/revoke (S)

`Accounts.ApiKey` has zero minting paths. One mix task; put **`scopes` schema
room on the key at mint time** (the t3code TC1-2 rider — enforce with the
first scoped surface, not now). The QR-enrollment ladder stays argus-bound;
cmux CM2-2's rule rides that later work (the QR carries addressing + an
account-binding check, never anything that authorizes). Source:
[myrlin MY1-4](../../exploration/pms/myrlin-workbook/FEATURES-WORTH-BORROWING.md).

### 19. OR2-4a — `mix jidoclaw.reproject_steps` (S)

Make `allocate.ex`'s moduledoc claim true: a maintenance entry point that
reads a run's `step_*` events in seq order and re-applies the existing
idempotent upserts. Tenant-scoped, read-the-log-only, no status writes.
Done-when in [OR-FIRST-WAVE item 1](../../exploration/pms/orca/OR-FIRST-WAVE.md):
hand-corrupted rows reproject byte-equal; healthy runs no-op; moduledoc cites
the command.

### 20. OR3-1 — Non-interactive subprocess env floor (XS)

One constant map (`CI=true`, `GIT_TERMINAL_PROMPT=0`, `GIT_ASKPASS=""`,
`PIP_NO_INPUT=1`, …) merged at the `scrubbed_cmd_env/1` / `scrubbed_port_env/1`
seams — after scrub, caller wins — for Forge runner/bootstrap/init children,
never interactive shells. Scrub = leakage hygiene; floor = liveness hygiene.
Done-when in [OR-FIRST-WAVE item 2](../../exploration/pms/orca/OR-FIRST-WAVE.md).

### 21. CH2-5 — Headless-contract prompt fragment + env marker (XS)

**Recovered** — present in
[CH-FIRST-WAVE item 2](../../exploration/pms/chorus/CH-FIRST-WAVE.md) but
dropped from the SYNTHESIS §7 merge; nothing in the shipped vendor prompts
covers it (re-verified 2026-07-09). One shared fragment in Forge runner prompt
assembly: no human at the terminal; route human-decision points through the
platform's async channels — which now has a *real* channel, PR-4's
`needs_input` answer loop; and set `JIDOCLAW_HEADLESS=1` at spawn (rides #2's
env-scrub site when that lands).

## Wave F — the approved hedge build

### 22. CM subscription lane — Spike 1 + Lane A (M)

**Operator go-ahead 2026-07-09** (the plan's soft trigger, now fired; the plan
doc's PROPOSED status flipped the same day). Per
[CM-SUBSCRIPTION-LANE-PLAN](../../exploration/ades/cmux/CM-SUBSCRIPTION-LANE-PLAN.md):

1. **Spike 1 — map the teams mailbox** (~half a day, observation-only, no
   product code): fs-watch `~/.claude` during a real teams session, enumerate
   the teammate env delta, probe fabricated-team enrollment. Deliverable: a
   protocol note beside the plan converting its [hypothesis] into pinned fact
   or killing Lane B.
2. **Spike 2 — Lane A end-to-end**, the contingency floor ("worth building
   even if the mailbox never pans out and even if `-p` never dies"): the
   `{:forge, :claude_code}` **interactive** variant hosted on the executor
   seam — PTY-as-pacifier in both sandbox backends (`docker exec -t` /
   `script -q`-class), turn state via per-invocation `--settings` hook
   injection to a loopback endpoint (the PR-2 deposit-endpoint precedent),
   transcript-JSONL reads at turn boundaries (never scraping), restore via
   interactive `--resume` under CM2-3's sanitizer rules. Done-when (from the
   plan, verbatim): a composer stage runs green driven through an interactive
   session with zero `-p` on the path, turn state engine-observed via hooks,
   restore proven under the sanitizer rules.
3. **Decision gate**: A-only vs A+B1/B3, recorded as a dated note in the plan
   doc; the chosen lane's acceptance criteria fold into #2 and executor PR-3
   as riders — one resume/driving stack, never two.

Risks held per the plan (§6): interactive-rides-subscription is itself a
monitored assumption; a session fleet makes #6's ratelimit second cut and
myrlin MY1-1's credential lineage live design inputs.

---

## Recorded, not queued

- **EM2-4(b)** — retrofit a `"v"` version field onto the compaction-snapshot
  jsonb **at its next touch** (opportunistic edit, not a work item).
- **herdr HD1-3** — the `AgentView` `:idle` split (completed-unacked vs idle)
  fixes today's web card but rides emdash EM2-1's attention fold, which is
  argus-slice-bound; it waits there as a projection shape, not a queue item.
- **`PullRequestCoordinator` stub** (`submit_pr` fabricates a URL; nothing
  subscribes to `"github:webhooks"`) — genuinely dead today, but all three
  argus docs assign it to **slice 4** ("builds the path real rather than
  wiring up the stub"); pre-argus work there would be discarded. Deliberate
  non-item.
- **Doc-consistency fixes** shipped with the commit that adds this queue: the
  pms README's "two inline items" overcount, `WorkflowLease`'s stale
  `@doc`/OVERVIEW-appendix `Node.self()` references, the hermes inventory's
  stale our-side Telegram-adapter claims, and the CM plan's status flip.

## Collision notes

None with active plans — next-five and next-ten are complete. #2/#3/#22 touch
the Forge runner files the executor seam just stabilized (coordinate if any
seam follow-up opens). #9 touches ForgeLive additively. #15 touches
`ServerRegistry`/`ToolApproval`/`SandboxInit` — disjoint from everything else
here except #13's `ToolApproval` neighborhood (sequence those two in one
sitting if both are in flight). #5/#6 both touch cron scheduling; pairing them
is natural but not required.
