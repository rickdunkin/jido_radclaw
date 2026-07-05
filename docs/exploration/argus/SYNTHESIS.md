# Argus — Corpus Synthesis (ades + pms)

**Status**: synthesis pass, 2026-07-05 — written after both research corpora closed.
Sources: the [ades corpus](../ades/README.md) (agent control-plane cockpits — six
subjects, all six dug 2026-07-03, plus a same-day connective pass) and the
[pms corpus](../pms/README.md) (agent-era project management — nine subjects, eight
digs, all 2026-07-04, plus its connective pass), stitched together by the 2026-07-05
cross-corpus pass ([DIG-BRIEFS](../pms/DIG-BRIEFS.md) "After the digs", motion 1).
This document rolls the research up **by argus concern** rather than by repo: what
the field validated, what it corrected, the composite artifacts no single subject
had, the pre-argus work queue, and the open-question register — one page to start
the build from.

## How to read this document

This is a read-model over the corpora, **not a third decision surface**. Decisions
live in [OVERVIEW.md](OVERVIEW.md) (architecture) and [FLOW.md](FLOW.md) (product
layer; newest where they disagree), and both already carry the corpus citations
inline at each decision point. Come here to see the research whole; follow the IDs
(`TR1-2`, `MC1-4`, …) into the fifteen per-repo `FEATURES-WORTH-BORROWING.md`
inventories — they resolve via the two corpus READMEs — for file:line evidence on
both sides. Claims below are dig-verified unless explicitly flagged "per scan".

---

## 1. The corpora in numbers

Fifteen subjects, fourteen digs (symphony + OpenSymphony were one joint read), no
planned reads left open — every "no dig" / "pattern notes only" verdict was
eventually upgraded or reversed, three on operator request (Xantham, muxara,
OpenHelm). The two theses are complementary: **ades** subjects are session cockpits
("one surface for many parallel coding agents" — watching terminals), **pms**
subjects are PM-forward (a board, tracker, or pipeline is the product's center of
gravity, and agents attach to *it*). That split is why the composites in §5 layer
instead of competing: the cockpits owned attention and status, the PM products owned
assignment, gates, and delivery.

Verification discipline paid: the six ades digs corrected **20** scan claims between
them; the four pms digs that tallied count **26** more (multica 6, orca 6, pad 5,
bosun 9), with the untallied digs correcting further. Two pms subjects (symphony,
OpenSymphony) are our own stack — Phoenix/LiveView/GenServer.

The cast, one line each (the READMEs' tables hold the detail):

- [**traycer**](../ades/traycer/FEATURES-WORTH-BORROWING.md) — contract-layer
  comparable: the versioned-RPC skew machinery (TR1-1/TR1-2), worktree schema cribs
  (TR1-3/TR1-4), phased busy-checked teardown (TR2-1).
- [**emdash**](../ades/emdash/FEATURES-WORTH-BORROWING.md) — worktree provisioning
  *practice* (EM1-1/-2), the shipped two-trigger notification set (EM1-3), the
  costed minimal ACP surface (EM1-4).
- [**termic**](../ades/termic/FEATURES-WORTH-BORROWING.md) — the emit-side
  work-done protocol (TM1-1), sandbox cage trust rules (TM1-2), the Spotlight
  preview-worktree spec (TM1-3). AGPL: patterns only.
- [**claude-command-center**](../ades/claude-command-center/FEATURES-WORTH-BORROWING.md)
  — the attention-feed read-model (CC1-2) + prose soft-block rubric (CC1-1); the
  mtime-409 half-precedent (CC1-3); the corpus's sharpest trust negative reference
  (CC2-4).
- [**muxara**](../ades/muxara/FEATURES-WORTH-BORROWING.md) — the single-agent
  status contract (MX1-1); the in-code sort-churn counterexample (MX2-1).
- [**Xantham**](../ades/Xantham-system-blueprint/FEATURES-WORTH-BORROWING.md) — the
  model-inside-the-approval-TCB anti-reference (XA1-1); the
  infra-alerts-never-ride-the-agent-path rule (XA1-2); three our-side gaps exposed
  by contrast (XA2-1/-2/-3).
- [**multica**](../pms/multica/FEATURES-WORTH-BORROWING.md) — strongest
  whole-product comparable (server Postgres + multi-device clients +
  worktree-per-task + agents-as-assignees): the CLI session-resume stack (MC1-1),
  task-schema field reference (MC1-2), the 21-reason run-failure taxonomy (MC1-4).
  Modified Apache: read the clause before lifting.
- [**Chorus**](../pms/chorus/FEATURES-WORTH-BORROWING.md) — plan-layer
  promote-the-edit #1 (CH1-1); the boundary-delivery steering answer (CH1-2);
  pinned-wake degradation ladder (CH1-3); instance identity/liveness split (CH1-4).
  AGPL: patterns only.
- [**symphony / OpenSymphony**](../pms/symphony/FEATURES-WORTH-BORROWING.md) — our
  stack, inverse philosophy (unattended by design): the Codex app-server client
  (SY1-1), dispatch hygiene (SY1-2), validated-config contract (SY1-3),
  account-health rotation + the shipped credential probe (SY1-4), the teardown PR
  sweep (SY2-4).
- [**orca**](../pms/orca/FEATURES-WORTH-BORROWING.md) — sharpest pattern-per-line
  donor: the review-verdict schema (OR1-1), catch-up staleness model (OR1-2),
  queue-then-release dependencies (OR1-3), toolchain-init table (OR1-4); plan-layer
  promote-the-edit #2.
- [**bosun**](../pms/bosun/FEATURES-WORTH-BORROWING.md) — feature-superset
  comparable and the most instructive wreck survey: the corpus's only shipped
  auto-resume (BO1-1), anomaly taxonomy + off-process sentinel (BO1-2), richest
  phone delivery shapes (BO1-3), the deleted-in-production two-way-sync
  counterexample (BO1-4), the field's one mid-turn steer (BO2-4).
- [**pad**](../pms/pad/FEATURES-WORTH-BORROWING.md) — the complement, not a
  competitor (external agents drive *it*): surface-versioning discipline + its rot
  lesson (PD1-1), the boundary error contract (PD1-2), task-schema garnishes
  (PD1-3), the import-copy seam validated (PD1-4). Contains no LLM code at all.
- [**myrlin-workbook**](../pms/myrlin-workbook/FEATURES-WORTH-BORROWING.md) — the
  ades↔pms bridge (a cockpit that grew a board): the credential lineage guard
  (MY1-1), conflict-detector shapes (MY1-2), storm-tested device delivery rules
  (MY1-3), the QR enrollment ladder (MY1-4); plan-layer promote-the-edit #3,
  severed from execution (MY2-1). AGPL: patterns only.
- [**OpenHelm**](../pms/openhelm/FEATURES-WORTH-BORROWING.md) — adjacent domain
  (business-automation fleet ops): the layered cron-health breaker family (OH1-1),
  the autonomy-dial approval stack (OH1-2), storm attention mechanics (OH2-2).
  BUSL: patterns only.

**License discipline** for anything beyond ideas: patterns/rubrics/schemas only
from termic, Chorus, myrlin-workbook (AGPL-3.0), OpenHelm (BUSL-1.1), and multica
(modified Apache with a commercial clause); the rest are MIT/Apache-clean.

---

## 2. The headline — the edit-and-resume sweep closed

The standing question asked of every subject — *does anyone already have
edit-the-step-output-and-resume?* — is answered. **At the execution layer: no,
nowhere.** All fifteen subjects across both corpora verified empty — pad in the
strongest form (it contains no LLM integration at all), muxara trivially (no input
channel to an agent exists) — closing the program-wide sweep at **subject 24** (the
counter predates these corpora; earlier exploration subjects fill the gap).

What pms found that ades could not: the **plan-layer** variant exists — exactly
three times, and all three **promote the operator's edit verbatim**, the model
never re-invoked:

1. **Chorus** — the proposal editor: human edits write into the same draft JSON the
   AI authored (including the task DAG); approve materializes those bytes
   ([CH1-1](../pms/chorus/FEATURES-WORTH-BORROWING.md)). Reject-with-note is the
   separate re-prompt lane.
2. **orca** — the briefing Accept path: `apply_edits_to_draft` merges operator
   edits into the materialized plan/tasks; Refine is the re-prompt lane; pushback
   never promotes ([orca dig](../pms/orca/FEATURES-WORTH-BORROWING.md)).
3. **myrlin-workbook** — the spinoff spec editor promotes verbatim, **but into a
   record no agent consumes**: the promoted spec never reaches the spawned agent
   ([MY2-1](../pms/myrlin-workbook/FEATURES-WORTH-BORROWING.md)).

Consequences for argus §5:

- The novelty claim narrows honestly: **execution-layer head-promotion** — the
  edited output *is* what the next step consumes — remains unique in a 24-subject
  field.
- The first editor is externally confirmed three times over: a **markdown/plan
  editor at a pre-execution gate** is the industry-validated entry point — exactly
  OVERVIEW §7 step 4's markdown-first sequencing, and FLOW §10 ships it as the
  PR-metadata landing gate.
- MY2-1's severed promotion supplies the acceptance criterion the other precedents
  can't: prove end-to-end that the resumed step consumes the head revision's
  **bytes** at its input, not merely that a revision row was stored.

During execution the field converges on **steering, not editing**: boundary
delivery (Chorus's "instruction injection" is a durable pending turn serialized
behind the in-flight subprocess — CH1-2; multica resumes sessions from comments;
orca re-runs a phase with authoritative notes), with exactly one shipped mid-turn
exception — bosun's Claude lane via the vendor-SDK streaming-input channel (BO2-4).
Two teams looked at richer in-run intervention and backed off: symphony's
comment-resume revert (#84→#85 — recorded as withdrawal, no technical why) and
orca's read-only-review-by-design doctrine.

---

## 3. Argus decisions the field corroborates

Each of these is already recorded in OVERVIEW/FLOW; this is the evidence roll-up.

1. **The differentiators survive both corpora** (OVERVIEW §2). Zero of six ades
   subjects had any of them; pms narrows the gap — five of nine ship a second
   device, two run real server Postgres — but confirms it: none has multi-node
   clustering with node-affine execution (every daemon is a spoke to one hub), a
   durable event-feed catch-up contract, an agent-unmintable decision object, or
   execution-layer edit-and-resume (pms observation 5). See §6.
2. **Worktree-per-task** (OVERVIEW §3.1). Unanimous in ades (6/6, counting CCC's
   spawn-time creation); five of nine in pms, with the exceptions paying visibly —
   OpenHelm's shared project dir forced a **global concurrency cap of 1**, and
   upstream symphony's per-issue shallow clones were replaced by worktrees in its
   fork (a clean isolated datapoint that worktrees win on cost at volume). The
   ownership spectrum's lesson: every step away from orchestrator-owned worktree
   ops cost something observable (ades observation 1).
3. **Nothing-migrates** (FLOW §1–2). multica's pinned placement validates it
   independently; Chorus is the second validation — origin-gone sessions go
   read-only, never rerouted, with one explicit cold re-point — and CH1-3 adds the
   hard/soft pin degradation ladder FLOW §12's wake resolution adopted.
4. **The task layer** (FLOW §7). Posed by pms observation 6, decided affirmatively
   2026-07-04. The binding direction is field-consistent: task = durable identity,
   worktree/session = execution residue. MC1-2 is the schema pressure-test
   reference; PD1-3, MY2-2, and BO1-4 the checklist set; two-way GitHub sync is
   rejected with a production counterexample (bosun's sync engine was *deleted in
   production*, BO1-4).
5. **Async, comment-like HITL** (FLOW §12; the §5 gate UX). pms observation 2: the
   field routes control through PM artifacts (ticket states as gates, comments as
   resume triggers, proposals as approval objects) and unanimously validates
   async, conversational, phone-answerable HITL over modal blocking. The argus gate
   UX should feel like answering a comment, not clearing a dialog.
6. **Grants never ride model-mediated channels** (OVERVIEW §4.4; FLOW §3 trust
   posture). Two negative references (XA1-1's model-inside-the-TCB approval loop;
   CC2-4's CSRF-is-not-auth) plus field-wide yolo defaults (multica hardcodes
   `bypassPermissions` with no gate anywhere; Chorus's daemon defaults
   `--dangerously-skip-permissions`) make the structural-gate posture a
   differentiator, not table stakes.
7. **The import-copy workflow seam** (FLOW §13 open item 1). pad ships the
   candidate nearly clause by clause — compiled-in read-only library, activate =
   import-copy, snapshots frozen at creation, drift closed by explicit re-import —
   and supplies the negative result for the main alternative (its auto-upgrade
   backfill was built, hurt intentional divergence, and was removed — PD1-4).
8. **Immutable-append workflow versions** (FLOW §9). pad's mutable-in-place
   playbooks are safe only because nothing executes them: version what engines
   consume.
9. **Cron overlap skip-and-record + circuit breaker** (FLOW §8). Independently
   validated four ways: multica's visible skip + auto-pause, myrlin's third
   confirmation (MY2-6), symphony's reconcile/backoff/stall checklist (SY1-2),
   OpenHelm's persisted breaker with bounded auto-recovery (OH1-1 — the ~9-hour
   fleet-pause lesson).
10. **Event-sourcing + single-writer leases**. The first architectural peers in
    either corpus (bosun, orca) both diverge instructively: bosun's auto-resume
    reads an atomic snapshot store, *not* its event ledger, and orca's
    correlation/causation columns are dead — our projection-owned status and
    event-append spine hold up well by comparison.
11. **Badges, not reordering** (the agent-list UX). Settled with prejudice: emdash
    never sorted, CCC shipped float-to-top and retracted it as churn, termic is
    badges-only, and muxara — the only shipping sorter — demonstrates the
    selection-drift defect in code (MX2-1).

---

## 4. What the research corrected

### 4.1 In the argus design docs

- **TR2-3** — the §5.4 sketch's "the event append is the CAS" was wrong: the append
  is *pessimistic* (`FOR UPDATE` + max+1 under the lock). `expectedSeq` is small
  net-new machinery checked under the existing lock, returning a typed
  `stale_revision` error carrying the current seq.
- **CC1-3** — the "CCC mtime-409 flow" cited as precedent is a **half-precedent**:
  the server contract is real, but the client recovery flow was never built (a
  conflict dead-ends and loses the operator's edits). Recovery UX moved from
  citation to acceptance criteria (§5.2).
- **The novelty claim narrowed** — from "nobody has edit-and-resume" to
  "execution-layer head-promotion is unique" (§2).
- **`fileConflicts` (OVERVIEW §6.2 / FLOW §12)** — trigger kept, citation
  corrected: the product that named it ships the push as dead code; the borrowable
  half is MY1-2's two detector shapes, and for us the transcript-derived detector
  is a query over durable tool-call rows, not a scrape.
- **Xantham/Chorus "boundary delivery, never mid-turn"** — softened to "with one
  vendor-SDK-mediated exception" once the bosun dig found BO2-4.
- **`PullRequestCoordinator` as existing plumbing** (FLOW §4/§10) — the HMAC
  ingress is real; the coordinator is unwired scaffolding (nothing subscribes to
  its PubSub topic; `submit_pr` fabricates a URL). Slice 4 builds the path real.

### 4.2 In our own tree (the wiring-mortality census, applied at home)

The pms census (observation 13) found dead code paths in all eight digs — and the
same lens turned on jido_radclaw found:

- The MCP server advertises a hardcoded **`0.2.0` on an `0.6.4` app** — pad's rot
  law live in our tree (PD1-1's do-now PR kills it).
- The step-projection moduledoc claims "repairable by replaying" with **no
  implementation** (OR2-4a → `mix jidoclaw.reproject_steps`).
- **`Forge.apply_input/2` has zero callers** — surfacing `:needs_input` without the
  reply half would show operators a park nobody can answer (CH-FIRST-WAVE item 1).
- **Cron failures are invisible**: in-memory failure counter, auto-disable hides
  the row from `:for_tenant` listings, status-blind telemetry, and the `:schedule`
  Trace channel has no producer (OH1-1's our-side slice).
- **`Accounts.ApiKey` has zero minting paths** (MY1-4a → `mix jidoclaw.api_key`).
- **Unconsumed approvals never expire** (XA2-1 — now a three-subject convergence:
  Xantham, OpenHelm, bosun; BO2-5 is the reference implementation) and **no
  hard-block never-grantable tier** exists (XA2-2).
- The **credential canary** exists but nothing schedules it — `check_provider/1`
  with no caller on a schedule (XA2-3 → SY-FIRST-WAVE item 1).

---

## 5. The composites — what only the corpus view shows

Each of these was assembled across subjects at a connective pass; no single dig saw
its whole shape. They are the research's most valuable artifacts.

### 5.1 The attention & delivery stack (five layers)

No subject has more than one layer; argus adopts the stack (FLOW §12):

1. **Per-agent status contract** — MX1-1: small closed enum, sub-typed
   needs-input, modes as orthogonal modifiers, honest `unknown`,
   raise-fast/clear-slow damping.
2. **Cross-agent fold + seen-flag** — EM2-1.
3. **Attention-feed read-model** — CC1-2: kinds, priority (doubling as the
   per-severity mute knob), suppression, git-stranded-work items, the
   produce/decide split — plus the layer no formal event system sees on any
   substrate, ours included: the prose soft-block rubric and `ended_blocked`
   (CC1-1).
4. **Delivery policy** (the pms layer): aggregation — BO1-3 (immediate-vs-digest
   split, a live digest edited in place, the pinned status board); storm semantics
   — OH2-2 (caller-supplied semantic dedup keys, touch-in-place priority
   escalation, 16-failing-jobs→one-incident collapse, the never-vanish fallback
   row, additive email at approval-or-priority≥80); device-side rules — MY1-3
   (replay suppression on reconnect, focus-acknowledgement consumes pending state,
   minimum-signal re-arm, per-device batch-coalescing, prune-on-provider-
   rejection); recipient model — CH2-3 (per-kind mutes, wake ≠ read, notifications
   as a projection over the activity stream).
5. **Triggers** — answered six times over, convergently: agent-finished +
   blocked-on-you (EM1-3, TM2-5 — independently re-derived by MY2-4);
   `ended_blocked` (CC1-1 + XA1-2); run-failed *included* (settled: this control
   plane's operator has left the desk); infra-degraded (XA2-3 canary, the
   watchdogs); `fileConflicts` (MY1-2's detector shapes).

Architecture rules: the notifier is the gateway layer subscribed to PubSub, never
agent behavior (XA1-2 — shipped twice as a *process*: bosun's off-process sentinel,
OpenHelm's heartbeat watchdog); the ask may ride any channel, the grant only enters
through authenticated non-model surfaces (XA1-1).

Negative space that completes it: multica's severity theater (three levels
declared, ~two live, no UI consumes severity), pad's
no-notification-model-at-all (attention as a capped *computed* array — confirming
the computed-feed shape from the null side), and myrlin's five-declared/two-live
pushes — yielding the **named-tested-producer law**: every trigger argus declares
must have a named, tested producer.

List UX: badges on stable order, one hoisted bucket, selection bound to identity
(§3 item 11).

### 5.2 The gate acceptance-criteria checklist (argus §5.4)

Eight axes; each has a shipped failure or a corrected sketch behind it:

1. **Approve fence** — Chorus and orca both double-materialize on double-approve;
   multica ships no human approve path at all. Ours exists (FOR-UPDATE + single-use
   `:consume`): the criterion is *keep it*.
2. **Revision history** — Chorus keeps one overwritten `reviewNote`; ours is the
   event log + ref-store, by design.
3. **Restart durability** — bosun's approved gates re-open to pending after a
   restart (requests durable, waiters in memory).
4. **Expiry** — three-subject convergence on XA2-1; BO2-5 (TTL + reconcilers) is
   the reference implementation.
5. **Timeout direction** — bosun defaults `onTimeout:"proceed"` (timeout =
   auto-approve): the corpus's sharpest argument for the inverted house rule — a
   gate timeout only ever fails closed.
6. **Severed-consumer test** — MY2-1: prove the resumed step consumes the head
   revision's bytes at its input.
7. **Concurrency mechanics** — TR2-3: `expectedSeq` compares under the existing
   FOR-UPDATE allocation lock; mismatch returns typed `stale_revision` carrying the
   current seq.
8. **Conflict-recovery UX** — CC1-3: the client keeps the operator's buffer across
   the refetch; an absent `expectedSeq` is a validation error, never
   last-write-wins; machine rewrites ride the same check.

Rider: the **decided-after-death** question (OH OQ-2) — OpenHelm's approve executes
the stored payload platform-side after the run ended; our consume semantics assume
a live agent loop re-issues. Owed an answer per gate kind when phone approvals land.

### 5.3 Worktree lifecycle — provisioning references and the teardown law

**Provisioning** (FLOW §5): TR1-3/TR1-4 (a six-state `setup_status` distinct from
lifecycle status; `origin: created | imported`; computed-never-persisted
disk-truth; clone-not-migrate node affinity) + EM1-1/-2 (preservePatterns with
safety rules; idempotent compiled setup steps) + OR1-4 (toolchain-init table,
init-status split, hard-stop/retry/recorded-skip) + MY2-3 (third init-hooks
precedent; reconcile-don't-fail collision posture recorded as contrast to our
`-{n}` counter) + BO2-1 (shared-path symlink install-avoidance as per-project
policy). Secrets materialize from the Vault at setup; MY1-1's OAuth refresh-token
lineage guard + SY1-4 are the credential-sync references.

**Teardown**: the merged spectrum runs from orca (force-deletes worktree *and
branch* — rejected work unrecoverable) and myrlin (record-delete strands both, the
paired opposite failure) up through CCC's delegate-to-agent anti-pattern, termic's
bare-confirm force, bosun's middle, multica's GC taxonomy, muxara's dirty-check
hard block, and traycer's phased busy-checked delete — with SY2-4 contributing the
only PR-side sweep in either corpus. The composite law FLOW §5 adopts: **phased +
dirty-checked (TR2-1/MX2-2) + PR-aware (SY2-4) + a records↔worktrees reconciliation
sweep** — and deletion is never delegated to an agent (CC2-3). Our-side
prerequisite: EM2-3, shell-gating `git worktree` mutations.

### 5.4 The health shelf

**Classify before counting**: MC1-4's 21-reason run-failure taxonomy (with
retryable / resume-unsafe subsets), BO2-3's infra-vs-session split, OpenHelm's
transient ≠ rate-limit ≠ infra rule ("a rate-limited job is not a failing job"),
MY1-1's transients-never-mark-dead — four subjects converging on the law our
shipped Verdict normalizer (camus C1-3) states in-house. **Then break**: persisted
consecutive-failure breakers with bounded auto-recovery (OH1-1's 9-hour-pause
lesson; multica's fail-ratio auto-pause; myrlin's crash-loop latch). **Then watch
the watcher**: off-process, so a dead agent loop can still page (bosun's sentinel
process; OpenHelm's heartbeat watchdog — XA1-2 shipped twice, independently). And
**rate-limit as a first-class schedulable state**: SY1-4's six-state account health
with the shipped reset-header probe; OpenHelm's defer-all-runs-to-reset. FLOW §8's
checklist membership: MC2-5 + SY1-2 + MY2-6 + OH2-1, with MC1-4 the taxonomy seam
they all classify into.

### 5.5 The wiring-mortality laws

Every one of the fourteen digs found dead *code paths*, not just stale docs (ades
observation 8 → pms observation 13; ≥46 corrections across the corpora). Two laws,
now written into the argus plans:

- **(a) Advertisement without mechanical enforcement rots** — PD1-1 (pad's own
  handshake instructions lag its surface by three versions), re-proven the same day
  by myrlin's pairing endpoint (shipped broken; the asserting test exists and
  doesn't gate releases), and live in our own tree (§4.2).
- **(b) A dependency edge survives only if a scheduler consumes it** — the census:
  four dead (multica's `issue_dependency`, bosun's `blockedByTaskIds`, pad's
  `blocks`, myrlin's `blockedBy`) against two live (orca's queue-then-release,
  multica's stage barriers), with Chorus in between (edges materialize and render;
  nothing schedules off them). The design rule for FLOW §7's `depends_on`: ship the
  release semantics with them or not at all.

Corollary (§5.1): every declared notification trigger needs a named, tested
producer.

### 5.6 The CLI-engine reference stack (FLOW §4 `:cli`, slice 6)

Headless CLI + stream-json + resume-by-session-id is the de facto driving standard
(pms observation 4); the seam belongs behind a small adapter behaviour. The merged
stack, in our language: SY1-1 (the Codex app-server JSON-RPC client) + MC1-1
(resume mechanics: server-persisted session id, exact-name env scrub,
clear-id-then-retry-fresh) + orca's gotcha list (Claude plan-mode deadlocks against
closed stdin; the auditor clamp on `bypassPermissions` *and* `plan`;
fresh-spawn-per-phase as the honest no-resume alternative) + OpenHelm's detached
process-group spawn + SY2-3 (single-source multi-CLI tool/config generation, strict
mcp-config pinning) + Chorus's interrupt taxonomy (`user`/`crash` provenance gating
resume) + OH2-3/OH2-5 (structural scheduler deny-list; MCP preflight with
min-tool-count gates) + BO2-4 (the agent-SDK streaming-input mode, on the reading
list as the one mid-turn precedent). Approval frames map to the `AgentCase` inbox —
where symphony auto-answers and Chorus auto-denies, we gate.

### 5.7 Placement & node identity (OVERVIEW §2.5/§3.3, FLOW §2)

Chorus's pinned-wake model — route the wake to exactly the instance that owns the
context — is the closest external design to our claim-on-`worktree.node` placement,
with CH1-3's degradation ladder (hard pin offline ⇒ notify-only; soft pin ⇒ visible
online-first fallback) and CH1-4's identity/liveness split (generation fencing,
registration conflict-refusal) feeding OVERVIEW §3.3's node columns. multica's
daemon runtimes (heartbeats, capability profiles) are the node-health-surfacing
reference. symphony's SSH workers are recorded contrast — **SKIP as mechanism**
(Erlang distribution is our fabric); their count-based least-loaded selection with
a sticky retry host is the noted datapoint.

### 5.8 Surface versioning & skew (OVERVIEW §6.3 → slice 1)

traycer owns the **negotiation** half — per-method `{major,minor}` manifests at
connect, a pure compatibility oracle, newer-side-owns-transforms, additive-minor
invariants, a CI-frozen released-surface golden born from two real skew incidents
(TR1-1/TR1-2) — and the block-with-refresh recovery UX (TR2-4). pad owns the
**advertisement** half — per-surface version constants with bump-rules-as-
doc-comment and an in-file changelog, advertised in the MCP handshake and a
`_meta/version` resource (PD1-1) — plus the paid-for lesson that advertisement
without mechanical enforcement rots. The fused do-now PR
([PD-FIRST-WAVE](../pms/pad/PD-FIRST-WAVE.md)) supersedes TR1-2a and kills our
hardcoded MCP `0.2.0`.

### 5.9 Review payloads, staleness, and approval fatigue (§5.3, FLOW §10/§12)

**Verdict payloads**: OR1-1 is the field's only shipped verdict-schema reference —
`approve|revise|reject` + `blocking|advisory` + nullable `{path,line}` anchors +
per-criterion `satisfied` mappings — with two paid lessons (anchors must live in
the *schema*, not the prompt: orca's Codex-path verdicts silently lost them;
finding shape validates at the boundary, never `Vec<Value>` pass-through) and the
anchor-fidelity taxonomy (`on_diff_line | on_unchanged_line | file_not_in_diff |
unmapped`) for every LLM-supplied anchor.

**Landing staleness**: OR1-2 — `clean | dirty | colliding` catch-up states,
approval-stales-when-parent-moves, and the judge re-runs after *any* catch-up (a
hard requirement when the agent performed the rebase). Merge-back-as-agent-work
gains its shipped precedent (resolution-as-reviewable-proposal).

**Approval fatigue**: OH1-2 is the field survivor — autonomy preset cards × action
classes × apply-with-undo, with its dead per-tool numeric scorer answering the
classes-vs-scores question in advance. FLOW §12's adopted design — single-use
`:consume` default, standing grants scoped `(kind, project)` with TTL, a visible
revocable list, and XA2-2's hard-block never-grantable tier — is the synthesis.

---

## 6. Where argus is ahead — the moat, evidence-backed

Four things **no subject in either corpus has** (pms observation 5):

1. Multi-node clustering with a shared DB and node-affine execution — every daemon
   scanned is a spoke to one hub, not a peer.
2. A durable event-feed catch-up contract behind the UI — bosun and orca
   event-source internally but expose nothing like `workflowEvents(afterSeq:)`.
3. An agent-unmintable durable decision object — `AgentCase` + `Cases.decide/4`;
   only bosun has comparable gate machinery at all, and its defects (approved gates
   re-opening, timeout-means-proceed, Mini-App-only decisions) are on the §5.2
   checklist.
4. Execution-layer edit-and-resume (§2).

Supporting evidence of position: **auth hygiene is the field's weak flank**
(symphony none/localhost, myrlin shared password, CCC CSRF-only; Chorus's OIDC +
API keys the lone exception) — the OVERVIEW §4.4 posture survives both corpora.
**Everyone else scrapes or bolts on hooks** for agent state (ades observation 3);
we read our own `WorkflowEvent` log and `AgentCase` rows — borrow the taxonomy and
UX, never the detection machinery, with two earned carve-outs: TM1-1's *emit* side
(speak the work-done protocol from our REPL) and CC1-1's prose soft-block rubric,
which no formal event system sees on any substrate, ours included. And the field
keeps **re-deriving what we already shipped**: four subjects converge on
classify-before-counting (our Verdict normalizer, camus C1-3), two independently
ship watch-the-watcher (XA1-2), three converge on approval expiry (XA2-1 — which we
still owe ourselves; §7).

---

## 7. The pre-argus work queue (merged do-now set)

Both corpora closed with first-wave queues of **argus-independent** items; the
cross-corpus pass (2026-07-05) re-statused the ades set against the pms one. Merged
and grouped (sizes where the queues recorded them; the per-queue files hold
done-when criteria):

**Contract & surface**
- **PD1-1** served-surface stability PR (S) — fuses traycer's golden pin with pad's
  advertisement half; **supersedes TR1-2a**; kills the hardcoded MCP `0.2.0`
  ([PD-FIRST-WAVE](../pms/pad/PD-FIRST-WAVE.md)).
- **PD1-2** boundary error-code registry (S) — MC3-4's consumer.
- **pad `/setup` doctor** (S).

**Attention & reply**
- **CC1-2a + CH item 1** (S) — surface the invisible attention signals (LoopGuard
  halts, cron failures, Forge `:needs_input`, plus muxara's two Forge sharpenings)
  *and* wire `Forge.apply_input/2` end-to-end — surfacing without the reply half
  shows a park nobody can answer ([CH-FIRST-WAVE](../pms/chorus/CH-FIRST-WAVE.md)).
- **TM1-1** emit the work-done protocol from our own CLI.
- **CC1-1** the prose soft-block detector (with MX3-1's fixture-corpus method).
- **CC2-2** ManagedDoc for `system_prompt.md` (XA3-1 as second reference).

**Gate hardening**
- **XA2-1 + XA2-2** (one session) — `AgentCase` TTL/sweeper + the hard-block
  never-grantable tier; three-subject convergence, BO2-5 the reference
  implementation; shadow-first per TM2-3.
- **EM2-3** shell-gate `git worktree` mutations — prerequisite for the worktree
  slice and for TM1-3/TM2-4.

**Health & scheduling**
- **SY item 1** scheduled provider credential canary (S) — **closes XA2-3**; SY1-4
  is the shipped probe, MY1-1's transients-never-mark-dead the health model
  ([SY-FIRST-WAVE](../pms/symphony/SY-FIRST-WAVE.md)).
- **OH cron-health slice** (S) — persist the breaker, classify before counting
  (reuses MC1-4), stop disabled rows vanishing, outcome-tagged telemetry + the
  `:schedule` Trace channel's first producer
  ([OH-FIRST-WAVE](../pms/openhelm/OH-FIRST-WAVE.md)).
- **SY config boot** (S) — fail-closed `.jido/config.yaml` load + last-known-good
  re-read.
- **SY `:stage_stalled`** (M) — composer wave inactivity clock; soft-depends on
  MC1-4.

**Execution substrate**
- **MC1-4 → MC1-1 → MC3-4** ([MC-FIRST-WAVE](../pms/multica/MC-FIRST-WAVE.md)) —
  the failure taxonomy first (S; resume consumes its `resume_unsafe?/1`), then
  native CLI session resume for the Forge runners (M — the corpus-wide composition
  target, with riders from orca (OR3-2 dual-timeout split + group-kill), Chorus
  (anchor-ownership + group teardown, CH2-6/CH3-2), symphony (SY3-3
  continuation-turn discipline), and bosun (BO2-3's infra-vs-session split, the
  Codex poisoned-resume inventory)), then exit-code tiering (XS — consume PD1-2's
  registry rather than re-sniffing).
- **OR2-4a** `mix jidoclaw.reproject_steps` (S) — build the step-projection rebuild
  our moduledoc already claims ([OR-FIRST-WAVE](../pms/orca/OR-FIRST-WAVE.md)).
- **OR env floor** (XS) — the non-interactive subprocess env floor.

**Enrollment**
- **MY1-4a** `mix jidoclaw.api_key` mint/list/revoke (S) — `Accounts.ApiKey` has
  zero minting paths today; pairs with the MY1-4 QR-ladder reference when the
  argus client lands.

---

## 8. Open-question register

Grouped by where the decision lands (slice numbering = FLOW §13):

**Slice 1 (attention loop)**
- Push-subscription wiring: the trigger set is settled (§5.1); every trigger needs
  its named, tested producer before it's declared.
- GraphQL codegen + rolling-upgrade skew tooling (OVERVIEW §6.3): TR1-1/TR1-2 +
  PD1-1 are the reading list.
- Delivery-policy seams to decide together: bosun OQ-2 (adopt the
  immediate-vs-digest split?), Chorus OQ-3 (per-kind mutes vs severity), multica
  OQ-3 (deferred escalation).
- Standing-grant UI (XA OQ-1 → FLOW §12's once / this-thread / this-project-N-days
  tiers; grants visible and revocable; hard-block list always asks).
- muxara OQ-1 (needs-input vs our non-blocking approvals) and OQ-2 (unknown
  semantics: boring-unknown vs termic's fail-toward-attention).
- CCC OQ-1/OQ-2 — the attention/disposition vocabulary shared with camus C1-4/C1-5.
- Task field mechanics (MC OQ-1/2/3, split across slices 1 and 3 per the multica
  dig).

**Slice 3 (board & workflows)**
- Review-gate YAML key shape (OVERVIEW §6.1) — with the Chorus dig in hand.
- Task-schema review: BO1-4's checklist (enforce kinds on the resource, provenance
  in the same write, round-trip tests on any external status mapping), MY2-2's
  two-terminal-status evidence, PD1-3's computed-refs garnishes.
- orca's arming question: is `ready`-kind the arming bit, or is arming per-task?
  (Queue-then-release: release ≠ start.)
- The workflow-YAML repo seam (FLOW §13 open item 1): the import-copy candidate
  is field-validated clause by clause (PD1-4), but the decision itself stays
  parked — settle by slice 3 (store) or slice 7 (editor); argus never writes
  into repos.

**Slice 4 (landing)**
- **OH2-4** (TRACK) — run-scope snapshot / detection-before-pin; triggered by
  composer external-MCP reach or slice 4's long-lived review gates.

**Per gate kind, when phone approvals land**
- **OH OQ-2** — decided-after-death: who executes a grant decided after the run
  ended (OpenHelm executes the stored payload platform-side; our consume semantics
  assume a live loop re-issues).

**Standing TRACKs**
- **ACP**: should JidoClaw *speak* ACP so third-party cockpits can drive it? Costed
  at EM1-4 (four methods + two callback families over `chat/4`, SignalBus, and the
  tool-approval gate); the one real design decision is the permission bridge
  (EM OQ-1: single-use consume vs `allow_always`); multica attaching its newest
  drivers via ACP is the strongest adoption datapoint yet. Trigger: the OVERVIEW §4
  API design pass.
- **BO1-1** — the reference (qualification fences, resume cap, unresumable-reason
  taxonomy) when a resume-past-the-gate / auto-resume-on-restart design ever
  starts.

---

## 9. Method notes

- **Pin the commit, read the code, treat docs as hypotheses.** The discipline held
  across all fourteen digs and is what produced the ≥46 corrections. Never cite a
  scan-level claim without the "per scan" flag — both corpora demonstrate why
  (every dig corrected its own scan, and two of OpenHelm's three recorded citations
  were dead code at HEAD).
- **The connective pass is load-bearing.** Every composite in §5 (ades observations
  6–8, pms observations 9–13) was invisible to the individual digs that supplied
  its parts; budget the pass whenever a corpus closes.
- **Cross-corpus back-links executed 2026-07-05** ([DIG-BRIEFS](../pms/DIG-BRIEFS.md)
  motion 1); each repo's standing questions ride along with any future full
  exploration rather than scoping one.
- **License discipline held** (§1) — keep it for any future lift: AGPL/BUSL/
  modified-Apache subjects contribute rubrics, schemas, and negative results, never
  code.
