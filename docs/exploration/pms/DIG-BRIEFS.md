# pms Dig Briefs — argus standing questions

**Prepared 2026-07-04**, after the argus product-flow pass
([../argus/FLOW.md](../argus/FLOW.md)) settled the decision layer. Each brief
below arms a dig with the questions that doc marked "hold soft" — the specific
evidence argus wants from that repo — plus the FLOW/OVERVIEW section each
answer feeds.

## The standing rule: full explorations, not scoped reads

The questions in these briefs are **areas of interest riding along with the
dig — they are not the dig's scope.** Every dig is a full exploration
(explore-repo conventions: pin the commit, read the code, treat docs as
hypotheses, tiered verdicts with file:line evidence on both sides). The ades
corpus is the argument: its six digs corrected **twenty scan claims** between
them, and the biggest hauls were things no scan flagged — termic's sandbox
trust rules were entirely unflagged, muxara's worktree lifecycle datapoints
were found looking for something else, CCC's targeted read got upgraded to a
full inventory when the seams pass found live our-side gaps. Expect the same
here: answer the standing questions, *and* sweep the whole subject.

**Method notes for every dig:**

- Repos live at `~/workspace/research/pms/`. Refresh before digging and
  re-pin HEAD; note drift from the scan commits (pinned in
  [README.md](README.md)) — several of these projects move at
  solo-plus-agents velocity.
- Hold [../argus/FLOW.md](../argus/FLOW.md) and
  [../argus/OVERVIEW.md](../argus/OVERVIEW.md) open as the our-side seam map.
- Corrections to [README.md](README.md) scan claims are part of the
  deliverable, as is the §5 sweep (below).
- **License discipline** (from README observation 8): clean — orca (MIT),
  bosun / pad / symphony / OpenSymphony (Apache-2.0). Patterns only, never
  code — Chorus / myrlin-workbook (AGPL-3.0), OpenHelm (BUSL-1.1), multica
  (modified Apache with Dify-style commercial clause — read it before lifting
  anything beyond ideas).

## Cross-cutting questions (every dig carries these)

1. **The §5 sweep continues**: any execution-layer edit-the-step-output-and-
   resume, anywhere? Fifteen subjects verified empty so far; keep the streak
   honest.
2. **Provisioning lifecycles** (FLOW §5): anything shaped like
   create → setup → ready for workdirs — setup state tracking, idempotent
   steps, toolchain init, secrets materialization.
3. **Branch/directory naming conventions** in the wild (FLOW §4 templates) —
   defaults, collision handling, operator overrides.
4. **Status/attention taxonomies** (FLOW §7/§12): status→category mappings
   (evidence for or against our seven kinds), severity models, what triggers
   a human ping.
5. **Teardown + stranded-work detection** (FLOW §5/§12): dirty-checks, phased
   deletes, orphaned-branch/PR surfacing.
6. **Placement & multi-machine addressing** (FLOW §2): anything that routes
   work to a specific host and what happens when that host is gone.

---

## multica — priority dig

**Trigger** (already named in README): argus Worktree-domain work beginning.
**Feeds**: FLOW §2 (placement), §4 (driver edge cases), §5 (worktree
binding), §7 (task schema — the largest hold-soft item), §12 (attention).
The only scanned product with argus's full server topology; also the fastest-
moving repo in the corpus, so expect drift from the scan.

1. **Task schema, field by field** (§7): `issue`, `issue_dependency`
   (blocks / blocked_by / related), sub-issues, kanban position mechanics,
   projects. Especially the status model: as a Linear clone, is there a
   workflow-state → category mapping (direct evidence for our seven-kind
   enum)? Per-team/project custom states? How does *blocked* manifest —
   status or computed?
2. **Issue ⇄ run ⇄ worktree binding** (`execenv/git.go`, repocache; §5):
   when worktrees are created, branch naming, reuse across sessions, cleanup
   policy, dirty-state handling.
3. **Daemon protocol** (§2): outbound WS, heartbeats, capability profiles —
   how work routes to a machine, and the failure story when a daemon
   disappears mid-run. Their placement policy vs our node-pinning.
4. **The Claude driver edge-case list** (`claude.go`; §4): env scrubbing
   (`CLAUDECODE*`), new-vs-resume transcript probing, session UUIDs anchored
   to the issue, crash recovery. Feeds our CLI adapter even though it's their
   native mode.
5. **Comment-triggered resume + `RerunIssue force_fresh_session`**: the
   successor-thread and poisoned-state analogs — what "discard state" means
   concretely.
6. **Inbox/severity model** (`action_required / attention / info`; §12):
   what produces each level, how it's consumed, the Slack/Lark @mention
   integration.
7. **Squads and autopilots** (§6/§8): leader-delegation fan-out shape, caps,
   failure handling; autopilot cron/webhook runs vs our cron design.
8. **The anti-interactive stance in practice**: `AskUserQuestion` disabled,
   clarifications forced into comments — how blocking questions actually play
   out (feeds `ended_blocked`, §12).
9. **Still no gates?** `bypassPermissions` was hardcoded at scan time —
   verify it held, and look for any post-scan approval machinery.

---

## Chorus — dig at the review-gate/editor design pass

**Trigger**: FLOW slices 3–4 design (workflow schema review gates; the
landing gate) — its proposal editor is the closest shipped UX to ours.
**Feeds**: FLOW §7, §9, §10, §12; OVERVIEW §5. **AGPL: patterns, rubrics,
and schemas only — never code.**

1. **The proposal lifecycle end-to-end** (§10, OVERVIEW §5): draft → human
   edits → approve → materialize-in-a-transaction; the `canEdit = draft`
   state guard; reject-with-note regeneration. Map exactly where their
   edits-re-prompt-the-model seam sits — the contrast that keeps our
   promote-the-edit claim honest.
2. **Task-DAG visual editing while draft** (§9): the closest prior art to
   our react-flow editor — interaction model, validation, how DAG edits
   survive materialization.
3. **The reverse control channel**: SIGINT-with-double-check interrupt,
   resume, free-text instruction injection into a running turn. Argus
   currently has no mid-run steering primitive — assess whether one belongs
   in FLOW (native threads can just be messaged; a workflow run mid-step is
   the open case).
4. **AgentInstance `(agent, host, cwd)` addressing + pinned wakes** (§2):
   the nearest external design to node-pinned threads — routing, and the
   failure mode when the pinned instance is gone.
5. **The unified user-or-agent Notification row** (§12): one model serving
   human pings and agent wakes — schema and delivery rules.
6. **The MCP permission matrix** (~81 tools, 5 resources × 3 actions; §4):
   how grants are stored, checked, and scoped — compare against our
   deny-by-default sandbox allowlist + session tokens.
7. **Verification semantics** (§7): dual-path (dev self-check + admin
   verify), per-task acceptance criteria — board semantics for review-kind
   statuses.

---

## symphony + OpenSymphony — one joint targeted read

**Trigger**: CLI engine slice (FLOW slice 6) — but worth reading earlier,
when the adapter behaviour gets its shape. **Feeds**: FLOW §2, §4 (`:cli`),
§8, §9; both Apache-2.0, our language.

1. **The Codex app-server client** (upstream; §4): full protocol surface —
   `initialize` → `thread/start` → `turn/start`, approval / user-input /
   elicitation handling, dynamic tools, token accounting, stall and turn
   timeouts. The adapter-behaviour reference, near-liftable.
2. **OpenSymphony's Claude Code headless stream-json driver** (§4): event
   mapping, resume, error/permission handling — the second adapter, same
   behaviour.
3. **Worktrees off a cached bare repo** (`workspace.ex`; §2): the exact git
   plumbing — clone flags, refspec config, fetch/prune cadence,
   `worktree add`/`remove`, collision handling. Verify the scan's
   fork-delta read while at it.
4. **The orchestrator dispatch loop** (§8): bounded concurrency, per-state
   caps, exponential backoff, stall detection, reconciliation against the
   external source of truth — hygiene our automation/cron engine should
   match.
5. **`WORKFLOW.md` as validated contract** (§9): YAML front-matter validated
   by Ecto embedded schemas (no DB) + Liquid prompt body — a datapoint for
   our workflow-schema validation story.
6. **Placement and capacity trio** (§2/§5): least-loaded SSH worker
   selection; OpenSymphony's label-routed model/effort tiers (kin to our
   AR-9 seam); multi-account rate-limit rotation
   (`healthy | limited | exhausted | paused`) — relevant to per-node CLI
   credential health.
7. **The reverted comment-resume** (#84 → #85): recover *why* it was backed
   out — a negative datapoint for conversational resume triggers.

---

## orca — targeted read alongside editor + worktree modeling

**Trigger**: FLOW §5 provisioning and the review-gate payload design.
**Feeds**: FLOW §4, §5, §7, §10; OVERVIEW §5.3. MIT; quiet since May 2026,
so low drift risk.

1. **The auditor verdict schema** (§10, OVERVIEW §5.3): approve / revise /
   reject with severity-tagged, `path:line`-anchored concerns — a
   ready-made candidate shape for review-gate payloads.
2. **The briefing-loop event vocabulary** (`BriefingDraftEdited`,
   `BriefingPushedBack`; per-assumption pushback feeding regeneration) — the
   plan-layer edit gate; again map the re-prompt vs promote-the-edit seam.
3. **DAG auto-queue-on-merge** (§7): exact trigger semantics — merge
   detection, dependency release — the external mirror of our
   ready-kind flip.
4. **Worktree auto-init** (§5): toolchain detection (pnpm/uv/cargo/go)
   before first phase — provisioning-step material.
5. **Event-store conventions**: `command_id` idempotency,
   correlation/causation ids, disposable rebuildable projections — an
   independent Rust mirror of our spine; flag any garnish worth adopting.
6. **CLI-driving gotchas** (§4): the plan-permission-mode stdin deadlock;
   the auditor hard-clamped from `bypassPermissions` — edge cases for the
   adapter's list.

---

## Second wave — targeted reads / pattern notes

**bosun** (targeted read, timeboxed — the codebase is enormous; verify
before citing anything): the worktree lifecycle manager and its **recovery
state machine** (§5 provisioning + failure); execution ledgers with
auto-resume-on-restart; whether the risk-tiered gate family actually
round-trips (README flagged scan-level claims as unverified); the Telegram
Mini App approval UX (phone-approve reference, §12); multi-backend kanban
adapters as the recorded two-way-sync cautionary tale (§7). Apache-2.0.

**myrlin-workbook** (pattern notes; AGPL — patterns only): the per-event
push-subscription taxonomy, especially **`fileConflicts`** — the cross-agent
conflict-detection mechanics our merge-back attention item needs (§6/§12);
task-spinoff's editable spec forms (agent-created tasks, §7); QR-pair device
enrollment + Bearer tokens (client enrollment, OVERVIEW §4.4); the
worktree-task board's column semantics and concurrency caps (§7/§8).

**pad** (pattern notes, at API-surface freeze): `tool_surface_version` +
closed error-code taxonomy (the skew problem at the tool-contract layer —
second precedent beside traycer TR1-1/TR1-2; OVERVIEW §6.3, and our sandbox
MCP endpoint); playbooks-as-data lifecycle (draft/active/deprecated — kin to
our immutable-append workflow versions, §9); stable item refs (`TASK-5` —
a task-ref shape datapoint, §7); the Yjs + SSE multi-node bridge.
Apache-2.0.

**OpenHelm**: ~~stays no-dig (contrast reference only). The two recorded
citations stand: the risk-taxonomy gate (a graduated version of our binary
require-list) and run-snapshot-for-resume (worth remembering when composer
stages gain external MCP reach). BUSL-1.1.~~ **Reversed — dug 2026-07-04** on
operator request
([openhelm/FEATURES-WORTH-BORROWING.md](openhelm/FEATURES-WORTH-BORROWING.md)
@ `2facabaa`), and the reversal paid: **both recorded citations were wrong at
HEAD** — the per-tool risk-1–5 gate is dead code (the live, better shape is an
autonomy dial × action-class taxonomy × apply-with-undo, OH1-2) and the run
snapshot is write-only (`readRunMcpSnapshot` has zero callers; resume
re-resolves live — the composer-MCP-reach trigger survives as OH2-4, TRACK,
detection-before-pin). The cross-cutting six all answered (§5 empty at subject
24); the unpredicted haul is the cron-health breaker family (OH1-1, with an
adoptable-now our-side slice) and the evaluator/outcome-contract convergence
riders (OH1-3).

---

## What each dig should produce

The house deliverable — `FEATURES-WORTH-BORROWING.md` under this directory's
repo folder, tiered verdicts, file:line evidence on both sides, corpus index
updates — **plus**, for these briefs: an explicit disposition for each
standing question (answered / contradicted / absent, with evidence), scan-
claim corrections back into [README.md](README.md), and a note in
[../argus/FLOW.md](../argus/FLOW.md)'s hold-soft list when a section can
harden.

## After the digs — the ades revisit policy

The [ades corpus](../ades/README.md) does **not** get re-dug when this corpus
completes — its six digs are fresh and the delta since is on *our* side (they
were dug against OVERVIEW-era argus, before FLOW existed). Three lighter
motions instead:

1. **Cross-corpus connective pass** once the pms digs land: stitch what the
   two corpora couldn't see of each other — the assembled stacks argus
   consumes (worktree references, the attention stack, notification triggers,
   editor prior art, adapter references) now span both — with dated
   back-links into the ades inventories where pms findings confirm,
   contradict, or extend them. Same motion as the ades README's own
   connective pass, one level up. *(Status 2026-07-04: the **intra-pms** half
   ran — README observations 9–13, the combined first wave, dated connective
   notes between the pms inventories. **2026-07-05: the cross-corpus half ran**
   — dated notes now sit in all six ades inventories (traycer TR1-1/-2/-3/-4,
   TR2-1/TR2-3, OQ-2/OQ-3 plus the TR1-2a supersession; emdash EM1-1/-2/-3/-4,
   EM2-1, OQ-1/OQ-3; termic TM1-2/TM1-3/TM2-2/TM2-5; CCC CC1-1/-2/-3,
   CC2-2/-3/-4; muxara MX2-2; Xantham XA1-1/-2, XA2-1/-2/-3, XA3-2, OQ-1) and
   in the ades README (observations 1–2 and 4–8, plus a first-wave status
   update recording TR1-2a's supersession by pad PD1-1, XA2-3's queued closure
   via SY-FIRST-WAVE item 1, CC1-2a's reply half via CH-FIRST-WAVE item 1, and
   the XA2-1 three-subject convergence). The earlier per-dig seeds — ades
   CC1-2, argus OVERVIEW deferred-questions 2/3, hermes T2-13 — stand as-is.)*
2. **Per-slice re-reads with a re-pin rule**: each argus build slice already
   carries its ades reading list via FLOW's citations; refresh and re-pin any
   ades repo *before a build decision cites it* (emdash, termic, traycer, and
   CCC move weekly — corpus observation 8 applies to our inventories of them
   too).
3. **Named re-verification trigger — the §5 novelty claim**: before FLOW
   slices 3–4 freeze the editor design, re-sweep the four active ades
   subjects for edit-and-resume shipping since 2026-07-03 (emdash's deleted
   Plan Mode is exactly the kind of thing that gets rebuilt). An afternoon,
   not six digs.

Escape hatch: a FLOW question the ades inventories can't answer
(sub-worktree nesting, preview-worktree UX beyond TM1-3, emdash's ACP
surface) triggers a *targeted* re-read of that one subject, scoped to the
question. muxara and Xantham are quiet/static and essentially never warrant
a second pass.
