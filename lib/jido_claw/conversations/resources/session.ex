defmodule JidoClaw.Conversations.Session do
  @moduledoc """
  Tenant- and workspace-scoped row representing a conversation session.

  Created by `JidoClaw.Conversations.Resolver.ensure_session/5` on every
  surface dispatch. The single uniqueness identity is
  `(tenant_id, workspace_id, kind, external_id)`, matching the natural
  per-surface keying (e.g. one Discord channel produces one session per
  tenant/workspace). The `:start` action uses upsert semantics restricted
  via `upsert_fields([:last_active_at, :updated_at])` so repeat calls only
  touch the recency markers — `started_at`, `metadata`,
  `idle_timeout_seconds`, `closed_at`, and `next_sequence` are preserved.

  ## Cross-tenant FK invariant

  `:start` runs a `before_action` hook that fetches the parent Workspace
  inside the create transaction and refuses to insert when the supplied
  `tenant_id` doesn't match the Workspace's `tenant_id`. This is the
  validate-equality form of v0.6's broader tenant integrity work — the
  copy-from-parent shape doesn't apply here because every Phase 0 caller
  already has both the Workspace UUID and the tenant in hand.
  """

  use JidoClaw.Resource,
    domain: JidoClaw.Conversations,
    global_actions: [:list_open_for_workspaces_global]

  alias JidoClaw.Conversations.Resources.GlobalLookup
  alias JidoClaw.Workspaces.Workspace

  postgres do
    table("conversation_sessions")
    repo(JidoClaw.Repo)

    custom_indexes do
      index([:workspace_id, :started_at])
      index([:tenant_id, :last_active_at])
    end
  end

  multitenancy do
    strategy(:attribute)
    attribute(:tenant_id)
    global?(false)
  end

  code_interface do
    define(:start, action: :start)
    define(:touch, action: :touch)
    define(:close, action: :close)
    define(:set_next_sequence, action: :set_next_sequence, args: [:next_sequence])
    define(:set_prompt_snapshot, action: :set_prompt_snapshot, args: [:snapshot])
    define(:set_compaction_snapshot, action: :set_compaction_snapshot, args: [:key, :snapshot])
    define(:set_current_agent_template, action: :set_current_agent_template, args: [:template])
    define(:set_triage_path, action: :set_triage_path, args: [:path])
    define(:set_path_transitions, action: :set_path_transitions, args: [:transitions])
    define(:set_oscillation_marker, action: :set_oscillation_marker, args: [:at])
    define(:set_pending_prototype, action: :set_pending_prototype, args: [:candidate])
    define(:active_for_workspace, action: :active_for_workspace, args: [:workspace_id])
    define(:list, action: :read)
    define(:list_open_for_workspaces_global, args: [:workspace_ids])

    define(:by_external,
      action: :by_external,
      args: [:workspace_id, :kind, :external_id],
      get?: true
    )

    define(:by_id, action: :by_id, args: [:id], get?: true)
    define(:by_id_global, action: :by_id_global, args: [:id], get?: true)
  end

  actions do
    defaults([:read, :destroy])

    create :start do
      primary?(true)

      accept([
        :workspace_id,
        :user_id,
        :kind,
        :external_id,
        :started_at,
        :idle_timeout_seconds,
        :metadata
      ])

      change(set_attribute(:last_active_at, &DateTime.utc_now/0))

      change(fn changeset, _ctx ->
        Ash.Changeset.before_action(changeset, fn cs ->
          tenant_id = cs.tenant || Ash.Changeset.get_attribute(cs, :tenant_id)
          workspace_id = Ash.Changeset.get_attribute(cs, :workspace_id)

          GlobalLookup.validate_tenant_match(
            cs,
            workspace_id,
            tenant_id,
            :workspace_id,
            &Workspace.by_id_global/1,
            "workspace_not_found"
          )
        end)
      end)

      change({JidoClaw.Audit.Producers.SessionStart, []})
    end

    update :touch do
      accept([])
      change(set_attribute(:last_active_at, &DateTime.utc_now/0))
    end

    update :close do
      accept([])
      require_atomic?(false)
      change(set_attribute(:closed_at, &DateTime.utc_now/0))
      change({JidoClaw.Audit.Producers.SessionEnd, []})
    end

    update :set_next_sequence do
      accept([])
      argument(:next_sequence, :integer, allow_nil?: false)
      change(set_attribute(:next_sequence, arg(:next_sequence)))
    end

    update :set_prompt_snapshot do
      accept([])
      argument(:snapshot, :string, allow_nil?: false)

      change({__MODULE__.Changes.SetMetadataKey, key: "prompt_snapshot", argument: :snapshot})
    end

    # Per-agent compaction snapshots are keyed under
    # `metadata["compactions"][key]` (note the plural — distinct from the
    # legacy single `metadata["compaction"]` slot). The write is ATOMIC: a
    # `jsonb_set` in the UPDATE itself, so two agents persisting different
    # keys concurrently both survive (Postgres serializes the row update, and
    # each `jsonb_set` operates on the other's committed value). The path arg
    # is an explicit `::text[]` and the snapshot is `Jason.encode!`-ed then
    # cast `::jsonb`.
    # Atomic per-key write via a named change implementing `atomic/3`, so the
    # action runs fully atomically (a function change would force the
    # non-atomic path, which silently drops the SQL expression).
    update :set_compaction_snapshot do
      accept([])
      argument(:key, :string, allow_nil?: false)
      argument(:snapshot, :map, allow_nil?: false)

      change({__MODULE__.Changes.SetCompactionSnapshot, []})
    end

    update :set_current_agent_template do
      accept([])
      argument(:template, :string, allow_nil?: true)

      change(
        {__MODULE__.Changes.SetMetadataKey, key: "current_agent_template", argument: :template}
      )
    end

    # AR-8 triage stickiness (Phase 3c): the front door persists the latest
    # verdict path under `metadata["last_triage_path"]` for observability /
    # cold-start (the decision itself is the fresh per-turn verdict, not this).
    # Reuses `SetMetadataKey` (no new change module) and stores the path as a
    # STRING (`to_string(path)`) — never an atom at the JSON boundary. The
    # `allow_nil?: false` argument makes the change's delete branch unreachable.
    update :set_triage_path do
      accept([])
      argument(:path, :string, allow_nil?: false)

      change({__MODULE__.Changes.SetMetadataKey, key: "last_triage_path", argument: :path})
    end

    # AR-8b-2 C2 oscillation guard: the bounded newest-first path-transition log
    # under `metadata["path_transitions"]` (the front door computes + caps it off
    # the snapshot, then overwrites). Reuses `SetMetadataKey` (atomic jsonb_set)
    # — no new change module. `allow_nil?: false` makes the delete branch
    # unreachable (the guard always writes a list, never clears).
    update :set_path_transitions do
      accept([])
      argument(:transitions, {:array, :map}, allow_nil?: false)

      change({__MODULE__.Changes.SetMetadataKey, key: "path_transitions", argument: :transitions})
    end

    # AR-8b-2 C2 "ask once, then proceed" marker under
    # `metadata["oscillation_prompted_at"]`. Set (ISO8601 string) on a debounce;
    # CLEARED (nil → the change's `#-` delete branch) on any proceed or a talk
    # turn. `allow_nil?: true` so the clear path is live.
    update :set_oscillation_marker do
      accept([])
      argument(:at, :string, allow_nil?: true)

      change({__MODULE__.Changes.SetMetadataKey, key: "oscillation_prompted_at", argument: :at})
    end

    # AR-8b-2 C1 durable graduation candidate under
    # `metadata["pending_prototype"]`. Set (a JSON-safe candidate map) on a
    # non-sensitive sketch launch; CONSUMED/CLEARED (nil → delete branch) on a
    # relevant graduation, a sensitive sketch, or a newer sketch replacing it.
    # `allow_nil?: true` so the consume path is live.
    update :set_pending_prototype do
      accept([])
      argument(:candidate, :map, allow_nil?: true)

      change({__MODULE__.Changes.SetMetadataKey, key: "pending_prototype", argument: :candidate})
    end

    read :active_for_workspace do
      argument(:workspace_id, :uuid, allow_nil?: false)
      filter(expr(workspace_id == ^arg(:workspace_id) and is_nil(closed_at)))
    end

    read :by_external do
      get?(true)
      argument(:workspace_id, :uuid, allow_nil?: false)
      argument(:kind, :atom, allow_nil?: false)
      argument(:external_id, :string, allow_nil?: false)

      filter(
        expr(
          workspace_id == ^arg(:workspace_id) and
            kind == ^arg(:kind) and external_id == ^arg(:external_id)
        )
      )
    end

    read :by_id do
      get?(true)
      argument(:id, :uuid, allow_nil?: false)
      filter(expr(id == ^arg(:id)))
    end

    read :by_id_global do
      get?(true)
      multitenancy(:bypass)
      argument(:id, :uuid, allow_nil?: false)
      filter(expr(id == ^arg(:id)))
    end

    # The Memory.Consolidator tick's per-session discovery seam: a
    # system-level scan over the (already cross-tenant) workspace candidate
    # set, policy-bypassed via the macro's `global_actions:` option.
    read :list_open_for_workspaces_global do
      description("Cross-tenant scan of open sessions belonging to the given workspaces.")
      multitenancy(:bypass)
      argument(:workspace_ids, {:array, :uuid}, allow_nil?: false)
      filter(expr(workspace_id in ^arg(:workspace_ids) and is_nil(closed_at)))
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute :workspace_id, :uuid do
      allow_nil?(false)
      public?(true)
    end

    attribute :user_id, :uuid do
      allow_nil?(true)
      public?(true)
    end

    attribute :kind, :atom do
      allow_nil?(false)
      public?(true)

      constraints(one_of: [:repl, :discord, :web_rpc, :cron, :api, :mcp, :imported_legacy])
    end

    attribute :external_id, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :tenant_id, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :started_at, :utc_datetime_usec do
      allow_nil?(false)
      public?(true)
    end

    attribute :last_active_at, :utc_datetime_usec do
      allow_nil?(false)
      public?(true)
    end

    attribute :closed_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
    end

    attribute :idle_timeout_seconds, :integer do
      allow_nil?(true)
      public?(true)
      default(300)
    end

    attribute :next_sequence, :integer do
      allow_nil?(false)
      public?(true)
      default(1)
    end

    attribute :metadata, :map do
      allow_nil?(true)
      public?(true)
      default(%{})
    end

    timestamps()
  end

  relationships do
    belongs_to :tenant, JidoClaw.Tenants.Tenant do
      define_attribute?(false)
      attribute_writable?(true)
      allow_nil?(false)
    end

    belongs_to :workspace, JidoClaw.Workspaces.Workspace do
      define_attribute?(false)
      attribute_writable?(true)
      allow_nil?(false)
    end

    belongs_to :user, JidoClaw.Accounts.User do
      define_attribute?(false)
      attribute_writable?(true)
      allow_nil?(true)
    end
  end

  identities do
    identity(:unique_external, [:tenant_id, :workspace_id, :kind, :external_id])
  end

  # ---------------------------------------------------------------------------
  # Inline change modules
  # ---------------------------------------------------------------------------

  defmodule Changes.SetMetadataKey do
    @moduledoc """
    Atomically sets or deletes a single top-level `metadata[key]` slot via
    `jsonb_set` / `#-` in the UPDATE itself, so a writer holding a stale
    record can never clobber concurrently-written sibling keys
    (e.g. `metadata["compactions"]`).

    A nil argument deletes the key (Map.delete semantics). That branch is a
    real path only for actions whose argument is `allow_nil?: true`
    (`:set_current_agent_template`); for `:set_prompt_snapshot` the
    `allow_nil?: false` argument is rejected by action-input validation
    before the change runs, so its delete branch is generic-but-unreachable.
    """
    use Ash.Resource.Change

    import Ash.Expr

    @impl Ash.Resource.Change
    def init(opts) do
      # Parameterized change: fail fast on malformed opts instead of letting
      # a nil key/argument flow into get_argument or the SQL path. Uses
      # Keyword.fetch/2 + {:error, ...} (the callback's contract) rather than
      # a raising fetch!.
      with {:ok, key} when is_binary(key) <- Keyword.fetch(opts, :key),
           {:ok, argument} when is_atom(argument) <- Keyword.fetch(opts, :argument) do
        {:ok, opts}
      else
        _ ->
          {:error,
           "SetMetadataKey requires :key (string) and :argument (atom), got: #{inspect(opts)}"}
      end
    end

    @impl Ash.Resource.Change
    def atomic(changeset, opts, _context) do
      key = Keyword.fetch!(opts, :key)

      case Ash.Changeset.get_argument(changeset, Keyword.fetch!(opts, :argument)) do
        nil ->
          {:atomic,
           %{
             metadata:
               {:atomic,
                expr(fragment("coalesce(?, '{}'::jsonb) #- array[?]::text[]", metadata, ^key))}
           }}

        value ->
          # Encode-then-`::text::jsonb`: passing the raw value to a `::jsonb`
          # param double-encodes it (see SetCompactionSnapshot below).
          encoded = Jason.encode!(value)

          {:atomic,
           %{
             metadata:
               {:atomic,
                expr(
                  fragment(
                    "jsonb_set(coalesce(?, '{}'::jsonb), array[?]::text[], ?::text::jsonb, true)",
                    metadata,
                    ^key,
                    ^encoded
                  )
                )}
           }}
      end
    end
  end

  defmodule Changes.SetCompactionSnapshot do
    @moduledoc """
    Atomically writes a per-agent compaction snapshot under
    `metadata["compactions"][key]` via a single `jsonb_set`.

    Implemented as an `atomic/3` change (not a function change) so the
    action runs fully atomically: the expression is applied in the UPDATE
    itself, and two agents persisting different keys concurrently both
    survive (Postgres serializes the row update; each `jsonb_set` operates
    on the other's committed value).
    """
    use Ash.Resource.Change

    import Ash.Expr

    @impl Ash.Resource.Change
    def atomic(changeset, _opts, _context) do
      key = Ash.Changeset.get_argument(changeset, :key)
      # Encode the snapshot to a JSON text literal and parse it back with
      # `::text::jsonb`. Passing the raw map (or a `Jason`-encoded string) to a
      # `::jsonb` param double-encodes it into a jsonb *string*; forcing the
      # param to `text` first makes Postgres parse the JSON into an object.
      encoded = Jason.encode!(Ash.Changeset.get_argument(changeset, :snapshot))

      # The inner `{:atomic, expr}` value skips `Ash.Type.Map.cast_atomic/3`
      # (which refuses expression-based atomic updates); the fragment already
      # produces valid jsonb.
      #
      # NOTE: a naive `jsonb_set(metadata, array['compactions', key], …)` is a
      # no-op when the `compactions` parent is absent — `jsonb_set` does not
      # create intermediate objects. So we set the top-level `compactions` key
      # to `(existing compactions OR {}) || {key: snapshot}`: `||` preserves
      # sibling keys and overwrites only this one. Reading `metadata` inside
      # the UPDATE keeps it atomic (concurrent distinct-key writes both
      # survive — Postgres serializes the row update).
      {:atomic,
       %{
         metadata:
           {:atomic,
            expr(
              fragment(
                "jsonb_set(coalesce(?, '{}'::jsonb), array['compactions']::text[], coalesce(? -> 'compactions', '{}'::jsonb) || jsonb_build_object(?::text, ?::text::jsonb), true)",
                metadata,
                metadata,
                ^key,
                ^encoded
              )
            )}
       }}
    end
  end
end
