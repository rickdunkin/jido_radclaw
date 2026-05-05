# Phase 3a Implementation Plan — Memory: Data Layer & Retrieval

This plan sequences the work to land `v0.6.3a` per
`docs/plans/v0.6/phase-3a-memory-data.md`. Where the spec doc is
ambiguous, **this plan is the authoritative shape** — concrete
code blocks are inlined below. The spec is updated to match
after this plan is approved (see §Spec corrections, last
section).

---

## Goal & success criteria

After 3a:
- Seven `JidoClaw.Memory.*` Ash resources exist and migrate
  cleanly against Postgres with `pgcrypto` available.
- `Memory.remember_from_model/2`, `Memory.remember_from_user/2`,
  `Memory.recall/2`, `Memory.list_recent/1`, `Memory.forget/3`
  are the public write/read surface; the legacy `JidoClaw.Memory`
  GenServer is gone.
- `Remember`, `Recall`, `Forget` (new) tools call the new module;
  schemas unchanged for the first two.
- `/memory blocks`, `/memory list`, `/memory search`,
  `/memory save`, `/memory forget` work in the REPL.
- Hybrid retrieval (`Memory.Retrieval.search/2`) returns
  RRF-ranked Facts with bitemporal predicate filtering and
  scope/source precedence dedup applied **inside the SQL**, with
  the dedup partition key correctly distinguishing labeled vs
  unlabeled rows.
- `mix jidoclaw.migrate.memory` ports `.jido/memory.json` rows
  into `Memory.Fact` with `source: :imported_legacy` and is
  idempotent. `mix jidoclaw.export.memory` round-trips
  sanitized fixtures.
- `Memory.Fact.embedding` is populated by the existing
  `Embeddings.BackfillWorker` (extended), gated by
  `Workspace.embedding_policy`, with `:processing` lease state
  honored.
- `Workspaces.PolicyTransitions.apply_memory_embedding/3` honors
  the same transition table as `apply_embedding/3` does for
  Solutions, and BOTH are invoked when the policy flips.
- All §3.19 data-layer gates pass; `mix compile
  --warnings-as-errors`, `mix format --check-formatted`,
  `mix ash.codegen --check`, `mix ash_postgres.generate_migrations`
  (no `identity_wheres_to_sql` errors), `mix test` clean.

## Pre-flight

Verify the v0.6.0 / v0.6.1 / v0.6.2 baseline before starting:

```bash
git status                                 # clean
mix deps.get
mix ecto.setup                             # fresh db (or `mix ecto.reset`)
mix compile --warnings-as-errors
mix format --check-formatted
mix ash.codegen --check
mix test
```

If any of those fail, fix the baseline first — Phase 3a cannot
land cleanly on top of a broken `main`.

---

## Implementation sequence

Each step ends with `mix compile --warnings-as-errors && mix
format --check-formatted` clean before moving on. Tests for each
step land alongside the code in that step.

### Step 1 — Foundation: extensions, domain, scope helper

**Modified files:**
- `lib/jido_claw/repo.ex` — append `"pgcrypto"` to
  `installed_extensions/0`.
- `config/config.exs` — append `JidoClaw.Memory.Domain` to
  `:ash_domains`.

**New files:**
- `lib/jido_claw/memory/domain.ex` — `JidoClaw.Memory.Domain`,
  empty `resources` block (mirror `lib/jido_claw/solutions/domain.ex`).
- `lib/jido_claw/security/cross_tenant_fk.ex` — shared validator
  module. Mirrors the inline `Changes.ValidateCrossTenantFk`
  used in `lib/jido_claw/conversations/resources/message.ex`
  (lines ~350-417) and `lib/jido_claw/solutions/resources/solution.ex`
  (~line 447). Skip-with-telemetry for parents lacking
  `tenant_id` (`Project`, `Forge.Session`); telemetry event
  `[:jido_claw, :memory, :cross_tenant_fk, :skipped]`.
- `lib/jido_claw/security/redaction/memory.ex` —
  `Redaction.Memory.redact_fact!/1` wraps `Transcript.redact/2`
  (note arity-2 with `:json_aware_keys` opt) and adds
  metadata-jsonb sensitive-key scrubbing. Idempotent.
- `lib/jido_claw/memory/scope.ex` — concrete shape below.
  - `resolve(tool_context) :: {:ok, scope_record} | {:error, reason}`
    where `scope_record = %{tenant_id, scope_kind, user_id,
    workspace_id, project_id, session_id}`.
    **Important ToolContext mapping:** Memory Ash FKs use
    `tool_context.workspace_uuid -> workspace_id` and
    `tool_context.session_uuid -> session_id`. The existing
    `tool_context.workspace_id` is a runtime shell/VFS key and must not
    be written into Memory resource FK columns.
    Resolves ancestors from `Workspace`/`Session` rows to populate the
    full chain when known, then derives `scope_kind` from the most
    specific populated FK in this order: `:session`, `:project`,
    `:workspace`, `:user`.

**`Memory.Scope` is the single source of truth for FK mapping
(addresses ToolContext ambiguity head-on).** The `tool_context`
module today carries `:workspace_id` / `:session_id` as
**runtime shell/VFS keys**, distinct from the Ash FK targets
(`:workspace_uuid` / `:session_uuid`). Memory resources name
their FK columns `workspace_id` / `session_id` (Phase 2 FK-column
naming convention — see `Conversations.Message.session_id`),
which collides with the runtime-key naming. `Scope.resolve/1`
performs the rename:

```elixir
defmodule JidoClaw.Memory.Scope do
  @moduledoc """
  Resolves a tool_context into a Memory scope record.

  CRITICAL: reads the **Ash FK target** keys from tool_context
  (`:workspace_uuid` and `:session_uuid`), NOT the runtime
  overloads (`:workspace_id` and `:session_id` are shell/VFS
  keys per `lib/jido_claw/tool_context.ex`). Returns a record
  whose keys match Memory resource attribute names (FK columns
  named `workspace_id`/`session_id` per Phase 2 convention).
  """

  defstruct [
    :tenant_id,
    :scope_kind,
    :user_id,
    :workspace_id,
    :project_id,
    :session_id
  ]

  @type t :: %__MODULE__{
          tenant_id: String.t(),
          scope_kind: :user | :workspace | :project | :session,
          user_id: Ecto.UUID.t() | nil,
          workspace_id: Ecto.UUID.t() | nil,
          project_id: Ecto.UUID.t() | nil,
          session_id: Ecto.UUID.t() | nil
        }

  @spec resolve(map()) :: {:ok, t} | {:error, term()}
  def resolve(tool_context) when is_map(tool_context) do
    tenant_id = Map.get(tool_context, :tenant_id)
    user_id = Map.get(tool_context, :user_id)

    # FK rename: tool_context.<resource>_uuid → Memory.<resource>_id
    workspace_id = Map.get(tool_context, :workspace_uuid)
    session_id = Map.get(tool_context, :session_uuid)

    project_id = Map.get(tool_context, :project_uuid)  # added when Project gets tenant_id; for now nil

    cond do
      is_nil(tenant_id) ->
        {:error, :missing_tenant_id}

      not is_nil(session_id) ->
        # Session scope: hydrate ancestors from Conversations.Session row.
        with {:ok, session} <- load_session(session_id) do
          {:ok,
           %__MODULE__{
             tenant_id: tenant_id,
             scope_kind: :session,
             session_id: session_id,
             workspace_id: session.workspace_id || workspace_id,
             project_id: project_id,
             user_id: session.user_id || user_id
           }}
        end

      not is_nil(project_id) ->
        # Project scope (deferred — Project lacks tenant_id today;
        # fall through unless project_uuid arrives via tool_context)
        ...

      not is_nil(workspace_id) ->
        with {:ok, workspace} <- load_workspace(workspace_id) do
          {:ok,
           %__MODULE__{
             tenant_id: tenant_id,
             scope_kind: :workspace,
             workspace_id: workspace_id,
             user_id: workspace.user_id || user_id
           }}
        end

      not is_nil(user_id) ->
        {:ok,
         %__MODULE__{
           tenant_id: tenant_id,
           scope_kind: :user,
           user_id: user_id
         }}

      true ->
        {:error, :no_scope_resolvable}
    end
  end

  @doc """
  Returns the populated FK column name for a scope.

  scope_fk_column(%Scope{scope_kind: :session}) #=> :session_id
  """
  def scope_fk_column(%__MODULE__{scope_kind: :session}), do: :session_id
  def scope_fk_column(%__MODULE__{scope_kind: :project}), do: :project_id
  def scope_fk_column(%__MODULE__{scope_kind: :workspace}), do: :workspace_id
  def scope_fk_column(%__MODULE__{scope_kind: :user}), do: :user_id

  @doc """
  Returns the populated FK value for a scope.
  """
  def scope_fk_value(%__MODULE__{} = s) do
    Map.get(s, scope_fk_column(s))
  end
end
```

The wrappers in Step 4 thread the resolved struct directly into
the Ash changeset — the Memory resource's `workspace_id`
attribute is set from `scope.workspace_id` (the renamed value
that originally came from `tool_context.workspace_uuid`). No
runtime/Ash-FK conflation possible.

**Tests:**
- `test/jido_claw/memory/scope_test.exs` — table tests for
  `resolve/1`:
  - `:session_uuid` set → `scope_kind: :session`, ancestor chain
    populated.
  - `:workspace_uuid` set, `:session_uuid` nil → `:workspace`.
  - Only `:user_id` set → `:user`.
  - **Explicit FK mapping assertion**: pass `tool_context =
    %{tenant_id: "t1", workspace_uuid: "ws-uuid", workspace_id:
    "runtime-shell-key"}`; assert
    `scope.workspace_id == "ws-uuid"` (the renamed value, NOT
    the runtime shell key).
- `test/jido_claw/security/cross_tenant_fk_test.exs` — happy
  path, cross-tenant rejection at every populated FK,
  parent-missing-tenant_id telemetry event emitted.
- `test/jido_claw/security/redaction/memory_test.exs` — pattern
  redaction + metadata key scrubbing; idempotency on already-
  redacted strings.

**Validate:** `mix compile --warnings-as-errors && mix test
test/jido_claw/memory/scope_test.exs
test/jido_claw/security/cross_tenant_fk_test.exs
test/jido_claw/security/redaction/memory_test.exs`.

### Step 2 — Memory resources (Ash declarations)

Add the seven resource modules. No migrations yet.

**Pattern reference** for every Memory resource:
- `lib/jido_claw/solutions/resources/solution.ex` — generated
  columns (`generated?: true, writable?: false`), partial
  identities, embedding state machine, nested `Changes.*`
  modules, IMMUTABLE wrapper-function pattern.
- `lib/jido_claw/conversations/resources/message.ex` — writable
  `inserted_at` pattern, `:append`/`:import` action split,
  `RedactContent` `before_action` shape.

#### 2.0 Bitemporal write rule (THE rule for `Memory.Fact`)

`Memory.Fact` has no sibling revision table — all bitemporal
history lives on the row. Under that constraint, **every
state-changing action on `Memory.Fact` is copy-on-write**:

> The only field ever mutated in place on an existing
> `Memory.Fact` row is `expired_at` (NULL → now()). Every other
> state change — `:record` label-replacement, `:promote`,
> `:invalidate_by_id`, `:invalidate_by_label` — inserts a
> **successor row** capturing the new state and sets the
> predecessor's `expired_at = now()`. Predecessor's
> `valid_at`, `invalid_at`, `content`, `source`, `trust_score`,
> `inserted_at` are NEVER mutated.

Concrete shape per action:

| Action | Successor row attrs | Predecessor mutation |
|---|---|---|
| `:record` (new label, no predecessor) | full new row | n/a |
| `:record` (label replacement) | new content; `valid_at = now()`; `inserted_at = now()`; `invalid_at = NULL`; `expired_at = NULL` | `expired_at = now()` only |
| `:promote` | content/scope/label/valid_at copied from predecessor; `source = :consolidator_promoted`; `trust_score = 0.85`; `inserted_at = now()`; `invalid_at = NULL`; `expired_at = NULL` | `expired_at = now()` only |
| `:invalidate_by_id` / `:invalidate_by_label` | content/scope/label/source/valid_at copied from predecessor; **`invalid_at = now()`**; `inserted_at = now()`; `expired_at = NULL` | `expired_at = now()` only |

This keeps system-time travel real — at any `T_s`, predecessor
returns iff `inserted_at <= T_s AND (expired_at IS NULL OR
expired_at > T_s)`, with the row's content + world-axis state
exactly as it was at `T_s`.

**The active partial unique identity must filter
`is_nil(expired_at)` AND `is_nil(invalid_at)`** so predecessor
(with `expired_at` set) and the invalidation successor (with
`invalid_at` set) are both excluded — only "currently active in
both axes" rows participate in uniqueness. This is the spec
correction listed at the bottom of this plan; the concrete
shape is in §2.1 below.

`Memory.Block` is different: it has a sibling
`Memory.BlockRevision` audit table, so `:revise` mutates the
live Block in place and appends a `BlockRevision` row capturing
the predecessor's state. `:invalidate` sets `invalid_at` on the
live Block. Block's bitemporal model is "current truth on the
live row, history in the audit table." This means Block's
partial unique identities only need `is_nil(invalid_at)` (no
`expired_at` clause).

#### 2.1 Partial identities — concrete Ash shape (resolves scope-uniqueness collision)

- Four partial unique identities for active labels
  (`unique_active_label_per_scope_user/_workspace/_project/_session`)
  plus four for active consolidator-promoted content
  (`unique_active_promoted_content_per_scope_<X>`). Each partial
  identity must include both the FK predicate and the matching
  `scope_kind` predicate to avoid collisions from ancestor FKs
  populated by `Memory.Scope.resolve/1`:
  - user: `WHERE scope_kind = 'user' AND invalid_at IS NULL AND expired_at IS NULL AND user_id IS NOT NULL`
  - workspace: `WHERE scope_kind = 'workspace' AND invalid_at IS NULL AND expired_at IS NULL AND workspace_id IS NOT NULL`
  - project: `WHERE scope_kind = 'project' AND invalid_at IS NULL AND expired_at IS NULL AND project_id IS NOT NULL`
  - session: `WHERE scope_kind = 'session' AND invalid_at IS NULL AND expired_at IS NULL AND session_id IS NOT NULL`

  Plus `label IS NOT NULL` for the label-identity family, or
  `source = 'consolidator_promoted' AND content_hash IS NOT NULL`
  for the content-identity family. The `expired_at IS NULL` clause
  is what makes the active-uniqueness predicate composable with
  copy-on-write predecessors (see §2.0). Block identities do NOT
  need `expired_at IS NULL` (Block uses in-place mutation with a
  sibling audit table).

The partial unique indexes MUST include `scope_kind == :X`
(matching the per-scope_kind variant) in their `where` clause,
not just `<fk> != nil`. A session-scoped row populates
`workspace_id` as an ancestor FK per `Memory.Scope.resolve/1`;
without `scope_kind == :workspace` in the workspace identity's
WHERE, that session row would collide with workspace-scoped
rows at the same label. Concrete declaration for each Fact
identity, repeated four times per scope_kind:

```elixir
# In lib/jido_claw/memory/resources/fact.ex:
#
# Every active partial unique identity discriminates on FOUR
# clauses, not just <fk> IS NOT NULL:
#   - scope_kind == :X        (per-variant; selects rows of this scope kind)
#   - not is_nil(<fk>)         (defensive: matching FK populated)
#   - is_nil(invalid_at)       (world-axis current)
#   - is_nil(expired_at)       (system-axis current — required because
#                               copy-on-write leaves predecessors with
#                               invalid_at IS NULL but expired_at set)
#
# Plus per-identity additions: not is_nil(label), or
# not is_nil(content_hash), etc.
#
# A session-scoped row has scope_kind=:session AND populates
# session_id + ancestor workspace_id + ancestor user_id (per
# Memory.Scope.resolve/1). The workspace identity's WHERE has
# scope_kind == :workspace, so the session-scoped row does NOT
# match the workspace identity. No cross-scope collision
# possible.
identities do
  identity :unique_active_label_per_scope_session,
           [:tenant_id, :session_id, :label, :source] do
    where expr(
            scope_kind == :session and
              not is_nil(session_id) and
              not is_nil(label) and
              is_nil(invalid_at) and
              is_nil(expired_at)
          )
  end

  identity :unique_active_label_per_scope_workspace,
           [:tenant_id, :workspace_id, :label, :source] do
    where expr(
            scope_kind == :workspace and
              not is_nil(workspace_id) and
              not is_nil(label) and
              is_nil(invalid_at) and
              is_nil(expired_at)
          )
  end

  identity :unique_active_label_per_scope_project,
           [:tenant_id, :project_id, :label, :source] do
    where expr(
            scope_kind == :project and
              not is_nil(project_id) and
              not is_nil(label) and
              is_nil(invalid_at) and
              is_nil(expired_at)
          )
  end

  identity :unique_active_label_per_scope_user,
           [:tenant_id, :user_id, :label, :source] do
    where expr(
            scope_kind == :user and
              not is_nil(user_id) and
              not is_nil(label) and
              is_nil(invalid_at) and
              is_nil(expired_at)
          )
  end

  # Same four-variant pattern for content-hash identities (used
  # for unlabeled consolidator-promoted Facts):
  #
  #   :unique_active_promoted_content_per_scope_<X>
  #   keys: [:tenant_id, <fk>, :content_hash]
  #   where: scope_kind == :X AND not is_nil(<fk>) AND
  #          source == :consolidator_promoted AND
  #          not is_nil(content_hash) AND
  #          is_nil(invalid_at) AND is_nil(expired_at)

  # Cross-scope single identity:
  identity :unique_import_hash, [:import_hash] do
    where expr(not is_nil(import_hash))
  end
end

postgres do
  identity_wheres_to_sql [
    # Active label identities (4 per scope_kind):
    {:unique_active_label_per_scope_session,
     "tenant_id IS NOT NULL AND scope_kind = 'session' AND " <>
       "session_id IS NOT NULL AND label IS NOT NULL AND " <>
       "invalid_at IS NULL AND expired_at IS NULL"},
    {:unique_active_label_per_scope_workspace,
     "tenant_id IS NOT NULL AND scope_kind = 'workspace' AND " <>
       "workspace_id IS NOT NULL AND label IS NOT NULL AND " <>
       "invalid_at IS NULL AND expired_at IS NULL"},
    {:unique_active_label_per_scope_project,
     "tenant_id IS NOT NULL AND scope_kind = 'project' AND " <>
       "project_id IS NOT NULL AND label IS NOT NULL AND " <>
       "invalid_at IS NULL AND expired_at IS NULL"},
    {:unique_active_label_per_scope_user,
     "tenant_id IS NOT NULL AND scope_kind = 'user' AND " <>
       "user_id IS NOT NULL AND label IS NOT NULL AND " <>
       "invalid_at IS NULL AND expired_at IS NULL"},
    # Active content-hash identities (4 per scope_kind, same shape
    # but with source = 'consolidator_promoted' AND content_hash
    # IS NOT NULL).
    # ... 4 entries ...
    {:unique_import_hash, "import_hash IS NOT NULL"}
  ]
end
```

The same shape applies to `Memory.Block`'s four
`unique_label_per_scope_<X>` identities (with `source` dropped
from the key columns, and `label` always non-null since Blocks
require a label). Total: 4 Block + 4 Fact label + 4 Fact
content + 1 Fact import = 13 partial identities, all listed
in `docs/plans/v0.6/README.md §Cross-cutting / Partial
identities`.

Run `mix ash_postgres.generate_migrations` after each resource
is added so SQL/expr divergence surfaces immediately, not at
the end of Step 2.

#### 2.2 Memory.Fact actions (concrete code)

- **Bitemporal write rule:** Fact updates are copy-on-write, not
  destructive updates. `:promote`, `:invalidate_by_id`,
  `:invalidate_by_label`, and label replacement set `expired_at` on
  the prior system row and insert a successor row when content/source/
  trust changes. `invalid_at` models world-time truth; `expired_at`
  models system-time supersession. No action updates historical
  Fact content in place.

Memory.Fact has no sibling `FactRevision` table (Block has
`BlockRevision`; Fact does not). The bitemporal model is enforced
on the row itself per the rule above and §2.0. Concrete action
bodies follow:

```elixir
# In lib/jido_claw/memory/resources/fact.ex:
actions do
  # Copy-on-write: invalidate prior, insert fresh.
  create :record do
    accept [
      :tenant_id, :scope_kind,
      :user_id, :workspace_id, :project_id, :session_id,
      :label, :content, :tags, :source, :trust_score,
      :metadata
    ]

    change Memory.Changes.ValidateScopeFkInvariant
    change {Memory.Changes.ValidateCrossTenantFks,
            fk_specs: [
              {:user_id, JidoClaw.Accounts.User},
              {:workspace_id, JidoClaw.Workspaces.Workspace},
              {:project_id, JidoClaw.Projects.Project},
              {:session_id, JidoClaw.Conversations.Session}
            ]}
    change Memory.Changes.RedactContent
    change Memory.Changes.InvalidatePriorActiveLabel
    # NB: caller wraps `:record` in a Repo.transaction with
    # pg_advisory_xact_lock — see Step 4.
  end

  create :import_legacy do
    accept [
      :tenant_id, :scope_kind, :inserted_at, :valid_at,
      :user_id, :workspace_id, :project_id, :session_id,
      :label, :content, :tags, :metadata, :import_hash
    ]

    change set_attribute(:source, :imported_legacy)
    change {Memory.Changes.ValidateCrossTenantFks, fk_specs: ...}
    upsert? true
    upsert_identity :unique_import_hash
  end

  # `:promote` — consolidator-only copy-on-write action; expires the
  # prior system row and inserts a successor with promoted source/trust.
  action :promote, :struct do
    argument :predecessor_id, :uuid, allow_nil?: false
    argument :new_trust_score, :float, default: 0.85
    argument :actor, :atom, default: :consolidator

    run fn input, _ctx ->
      Repo.transaction(fn ->
        predecessor = Ash.get!(__MODULE__, input.arguments.predecessor_id)

        # Source-protect: reject consolidator promote of user rows.
        if input.arguments.actor == :consolidator and
             predecessor.source == :user_save do
          Ash.Changeset.add_error(...)  # :user_fact_protected
          Repo.rollback(:user_fact_protected)
        end

        # Insert successor with promoted attributes.
        attrs =
          predecessor
          |> Map.take([
            :tenant_id, :scope_kind, :user_id, :workspace_id,
            :project_id, :session_id, :label, :content, :tags,
            :metadata
          ])
          |> Map.merge(%{
            source: :consolidator_promoted,
            trust_score: input.arguments.new_trust_score
            # inserted_at and valid_at default to now()
          })

        {:ok, successor} =
          __MODULE__
          |> Ash.Changeset.for_create(:record, attrs)
          |> Ash.create()

        # Expire predecessor on the system axis (preserve
        # valid_at/invalid_at — world axis is unchanged).
        {:ok, _} =
          predecessor
          |> Ash.Changeset.for_update(:expire_predecessor, %{
              expired_at: DateTime.utc_now()
            })
          |> Ash.update()

        # Optional: write a :supersedes Link.
        Memory.Link
        |> Ash.Changeset.for_create(:create, %{
          from_fact_id: successor.id,
          to_fact_id: predecessor.id,
          relation: :supersedes,
          reason: "promoted by consolidator"
        })
        |> Ash.create!()

        successor
      end)
    end
  end

  # COPY-ON-WRITE invalidation: insert a successor row with
  # invalid_at populated, set predecessor's expired_at. The
  # predecessor's content / source / valid_at / inserted_at are
  # NEVER mutated — system-time travel at T_s < expired_at
  # returns predecessor with invalid_at IS NULL (the belief at
  # that knowledge-time).
  #
  # The Ash action surface here is two underlying CRUD actions
  # (:record_invalidation create + :expire_predecessor update).
  # The composing flow lives in `JidoClaw.Memory.invalidate/3`
  # (Step 4) which wraps both in `Repo.transaction/1`.
  create :record_invalidation do
    accept [
      :tenant_id, :scope_kind,
      :user_id, :workspace_id, :project_id, :session_id,
      :label, :content, :tags, :source, :trust_score,
      :metadata, :valid_at, :invalid_at
      # NB: invalid_at is required input here — caller sets it to
      # now() when invalidating. inserted_at defaults to now()
      # via the resource attribute. expired_at stays NULL.
    ]

    change Memory.Changes.ValidateScopeFkInvariant
    # No invalidate-prior step here — this action is itself the
    # successor write within a copy-on-write invalidation.
    # No advisory lock — the calling flow holds it once around
    # the create+update pair.
  end

  # Internal: terminal-state mutation of system axis only.
  update :expire_predecessor do
    accept [:expired_at]
    # No before_action chain other than guarding actor.
  end

  # Public read-side helpers — the actual invalidation logic is
  # composed in Memory.invalidate_by_* (Step 4).
end
```

The composed `invalidate_by_id` flow lives in
`JidoClaw.Memory` (Step 4) and looks like:

```elixir
def invalidate_by_id(fact_id, opts \\ []) do
  actor = Keyword.get(opts, :actor, :user)

  Repo.transaction(fn ->
    pred = Ash.get!(JidoClaw.Memory.Fact, fact_id)

    if actor == :consolidator and pred.source == :user_save do
      Repo.rollback(:user_fact_protected)
    end

    now = DateTime.utc_now()

    # Successor row: same content/scope/source/valid_at as
    # predecessor, but invalid_at is now set.
    {:ok, _} =
      JidoClaw.Memory.Fact
      |> Ash.Changeset.for_create(:record_invalidation, %{
        tenant_id: pred.tenant_id,
        scope_kind: pred.scope_kind,
        user_id: pred.user_id,
        workspace_id: pred.workspace_id,
        project_id: pred.project_id,
        session_id: pred.session_id,
        label: pred.label,
        content: pred.content,
        tags: pred.tags,
        metadata: pred.metadata,
        source: pred.source,
        trust_score: pred.trust_score,
        valid_at: pred.valid_at,
        invalid_at: now
      })
      |> Ash.create()

    # Predecessor: only expired_at is mutated.
    {:ok, _} =
      pred
      |> Ash.Changeset.for_update(:expire_predecessor, %{expired_at: now})
      |> Ash.update()

    :ok
  end)
end

def invalidate_by_label(tenant_id, scope, label, source, opts \\ []) do
  # Same shape, but the predecessor lookup uses the partial
  # active identity's WHERE clause (scope_kind, FK, label,
  # source, invalid_at IS NULL, expired_at IS NULL) inside the
  # advisory lock, then runs the same successor-create +
  # predecessor-expire pair.
  ...
end
```

The same wrapper pattern applies to `:record` label-replacement
(Step 4): the `Memory.Changes.InvalidatePriorActiveLabel` change
finds the predecessor inside the lock, sets
`predecessor.expired_at = now()`, and lets the create proceed —
NEVER mutating predecessor's `invalid_at`. With the partial
identity's `is_nil(expired_at) AND is_nil(invalid_at)` clauses,
predecessor is excluded from the active-uniqueness set after
its `expired_at` is set, so the new row inserts cleanly.

For `Memory.Block`, the existing `:revise` already does
copy-on-write (writes a `BlockRevision` row + mutates the live
Block). Add a source-protect guard:

```elixir
# In lib/jido_claw/memory/resources/block.ex:
update :revise do
  accept [:value, :description, :char_limit, :pinned, :position, :reason]
  argument :actor, :atom, default: :user

  change before_action(fn cs, ctx ->
    if ctx.arguments.actor == :consolidator and
         Ash.Changeset.get_attribute(cs, :source) == :user do
      Ash.Changeset.add_error(cs, :user_block_protected)
    else
      cs
    end
  end)

  # Same paired-revision-write hook as today.
end
```

#### 2.3 `Memory.Fact.embedding_status` enum (resolves missing `:processing`)

The existing `BackfillWorker` lease model needs `:processing` as
a transition state between `:pending` and `:ready/:failed/:disabled`
(see `lib/jido_claw/embeddings/backfill_worker.ex` lines 19-23
on the lease pattern). Concrete attribute:

```elixir
# In lib/jido_claw/memory/resources/fact.ex:
attributes do
  ...

  attribute :embedding_status, :atom do
    constraints one_of: [:pending, :processing, :ready, :failed, :disabled]
    default :pending
    allow_nil? false
  end

  attribute :embedding_attempt_count, :integer, default: 0
  attribute :embedding_next_attempt_at, :utc_datetime_usec
  attribute :embedding_last_error, :string
  attribute :embedding_model, :string

  attribute :embedding,
            JidoClaw.Embeddings.Vector do
    # vector(1024); see Solutions.Solution for shape
  end

  ...
end
```

#### 2.4 `:list_recent` action — dedicated recent-list path

`/memory list` cannot rely on hybrid retrieval with no query
text — Postgres FTS and pg_trgm return unreliable, planner-
dependent results when the input is blank. Memory ships a
dedicated Ash read action that recency-sorts and skips FTS /
trigram entirely:

```elixir
# In lib/jido_claw/memory/resources/fact.ex:
read :list_recent do
  argument :tenant_id, :string, allow_nil?: false
  argument :scope_kind, :atom, allow_nil?: false
  argument :user_id, :uuid
  argument :workspace_id, :uuid
  argument :project_id, :uuid
  argument :session_id, :uuid
  argument :limit, :integer, default: 20

  prepare fn query, ctx ->
    args = ctx.arguments

    query
    |> Ash.Query.filter(
        tenant_id == ^args.tenant_id and
          is_nil(invalid_at) and
          valid_at <= now()
      )
    |> filter_by_scope_chain(args)
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(args.limit)
  end
end
```

`/memory list` (Step 7) and `JidoClaw.Memory.list_recent/1`
(Step 4) call this action directly — NOT
`Memory.Retrieval.search/2`.

#### 2.5 Block identities — concrete Ash shape

- Four partial unique identities
  (`unique_label_per_scope_user/_workspace/_project/_session`).
  Each partial identity must include both the FK predicate and the
  matching `scope_kind` predicate to avoid collisions from ancestor
  FKs populated by `Memory.Scope.resolve/1`:
  - user: `WHERE scope_kind = 'user' AND invalid_at IS NULL AND user_id IS NOT NULL`
  - workspace: `WHERE scope_kind = 'workspace' AND invalid_at IS NULL AND workspace_id IS NOT NULL`
  - project: `WHERE scope_kind = 'project' AND invalid_at IS NULL AND project_id IS NOT NULL`
  - session: `WHERE scope_kind = 'session' AND invalid_at IS NULL AND session_id IS NOT NULL`

`Memory.Block` follows the same per-`scope_kind` partial-identity
pattern as Fact (each variant filters on `scope_kind == :X` so
ancestor FKs from `Scope.resolve/1` cannot cause cross-scope
collisions), but Block uses in-place mutation with a sibling
`BlockRevision` audit table — so its WHERE clauses do NOT
include `is_nil(expired_at)`. Just `is_nil(invalid_at)`.

```elixir
# In lib/jido_claw/memory/resources/block.ex:
identities do
  identity :unique_label_per_scope_session,
           [:tenant_id, :session_id, :label] do
    where expr(
            scope_kind == :session and
              not is_nil(session_id) and
              not is_nil(label) and
              is_nil(invalid_at)
          )
  end

  identity :unique_label_per_scope_workspace,
           [:tenant_id, :workspace_id, :label] do
    where expr(
            scope_kind == :workspace and
              not is_nil(workspace_id) and
              not is_nil(label) and
              is_nil(invalid_at)
          )
  end

  identity :unique_label_per_scope_project,
           [:tenant_id, :project_id, :label] do
    where expr(
            scope_kind == :project and
              not is_nil(project_id) and
              not is_nil(label) and
              is_nil(invalid_at)
          )
  end

  identity :unique_label_per_scope_user,
           [:tenant_id, :user_id, :label] do
    where expr(
            scope_kind == :user and
              not is_nil(user_id) and
              not is_nil(label) and
              is_nil(invalid_at)
          )
  end
end

postgres do
  identity_wheres_to_sql [
    {:unique_label_per_scope_session,
     "tenant_id IS NOT NULL AND scope_kind = 'session' AND " <>
       "session_id IS NOT NULL AND label IS NOT NULL AND " <>
       "invalid_at IS NULL"},
    {:unique_label_per_scope_workspace,
     "tenant_id IS NOT NULL AND scope_kind = 'workspace' AND " <>
       "workspace_id IS NOT NULL AND label IS NOT NULL AND " <>
       "invalid_at IS NULL"},
    {:unique_label_per_scope_project,
     "tenant_id IS NOT NULL AND scope_kind = 'project' AND " <>
       "project_id IS NOT NULL AND label IS NOT NULL AND " <>
       "invalid_at IS NULL"},
    {:unique_label_per_scope_user,
     "tenant_id IS NOT NULL AND scope_kind = 'user' AND " <>
       "user_id IS NOT NULL AND label IS NOT NULL AND " <>
       "invalid_at IS NULL"}
  ]
end
```

A session-scoped Block has `scope_kind = :session` and populates
`session_id` plus ancestor `workspace_id`/`user_id`. The
workspace identity's WHERE has `scope_kind == :workspace`, so
the session-scoped row does NOT match. No cross-scope collision.
Same shape, same reasoning, just without the `expired_at` clause
that Fact's copy-on-write model requires.

#### 2.6 Other resources

- **`Memory.Block`**: `:write`, `:revise` (with source-protect
  guard above), `:invalidate`, `:for_scope_chain`,
  `:history_for_label`. No `:destroy`.
- **`Memory.BlockRevision`**: `:create_for_block` only. Append-
  only; no update, no destroy.
- **`Memory.Episode`**: `:record` (with `CrossTenantFk`
  validation over scope FKs **and** `source_message_id` /
  `source_solution_id`), `:for_consolidator`, `:for_fact`.
- **`Memory.FactEpisode`**: `:link` with `before_action`
  denormalizing `tenant_id` from `fact_id` and validating equal
  to `episode.tenant_id`. Identity `unique_pair`.
- **`Memory.Link`**: `:create` with `before_action` rejecting
  cross-tenant edges (`:cross_tenant_link`) and cross-scope
  edges (`:cross_scope_link`).
- **`Memory.ConsolidationRun`**: `:record_run`,
  `:latest_for_scope`, `:history_for_scope`. Append-only. Ship
  in 3a so 3b's consolidator has somewhere to write; no rows
  produced in 3a.

**Tests:** one `_test.exs` per resource under
`test/jido_claw/memory/resources/`. Cover:
- Happy-path actions.
- Cross-tenant FK rejection at every populated FK level.
- Scope FK invariant.
- Bitemporal axis behavior.
- **Cross-scope identity isolation**: a session-scoped Fact with
  ancestor `workspace_id` populated does NOT collide with a
  workspace-scoped Fact at the same `(tenant, workspace_id,
  label)`. This is the key test for §2.1's per-scope_kind WHERE
  clauses.
- **Copy-on-write `:promote`**: predecessor preserved with
  `expired_at` set, `valid_at` unchanged; successor row has
  fresh `inserted_at`; `:supersedes` Link written; system-time
  travel at `as_of_system: T_promote - 1s` returns predecessor
  with `:model_remember` source.
- **Source-protect**: `:promote`, `:invalidate_by_*`,
  `Block.:revise` reject consolidator-actor mutation of user
  rows.
- **`:list_recent`**: returns rows even on a fresh scope with
  no FTS-matchable content; sorted by `inserted_at: :desc`;
  honors `:limit`.

**Validate:** `mix compile --warnings-as-errors && mix
ash_postgres.generate_migrations && mix test
test/jido_claw/memory/resources`.

### Step 3 — Migration generation + hand-edits

```bash
mix ash.codegen v063_memory                        # writes priv/repo/migrations/<ts>_v063_memory.exs
```

**Hand-edits** to `priv/repo/migrations/<ts>_v063_memory.exs`:

1. Top of `up/0`: explicit pgcrypto create (belt-and-braces with
   `installed_extensions/0`):

   ```elixir
   execute(
     "CREATE EXTENSION IF NOT EXISTS pgcrypto",
     "DROP EXTENSION IF EXISTS pgcrypto"
   )
   ```

2. IMMUTABLE wrapper functions (mirror v061_solutions.exs lines
   26-55):

   ```elixir
   execute("""
   CREATE OR REPLACE FUNCTION memory_search_vector(
     label text, content text, tags text[]
   )
   RETURNS tsvector LANGUAGE SQL IMMUTABLE AS $$
     SELECT to_tsvector(
       'english',
       coalesce(label, '') || ' ' || content || ' ' ||
       array_to_string(coalesce(tags, ARRAY[]::text[]), ' ')
     )
   $$;
   """)
   # Same shape for memory_lexical_text(label, content, tags).
   ```

3. Replace auto-generated `add :search_vector, :tsvector` with
   `add(:search_vector, :tsvector, generated: "ALWAYS AS
   (memory_search_vector(label, content, tags)) STORED")`. Same
   for `lexical_text` (text type).
4. Replace `add :content_hash, :bytea` with
   `add(:content_hash, :bytea, generated: "ALWAYS AS
   (digest(content, 'sha256')) STORED")`.
5. HNSW indexes (mirror v061_solutions.exs lines 148-158, partial
   per `embedding_model`):

   ```elixir
   execute("""
   CREATE INDEX memory_facts_voyage_4_large_hnsw_idx
     ON memory_facts USING hnsw (embedding vector_cosine_ops)
     WHERE embedding_model = 'voyage-4-large';
   """)
   # Plus mxbai-embed-large sibling.
   ```

6. GIN trigram index for `lexical_text`:

   ```elixir
   execute("""
   CREATE INDEX memory_facts_lexical_text_trgm_idx
     ON memory_facts USING gin (lexical_text gin_trgm_ops);
   """)
   ```

7. `down/0` reverses each `execute/1` with a `DROP` sibling.

**Run:**

```bash
mix ecto.migrate
mix ash.codegen --check
mix ash_postgres.generate_migrations
```

**Tests** (`test/jido_claw/memory/migration_test.exs`):
- Insert a Fact; assert DB-side population of `content_hash`
  and `search_vector`.
- `unique_active_promoted_content_per_scope_*` rejects duplicate-
  content row at same scope.
- FTS via `to_tsquery('english', '...')` matches expected rows.

### Step 4 — Write paths (advisory lock + ToolContext FK rename)

Public surface added by Step 4:

- `remember_from_model(attrs, tool_context)` /
  `remember_from_user(attrs, tool_context)` — write a Fact at the
  resolved scope. Always-`:ok` external contract preserved.
- `recall(query, opts)` — hybrid retrieval via
  `Memory.Retrieval.search/2`.
- `list_recent(scope, opts)` — dedicated recent-list path for `/memory`
  and `/memory list`. This does not route through empty-query hybrid
  search; it performs a scoped read ordered by `inserted_at`/`valid_at`
  and returns the legacy memory map shape.
- `forget(label, tool_context, opts)` — copy-on-write invalidation
  composing `Memory.Fact.:record_invalidation` and
  `:expire_predecessor` inside one transaction with the same advisory
  lock as `:record`.

The thin module that replaces `JidoClaw.Memory`. Concrete shape:

```elixir
# lib/jido_claw/memory.ex
defmodule JidoClaw.Memory do
  @moduledoc """
  Public Memory API. Replaces the v0.5 GenServer at
  `lib/jido_claw/platform/memory.ex`.

  All wrappers preserve today's always-`:ok` external contract
  (callers in `tools/remember.ex:42` and `cli/commands.ex:209`
  rely on it). Errors are logged via `Logger`; the return value
  stays `:ok` even on persistence failure.
  """

  alias JidoClaw.Memory.{Fact, Scope}
  alias JidoClaw.Repo
  require Logger

  @spec remember_from_model(map(), map()) :: :ok
  def remember_from_model(attrs, tool_context) do
    do_record(attrs, tool_context, :model_remember, 0.4)
  end

  @spec remember_from_user(map(), map()) :: :ok
  def remember_from_user(attrs, tool_context) do
    do_record(attrs, tool_context, :user_save, 0.7)
  end

  defp do_record(attrs, tool_context, source, trust_score) do
    with {:ok, scope} <- Scope.resolve(tool_context),
         {:ok, _fact} <- record_with_lock(attrs, scope, source, trust_score) do
      :ok
    else
      {:error, reason} ->
        Logger.warning("[Memory] #{source} failed: #{inspect(reason)}")
        :ok
    end
  end

  # Concurrent label replacement uses a transaction-level
  # advisory lock. xact_lock is auto-released on commit/rollback
  # — no connection pool concern (3a never holds connections
  # outside a single transaction's window).
  #
  # 3b's consolidator uses pg_advisory_lock (session-level) for a
  # different reason: harness latency forbids holding an open
  # transaction. That's a 3b-only concern with documented
  # max_concurrent_scopes pool sizing.
  defp record_with_lock(attrs, scope, source, trust_score) do
    Repo.transaction(fn ->
      if Map.get(attrs, :label) do
        lock_key =
          :erlang.phash2(
            {:memory_fact_label, scope.tenant_id, scope.scope_kind,
             Scope.scope_fk_value(scope), attrs.label}
          )

        Repo.query!("SELECT pg_advisory_xact_lock($1)", [lock_key])
      end

      changeset_attrs =
        attrs
        |> Map.merge(%{
          tenant_id: scope.tenant_id,
          scope_kind: scope.scope_kind,
          user_id: scope.user_id,
          workspace_id: scope.workspace_id,    # NB: Memory FK column.
                                                # Value comes from
                                                # tool_context.workspace_uuid
                                                # via Scope.resolve/1.
          project_id: scope.project_id,
          session_id: scope.session_id,
          source: source,
          trust_score: trust_score
        })

      # `:record` runs the InvalidatePriorActiveLabel before_action
      # change, which (under the lock) finds any predecessor row
      # matching (tenant, scope, label, source, invalid_at IS NULL,
      # expired_at IS NULL) and sets predecessor.expired_at = now()
      # via :expire_predecessor. The new row inserts with fresh
      # valid_at = now(), invalid_at = NULL, expired_at = NULL.
      # Predecessor's invalid_at is NEVER mutated — copy-on-write
      # per §2.0.
      Fact
      |> Ash.Changeset.for_create(:record, changeset_attrs)
      |> Ash.create()
      |> case do
        {:ok, fact} -> fact
        {:error, error} -> Repo.rollback(error)
      end
    end)
  end

  @spec recall(String.t(), keyword()) :: [map()]
  def recall(query, opts \\ []) do
    JidoClaw.Memory.Retrieval.search(query, opts)
    |> Enum.map(&to_legacy_shape/1)
  end

  @spec list_recent(non_neg_integer()) :: [map()]
  def list_recent(limit \\ 20) do
    # Calls the dedicated :list_recent Ash action, NOT hybrid
    # retrieval — empty FTS/trigram queries are planner-
    # dependent. See Step 2.4.
    scope = current_scope_or_default()

    Fact
    |> Ash.Query.for_read(:list_recent, %{
      tenant_id: scope.tenant_id,
      scope_kind: scope.scope_kind,
      user_id: scope.user_id,
      workspace_id: scope.workspace_id,
      project_id: scope.project_id,
      session_id: scope.session_id,
      limit: limit
    })
    |> Ash.read!()
    |> Enum.map(&to_legacy_shape/1)
  end

  @spec forget(String.t(), map(), keyword()) :: :ok | {:error, term()}
  def forget(label, tool_context, opts \\ []) do
    # Copy-on-write invalidation. Composes Fact's two underlying
    # CRUD actions (:record_invalidation create + :expire_predecessor
    # update) inside one Repo.transaction with the same advisory
    # lock as `:record`. See §2.0 for the bitemporal write rule.
    actor = Keyword.get(opts, :actor, :user)
    source = Keyword.get(opts, :source, :user_save)
    {:ok, scope} = Scope.resolve(tool_context)

    Repo.transaction(fn ->
      lock_key =
        :erlang.phash2(
          {:memory_fact_label, scope.tenant_id, scope.scope_kind,
           Scope.scope_fk_value(scope), label}
        )

      Repo.query!("SELECT pg_advisory_xact_lock($1)", [lock_key])

      pred =
        Fact
        |> Ash.Query.filter(
          tenant_id == ^scope.tenant_id and
            scope_kind == ^scope.scope_kind and
            ^Scope.scope_fk_column(scope) == ^Scope.scope_fk_value(scope) and
            label == ^label and
            source == ^source and
            is_nil(invalid_at) and
            is_nil(expired_at)
        )
        |> Ash.read_one!()

      cond do
        is_nil(pred) ->
          :no_active_row

        actor == :consolidator and pred.source == :user_save ->
          Repo.rollback(:user_fact_protected)

        true ->
          now = DateTime.utc_now()

          # Successor row records the new world-axis state.
          {:ok, _succ} =
            Fact
            |> Ash.Changeset.for_create(:record_invalidation, %{
              tenant_id: pred.tenant_id,
              scope_kind: pred.scope_kind,
              user_id: pred.user_id,
              workspace_id: pred.workspace_id,
              project_id: pred.project_id,
              session_id: pred.session_id,
              label: pred.label,
              content: pred.content,
              tags: pred.tags,
              metadata: pred.metadata,
              source: pred.source,
              trust_score: pred.trust_score,
              valid_at: pred.valid_at,
              invalid_at: now
            })
            |> Ash.create()

          # Predecessor: only expired_at mutated.
          {:ok, _} =
            pred
            |> Ash.Changeset.for_update(:expire_predecessor, %{expired_at: now})
            |> Ash.update()

          :ok
      end
    end)
  end

  # Returns %{key, content, type, created_at, updated_at} maps so
  # tools/recall.ex and cli/presenters.ex keep working unchanged.
  # `key` ← Fact.label, `type` ← first tag, `created_at` /
  # `updated_at` ← Fact.inserted_at (legacy returned both equal).
  defp to_legacy_shape(%Fact{} = fact) do
    %{
      key: fact.label,
      content: fact.content,
      type: List.first(fact.tags || []) || "fact",
      created_at: DateTime.to_iso8601(fact.inserted_at),
      updated_at: DateTime.to_iso8601(fact.inserted_at)
    }
  end
end
```

**Tests** (`test/jido_claw/memory_test.exs`):
- `remember_from_model` / `_from_user` write Facts at the
  resolved scope. **Pin FK mapping**:
  `tool_context.workspace_uuid → Memory.Fact.workspace_id`.
- Re-`remember_from_model` of the same `key` invalidates prior
  active row, inserts fresh; both queryable via `as_of_world`.
- `forget` with default source invalidates user row, leaves
  model row alone.
- **Concurrent-write contention**: 20 Tasks calling
  `remember_from_user` for the same `(scope, label)`; assert
  exactly N writes complete; assert exactly one row active;
  assert all earlier rows invalidated with monotonic
  `expired_at`.
- **`list_recent` shape preservation**: returns
  `%{key, content, type, created_at, updated_at}` maps.
- **`list_recent` non-empty on fresh scope**: insert 3 Facts at
  scope, no FTS-matchable text; assert all 3 returned.

### Step 5 — Tool surface swap + new Forget

**Modified files:**
- `lib/jido_claw/tools/remember.ex` — call
  `JidoClaw.Memory.remember_from_model/2`. Schema and return
  shape unchanged.
- `lib/jido_claw/tools/recall.ex` — call
  `JidoClaw.Memory.recall/2`. Docstring stays.

**New file:**
- `lib/jido_claw/tools/forget.ex` — `Memory.Forget` Jido.Action.
  Schema accepts `id` (uuid, optional) or `label` (string,
  required when `id` not given). Calls
  `JidoClaw.Memory.forget/3` with implicit
  `source: :model_remember`. The action's resource-side
  source-protect guard is defense-in-depth.

**Modified:**
- `lib/jido_claw/agent/agent.ex` — register
  `JidoClaw.Tools.Forget` in the tool list.

**Tests** — adapt `test/jido_claw/tools/remember_test.exs`,
`test/jido_claw/tools/recall_test.exs`; new
`test/jido_claw/tools/forget_test.exs`.

### Step 6 — Retrieval API (RRF + bitemporal + dedup partition)

**New files:**
- `lib/jido_claw/memory/retrieval.ex` — `search(query, opts)`
  orchestrates Block tier (no search; `Block.for_scope_chain`
  ordered by `position`), Fact tier (delegates to
  `HybridSearchSql.run/1`), Episode tier (FTS + lexical only).
  Bitemporal predicate matrix per spec §3.13 (4 modes:
  current truth / world / system / full).
- `lib/jido_claw/memory/hybrid_search_sql.ex` — RRF SQL.

Three-pool CTE shape mirrors
`lib/jido_claw/solutions/hybrid_search_sql.ex`, with these
specific divergences:

```sql
-- After fts_pool / ann_pool / lexical_pool (each LIMIT 100):
merged AS (
  SELECT f.id, f.*,
         1.0 / (60 + COALESCE(fts.r_fts, 1000)) +
         1.0 / (60 + COALESCE(ann.r_ann, 1000)) +
         1.0 / (60 + COALESCE(lexical.r_lex, 1000)) AS rrf
  FROM memory_facts f
  LEFT JOIN fts ON fts.id = f.id
  LEFT JOIN ann ON ann.id = f.id
  LEFT JOIN lexical ON lexical.id = f.id
  WHERE (fts.id IS NOT NULL OR ann.id IS NOT NULL OR lexical.id IS NOT NULL)
    AND f.tenant_id = $9
    -- Bitemporal predicates (one of four modes):
    AND f.valid_at <= $now AND (f.invalid_at IS NULL OR f.invalid_at > $now)
    AND f.expired_at IS NULL
),
deduped AS (
  SELECT *,
         ROW_NUMBER() OVER (
           PARTITION BY
             -- DEDUP KEY (resolves nullable-label collapse).
             -- Labeled rows partition by label across scope/source axes
             -- so source precedence wins inside a label.
             -- Unlabeled (consolidator-promoted) rows partition by
             -- scope+content_hash so cross-scope copies survive but
             -- same-scope duplicates collapse.
             CASE
               WHEN label IS NOT NULL THEN 'L:' || label
               ELSE 'C:' || scope_kind::text || ':' ||
                    COALESCE(
                      session_id::text, project_id::text,
                      workspace_id::text, user_id::text
                    ) || ':' || encode(content_hash, 'hex')
             END
           ORDER BY
             -- Scope precedence outer.
             CASE scope_kind
               WHEN 'session'   THEN 1
               WHEN 'project'   THEN 2
               WHEN 'workspace' THEN 3
               WHEN 'user'      THEN 4
             END ASC,
             -- Source precedence inner.
             CASE source
               WHEN 'user_save'              THEN 1
               WHEN 'consolidator_promoted'  THEN 2
               WHEN 'imported_legacy'        THEN 3
               WHEN 'model_remember'         THEN 4
             END ASC,
             rrf DESC,
             valid_at DESC,
             id DESC
         ) AS prec_rank
  FROM merged
)
SELECT *
FROM deduped
WHERE prec_rank = 1
ORDER BY rrf DESC
LIMIT $5;
```

Bitemporal mode selection (passed into `$now` and the WHERE
clause) per spec §3.13 matrix:

| Mode | Predicate |
|---|---|
| Current (default) | `valid_at <= now() AND (invalid_at IS NULL OR invalid_at > now()) AND expired_at IS NULL` |
| World time-travel (`as_of_world: T_w`) | `valid_at <= T_w AND (invalid_at IS NULL OR invalid_at > T_w)` (drop `expired_at IS NULL`) |
| System time-travel (`as_of_system: T_s`) | `inserted_at <= T_s AND (expired_at IS NULL OR expired_at > T_s)` + default world |
| Full bitemporal (both) | both axes applied independently |

Reuse: `JidoClaw.Solutions.SearchEscape.escape_like/1` +
`lower_only/1`; `JidoClaw.Embeddings.Voyage.embed_for_query/1`;
`JidoClaw.Embeddings.PolicyResolver` (gate the ANN pool when
workspace policy is `:disabled`).

**Tests** (`test/jido_claw/memory/retrieval_test.exs`):
- Substring-superset (api_base_url, [:preference], foo.bar.baz).
- Lexical-index engaged: seed 5,000 Facts; `EXPLAIN ANALYZE`
  with `SET LOCAL enable_seqscan = off`; assert
  `Bitmap Index Scan on memory_facts_lexical_text_trgm_idx`.
- Source-precedence dedup (3 sources at one scope; `:user_save`
  wins).
- Scope-precedence dedup (3 scopes at one label; session wins).
- Combined precedence (scope outer, source inner).
- **Unlabeled-Fact dedup**: two consolidator-promoted Facts at
  the same scope with identical content; partial unique
  identity rejects the second. At cross-scope: same content
  promoted under different scopes survives both.
- Bitemporal current-truth, world-time-travel,
  system-time-travel, full-axis cells.
- Embedding-space isolation (voyage vs local don't cross the
  `embedding_model = $X` filter).

### Step 7 — CLI surface (`/memory list` uses `:list_recent`)

**Modified files:**
- `lib/jido_claw/cli/commands.ex` — replace the `/memory` block:
  - `/memory blocks` — `Memory.Block.for_scope_chain`.
  - `/memory blocks edit <label>` — `$EDITOR` on block value;
    on save, `Memory.Block.revise` with `actor: :user`.
  - `/memory blocks history <label>` — `Block.history_for_label`.
  - `/memory list` — preserved via `Memory.Retrieval.list_recent/2`,
    mirroring today's `list_recent(20)`. Do not implement list as an
    empty-query search.
  - `/memory search <q>` — `Retrieval.search/2`.
  - `/memory save <label> <content>` —
    `Memory.remember_from_user/2`.
  - `/memory forget <label> [--source model|user|all]` — default
    `:user_save`; on multi-source ambiguity without `--source`,
    list candidates via `dedup: :none` and prompt.

  Do **not** add `/memory consolidate` or `/memory status` — 3b.
- `lib/jido_claw/cli/branding.ex` — help text update.
- `lib/jido_claw/cli/presenters.ex` — `format_memory_results/1`
  works unchanged (return-shape preserved).

**Tests** (`test/jido_claw/cli/memory_commands_test.exs`):
- Each subcommand's parsing + dispatch.
- `/memory list` returns rows on a fresh scope without seeded
  FTS-matchable content (pins #10 fix).

### Step 8 — Embedding backfill + policy transitions for Memory

- Extend `JidoClaw.Workspaces.PolicyTransitions.apply_embedding/3`
  so every policy transition updates both `solutions` and
  `memory_facts`. The same transition table applies:
  `:disabled -> :default/:local_only` sets disabled Memory Facts to
  `:pending`; model changes null incompatible ready embeddings and
  requeue; disabling sets pending/processing/failed to `:disabled`
  and optionally purges ready embeddings with `purge_existing: true`.

**Modified files:**

1. `lib/jido_claw/embeddings/backfill_worker.ex` — extend the
   scan loop to discover both `Solutions.Solution` and
   `Memory.Fact` rows. The two-branch WHERE pattern stays:

   ```sql
   WHERE embedding_status = 'pending'
      OR (embedding_status = 'processing'
          AND embedding_next_attempt_at < now() - INTERVAL '5 minutes')
   ```

   honored for `:processing` lease expiry on Memory.Fact rows
   (this is why §2.3 puts `:processing` in the enum).

2. **`lib/jido_claw/workspaces/policy_transitions.ex`** — add
   `apply_memory_embedding/3` mirroring the existing
   `apply_embedding/3` for Solutions:

   ```elixir
   @doc """
   Memory.Fact analogue of `apply_embedding/3`. Same transition
   table; UPDATE memory_facts instead of solutions.
   """
   @spec apply_memory_embedding(String.t(), atom(), keyword()) :: :ok | {:error, term()}
   def apply_memory_embedding(workspace_id, :disabled, opts) do
     purge? = Keyword.get(opts, :purge_existing, false)

     Repo.transaction(fn ->
       Repo.query!(
         """
         UPDATE memory_facts
            SET embedding_status = 'disabled',
                embedding_attempt_count = 0,
                embedding_next_attempt_at = NULL,
                embedding_last_error = NULL
          WHERE workspace_id = $1
            AND embedding_status IN ('pending', 'processing', 'failed')
         """,
         [Ecto.UUID.dump!(workspace_id)]
       )

       if purge? do
         Repo.query!("UPDATE memory_facts SET embedding = NULL, ...", [...])
       end
     end)
     |> normalize_result()
   end

   def apply_memory_embedding(workspace_id, policy, _opts) when policy in [:default, :local_only] do
     # Re-enable :disabled rows + (for cross-policy flips) NULL :ready
     # rows so they re-embed under the new model. Same as Solutions.
     ...
   end
   ```

   **Caller sites.** `Workspace.set_embedding_policy/2`'s caller
   (today: only `apply_embedding/3`) must invoke BOTH after the
   policy flip. Search call sites: `grep -r "apply_embedding"
   lib/`. Without this, flipping `embedding_policy` updates
   Solutions but leaves Memory rows stale — a user-visible bug.

**New module(s)** — copy from
`lib/jido_claw/solutions/resources/solution.ex`:
- `Changes.ResolveInitialEmbeddingStatus` (or shared helper)
  that reads `Workspace.embedding_policy` at create time and
  resolves `:disabled` vs `:pending`.
- `Changes.HintBackfillWorker` that emits `{:hint_pending, id}`
  from `after_transaction` so the worker doesn't wait for the
  next scan.

**Tests** (`test/jido_claw/memory/embedding_backfill_test.exs`):
- Workspace `:disabled` → Fact `embedding_status: :disabled`.
- Flip to `:default` via `Workspace.set_embedding_policy` →
  Memory.Fact rows transition `:disabled → :pending`.
- Worker processes `:pending → :processing → :ready`.
- **`:processing` lease expiry**: write a Fact with
  `embedding_status: :processing` and
  `embedding_next_attempt_at` in the past; assert next scan
  re-claims it.
- **Cross-resource policy transition**: workspace at `:default`
  with both Memory.Fact and Solutions.Solution rows `:ready`;
  flip to `:local_only` with `purge_existing: true`; assert
  BOTH tables NULL embeddings and re-mark `:pending`.

### Step 9 — Migration tasks

**New files:**
- `lib/mix/tasks/jidoclaw.migrate.memory.ex` — walks
  `.jido/memory.json` per workspace,
  `Workspaces.Resolver.ensure_workspace/3` (correct function
  name — not `ensure/1`), calls `Memory.Fact.import_legacy`.
  Idempotent via `unique_import_hash`.
- `lib/mix/tasks/jidoclaw.export.memory.ex` — round-trips active
  Memory.Fact rows to v0.5.x JSON shape; drops Block / Episode /
  Link with manifest warning.

Pattern reference: `lib/mix/tasks/jidoclaw.migrate.conversations.ex`
+ `.export.conversations.ex` (v0.6.2).

**Tests** (`test/jido_claw/memory/migrate_task_test.exs`):
- Sanitized-fixture round-trip.
- Redaction-delta-fixture round-trip with manifest.
- Idempotency — second migrate run inserts zero rows.

### Step 10 — Decommissioning

**Deletions:**
- `lib/jido_claw/platform/memory.ex` (the GenServer).
- `test/jido_claw/memory_test.exs` (after relocating
  preserved assertions to `test/jido_claw/memory/`).

**Modified:**
- `lib/jido_claw/application.ex` — drop the `JidoClaw.Memory`
  Core child spec.
- `mix.exs` — drop `:jido_memory` if unused. Verify
  `grep -r "Jido.Memory" lib/ test/` is zero.

**Validate:**
```bash
mix compile --warnings-as-errors
mix format --check-formatted
mix test
mix ash.codegen --check
grep -r "JidoClaw.Memory.remember/3\|@store" lib/ test/   # zero hits
```

### Step 11 — Acceptance gate sweep

Targeted gates (above and beyond the per-step tests):

- `mix ash_postgres.generate_migrations` clean — every partial
  identity has its `identity_wheres_to_sql` entry.
- **Cross-scope partial-identity isolation**: session-scoped
  Fact at workspace W1 doesn't collide with workspace-scoped
  Fact at W1 with the same label.
- **Cross-tenant FK validation** at every populated FK level
  (not just leaf).
- **Cross-tenant `Memory.Link` rejection**.
- **Scope denormalization** for `BlockRevision` and
  `FactEpisode`.
- **Source-protect**: `:promote`, `:invalidate_by_*`,
  `Block.:revise` reject consolidator-actor mutation of user
  rows.
- **Copy-on-write `:promote`**: predecessor preserved with
  `expired_at`; system-time-travel returns predecessor's
  pre-promote shape.
- **Concurrent label replacement**: 20 concurrent writers
  produce 1 active + 19 invalidated.
- **`/memory list` on fresh scope** returns rows (no FTS-
  matchable content needed).
- **Cross-resource policy transition**: workspace flip updates
  both `solutions` and `memory_facts`.
- Bitemporal queries: current truth, world-time, system-time,
  full-axis matrix.
- Embedding backfill recovery (worker crash mid-claim).
- **Ancestor-FK identity isolation** — session-scoped and workspace-
  scoped rows with the same label can coexist because partial unique
  indexes include `scope_kind`.
- **ToolContext FK mapping** — Memory writes use `workspace_uuid` and
  `session_uuid`, never runtime `workspace_id`.
- **Prompt snapshot ordering** — snapshot is persisted and injected
  after durable session resolution and before the first model request.
- **Scoped MCP smoke test** — start the per-run HTTP server, discover
  the bound port, and execute one tool call through Anubis/Bandit.
- **Policy transition dual-table test** — flipping workspace
  `embedding_policy` updates both `solutions` and `memory_facts`.

Out of 3a scope (deferred): consolidator opt-out / concurrency /
crash-recovery, frozen-snapshot prompt cache, scheduled-run
Block content, Codex round-trip, dynamic MCP server tool-call
HTTP test.

---

## Out-of-band notes for 3b/3c

These review items aren't 3a's responsibility but should be
pinned for the 3b plan when it's drafted:

- Add `Conversations.Session.set_prompt_snapshot` (or
  `update_metadata`) update action. It merges
  `metadata["prompt_snapshot"]` without disturbing existing metadata.
- Reorder prompt injection so durable `Workspace` and
  `Conversations.Session` rows are resolved before the final
  session-scoped system prompt is injected. Boot may inject only a
  static placeholder; the session snapshot becomes authoritative
  before the first model turn. (Today,
  `Startup.inject_system_prompt/2` runs in `lib/jido_claw.ex:71`
  BEFORE persistence resolution; CLI persisted-session setup
  happens later in `lib/jido_claw/cli/repl.ex:147`.)
- The 3b scoped MCP server must start a Bandit endpoint on a free
  port (`port: 0`). Port discovery uses Bandit / ThousandIsland
  APIs such as `ThousandIsland.listener_info/1`. The scoped server
  does **not** rely on `use Jido.MCP.Server` for a runtime tool
  list, because that macro publishes tools at compile time.
  Implement the scoped server directly with `Anubis.Server`, or
  use a fixed module list and pass per-run state through
  `Frame.assigns` / registry lookup.
- Because a session-level advisory lock pins one Repo connection
  for the harness window, `max_concurrent_scopes` must be bounded
  below the Repo pool size. Default to a conservative value, e.g.
  `1` or `max(1, pool_size - reserved_connections)`, and document
  that each in-flight consolidator run holds one checked-out
  connection until unlock. 3a uses `pg_advisory_xact_lock`
  (transaction-scoped, no pool concern); the session-level lock
  is 3b territory.
- **Worker templates' `anthropic_prompt_cache: true`.** Seven
  workers under `lib/jido_claw/agent/workers/` each declare
  their own `llm_opts` and don't inherit the main agent's cache
  flag. 3b's snapshot only fires for the main agent's sessions
  until each worker template adopts the flag.

---

## Spec corrections (applied immediately after plan approval)

These are edits to `docs/plans/v0.6/phase-3a-memory-data.md`
that fold this plan's decisions back into the canonical spec.
They cannot be applied in plan mode (only the plan file is
editable here). Once `ExitPlanMode` is approved, I apply them
in this order:

1. **§3.6 attribute table** — `embedding_status` constraint:
   `:pending | :processing | :ready | :failed | :disabled`
   (add `:processing` to the existing 4-value enum).
2. **§3.6 "Why this is no longer an upsert"** — REWRITE the
   invalidate-and-replace step list to match §2.0 of this plan.
   Specifically: change step 2 from "set its `invalid_at = now()`
   and `expired_at = now()`" to "set its `expired_at = now()` —
   do NOT mutate `invalid_at`, which is a world-axis state that
   stays frozen for the predecessor." This is the bitemporal
   copy-on-write rule.
3. **§3.6 actions / `:promote`** — rewrite as copy-on-write
   (insert successor with promoted attrs, set predecessor
   `expired_at` only, write `:supersedes` Link). Add the
   `actor: :consolidator AND predecessor.source == :user_save →
   :user_fact_protected` guard.
4. **§3.6 actions / `:invalidate_by_id`,
   `:invalidate_by_label`** — REPLACE the in-place mutation
   description ("sets `invalid_at` and `expired_at` on the live
   row") with the copy-on-write composition: insert a successor
   row with `invalid_at = now()` and the predecessor's other
   fields copied; set predecessor's `expired_at = now()`. Add
   the same source-protect guard for `actor: :consolidator`.
   The action surface becomes a wrapper in `JidoClaw.Memory`
   that composes two underlying CRUD actions
   (`:record_invalidation` create + `:expire_predecessor`
   update) — see §2.2 of this plan.
5. **§3.6 attribute table / partial identities** — every Fact
   active partial unique identity gains an `expired_at IS NULL`
   clause. Without it, copy-on-write predecessors (with
   `invalid_at IS NULL` but `expired_at` set) would collide with
   their successors in the unique-active set. The 8 affected
   identities are the 4 `unique_active_label_per_scope_<X>` and
   the 4 `unique_active_promoted_content_per_scope_<X>`. Update
   `identity_wheres_to_sql` entries in
   `docs/plans/v0.6/README.md §Cross-cutting / Partial
   identities` accordingly.
   - Note: `Memory.Block` partial identities do NOT need this
     addition. Block is mutated in-place (audit lives in
     `BlockRevision`), so its active-set predicate is just
     `invalid_at IS NULL`.
6. **§3.4 actions / `Block.:revise`** — add the source-protect
   guard for `actor: :consolidator AND current.source == :user
   → :user_block_protected`.
7. **§3.6 prose** ("Why this is no longer an upsert") —
   replace the "rely on the partial unique constraint" wording
   with "transaction-level advisory lock keyed on `(tenant,
   scope_kind, scope_fk_id, label)`; partial unique constraint
   (now including `expired_at IS NULL` per #5) is
   defense-in-depth."
8. **§3.6 actions** — drop the `:search` Ash action; add
   `:list_recent` action (recency-sorted, no FTS, used by
   `/memory list` and `Memory.list_recent/1`). Plus add the
   two new internal CRUD actions used by the
   copy-on-write flows: `:record_invalidation` (create) and
   `:expire_predecessor` (update).
9. **§3a.0 Implementation discoveries** — append:
   - ToolContext FK rename: `Memory.Scope.resolve/1` reads
     `tool_context.workspace_uuid` / `:session_uuid` and writes
     to `Memory.Fact.workspace_id` / `.session_id`. The runtime
     `tool_context.workspace_id` / `:session_id` are NOT used.
   - Concurrent-write protection uses `pg_advisory_xact_lock`;
     session-level locks are 3b territory.
   - `Workspaces.PolicyTransitions.apply_memory_embedding/3`
     is the Memory analogue of `apply_embedding/3`; both must
     be invoked when `Workspace.set_embedding_policy/2` flips.
   - **Bitemporal copy-on-write is the only mutation pattern
     for `Memory.Fact`.** Predecessor's `expired_at` is the
     ONLY field ever mutated in place. `:record` label
     replacement, `:promote`, and `:invalidate_by_*` all
     follow this pattern.
10. **§3.4 / §3.6 identity prose** — restate that each partial
    identity's WHERE clause is `scope_kind = '<X>' AND <fk> IS
    NOT NULL AND label IS NOT NULL AND invalid_at IS NULL AND
    expired_at IS NULL` (Fact) or `... AND invalid_at IS NULL`
    (Block). NOT `<fk> IS NOT NULL` alone. The per-scope_kind
    discriminator is what prevents a session-scoped row with
    ancestor `workspace_id` from colliding with a workspace-
    scoped row at the same label.

---

## Risks & rollback

- **Identity-where SQL drift.** Run
  `mix ash_postgres.generate_migrations` after each resource
  is added. The cross-scope partial-identity isolation test in
  Step 11 catches a buggy `where(expr)` that compiles silently.
- **Generated-column expression drift.** If the IMMUTABLE
  wrapper signature changes, the migration fails at
  `CREATE TABLE` (intended fail-loud). Wrapper signatures
  documented inline at the top of the migration.
- **HNSW partial-by-model index assumption.** The retrieval
  query relies on `embedding_model = $X` to hit the partial
  index. The embedding-space isolation gate in Step 6 catches
  refactors that drop the filter.
- **Advisory lock overhead.** `pg_advisory_xact_lock` is
  transaction-scoped and auto-released. No pool concern for
  3a. Many concurrent writes to the same `(scope, label)`
  serialize — desired behavior. Reads are unaffected.
- **`Memory.list_recent/1` consumer compatibility.**
  `lib/jido_claw/agent/prompt.ex:427` (until 3b's snapshot
  rewrite removes it) and CLI presenter call this expecting
  `%{key, content, type, created_at, updated_at}` maps. The
  return-shape pin is in `test/jido_claw/memory_test.exs`.
- **Policy-transition coverage.** The cross-resource policy-
  transition test in Step 8 catches a missed Memory.Fact
  branch.
- **Rollback.** 3a removes `lib/jido_claw/platform/memory.ex`
  and the `JidoClaw.Memory` child spec. Per source plan's
  "Rollback caveat," `mix jidoclaw.export.memory` must run
  before downgrading; the rolled-back binary doesn't read
  Postgres tables.

## Validation checklist (run before tagging `v0.6.3a`)

```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix ash.codegen --check
mix ash_postgres.generate_migrations         # no identity_wheres_to_sql errors
mix test                                     # full suite green
mix test test/jido_claw/memory                # focused
grep -r "JidoClaw.Memory.remember/3\|Jido.Memory.Store" lib/ test/   # zero hits
```

When all clean: tag `v0.6.3a`, ship.
