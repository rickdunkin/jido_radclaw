# Argus — Unified Control Plane for Multi-Agent JidoClaw

Exploration notes — not a plan, not a commitment. Codename `argus` (Greek myth: hundred-eyed watcher) is provisional. Compared against jido_radclaw as of 2026-05-10.

## How to read this document

The body is architecture-level: vision, decisions, data-model implications, API surface plan, and the novel "step-type-specific editors" feature. The appendix holds the file:line audit of the current state — useful when you sit down to build, skippable on first read.

Each "where we landed" subsection records a decision made during the exploration. The "open questions" section collects everything we explicitly deferred.

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

JidoClaw already has the wiring (`:cluster_enabled`, libcluster + `:pg` per AGENTS.md) — this just means turning it on and picking a strategy (likely a static list of MagicDNS names, or `Cluster.Strategy.Epmd` with explicit nodes).

### 2.2 Database: shared Postgres on an always-on desktop

One device hosts Postgres; all JidoClaw nodes connect to it. Daily backups on the host. This unifies persisted data — Projects, Workspaces, Worktrees, Conversations, WorkflowRuns, Memories, Knowledge, Audit — across the cluster automatically.

**Tradeoff acknowledged**: the desktop becomes a hard dependency. A laptop that drops off the tailnet loses DB access and effectively cannot run JidoClaw. This is acceptable for the use case (always-online tailnet, agents that need shared memory anyway), but is the single biggest fragility in the design.

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

Two transports, each used for what it's best at: GraphQL for "fetch this tree of data" and "perform this action," Channels for "tell me when X changes."

### 2.5 Cross-node concerns: fan-out for in-memory state

Shared Postgres unifies *persisted* data. It does **not** unify per-node in-memory state (`AgentTracker` ETS, `Forge.Manager` GenServer state, `Platform.Approval` ETS, `JidoClaw.SessionRegistry`). Any "what is each node doing right now?" query needs cross-node fan-out via `:erpc.multicall` or `Task.Supervisor.async_stream` over `Node.list()`. The gateway node aggregates and returns.

### 2.6 UI client: React + Apollo Client

The control-plane UI is a React web app served as a static SPA, talking to any node's gateway. **Apollo Client** handles GraphQL queries and mutations with a typed, normalized cache; **Phoenix Channels** (via `phoenix.js`) handle live subscriptions. TypeScript types are generated from the AshGraphql schema via codegen — exact tooling TBD.

PWA installability is a low-cost addition that makes the app feel native on a phone (add-to-home-screen, full-screen, offline shell). Push notifications use the Web Push API where supported, including iOS 16.4+ for installed PWAs. Native iOS push via APNs is out of scope for v1; if it becomes required, wrap the React app in Tauri or Capacitor rather than rebuilding.

Node ownership is surfaced in the UI wherever it's operationally relevant — worktree lists show which machine holds the checkout, agent and forge runtime views show which node hosts the process. Useful for debugging across machines.

---

## 3. Data Model Changes Required

### 3.1 New `Worktrees` domain with a `Worktree` resource

Worktree is **not** an existing concept in JidoClaw. The closest existing thing (`Workspaces.Workspace`) maps one tenant to one path; it doesn't model the multiple-branches-in-flight pattern that real parallel work requires.

**Why a new `Worktrees` domain rather than nesting under `Projects`:**

- Matches the codebase convention. JidoClaw groups domains by bounded context, not hierarchy: `Workspaces`, `Conversations`, `Forge`, `Orchestration`, `Audit` are all standalone even though they reference `Projects`. `Projects` is a single-resource metadata domain (`projects.ex:1-11`) — meant to stay focused.
- Worktree is operationally heavy (shell side-effects via `git worktree add/remove`, node-affinity, lifecycle status) and is the natural parent for likely future siblings: per-worktree sandbox metadata, per-worktree memory partitions, attached background processes. All want to live in a domain together.

Cross-domain `belongs_to :project` works fine in Ash 3.

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

Today: `id`, `name`, `github_full_name`, `default_branch`, `settings`, timestamps. No "active" concept, no list API.

Add:
- `attribute :status, :atom, constraints: [one_of: [:active, :archived]], default: :active` (or `archived_at` for soft-delete style).
- `read :list_active` on the resource.
- `code_interface` entries so `Projects.list_active!()` is a one-liner.
- `has_many :worktrees, JidoClaw.Worktrees.Worktree`.

### 3.3 Workspace and Worktree stack rather than collapse

Worktree is git-shaped; Workspace is not. The two model different concerns and neither subsumes the other.

**What Workspace is**: a tenant-scoped, durable anchor for *operating in a directory*. It carries identity (`tenant_id + path + optional user_id + optional project_id`), memory-egress policy (`embedding_policy`, `consolidation_policy`, with cross-row aggregates in `Workspaces.PolicyTransitions`), and a dual-identity quirk — the same path can have separate rows for an authed user and for anonymous CLI use (`workspace.ex:219-225`). It is the parent UUID for `Conversations.Session`, `Solutions.Solution`, `Reasoning.Outcome`, `RequestCorrelation`, and the polymorphic target for `Audit.Event`. It is bootstrapped lazily from 7+ surfaces (REPL, web RPC, shell, MCP, network node, mix tasks) via `Workspaces.Resolver.ensure_workspace/3` — none of which require a git checkout. The CLI running in `/tmp/scratch` creates a real Workspace.

**Why collapsing fails**: forcing every working directory to be a git worktree excludes the non-git cases above; alternatively, watering down "Worktree" until it accepts non-git directories makes the name misleading and loses the value of having a focused project + git facet.

**The stack**:

- `Workspace` is the directory anchor, memory/audit parent — present whenever an agent operates in a directory. Gains a `node` field so cluster-aware queries route correctly without relying on path-existence checks at query time.
- `Worktree belongs_to :workspace, allow_nil?: false` and `belongs_to :project, allow_nil?: false`. It is a *facet* on Workspace, present only when the workspace is a managed git checkout under a known Project.
- A Workspace can exist without a Worktree (CLI, non-git, scratch). A Worktree always has exactly one Workspace. `Workspace has_one :worktree`.
- Path lives on Workspace; Worktree adds `branch`, `status`, `last_activity_at`. Both carry `node`, because both anchor data tied to a specific machine's filesystem.

This stays mostly additive: a new `node` column on Workspace, populated automatically by `Workspaces.Resolver.ensure_workspace/3` (which sets `node: Node.self()`) — none of the 7+ bootstrap surfaces need to change. Existing rows backfill trivially from the current node since the system is single-node today. No policy refactor.

For the UI: `Project.has_many :worktrees`, drill into a Worktree, list activity via `worktree.workspace.conversation_sessions`. Workspace is invisible to the operator but does the work underneath. The `Workspace.project_id` field — currently nullable and inconsistently populated — should be kept in sync with `worktree.project_id` when a Worktree exists, so project-scoped queries can reach Workspace-anchored data without always going through Worktree.

### 3.4 Finish the workflow runner so it uses the schema

**Workflows and Skills are distinct concepts.** Skills (`.jido/skills/`) extend AI agent capabilities — a skill might wrap a single tool, drive a multi-turn interaction, or *invoke a workflow* as one of its actions. A workflow is its own definition with its own runner and persistent state machine; it is the thing that pauses, persists steps, and supports the editable-draft feature in §5. The existing code partially conflates the two (skill YAML and workflow runner both have DAG-of-steps shapes); cleanly separating them is part of this work.

This is the upstream blocker for the entire "edit drafts" feature. Current state (see appendix A.4):

- `Orchestration.WorkflowRun`, `WorkflowStep`, `ApprovalGate` exist as Ash resources with full state-machine actions (`:await_approval`, `:resume`, `:approve`).
- The actual runner (`workflows/plan_workflow.ex`) uses `Task.async_stream` in-memory, never reads or writes any of these tables, never checks gates.
- `Orchestration.RunPubSub`'s run-level lifecycle events (`:run_started`/`:run_completed`/`:run_failed`) are now published by `WorkflowRunner` and consumed by `DashboardLive`; `plan_workflow.ex` still publishes no per-step transitions.

The runner needs to be rewritten to:
1. Create a `WorkflowRun` row at start.
2. Create a `WorkflowStep` row per step, transitioning `:pending → :running → :completed/awaiting_review`.
3. Persist each step's `output` to the row.
4. Honor `pause_for_review` on a step (see §5) by transitioning the run to `:awaiting_approval` and the step to a new `:awaiting_review` status.
5. Broadcast every transition on `Orchestration.RunPubSub`.
6. On `:resume`, read the (possibly edited) `WorkflowStep.output` from the DB and feed it to the next step.

This is mostly a rewrite of one file, not a redesign. The schema is already correct.

**Where the runner runs**: on the worktree's owning node. Because the workflow operates on files in the checkout (and the checkout only exists on one machine), the runner naturally pins to `worktree.node` — same constraint as Forge sandboxes and direct tool execution. This gives a single writer per `run_id` for free, and Phoenix.PubSub guarantees FIFO delivery cluster-wide from a single publisher — so subscribers see step transitions in order without any consumer-side reordering logic. No cluster-wide process registry needed.

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
  steps: [WorkflowStep!]!
  pendingApprovalGate: ApprovalGate
}

type WorkflowStep {
  id: ID!
  sequence: Int!
  name: String!
  status: WorkflowStepStatus!
  output: JSON
  pauseForReview: PauseForReviewMeta
  outputRevisions: [StepOutputRevision!]!
}

type PauseForReviewMeta {
  editor: EditorType!   # MARKDOWN | CODE_DIFF | JSON | PROMPT | COMMAND_LIST
  label: String
}

type StepOutputRevision {
  version: Int!
  output: JSON!
  editedBy: User
  editedAt: DateTime!
}

enum WorkflowRunStatus { PENDING RUNNING AWAITING_APPROVAL COMPLETED FAILED CANCELLED }
enum WorkflowStepStatus { PENDING RUNNING AWAITING_REVIEW COMPLETED FAILED SKIPPED }

# Top-level queries
type Query {
  projects(filter: ProjectFilter): [Project!]!
  project(id: ID!): Project
  worktree(id: ID!): Worktree
  workflowRun(id: ID!): WorkflowRun
  auditEvents(filter: AuditEventFilter): [AuditEvent!]!   # source of agent activity history
  cluster: ClusterStatus!                                  # cross-node fan-out
}

# Mutations
type Mutation {
  startWorkflowRun(input: StartWorkflowRunInput!): WorkflowRunPayload!
  editWorkflowStepOutput(input: EditStepOutputInput!): WorkflowStepPayload!
  resumeWorkflowRun(input: ResumeRunInput!): WorkflowRunPayload!
  approveGate(input: ApproveGateInput!): ApprovalGatePayload!
  rejectGate(input: RejectGateInput!): ApprovalGatePayload!
  archiveWorktree(input: ArchiveWorktreeInput!): WorktreePayload!
}

input EditStepOutputInput {
  stepId: ID!
  output: JSON!
  expectedVersion: Int!  # optimistic locking
}
```

Most of this is generated by AshGraphql from the resource definitions; the manual surface is the queries/mutations exposed and any custom field resolvers (e.g., `cluster` for the cross-node fan-out).

### 4.2 Phoenix Channels (live layer)

| Channel topic | Source | Status |
|---|---|---|
| `forge:sessions` | `JidoClaw.Forge.PubSub` | Already broadcast; needs channel proxy |
| `forge:session:<id>` | `JidoClaw.Forge.PubSub` | Already broadcast; needs channel proxy |
| `worktrees:project:<project_id>` | New PubSub topic | Broadcast on Worktree create/update/archive |
| `conversations:session:<id>` | New PubSub topic + bridge from SignalBus | Bridge `Conversations.Recorder` to also broadcast |
| `workflows:run:<id>` | `Orchestration.RunPubSub` (published by `WorkflowRunner`) | Already broadcast; needs channel proxy |
| `workflows:project:<project_id>` | New aggregated topic | For the project-level workflow list |
| `approvals:user:<user_id>` | `Platform.Approval` topic exists | Channel proxy + filter |
| `cluster:nodes` | New | `:net_kernel.monitor_nodes/1` → broadcast |

Channel events carry minimal payloads (resource id + change type). The client refetches via GraphQL using the id. This avoids duplicating shape between the channel payload and the GraphQL schema.

On reconnect, the client refetches the current state via GraphQL — no event replay, no sequence tracking on the wire. Workflow runs are pinned to a single writer (§3.4), so events arrive in order while connected; missed-while-offline events are recovered by simply re-querying.

### 4.3 Plain controllers / GraphQL fields for non-Ash, runtime/cluster data

Some data isn't backed by Ash resources — per-node in-memory state, YAML skills, cluster topology. Two options: bespoke Phoenix controllers, or generic Ash actions on a synthetic `System` resource exposed through GraphQL. The latter keeps the client surface uniform (one transport for queries) at the cost of a slightly contorted resource:

- `cluster: ClusterStatus` — node list, version per node, uptime per node. Implementation: `:erpc.multicall` fan-out.
- `agentRuntime: [NodeAgentSnapshot!]!` — per-node `AgentTracker` snapshot for **live** state only (currently running agents, current tool, in-flight tokens). Fanned out and merged via `:erpc.multicall`. **Historical** agent activity is sourced from `Audit.Event` aggregations via the regular AshGraphql side — `AgentTracker` stays in-memory per-node and is not promoted to a DB-backed resource.
- `forgeRuntime: [NodeForgeSnapshot!]!` — per-node `Forge.Manager` state.
- `skills: [Skill!]!` — list YAML skills available on each node (skills are not DB rows).
- `runSkill(input: RunSkillInput!): SkillRunPayload!` — kick a skill on a chosen node.

Lean: GraphQL via synthetic resources for uniformity. The fan-out implementation lives in custom resolvers.

### 4.4 Auth

A single API key authenticates both the GraphQL endpoint and the WebSocket, validated by the existing `JidoClaw.Web.Plugs.ApiKeyAuth` (Bearer / `x-api-key`) against an Ash user. Extend `UserSocket` to accept the same key alongside its current Ash session auth.

The control plane is **not** intended for open-internet exposure; access is gated at the network layer by Tailscale tailnet ACLs. RBAC, per-device keys, and rotation tooling are explicitly out of scope unless the trust assumption changes.

### 4.5 Endpoints retained

- `POST /v1/chat/completions` — OpenAI-compatible streaming chat. Untouched.
- `POST /webhooks/github` — HMAC-verified webhook. Untouched.
- `GET /health` — unauth health/version. Untouched.

### 4.6 Endpoints replaced

- `/ws` channel `rpc:*` — the current `gateway.status`, `sessions.list`, `sessions.create`, `sessions.sendMessage` handlers either move to GraphQL mutations (`createSession`, `sendMessage`) or get superseded by the new channel topics. Old channel can stay during transition.
- All LiveView pages become optional (the new client replaces them) but don't need to be removed — the dashboard remains useful for local operator work.

---

## 5. The Novel Feature — Step-Type-Specific Editors

The "edit the draft output between steps" feature is what makes this control plane interesting. It's also the part that requires the most design.

### 5.1 Concept

Every workflow step produces an `output`. By default, the next step consumes it as-is. With `pause_for_review`, the run pauses after the step completes; the UI shows an editor *typed for the kind of output*; the user edits or approves; the (possibly edited) output is what the next step receives.

A diff-editor for code patches, a markdown editor for prose, a JSON editor for structured data, a prompt editor for "the next instruction to send to the model." The editor is chosen by the step's declared editor type, not by the UI guessing.

### 5.2 Workflow definition format

Workflows are defined separately from skills (see §3.4 — a skill may *invoke* a workflow but is not itself a workflow). A workflow definition lives somewhere distinct from `.jido/skills/` — likely `.jido/workflows/`, exact location TBD (see §6) — and looks like:

```yaml
name: feature_with_review
type: pipeline
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

The list is intentionally short. Adding an editor type is a coordinated change between the YAML schema, the runner, and the client — that friction is good; it stops the surface from sprawling.

### 5.4 Lifecycle

```
[step starts]
  WorkflowStep.status: :pending → :running

[step completes, pause_for_review present]
  WorkflowStep.output: <model output>
  WorkflowStep.status: :running → :awaiting_review        ← new state
  WorkflowRun.status: :running → :awaiting_approval
  ApprovalGate row created with editor metadata
  Broadcast on workflows:run:<id>

[user views in UI]
  GraphQL: query { workflowStep(id) { output, pauseForReview { editor, label } } }
  Client renders matching editor

[user edits]
  GraphQL: mutation editWorkflowStepOutput(stepId, output, expectedVersion)
  Each edit appended to a step_output_revisions table (audit trail)
  Optimistic concurrency: expectedVersion must match current

[user approves]
  GraphQL: mutation resumeWorkflowRun(runId)
  WorkflowStep.status → :completed
  WorkflowRun.status → :running
  Next step starts; consumes the edited output

[user rejects]
  GraphQL: mutation cancelWorkflowRun(runId)  (or)
  GraphQL: mutation retryWorkflowStep(stepId)  (re-run with same inputs)
```

### 5.5 Open design questions for editors

- **Edit in place vs. revisions table?** Editing `WorkflowStep.output` directly is simple but loses the original LLM output. A `step_output_revisions` table preserves history at small cost. **Lean: revisions table** — audit value is high.
- **Server-side validation per editor type?** Should `code_diff` editor reject malformed diffs server-side, or trust the client? **Lean: server-side parse, return GraphQL field errors.**
- **Concurrent reviewers?** Two users open the same paused step. **Lean: optimistic locking via `expectedVersion` field on the mutation.**

---

## 6. Open Questions

Things we explicitly deferred during the exploration. Each has a real decision to make before building.

1. **Workflow definition format & location.** Workflows are distinct from skills (§3.4) and need their own definition format and home — likely `.jido/workflows/`, with a YAML (or other) format the runner reads. The shape may resemble the existing skill DAG, but it should be its own format, not a reuse. Open: file format details, directory layout, and the conventions for invoking a workflow from a skill.
2. **Push notification trigger taxonomy.** With the React PWA + Web Push path settled (§2.6), the open question is *which* events warrant a push: workflow step needs review, workflow failure, approval gate timeout, long-running job complete? Worth defining the trigger set before wiring the subscription endpoint.
3. **GraphQL codegen tooling.** Apollo's recommended client codegen approach has shifted (the older `typescript-react-apollo` plugin is no longer the recommendation). Pick the current Apollo-blessed option when the time comes, rather than locking in now.
4. **Codename.** `argus` is provisional. Other options floated mentally: `helm`, `atlas`, `tower`, `bridge`. Bikeshed-class.

---

## 7. Sequencing — Suggested Order of Work

This is suggestive, not prescriptive. Each item is roughly self-contained and shippable.

1. **Finish the workflow runner** — wire `plan_workflow.ex` (still in-memory `Task.async_stream`) to persist `WorkflowRun`/`WorkflowStep` rows. The cron-driven `WorkflowRunner` already creates a `WorkflowRun` row and broadcasts run-level lifecycle events on `RunPubSub`, but no code persists `WorkflowStep` rows yet. Unblocks every "view workflows" feature with zero new resources.
2. **Add `pause_for_review` to the runner** without editor types — just a binary "pauses on user approval, resumes." Validates the lifecycle before committing to editor-type design.
3. **Introduce `Worktrees` domain + `Worktree` resource** layered on top of existing `Workspace` (per §3.3). Worktree is created when a workspace's path is a managed git checkout under a known Project. No changes to Workspace's schema, callers, or policy aggregates. Smallest schema change that unlocks the UI's main hierarchy.
4. **Stand up AshGraphql** on the resources from §4.1. Mostly mechanical — extension declarations + the schema module + custom resolvers for the synthetic `System` resource. Wire Apollo Client + GraphQL codegen on the React side (codegen tooling per §6.3).
5. **Bridge `Conversations.Recorder` to a Phoenix.PubSub topic** so live message activity reaches the channel layer.
6. **Wire Phoenix Channels** for `forge:session:<id>`, `workflows:run:<id>`, `conversations:session:<id>`. Build the first non-LiveView client against this.
7. **Editor types** — add the YAML extension and editor metadata to `pause_for_review`; build the first editor (markdown) end-to-end; iterate.
8. **Cluster fan-out resolvers** — the `cluster`, `agentRuntime`, `forgeRuntime`, `skills` GraphQL fields. Lower priority; useful but not blocking.
9. **Push notifications** via Web Push for the installed PWA. Define the trigger taxonomy (§6.2) and wire the subscription endpoint.

Steps 1-2 could each be a single PR; step 3 is one Ash resource and a migration; step 4 is mostly boilerplate; step 7 is the "interesting" UX work and probably wants real-world iteration before polishing.

---

## Appendix A — Current State Audit

File:line citations for the existing surface, captured during this exploration. All paths relative to `lib/` unless noted.

### A.1 External API surfaces today

**MCP server (stdio)** — `mix jidoclaw --mcp`
- Entry point: `mix/tasks/jidoclaw.ex:10` sets `:serve_mode = :mcp`.
- Wiring: `jido_claw/application.ex:269-295` starts `JidoClaw.MCPServer` only in MCP mode.
- Server module: `jido_claw/core/mcp_server.ex` — `use Jido.MCP.Server`, lists 15 tools at lines 17-35.
- Transport: stdio only. No auth (process trust).
- Internal-only loopback MCP for the consolidator: `jido_claw/memory/consolidator/mcp_endpoint.ex:17-28` (Bandit, `127.0.0.1:0`).

**Phoenix HTTP API** — `jido_claw/web/router.ex`, started when `:mode in [:gateway, :both]` (`application.ex:244-253`)
- `GET /health` (line 38) — unauth health/version.
- `POST /v1/chat/completions` (line 45) — OpenAI-compatible chat with SSE streaming, auth via `Authorization: Bearer` or `x-api-key` against Ash users (`web/plugs/api_key_auth.ex`).
- `POST /webhooks/github` (line 51) — HMAC-verified webhook ingress.
- `/admin` (Ash Admin), `/live-dashboard` (dev only), LiveViews at `/`, `/forge`, `/workflows`, `/agents`, `/projects`, `/settings`, `/folio`, `/sign-in`, `/setup`.
- WebSocket `/ws` mounted at `web/endpoint.ex:20`. Channel `rpc:*` (`web/channels/rpc_channel.ex`) handles `gateway.status`, `sessions.list`, `sessions.create`, `sessions.sendMessage`. `sessions.list` reads in-memory `JidoClaw.SessionRegistry` only — does NOT see `Conversations.Session` rows.

**Discord bot** — `jido_claw/platform/channel/discord_consumer.ex`
- Enabled when `DISCORD_TOKEN` is set (`application.ex:38-53`); MCP mode forces it off.
- Only handles `MESSAGE_CREATE` and `READY`. **No slash commands, no application commands registered.**
- Inbound messages routed to `JidoClaw.chat/3` keyed by `discord_<channel_id>`.

### A.2 Project/Worktree concept

- `JidoClaw.Projects.Project` Ash resource — `projects/project.ex:1-77`. Attributes: `id`, `name`, `github_full_name`, `default_branch`, `settings`, timestamps. Domain at `projects.ex:1-11`.
- `/projects` LiveView — `web/live/projects_live.ex:6-9` does `Ash.read!(Project, authorize?: false)`, renders static table.
- `Workspace.project_id` field exists at `workspaces/resources/workspace.ex:164-167`, used in `workspaces/resolver.ex:47`. **Nullable, and the RPC `sessions.create` path (`web/channels/rpc_channel.ex:57-58`) does not pass it.**
- **No `worktree` references in the codebase.** Grep for `worktree` in `lib/` returns only one unrelated hit in `solutions/resources/reputation_import.ex`. No `git worktree` shell calls anywhere.

### A.3 Session / activity history

**Persisted:**
- `Conversations.Message` — `conversations/resources/message.ex:1-80`. Roles `[:user, :assistant, :tool_call, :tool_result, :reasoning, :system]`, monotonic per-session sequence. Written by `Conversations.Recorder` (`conversations/recorder.ex:1-60`) which subscribes to `ai.*` signals on `JidoClaw.SignalBus`.
- `Audit.Event` — `audit/resources/event.ex:1-80`. Append-only `audit_events`.
- `Forge.Resources.Event` — `forge/resources/event.ex:1-100`. Per-forge-session events with `read :for_session` (paginates by `after`, `event_types`, `after_sequence`).
- `AgentTracker` — `agent_tracker.ex:1-273`. **In-memory only**, per-agent tokens / tool calls / status. Subscribes to SignalBus patterns `jido_claw.tool.*`, `jido_claw.agent.*`. No persistence; resets between conversations.

**Live streaming:**
- `JidoClaw.SignalBus` — `core/signal_bus.ex:1`. Wraps `Jido.Signal.Bus`. Used by Recorder/Tracker.
- `JidoClaw.Forge.PubSub` — `forge/pubsub.ex:1-43`. Topics `forge:sessions` and `forge:session:<id>`. **Broadcasts are real and active**: `forge/manager.ex:116,139,182,207` (lifecycle), `forge/harness.ex:116,275,290,312,539,543,551,559,611,638` (`:ready`, `:needs_input`, `:error`, `:stopped`).
- Approval requests: topic `"approvals"` at `platform/approval.ex:103-107`.
- **No PubSub for `Conversations.Message` appends or `Conversations.Session` lifecycle.** The Recorder writes to Postgres but doesn't fan out.

### A.4 Workflows / orchestration

**Persisted state machine (full schema, mostly unused):**
- `Orchestration.WorkflowRun` — `orchestration/workflow_run.ex:1-174`. Status `[:pending, :running, :awaiting_approval, :completed, :failed, :cancelled]`. Transition actions: `start`, `await_approval`, `resume`, `complete`, `fail`, `cancel`. `belongs_to :project`. Reads include `:list_active` and `:by_project`.
- `Orchestration.WorkflowStep` — `orchestration/workflow_step.ex:1-118`. Status `[:pending, :running, :completed, :failed, :skipped]`. Has `output :map`, `sequence :integer`, `belongs_to :workflow_run`.
- `Orchestration.ApprovalGate` — `orchestration/approval_gate.ex:1-109`. Status `[:pending, :approved, :rejected]`. Actions `:create`, `:approve`, `:reject`, `:list_pending_for_run`. `belongs_to :workflow_run`, `:requester`.

**The runner does not use any of this.**
- `workflows/plan_workflow.ex:1-100` uses synchronous `Task.async_stream` over phases.
- Never reads or writes `WorkflowRun` / `WorkflowStep` rows.
- Never checks `ApprovalGate`.
- `Workflows.StepResult` (`workflows/step_result.ex`) is a transient struct, not persisted.

**Skill YAML format** (`.jido/skills/iterative_feature.yaml`): fields `name`, `template`, `task`, `depends_on`, `produces`, `consumes`. This is a *skill* definition — skills extend agent capabilities and may invoke workflows, but are conceptually distinct (see §3.4). **No separate workflow definition format exists today**; `plan_workflow.ex` operates on phases derived in code rather than from a workflow file. `pause_for_review` doesn't exist anywhere yet.

**`Platform.Approval`** (`platform/approval.ex:1-149`): tool-call approval only, ETS + GenServer, in-memory. **NOT wired to `Orchestration.ApprovalGate`.** Two separate concepts in the codebase.

**Live broadcast:**
- `Orchestration.RunPubSub` — `orchestration/run_pubsub.ex:1-17`. Defines topics `orchestration:run:<id>` and `orchestration:runs`. `DashboardLive` subscribes via `RunPubSub.subscribe_all/0` (`dashboard_live.ex:17`), handling run events at `dashboard_live.ex:97`.
- **`RunPubSub.broadcast/2` is published by `WorkflowRunner`** (`:run_started`/`:run_completed`/`:run_failed` at `workflow_runner.ex:108,172,199` via the helper at `:218`) and consumed by `DashboardLive` (`dashboard_live.ex:97`).

**`/workflows` LiveView** — `web/live/workflows_live.ex:1-52`. Trivial: `Ash.read!(WorkflowRun, authorize?: false)`, table of name/type/status/started_at. No drill-in, no steps, no approvals UI.

### A.5 RPC channel coverage

`web/channels/rpc_channel.ex:14-94` handles only:
- `gateway.status`
- `sessions.list` (in-memory `SessionRegistry`, NOT DB rows)
- `sessions.create`
- `sessions.sendMessage`
- catch-all error

**Available-but-unrouted PubSub topics** the channel could trivially proxy:
- `forge:sessions`, `forge:session:<id>` (`forge/pubsub.ex:6-8`) — fully populated.
- `"approvals"` (`platform/approval.ex:105`) — populated for tool-call approvals.
- `orchestration:run:<id>`, `orchestration:runs` — defined; published by `WorkflowRunner`, consumed by `DashboardLive`.

**Missing entirely:**
- PubSub for Project, Worktree, Workspace lifecycle.
- PubSub for Conversations.Message appends and Conversations.Session open/close.
- PubSub for ApprovalGate state changes.
- PubSub for WorkflowStep transitions.
- RPC handlers for `projects.*`, `worktrees.*`, `workflows.*` (start, approve, edit step output), `sessions.history`.

### A.6 Cluster wiring

- libcluster is a dep; `:cluster_enabled` config flag controls activation (per AGENTS.md "Cluster: libcluster + `:pg`").
- `:pg` is the process group registry — used for cluster-aware PubSub fanout.
- Phoenix.PubSub default adapter (PG2-equivalent) broadcasts cluster-wide once nodes are connected. **No additional configuration needed for cross-node PubSub once the cluster forms.**
