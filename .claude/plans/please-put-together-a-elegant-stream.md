# Phase 0 Foundation — Implementation Plan

## Context

`docs/plans/v0.6/phase-0-foundation.md` specifies two new Ash domains
(`JidoClaw.Workspaces`, `JidoClaw.Conversations`) plus a `tool_context`
shape upgrade so v0.6's later phases (Solutions tenanting, Conversations
transcripts, Memory, Audit) can land against real FK targets instead of
opaque strings. Today `workspace_id` is overloaded as a per-session
runtime key across Shell/VFS/Profile, and `tenant_id` is threaded
explicitly through every call chain — neither situation changes here;
Phase 0 only adds parallel UUID columns and threads them alongside.

This plan executes the spec verbatim except where the decisions below
resolve ambiguities the spec leaves open.

## Decisions taken

1. **Tenant access** — resolvers take `tenant_id` as a required arg,
   sourced from `tool_context.tenant_id` / `scope_context.tenant_id`.
   No new `Tenant.Manager.current/0`; no process-dict accessor.
2. **`:mcp` Session.kind** — kept in §0.4's enum for forward-compat;
   Phase 0 emits no live `:mcp` Session rows. MCP `tool_context`
   plumbing stays out of scope.
3. **Atom enums** — inline `constraints(one_of: [...])` per attribute.
4. **`Reasoning.Outcome` FKs** — adds **both** `workspace_uuid` and
   `session_uuid` (nullable) alongside the existing string columns.
5. **Module naming** — follows the spec doc literally:
   `JidoClaw.Workspaces` (domain) + `JidoClaw.Workspaces.Workspace`
   (resource), even though Forge/Reasoning use the deeper
   `…Domain.Resources.X` shape.
6. **`chat/3` shim** — preserves today's `tenant_id \\ "default"`
   default for back-compat; emits a one-time `Logger.warning/2`
   keyed on a process-dict sentinel.
7. **`chat/3` vs `chat/4` arity collision** — `chat/4` MUST be
   defined without a default on `opts` (i.e. `def chat(tenant_id,
   session_id, message, opts) when is_list(opts)`); `opts \\ []`
   would generate a `chat/3` clause that collides with the explicit
   shim.
8. **FK attribute pattern** — follow `Folio.Project`
   (`folio/project.ex:81-99`): define the `*_id`/`*_uuid` attribute
   manually in `attributes do`, then declare the relationship in
   `relationships do` with `define_attribute?: false,
   attribute_writable?: true`.
9. **Resolver concurrency** — only the resolvers opt into upsert,
   via `upsert?: true, upsert_identity: …` on **`Ash.create/2`**
   (not on `Ash.Changeset.for_create/4`).
   `Workspace.:register` does NOT declare action-level
   `upsert?(true)`; if it did, a direct `Workspace.register/1` call
   without `upsert_identity` would fall back to primary-key upsert,
   which is wrong for a resource with two partial identities.
   `Session.:start` is allowed to declare action-level
   `upsert?(true)` because it has a single non-partial
   `:unique_external` identity. Both actions still declare
   `upsert_fields` so that *if* upsert is engaged (by the resolver
   or by a future caller), the conflict-time field set is
   restricted — see Decision 10.
10. **Restricted `upsert_fields` (regression safety)** — without
    this, idempotent resolver calls overwrite user-tuned state.
    - `Workspace.:register` → `upsert_fields: [:updated_at]` only.
      Policies (`embedding_policy`, `consolidation_policy`) are
      written on initial create from the resolver's defaults but
      **never overwritten** on conflict; users keep whatever they
      set via `set_embedding_policy/2` /
      `set_consolidation_policy/2`. `name`/`metadata`/`archived_at`
      are similarly preserved.
    - `Session.:start` → `upsert_fields: [:last_active_at,
      :updated_at]` only. `started_at`, `metadata`,
      `idle_timeout_seconds`, `closed_at`, and `next_sequence` are
      preserved across resolver calls.
11. **Path normalization + name derivation in resolver** — resolver
    expands `project_dir` with `Path.expand/1` AND pre-computes
    `name = opts[:name] || Path.basename(expanded)` **before**
    `for_create/3`, since `name allow_nil?: false` validation runs
    before any resource-level `change`. A resource-level
    `change(set_attribute(:name, ...))` defense-in-depth is
    optional but the resolver must not depend on it.
12. **Table names** — `Workspace` → `table("workspaces")`;
    `Session` → `table("conversation_sessions")` (singular domain
    prefix + plural resource, matching `forge_sessions`,
    `folio_actions` precedent and avoiding collision with the
    pre-existing `forge_sessions` table). Snapshot directories will
    be `priv/resource_snapshots/repo/workspaces/` and
    `priv/resource_snapshots/repo/conversation_sessions/`.

## Implementation steps

### 1. New resources + domains

**1.1** `lib/jido_claw/workspaces/domain.ex` (`JidoClaw.Workspaces`) +
`lib/jido_claw/workspaces/resources/workspace.ex`
(`JidoClaw.Workspaces.Workspace`).

```elixir
defmodule JidoClaw.Workspaces.Workspace do
  use Ash.Resource,
    otp_app: :jido_claw,
    domain: JidoClaw.Workspaces,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("workspaces")
    repo(JidoClaw.Repo)

    identity_wheres_to_sql unique_user_path_authed: "user_id IS NOT NULL",
                           unique_user_path_cli: "user_id IS NULL"
  end

  # ...
end
```

`identity_wheres_to_sql` is the DSL **macro form** (per the
user-feedback correction — not a keyword option of the postgres
block). The strings are plain SQL fragments without leading
`WHERE`.

Attributes per §0.2 — manually defined per Decision 8:

- `uuid_primary_key :id`
- `name :string, allow_nil?: false, public?: true`
- `path :string, allow_nil?: false, public?: true`
- `user_id :uuid, allow_nil?: true, public?: true`
- `project_id :uuid, allow_nil?: true, public?: true`
- `tenant_id :string, allow_nil?: false, public?: true`
- `embedding_policy :atom, allow_nil?: false, default: :disabled,
  public?: true` with `constraints(one_of: [:default, :local_only,
  :disabled])`
- `consolidation_policy :atom, allow_nil?: false, default: :disabled,
  public?: true` with the same constraints
- `metadata :map, default: %{}, public?: true`
- `archived_at :utc_datetime_usec, allow_nil?: true, public?: true`
- `timestamps()`

```elixir
relationships do
  belongs_to :user, JidoClaw.Accounts.User,
    define_attribute?: false, attribute_writable?: true
  belongs_to :project, JidoClaw.Projects.Project,
    define_attribute?: false, attribute_writable?: true
end
```

Identities (Decision 9 + the user-feedback correction on syntax):

```elixir
identities do
  identity :unique_user_path_authed, [:tenant_id, :user_id, :path],
    where: expr(not is_nil(user_id))
  identity :unique_user_path_cli, [:tenant_id, :path],
    where: expr(is_nil(user_id))
end
```

Actions per §0.2:

```elixir
actions do
  defaults([:read, :destroy])

  create :register do
    primary?(true)
    # No action-level upsert?(true) — see Decision 9. The resolver opts
    # in via Ash.create/2 with the right :upsert_identity for the
    # supplied user_id. Direct Workspace.register/1 without resolver
    # behaves as a normal create (no upsert) and surfaces a unique
    # constraint error on conflict — the right default for a public
    # write surface.
    upsert_fields([:updated_at])
    accept([:name, :path, :user_id, :project_id, :tenant_id,
            :embedding_policy, :consolidation_policy, :metadata])
  end

  update :rename do
    accept([])
    argument :name, :string, allow_nil?: false
    change(set_attribute(:name, arg(:name)))
  end

  update :archive do
    accept([])
    change(set_attribute(:archived_at, &DateTime.utc_now/0))
  end

  update :set_embedding_policy do
    accept([])
    argument :embedding_policy, :atom, allow_nil?: false,
      constraints: [one_of: [:default, :local_only, :disabled]]
    change(set_attribute(:embedding_policy, arg(:embedding_policy)))
  end

  update :set_consolidation_policy do
    accept([])
    argument :consolidation_policy, :atom, allow_nil?: false,
      constraints: [one_of: [:default, :local_only, :disabled]]
    change(set_attribute(:consolidation_policy, arg(:consolidation_policy)))
  end

  read :by_path do
    get?(true)
    argument :tenant_id, :string, allow_nil?: false
    argument :user_id, :uuid                    # nilable
    argument :path, :string, allow_nil?: false

    filter expr(tenant_id == ^arg(:tenant_id) and path == ^arg(:path) and
                ((is_nil(user_id) and is_nil(^arg(:user_id))) or
                 user_id == ^arg(:user_id)))
  end

  read :for_user do
    argument :tenant_id, :string, allow_nil?: false
    argument :user_id, :uuid, allow_nil?: false
    filter expr(tenant_id == ^arg(:tenant_id) and user_id == ^arg(:user_id))
  end
end
```

`code_interface do … end` block on the resource (per JidoClaw
convention — see `Reasoning.Outcome:48-55`) defines `register/1`,
`rename/2`, `archive/1`, `set_embedding_policy/2`,
`set_consolidation_policy/2`, `by_path/3` (with `get?: true`),
`for_user/2`.

**1.2** `lib/jido_claw/conversations/domain.ex` +
`lib/jido_claw/conversations/resources/session.ex`.

```elixir
defmodule JidoClaw.Conversations.Session do
  use Ash.Resource,
    otp_app: :jido_claw,
    domain: JidoClaw.Conversations,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("conversation_sessions")
    repo(JidoClaw.Repo)
  end

  # ...
end
```

Attributes per §0.4 — manually defined per Decision 8:

- `uuid_primary_key :id`
- `workspace_id :uuid, allow_nil?: false, public?: true` (FK)
- `user_id :uuid, allow_nil?: true, public?: true` (FK)
- `kind :atom, allow_nil?: false, public?: true` with
  `constraints(one_of: [:repl, :discord, :telegram, :web_rpc, :cron,
  :api, :mcp, :imported_legacy])`
- `external_id :string, allow_nil?: false, public?: true`
- `tenant_id :string, allow_nil?: false, public?: true`
- `started_at :utc_datetime_usec, allow_nil?: false, public?: true`
- `last_active_at :utc_datetime_usec, allow_nil?: false, public?: true`
- `closed_at :utc_datetime_usec, allow_nil?: true, public?: true`
- `idle_timeout_seconds :integer, default: 300, public?: true`
- `next_sequence :integer, default: 1, public?: true` (verify the
  generated migration uses `bigint` per §0.4; if not, hand-edit the
  migration)
- `metadata :map, default: %{}, public?: true`
- `timestamps()`

```elixir
relationships do
  belongs_to :workspace, JidoClaw.Workspaces.Workspace,
    define_attribute?: false, attribute_writable?: true
  belongs_to :user, JidoClaw.Accounts.User,
    define_attribute?: false, attribute_writable?: true
end
```

Identity (single, full uniqueness — no partial-where needed):

```elixir
identities do
  identity :unique_external, [:tenant_id, :workspace_id, :kind, :external_id]
end
```

`:start` action with the cross-tenant `before_action` (§0.5.2,
validate-equality shape):

```elixir
create :start do
  primary?(true)
  upsert?(true)
  upsert_identity(:unique_external)
  upsert_fields([:last_active_at, :updated_at])    # Decision 10
  accept([:workspace_id, :user_id, :kind, :external_id, :tenant_id,
          :started_at, :idle_timeout_seconds, :metadata])

  change(set_attribute(:last_active_at, &DateTime.utc_now/0))

  change(fn changeset, _ctx ->
    Ash.Changeset.before_action(changeset, fn cs ->
      tenant_id = Ash.Changeset.get_attribute(cs, :tenant_id)
      workspace_id = Ash.Changeset.get_attribute(cs, :workspace_id)

      case Ash.get(JidoClaw.Workspaces.Workspace, workspace_id,
             domain: JidoClaw.Workspaces) do
        {:ok, %{tenant_id: ^tenant_id}} ->
          cs

        {:ok, %{tenant_id: parent_tenant}} ->
          Ash.Changeset.add_error(cs,
            field: :workspace_id,
            message: "cross-tenant FK mismatch",
            vars: [supplied_tenant: tenant_id, parent_tenant: parent_tenant])

        {:error, _} ->
          Ash.Changeset.add_error(cs,
            field: :workspace_id, message: "workspace not found")
      end
    end)
  end)
end
```

Use `Ash.Changeset.get_attribute/2` to read attrs and
`Ash.Changeset.add_error/2` to surface mismatches (per the
user-feedback correction — never return `{:error, _}` directly from
`before_action`). The `Ash.get/3` runs inside the create
transaction so the parent's `tenant_id` cannot change between fetch
and insert.

This is the **first `before_action` in the codebase** — no existing
resource demonstrates it.

Other actions: `:touch`, `:close`, `:active_for_workspace`,
`:by_external` (the latter as `get?: true` with explicit args).

**Closed-session reuse semantics.** Per Decision 10, `:closed_at`
is NOT in `upsert_fields`, so an `ensure_session/5` call against a
previously closed `(tenant, workspace, kind, external_id)`
returns the existing closed row unchanged (closed_at preserved).
This is intentional for Phase 0 — `closed_at` is informational
per §0.4, no consumer treats a closed session as unusable, and
the `:touch` action exists for consumers that want to bump
`last_active_at`. If a future surface needs explicit reopen
semantics, add a dedicated `:reopen` action that clears
`closed_at`; do not add `:closed_at` to `upsert_fields` (which
would silently reset closure on every upsert).

**1.3** Append `JidoClaw.Workspaces` and `JidoClaw.Conversations` to
`config :jido_claw, :ash_domains` in `config/config.exs:221-230`.

**1.4** Run `mix ash.codegen v060_create_workspaces_and_sessions`.
This generates **both** the migration
(`priv/repo/migrations/<ts>_*.exs`) **and** the resource snapshot
files (`priv/resource_snapshots/repo/workspaces/<ts>.json`,
`…/conversation_sessions/<ts>.json`, updated
`…/extensions.json`). All snapshot files must be committed; `mix
ash.codegen --check` (in §10) compares the live resource shape
against them and fails on drift.

Verify by hand: indexes on `(tenant_id, user_id, path)`,
`(workspace_id, started_at)`, `(tenant_id, workspace_id, kind,
external_id)`, `(tenant_id, last_active_at)`. The two partial
unique indexes carry the correct `WHERE user_id IS [NOT] NULL`
predicates — no precedent in `priv/repo/migrations/`, so review
carefully.

### 2. Resolvers

**2.1** `lib/jido_claw/workspaces/resolver.ex`
(`JidoClaw.Workspaces.Resolver`):

```elixir
@spec ensure_workspace(String.t(), String.t(), keyword()) ::
        {:ok, %Workspace{}} | {:error, term()}
def ensure_workspace(tenant_id, project_dir, opts \\ []) do
  expanded = Path.expand(project_dir)
  user_id = Keyword.get(opts, :user_id)
  name = Keyword.get(opts, :name) || Path.basename(expanded)

  upsert_identity =
    if user_id, do: :unique_user_path_authed, else: :unique_user_path_cli

  attrs = %{
    tenant_id: tenant_id,
    path: expanded,
    name: name,                                       # Decision 11
    user_id: user_id,
    project_id: Keyword.get(opts, :project_id),
    embedding_policy: Keyword.get(opts, :embedding_policy, :disabled),
    consolidation_policy: Keyword.get(opts, :consolidation_policy, :disabled)
  }

  Workspace
  |> Ash.Changeset.for_create(:register, attrs)
  |> Ash.create(upsert?: true, upsert_identity: upsert_identity)
  # ↑ upsert opts on Ash.create/2, not on for_create/3 (Decision 9)
end
```

Per Decision 11, `name` is precomputed *before* `for_create` so that
`allow_nil?: false` validation passes. Per Decision 9, `upsert?` and
`upsert_identity` are options to `Ash.create/2`. Per Decision 10,
the action's `upsert_fields([:updated_at])` ensures repeat calls
don't overwrite policies/metadata users have tuned.

**2.2** `lib/jido_claw/conversations/resolver.ex`
(`JidoClaw.Conversations.Resolver`):

```elixir
@spec ensure_session(String.t(), Ecto.UUID.t(), atom(), String.t(), keyword()) ::
        {:ok, %Session{}} | {:error, term()}
def ensure_session(tenant_id, workspace_id, kind, external_id, opts \\ []) do
  attrs = %{
    tenant_id: tenant_id,
    workspace_id: workspace_id,
    kind: kind,
    external_id: external_id,
    user_id: Keyword.get(opts, :user_id),
    started_at: Keyword.get(opts, :started_at, DateTime.utc_now()),
    idle_timeout_seconds: Keyword.get(opts, :idle_timeout_seconds, 300),
    metadata: Keyword.get(opts, :metadata, %{})
  }

  Session
  |> Ash.Changeset.for_create(:start, attrs)
  |> Ash.create(upsert?: true, upsert_identity: :unique_external)
end
```

The §0.4 cross-tenant `before_action` runs as part of `:start`, so
the resolver doesn't need its own validation. Per Decision 10,
`upsert_fields([:last_active_at, :updated_at])` preserves
`started_at`/`metadata`/`idle_timeout_seconds` across repeat calls
(only the touch fields update).

### 3. `tool_context` shape upgrade in `JidoClaw`

**3.1** Replace `lib/jido_claw.ex:27-38`. Per Decision 7:

```elixir
@spec chat(String.t(), String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
def chat(tenant_id \\ "default", session_id, message)

def chat(tenant_id, session_id, message) do
  warn_chat3_deprecation()
  chat(tenant_id, session_id, message, kind: :api)
end

@spec chat(String.t(), String.t(), String.t(), keyword()) ::
        {:ok, String.t()} | {:error, term()}
def chat(tenant_id, session_id, message, opts) when is_list(opts) do
  # actual implementation
end
```

`chat/4` opts: `:kind` (required — raise `KeyError` if missing
rather than silently defaulting), `:external_id` (defaults to
`session_id`), `:workspace_id` (defaults to `File.cwd!()`),
`:user_id`, `:metadata`.

**3.2** Rewrite `dispatch_to_agent/5` at `lib/jido_claw.ex:55-91`
to resolve workspace + session **before** building tool_context:

```elixir
defp dispatch_to_agent(pid, tenant_id, session_id, message, project_dir, opts) do
  {:ok, workspace} =
    Workspaces.Resolver.ensure_workspace(tenant_id, project_dir,
      user_id: opts[:user_id])

  {:ok, session} =
    Conversations.Resolver.ensure_session(
      tenant_id, workspace.id, opts[:kind],
      opts[:external_id] || session_id,
      user_id: opts[:user_id], metadata: opts[:metadata] || %{})

  tool_context = JidoClaw.ToolContext.build(%{
    project_dir:    project_dir,
    tenant_id:      tenant_id,
    session_id:     session_id,
    session_uuid:   session.id,
    workspace_id:   session_id,           # UNCHANGED — per-session runtime key
    workspace_uuid: workspace.id,
    agent_id:       session_id
  })

  JidoClaw.Agent.ask_sync(pid, message, timeout: 120_000,
    tool_context: tool_context)
  |> handle_response(tenant_id, session_id)
end
```

Per Decision 5 the runtime `workspace_id` keeps its current
overload; `workspace_uuid` is the new field every Phase 1+ DB query
reads.

### 4. Direct `Agent.ask` callers + helper module (§0.5.1 cat. 2)

**4.1** `lib/jido_claw/cli/repl.ex` boot path around line 151 calls
both resolvers (kind `:repl`); per-message handler at lines
242-249 builds the tool_context from `state.tenant_id` /
`state.session_uuid` / `state.workspace_uuid` etc.

**4.2 + 4.3** Extract a shared helper at
`lib/jido_claw/tool_context.ex`. Build the map with explicit
`Map.get/2` so absent keys are present-but-`nil`, not omitted (per
the user-feedback correction — `Map.take/2` would silently drop
unprovided keys, breaking the canonical shape contract):

```elixir
defmodule JidoClaw.ToolContext do
  @moduledoc false

  @canonical_keys [:project_dir, :tenant_id, :session_id, :session_uuid,
                   :workspace_id, :workspace_uuid, :agent_id]

  @doc "Builds the canonical tool_context map. forge_session_key is preserved when set."
  def build(scope) when is_map(scope) do
    base =
      Map.new(@canonical_keys, fn key -> {key, Map.get(scope, key)} end)

    case Map.get(scope, :forge_session_key) do
      nil -> base
      key -> Map.put(base, :forge_session_key, key)
    end
  end

  @doc "Builds a child tool_context, inheriting parent scope, with a new agent_id."
  def child(parent_tool_context, child_tag) when is_binary(child_tag) do
    parent = parent_tool_context || %{}

    parent
    |> Map.put(:agent_id, child_tag)
    |> Map.put(:project_dir, Map.get(parent, :project_dir) || File.cwd!())
    |> build()
  end
end
```

Per the user-feedback correction:

- `forge_session_key` MUST be preserved (today's
  `spawn_agent.ex:44` and `send_to_agent.ex` both propagate it;
  `reasoning/telemetry.ex` reads it for outcome attribution).
- `child/2` uses `Map.put` with an explicit `||` fallback (NOT
  `Map.put_new`) so `%{project_dir: nil}` becomes
  `%{project_dir: File.cwd!()}`. `Map.put_new/3` only inserts when
  the key is absent — it leaves an explicit `nil` in place, which
  would regress today's `spawn_agent.ex:42` behavior of `nil ||
  File.cwd!()`.

`lib/jido_claw/tools/spawn_agent.ex:35-95` and
`lib/jido_claw/tools/send_to_agent.ex` (both branches at :43 and
:52) delete their local `child_tool_context/4` helpers and call
`ToolContext.child(Map.get(context, :tool_context), tag)`. Use
`Map.get/2` (per the user-feedback correction) rather than
`context.tool_context` so sparse test contexts and pre-Phase-0
callers don't raise `KeyError`. After this step the two files have
no remaining duplication.

**4.4** `lib/jido_claw/workflows/step_action.ex`:

- Schema (lines 13-22) gains optional string params: `tenant_id`,
  `session_id`, `session_uuid`, `workspace_uuid`. (`workspace_id`
  is already there; `agent_id` is `tag`.)
- Replace `resolve_workspace_id/3` (lines 130-135) with
  `resolve_scope/3` that runs the same params → context →
  `context.tool_context` → fallback chain. Declare it `@doc false
  def resolve_scope/3` (public-but-undocumented) per the
  user-feedback correction so the §9.6 unit test can call it
  directly — `defp` would force the test to drive it through
  `StepAction.run/2`, which couples a unit test to template lookup.
  Per the same correction, **keep the existing `"wf_#{tag}"`
  fallback for `workspace_id`** (the runtime key); the new scope
  keys (`tenant_id`, `session_id`, `session_uuid`,
  `workspace_uuid`) fall back to `nil`:

  ```elixir
  @doc false
  def resolve_scope(params, context, tag) do
    %{
      tenant_id:      pick(params, context, :tenant_id, nil),
      session_id:     pick(params, context, :session_id, nil),
      session_uuid:   pick(params, context, :session_uuid, nil),
      workspace_id:   pick(params, context, :workspace_id, "wf_#{tag}"),
      workspace_uuid: pick(params, context, :workspace_uuid, nil),
      project_dir:    Map.get(params, :project_dir, File.cwd!()),
      agent_id:       tag
    }
  end

  @doc false
  def pick(params, context, key, fallback) do
    Map.get(params, key) ||
      Map.get(context, key) ||
      get_in(context, [:tool_context, key]) ||
      fallback
  end
  ```

- The `tool_context` build at lines 40-44 calls
  `ToolContext.build(scope)` with the resolved scope.
- Existing ad-hoc test callers using `StepAction.run(params, %{})`
  keep working.

**4.5 (test infrastructure)** Modify
`lib/jido_claw/agent/templates.ex:9` so `get/1` consults a
test-only override before falling back to the static `@templates`
map. **Preserve the existing error shape** (per the user-feedback
correction — current code returns a helpful `{:error, "Unknown
template: …"}`-style string, not `{:error, :unknown_template}`):

```elixir
def get(name) do
  override = Application.get_env(:jido_claw, :agent_templates_override, %{})
  case Map.get(override, name) || Map.get(@templates, name) do
    nil      -> existing_unknown_template_error(name)   # whatever the file already returns
    template -> {:ok, template}
  end
end
```

Read the file before editing to copy the exact existing error
return — do not introduce a new error atom. Override applies to
`get/1` only; `list/0`, `names/0`, and `exists?/1` remain
@templates-only (which is fine for production since overrides only
exist in test). Document this in the function's `@doc` so future
readers know the asymmetry is intentional.

This makes the §9.6 integration test (registering `echo_test` via
`Application.put_env`) feasible without plumbing template lookup
through every workflow driver. No-op in production.

### 5. Workflow drivers (§0.5.1 cat. 3)

Each driver accepts a new `:scope_context` keyword option (a map
carrying **all canonical scope keys except `:agent_id`** — that is,
`tenant_id`, `session_id`, `session_uuid`, `workspace_id`,
`workspace_uuid`, `project_dir`). Per the user-feedback correction,
`workspace_id` (the runtime key for VFS/Shell/Profile continuity
across steps) is included alongside the new UUIDs — leaving it out
would break per-step VFS sharing. `agent_id` is excluded because
each step assigns its own tag. The driver merges `:scope_context`
into the `params` it passes to `StepAction.run` **and** passes the
same map as the second argument so the resolver finds it in either
slot.

- **5.1** `lib/jido_claw/workflows/skill_workflow.ex` — opts at
  line 33; thread through `execute_loop/6`; `StepAction.run(params,
  %{})` at line 117 becomes `StepAction.run(params, scope_ctx)`.
- **5.2** `lib/jido_claw/workflows/plan_workflow.ex` — same shape;
  opts at line 40, `StepAction.run` at line 312.
- **5.3** `lib/jido_claw/workflows/iterative_workflow.ex` — opts
  at line 51, `StepAction.run` at lines 211 and 235.
- **5.4** `lib/jido_claw/tools/run_skill.ex:48-49` — read full
  scope from `context.tool_context` and forward via
  `:scope_context` to the dispatched workflow.

### 6. Surface entry points (§0.5.1 cat. 1)

Each calls `JidoClaw.chat/4` with explicit `:kind`. Authenticated
surfaces also pass `:user_id` (per the user-feedback correction —
without it, web/RPC-resolved Workspaces would land as CLI-style
`user_id: nil` rows and silently match the wrong partial identity).

| File:Line | `:kind` | `:external_id` | `:user_id` |
|---|---|---|---|
| `web/controllers/chat_controller.ex:35` | `:api` | `"api_#{int}"` | `conn.assigns.current_user.id` |
| `web/controllers/chat_controller.ex:68` | `:api` | `"api_stream_#{int}"` | same |
| `web/channels/rpc_channel.ex:59` | `:web_rpc` | client-supplied `session_id` | `socket.assigns.current_user.id` |
| `platform/channel/discord.ex:46` | `:discord` | `"discord_#{channel_id}"` | nil (today's `tenant_for/1` is `"default"`) |
| `platform/channel/telegram.ex:45` | `:telegram` | `"telegram_#{chat_id}"` | nil |
| `platform/cron/worker.ex:116` (`:main`) | `:cron` | `state.agent_id` | nil |
| `platform/cron/worker.ex:120` (`:isolated`) | `:cron` | `"cron_#{id}_#{ts}"` | nil |

**6.x — `sessions.create` plumbing** (per the user-feedback
correction). `lib/jido_claw/web/channels/rpc_channel.ex:39-50`
does NOT call `JidoClaw.chat`; it directly calls
`Session.Supervisor.start_session/2`. To meet §0.7's "New REPL/
Discord/Web RPC sessions create rows" gate, this handler must also
call `Workspaces.Resolver.ensure_workspace/3` and
`Conversations.Resolver.ensure_session/5` (kind `:web_rpc`,
`user_id: socket.assigns.current_user.id`) before/after
`start_session`. Reply payload returns `session.id` (UUID)
alongside `session_id` (string).

The REPL is covered in step 4.1 (it bypasses `chat/*` and is
already wired to call resolvers at boot). MCP server stdio is
Decision 2 — no change.

### 7. `Reasoning.Outcome` sibling FKs

Modify `lib/jido_claw/reasoning/resources/outcome.ex`:

**7.1** Attributes — add `attribute :workspace_uuid, :uuid,
allow_nil?: true, public?: true` and `:session_uuid` (same shape).
Existing string columns unchanged.

**7.2** Relationships (Decision 8 — `define_attribute?: false`):

```elixir
relationships do
  belongs_to :workspace, JidoClaw.Workspaces.Workspace,
    define_attribute?: false, attribute_writable?: true,
    source_attribute: :workspace_uuid
  belongs_to :session, JidoClaw.Conversations.Session,
    define_attribute?: false, attribute_writable?: true,
    source_attribute: :session_uuid
end
```

**7.3** `:record` action's `accept` list (lines 63-87) — append
`:workspace_uuid` and `:session_uuid`.

**7.4** `custom_indexes` block (lines 37-45) — append
`index([:workspace_uuid, :started_at])` and
`index([:session_uuid, :started_at])`.

**7.5** `lib/jido_claw/reasoning/telemetry.ex:190-210` — extend
`with_outcome` to read `:workspace_uuid` / `:session_uuid` from
opts and forward to `Outcome.record/1`.

**7.6** Three telemetry callers — `lib/jido_claw/tools/reason.ex:178-186`,
`lib/jido_claw/tools/run_pipeline.ex:151-155`,
`lib/jido_claw/tools/verify_certificate.ex:119-123` — read the two
new fields from `context.tool_context` and forward.

**7.7** `mix ash.codegen v060_outcome_sibling_fks` (separate from
step 1.4 so the second migration runs after Workspace/Session
tables exist). Commit the resulting migration and updated snapshot
files at `priv/resource_snapshots/repo/reasoning_outcomes/<ts>.json`.

### 8. Cross-tenant FK invariant (§0.5.2)

In Phase 0 only one resource exercises the validate-equality hook:
`Conversations.Session.:start` (already detailed in step 1.2). The
copy-from-parent shape doesn't apply yet because no Phase 0 action
takes an FK without also taking `tenant_id`. Future phases extend
the pattern.

### 9. Acceptance gate tests (§0.7)

Mirror the existing `tool_context` test pattern (13 hits across 6
files in `test/jido_claw/tools/*`).

**9.1** `test/jido_claw/workspaces/workspace_test.exs` — basic
create/identity, plus the §0.7 `embedding_policy` and
`consolidation_policy` default tests (register without policy →
`:disabled`; register with `:default` → `:default`; setter flips
column; the two policies stay independent). **Plus an
upsert-preservation test** (Decision 10): register a workspace with
`embedding_policy: :default`, then call `register/1` again with the
same path/tenant/user but `embedding_policy: :disabled`; assert the
stored value is still `:default` (proving `upsert_fields([:updated_at])`
keeps user-tuned policies intact across resolver calls).

**9.2** `test/jido_claw/conversations/session_test.exs` — basic
create/identity, plus the §0.7 cross-tenant FK invariant fixture:
construct a Workspace at `tenant_id = "T2"`, attempt
`Session.start(workspace_id: that_workspace.id, tenant_id: "T1",
...)`, assert the action errors with the
`"cross-tenant FK mismatch"` message via
`Ash.Error.Changes.InvalidAttribute`.

**9.3** `test/jido_claw/workspaces/resolver_test.exs` — cross-tenant
collision regression (§0.7): same path under two unauthenticated
tenants → two distinct rows; idempotent reuse within a tenant. Also
verify path normalization: `ensure_workspace("default", "./foo")`
and `ensure_workspace("default", "/abs/path/foo")` resolve to the
same row when the cwd makes them equivalent.

**9.4** `test/jido_claw/conversations/resolver_test.exs` —
cross-workspace collision regression (§0.7): two workspaces in one
tenant, `(kind: :cron, external_id: "shared-agent-id")` for each
→ two distinct rows + idempotent reuse.

**9.5** `test/jido_claw/tool_context_shape_test.exs` — two-layer
approach (per the user-feedback correction):

- (a) **Static caller check**: AST-parse each direct caller
  (`lib/jido_claw.ex`, `lib/jido_claw/cli/repl.ex`,
  `lib/jido_claw/tools/spawn_agent.ex`,
  `lib/jido_claw/tools/send_to_agent.ex`,
  `lib/jido_claw/workflows/step_action.ex`); for each `Agent.ask*`
  call site, assert a `tool_context:` keyword option is present
  (any expression form — literal, helper call, variable). This
  catches regressions where someone removes the option entirely.
- (b) **Helper unit test**: `JidoClaw.ToolContext.build/1` and
  `child/2` produce the canonical shape (all 7 canonical keys
  present; `forge_session_key` preserved when set; `child/2`
  defaults `project_dir` to `File.cwd!()` for nil parent). Pin the
  key set as a golden test.

**9.6** `test/jido_claw/workflows/scope_propagation_test.exs` —
two layers:

- **Unit**: `StepAction.resolve_scope/3` with combinations of
  `params` carrying scope, `context` carrying `tool_context`, both,
  neither. Asserts each scope key resolves correctly and
  `workspace_id` falls back to `"wf_#{tag}"` when nothing else
  provides it (per the user-feedback correction).
- **Integration**: with the test override hook from step 4.5, register
  an `echo_test` template via `Application.put_env(:jido_claw,
  :agent_templates_override, %{"echo_test" => %{module: EchoStub,
  description: "echo", model: :fast, max_iterations: 1}})` in
  `setup`. `EchoStub` is a tiny in-test agent module whose `ask_sync`
  returns the received `tool_context`. Run `SkillWorkflow.run/4` with
  a one-step skill targeting `echo_test` and `:scope_context`
  carrying parent values; assert the echoed tool_context reflects
  parent scope. Cover one driver in this integration shape; the
  other two get unit coverage via assertions on params plumbing.

**9.7** `test/jido_claw/reasoning/outcome_test.exs` (extend) —
verify `:record` accepts `:workspace_uuid` + `:session_uuid` and
that the new indexes exist via `JidoClaw.Repo.query!` against
`pg_indexes` (per the user-feedback correction — Tidewave is for
manual interactive use, not test code):

```elixir
test "outcome has workspace_uuid and session_uuid indexes" do
  {:ok, %{rows: rows}} =
    JidoClaw.Repo.query("""
      SELECT indexname FROM pg_indexes
      WHERE tablename = 'reasoning_outcomes' AND indexname LIKE '%uuid%'
    """)

  names = Enum.map(rows, &List.first/1)
  assert "reasoning_outcomes_workspace_uuid_started_at_index" in names
  assert "reasoning_outcomes_session_uuid_started_at_index" in names
end
```

Plus a happy-path test that the telemetry write populates both new
columns when `:workspace_uuid` / `:session_uuid` are present in
`tool_context`.

### 10. Final checks (§0.7 last-mile)

- `mix format --check-formatted`
- `mix compile --warnings-as-errors`
- `mix test`
- `mix ash.codegen --check` — clean (snapshot files committed,
  no pending resource diffs)
- `mix ash_postgres.generate_migrations` — runs without
  `identity_wheres_to_sql` errors

## Critical files to modify

**New files:**
- `lib/jido_claw/workspaces/domain.ex`
- `lib/jido_claw/workspaces/resources/workspace.ex`
- `lib/jido_claw/workspaces/resolver.ex`
- `lib/jido_claw/conversations/domain.ex`
- `lib/jido_claw/conversations/resources/session.ex`
- `lib/jido_claw/conversations/resolver.ex`
- `lib/jido_claw/tool_context.ex` (shared helper, step 4.3)
- `priv/repo/migrations/<ts>_v060_create_workspaces_and_sessions.exs` (auto)
- `priv/repo/migrations/<ts>_v060_outcome_sibling_fks.exs` (auto)
- `priv/resource_snapshots/repo/workspaces/<ts>.json` (auto)
- `priv/resource_snapshots/repo/conversation_sessions/<ts>.json` (auto)
- `priv/resource_snapshots/repo/reasoning_outcomes/<ts>.json` (auto, updated)
- `priv/resource_snapshots/repo/extensions.json` (auto, updated)
- `test/jido_claw/workspaces/workspace_test.exs`
- `test/jido_claw/workspaces/resolver_test.exs`
- `test/jido_claw/conversations/session_test.exs`
- `test/jido_claw/conversations/resolver_test.exs`
- `test/jido_claw/tool_context_shape_test.exs`
- `test/jido_claw/workflows/scope_propagation_test.exs`

**Modified files:**
- `config/config.exs` (lines 221-230 — append two domains)
- `lib/jido_claw.ex` (lines 27-91 — `chat/4`, `chat/3` shim, `dispatch_to_agent`)
- `lib/jido_claw/agent/templates.ex` (line 9 — test-override hook for §9.6)
- `lib/jido_claw/cli/repl.ex` (line ~151 boot resolvers, lines 242-249 tool_context)
- `lib/jido_claw/tools/spawn_agent.ex` (lines 35-95 — call `ToolContext.child`)
- `lib/jido_claw/tools/send_to_agent.ex` (lines 18-78 — same)
- `lib/jido_claw/workflows/step_action.ex` (schema 13-22, build 38-44, helper 130-135)
- `lib/jido_claw/workflows/skill_workflow.ex` (run/4 + line 117)
- `lib/jido_claw/workflows/plan_workflow.ex` (run/4 + line 312)
- `lib/jido_claw/workflows/iterative_workflow.ex` (run/4 + lines 211, 235)
- `lib/jido_claw/tools/run_skill.ex` (lines 48-49 + workflow dispatch sites)
- `lib/jido_claw/web/controllers/chat_controller.ex` (lines 35, 68 — pass `:user_id`)
- `lib/jido_claw/web/channels/rpc_channel.ex` (line 59 + `sessions.create` at 39-50)
- `lib/jido_claw/platform/channel/discord.ex` (line 46)
- `lib/jido_claw/platform/channel/telegram.ex` (line 45)
- `lib/jido_claw/platform/cron/worker.ex` (lines 116, 120)
- `lib/jido_claw/reasoning/resources/outcome.ex` (attributes, accept, indexes, relationships)
- `lib/jido_claw/reasoning/telemetry.ex` (with_outcome opts)
- `lib/jido_claw/tools/reason.ex` (forward UUIDs)
- `lib/jido_claw/tools/run_pipeline.ex` (same)
- `lib/jido_claw/tools/verify_certificate.ex` (same)
- `test/jido_claw/reasoning/outcome_test.exs` (extend)

## Verification

End-to-end:

1. `mix setup && mix compile --warnings-as-errors` — clean compile
   with two new resources + `before_action`.
2. `mix test` — full green, including the seven new test files.
3. **REPL smoke test**: `mix jidoclaw` — first message creates a
   `Workspace` row (tenant `"default"`, `path = expanded cwd`,
   `name = Path.basename(cwd)`, both policies `:disabled`) and a
   `Session` row (`kind: :repl`, `external_id: "session_<ts>"`).
   Verify via `mcp__tidewave__execute_sql_query` (manual, not
   in-test):
   ```sql
   SELECT id, name, path, tenant_id, embedding_policy, consolidation_policy
   FROM workspaces ORDER BY inserted_at DESC LIMIT 1;
   ```
4. **Reasoning telemetry smoke test**: trigger a `reason` tool call
   inside the REPL; verify the `Reasoning.Outcome` row has both
   `workspace_uuid` and `session_uuid` populated, pointing at the
   rows from step 3.
5. **Partial-index verification (manual)**: confirm both Workspace
   partial uniques exist via Tidewave or `psql`:
   ```sql
   SELECT indexname, indexdef FROM pg_indexes
   WHERE tablename = 'workspaces' AND indexname LIKE 'unique_user_path%';
   ```
   — should show two indexes with `WHERE (user_id IS NOT NULL)` and
   `WHERE (user_id IS NULL)` predicates respectively.
6. **Codegen idempotence**: `mix ash.codegen --check` post-migration
   exits clean (no pending diffs, all snapshots committed).
7. **Skill regression**: invoke a skill from a parent agent with
   non-default scope; assert child agent receives parent's scope
   (covered by 9.6's integration test using the
   `agent_templates_override` hook from step 4.5).
8. **Web RPC `sessions.create`**: from a real RPC client, call the
   `sessions.create` handler; verify both a runtime `Session.Worker`
   and a `Conversations.Session` DB row are created with `kind:
   :web_rpc` and the authenticated user's id.
9. **Upsert preservation**: in IEx, register a workspace with
   `embedding_policy: :default`, then call `Resolver.ensure_workspace/3`
   again with the default `:disabled`; reread and verify the column
   still says `:default` (proves Decision 10's `upsert_fields`
   restriction is in effect).

## Out of scope for Phase 0

- MCP `tool_context` plumbing (Decision 2 — `:mcp` is enum-only)
- De-overloading `workspace_id` as a runtime key (Decision 5)
- Tenant promotion to a real Ash resource (Phase 4)
- Solutions / Memory / Audit tenant columns (Phases 1, 3, 4)
- `JidoClaw.Repo.prepare_query/2` injection (post-v0.6.4)
