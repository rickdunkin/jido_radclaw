# T2-2 AgentView + T2-4 Inspection — Implementation Plan

## Context

The Jidoka exploration doc (`docs/exploration/jidoka/FEATURES-WORTH-BORROWING.md`) lists two paired Tier-2 borrows currently `NOT_ADOPTED`:

- **T2-2 AgentView** — every surface (3 LiveViews, CLI REPL, MCP, Display) currently reinvents the "what is this agent doing right now" projection and the shapes drift. A unified `%JidoClaw.AgentView{}` struct + single `snapshot/2` projection function would let LiveViews/REPL/MCP consume one stable shape over the existing `Trace`/`AgentTracker`/`Conversations`/`Session.Worker` sources.
- **T2-4 Inspection** — there is no `JidoClaw.inspect_agent(id)` that returns a single shape for definition + last request + active state. Debugging a misbehaved agent today requires stitching together `AgentTracker.get_agent/1`, the agent's `strategy_opts/0`, `Conversations.Session.metadata`, and the Trace surface by hand.

Both borrows are now unblocked: T1-1 Trace, T1-2 Compaction, T1-3 Output, T1-4 Error, and T2-1 Handoff have all landed and supply the sources these projections need to consume. The user-selected v1 scope is **data layers + two MCP tools + a rewire of the static `agents_live.ex` stub**. No macros, no lifecycle callbacks, no broader consumer migration.

Outcome: a stable read-only projection surface that future LiveView/REPL/MCP work can consume without each consumer re-deriving session/agent state from raw sources.

## Module Layout

```
lib/jido_claw/agent_view.ex                  — %JidoClaw.AgentView{} + snapshot/2 + to_mcp_map/1
lib/jido_claw/inspection.ex                  — JidoClaw.Inspection (3 polymorphic entry points)
lib/jido_claw/inspection/summary.ex          — %JidoClaw.Inspection.Summary{}
lib/jido_claw/tools/agent_status.ex          — MCP tool wrapping AgentView.snapshot/2
lib/jido_claw/tools/inspect_agent.ex         — MCP tool wrapping Inspection.inspect_agent/1
lib/jido_claw/web/live/agents_live.ex        — REWIRE: consume AgentView (currently static stub)
lib/jido_claw/orchestration/workflow_run.ex  — add `define(:by_id, action: :read, get_by: [:id])`
lib/jido_claw/core/mcp_server.ex             — register two new tools in publish.tools
lib/jido_claw.ex                             — add top-level `inspect_agent/2`, `inspect_request/2`, `inspect_workflow/1` delegating to JidoClaw.Inspection (full T2-4 adoption)

test/jido_claw/agent_view_test.exs
test/jido_claw/inspection_test.exs
test/jido_claw/inspection/summary_test.exs
test/jido_claw/tools/agent_status_test.exs
test/jido_claw/tools/inspect_agent_test.exs
test/jido_claw/web/live/agents_live_test.exs
test/jido_claw/mcp_server_test.exs           — UPDATE existing assertion at :59 (15 → 17 tools, assert new modules present)
```

The two top-level modules sit at `lib/jido_claw/*.ex` as peers of `lib/jido_claw/trace.ex`. They are independent — no shared "snapshot context" struct (AgentView is session-axis, Inspection is agent-axis).

## `%JidoClaw.AgentView{}` and `snapshot/2`

### Struct

Fields (with `@type t :: %__MODULE__{...}` typespec; defaults `nil` or `[]` unless noted):

```
# Identity
tenant_id            String.t            (required, non-nil)
session_id           String.t            (required, runtime session id)
session_uuid         String.t | nil      (Conversations.Session.id — durable handle)
workspace_id         String.t | nil
agent_id             String.t | nil      (runtime trace key — "handoff:<uuid>:<template>" or session_id)
agent_template       String.t | nil      ("main" | "reviewer" | …)
agent_module         module | nil        (JidoClaw.Agent or JidoClaw.Agent.Workers.*)

# Lifecycle
status               :idle | :running | :awaiting_handoff | :error | :hibernated | :agent_lost
request_id           String.t | nil
handoff_owner        nil | %{template, module, preamble_consumed?, prompt_injected?, updated_at_ms}
started_at           DateTime.t | nil
last_active          DateTime.t | nil
error                nil | %{message, details}

# Conversation
messages             [%{role, content, timestamp}]
message_count        non_neg_integer                  (default 0)
streaming_message    nil                              (v1 placeholder, documented)

# Trace projection
trace_id             String.t | nil
run_id               String.t | nil
trace_status         atom | nil
events               [%JidoClaw.Trace.Event{}]
summary              map                              (verbatim from Trace.summary — event counts only)

# Optional surfaces
outcome              nil | map
compaction           nil | map
metadata             map
```

Departures from Jidoka's struct: dropped `runtime_context` (lives on `JidoClaw.ToolContext`) and `llm_context` (events carry it via `:model` metadata); added `tenant_id` (always required), `compaction`, `handoff_owner`, `agent_template`.

### `snapshot/2`

```elixir
@type input ::
        %{required(:tenant_id) => String.t(), required(:session_id) => String.t(), optional(:session_uuid) => String.t()}
        | %JidoClaw.Conversations.Session{}
        | %JidoClaw.Session.Worker{}

@type opts :: [
        events_limit: pos_integer() | :infinity,
        messages_limit: pos_integer() | :infinity,
        events_categories: [atom()] | :all,
        actor: map() | nil,
        include_compaction?: boolean()
      ]

@spec snapshot(input(), opts()) :: {:ok, t()} | {:error, term()}
```

Defaults: `events_limit: 100`, `messages_limit: 50`, `events_categories: [:request, :model, :tool, :output, :handoff, :reasoning]`, `include_compaction?: true`, `actor: JidoClaw.Authorization.Actor.system(tenant_id)`. Note: `:error` is **not** a Trace category — failures are surfaced via `event.status == :failed` on the existing categories ([event.ex](../../lib/jido_claw/trace/event.ex)). The `error` field on AgentView still derives from "latest event with `status: :failed`".

Algorithm:

1. **Normalize input** to `(tenant_id, session_id, session_uuid?, workspace_id?, actor)`.

   **Identity vocabulary** (clarified up front because two ids are easily confused):
   - **runtime `session_id`** = `Conversations.Session.external_id` — the string used by the live OTP layer. Keys for `Session.Worker` registration, `Handoff.Registry`, `Session.Supervisor.list_sessions/1`.
   - **`session_uuid`** = `Conversations.Session.id` — the Postgres UUID used for FKs (Messages, RequestCorrelation, compaction snapshots).

   - `%Session{}` form: runtime `session_id := session.external_id`; `session_uuid := session.id`. This is the **only permissive** form — snapshot returns `{:ok, ...}` even with no live worker.
   - `%Session.Worker{}` form: runtime `session_id := worker.id`; `session_uuid := worker.session_uuid` (may be `nil` before hydration).
   - Map form must carry `tenant_id` + `session_id` (runtime); `session_uuid` is optional. If `session_uuid` is supplied at this point, resolve the persisted row via **tenant-scoped** `JidoClaw.Conversations.Session.by_id(session_uuid, tenant: tenant_id, actor: actor)` — **not** `by_id_global/1`, which bypasses multitenancy ([session.ex:199](../../lib/jido_claw/conversations/resources/session.ex)). After resolution, **reject** if the supplied `session_id` does not match `session.external_id` (returns `{:error, :session_id_mismatch}`); otherwise canonicalize on `session.external_id`. Tenant mismatch on `by_id` is treated as unresolved.

   **Strict contract for map input** is enforced **after** step 2 (`safe_worker_info`), not here — a map with no `session_uuid` is still valid if a live worker exists, since the worker carries the UUID. See step 2.5 below.
2. **Resolve worker info safely**. `Session.Worker.get_info/2` is a raw `GenServer.call` and will **exit** if no worker is registered. Wrap in `safe_worker_info/2`:
   ```elixir
   try do
     {:ok, JidoClaw.Session.Worker.get_info(tenant_id, session_id)}
   catch
     :exit, _ -> :no_worker
   end
   ```
   On `:no_worker`, populate `started_at`/`last_active`/`message_count` from a `%Session{}` (if available) or leave `nil`; do not call the GenServer further. **If the worker is present, adopt its `session_uuid`** for downstream durable reads (it may be the only source of the UUID for map input).

2.5. **Enforce strict contract** (map input only, after worker resolution): if `worker_info == :no_worker` AND `session_uuid` is still `nil` (neither supplied by caller nor recovered from a `%Session{}`), return `{:error, :session_not_resolved}`. `%Session{}` and `%Session.Worker{}` inputs skip this gate.
3. **Resolve handoff owner** via `JidoClaw.Agent.Handoff.Registry.owner(tenant_id, session_id)` ([registry.ex:59](../../lib/jido_claw/agent/handoff/registry.ex)). When present → populate `handoff_owner`, `agent_template`, `agent_module`. When `nil` → `agent_template: "main"`, `agent_module: JidoClaw.Agent`.
4. **Pick `agent_id` for Trace lookup** in this preference order:
   - Handoff owner present → `"handoff:<uuid>:<template>"` where `uuid` is `session_uuid || handoff_owner.handoff.session_uuid` (the owner record carries its own UUID — fall back to it if the snapshot input was an unhydrated worker/map with no resolved `session_uuid`, otherwise the constructed id would be `"handoff:nil:reviewer"`).
   - Worker info available and `agent_pid` is alive → use the **PID** directly with `Trace.latest(pid, tenant_id: tenant_id)`.
   - Else → fall back to runtime `session_id` (`JidoClaw.chat/4` threads `session_id` as `routed_agent_id` by default). **Do not default to `"main"`** — that misses web/API traces.
5. **Pull session messages**: worker info available → `Session.Worker.get_messages/2` (also `try/catch :exit`); else → `JidoClaw.Conversations.Message.for_session(session_uuid, ...)` paginated read tenant-scoped (skip if no `session_uuid`).
6. **Pull Trace** via `JidoClaw.Trace.latest(agent_id, tenant_id: tenant_id)` ([trace.ex:134](../../lib/jido_claw/trace.ex)). On `{:error, :not_found}`, leave Trace fields `nil`. Otherwise populate `trace_id`/`run_id`/`request_id`/`trace_status`/`summary`. **Filter by `events_categories` first, then cap**: `events |> filter_categories(opts) |> take_latest(events_limit)`. The reverse order would discard older same-category events when only the most-recent items happen to be in unwanted categories. Branch `events_limit == :infinity` explicitly (skip the `Enum.take/2` call entirely) — passing `:infinity` to `Enum.take(_, -:infinity)` is malformed.
7. **Derive top-level `status`** by cascade — `worker.status == :active` is the normal idle lifecycle ([worker.ex:73](../../lib/jido_claw/platform/session/worker.ex)) and **must not** map to `:running`:
   1. `trace.status == :failed` → `:error` (and populate `error` from latest failed event).
   2. `trace.status == :running` → `:running`.
   3. `handoff_owner` present AND `preamble_consumed? == false` → `:awaiting_handoff`.
   4. worker `status: :hibernated` → `:hibernated`; `:agent_lost` → `:agent_lost`.
   5. fallback → `:idle`.

   **Note on `:done`**: prior drafts had `trace.status in [:completed, :cancelled, :interrupted]` → `:done`. Removed deliberately. AgentView's contract is "what is this agent doing **right now**" — a long-lived session whose last trace completed is `:idle` from the user's perspective. The `trace_status` field carries `:completed` / `:cancelled` / `:interrupted` separately for consumers that want the terminal-state nuance. `status: :done` is therefore not in the enum.
8. **`compaction`** (best-effort, requires `session_uuid`): `JidoClaw.Reasoning.Compactor.Storage.latest(session_uuid, tenant: tenant_id, actor: actor)`. Errors swallowed → field stays `nil`.
9. **`outcome`**: latest `:output` event with `status == :completed`. Best-effort.
10. **Field-level failures absorbed** → return `:ok` with `nil` fields. Reserved errors:
    - `{:error, :tenant_required}` — input missing `tenant_id`.
    - `{:error, :session_not_resolved}` — map input with no live worker and no resolvable `session_uuid`.
    - `{:error, :session_not_found}` — `session_uuid` supplied but tenant-scoped `Session.by_id` returns not-found (covers tenant mismatch).

A co-located `AgentView.to_mcp_map/1` projects the struct to a JSON-safe map. Recursive normalization handles:
- **Atoms** → strings (including nested atoms inside `summary`, `compaction`, event `category`/`event`/`status`/`phase`, `handoff_owner.template`, etc.).
- **`DateTime`** → `DateTime.to_iso8601/1`; **`NaiveDateTime`** → `NaiveDateTime.to_iso8601/1` (distinct functions — `DateTime.to_iso8601/1` won't accept a `%NaiveDateTime{}`).
- **Module values** (`agent_module`, handoff `module`) → dropped from output (modules are not meaningful over MCP) or serialized as their `inspect` string if explicitly needed.
- **`MapSet`** → list (e.g. AgentTracker `tool_names`).
- **PIDs / refs** → dropped (never sent over MCP).
- **`%Trace.Event{}`** → slimmed to `%{seq, at_ms, category, event, status, name, duration_ms}` with all atom values stringified; `measurements` and `metadata` recursively normalized.

The normalization is implemented as a private `jsonify/1` helper with explicit clauses; tests assert "no leaf atoms" AND "no leaf DateTimes" AND "no leaf modules" via a recursive walker.

## `%JidoClaw.Inspection.Summary{}`

Matches Jidoka's `Debug.summary` shape field-for-field, adapted to jido_radclaw sources:

```
# Definition
system_prompt        String.t | nil
skills               [%{name, description, version}]
tool_names           [String.t]
mcp_tools            [String.t]
context_preview      String.t | nil

# Running
memory               nil | %{namespace, blocks_count, scope}
compaction           nil | map                (shape ≡ AgentView.compaction)
subagents            [%{id, status, template, last_tool}]
workflows            [%{id, name, status, started_at}]
handoffs             nil | %{template, from_template, message, updated_at_ms}
usage                %{input_tokens, output_tokens, cost: nil}
duration_ms          non_neg_integer | nil
interrupt            map | nil
error                map | nil
message_count        non_neg_integer | nil

# Carry-through
request_id           String.t | nil
input_kind           :module | :pid | :agent_id | :session | :request_id | :workflow_id
resolved_at_ms       integer
```

## `JidoClaw.Inspection`

Three public functions. **None raise** — every field extraction is wrapped in a `safe/2` helper that rescues exceptions and catches exits, turning failures into `nil` fields. `{:error, ...}` is reserved for unresolvable inputs.

### `inspect_agent/1` / `inspect_agent/2`

```elixir
@spec inspect_agent(
        module()
        | pid()
        | String.t()
        | %JidoClaw.Conversations.Session{}
        | %{tenant_id: String.t(), session_id: String.t()},
        keyword()
      ) :: {:ok, Summary.t()} | {:error, term()}
```

Dispatch order:

1. `is_atom(target)` and `function_exported?(target, :strategy_opts, 0)` → **module path** (`input_kind: :module`).
   - `tool_names` ← extract from `target.strategy_opts() |> Keyword.fetch!(:tools)` then map to action names (`module.name/0` per `Jido.Action`). Works uniformly for `JidoClaw.Agent` and every worker module (which all `use JidoClaw.Agent.Defaults`). The main agent additionally exposes `tool_modules/0` ([agent.ex:66](../../lib/jido_claw/agent/agent.ex)) but we route through `strategy_opts` for uniformity.
   - `system_prompt` ← `JidoClaw.Agent.Prompt.build_snapshot/2` (cwd-derived).
   - `skills` ← `JidoClaw.Skills.all/0`.
   - `mcp_tools` ← MCP publish list module-name → tool-name.
   - Running-state fields stay `nil`.
2. `is_pid(target)` → **pid path** (`input_kind: :pid`). `Jido.AgentServer.state(pid)` → derive `agent_id`/`module` from `state.agent.id`; **`request_id` lives at `state.agent.state[:last_request_id]`** (not top-level `state.last_request_id` — matches how `JidoClaw.Trace` resolves agent server state). Fall through to running-state assembly via the agent-id path.
3. `is_binary(target)` → **agent-id path** (`input_kind: :agent_id`).
   - Pattern `"handoff:" <> rest` parses `<session_uuid>:<template>`. The Handoff Registry is keyed by **runtime session id**, not session UUID ([registry.ex:39](../../lib/jido_claw/agent/handoff/registry.ex)). Resolution order: (a) require `opts[:tenant_id]` (missing → `{:error, :tenant_required}`), (b) load `Conversations.Session.by_id(session_uuid, tenant: opts[:tenant_id], actor: actor)`, (c) use `session.external_id` as the runtime session id, (d) `Handoff.Registry.owner(tenant_id, external_id)`, (e) **validate parsed template against `owner.template`** — if the id encodes `reviewer` but the current owner is `coder`, return `{:error, :handoff_not_found}` rather than serving the unrelated owner. If the owner is `nil` entirely, also `{:error, :handoff_not_found}`.
   - Otherwise → `JidoClaw.AgentTracker.get_agent/1` + `JidoClaw.Jido.whereis/1` (not `Jido.whereis/1`) to recover module/template/request_id.
4. `%JidoClaw.Conversations.Session{}` → **session path** (`input_kind: :session`). Derives `(tenant_id, session_id)`, routes through agent-id path using `Handoff.Registry.owner/2`.
5. `%{tenant_id:, session_id:}` map → **session path** (same).
6. Anything else → `{:error, :unknown_target}`.

Field source matrix (running fields populated when paths 2–5 resolve an agent):

| Field | Source |
|---|---|
| `system_prompt` | `JidoClaw.Agent.Prompt.build_snapshot/2` (or `Session.metadata["prompt_snapshot"]` when session-resolved) |
| `skills` | `JidoClaw.Skills.all/0` (module at `lib/jido_claw/platform/skills.ex`) |
| `tool_names` | `module.strategy_opts() \|> Keyword.fetch!(:tools)` → `Enum.map(&apply(&1, :name, []))` |
| `mcp_tools` | MCP publish list module-name → tool-name from `lib/jido_claw/core/mcp_server.ex` |
| `context_preview` | most-recent assistant `Message.content` (truncated 500 chars) |
| `memory` | `nil` in v1 (`JidoClaw.Memory.namespace_info/1` does not exist today). Documented as a deferred surface; if it lands later, populate via guarded `function_exported?/3` + `apply/3`. |
| `compaction` | `Compactor.Storage.latest/2` |
| `subagents` | `AgentTracker.get_state/0` filtered to children (id != "main"). **Global, not tenant-scoped** — AgentTracker is process-global today. Documented as `subagents` (global best-effort) in `Summary` `@moduledoc`. The MCP `inspect_agent` tool omits this field from output for tenant-facing safety in v1 — see MCP section. |
| `workflows` | Reuse the existing `JidoClaw.Orchestration.WorkflowRun.list_active/0` (or equivalent) shape rather than rebuilding a status filter. **Not tenant-scoped today** (same caveat as `subagents`). Documented as "global best-effort"; **omitted from MCP tool output in v1** alongside `subagents`. Local Elixir callers see it. |
| `handoffs` | `Handoff.Registry.owner/2` |
| `usage.input_tokens` / `usage.output_tokens` | **Sum from `:model` events' `measurements.input_tokens` / `measurements.output_tokens`** (not from `trace.summary`, which is event counts only — [collector.ex:564](../../lib/jido_claw/trace/collector.ex)). Fall back to `AgentTracker.get_agent/1.tokens` if no trace |
| `duration_ms` | `Trace.latest/2.completed_at_ms - started_at_ms` |
| `interrupt`, `error` | latest matching event from `Trace.events/2` |
| `message_count` | `safe_worker_info(tenant, session).message_count` or `Conversations.Message.for_session/1` count |

### `inspect_request/1` / `inspect_request/2`

```elixir
@spec inspect_request(String.t(), keyword()) :: {:ok, Summary.t()} | {:error, term()}
# opts: tenant_id (required), actor
```

Algorithm:

0. **Validate opts**: `opts[:tenant_id]` is required; missing → `{:error, :tenant_required}`. `actor` defaults to `JidoClaw.Authorization.Actor.system(opts[:tenant_id])`.
1. `JidoClaw.Trace.for_request({:request, request_id}, request_id, tenant_id: opts[:tenant_id])` ([trace.ex:149](../../lib/jido_claw/trace.ex)). On `{:error, :not_found}` (including wrong-tenant id, since `for_request` enforces tenant filter), return `{:error, :not_found}`. **Do not** return `{:ok, summary_with_nils}` — `Inspection`'s contract is that `{:error, ...}` covers unresolvable inputs, and wrong-tenant request ids are intentionally unresolvable.
2. **`session_uuid` does not live on `%Trace{}`.** Resolve via `JidoClaw.Conversations.RequestCorrelation.lookup(request_id)` ([request_correlation.ex:106](../../lib/jido_claw/conversations/resources/request_correlation.ex)). Pass `tenant: opts[:tenant_id], actor: actor` if the generated `lookup` code interface accepts opts (most Ash code_interface defines do); otherwise validate the returned row's `tenant_id` matches. Cases:
   - **Lookup row found, tenant matches** → `session_uuid` extracted, downstream `context_preview`/`compaction` populated.
   - **Lookup row found, tenant mismatch** → `{:error, :not_found}` (intentional unresolvability, matches Trace's contract).
   - **Lookup row missing/expired** → `session_uuid := nil`. Still return `{:ok, summary}` with `context_preview` and `compaction` left `nil`. The request itself is resolvable from Trace; only the session-derived fields are unavailable.
3. From the resulting `%Trace{}` + correlation row:
   - `usage` ← sum `:model` events' `measurements.input_tokens` / `output_tokens`.
   - `duration_ms` ← `completed_at_ms - started_at_ms`.
   - `interrupt`, `error` ← latest event with matching status.
   - `context_preview` ← `Conversations.Message.by_request(session_uuid, request_id, tenant: tid)` last assistant message, truncated.
   - `compaction` ← `Compactor.Storage.latest(session_uuid, ...)`.
4. `input_kind: :request_id`.

### `inspect_workflow/1`

```elixir
@spec inspect_workflow(String.t() | %JidoClaw.Orchestration.WorkflowRun{}) :: {:ok, Summary.t()} | {:error, term()}
```

Add to `JidoClaw.Orchestration.WorkflowRun.code_interface`:

```elixir
define(:by_id, action: :read, get_by: [:id])
```

(No custom action needed — `get_by` on the default `:read` works.)

Fills `workflows: [%{id, name, status, started_at}]`, `duration_ms` from `completed_at - started_at`, `error` from `run.error`. Agent fields stay `nil`. `input_kind: :workflow_id`.

### Top-level `JidoClaw` delegates

For full T2-4 adoption parity with Jidoka's API, add three thin delegates to `lib/jido_claw.ex`:

```elixir
defdelegate inspect_agent(target, opts \\ []), to: JidoClaw.Inspection
defdelegate inspect_request(request_id, opts \\ []), to: JidoClaw.Inspection
defdelegate inspect_workflow(target), to: JidoClaw.Inspection
```

Documented as one-line conveniences over `JidoClaw.Inspection`.

## MCP Tools

### `lib/jido_claw/tools/agent_status.ex`

Pattern matches `lib/jido_claw/tools/list_agents.ex`. **Tenant is derived strictly from `context.tool_context.tenant_id` — not an MCP-overridable param.** This matches the convention used by other tenant-aware tools and avoids handing the LLM a privilege-escalation lever.

```elixir
use JidoClaw.Tools.Action,
  name: "agent_status",
  description: "Return the live AgentView snapshot for a session: agent template, status, recent events, handoff state, compaction.",
  category: "introspection",
  tags: ["agent", "read"],
  schema: [
    session_id: [type: :string, required: true],
    events_limit: [type: :pos_integer, required: false]
  ],
  output_schema: [
    tenant_id: [type: :string, required: true],
    session_id: [type: :string, required: true],
    agent_template: [type: :string, required: false],
    status: [type: :string, required: true],
    request_id: [type: :string, required: false],
    message_count: [type: :integer, required: true],
    summary: [type: :map, required: false],
    handoff: [type: :map, required: false],
    compaction: [type: :map, required: false],
    recent_events: [type: {:list, :map}, required: true]
  ]
```

`run/2`: read `tenant_id` from `context.tool_context.tenant_id`; return `{:error, :tenant_required}` if absent. Call `AgentView.snapshot/2`; on `{:ok, view}` return `{:ok, AgentView.to_mcp_map(view)}`. On `{:error, reason}` return `{:error, reason}` directly — `JidoClaw.Tools.Action` already wraps `Error.normalize_result/1` around the result ([tools/action.ex](../../lib/jido_claw/tools/action.ex)), so re-normalizing in the tool body is redundant.

### `lib/jido_claw/tools/inspect_agent.ex`

Same `use` pattern, same tenant-from-context discipline.

```elixir
schema: [
  target: [type: :string, required: true, doc: "Module name (\"JidoClaw.Agent\"), agent_id (\"main\", \"handoff:<uuid>:<template>\"), or session_id."],
  kind: [type: {:in, ~w(auto module agent_id session request workflow)}, required: false, default: "auto"]
]
```

MCP JSON sends string values, so the enum is strings (not atoms). `run/2` converts post-validation with explicit `case kind do "module" -> ...; "agent_id" -> ...; ... end`. When `kind == "auto"`, try `String.to_existing_atom/1` for module dispatch (rescue `ArgumentError` → fall back to agent_id). When `kind == "request"`, route to `inspect_request/2`. Tenant comes from `context.tool_context.tenant_id` (same discipline as `agent_status`); error `{:error, :tenant_required}` when absent for the dispatch paths that need it (`handoff:` / session / request). On `{:error, reason}` return the tuple unchanged — `Tools.Action` wraps `Error.normalize_result/1`. Returns `Summary` projected to a JSON-safe map. **The MCP projection drops `:subagents` AND `:workflows`** because both underlying sources (`AgentTracker`, `WorkflowRun`) are not tenant-scoped today; including either would leak cross-tenant runtime state to a tenant-facing tool. Local Elixir callers of `JidoClaw.Inspection.inspect_agent/2` still see both fields — their consumers are trusted infrastructure.

### Registration

Both tools registered in `lib/jido_claw/core/mcp_server.ex` `publish: %{ tools: [...] }`. **The existing test at `test/jido_claw/mcp_server_test.exs:59` (`"publishes 15 tools"`) must be updated** — bump assertion to 17 and add positive assertions for `JidoClaw.Tools.AgentStatus` and `JidoClaw.Tools.InspectAgent`.

## LiveView Rewire: `agents_live.ex`

Current state: 43-line static stub with three hardcoded cards (`lib/jido_claw/web/live/agents_live.ex`).

Replace with — all logic in `mount/3`, **no new `on_mount` callback** (the existing `:live_user_required` mount from `LiveUserAuth` already populates `current_user`):

1. **`mount/3`**: read `socket.assigns.current_user` (set by `JidoClaw.Web.LiveUserAuth` at [live_user_auth.ex:33](../../lib/jido_claw/web/live_user_auth.ex)). Derive `tenant_id := to_string(current_user.id)` matching `JidoClaw.Authorization.Actor.build/1`. When `current_user` is `nil`, assign empty list and return — don't crash.
2. **Initial session list**: `JidoClaw.Session.Supervisor.list_sessions(tenant_id)` returns `[{session_id, pid}]` tuples (live OTP workers — `lib/jido_claw/platform/session/supervisor.ex`). Do **not** use `Session.active_for_workspace/1`, which requires a workspace id we don't have at this layer.
3. **Snapshot per session**: map each `{sid, _pid}` tuple to `JidoClaw.AgentView.snapshot(%{tenant_id: tenant_id, session_id: sid})`; keep only the `{:ok, _}` results; assign as `:agent_views`.
4. **`render/1`**: one card per `%AgentView{}` showing `agent_template`, `status`, `message_count`, last event name; awaiting-handoff banner when `status == :awaiting_handoff`.
5. **Refresh**: schedule only when `connected?(socket)` (avoids duplicate timers on the initial static render). At the end of `mount/3`: `if connected?(socket), do: Process.send_after(self(), :refresh, 5_000)`. In `handle_info(:refresh, socket)`: re-fetch snapshots, then re-schedule with another `Process.send_after`. PubSub-driven refresh deferred.
6. Reuse the existing `status_badge` component used by the current stub.

## Tests

`test/jido_claw/agent_view_test.exs` (uses `JidoClaw.TenantCase`):

1. `%Session{}` input, no live worker → `{:ok, view}` with `:idle`, empty messages, `message_count: 0` (permissive form).
2. Map input with no live worker AND no `session_uuid` → `{:error, :session_not_resolved}` (strict contract).
3. Map input with resolvable `session_uuid` but wrong tenant → `{:error, :session_not_found}`.
4. Live worker (status `:active`) with messages, no Trace → `:idle` (worker `:active` ≠ running).
5. Trace status `:running` → `:running` regardless of worker status.
6. Trace status `:failed` → `:error`, `error` field populated from latest `status: :failed` event.
7. Handoff owner present + `preamble_consumed?: false` → `:awaiting_handoff`, `agent_template == "reviewer"`.
8. `agent_id` selection: handoff → `"handoff:<uuid>:<template>"`; live worker pid present → uses pid; neither → uses `session_id` (not `"main"`).
9. Compaction snapshot written via `Session.set_compaction_snapshot/2` → `:compaction` populated.
10. Filter-before-cap: 10 events (4 `:model`, 6 `:tool`); `events_categories: [:model]`, `events_limit: 3` → all 4 model events surface, then cap to 3 latest (proves filter precedes cap).
11. `events_limit: :infinity` → all events retained, no `Enum.take/2` arity crash.
11b. `messages_limit: 3` against a session with 10 messages → `messages` carries the latest 3, `message_count` is the full underlying count (10).
11c. `messages_limit: :infinity` → all messages retained, no crash.
12. `include_compaction?: false` honored.
13. `to_mcp_map/1` recursive normalization — no leaf atoms, no leaf `DateTime`s, no leaf modules; `:agent_module` dropped; `MapSet` (e.g. `tool_names`) becomes a list.
14. `safe_worker_info` — kill the worker mid-test → no exit propagates; snapshot returns `:ok` for `%Session{}` form.
15. **Identity invariant**: map input where supplied `session_id` does not match `Session.by_id(session_uuid).external_id` → `{:error, :session_id_mismatch}`.
16. Handoff trace lookup uses `handoff_owner.handoff.session_uuid` fallback when input lacks resolved `session_uuid` — constructed agent_id is `"handoff:<owner-uuid>:<template>"`, not `"handoff:nil:<template>"`.
17. **`:done` semantics removed**: completed last trace produces `status: :idle`, `trace_status: :completed` — not `status: :done`.

`test/jido_claw/inspection_test.exs`:

1. Module dispatch: `inspect_agent(JidoClaw.Agent)` → `tool_names` populated, `input_kind: :module`.
2. Worker module dispatch: `inspect_agent(JidoClaw.Agent.Workers.Coder)` → tool_names from `strategy_opts()[:tools]`, matches worker's declared set.
3. PID dispatch: spawn an agent → `input_kind: :pid`.
4. Agent-id (no tracker entry) → `:ok` with all-nil running fields, no raise.
5. Agent-id handoff format `"handoff:<session_uuid>:reviewer"` with `tenant_id` opt → loads `Session.by_id` to derive `external_id`, then `Handoff.Registry.owner(tenant_id, external_id)`. `handoffs` populated.
6. Same input but with a `session_uuid` belonging to a **different** tenant → `{:error, :not_found}` (Session.by_id is tenant-scoped).
7. Handoff agent-id with **no `tenant_id` opt** → `{:error, :tenant_required}`.
8. Handoff agent-id where parsed template (`"reviewer"`) disagrees with current owner template (`"coder"`) → `{:error, :handoff_not_found}`.
9. Handoff agent-id where `Handoff.Registry.owner/2` returns `nil` → `{:error, :handoff_not_found}`.
10. Session struct dispatch → derives current template via Registry.
11. `{tenant_id, session_id}` map dispatch → same.
12. `inspect_request/2` happy path: Trace + `RequestCorrelation.lookup/1` resolves session_uuid, `usage` summed from `:model` events.
13. `inspect_request/2` with **no `tenant_id` opt** → `{:error, :tenant_required}`.
14. `inspect_request/2` tenant isolation — Trace tenant mismatch returns `{:error, :not_found}`.
15. `inspect_request/2` where `RequestCorrelation.lookup/1` returns a row whose `tenant_id` does not match → `{:error, :not_found}` (validates cross-check when code interface lacks opts).
16. `inspect_request/2` where `RequestCorrelation.lookup/1` returns no row (expired/missing) → `{:ok, summary}` with `context_preview` and `compaction` both `nil`, but `usage` / `duration_ms` populated from Trace.
17. `inspect_workflow/1` with `%WorkflowRun{}` struct.
18. `inspect_workflow/1` with UUID string (exercises new `by_id` code_interface).
19. `inspect_agent(:bad_atom)` → `{:error, :unknown_target}`.
20. Safe-rescue: stub a source to raise → field becomes `nil`, no raise.

`test/jido_claw/inspection/summary_test.exs`: struct defaults + typespec smoke (~10 lines).

`test/jido_claw/tools/agent_status_test.exs`:
1. Happy path — running session returns map.
2. Tenant derived from `tool_context.tenant_id`.
3. Missing tenant in context → structured error via `Tools.Error.normalize/1`.
4. Unknown session → structured error.

`test/jido_claw/tools/inspect_agent_test.exs`:
1. `kind: "module"` with `target: "JidoClaw.Agent"` → resolves via `String.to_existing_atom/1`.
2. `kind: "auto"` falls back to agent_id when string isn't a module.
3. `kind: "request"` routes to `inspect_request/2`.
4. Output is JSON-safe (no atoms in leaves).

`test/jido_claw/web/live/agents_live_test.exs`:
1. Authenticated user with no active sessions → renders empty state.
2. With active session → renders a card with status badge.
3. Awaiting-handoff banner shown when applicable.
4. Unauthenticated user → redirect (covered by existing `:live_user_required` mount).

**Test harness note**: there is no existing `ConnCase`/LiveView test harness under `test/support`. Budget either (a) a small `test/support/conn_case.ex` + authenticated-session helper, or (b) write the tests using `Phoenix.ConnTest` + `Phoenix.LiveViewTest` directly with manual session setup. Pick (b) for v1 to minimize new surface; revisit if more LiveView tests follow.

`test/jido_claw/mcp_server_test.exs` (modify existing):
- Update the `"publishes 15 tools"` assertion to `17`, rename label.
- Add `assert JidoClaw.Tools.AgentStatus in tools` and `assert JidoClaw.Tools.InspectAgent in tools` in the appropriate `describe` block.

## Verification

`mix precommit` (see `aliases/0` in `mix.exs`) is the gate. It runs:

1. `compile --warnings-as-errors`
2. `jidoclaw.system_prompt.check`
3. `deps.unlock --unused`
4. `format`
5. `credo --strict`
6. `dialyzer --format short`
7. `test`

Steps to keep it green:

- `@spec` on every public function; `@type t` on AgentView and Summary.
- `@moduledoc` on every public module (`@moduledoc false` acceptable for `Inspection.Summary`).
- Credo `Design.AliasUsage`: alias long modules at the top when used more than ~2x; inline-disable follows the pattern at `lib/jido_claw/agent/defaults.ex:69`.
- Dialyzer PLT lives at `priv/plts/`; first run slow.
- `mix test` depends on `ash.setup --quiet` (see `test` alias in `mix.exs`); tenant-scoped tests use existing helpers under `test/jido_claw/`.

End-to-end after implementation:

```
mix format
mix compile --warnings-as-errors
mix test test/jido_claw/agent_view_test.exs test/jido_claw/inspection_test.exs test/jido_claw/inspection/summary_test.exs test/jido_claw/tools/agent_status_test.exs test/jido_claw/tools/inspect_agent_test.exs test/jido_claw/web/live/agents_live_test.exs test/jido_claw/mcp_server_test.exs
mix precommit
```

Manual smoke checks (optional):

- REPL (`mix jidoclaw`) → drive an agent turn → IEx: `JidoClaw.inspect_agent("main")` and `JidoClaw.AgentView.snapshot(%{tenant_id: "...", session_id: "..."})`.
- Web (`mix phx.server`) → `/agents` renders cards and refreshes.
- MCP (`mix jidoclaw --mcp`) → invoke `agent_status` and `inspect_agent` from a connected client.

## Order of Implementation

1. `lib/jido_claw/agent_view.ex` (struct + `snapshot/2` + `to_mcp_map/1`).
2. `test/jido_claw/agent_view_test.exs`.
3. `lib/jido_claw/inspection/summary.ex` + summary test.
4. `lib/jido_claw/orchestration/workflow_run.ex` — add `define(:by_id, action: :read, get_by: [:id])`.
5. `lib/jido_claw/inspection.ex` + inspection test.
6. `lib/jido_claw.ex` — add three top-level delegates.
7. `lib/jido_claw/tools/agent_status.ex` + `lib/jido_claw/tools/inspect_agent.ex` + their tests.
8. Register both in `lib/jido_claw/core/mcp_server.ex` + update `test/jido_claw/mcp_server_test.exs:59`.
9. Rewire `lib/jido_claw/web/live/agents_live.ex` + LiveView test.
10. `mix precommit` end-to-end.

Per project memory, do **not** commit without explicit user authorization.

## Explicitly Out of Scope (v1)

1. No macro — `use JidoClaw.AgentView` not shipped.
2. No lifecycle callbacks (`before_turn`/`start_turn`/etc.).
3. No CLI Presenters refactor.
4. No REPL refactor to consume AgentView.
5. No `dashboard_live.ex` / `forge_live.ex` migration.
6. No `streaming_message` implementation — `nil` placeholder.
7. No `Tools.ListAgents` refactor.
8. No tenant-scoping of `AgentTracker`.
9. No PubSub-driven refresh in `agents_live.ex` — 5s polling tick.
10. No `Session.by_external` resolution from `{tenant, session}` map input — caller must supply `session_uuid` or `%Session{}` for cold reads.

## Critical Files

New:

- `/Users/rickdunkin/workspace/claws/jido_radclaw/lib/jido_claw/agent_view.ex`
- `/Users/rickdunkin/workspace/claws/jido_radclaw/lib/jido_claw/inspection.ex`
- `/Users/rickdunkin/workspace/claws/jido_radclaw/lib/jido_claw/inspection/summary.ex`
- `/Users/rickdunkin/workspace/claws/jido_radclaw/lib/jido_claw/tools/agent_status.ex`
- `/Users/rickdunkin/workspace/claws/jido_radclaw/lib/jido_claw/tools/inspect_agent.ex`

Modified:

- `/Users/rickdunkin/workspace/claws/jido_radclaw/lib/jido_claw.ex` (3 top-level delegates)
- `/Users/rickdunkin/workspace/claws/jido_radclaw/lib/jido_claw/web/live/agents_live.ex` (rewire)
- `/Users/rickdunkin/workspace/claws/jido_radclaw/lib/jido_claw/orchestration/workflow_run.ex` (`by_id` code_interface)
- `/Users/rickdunkin/workspace/claws/jido_radclaw/lib/jido_claw/core/mcp_server.ex` (register two tools)
- `/Users/rickdunkin/workspace/claws/jido_radclaw/test/jido_claw/mcp_server_test.exs` (bump count + assertions)

Sources reused (read-only):

- `lib/jido_claw/trace.ex` — `latest/2`, `for_request/3`, `events/2`, `spans/2`
- `lib/jido_claw/agent_tracker.ex` — `get_state/0`, `get_agent/1`
- `lib/jido_claw/conversations/resources/message.ex` — `for_session/2`, `since_watermark/2`, `by_request/2`
- `lib/jido_claw/conversations/resources/session.ex` — `by_id/1` (tenant-scoped), `list/0` (NOT `by_id_global/1`, which bypasses multitenancy)
- `lib/jido_claw/conversations/resources/request_correlation.ex` — `lookup/1`
- `lib/jido_claw/platform/session/worker.ex` (`JidoClaw.Session.Worker`) — `get_info/2`, `get_messages/2` (both wrapped in `try/catch :exit`)
- `lib/jido_claw/platform/session/supervisor.ex` — `list_sessions/1`
- `lib/jido_claw/agent/handoff/registry.ex` — `owner/2`
- `lib/jido_claw/reasoning/compactor/storage.ex` — `latest/2`
- `lib/jido_claw/platform/skills.ex` — `all/0`
- `lib/jido_claw/agent/prompt.ex` — `build_snapshot/2`
- `lib/jido_claw/jido.ex` — `whereis/1`
- `lib/jido_claw/web/live_user_auth.ex` — `current_user` assign source
