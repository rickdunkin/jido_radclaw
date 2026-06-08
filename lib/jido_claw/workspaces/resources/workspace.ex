defmodule JidoClaw.Workspaces.Workspace do
  @moduledoc """
  Tenant-scoped anchor row for a project directory.

  Created lazily by `JidoClaw.Workspaces.Resolver.ensure_workspace/3` on
  every entry-point that opens a session. Two partial-unique identities
  separate authenticated rows (carry a `user_id`) from CLI-style rows
  (no `user_id`) so the same `path` under one tenant can coexist for both
  audiences without colliding.

  ## Policy attributes

  `embedding_policy` and `consolidation_policy` carry per-workspace toggles.
  Both accept `:default | :disabled`. The resolver writes the defaults on
  initial create and the upsert path is restricted (via
  `upsert_fields([:updated_at])`) so user-tuned values are preserved across
  repeat resolver calls.
  """

  use JidoClaw.Resource, domain: JidoClaw.Workspaces

  postgres do
    table("workspaces")
    repo(JidoClaw.Repo)

    identity_wheres_to_sql(
      unique_user_path_authed: "user_id IS NOT NULL",
      unique_user_path_cli: "user_id IS NULL"
    )

    custom_indexes do
      index([:tenant_id, :user_id, :path])
    end
  end

  multitenancy do
    strategy(:attribute)
    attribute(:tenant_id)
    global?(false)
  end

  code_interface do
    define(:register, action: :register)
    define(:rename, action: :rename, args: [:name])
    define(:archive, action: :archive)
    define(:set_embedding_policy, action: :set_embedding_policy, args: [:embedding_policy])

    define(:set_consolidation_policy,
      action: :set_consolidation_policy,
      args: [:consolidation_policy]
    )

    define(:list, action: :read)
    define(:by_id, action: :by_id, args: [:id], get?: true)
    define(:by_id_global, action: :by_id_global, args: [:id], get?: true)
    define(:by_path, action: :by_path, args: [:user_id, :path], get?: true)
    define(:for_user, action: :for_user, args: [:user_id])
  end

  actions do
    defaults([:read, :destroy])

    create :register do
      primary?(true)

      accept([
        :name,
        :path,
        :user_id,
        :project_id,
        :embedding_policy,
        :consolidation_policy,
        :metadata
      ])

      upsert_fields([:updated_at])
    end

    update :rename do
      accept([])
      argument(:name, :string, allow_nil?: false)
      change(set_attribute(:name, arg(:name)))
    end

    update :archive do
      accept([])
      change(set_attribute(:archived_at, &DateTime.utc_now/0))
    end

    update :set_embedding_policy do
      accept([])

      argument(:embedding_policy, :atom,
        allow_nil?: false,
        constraints: [one_of: [:default, :disabled]]
      )

      change(set_attribute(:embedding_policy, arg(:embedding_policy)))
    end

    update :set_consolidation_policy do
      accept([])

      argument(:consolidation_policy, :atom,
        allow_nil?: false,
        constraints: [one_of: [:default, :disabled]]
      )

      change(set_attribute(:consolidation_policy, arg(:consolidation_policy)))
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

    read :by_path do
      get?(true)
      argument(:user_id, :uuid, allow_nil?: true)
      argument(:path, :string, allow_nil?: false)

      filter(
        expr(
          path == ^arg(:path) and
            ((is_nil(user_id) and is_nil(^arg(:user_id))) or user_id == ^arg(:user_id))
        )
      )
    end

    read :for_user do
      argument(:user_id, :uuid, allow_nil?: false)
      filter(expr(user_id == ^arg(:user_id)))
    end

    # Additive undo seam for `Ash.Reactor` create-step rollback. The Reactor
    # undo path calls `Changeset.for_destroy(:reactor_undo, %{changeset: stored})`,
    # and the create-step builder verifier requires the undo action to take
    # exactly one `:changeset` argument — the default `:destroy` does not. The
    # tenant write policy (`action_type :destroy` -> `ActorTenantMatches`) still
    # authorizes this destroy; `public?(false)` only keeps it off
    # code-interface / AshAdmin surfaces, not the internal undo path.
    destroy :reactor_undo do
      description("Undo action for Ash.Reactor create-step rollback.")
      public?(false)
      argument(:changeset, :term)
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute :name, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :path, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :user_id, :uuid do
      allow_nil?(true)
      public?(true)
    end

    attribute :project_id, :uuid do
      allow_nil?(true)
      public?(true)
    end

    attribute :tenant_id, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :embedding_policy, :atom do
      allow_nil?(false)
      public?(true)
      default(:disabled)
      constraints(one_of: [:default, :disabled])
    end

    attribute :consolidation_policy, :atom do
      allow_nil?(false)
      public?(true)
      default(:disabled)
      constraints(one_of: [:default, :disabled])
    end

    attribute :metadata, :map do
      allow_nil?(true)
      public?(true)
      default(%{})
    end

    attribute :archived_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
    end

    timestamps()
  end

  relationships do
    belongs_to :tenant, JidoClaw.Tenants.Tenant do
      define_attribute?(false)
      attribute_writable?(true)
      allow_nil?(false)
    end

    belongs_to :user, JidoClaw.Accounts.User do
      define_attribute?(false)
      attribute_writable?(true)
      allow_nil?(true)
    end

    belongs_to :project, JidoClaw.Projects.Project do
      define_attribute?(false)
      attribute_writable?(true)
      allow_nil?(true)
    end
  end

  identities do
    identity(:unique_user_path_authed, [:tenant_id, :user_id, :path],
      where: expr(not is_nil(user_id))
    )

    identity(:unique_user_path_cli, [:tenant_id, :path], where: expr(is_nil(user_id)))
  end
end
