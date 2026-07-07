# Argus — Product Flow

**Living draft.** This document sketches how argus should work at the product
layer — the shape we currently believe in, not a finalized spec. It extends
[OVERVIEW.md](OVERVIEW.md) (architecture: cluster topology, API surface, the
§5 editor family); where the two disagree, this document is newer. The
pms-corpus digs ([../pms/README.md](../pms/README.md)) have all landed
(2026-07-04) and are folded in — §13 records what each hardened — as are the
three late-addition ades digs (t3code, herdr, cmux — 2026-07-06; §4, §5, §11,
§12, and the §13 coda carry their folds) — and
[SYNTHESIS.md](SYNTHESIS.md) (2026-07-05, refreshed 2026-07-06) rolls both
corpora up by argus
concern: the composite checklists, the merged do-now queue, and the
open-question register this doc cites piecemeal. Corpus shorthand
(`TR…`, `EM…`, `MX…`, `CC…`, `XA…`, `TC…`, `HD…`, `CM…` — ades; `MC…`, `CH…`,
`SY…`, `OR…`, `BO…`, `PD…`, `MY…`, `OH…` — pms) resolves via the two corpus
READMEs
([../ades/README.md](../ades/README.md),
[../pms/README.md](../pms/README.md)); this doc answers pms observation 6
(the task layer) in the affirmative. [DECISIONS.md](DECISIONS.md)
(2026-07-07) snapshots every settled decision across all three docs, one
line each, grouped by build slice — start there; this doc holds the
rationale.

## 1. The shape of the system

- **Projects** are GitHub repos, cloned bare onto the cluster's nodes; all git
  work happens in worktrees.
- **Threads** are conversations with an agent — the unit of interaction. A
  thread holds at most one worktree.
- **Worktrees** are first-class and durable; threads are visitors, one writer
  at a time.
- **Tasks** live on a per-project kanban board and are the durable identity of
  work; threads and worktrees are its execution residue.
- **Crons** schedule recurring agent work per project.
- **Workflows** are the automation currency: DAG definitions runnable
  manually, by task-status change, by cron, or by other workflows.
- **Nothing migrates.** Threads, worktrees, and sandboxes are pinned at
  creation to one node until deletion. Mobility comes from cloning repos
  everywhere and creating *new* things elsewhere — never from moving existing
  ones.

## 2. Nodes & placement

Every participating node carries, per project: a **bare clone**, a
`worktrees/` directory holding that node's worktrees, and a **reference
checkout** of the primary branch. The reference checkout is read-only by
invariant — browsing and file-tree duty only, enforced (shell-gating `git
worktree` mutations, EM2-3), never edited. Fetch/fast-forward of clones and
reference checkouts is per-node housekeeping.

Cloning everywhere is the resilience story: a node that is down (restarting,
updating, gone) takes its pinned worktrees offline with it, but new work for
any project can start on any live node immediately.

Placement rules:

- **Every thread gets its node at creation** via a defaulted, ignorable
  picker: automations and plain chat default to the always-on node (the
  Postgres host); interactive defaults are sticky per project; override is
  always visible.
- **Worktrees are created on the creating thread's node** and pinned there.
- **Attach-existing is same-node only.** Continuing branch X from another node
  is a one-click *successor thread* on X's node, never a move.
- **Sub-threads and sub-worktrees inherit the parent's node** — fan-out
  parallelism is deliberately bounded by one machine's capacity.
- Node-offline is a first-class UI state on every worktree (device-local
  affinity, TR2-2), not an error.

## 3. Projects

A project starts from a GitHub `org/repo`. Each project carries a
**participation set** — which nodes clone it — defaulting to *all nodes,
including future joins* (a node joining the tailnet auto-clones every
default-all project), with an explicit subset override for disk-heavy repos
on small nodes. Leaving the set is busy-checked like worktree deletion: a
node still holding pinned worktrees can't be removed. Projects carry
`status: active | archived`, per-project settings (naming templates, landing
defaults, sticky placement), and own everything below: threads, worktrees,
tasks, crons, project-scoped workflows.

## 4. Threads

A thread anchors on `Conversations.Session` — the existing resource; kinds,
metadata, and compaction snapshots all apply — and argus renders the
transcript the Recorder already writes. New is a per-thread **engine**:

- **`:native`** (default): the JidoClaw agent loop — FrontDoor → composer,
  gates, compaction, the full tool pipeline. Everything argus displays for a
  native thread is structured events the platform already emits.
- **`:cli`**: an external coding CLI (Claude Code, Codex) run **inside a
  Forge sandbox on the thread's node, piped to the UI** — the operator talks
  to the CLI directly rather than through the native agent. It is a Forge
  workload, not a raw host process, so containment, egress scoping, credential
  file sync, and the Harness lifecycle events (`:ready`, `:needs_input`,
  `:error`, `:stopped` on `Forge.PubSub`) come with it — thread status
  classification with no scraping.

**One rendering path.** The CLI adapter normalizes its session stream into the
same transcript rows and durable events the native path produces. The moment
the UI grows a second rendering path for CLI threads, the "we have events,
everyone else scrapes" advantage is forfeit. Piped output is **redacted at the
durable sink** (`Security.Redaction` before persistence — the consolidator's
redact-at-sink precedent) so un-redacted tool output never reaches Postgres or
the web UI. *(Connective note, 2026-07-04 pass: chorus CH2-4 adds the
injected-scaffolding half — drop synthetic envelopes **structurally**, by
stream-json event type (their `isSynthetic` precedent), before redaction runs,
so skill bodies / system-reminder spans never bloat the durable transcript;
adoption sketch in the chorus inventory, slice 6.)*

**CLI trust posture — structural gate plus vendor rails.** The load-bearing
layer is structural: the sandbox carries **no GitHub credentials**, its egress
allowlist covers only LLM APIs and JidoClaw's MCP endpoint, and the worktree's
git `origin` is the **node-local bare repo** — so commits and branch work are
free and local by construction, while push, PR creation, and arbitrary web
reach exist *only* as gated JidoClaw MCP tools (`git_commit` is already
require-listed; push/PR tools join it; web goes through the
destination-policy-gated `browse_web`). The grant never rides a model-mediated
channel (XA1-1), by construction. On top, each CLI runs its native
ask-rules as defense-in-depth — permission-prompt-tool / approval callbacks
bridged into the same `AgentCase` inbox — tuned sparse, since the structural
layer already blocks the big stuff. The adapter owns the per-CLI permission
config templates.

**MCP access.** The sandboxed CLI connects to JidoClaw's MCP server and gets
the platform tools (`find_solution`/`store_solution`, `workflow_status`,
`fetch_output`, `lua_query`, `network_share`, …); every such call runs the
full `Tools.Action` pipeline on our side (approval gate, redaction, shaping,
loop guard). The CLI's *native* tools (its own file/exec inside the sandbox)
ride sandbox containment instead of per-call gating — the documented `:docker`
posture, accepted here explicitly. This needs one new piece of plumbing: an
**HTTP MCP endpoint reachable from sandboxes** (the server is stdio-only
today; the consolidator's loopback Bandit endpoint is the precedent). Its
scoping is **deny-by-default**: a per-thread tool allowlist bound into a
per-Forge-session token (auth + tool scope + tenant/session identity, minted
at session start, dead at session end). Host-executing tools (`run_command`,
`write_file`, `git_*`, …) are structurally unreachable from sandboxes — one
such call would be a sandbox escape by design.

**Creation paths**: manual (modal: node picker defaulted, optional worktree,
optional workflow), task, cron, workflow step; later, GitHub webhook ingest
(issue labeled / PR comment — the HMAC ingress and `PullRequestCoordinator`
already exist). Automated branch and directory names come from **two
templates** — branch and directory, each per-project over global defaults
(branch default `{source}/{slug}`; directory default mirrors the sanitized
branch; tokens `{source, slug, date, n, parent}`; a `-{n}` collision counter
auto-appends to both; sub-worktrees default off the parent; herdr datapoint
2026-07-06 — generated adjective-noun slugs + collapse-to-dash path
sanitization with a non-empty fallback,
[ades/herdr HD2-4](../ades/herdr/FEATURES-WORTH-BORROWING.md)). Manual creation
takes input. Workflows are
**native-engine-only for now**; a CLI-turn step kind has schema room (§9) but
is explicitly later.

## 5. Worktrees

First-class, durable, stacked on `Workspace` per OVERVIEW §3.3 (`branch`,
`status`, `node`), plus a parent link (§6) and a **writer lease**: at most one
active thread at a time, acquired and released in Postgres — never in node
memory. Threads visit serially over a worktree's lifetime. Lease-busy is a
designed UX state: point at the holding thread, never queue silently.

**Binding**: thread → worktree is 0..1, set-once (0→1), never swapped. Attach
happens at creation or mid-thread; mid-thread may create new (on the thread's
node) or acquire an existing same-node worktree's lease. Attach is an explicit
recorded event.

**Provisioning is a lifecycle, not a side effect**: create → setup → ready,
with `setup_status` tracked separately from lifecycle status (traycer TR1-3).
Setup steps are idempotent and per-project (emdash EM1-1/-2: preservePatterns,
compiled steps), covering toolchain init (orca's auto-detect) and **secrets
materialization**: per-project secrets live in the Vault and materialize into
a worktree at setup — never copied around by hand. Per-node CLI credentials
follow the Forge OAuth file-sync approach. A worktree isn't offered to a
thread until ready.

**Deletion is phased, dirty-checked, PR-aware, and reconciled** — the
composite teardown law ([SYNTHESIS §5.3](SYNTHESIS.md)): phased +
dirty-checked (the corpus spectrum's strong end: TR2-1, MX2-2), a
teardown-time open-PR sweep (SY2-4), and a records↔worktrees
reconciliation sweep (against myrlin's record-delete stranding, MY2-3;
herdr's gitdir-provenance check before deleting a stray checkout dir joins
it, and its branch-survives-teardown default is the named recoverability
middle point — HD2-4, 2026-07-06) —
and never delegated to an agent (CC2-3).

## 6. Sub-threads & fan-out

A thread holding worktree W (branch X) can fan out: sub-threads, each with a
sub-worktree whose branch forks **off X** (not primary) from **committed
HEAD** — commit-first; uncommitted work never carries over. Sub-threads and
sub-worktrees carry parent links, inherit the parent's node, and are
depth-capped (the AgentTracker spawn-cap philosophy).

**Spawn paths**: the operator (UI) and workflow steps spawn freely — human or
definition intent. The parent agent also gets a spawn tool, but it is
**approval-require-listed** (livable via standing grants, §12) and capped.

**Merge-back is agent work, not platform mechanics.** When a sub-thread
completes, the platform emits an event/attention item to the parent thread;
the **parent's agent** — which holds the lease, has the context, and is good
at resolving conflicts — runs a gated `merge_child` tool call. Conflicts
become agent work surfaced as attention items (myrlin's `fileConflicts`
trigger has its home here). The platform's job is eventing plus one tool; no
system actor ever mechanically merges into a live worktree. PRs stay reserved
for landing on primary (§10).

## 7. Tasks & the board

Tasks are a **native Ash resource** — argus is the source of truth. A task may
*link* a GitHub issue (reference only). One-way ingest (issue opened → task)
is a later bolt-on through the webhook ingress; two-way sync is explicitly
rejected (the bosun-adapter trap — dig-verified 2026-07-04: bosun's two-way sync
engine was *deleted in production*, its workflow-template replacement
dynamic-imports the missing module and fails silently, and its board webhook
503s unconditionally;
[../pms/bosun/FEATURES-WORTH-BORROWING.md](../pms/bosun/FEATURES-WORTH-BORROWING.md)
BO1-4 carries the residue as slice 3's schema checklist).

**Statuses and lanes**: statuses are per-project and fine-grained; each lane
*displays* a group of 1+ statuses. Workflow bindings attach at either
granularity (status or lane), so one transition can fire several workflows.
Each status also carries a fixed, system-owned **semantic kind**:
`triage / backlog / ready / in_progress / review / done / canceled`. `triage`
is the inbox kind — webhook-ingested and agent-spun-off tasks land there
("N tasks awaiting triage" is an attention-feed item), so auto-created work
never hits the board unsorted; `ready` means automation-eligible; `done`
releases dependents while `canceled` terminates without releasing (default
policy); blocked is **computed** from dependencies, never a kind. User
automations bind to statuses and lanes; *system* behavior binds to kinds:
dependency release ("queue B when A reaches a `done`-kind status" — orca's
queue-then-release: release ≠ start; whether `ready`-kind is the arming bit
or arming is per-task is the slice-3 OQ), cross-project review queues,
merge auto-advance, completion detection.

**Task ↔ thread is M:N with a strong default of one task per thread.** The
M:N exists for the roll-in case: a task that turns out to be a dupe,
near-dupe, or close-enough neighbor of in-flight work gets rolled into that
thread rather than spawning a parallel effort. The UI treats multi-task
threads as the explicit exception. One thread-spawn in flight per task at a
time; a second triggered spawn queues visibly, never drops.

Status transitions produce durable audit rows with **actor provenance**
(human / workflow / agent). *(Citation corrected by the pad dig 2026-07-04:
pad's `status_transitions` rows carry the fact only — field/from/to/when, no
actor columns — with attribution split onto the item and a separate activities
feed; we deliberately fuse fact and actor in one row —
[../pms/pad/FEATURES-WORTH-BORROWING.md](../pms/pad/FEATURES-WORTH-BORROWING.md)
PD1-3.)* Tasks can be created by
operators, by ingest, or by agents/workflows (myrlin's task-spinoff:
extracting actionable tasks from a live thread — *dig 2026-07-04: shipped and
promote-the-edit, but with no stored provenance beyond a tag, and the promoted
spec never reaches the spawned agent; our provenance-in-the-row and
spec-feeds-the-thread requirements are the corrections, MY2-1/MY2-2*) —
provenance recorded, auto-created tasks land in a triage-kind status, and
agent-created tasks flow through the same automation budget as everything
else (§8).

## 8. Automations

**Bindings** fire workflows from: manual thread creation, a task entering a
status, a task entering a lane, a cron tick, or a `run_workflow` step inside
another workflow.

- **Deterministic multi-fire order**: status-bound before lane-bound, then
  declaration order.
- **Automation doom-loop budget**: a workflow that moves a card must not
  re-trigger itself; workflow→workflow chains are depth-capped. LoopGuard's
  sibling at the automation layer.
- **Every fire is explainable**: each triggered run records its binding and
  the transition that fired it — "why did this run?" is a lookup, not
  forensics.

**Crons** are project-scoped; each picks a workflow and a thread policy —
new-thread-per-run, or same-thread-every-run (run-boundary markers in the
transcript; compaction handles LLM context). Overlap policy: **skip the tick
and record it visibly** (attention feed, never silence), per-cron override to
queue or run concurrent; same-thread mode cannot overlap by construction.
Consecutive failures trip a **circuit breaker** — pause the schedule, raise an
attention item (OpenHelm/Xantham precedent — *dig-verified 2026-07-04,
[../pms/openhelm/FEATURES-WORTH-BORROWING.md](../pms/openhelm/FEATURES-WORTH-BORROWING.md)
OH1-1, with three sharpenings: classify before counting — a rate-limited job
defers, it doesn't count as failing, and an infra outage counts for nobody;
persist the counter — OpenHelm's survives restarts, ours today is in-memory and
resets exactly when the cluster is unstable; and pauses auto-recover with
bounded re-trip churn — their unrecovered pause once cost a ~9h fleet outage.
A trip must produce an attention item, never a vanishing row: our current cron
auto-disable hides the job from `:for_tenant` listings, the anti-pattern this
slice fixes*). Cron threads may be
worktree-less, and cron placement defaults to the always-on node.

## 9. Workflows

**Store**: DB rows (Ash resource), scoped **global or per-project**.
**Schema**: a strict superset of skill YAML — still YAML-serializable for
import/export — compiled by the **one** compiler (`Skills.Compiler`,
extended). New step kinds extend that compiler, never a parallel engine, and
plain skill YAML remains valid input. This keeps OVERVIEW §3.4's "no third
DAG format" decision true in spirit: the canonical format is upgraded, not
rivaled.

Superset additions (schema room, not all at once): a declared **inputs**
block (task / cron / operator-supplied variables), `run_workflow`
(workflow→workflow as a step, not magic), thread/worktree operations,
task-status moves, review gates (`pause_for_review`, OVERVIEW §5.2), and —
later — a CLI-turn step kind.

**Versions are immutable-append**: an edit creates a new version; runs pin the
version they started with (the replay/definition-hash drift gates assume
this).

**Execution is thread-anchored**: every workflow run executes inside a
thread; a thread hosts many runs over its lifetime. "Select a workflow at
creation" simply queues the thread's first run.

The **react-flow visual editor** is UX over this schema (nodes = steps,
edges = `depends_on`), and deliberately late (§13, slice 7): YAML authoring +
import/export works from the moment the resource exists, and the schema
should stabilize before the editor freezes it visually.

## 10. Landing

Both paths exist, chosen per project (and overridable per landing):

- **PR-centric (default)**: push the branch and open a GitHub PR
  (`PullRequestCoordinator`); CI and merge authority stay on GitHub. Before
  creation, a **review gate on the PR title/description** — the §5 editor
  family's first shipping use: a `:review` gate holding the PR metadata,
  a typed editor, and promote-the-edit-on-resume (the operator's edit *is*
  what ships — not a re-prompt; **execution-layer** head-promotion, the
  property the 15-repo corpus verified nobody else has — the plan-layer
  variant ships three times, all promoting verbatim,
  [SYNTHESIS §2](SYNTHESIS.md)). Gate on by default;
  per-project/per-workflow setting to
  disable. The merge webhook auto-advances **explicitly linked** tasks (via
  status semantic kind) and offers phased worktree cleanup.
- **In-argus quick-merge**: local merge to primary plus push, no PR — for
  work where a PR is ceremony. Executed against the bare repo; git itself
  forces this shape, since primary is checked out in the reference checkout
  and a branch cannot be checked out twice. *(Corrected 2026-07-07: the
  original "bare-repo ref update" phrasing was only true for
  fast-forwards.)* Two mechanical cases, both landing through a fenced
  compare-and-swap `update-ref` against the expected old primary head (the
  lease-discipline posture): a fast-forward IS just that ref update; a true
  merge has no working tree to merge in, so the merge commit is built with
  plumbing — `git merge-tree --write-tree` (git ≥ 2.38, a per-node version
  floor; the same plumbing OR1-2's staleness dry-runs ride) to compute the
  merged tree, then `git commit-tree` with both parents. A conflicted
  merge-tree never lands platform-side: quick-merge refuses loudly, and
  resolution is agent work in the source worktree (merge primary into the
  branch there — §6's doctrine — then re-attempt) or the operator falls
  back to the PR path.

Landing attribution is **explicit and rides the landing gate**: the
PR-metadata review (and quick-merge's confirm) carries a task checklist,
pre-checked from the thread's task links and adjustable in place — one
checkpoint covers title, description, and "this closes A and B". Confirmed
tasks get PR-linked for the webhook to advance on merge (quick-merge advances
them immediately); taskless landings are legal; nothing is ever inferred.
Pre-merge review surfaces deletions explicitly (merge-base three-dot —
XA3-2).

## 11. Cockpit surfaces

All of these are in v1's definition; they arrive in value order (§13), with
the last two slices (visual editor, terminal) deliberately at the tail.

- **Diffs** — the review surface, three jobs: the live dirty diff of a
  worktree; branch-vs-base (child→parent for merge-backs, branch→primary
  before a PR); and the `code_diff` editor inside review gates. Read-only
  first; comment-on-a-diff-line feeding back as a thread instruction
  (annotate-then-reprompt, emdash/termic) comes later.
- **File tree + viewer** — read-only, served by the owning node from the
  worktree (reference checkout for worktree-less threads),
  syntax-highlighted. Cheap, and disproportionately useful on the phone.
- **Operator terminal** — per-worktree PTY, broker on the owning node over
  the authed WebSocket. Guardrails: **operator-only and never
  model-reachable** (the model's path to a shell remains the gated
  `run_command`/Forge route — CC2-4 is the negative reference); auth via
  **per-session short-lived tokens minted through the UI**, not the standing
  API key, so a leaked key never equals a shell; treated as argus's
  strictest-tier endpoint. Mechanics reference banked 2026-07-06: herdr's
  server-side PTY broker
  ([ades/herdr HD2-1](../ades/herdr/FEATURES-WORTH-BORROWING.md)) — reattach as
  current-state redraw (never byte replay), bounded server-side scrollback,
  single-slot latest-wins render lane per client, size follows the active
  viewer; its two inversions for us: real auth (herdr is 0600+ssh) and
  skew-tolerant versioning (herdr is exact-match-or-die). t3code TC2-3 is the
  MIT sibling reference (server-owned `node-pty`, thread-scoped, PTYs survive
  disconnect, every method gated by a `terminal:operate` scope — the short-lived
  token above is its `wsTicket`, generalized), and cmux CM3-3 files three
  remote-auth garnishes alongside.

## 12. Attention & approvals

Adopt the corpus-merged answer to OVERVIEW §6.2 wholesale:

- **Triggers**: agent finished; blocked-on-you (gate / needs-input —
  including Forge `:needs_input` from CLI threads); `ended_blocked` (ended
  owing an answer — CC1-1/XA1-2); run failed (*included* — this control
  plane's operator has left the desk); infra-degraded (credential canary
  XA2-3, watchdog); `fileConflicts` from merge-backs (myrlin — *citation
  corrected by the 2026-07-04 dig: myrlin declares the trigger but its
  conflict→push wiring is dead code; the borrowable half is the two detector
  shapes —
  [../pms/myrlin-workbook/FEATURES-WORTH-BORROWING.md](../pms/myrlin-workbook/FEATURES-WORTH-BORROWING.md)
  MY1-2 — and for us the transcript-derived detector is a query over durable
  tool-call rows, not a scrape*).
- **Delivery rules**: transition-edge dedupe, active-surface suppression,
  deep links (emdash); per-key debounce, ambiguous-states-fail-toward-
  attention (termic); per-kind daily caps, `==`-not-`>=` streak firing
  (Xantham); replay suppression during reconnect catch-up,
  focus-acknowledgement consumes pending state, minimum-signal re-arm floor
  (myrlin MY1-3 — storm-tested 2026-07-02); immediate-vs-digest priority
  split, a per-window live digest edited in place, the pinned always-current
  status board (bosun BO1-3 — delivery mechanics only); infra-incident
  collapse, guaranteed escalation, email-on-attention additive at
  approval-or-priority≥80 (OpenHelm OH2-2); re-verify-at-delivery — a delayed
  notification re-proves its predicate before firing, else drops — and
  blocked-class pierces focus/DND suppression while completion-class respects
  it (herdr HD1-2, 2026-07-06); **presence-gated cross-device forwarding** —
  push to the phone only while no operator surface is active (presence-gated,
  not device-gated) — and **ack-sync as an absolute projection**: badge/unread
  derives from the durable ack watermark, dismissals are synced facts, never
  per-device ±1 arithmetic (cmux CM1-4, 2026-07-06 —
  [../ades/cmux/FEATURES-WORTH-BORROWING.md](../ades/cmux/FEATURES-WORTH-BORROWING.md)).
- **Architecture rules**: the notifier is the gateway layer subscribed to
  PubSub — never agent behavior (XA1-2); the *ask* may ride any channel, the
  *grant* only ever enters through authenticated non-model surfaces (XA1-1).

**Approval fatigue is the designed-against failure mode**: once phone
approval is one tap, rubber-stamping becomes the real risk. Single-use
`:consume` stays the default; the deliberate exception is a **standing grant
scoped `(kind, project)` with a TTL** (XA OQ-1 / XA2-1's expiry) — the
approve dialog offers *once / this thread / this project for N days*, grants
live in a visible, revocable list, and a **hard-block list** of
never-grantable kinds (the irreversible class: `forget`, replay overrides,
and kin — XA2-2) asks every time, always. UI details land with slice 1's
approvals build.

## 13. Sequencing & open items

**The client is the second product** — server-side, argus mostly reuses the
existing spine; the React SPA (Apollo, Channels, kanban, Monaco, xterm,
react-flow, PWA/push) is greenfield and will likely cost more than the
server. So v1 keeps its full feature set but arrives in **value-ordered
slices, each usable on its own**, dogfooded as soon as the board exists
(argus's own project/kanban as the first board):

1. **Attention loop** — thread list + transcripts (native), approvals inbox,
   push. The thing you check from your phone.
2. **Worktrees** — create/attach/lease, provisioning, diffs, file tree.
3. **Board & automations** — tasks, statuses/lanes/kinds, bindings, crons.
4. **Landing** — PR flow with the metadata review gate; quick-merge; webhook
   auto-advance + cleanup.
5. **Fan-out** — sub-threads/sub-worktrees, `merge_child`, conflict
   attention.
6. **CLI engine** — Forge-piped threads, the sandbox MCP endpoint, ask-rule
   bridges (reading list assembled in [SYNTHESIS §5.6](SYNTHESIS.md)).
7. **Workflow visual editor** — react-flow over the by-then-stable schema.
8. **Operator terminal.**

**Open items**:

1. **Workflow YAML seam** (deferred): how repo-committed `.jido/skills/`
   files surface in argus and what import/export looks like. Leading
   candidate: read-only + one-click import-copy (provenance recorded,
   independent thereafter), export = YAML download, and argus never writes
   into repos — vendoring a definition back is a normal thread/commit job.
   Decide by slice 3 (store) or slice 7 (editor). **Field-validated
   2026-07-04** (pad dig,
   [../pms/pad/FEATURES-WORTH-BORROWING.md](../pms/pad/FEATURES-WORTH-BORROWING.md)
   PD1-4): pad ships the candidate nearly clause by clause — compiled-in
   read-only library, activate = import-copy as a new local item, snapshots
   frozen at creation, drift accepted and closed by explicit re-import — and
   supplies the negative result for the main alternative (its startup
   auto-upgrade backfill was built, hurt intentional divergence, and was
   removed — IDEA-1479). Export shape reference: pad's versioned artifact
   format (format_version + provenance frontmatter over the body), with one
   wart to dodge (their artifact vocabulary drifted from the live schema —
   single-source ours). Rider from the same dig: §9's immutable-append holds
   — pad's mutable-in-place playbooks are safe only because nothing executes
   them; version what engines consume.
2. **Slice-attached engineering opens** — deliberately left to their slices:
   review-gate YAML key shape → slice 3, with the Chorus dig in hand;
   push-subscription wiring → slice 1; GraphQL codegen + rolling-upgrade skew
   tooling → slice 1 (traycer TR1-1/TR1-2 is the reading list).
3. **Naming**: argus stays the codename; a product name is a launch-time
   question, if ever.

**Hold soft until the digs land**: ~~task schema field details (multica)~~ —
**hardened 2026-07-04**, the multica dig landed
([../pms/multica/FEATURES-WORTH-BORROWING.md](../pms/multica/FEATURES-WORTH-BORROWING.md)):
§7's kind layer and computed-blocked now carry evidence (multica's fixed
status enum forces divergent hardcoded category sets per call site, and its
two unrelated "blocked" meanings are the collision our split avoids); §7's
one-spawn-in-flight queue-visibly rule has its DB shape (their
one-pending-task-per-issue partial unique index); §2's nothing-migrates and
§8's skip-and-record + breaker are independently validated; field mechanics
(numbering, position, provenance, metadata KV) are referenced in MC1-2 with
three open decisions (MC OQ-1/2/3) parked to slices 1/3. The dig also
covered a large share of the `:cli` adapter's Claude/Codex driving detail
(MC1-1 — resume stack, env scrub, deadlock discipline), narrowing what the
symphony + OpenSymphony joint read still owes (the Codex app-server client,
SSH workers, `WORKFLOW.md`). ~~The remaining CLI adapter surface (symphony
joint read)~~ — **hardened 2026-07-04**, the joint read landed
([../pms/symphony/FEATURES-WORTH-BORROWING.md](../pms/symphony/FEATURES-WORTH-BORROWING.md)):
§4's `:cli` engine now has its full reference stack in our language (SY1-1
app-server client + MC1-1 resume mechanics; approval frames map to the
`AgentCase` inbox where symphony auto-answers); §4's adapter config templates
have their pattern (SY2-3 single-source multi-CLI tool generation, strict
mcp-config pinning); §9's workflow-store validation has its contract (SY1-3 —
fail-closed writes, last-known-good reload, strict rendering); §8/§10 gain the
reconcile-before-dispatch + revalidate-at-fire + stall-detection checklist
(SY1-2, joining MC2-5); §12's blocked-on-you trigger gains the park-don't-retry
+ reconciliation-releases rules (SY2-2), and stranded-work gains the
teardown-time open-PR sweep (SY2-4). SSH workers confirmed SKIP as mechanism
(Erlang dist is our fabric; their count-based least-loaded + sticky-retry-host
is recorded contrast). ~~Review-editor UX (Chorus)~~ — **hardened 2026-07-04**,
the Chorus dig landed
([../pms/chorus/FEATURES-WORTH-BORROWING.md](../pms/chorus/FEATURES-WORTH-BORROWING.md)):
§10's landing review gate and OVERVIEW §5.4 gain the field's only shipped
promote-the-edit precedent — plan-layer: human draft edits (including DAG edges)
materialize verbatim, the model never re-invoked, with reject-with-note as the
separate re-prompt lane — and its two missing fences (no approve idempotency:
double-approve double-materializes; no revision history: one overwritten
`reviewNote`) become the §5.4 build's named acceptance criteria (CH1-1;
execution-layer edit-and-resume stays empty, subject 19). The §4 steering
question is answered: the field ships **boundary delivery, never mid-turn** —
Chorus's "instruction injection" is a durable pending turn + lossy ping,
serialized behind the in-flight subprocess — and our agent-server mailbox
already queues mid-turn messages as next-turn signals while the dep's true
`steer/inject` sits unwired, so slice 1's work is affordances (busy-thread
send with queue visibility; the Forge `:needs_input` → attention → `apply_input`
reply loop, CC1-2's missing half) and slice 6's is the CLI interrupt taxonomy
(`user`/`crash` provenance gating resume, composing with MC1-1). §2
nothing-migrates gains its second independent validation (origin-gone sessions
go read-only, never rerouted; one explicit cold re-point) and §12's wake
resolution gets the hard/soft pin degradation ladder (hard pin offline ⇒
notify-only, soft ⇒ visible online-first fallback; CH1-3); OVERVIEW §3.3's
node columns get the identity/liveness-split schema reference with generation
fencing and registration conflict-refusal (CH1-4). ~~Still soft: event-store
garnishes and auditor verdict shapes (orca)~~ — **hardened 2026-07-04**, the orca
dig landed
([../pms/orca/FEATURES-WORTH-BORROWING.md](../pms/orca/FEATURES-WORTH-BORROWING.md)),
closing the pms first wave: §10's review-gate payload and OVERVIEW §5.3 gain the
field's only shipped verdict-schema reference (OR1-1 —
`approve|revise|reject` + `blocking|advisory` + nullable `{path,line}` anchors +
per-criterion `satisfied` mappings, with two paid-for lessons: anchors must live
in the *schema*, not just the prompt, and finding shape is validated at the
boundary, never `Vec<Value>` pass-through — plus the anchor-fidelity taxonomy
`on_diff_line|on_unchanged_line|file_not_in_diff|unmapped` for every LLM-supplied
anchor); §10 landing gains the staleness model it lacked (OR1-2:
`clean|dirty|colliding` catch-up states, approval-stales-when-parent-moves, the
judge re-runs after any catch-up — hard requirement when the *agent* performed
the rebase) and §6's merge-back-is-agent-work doctrine gains its shipped
precedent (resolution-as-reviewable-proposal, with the
preserve-ACs-prefer-parent instruction as a tunable setting); §7's done-kind
release sharpens to **queue-then-release** (release ≠ start: orca auto-starts
only human-armed tasks — OQ: is `ready`-kind the arming bit or is arming
per-task?) with canceled-keeps-blocked independently shipped, and §12's
`fileConflicts` gains a second, code-verified reference (their warning-only
file-overlap advisory); §5 provisioning gains the toolchain-init table +
init-status-split + hard-stop/retry/recorded-skip reference (OR1-4) and — as the
anti-reference — orca's force-delete-everything teardown is the datapoint for
why §5's phased+dirty-checked deletion is right; the event-store garnish
resolves to an our-side IOU (OR2-4a: our step-projection "repairable by
replaying" moduledoc claim has no implementation — queued adoptable-now in
[../pms/orca/OR-FIRST-WAVE.md](../pms/orca/OR-FIRST-WAVE.md)). §5
edit-and-resume verified empty at the execution layer (20th subject), and the
plan-layer promote-the-edit precedent now exists **twice** (Chorus + orca's
Accept path — scan observation 1(b) corrected again). The second-wave **bosun**
targeted read also landed 2026-07-04, upgraded to a full dig
([../pms/bosun/FEATURES-WORTH-BORROWING.md](../pms/bosun/FEATURES-WORTH-BORROWING.md)):
§7's two-way-sync rejection is now counterexample-backed (the sync engine was
deleted in production — see the §7 citation above; BO1-4's task-store lessons —
enforce kinds on the resource not the caller, provenance in the same write,
round-trip tests on any external status mapping — join slice 3's schema review);
§12 gains the field's richest phone delivery shapes (BO1-3: immediate-vs-digest
priority split, a per-window live digest edited in place, a pinned
always-current status board — delivery mechanics only, the keyword classifier
stays the anti-pattern) plus the 13-type anomaly taxonomy and the off-process
sentinel watchdog as the infra-degraded reference (BO1-2, the XA1-2 rule
shipped as a process); §5 provisioning gains shared-path symlink
install-avoidance as a per-project policy (BO2-1); the future
resume-past-the-gate design has its field reference (BO1-1: qualification
fences, resume cap, unresumable-reason taxonomy — bosun ships the corpus's only
auto-resume-on-restart); and §4's steering record gains an honest asterisk —
mid-turn injection is shipped in the field exactly once, on bosun's Claude lane
via the agent-SDK streaming-input channel (BO2-4), so the Chorus dig's
"boundary delivery, never mid-turn" softens to "boundary delivery, with one
vendor-SDK-mediated exception"; slice 1's conclusions stand and the
streaming-input mode joins slice 6's CLI-adapter reading list. *(Corrected again
2026-07-06, t3code dig: no longer one exception — t3code folds concurrent sends
into the live turn across all four of its non-codex adapters and codex ships a
first-class `turn/steer`; mid-turn steering is mainstream in the field's newest
peer — [ades/t3code TC2-2](../ades/t3code/FEATURES-WORTH-BORROWING.md).)* §5
edit-and-resume stays empty at subject 21. The **myrlin-workbook** dig
(2026-07-04, upgraded from pattern notes to a full dig) closes the corpus's
planned reads
([../pms/myrlin-workbook/FEATURES-WORTH-BORROWING.md](../pms/myrlin-workbook/FEATURES-WORTH-BORROWING.md)):
§12's `fileConflicts` citation is corrected in place (trigger kept, source's
push wiring dead, detector shapes referenced — MY1-2) and its delivery-rule
list gains myrlin's three storm-tested rules (MY1-3, folded into §12 above);
§5's per-node credential-sync plan gains the corpus's only shipped
multi-machine OAuth reference — the refresh-token **lineage guard**,
rotation write-back, and three-state token health (MY1-1, composing with
SY1-4); §4/§5 worktree templates gain the reconcile-don't-fail collision
posture as a recorded contrast to our `-{n}` counter, plus a third
init-hooks precedent and a second teardown anti-reference
(record-delete-strands, opposite of orca's force-delete — MY2-3); §7's
schema checklist gains the two-terminal-status evidence (two landing paths
⇒ two done-kind statuses — exactly what §10 will produce), a fourth
dead-dependency datapoint, and the enforce-caps-on-the-resource
counterexample (MY2-2); OVERVIEW §4.4's enrollment story gains the QR
ladder reference with its shipped-broken-pairing cautionary and our own
zero-minting-path gap (MY1-4 — do-now: `mix jidoclaw.api_key`); and §5.4's
acceptance criteria gain the severed-consumer test — the field's third
plan-layer promote-the-edit promotes into a record nothing consumes, so
head-promotion must be proven end-to-end at the resumed step's input
(MY2-1). §5 edit-and-resume stays empty at subject 23. The **OpenHelm** dig
(2026-07-04, the corpus's recorded no-dig reversed on operator request —
[../pms/openhelm/FEATURES-WORTH-BORROWING.md](../pms/openhelm/FEATURES-WORTH-BORROWING.md))
closes the pms corpus: §8's breaker citation is dig-verified and sharpened in
place (see §8 above; OH1-1 carries an adoptable-now our-side slice — cron
failures currently have no persisted state, no Trace producer, and
status-blind telemetry), §8's "automation doom-loop budget" gains its shipped
shape (OH2-1: charge-before-call daily ledger, graduated degrade, the
v1-burned-tokens anti-pattern), §12's approval-fatigue design gains the field
survivor (OH1-2: autonomy preset cards × action classes × apply-with-undo —
their dead per-tool numeric scorer answers the classes-vs-scores question in
advance) plus the ended-session grant-execution question our fingerprint-
re-issue consume semantics can't answer alone (their approve executes the
stored payload after the run ended; OQ-2), §12's delivery stack gains the
storm mechanics (infra-incident collapse, guaranteed escalation,
email-on-attention additive at approval-or-priority≥80), slice 6's adapter
reading list gains the structural scheduler deny-list + MCP preflight with
min-tool-count gates (OH2-3/OH2-5), and §5 provisioning gains its sharpest
anti-reference (no worktrees ⇒ runs in the user's real project dir ⇒ the
collision fix was global concurrency 1). Both of the scan's recorded OpenHelm
citations were wrong at HEAD (per-tool risk gate dead, run snapshot
write-only) — the standing run-scope-snapshot idea survives as OH2-4 (TRACK:
detection-before-pin, triggered by composer external-MCP reach or slice 4's
long-lived review gates). §5 edit-and-resume verified empty at **subject 24**,
closing the corpus. Standing questions per repo, with the full-exploration
rule they ride along with: [../pms/DIG-BRIEFS.md](../pms/DIG-BRIEFS.md).

**Late-addition ades digs (2026-07-06)** — three targeted reads fired after
both corpora closed, folded in above where they touch. **t3code** (TC-*) hands
slice 1 its working sync-loop reference (the durable `afterSequence` catch-up
contract + client sync loop, TC1-1 — the moat item it retires is re-graded in
[SYNTHESIS §6](SYNTHESIS.md)), OVERVIEW §4.4 its first *positive* auth
reference (TC1-2), and slice 6 / executor PR-2 their protocol spec (TC1-3),
plus the steering correction noted above (TC2-2). **herdr** (HD-*, AGPL
patterns-only) hands slice 1 the per-agent status rubric (HD1-1..HD1-3 —
[SYNTHESIS §5.1](SYNTHESIS.md)), §12 two delivery rules, §11 the PTY-broker
mechanics (HD2-1), §4 its naming datapoint (HD2-4), and the queued MC1-1 build
the 14-vendor resume argv table (HD2-2). **cmux** (CM-*, GPL patterns-only)
hands §12 two cross-device delivery rules (CM1-4), slice 6 the ask-rule
classifier and the teams-driving cost sheet (CM1-3/CM1-1), OVERVIEW §2.6 its
native-cost evidence (CM2-1), and MC1-1 the restore-argv sanitizer (CM2-3).
The §5 edit-and-resume sweep extended and re-closed **empty at subject 27**
(herdr 25, cmux 26, t3code 27).

**Our-side caveat recorded by the same dig's seams pass (2026-07-04)**: §4
and §10 cite `PullRequestCoordinator` as existing plumbing — the HMAC
webhook ingress is real, but the coordinator itself is unwired scaffolding
today (nothing subscribes to the `"github:webhooks"` PubSub topic, and
`submit_pr` returns a fake URL without calling GitHub —
`github/agents/pull_request_coordinator.ex:87-94`). The landing slice (4)
builds that path real rather than wiring up the stub.
