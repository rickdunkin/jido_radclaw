# Argus — Unified Control Plane for Multi-Agent JidoClaw

Exploration notes — not a plan, not a commitment. Codename `argus` (Greek myth: hundred-eyed watcher) — settled: [FLOW §13](FLOW.md) keeps it, and sibling docs already cite the program by this name. Compared against jido_radclaw as of 2026-07-03.

## How to read this document

The body is architecture-level: vision, decisions, data-model implications, API surface plan, and the novel "step-type-specific editors" feature. The appendix holds the file:line audit of the current state — useful when you sit down to build, skippable on first read.

Each "where we landed" subsection records a decision made during the exploration. The "open questions" section collects everything we explicitly deferred.

**Product-flow companion**: [FLOW.md](FLOW.md) is the living product-layer draft — threads (per-thread engine, CLI-as-Forge-session), the worktree lease/provisioning model, the nothing-migrates node doctrine, the task/kanban layer (answering pms observation 6), the workflow store, landing and fan-out flows, cockpit surfaces, and v1 sequencing. Where it and this doc disagree, FLOW.md is newer.

**Research companion**: [SYNTHESIS.md](SYNTHESIS.md) (2026-07-05) rolls up the closed [ades](../ades/README.md) and [pms](../pms/README.md) corpora by argus concern — what the field validated, what it corrected, the composite checklists (the attention/delivery stack, the §5.4 gate acceptance criteria, the worktree teardown law, the health shelf), the merged pre-argus do-now queue, and the open-question register. The corpus IDs cited piecemeal through this doc (`TR…`, `EM…`, `CC…`, `XA…`, `MC…`, …) appear there assembled.

**Decisions snapshot**: [DECISIONS.md](DECISIONS.md) (2026-07-07) — every settled decision across this doc and FLOW on one page, grouped by build slice, no correction archaeology. Start there; come back here for the reasoning.

---

## 1. The Vision

A unified control plane for multiple JidoClaw agents running across multiple devices on a private Tailscale tailnet. The operator (one person, possibly on a phone) wants to:

1. **See all active projects** across every agent in the tailnet.
2. **For each project, see all active worktrees** — the parallel pieces of work in flight (different branches, different sandboxes, different agents).
3. **Drill into a worktree** to see what is currently happening (live activity feed) and what has happened so far (history).
4. **Run workflows with human-in-the-loop checkpoints** — pause between steps, review the step's output, *edit it*, and resume so the edited version flows into the next step.

The control plane is not LiveView. It is a decoupled client that speaks to *any* JidoClaw node and gets a unified, cluster-wide view back.

---

## 2. Where We Landed — Architecture

### 2.1 Backend topology: clustered JidoClaw nodes over Tailscale

Each device runs a full JidoClaw instance. The instances form an Erlang cluster over Tailscale using libcluster. Tailscale's MagicDNS gives stable hostnames and the network layer handles auth, which is exactly the configuration where Erlang distribution shines.

The cluster layer is real, not aspirational: `:cluster_enabled` starts libcluster plus a leadership stack (a dedicated `:pg` scope and `JidoClaw.Cluster.Leader`), and the clustering program (`docs/plans/clustering/`, WS1–WS5) covers run leases with CAS fencing, reclaim & recovery of runs from dead nodes, leader election + singleton audit, clustered cron ownership, and cross-node cancellation. WS6 — multi-node validation — explicitly waits on the argus second node, so argus is the forcing function for exercising all of it outside tests. One placement note: `:cluster_strategy` defaults to `:gossip`, which depends on UDP multicast and will not traverse a tailnet; for Tailscale, configure the `:epmd` strategy with an explicit list of MagicDNS node names (`:cluster_nodes`).

### 2.2 Database: shared Postgres on an always-on desktop

One device hosts Postgres; all JidoClaw nodes connect to it. Daily backups on the host. This unifies persisted data — Projects, Workspaces, Worktrees, Conversations, WorkflowRuns, Memories, Knowledge, Audit — across the cluster automatically.

**Tradeoff acknowledged**: the desktop becomes a hard dependency. A laptop that drops off the tailnet loses DB access and effectively cannot run JidoClaw. This is acceptable for the use case (always-online tailnet, agents that need shared memory anyway), but is the single biggest fragility in the design. Node loss for in-flight *runs* is handled separately (leases + reclaim, appendix A.6); the DB is the remaining single point of failure.

**Offline behavior**: when a node loses DB access, it exits or returns an offline error to any incoming request — *no* local-only degraded mode. The shared DB is the system of record; operating without it would split-brain memory and audit. Easier to recover from "everything just stops" than from divergent state.

### 2.3 UI transport: HTTP + WebSocket, not Erlang distribution

The control-plane client connects to *any* JidoClaw node over HTTP/WebSocket. Reasons:

- **Phone clients can't be cluster members.** This alone forces a wire-protocol API.
- **Decoupled lifecycle.** The client can ship and update independently of agent nodes.
- **Polyglot future.** A native iOS app, a Tauri desktop app, a web PWA — all are possible from day one with a wire protocol; none are with `:erpc.call`.

The client connects to one node; that node serves as the gateway for cluster-wide data. Phoenix.PubSub is cluster-aware out of the box (PG2 adapter), so a subscription on the gateway node receives broadcasts from any node.

### 2.4 API surface: GraphQL for queries/mutations, Phoenix Channels for live

**GraphQL (AshGraphql)** for the read/write surface. The UI is deeply hierarchical (project → worktrees → sessions → messages, with workflow runs grafted on) and varies per screen — exactly what GraphQL was designed for. JSON:API was the alternative considered; rejected because deep nested includes get brittle and per-screen sparse fieldsets are verbose. AshGraphql also gives best-in-class TypeScript codegen for the client, which matters disproportionately on a small team.

**Phoenix Channels** for the live event layer. AshGraphql supports subscriptions but Channels are more battle-tested, the forge subsystem already broadcasts via Phoenix.PubSub, and using Channels keeps a single live transport regardless of how the query layer evolves.

A third surface exists and stays: **MCP**. The stdio server already exposes workflow observe/control tools (`workflow_status`, `inspect_workflow`, `workflow_events`, `replay_workflow`) plus the `jido://workflows/catalog` and `jido://workflows/{name}` resources — the right surface for editor-embedded agent clients, and proof the read-models exist. It is not the control-plane transport (no phone client, no typed cache, no subscription fan-out), but the GraphQL resolvers should reuse the same view modules those tools read (`WorkflowView`, `RouteComposer.Observe`) rather than growing a parallel query layer.

Two client-facing transports, each used for what it's best at: GraphQL for "fetch this tree of data" and "perform this action," Channels for "tell me when X changes."

### 2.5 Cross-node concerns: fan-out for in-memory state

Shared Postgres unifies *persisted* data — and because workflow state is event-sourced (appendix A.4), even live run/wave/gate state is DB-projected: answering "what is this workflow doing right now" needs no fan-out. Human approvals are durable `AgentCase` rows, likewise fan-out-free. What remains genuinely per-node and in-memory: `AgentTracker` (GenServer state — live agents, current tool, in-flight tokens), `Forge.Manager` state, `JidoClaw.SessionRegistry`, and shell sessions. "What is each node doing right now?" queries over those need cross-node fan-out via `:erpc.multicall` or `Task.Supervisor.async_stream` over `Node.list()`. The gateway node aggregates and returns.

### 2.6 UI client: React + Apollo Client

The control-plane UI is a React web app served as a static SPA, talking to any node's gateway. **Apollo Client** handles GraphQL queries and mutations with a typed, normalized cache; **Phoenix Channels** (via `phoenix.js`) handle live subscriptions. TypeScript types are generated from the AshGraphql schema via codegen — settled (2026-07-10, argus-ui-bootstrap): `@graphql-codegen/cli` with the basic `typescript` + `typescript-operations` plugins, generated types only; `typescript-react-apollo` and `client-preset` explicitly rejected (Apollo recommends against both). The generator reads the committed SDL golden (`ui/schema.graphql`, precommit-drift-guarded since P1). Hosting is also settled: **each node serves the SPA** from `priv/static/argus/` at `/argus` — same-origin with `/gql` and `/ws`, so no CORS surface exists (the SPA lives at top-level `ui/` in this same repo; see `docs/plans/argus-ui-bootstrap/README.md`).

PWA installability is a low-cost addition that makes the app feel native on a phone (add-to-home-screen, full-screen, offline shell). Push notifications use the Web Push API where supported, including iOS 16.4+ for installed PWAs. Native iOS push via APNs is out of scope for v1; if it becomes required, wrap the React app in Tauri or Capacitor rather than rebuilding.

*(Evidence note, 2026-07-06)*: the native alternative is now priced by the field — cmux's iOS companion, the corpus's only shipped native terminal client, costs ~75k LOC of Swift across 15+ packages, four cloud services (a hosted auth provider, a device-registry/APNs API, a presence worker, APNs itself), a mandatory VPN data plane, and a second release pipeline ([ades/cmux CM2-1](../ades/cmux/FEATURES-WORTH-BORROWING.md)); t3code ships native APNs via a relay and no PWA at all ([ades/t3code TC2-6](../ades/t3code/FEATURES-WORTH-BORROWING.md)). The two things native buys that a PWA cannot: terminal-grade on-device rendering of a live mirror, and APNs-class background delivery. The PWA choice stands, now evidence-based rather than cost-led; those two datapoints are the revisit's reading list.

Node ownership is surfaced in the UI wherever it's operationally relevant — worktree lists show which machine holds the checkout, agent and forge runtime views show which node hosts the process. Useful for debugging across machines.

---

## 3. Data Model Changes Required

### 3.1 New `Worktrees` domain with a `Worktree` resource

Worktree is **not** an existing concept in JidoClaw. The closest existing thing (`Workspaces.Workspace`) maps one tenant to one path; it doesn't model the multiple-branches-in-flight pattern that real parallel work requires.

**Why a new `Worktrees` domain rather than nesting under `Projects`:**

- Matches the codebase convention. JidoClaw groups domains by bounded context, not hierarchy: `Workspaces`, `Conversations`, `Forge`, `Orchestration`, `Audit` are all standalone even though they reference `Projects`. `Projects` is a single-resource metadata domain — meant to stay focused.
- Worktree is operationally heavy (shell side-effects via `git worktree add/remove`, node-affinity, lifecycle status) and is the natural parent for likely future siblings: per-worktree sandbox metadata, per-worktree memory partitions, attached background processes. All want to live in a domain together.

Cross-domain `belongs_to :project` works fine in Ash 3.

> **External reference (2026-07-03)**: design this resource with the traycer dig open — [ades/traycer TR1-3/TR1-4, TR2-1/TR2-2](../ades/traycer/FEATURES-WORTH-BORROWING.md): setup-state telemetry (a six-state `setup_status` distinct from lifecycle `status`), `origin: :created | :imported`, computed-never-persisted disk-truth, clone-not-migrate node affinity, busy-checked phased deletion, committable per-repo environment scripts.
>
> **FLOW additions (2026-07-04)**: [FLOW §5–§6](FLOW.md) extend this sketch — a **writer lease** (at most one active thread at a time, acquired and released in Postgres, never in node memory), a **parent link** for sub-worktrees (forked off the parent branch's committed HEAD, node-inherited, depth-capped), and the provisioning lifecycle (create → setup → ready, `setup_status` tracked separately from lifecycle `status`). Build from FLOW's shape, not this sketch alone.

Proposed shape:

```elixir
defmodule JidoClaw.Worktrees do
  use Ash.Domain
  resources do
    resource JidoClaw.Worktrees.Worktree
  end
end

defmodule JidoClaw.Worktrees.Worktree do
  use Ash.Resource,
    domain: JidoClaw.Worktrees,
    data_layer: AshPostgres.DataLayer
  
  attributes do
    uuid_primary_key :id
    attribute :branch, :string, allow_nil?: false
    attribute :status, :atom,
      constraints: [one_of: [:active, :idle, :archived]],
      default: :active
    attribute :node, :string, allow_nil?: false   # which JidoClaw node owns this checkout
    attribute :last_activity_at, :utc_datetime_usec
    timestamps()
    # path lives on the underlying Workspace
  end
  
  relationships do
    belongs_to :workspace, JidoClaw.Workspaces.Workspace, allow_nil?: false
    belongs_to :project, JidoClaw.Projects.Project, allow_nil?: false
    has_many :workflow_runs, JidoClaw.Orchestration.WorkflowRun
    has_many :forge_sessions, JidoClaw.Forge.Resources.Session
    # conversation sessions reach via :workspace (they belong_to :workspace)
  end
  
  actions do
    defaults [:read, :destroy]
    create :create
    update :archive
    read :list_active do
      filter expr(status == :active)
    end
    read :by_project do
      argument :project_id, :uuid, allow_nil?: false
      filter expr(project_id == ^arg(:project_id))
    end
  end
end
```

Implications:
- Worktree wraps a Workspace and adds project + git semantics. It does not replace Workspace — see §3.3 for why we stack rather than collapse.
- The path lives on `Workspace.path`; Worktree adds branch/status/node/git semantics. Conversation messages, memory, audit, solutions all continue to hang off Workspace; the UI surfaces them through `worktree.workspace.conversation_sessions`.
- The `node` field is critical because the *checkout itself* lives on one machine, even though the cluster shares the DB. Cross-node operations on a Worktree need to RPC to its owning node.
- `git worktree add`/`remove` are real shell ops; the resource should orchestrate them via a tool/action, not pretend they're free.

### 3.2 `Projects.Project` enhancements

Today: `id`, `name`, `github_full_name`, `default_branch`, `settings`, timestamps, plus a `code_interface` for CRUD and `get_by_github_full_name`. No "active" concept, no scoped list.

Add:
- `attribute :status, :atom, constraints: [one_of: [:active, :archived]], default: :active` (or `archived_at` for soft-delete style).
- `read :list_active` on the resource, with a matching `code_interface` entry so `Projects.list_active!()` is a one-liner.
- `has_many :worktrees, JidoClaw.Worktrees.Worktree`.

### 3.3 Workspace and Worktree stack rather than collapse

Worktree is git-shaped; Workspace is not. The two model different concerns and neither subsumes the other.

**What Workspace is**: a tenant-scoped, durable anchor for *operating in a directory*. It carries identity (`tenant_id + path + optional user_id + optional project_id`), memory-egress policy (`embedding_policy`, `consolidation_policy`, with cross-row aggregates in `Workspaces.PolicyTransitions`), and a dual-identity quirk — the same path can have separate rows for an authed user and for anonymous CLI use (`workspace.ex:245-251`). It is the parent UUID for `Conversations.Session`, `Solutions.Solution`, `Reasoning.Outcome`, `RequestCorrelation`, and the polymorphic target for `Audit.Event`. It is bootstrapped lazily from 7+ surfaces (REPL, web RPC, shell, MCP, network node, mix tasks) via `Workspaces.Resolver.ensure_workspace/3` — none of which require a git checkout. The CLI running in `/tmp/scratch` creates a real Workspace.

**Why collapsing fails**: forcing every working directory to be a git worktree excludes the non-git cases above; alternatively, watering down "Worktree" until it accepts non-git directories makes the name misleading and loses the value of having a focused project + git facet.

**The stack**:

- `Workspace` is the directory anchor, memory/audit parent — present whenever an agent operates in a directory. Gains a `node` field so cluster-aware queries route correctly without relying on path-existence checks at query time.
- `Worktree belongs_to :workspace, allow_nil?: false` and `belongs_to :project, allow_nil?: false`. It is a *facet* on Workspace, present only when the workspace is a managed git checkout under a known Project.
- A Workspace can exist without a Worktree (CLI, non-git, scratch). A Worktree always has exactly one Workspace. `Workspace has_one :worktree`.
- Path lives on Workspace; Worktree adds `branch`, `status`, `last_activity_at`. Both carry `node`, because both anchor data tied to a specific machine's filesystem. Use the lease layer's identity convention — `WorkflowLease.node_identity/0`, which is `to_string(Cluster.local_node())` (the `Cluster` wrapper, not raw `Node.self()` — corrected 2026-07-03), the same value `WorkflowRun.claimed_by` stores — so node comparisons work across subsystems.

This stays mostly additive: a new `node` column on Workspace, populated automatically by `Workspaces.Resolver.ensure_workspace/3` (which sets `node: Cluster.local_node()`) — none of the 7+ bootstrap surfaces need to change. Existing rows backfill trivially from the current node since the system is single-node today. No policy refactor. **One non-additive edit hides here (2026-07-03)**: Workspace's partial-unique identities are `(tenant_id, user_id, path)` / `(tenant_id, path)` (`workspace.ex:245-251`), so the same path checked out on two machines would collide — `node` must also join the identity key lists, the `identity_wheres_to_sql` partial-index SQL (`workspace.ex:28-31`), and the resolver's upsert attrs, not just the attribute block.

> **External reference (2026-07-04, Chorus dig)**: [pms/chorus CH1-4](../pms/chorus/FEATURES-WORTH-BORROWING.md) — the schema reference for these node columns: split instance *identity* from *liveness*, fence with a generation counter, and refuse conflicting registrations outright rather than last-write-wins; the placement composite is assembled in [SYNTHESIS §5.7](SYNTHESIS.md).

For the UI: `Project.has_many :worktrees`, drill into a Worktree, list activity via `worktree.workspace.conversation_sessions`. Workspace is invisible to the operator but does the work underneath. The `Workspace.project_id` field — currently nullable and inconsistently populated — should be kept in sync with `worktree.project_id` when a Worktree exists, so project-scoped queries can reach Workspace-anchored data without always going through Worktree.

### 3.4 The execution substrate — what exists, and the delta argus needs

**Workflows and Skills converged rather than separated.** Skills (`.jido/skills/` YAML — `name`, `template`, `task`, `depends_on`, `produces`, `consumes`) are the workflow definitions: `Skills.Compiler` compiles a skill into an `%Reactor{}`, and `ReactorRunner` + `ReactorMiddleware` execute it inside a durable envelope shared by every run — cron-triggered runs and composer waves alike. There is no separate workflow YAML format, and argus should not introduce one (§5.2).

The substrate is event-sourced (details in appendix A.4):

- **Durable spine.** Every run appends to an immutable `WorkflowEvent` log; `WorkflowRun.status` and `WorkflowStep` rows are *projections* of that log — the only status writer lives inside the event-append transaction. Runs carry encrypted resume checkpoints and replay inputs; `Replay` can re-run any terminal run from its stored inputs, behind safety gates (definition-hash drift, irreversible steps).
- **Gate family.** A `GateStep` halts a run `:awaiting_approval` and opens a durable `AgentCase` (workflow-axis kinds `:plan` and `:irreversible_write`; the conversation-axis tool-approval gate uses `:tool_call`). Operators decide through `Cases.decide/4` from the REPL (`/gates`) or the web (`/approvals`); on approve, `GateResume` re-runs the persisted checkpoint, seeding only the decision atom.
- **Composer.** `RouteComposer` is the multi-wave orchestration loop on top of the Reactor envelope: a compile-time stage catalog (`%Stage{}` with data + signal graphs, locks, and per-stage model/effort tiers), Kahn-level waves, a parent "composer" run plus one child run per wave, an encrypted `art_…` artifact ref-store (`ComposerArtifact`), and full observability (held/dropped stages, live signals, gate-block state) over MCP.
- **Leases.** Single-writer-per-run is enforced, not assumed: `WorkflowRun.claimed_by`/`claim_token` with CAS stamping, commit-time token fencing, and reclaim/recovery of runs whose node died.

**The delta argus needs from this substrate** — this is the actual backend work, and it is small relative to what exists:

1. **An edit path at gates.** Today gates are approve/reject/abandon only: declared gate fields fold into a free-text `decision_comment`, and the plan gate re-emits the *original* artifact from its encrypted ref, unchanged. The reviewable-editor feature (§5) needs a `:review` gate kind whose resume promotes the *head revision* — the operator's edit if one exists, else the original.
2. **Per-step review checkpoints.** Gates are standalone stages wired per-reactor; a `pause_for_review` annotation on any skill step, compiled into an interposed review gate, makes checkpointing declarative.
3. **Channel-layer streaming.** Run lifecycle and gate events broadcast on `Orchestration.RunPubSub` (since the P4 remediation composer parents publish their own start/terminals too — family-kind broadcasts from `RouteComposer`, not `ReactorMiddleware`), and P4's `WorkflowsChannel` proxies the lifecycle to the SPA; per-step transitions still exist only in the durable event log — projecting those to subscribers is the remaining delta.
4. **Worktree node-affinity.** A run operating on a checkout must execute on the machine that has it. The lease machinery already records the claiming node; argus adds the placement policy — claim on `worktree.node` — same constraint as Forge sandboxes and direct tool execution.

**Where the runner runs**: on the worktree's owning node, per delta 4. This preserves the existing single-writer guarantee (leases), and Phoenix.PubSub guarantees FIFO delivery cluster-wide from a single publisher — so subscribers see transitions in order without consumer-side reordering. No cluster-wide process registry needed.

---

## 4. API Surface Plan

### 4.1 GraphQL schema sketch (AshGraphql)

The Ash resources from §3 plus the existing ones map to a GraphQL schema. Sketch (not final):

```graphql
type Project {
  id: ID!
  name: String!
  githubFullName: String
  defaultBranch: String
  status: ProjectStatus!
  worktrees(filter: WorktreeFilter, limit: Int): [Worktree!]!
}

type Worktree {
  id: ID!
  branch: String!
  status: WorktreeStatus!
  node: String!
  lastActivityAt: DateTime
  project: Project!
  workspace: Workspace!
  path: String!   # convenience; resolves through workspace.path
  conversationSessions(filter: SessionFilter): [ConversationSession!]!  # via workspace
  workflowRuns(filter: WorkflowRunFilter): [WorkflowRun!]!
  forgeSessions(filter: ForgeSessionFilter): [ForgeSession!]!
}

type Workspace {
  id: ID!
  path: String!
  node: String!
  embeddingPolicy: EmbeddingPolicy
  consolidationPolicy: ConsolidationPolicy
  archivedAt: DateTime
  worktree: Worktree
  conversationSessions(filter: SessionFilter): [ConversationSession!]!
}

type ConversationSession {
  id: ID!
  closedAt: DateTime
  workspace: Workspace!
  messages(after: Int, limit: Int): MessageConnection!
}

type Message {
  id: ID!
  sequence: Int!
  role: MessageRole!
  content: JSON!
  insertedAt: DateTime!
}

type WorkflowRun {
  id: ID!
  name: String!
  status: WorkflowRunStatus!
  startedAt: DateTime
  worktree: Worktree
  parentRun: WorkflowRun          # composer lineage
  childRuns: [WorkflowRun!]!
  steps: [WorkflowStep!]!
  pendingCase: AgentCase          # the gate blocking this run, if any
}

type WorkflowStep {
  id: ID!
  sequence: Int!
  name: String!
  status: WorkflowStepStatus!
  output: JSON                    # projection head — reflects operator revisions
  outputRevisions: [StepOutputRevision!]!
}

type AgentCase {
  id: ID!
  kind: CaseKind!                 # PLAN | IRREVERSIBLE_WRITE | TOOL_CALL | REVIEW
  status: CaseStatus!
  title: String
  editor: EditorType              # for REVIEW cases (§5)
  targetStep: WorkflowStep
  decisionComment: String
}

type StepOutputRevision {
  version: Int!
  output: JSON!
  editedBy: User
  editedAt: DateTime!
}

enum WorkflowRunStatus { PENDING RUNNING AWAITING_APPROVAL COMPLETED FAILED CANCELLED ABANDONED }
enum WorkflowStepStatus { PENDING RUNNING COMPLETED FAILED SKIPPED }

# Top-level queries
type Query {
  projects(filter: ProjectFilter): [Project!]!
  project(id: ID!): Project
  worktree(id: ID!): Worktree
  workflowRun(id: ID!): WorkflowRun
  workflowEvents(runId: ID!, afterSeq: Int, limit: Int): WorkflowEventPage!  # durable feed; reconnect catch-up
  auditEvents(filter: AuditEventFilter): [AuditEvent!]!   # source of agent activity history
  cluster: ClusterStatus!                                  # cross-node fan-out
}

# Mutations
type Mutation {
  startWorkflowRun(input: StartWorkflowRunInput!): WorkflowRunPayload!
  reviseStepOutput(input: ReviseStepOutputInput!): WorkflowStepPayload!  # appends a revision event
  decideCase(input: DecideCaseInput!): AgentCasePayload!                 # approve resumes; reject cancels; abandon parks
  cancelWorkflowRun(input: CancelRunInput!): WorkflowRunPayload!
  replayWorkflowRun(input: ReplayRunInput!): WorkflowRunPayload!
  archiveWorktree(input: ArchiveWorktreeInput!): WorktreePayload!
}

input ReviseStepOutputInput {
  stepId: ID!
  output: JSON!
  expectedSeq: Int!  # run's event-log seq at read time — checked inside the append's FOR-UPDATE txn (§5.4 correction note)
}
```

Most of this is generated by AshGraphql from the resource definitions; the manual surface is the queries/mutations exposed and any custom field resolvers (e.g., `cluster` for the cross-node fan-out). Note that `WorkflowStep` is a projection — `reviseStepOutput` appends an event rather than mutating the row (§5.4), and `decideCase` wraps the same `Cases.decide/4` the REPL and LiveView use.

### 4.2 Phoenix Channels (live layer)

| Channel topic | Source | Status |
|---|---|---|
| `forge:sessions` | `JidoClaw.Forge.PubSub` | Already broadcast; needs channel proxy |
| `forge:session:<id>` | `JidoClaw.Forge.PubSub` | Already broadcast; needs channel proxy |
| `worktrees:project:<project_id>` | New PubSub topic | Broadcast on Worktree create/update/archive |
| `conversations:session:<id>` | New PubSub topic + bridge from SignalBus | Bridge `Conversations.Recorder` to also broadcast |
| `workflows:run:<id>` | `Orchestration.RunPubSub` (run lifecycle — published by `ReactorMiddleware` for reactor runs, by `RouteComposer` itself for composer parents since the P4 remediation) | **Implemented (P4, 2026-07-11)**: lifecycle proxy live over the key-only `ArgusSocket` (`WorkflowsChannel` — minimal `{id, kind}` pushes + a `{id, status}` join reply; [docs/system/channels-surface.md](../../system/channels-surface.md)). Per-step deltas exist only in the `WorkflowEvent` log — still slice 1 (project them to subscribers, or add a broadcast in the event-append path) |
| `workflows:project:<project_id>` | New aggregated topic | For the project-level workflow list |
| `gates:user:<user_id>` | `Orchestration.RunPubSub` gates topic | Already broadcast (ApprovalsLive consumes); needs channel proxy + per-user filter |
| `cluster:nodes` | New | `:net_kernel.monitor_nodes/1` → broadcast |

Channel events carry minimal payloads (resource id + change type). The client refetches via GraphQL using the id. This avoids duplicating shape between the channel payload and the GraphQL schema.

On reconnect, workflow topics catch up from the durable event feed — the `workflowEvents(afterSeq:)` query pages the same append-only log the `workflow_events` MCP tool reads, so nothing is lost while offline. Other topics simply refetch current state via GraphQL; no sequence tracking on the wire. Workflow runs are single-writer (leases, §3.4), so events arrive in order while connected.

### 4.3 Plain controllers / GraphQL fields for non-Ash, runtime/cluster data

Some data isn't backed by Ash resources — per-node in-memory state, YAML skills, cluster topology. Two options: bespoke Phoenix controllers, or generic Ash actions on a synthetic `System` resource exposed through GraphQL. The latter keeps the client surface uniform (one transport for queries) at the cost of a slightly contorted resource:

- `cluster: ClusterStatus` — node list, current leader (`Cluster.Leader`), version + uptime per node. Implementation: `:erpc.multicall` fan-out.
- `agentRuntime: [NodeAgentSnapshot!]!` — per-node `AgentTracker` snapshot for **live** state only (currently running agents, current tool, in-flight tokens). Fanned out and merged via `:erpc.multicall`; the tracker's scoped view projections (AgentView) are the read-model to expose. **Historical** agent activity is sourced from `Audit.Event` aggregations via the regular AshGraphql side — `AgentTracker` stays in-memory per-node and is not promoted to a DB-backed resource.
- `forgeRuntime: [NodeForgeSnapshot!]!` — per-node `Forge.Manager` state.
- `skills: [Skill!]!` — list YAML skills available on each node (skills are not DB rows).
- `runSkill(input: RunSkillInput!): SkillRunPayload!` — kick a skill on a chosen node (the MCP `run_skill` tool does this for the local node; the GraphQL mutation adds node targeting).

Lean: GraphQL via synthetic resources for uniformity. The fan-out implementation lives in custom resolvers.

### 4.4 Auth

A single API key authenticates both the GraphQL endpoint and the WebSocket, validated by the existing `JidoClaw.Web.Plugs.ApiKeyAuth` (Bearer / `x-api-key`) against an Ash user. Extend `UserSocket` to accept the same key alongside its current Ash session auth.

*(Implemented, 2026-07-11 — argus P1)*: `/gql` is live behind `ApiKeyAuth` **plus a tenant-activity gate** (`JidoClaw.Web.Plugs.GraphqlTenantGate`: a suspended tenant's valid key gets 403, activity-check infra failure 503 — necessary because `Project` is a global resource whose policy alone would serve a suspended tenant). The bootstrap surface is **read-only** (no GraphQL mutations), and the CC2-4 config/trust-mutation exclusion below is now **golden-pinned**: the committed `ui/schema.graphql` + its precommit drift guard + no-Mutation-root schema tests make adding any mutation a deliberate, reviewed act. Details: [docs/system/graphql-surface.md](../../system/graphql-surface.md).

*(Implemented, 2026-07-11 — argus P4)*: the WebSocket half deviates from this section's sketch in two recorded ways. (1) A **separate key-only `ArgusSocket`** (`/argus/ws`, `workflows:*` its only channel) instead of extending `UserSocket`: key auth on the shared socket would have unlocked the mutable `rpc:*` surface (`sessions.create` / `sessions.sendMessage`) for the SPA's baked key — capability separation by construction, test-pinned in both directions; `UserSocket`/`RpcChannel` are untouched. (2) The key rides Phoenix's **`authToken` header transport** (`Sec-WebSocket-Protocol` → `connect_info[:auth_token]`), never connect params or the URL — no log-filtering dependence. Connect mirrors `/gql` (shared `ApiKeyAuth.authenticate_api_key/1`, then the tenant-activity gate, fail closed), suspension force-disconnects a tenant's sockets cluster-wide, and key revocation on a live socket is a documented residual (reconnect-only revalidation) pending TC1-2 tickets. Details: [docs/system/channels-surface.md](../../system/channels-surface.md).

The control plane is **not** intended for open-internet exposure; access is gated at the network layer by Tailscale tailnet ACLs. RBAC, per-device keys, and rotation tooling are explicitly out of scope unless the trust assumption changes.

> **External reference (2026-07-03)**: [ades/claude-command-center CC2-4](../ades/claude-command-center/FEATURES-WORTH-BORROWING.md) — the negative reference for this section, sharpened by our threat model (the relevant peer on the tailnet is an LLM agent with `curl`). Its three checklist lessons: origin/CSRF allowlists authenticate nothing — Origin-less programmatic requests must still present the key, on every surface including WebSocket connect; reads are not safe by being reads — transcripts and step outputs carry secrets, so the key gates queries too; config/trust-mutation endpoints deserve a stricter tier than data mutations (keep them off the GraphQL surface entirely).
>
> **Second external reference (2026-07-03, Xantham dig)**: [ades/Xantham XA1-1](../ades/Xantham-system-blueprint/FEATURES-WORTH-BORROWING.md) — the other failure shape, directly relevant to the phone-approval surface: an approval loop built on prompt trust (the model phrases the ask, interprets the natural-language "yes", and writes the approval into a file inside the agent's own write reach; its SECURITY.md enumerates the consequences — self-approval, TOCTOU, symlink races). The checklist it adds: decisions enter only through authenticated non-model surfaces; the decision artifact is a DB row the agent cannot mint (our `AgentCase` + `Cases.decide/4`, which `decideCase` wraps); the *ask* may be delivered over any channel, but the *grant* never rides one the model mediates. Same doc, same design conversation: XA OQ-1 (standing approvals — approve-for-N-days tiers vs our single-use `:consume`) — since designed in [FLOW §12](FLOW.md) (once / this-thread / this-project-for-N-days tiers, grants visible and revocable, a hard-block never-grantable list); only the slice-1 UI details remain open.
>
> **Third external reference (2026-07-04, myrlin dig)**: [pms/myrlin-workbook MY1-4](../pms/myrlin-workbook/FEATURES-WORTH-BORROWING.md) — the enrollment story this section owes: the QR pairing ladder is the reference shape for getting the key onto a phone (with its shipped-broken-pairing cautionary — the asserting test exists but doesn't gate releases), and the same dig exposed our own gap: `Accounts.ApiKey` has **zero minting paths** today (do-now: `mix jidoclaw.api_key` mint/list/revoke, MY1-4a). The single shared key stays the v1 posture; the QR ladder is the reference if per-device enrollment ever becomes real.
>
> **Fourth external reference (2026-07-06, t3code dig)**: [ades/t3code TC1-2](../ades/t3code/FEATURES-WORTH-BORROWING.md) — the field's first **positive** reference for this section: scoped credentials on every HTTP request *and* WS upgrade (no localhost-trust path exists), one-time pairing tokens exchanged for HttpOnly cookie sessions, short-lived single-purpose WebSocket tickets (browsers can't set WS headers — the same constraint our UserSocket faces), a per-RPC scope map that throws at handler build when a method lacks a declared scope, and shipped-working QR enrollment (the flow myrlin's reference broke). The single-shared-key v1 posture stands; TC1-2 sketches the upgrade riding MY1-4a's mint task — scope schema room at mint time, enforcement with the first scoped surface (FLOW §11's terminal "per-session short-lived tokens" are exactly t3code's `wsTicket`, generalized).

### 4.5 Endpoints retained

- `POST /v1/chat/completions` — OpenAI-compatible streaming chat. Untouched.
- `POST /webhooks/github` — HMAC-verified webhook. Untouched.
- `GET /health` — unauth health/version. Untouched.

### 4.6 Endpoints replaced

- `/ws` channel `rpc:*` — the current `gateway.status`, `sessions.list`, `sessions.create`, `sessions.sendMessage` handlers either move to GraphQL mutations (`createSession`, `sendMessage`) or get superseded by the new channel topics. Old channel can stay during transition.
- All LiveView pages remain — the dashboard is a capable local operator surface (workflow drill-in with step graph, replay with preflight diagnostics, cancellation, the approvals queue) and keeps working. Argus differentiates on decoupled lifecycle, phone form-factor, and cluster-wide aggregation, not on replacing it.

---

## 5. The Novel Feature — Step-Type-Specific Editors

The "edit the draft output between steps" feature is what makes this control plane interesting. It's also the part that requires the most design — and the one capability the gate family does not have: gates today are approve/reject/abandon, and resume re-emits the original artifact untouched.

### 5.1 Concept

Every workflow step produces an `output`. By default, the next step consumes it as-is. With a review checkpoint, the run pauses at a gate after the step completes; the UI shows an editor *typed for the kind of output*; the user edits or approves; the (possibly edited) output is what the next step receives.

A diff-editor for code patches, a markdown editor for prose, a JSON editor for structured data, a prompt editor for "the next instruction to send to the model." The editor is chosen by the checkpoint's declared editor type, not by the UI guessing.

### 5.2 Declaring review checkpoints

No new definition format. Skills are the workflow definitions (§3.4), so the checkpoint is a per-step annotation in skill YAML, compiled by `Skills.Compiler` into an interposed review-gate step — the same `GateStep`/`AgentCase` machinery the plan and safety gates use, with a new `:review` kind carrying editor metadata. Composer routes get the same capability as a catalog gate stage.

```yaml
name: feature_with_review
steps:
  - name: research
    template: researcher
    task: "Find prior art for {{topic}}"
    produces: research_notes
    pause_for_review:
      editor: markdown
      label: "Review research before outlining"

  - name: outline
    depends_on: [research]
    template: planner
    task: "Outline implementation based on the research notes"
    consumes: [research_notes]
    produces: implementation_plan
    pause_for_review:
      editor: markdown

  - name: implement
    depends_on: [outline]
    template: coder
    task: "Implement against the outline"
    consumes: [implementation_plan]
    produces: code_patch
    pause_for_review:
      editor: code_diff
      label: "Review patch before applying"

  - name: apply
    depends_on: [implement]
    template: applier
    consumes: [code_patch]
    # no pause_for_review → auto-proceeds
```

### 5.3 Editor type registry

A small set of editor types, each mapped to a UI component on the client:

| Editor type | UI component | Output shape |
|---|---|---|
| `markdown` | Markdown editor with preview | string |
| `code_diff` | Unified diff editor (Monaco diff view) | unified diff string or `{files: [{path, patch}]}` |
| `json` | JSON tree/text editor with optional schema hint | arbitrary JSON |
| `prompt` | Plain-text editor with token count | string |
| `command_list` | Editable list of shell commands | `[string]` |
| `none` | (no UI; auto-proceed) | — |

The list is intentionally short. Adding an editor type is a coordinated change between the YAML schema, the gate declaration, and the client — that friction is good; it stops the surface from sprawling.

> **External reference (2026-07-04, orca dig)**: [pms/orca OR1-1](../pms/orca/FEATURES-WORTH-BORROWING.md) — the field's only shipped review-verdict schema, the reference for any structured payload these editors emit or review gates collect: `approve|revise|reject` + `blocking|advisory` + nullable `{path,line}` anchors + per-criterion `satisfied` mappings, with two paid-for lessons (anchors must live in the *schema*, not just the prompt — orca's Codex-path verdicts silently lost them; finding shape is validated at the boundary, never passed through raw) and the anchor-fidelity taxonomy (`on_diff_line | on_unchanged_line | file_not_in_diff | unmapped`) for every LLM-supplied anchor.

### 5.4 Lifecycle

```
[step completes; a review checkpoint follows]
  step_completed event appended → WorkflowStep projected :completed
  review GateStep runs: halts the run (:awaiting_approval),
    opens AgentCase (kind :review, editor metadata, ref to the output under review)
  broadcast on workflows:run:<id> and gates:user:<user_id>

[user views in UI]
  GraphQL: query { workflowRun(id) { pendingCase { editor, targetStep { output, outputRevisions } } } }
  Client renders matching editor

[user edits]
  GraphQL: mutation reviseStepOutput(stepId, output, expectedSeq)
  Revision payload stored via the encrypted ref-store; a revision event is appended
  Projection updates WorkflowStep.output to the head; the original survives in the log
  Optimistic concurrency: expectedSeq must match — checked inside the append transaction

[user approves]
  GraphQL: mutation decideCase(caseId, APPROVE)
  Cases.decide → GateResume re-runs the persisted checkpoint
  Resume promotes the HEAD revision (operator's edit if any, else the original)
  WorkflowRun.status → :running; next step consumes the edited output

[user rejects]
  GraphQL: mutation decideCase(caseId, REJECT)   → run :cancelled   (or)
  GraphQL: mutation replayWorkflowRun(runId)     → re-run from stored inputs
```

The one behavioral change to the gate family is the resume rule: promote the head revision instead of re-emitting the original. Everything upstream of that — durable halt, encrypted checkpoint, decision surfaces, audit timeline — already exists and is reused as-is.

> **Correction (2026-07-03, traycer-dig seams pass)**: this section originally said "the event append is the CAS." It is not — the append is *pessimistic*: `Changes.Allocate` takes `FOR UPDATE` on the run row and allocates `seq = max+1` under that lock (`workflow_event/changes/allocate.ex:171-195`); the only CAS in the path is the WS1 lease-token fence, which fences ownership, not sequencing. The `expectedSeq` check is therefore small **net-new** machinery with an easy home: compare the caller's `expectedSeq` against the current max seq *after* acquiring the existing lock; mismatch returns a typed `stale_revision` error carrying the current seq (client refetches and re-edits — the CCC mtime-409 flow). See [ades/traycer TR2-3](../ades/traycer/FEATURES-WORTH-BORROWING.md).
>
> **Second correction (2026-07-03, CCC dig)**: the "CCC mtime-409 flow" cited above is a **half-precedent** — CCC's server half is real (typed 409 carrying the fresh mtime, convergent with this design), but its client refetch-and-re-edit half was never built: a conflict dead-ends and the only recovery path loses the operator's edits. Treat the recovery UX as acceptance criteria to design (client keeps the operator's buffer across the refetch; absent `expectedSeq` is a validation error, never last-write-wins; machine rewrites go through the same check), not a precedent to copy — [ades/claude-command-center CC1-3](../ades/claude-command-center/FEATURES-WORTH-BORROWING.md).
>
> **Acceptance criteria from the pms wave (2026-07-04; the full eight-axis checklist is assembled in [SYNTHESIS §5.2](SYNTHESIS.md))**: [pms/chorus CH1-1](../pms/chorus/FEATURES-WORTH-BORROWING.md) — the field's closest precedent (plan-layer promote-the-edit: human draft edits materialize verbatim, the model never re-invoked) ships without two fences this build must keep by name: an **approve-idempotency fence** (Chorus double-materializes on double-approve; ours exists — FOR-UPDATE + single-use `:consume` — the criterion is *keep it*) and **revision history** (Chorus keeps one overwritten note; ours is the event log + ref-store, by design). [pms/myrlin-workbook MY2-1](../pms/myrlin-workbook/FEATURES-WORTH-BORROWING.md) adds the **severed-consumer test**: myrlin's promote-the-edit lands in a record nothing consumes — so prove end-to-end that the resumed step consumes the head revision's *bytes* at its input, not merely that a revision row was stored.

### 5.5 Open design questions for editors

- **Where do revision payloads live?** Inline in the revision event, or in the encrypted ref-store with the event carrying the ref? **Lean: ref-store** (`art_…`-style refs) — payloads can be large, events stay small, and gate resume already resolves values by ref. The event log doubles as the audit trail, so a separate revisions table is unnecessary.
- **Server-side validation per editor type?** Should `code_diff` reject malformed diffs server-side, or trust the client? **Lean: server-side parse, return GraphQL field errors.**
- **Does `:review` subsume `:plan`?** A plan approval is arguably a review checkpoint with a markdown editor. **Lean: keep them distinct initially** — plan/safety gates have bespoke promote semantics — and revisit once editors are real.

---

## 6. Open Questions

Things we explicitly deferred during the exploration. Status per item — [FLOW](FLOW.md) settled items 2 and 4, and the argus-ui-bootstrap plan settled item 3 (2026-07-10); item 1 still holds a real decision to make before building.

1. **Review-gate declaration details.** The mechanism is settled (§5.2: skill-step annotation compiled to an interposed `:review` gate; catalog gate stage for composer routes). Open: the exact YAML key shape, how editor metadata rides the gate's declared fields, and whether composer stages declare review per-stage (like `lock`) or via dedicated catalog gate entries.
2. **Push notification trigger taxonomy — settled (2026-07-04).** With the React PWA + Web Push path settled (§2.6), the trigger set is now settled too: [FLOW §12](FLOW.md) adopts the corpus-merged answer wholesale (agent finished; blocked-on-you incl. Forge `:needs_input`; `ended_blocked`; run failed; infra-degraded; `fileConflicts`) plus the delivery and architecture rules, and [SYNTHESIS §5.1](SYNTHESIS.md) assembles the full five-layer stack. What remains open moved to slice 1: the subscription-endpoint wiring, and — the named-tested-producer law — a named, tested producer for every declared trigger before it ships. The evidence trail that produced the answer: **External references (2026-07-03)**: [ades/emdash EM1-3](../ades/emdash/FEATURES-WORTH-BORROWING.md) — a shipped two-trigger answer (agent finished + agent waiting on you; delivery rules: unfocused-only, transition-deduped, deep-linked; error pushes deliberately excluded there, revisit per its OQ-3), independently confirmed by termic with three delivery deltas folded into it ([ades/termic TM2-5](../ades/termic/FEATURES-WORTH-BORROWING.md): sound only on completion, per-key debounce, ambiguous states fail toward attention); [ades/claude-command-center CC1-2](../ades/claude-command-center/FEATURES-WORTH-BORROWING.md) — the attention-feed read-model the triggers should read from (priority doubles as the per-severity mute knob), plus `ended_blocked` (run ended on an unanswered question) as a trigger candidate this list is missing; [ades/Xantham XA1-2](../ades/Xantham-system-blueprint/FEATURES-WORTH-BORROWING.md) — the third shipping set, converging on `ended_blocked` (its "never-silent fallback" — a turn that owed a reply and sent none — is the same trigger arrived at independently, now settled) and adding what the other two lack: infra-degraded triggers (credential canary XA2-3, watchdog alerts), per-kind daily caps, transition-only firing (`== N` streaks, not `>= N`), and the delivery rule the others never state — the notifier must not depend on the agent loop being healthy: pushes are sent by the gateway layer subscribed to PubSub, never implemented as an agent behavior. **Fourth reference (2026-07-04, myrlin dig)**: [pms/myrlin-workbook MY1-3/MY2-4](../pms/myrlin-workbook/FEATURES-WORTH-BORROWING.md) — the field's only *per-event device-subscription* taxonomy (five preference booleans minted at pairing) comes with the corpus's sharpest cautionary: only two of the five events actually fire (agent-finished + task-ready-for-review — exactly emdash's set, independently re-derived), the `fileConflicts` push being dead code in the product that named the trigger — so every trigger argus declares must have a named, tested producer; the trigger itself stands (FLOW §12 keeps it, now sourced to the two detector shapes in MY1-2 rather than the unwired push), and myrlin's storm-tested delivery deltas (replay suppression on reconnect, focus-acknowledgement that consumes pending state, minimum-signal re-arm floor) plus its transport mechanics (per-device batch-coalescing into a summary push, prune-on-provider-rejection) fold into the EM/TM/XA delivery-rule stack. **Fifth reference (2026-07-06, herdr + cmux digs)**: [ades/herdr HD1-2](../ades/herdr/FEATURES-WORTH-BORROWING.md) adds fire-time honesty — a delayed notification re-proves its predicate at delivery or drops, and blocked-class pierces focus/DND while completion-class respects it — and [ades/cmux CM1-4](../ades/cmux/FEATURES-WORTH-BORROWING.md) adds the stack's first cross-device rules (presence-gated forwarding — push only while no operator surface is active — and ack-sync as an absolute projection of the durable watermark); both folded into FLOW §12. herdr also re-proves the soft-block layer's uniqueness from the null side: the field's most engineered screen classifier cannot see a prose soft-block (herdr S-5) — CC1-1 stays unique.
3. **GraphQL codegen tooling — settled (2026-07-10, argus-ui-bootstrap).** Basic `@graphql-codegen/cli` with `typescript` + `typescript-operations` (types only); `typescript-react-apollo` and `client-preset` explicitly rejected (Apollo recommends against both) — iterate from working-and-boring on real friction. The golden-SDL guard half is **implemented** (P1, 2026-07-11): `ui/schema.graphql` is committed, regenerated by `mix jidoclaw.graphql.schema`, and byte-diffed by `mix jidoclaw.graphql.schema.check` in `mix precommit`. Historical context of the original question: Apollo's recommended client codegen approach had shifted (the older `typescript-react-apollo` plugin is no longer the recommendation). The harder half of this question — schema *skew* between a rolling-upgraded cluster and a service-worker-cached PWA shell — now has a worked external reference (2026-07-03): [ades/traycer TR1-1/TR1-2/TR2-4](../ades/traycer/FEATURES-WORTH-BORROWING.md) — per-topic version manifests for the Channels layer, golden-SDL / released-surface CI guards, and block-with-refresh recovery UX. **Second precedent (2026-07-04, pad dig)**: [pms/pad PD1-1](../pms/pad/FEATURES-WORTH-BORROWING.md) supplies the *advertisement* half traycer lacks — per-surface version constants with bump-rules-as-doc-comment and an in-file changelog, advertised in the MCP handshake and a `_meta/version` resource — plus the paid-for lesson that advertisement without mechanical enforcement rots (pad's own handshake instructions lag its surface by three versions, and our MCP server advertises a hardcoded `0.2.0` on an `0.6.4` app — the PD1-1 do-today fix fuses both halves). **Re-confirmed from the architectural peer (2026-07-06, t3code dig)**: even t3code ships no negotiation and no goldens — a dismissible version-skew banner is its whole answer ([ades/t3code TC2-5/S-6](../ades/t3code/FEATURES-WORTH-BORROWING.md)) — so traycer + pad remain the only field references for this section.
4. **Codename — settled.** `argus` stays ([FLOW §13](FLOW.md) open item 3): the clustering and Reactor-adoption docs already refer to "the argus second node" / "the clustered-tailnet future (argus)", and it has de facto stuck. A product name, if ever, is a launch-time question. (Options once floated — `helm`, `atlas`, `tower`, `bridge` — retired. Bikeshed-class.)

---

## 7. Sequencing — Suggested Order of Work

This is suggestive, not prescriptive. Each item is roughly self-contained and shippable.

> **Supersession note (2026-07-04)**: [FLOW §13](FLOW.md) re-sequenced delivery into value-ordered product slices, and where the two orders disagree FLOW wins — most visibly, FLOW's slice 1 (attention loop) pulls push notifications (step 8 below) to the front, ahead of worktrees (step 1 below). Read this list as the backend dependency ordering inside those slices, not as delivery order.

1. **Introduce `Worktrees` domain + `Worktree` resource** layered on top of existing `Workspace` (per §3.3), plus the `node` column on Workspace. Worktree is created when a workspace's path is a managed git checkout under a known Project. No changes to Workspace's callers or policy aggregates. Smallest schema change that unlocks the UI's main hierarchy.
2. **Stand up AshGraphql** on the resources from §4.1 — runs, steps, events, cases, projects, worktrees. Mostly mechanical: extension declarations + the schema module + custom resolvers for the synthetic `System` resource, reusing the existing view modules (`WorkflowView`, `Observe`, AgentView). Wire Apollo Client + GraphQL codegen on the React side (tooling per §6.3).
3. **Wire Phoenix Channels**: proxy the existing run-lifecycle and gates PubSub topics, project per-step deltas from the `WorkflowEvent` log, and bridge `Conversations.Recorder` to a PubSub topic for live message activity. Build the first non-LiveView client against this.
4. **The edit path** (§5.4): revision events + ref-store storage, the `:review` gate kind, and the `GateResume` head-promotion rule. Ship with the binary markdown editor end-to-end — this is the first genuinely novel change to the gate family and wants a design pass on the revision-event shape.
5. **`pause_for_review` compilation** in `Skills.Compiler`, so any skill step can checkpoint declaratively; catalog gate-stage equivalent for composer routes.
6. **Editor registry expansion** — `code_diff`, `json`, `prompt`, `command_list`; iterate against real runs.
7. **Cluster fan-out resolvers** — the `cluster`, `agentRuntime`, `forgeRuntime`, `skills` GraphQL fields. Lower priority; useful but not blocking.
8. **Push notifications** via Web Push for the installed PWA. Define the trigger taxonomy (§6.2) and wire the subscription endpoint.

Steps 1 and 4 are each a PR or two; step 2 is mostly boilerplate; step 6 is the "interesting" UX work and probably wants real-world iteration before polishing.

---

## Appendix A — Current State Audit

File:line citations for the existing surface, captured during this exploration. All paths relative to `lib/` unless noted.

### A.1 External API surfaces today

**MCP server (stdio)** — `mix jidoclaw --mcp`
- Wiring: `jido_claw/application.ex:505-530` starts `JidoClaw.MCPServer` only in MCP mode, `transport: :stdio` (`application.ex:524`).
- Server module: `jido_claw/core/mcp_server.ex` — `use Jido.MCP.Server`, 24 tools at lines 16-59. Workflow-control tools among them: `workflow_status` (tenant rollup), `inspect_workflow` (single-run drill-in incl. composer route/waves/held/dropped/gate-block), `workflow_events` (raw byte-paginated `WorkflowEvent` feed, `after_seq`/`limit`), `replay_workflow` (no force/irreversible overrides — those are dashboard-only). The last three are MCP-only by design.
- Resources: `jido://workflows/catalog` (`core/mcp_server/resources/workflow_catalog.ex:22`, published at `mcp_server.ex:60-64`) — the full composer stage catalog as JSON; `jido://workflows/{name}` template (`core/mcp_server/resources/workflow_stage.ex:24`, component at `mcp_server.ex:75`) — per-stage drill-down, byte-identical to the catalog entry.
- Transport: stdio only. No auth (process trust).
- Internal-only loopback MCP for the consolidator: `jido_claw/memory/consolidator/mcp_endpoint.ex:17-28` (Bandit, `127.0.0.1:0`).
- Separately, `lib/jido_claw/mcp/` (Consumer/EndpointConfig/ProxyGenerator/Client) is *outbound* MCP consumption — JidoClaw dialing external servers — not an inbound surface.

**Phoenix HTTP API** — `jido_claw/web/router.ex`, started when `:mode in [:gateway, :both]` (`application.ex:456-464`)
- `GET /health` (line 50) — unauth health/version.
- `POST /v1/chat/completions` (line 57) — OpenAI-compatible chat with SSE streaming, auth via `Authorization: Bearer` or `x-api-key` against Ash users (`web/plugs/api_key_auth.ex:41,45`).
- `POST /webhooks/github` (line 63) — HMAC-SHA256-verified webhook ingress (`github/webhook_signature.ex:12-17`).
- `/admin` (Ash Admin, line 43), `/live-dashboard` (dev only, lines 104-113), LiveViews at `/`, `/dashboard`, `/forge`, `/workflows`, `/agents`, `/projects`, `/settings`, `/approvals` (lines 92-99), `/sign-in` (line 79), `/setup` (line 83).
- WebSocket `/ws` mounted at `web/endpoint.ex:20` (`UserSocket` — Ash session auth only, `user_socket.ex:10-32`). Channel `rpc:*` (`web/channels/rpc_channel.ex`) handles `gateway.status` (:19), `sessions.list` (:29), `sessions.create` (:40), `sessions.sendMessage` (:76). `sessions.list` reads the in-memory `JidoClaw.SessionRegistry` via `Session.Supervisor.list_sessions/1` (`platform/session/supervisor.ex:50-57`) — does NOT see `Conversations.Session` rows.

**Discord bot** — `jido_claw/platform/channel/discord_consumer.ex`
- Enabled when `DISCORD_BOT_TOKEN` is set (`application.ex:86-102`); MCP mode forces it off.
- Only handles `MESSAGE_CREATE` (`discord_consumer.ex:12`) and `READY` (`:29`). **No slash commands, no application commands registered.**
- Inbound messages routed to `JidoClaw.chat/3` keyed by `discord_<channel_id>`.

### A.2 Project/Worktree concept

- `JidoClaw.Projects.Project` Ash resource — `projects/project.ex`. Attributes: `id`, `name`, `github_full_name`, `default_branch`, `settings`, timestamps (`:72-102`). Actions: CRUD + `:reactor_undo` (`:22-56`); `code_interface` for CRUD + `get_by_github_full_name` (`:14-20`). Domain at `projects.ex:16-18` (single resource).
- `/projects` LiveView — `web/live/projects_live.ex:11-18` reads actor-scoped via `Project.read(actor: ...)`, renders a static table. No create/archive UI.
- `Workspace.project_id` field exists at `workspaces/resources/workspace.ex:187-190` (nullable; `belongs_to :project` at `:238-242`), used in `workspaces/resolver.ex:49`. **The RPC `sessions.create` path (`web/channels/rpc_channel.ex:59-60`) does not pass it.**
- **No worktree functionality in the codebase.** The only textual match for `worktree` in `lib/` is the `--worktree` flag token in the shell-command analyzer's git-config allowlist (`security/shell_command/git.ex:150`). No `git worktree` shell calls anywhere.

### A.3 Session / activity history

**Persisted:**
- `Conversations.Message` — `conversations/resources/message.ex`. Roles `[:user, :assistant, :tool_call, :tool_result, :reasoning, :system]` (`:73`), monotonic per-session sequence allocated by a raw `UPDATE … RETURNING` on the session row (`:517-560`). `Conversations.Recorder` (`conversations/recorder.ex:115-122, 257-258`) subscribes to `ai.*` signals on `JidoClaw.SignalBus` and writes the `tool_call`/`tool_result`/`reasoning` rows; `user`/`assistant`/`system` turns land via the dispatcher and `Conversations.SubagentTranscript` (which closes each spawned sub-agent's durable slice, stamped `subagent: true`).
- `Conversations.Session` — `conversations/resources/session.ex`. Kinds `repl/discord/web_rpc/cron/api/mcp/imported_legacy`; `metadata` carries per-agent compaction snapshots under `"compactions"` via atomic `jsonb_set` actions (`:146-152`). Session `:start`/`:close` append durable `Audit.Event` rows via producers (`:107`, `:119`) — durable, not PubSub.
- `Conversations.ToolOutput` — tenant-scoped full-output store under unguessable `out_…` refs; backs `OutputShaper` reversibility and the `fetch_output` tool.
- `Audit.Event` — `audit/resources/event.ex`. Append-only `audit_events` with polymorphic `target_kind`/`target_id`.
- `Forge.Resources.Event` — `forge/resources/event.ex`. Per-forge-session events with `read :for_session` (`:35`).
- `AgentTracker` — `agent_tracker.ex` (~750 lines). **In-memory only** — plain GenServer state, no ETS, no persistence. Per-agent tokens/tool-calls/status counted via telemetry on `[:jido, :ai, :tool, :execute, :*]` (`:266-278`); scoped tenant/session/workspace projections (`:734-736`); child-pid + orchestrator monitoring, terminal-TTL sweep, spawn caps. The MCP Consumer re-attaches proxy tools to live worker pids by reading it (`mcp/consumer.ex:709-720`).

**Live streaming:**
- `JidoClaw.SignalBus` — `core/signal_bus.ex`. Wraps `Jido.Signal.Bus`. Used by Recorder.
- `JidoClaw.Forge.PubSub` — `forge/pubsub.ex:6,12`. Topics `forge:sessions` and `forge:session:<id>`. **Broadcasts are real and active**: `forge/manager.ex:127,170,197,225` (lifecycle), `forge/harness.ex` (`:ready` :240/:359/:374/:396, `:error` :436/:682/:739, `:needs_input` :662/:666/:674, `:stopped` :769).
- **No PubSub for `Conversations.Message` appends or `Conversations.Session` lifecycle.** The Recorder writes to Postgres but doesn't fan out.

### A.4 Workflows / orchestration

**Durable spine (event-sourced):**
- `Orchestration.WorkflowEvent` — the append-only log. Step kinds `step_started/step_completed/step_failed/step_retried/step_compensated/step_undone` (`workflow_event.ex:104-108`); composer kinds `route_composed, wave_started, wave_completed, signals_published, artifacts_produced, wave_paused/resumed, signals_retracted, stages_invalidated, artifacts_invalidated` plus terminals (`route_converged` → `:completed`; `route_not_converged/…/route_failed` → `:failed`; `route_rejected/route_abandoned` → `:cancelled`) (`:126-158`). The append transaction also projects run status and step rows.
- `Orchestration.WorkflowRun` — `orchestration/workflow_run.ex`. Statuses `[:pending, :running, :awaiting_approval, :completed, :failed, :cancelled, :abandoned]` (`:294-305`). **Status is projection-owned**: the only writer is the private `set_status` action (`:140-165`), called solely from the event-append path. Reads include `:list_active` (`:179`), `:by_project` (`:198`), `:claimable`. Lease columns `claimed_by`/`claim_token`/`claim_expires_at` (`:403-406`, index `:79`); AshCloak-encrypted `resume_checkpoint`/`replay_inputs`; composer lineage `parent_run`/`child_runs` (`:453-455`); `belongs_to :project` (`:444`).
- `Orchestration.WorkflowStep` — a **read-model projected from `step_*` events** (moduledoc `workflow_step.ex:1-7`) via upserts `record_started/record_completed/record_failed` (`:75-133`). Statuses `[:pending, :running, :completed, :failed, :skipped]` (`:203`), `output :map` (`:237`), `sequence` (`:193`), `belongs_to :workflow_run` (`:261`).

**Execution envelope:**
- `Skills.Compiler` compiles `.jido/skills/*.yaml` (fields `name`, `template`, `task`, `depends_on`, `produces`, `consumes`) into `%Reactor{}`. There is no `.jido/workflows/` directory and no separate workflow YAML; the composer catalog is the second, compile-time DAG format.
- `ReactorRunner` executes; `ReactorMiddleware` appends the events and broadcasts run lifecycle (`reactor_middleware.ex:158,213,242`; step-event mapping `:273-295`; terminal backstop `reactor_runner.ex:908`). `WorkflowRunner` is a thin cron adapter (moduledoc `workflow_runner.ex:8-11`). `Workflows.StepResult` (`workflows/step_result.ex:1-21`) remains a transient in-memory struct.
- `Orchestration.Replay` (`replay.ex:1-60`) re-runs a terminal run from durably-stored `replay_inputs`, behind two safety gates (definition-hash drift; irreversible steps executed).

**Gate family (human-in-the-loop):**
- Kinds `:plan`, `:irreversible_write` (workflow axis) and `:tool_call` (conversation axis), single-sourced in `gate/kinds.ex:15`. A `GateStep` halts the run `:awaiting_approval` and opens a durable `AgentCase` with an `AgentCaseEvent` timeline. Operator-facing gate declarations (`use JidoClaw.Orchestration.HumanGate`: title/description/fields) live in `lib/jido_claw/gates/`.
- Decisions flow through `Cases.decide/4` (`cases.ex:118`) from REPL `/gates` (`cli/commands/approvals.ex`) and web `/approvals` (`web/live/approvals_live.ex`). **Approve/reject/abandon only — no edit path**: declared field values fold into the free-text `decision_comment` (`approvals_live.ex:122, 256-267`); `GateResume` re-runs the persisted encrypted checkpoint seeding only the decision atom (`gate_resume.ex:160-167, 278-284`); the plan gate re-emits the *original* plan from its `plan_ref`, unchanged (`reactors/plan_gate.ex:60-79`). §5's edit path is the delta.
- Tool-call axis: `Security.ToolApproval.gate/4` (`security/tool_approval.ex:199-211`) → `Orchestration.ToolApprovals.request/3` (`tool_approvals.ex:87`) → run-less `AgentCase` (`kind: :tool_call`), fingerprint-keyed, single-use approve / deny-once. Gate requests broadcast on the gates topic (`tool_approvals.ex:294-298`).

**Composer (multi-wave orchestration):**
- `JidoClaw.RouteComposer` (`route_composer/route_composer.ex`, moduledoc `:1-98`) — supervised single-run GenServer loop: seed → `compose_route` → dispatch next unrun wave → run on Reactor → fold signals/artifacts → recompose → converge. Sole user-turn caller is `FrontDoor` (`front_door.ex:37, 275`).
- Compile-time stage catalog (`route_composer/catalog.ex`; `%Stage{}` fields incl. two graphs — data `input`/`output`, signal `subscribes`/`publishes` — plus `lock`, and per-stage `model`/`effort` tiers, `stage.ex:106-122`). Router computes runnable waves plus `held`/`dropped` (`router.ex:20-30, 225-232`). `WaveBuilder` (`wave_builder.ex:61`) builds a worker-cohort reactor per wave, or a solo gate wave. Multi-plan arming (`front_door.ex:485-488`) inserts the judge panel: 3 lens planners → 3 challengers → plan-arbiter (`catalog.ex:11-22`).
- Durability: parent `workflow_type: "composer"` run + one child run per wave; `commit.ex` welds each wave's effects into one `Ash.transact` with a FOR-UPDATE token fence (`:156-168, 177-181`). `Orchestration.ComposerArtifact` is the encrypted `art_…` ref-store (`composer_artifact.ex:25-34`; refs minted by `JidoClaw.Refs.mint/1`, `refs.ex:22`) — durable surfaces carry only opaque refs, values decrypt at the wave boundary.
- Observability: `RouteComposer.Observe` (`observe.ex:48-49, 95-96`) derives route/waves/held/dropped/live-signals plus the authoritative blocked-on-a-gate determination from the event log — the read-model behind `inspect_workflow`.

**Live broadcast + UI:**
- `Orchestration.RunPubSub` — topics `orchestration:run:<id>`, `orchestration:runs`, `orchestration:gates` (`run_pubsub.ex`). Run lifecycle published by `ReactorMiddleware` for reactor runs and by `RouteComposer` itself for composer parents (post-append status-family broadcasts, P4 remediation; the five-kind inventory is `RunPubSub.lifecycle_kinds/0`); gate requests/decisions on the gates topic. `DashboardLive` subscribes to both (`dashboard_live.ex:17-18`); `ApprovalsLive` consumes gates (`approvals_live.ex:25`). **Per-step transitions are durable-log-only — nothing broadcasts them.**
- `/workflows` LiveView — `web/live/workflows_live.ex`: expandable per-run step drill-in (`:55`), step graph/table toggle (`:79-85`), replay with preflight diagnostics + force/irreversible overrides (`:109-160`), cancel (`:165`), payload-reveal auditor scope (`:91`); actor-scoped reads (`:504, 519`). Approvals live separately at `/approvals`.

**Not present anywhere:** `pause_for_review`, an `:awaiting_review` step status, or any operator edit-before-resume path. The pause primitive that exists is the run-level `:awaiting_approval` gate.

### A.5 RPC channel coverage

`web/channels/rpc_channel.ex` handles only:
- `gateway.status` (:19)
- `sessions.list` (:29 — in-memory registry, NOT DB rows)
- `sessions.create` (:40)
- `sessions.sendMessage` (:76)
- catch-all error (:100)

**Available-but-unrouted PubSub topics** the channel could trivially proxy:
- `forge:sessions`, `forge:session:<id>` (`forge/pubsub.ex:6,12`) — fully populated.
- `orchestration:run:<id>`, `orchestration:runs`, `orchestration:gates` (`run_pubsub.ex:7-13`) — populated; consumed today only by LiveView.

**Missing entirely:**
- PubSub for Project, Worktree, Workspace lifecycle.
- PubSub for Conversations.Message appends and Conversations.Session open/close.
- PubSub for per-step transitions (durable `WorkflowEvent`s exist; no broadcast).
- RPC handlers for `projects.*`, `worktrees.*`, `workflows.*` (start, revise output, decide case), `sessions.history`.

### A.6 Cluster wiring

- Cluster children start in `application.ex:466-502`, gated by `:cluster_enabled` (`:468`): a `:rest_for_one` LeadershipSupervisor with the dedicated `:pg` scope `:jido_claw` (`:492`) + `JidoClaw.Cluster.Leader` (`:493`), then libcluster's `Cluster.Supervisor` (`:497`).
- Topology from `JidoClaw.Cluster.topology/0` (`core/cluster.ex:141-181`), selected by `:cluster_strategy`: **default `:gossip`** (UDP multicast `230.1.1.251:45892`, requires `JIDOCLAW_CLUSTER_SECRET`) — multicast does not traverse a tailnet, so argus uses `:epmd` with explicit `:cluster_nodes`; also `:kubernetes` and `:none`.
- Phoenix.PubSub default adapter (PG2) broadcasts cluster-wide once nodes connect (`application.ex:148`). No additional configuration needed for cross-node PubSub.
- Single-writer runs: `WorkflowRun.claimed_by`/`claim_token` stamped via CAS by `WorkflowLease` (`workflow_lease.ex:78`; node identity = `to_string(Cluster.local_node())`, `:108-109` — appendix corrected 2026-07-09 to match the body's 2026-07-03 correction), commit-time fencing in the composer (`commit.ex:177-181`), reclaim & recovery of expired claims. Full program: `docs/plans/clustering/` WS1–WS5 (lease core, composer lease, reclaim/recovery, leader election + singleton audit, clustered cron ownership, cross-node cancellation); WS6 multi-node validation awaits the argus second node.
