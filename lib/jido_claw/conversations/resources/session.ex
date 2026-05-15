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

  use JidoClaw.Resource, domain: JidoClaw.Conversations

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
    define(:active_for_workspace, action: :active_for_workspace, args: [:workspace_id])

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
      require_atomic?(false)

      change(fn changeset, _ctx ->
        snap = Ash.Changeset.get_argument(changeset, :snapshot)
        md = Ash.Changeset.get_attribute(changeset, :metadata) || %{}

        Ash.Changeset.force_change_attribute(
          changeset,
          :metadata,
          Map.put(md, "prompt_snapshot", snap)
        )
      end)
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

      constraints(
        one_of: [:repl, :discord, :telegram, :web_rpc, :cron, :api, :mcp, :imported_legacy]
      )
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
end
