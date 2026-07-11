# Argus — Decisions of Record

**Snapshot, 2026-07-11.** One line per settled decision, grouped by the
FLOW §13 slice that builds it — no rationale, no evidence trails, no
correction archaeology. This page is a read-model for build kickoff, **not
a fourth decision surface**: [OVERVIEW.md](OVERVIEW.md) (architecture),
[FLOW.md](FLOW.md) (product layer; newest where they disagree), and
[SYNTHESIS.md](SYNTHESIS.md) (the corpus evidence) hold the reasoning and
stay authoritative — when this page and the sources disagree, the sources
win and this page is stale. Refresh it whenever a decision changes. Corpus
IDs (`TR…`, `MC…`, …) resolve via SYNTHESIS §1; bracketed refs point into
the source docs. Items tagged **(lean)** are recorded inclinations, not
commitments. OVERVIEW §7 remains the backend dependency ordering *inside*
these slices.

## Architecture (OVERVIEW)

- Every device runs full JidoClaw; Erlang cluster over Tailscale; libcluster
  `:epmd` strategy with explicit MagicDNS `:cluster_nodes` — never the
  default `:gossip` (multicast doesn't traverse a tailnet). [§2.1]
- One shared Postgres on the always-on desktop; a node that loses the DB
  stops or errors — no local/offline degraded mode, ever. [§2.2]
- Transports: GraphQL (AshGraphql) for queries/mutations; Phoenix Channels
  for live events; channel payloads are minimal (id + change type) with
  client refetch — except workflow topics, which catch up from the durable
  `workflowEvents(afterSeq:)` feed. MCP stays as the third (editor-agent)
  surface; GraphQL resolvers reuse the existing read-models
  (`WorkflowView`, `Observe`, AgentView), never a parallel query layer.
  [§2.4, §4.2]
- Client: React SPA + Apollo + phoenix.js, installable PWA with Web Push;
  a native wrapper only if the PWA fails on live-terminal rendering or
  APNs-class delivery (the named revisit, evidence-based). [§2.6]
- Per-node in-memory state (AgentTracker, Forge.Manager, SessionRegistry)
  is read via `:erpc` fan-out from the gateway node; everything durable is
  DB-projected and needs no fan-out. Historical agent activity comes from
  `Audit.Event`, never a promoted tracker. [§2.5, §4.3]
- Auth: one API key (Bearer / `x-api-key`) on GraphQL and WS connect;
  Tailscale ACLs are the perimeter; scopes get schema room at key-mint
  time, enforcement arrives with the first scoped surface. Config/trust
  mutations stay off the GraphQL surface entirely. [§4.4]
- New `Worktrees` domain; `Worktree` is a facet stacked on `Workspace`
  (never collapsed — non-git workspaces are real); `node` joins Workspace's
  identity keys (the one non-additive edit); `Project` gains `status` +
  `list_active`. [§3.1–3.3]
- No third DAG format: skill YAML is the workflow definition; extensions
  are a strict superset compiled by the one `Skills.Compiler`. [§3.4,
  FLOW §9]
- Runs execute on the worktree's owning node — claim on `worktree.node`,
  a placement policy over the existing lease machinery. [§3.4]
- The LiveView dashboard stays; argus differentiates on decoupled
  lifecycle, phone form-factor, and cluster-wide aggregation. [§4.6]
- Same repo, no restructure: the SPA lives at top-level `ui/`; the Elixir
  app stays at the repo root; pnpm, single package (workspaces only if a
  second JS package becomes real, and inside `ui/`).
  [argus-ui-bootstrap]
- Each node serves the built SPA from `priv/static/argus/` at `/argus` —
  same-origin with `/gql` and `/ws`, no CORS surface.
  [argus-ui-bootstrap]
- Codegen starts basic: `typescript` + `typescript-operations` plugins,
  types only; `typescript-react-apollo` and `client-preset` rejected.
  [argus-ui-bootstrap, §6.3]
- The SDL golden `ui/schema.graphql` is committed and precommit-enforced
  (`mix jidoclaw.graphql.schema` / `.check`) — shipped with P1.
  [argus-ui-bootstrap]
- `mix precommit` stays node-free; the UI gate
  (`pnpm --dir ui typecheck|test|build`) runs when `ui/` is touched.
  [argus-ui-bootstrap]
- The bootstrap GraphQL surface is zero-mutation (reads only, behind
  ApiKeyAuth + a tenant-activity gate); the first mutation (`decideCase`)
  arrives with slice 1. [argus-ui-bootstrap, §4.4]
- The GraphQL runs surface shares Visibility's terminal-disposition
  derivation (`disposition`/`findings_deferred_count` calculations
  delegate to the `run_view/3` derivations — never a parallel read
  model). [argus-ui-bootstrap]

## Product shape (FLOW §1–3)

- Projects = GitHub repos, bare-cloned per participating node (default all
  nodes incl. future joins; subset override is busy-checked) + a read-only
  reference checkout; all git work happens in worktrees.
- Threads = conversations (anchored on `Conversations.Session`); a thread
  holds ≤ 1 worktree, set-once, never swapped; per-thread engine `:native`
  | `:cli`.
- Worktrees are first-class and durable, with a Postgres writer lease —
  one active thread at a time; lease-busy points at the holder, never
  queues silently.
- Tasks are the durable identity of work (per-project kanban); threads and
  worktrees are execution residue.
- Nothing migrates: threads/worktrees/sandboxes pin to one node at
  creation; mobility = create new elsewhere; node-offline is a first-class
  UI state.
- Placement: defaulted, ignorable picker; automations and plain chat
  default to the always-on node; interactive defaults sticky per project;
  sub-things inherit the parent's node; attach-existing is same-node only
  (else a one-click successor thread).

## Slice 1 — attention loop

- Triggers (closed set): agent finished; blocked-on-you (gates + Forge
  `:needs_input`); `ended_blocked`; run failed; infra-degraded;
  `fileConflicts`. Law: no trigger ships without a named, tested producer.
- Delivery stack: transition-edge dedupe; active-surface suppression; deep
  links; per-key debounce; ambiguous states fail toward attention;
  per-kind daily caps; `==`-not-`>=` streak firing; replay suppression on
  reconnect; focus-ack consumes pending state; minimum-signal re-arm
  floor; immediate-vs-digest priority split; re-verify the predicate at
  delivery or drop; blocked-class pierces focus/DND, completion-class
  respects it; presence-gated cross-device forwarding; badge/unread
  projected from the durable ack watermark, never per-device arithmetic.
- The notifier is the gateway layer subscribed to PubSub — never agent
  behavior; the *ask* may ride any channel, the *grant* only enters
  through authenticated non-model surfaces.
- Approvals: single-use `:consume` default; standing grants scoped
  `(kind, project)` with TTL (once / this-thread / this-project-N-days);
  grants visible and revocable; a hard-block never-grantable list always
  asks.
- Agent-list UX: badges on stable order, selection bound to identity;
  status is a small closed enum with honest `unknown` (ranks below idle,
  renders muted); the arbitration fences (generation gating, exit
  fencing, misroute refusal) are invariants.
- Event-feed catch-up acceptance criteria: no mount-pinned cursor, gap
  recovery actually wired (the t3code defects).
- Open: push-subscription wiring; carry-events vs minimal payloads per
  topic (lean: carry on run topics); per-run seq vs global cursor (lean:
  per-run); busy-thread sends queue-vs-fold (lean: both, operator-chosen);
  digest/mute/escalation seams; standing-grant UI details.

## Slice 2 — worktrees

- Provisioning is a lifecycle: create → setup → ready; `setup_status`
  tracked separately from lifecycle `status`; idempotent per-project setup
  steps; secrets materialize from the Vault at setup; a worktree isn't
  offered to a thread until ready.
- Teardown law: phased + dirty-checked + open-PR sweep + records↔worktrees
  reconciliation (gitdir-provenance check before deleting strays; the
  branch survives teardown by default); never delegated to an agent.
- Naming: two per-project templates (branch + directory), `-{n}` collision
  counter on both; sub-worktrees default off the parent.
- Diffs: three jobs — live dirty diff, branch-vs-base, and the `code_diff`
  gate editor; read-only first (annotate-then-reprompt later). File tree +
  viewer read-only, served by the owning node.
- Prerequisite: shell-gate `git worktree` mutations (EM2-3).

## Slice 3 — board & automations

- Tasks are a native Ash resource; a linked GitHub issue is reference-only;
  one-way ingest is a later bolt-on; two-way sync rejected outright.
- Statuses are per-project and fine-grained; lanes display groups of
  statuses; every status carries a system-owned semantic kind (`triage /
  backlog / ready / in_progress / review / done / canceled`); blocked is
  computed from dependencies, never a kind; auto-created tasks land in a
  triage-kind status.
- User automations bind to statuses and lanes; system behavior binds to
  kinds; deterministic multi-fire order (status-bound → lane-bound →
  declaration order); an automation doom-loop budget (no self-re-trigger;
  workflow→workflow depth-capped); every fire records its binding and
  transition.
- Dependency release is queue-then-release (release ≠ start); `canceled`
  terminates without releasing; `depends_on` ships with its release
  semantics or not at all.
- Task ↔ thread is M:N with a strong one-per default (roll-in is the
  explicit exception); one spawn in flight per task, a second queues
  visibly, never drops.
- Status transitions are durable audit rows fusing fact + actor provenance
  (human / workflow / agent) in one row.
- Crons: project-scoped; thread policy new-per-run or same-thread; overlap
  = skip-and-record (per-cron override to queue/concurrent); a persisted,
  classify-before-counting circuit breaker with bounded auto-recovery; a
  trip raises an attention item, never a vanishing row.
- Workflow store: DB rows (Ash resource), global or per-project; schema is
  a strict superset of skill YAML (declared inputs, `run_workflow`,
  thread/worktree ops, task-status moves, `pause_for_review`); versions
  are immutable-append and runs pin their version; execution is
  thread-anchored. Dogfood starts here — argus's own board is the first
  board.
- Open: review-gate YAML key shape; is `ready`-kind the arming bit or is
  arming per-task; the repo-YAML seam (import-copy candidate
  field-validated; decide here or slice 7; argus never writes into repos).

## Slice 4 — landing

- Two paths, chosen per project: PR-centric default (push + GitHub PR; CI
  and merge authority stay on GitHub) and in-argus quick-merge.
- The PR path gates on a `:review` editor over PR title/description — the
  editor family's first shipping use; promote-the-edit on resume; on by
  default, per-project/per-workflow disable.
- Quick-merge (per the 2026-07-07 correction): fast-forward = a fenced CAS
  `update-ref`; true merge = `git merge-tree --write-tree` (git ≥ 2.38) +
  `commit-tree` + the same fenced update; conflicts never land
  platform-side — resolution is agent work in the source worktree, or fall
  back to the PR path.
- Landing attribution rides the gate: a pre-checked, adjustable task
  checklist; confirmed tasks get PR-linked for webhook auto-advance
  (quick-merge advances immediately); taskless landings legal; nothing
  inferred. Pre-merge review surfaces deletions merge-base three-dot.
- Staleness model: `clean | dirty | colliding`; approval stales when the
  parent moves; the judge re-runs after *any* catch-up.
- `PullRequestCoordinator` is unwired scaffolding today — this slice
  builds the path real, not the stub wired up.
- Open: OH2-4 run-scope snapshot (TRACK; triggered by long-lived review
  gates or composer external-MCP reach).

## Slice 5 — fan-out

- Sub-worktrees fork off the parent branch's committed HEAD (commit-first;
  uncommitted work never carries over); sub-threads/sub-worktrees carry
  parent links, inherit the parent's node, and are depth-capped.
- Spawn paths: operator UI and workflow steps spawn freely; the parent
  agent's spawn tool is approval-require-listed (livable via standing
  grants) and capped.
- Merge-back is agent work, not platform mechanics: the platform emits the
  attention item; the parent's agent (lease holder) runs the gated
  `merge_child` tool; conflicts become agent work; no system actor ever
  mechanically merges into a live worktree. PRs stay reserved for landing
  on primary.

## Slice 6 — CLI engine

- `:cli` threads run the vendor CLI inside a Forge sandbox on the thread's
  node, piped to the UI. One rendering path: the adapter normalizes the
  vendor stream into the same transcript rows and durable events as
  `:native`; redaction at the durable sink; synthetic scaffolding dropped
  structurally by event type, before redaction.
- Trust is structural first: no GitHub credentials in the sandbox; egress
  allowlist = LLM APIs + our MCP endpoint only; git `origin` = the
  node-local bare repo; push/PR/web reach exist only as gated JidoClaw MCP
  tools. Vendor ask-rules bridge into the `AgentCase` inbox as
  defense-in-depth, tuned sparse.
- New plumbing: an HTTP MCP endpoint reachable from sandboxes,
  deny-by-default — a per-thread tool allowlist bound into a per-session
  token (auth + scope + identity, dead at session end); host-executing
  tools structurally unreachable from sandboxes.
- Adapter shape: a small behaviour over headless CLI + stream-json +
  resume-by-session-id; per-vendor resume argv from the banked 14-vendor
  table; restore argv sanitized (prompts and trust bypasses never replay);
  interrupt taxonomy (`user`/`crash` provenance gates resume).
- Workflows stay native-engine-only for now; a CLI-turn step kind has
  schema room but is explicitly later.
- Open: gate-timeout polarity for vendor-intercepted approvals (lean:
  soft-wait where a live PTY fallback surface exists, durable-hold for
  headless); teams-driving default no (subscription-lane plan PROPOSED,
  not queued).

## Slice 7 — workflow visual editor

- react-flow UX over the by-then-stable workflow schema (nodes = steps,
  edges = `depends_on`); YAML authoring + import/export works from the
  moment the store exists; deliberately late so the schema stabilizes
  before the editor freezes it visually.

## Slice 8 — operator terminal

- Per-worktree PTY, brokered by the owning node over the authed WebSocket;
  operator-only and never model-reachable (the model's shell path remains
  gated `run_command`/Forge); auth via per-session short-lived UI-minted
  tokens, never the standing key; argus's strictest-tier endpoint.
- Mechanics: reattach = current-state redraw (never byte replay); bounded
  server-side scrollback; single-slot latest-wins render lane per client;
  size follows the active viewer.

## The editor family (OVERVIEW §5)

- Declaration: `pause_for_review` as a skill-step annotation compiled by
  `Skills.Compiler` into an interposed `:review` gate (same
  `GateStep`/`AgentCase` machinery); a catalog gate stage for composer
  routes; no new definition format.
- Registry stays deliberately short: `markdown`, `code_diff`, `json`,
  `prompt`, `command_list`, `none`; adding one is a coordinated
  YAML/gate/client change. Markdown ships first (the thrice-validated
  entry point); slice 4's PR-metadata gate is the first shipping use.
- The ONE gate-family behavior change in all of argus: resume promotes the
  head revision (the operator's edit if any, else the original) instead of
  re-emitting the original.
- Revision payloads live in the encrypted ref-store (`art_…`-style refs);
  a revision event is appended; the projection updates the step-output
  head; the original survives in the log.
- `expectedSeq` optimistic concurrency checked under the existing
  FOR-UPDATE seq allocation; mismatch = typed `stale_revision` carrying
  the current seq.
- Server-side validation per editor type, returned as GraphQL field
  errors (lean). `:review` stays distinct from `:plan` initially (lean;
  revisit once editors are real).
- Structured review payloads follow the OR1-1 verdict-schema reference
  (anchors in the schema, validation at the boundary, anchor-fidelity
  taxonomy).
- Novelty, stated honestly: execution-layer head-promotion is unique
  across the 27-subject sweep; the plan-layer variant ships three times,
  all promote-verbatim.

## Cross-slice invariants

- The eight gate acceptance axes [SYNTHESIS §5.2]: approve-idempotency
  fence (keep ours); revision history (event log + ref-store); restart
  durability; case expiry/TTL; gate timeouts fail closed
  (vendor-intercepted polarity is the slice-6 open); the severed-consumer
  test — prove the resumed step consumes the head revision's *bytes*;
  `expectedSeq` mechanics as above; conflict-recovery UX keeps the
  operator's buffer, absent `expectedSeq` is a validation error, machine
  rewrites ride the same check.
- Every declared trigger and dependency edge ships with its consumer
  (named-tested-producer law; release semantics with `depends_on` or no
  edges at all).
- Advertisement without mechanical enforcement rots — pin served surfaces
  with goldens. Realized for GraphQL (P1, 2026-07-11): `ui/schema.graphql`
  + `mix jidoclaw.graphql.schema.check` in precommit; the MCP surface
  golden preceded it.
- License discipline: patterns/rubrics/schemas only from AGPL (termic,
  Chorus, myrlin, herdr), GPL (cmux), BUSL (OpenHelm), and
  modified-Apache (multica) subjects; code only from MIT/Apache-clean
  subjects.

## Explicitly rejected

- Two-way GitHub issue sync (deleted-in-production counterexample).
- Any second workflow-definition format or parallel DAG engine.
- A local/offline degraded mode when the shared DB is unreachable.
- JSON:API for the query surface; a native iOS app for v1.
- RBAC / per-device keys / rotation tooling for v1 (tailnet ACLs are the
  perimeter; the scoped-key upgrade path is reserved, not built).
- "Blocked" as a task status kind (computed from dependencies only).
- Startup auto-upgrade backfill of imported workflow definitions
  (import-copy + explicit re-import instead).
- System-mechanical merges into live worktrees (merge-back is agent work).
- Replacing the LiveView dashboard.
- SSH workers as the cross-node mechanism (Erlang distribution is the
  fabric).

## Standing riders

- Pre-argus do-now queue: SYNTHESIS §7 (argus-independent; several items
  have already shipped — verify against the tree, not this page).
- Decided-after-death (who executes a grant decided after the run ended):
  answer per gate kind when phone approvals land.
- TRACKs: speaking ACP; resume-past-the-gate (BO1-1); the PWA-vs-native
  revisit; paired turn rewind (TC2-1); provider-instance registry (TC2-4).
