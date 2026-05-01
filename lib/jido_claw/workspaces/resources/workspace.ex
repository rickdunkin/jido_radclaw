defmodule JidoClaw.Workspaces.Workspace do
  @moduledoc """
  Tenant-scoped anchor row for a project directory.

  Created lazily by `JidoClaw.Workspaces.Resolver.ensure_workspace/3` on
  every entry-point that opens a session. Two partial-unique identities
  separate authenticated rows (carry a `user_id`) from CLI-style rows
  (no `user_id`) so the same `path` under one tenant can coexist for both
  audiences without colliding.

  ## Policy attributes

  `embedding_policy` and `consolidation_policy` carry per-workspace toggles
  for v0.6's later Memory phase. Phase 0 ships them with a `:disabled`
  default and dedicated `:set_embedding_policy` / `:set_consolidation_policy`
  update actions; the resolver writes the defaults on initial create and the
  upsert path is restricted (via `upsert_fields([:updated_at])`) so user-
  tuned values are preserved across repeat resolver calls.
  """

  use Ash.Resource,
    otp_app: :jido_claw,
    domain: JidoClaw.Workspaces,
    data_layer: AshPostgres.DataLayer

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

  code_interface do
    define(:register, action: :register)
    define(:rename, action: :rename, args: [:name])
    define(:archive, action: :archive)
    define(:set_embedding_policy, action: :set_embedding_policy, args: [:embedding_policy])

    define(:set_consolidation_policy,
      action: :set_consolidation_policy,
      args: [:consolidation_policy]
    )

    define(:by_path, action: :by_path, args: [:tenant_id, :user_id, :path], get?: true)
    define(:for_user, action: :for_user, args: [:tenant_id, :user_id])
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
        :tenant_id,
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
        constraints: [one_of: [:default, :local_only, :disabled]]
      )

      change(set_attribute(:embedding_policy, arg(:embedding_policy)))
    end

    update :set_consolidation_policy do
      accept([])

      argument(:consolidation_policy, :atom,
        allow_nil?: false,
        constraints: [one_of: [:default, :local_only, :disabled]]
      )

      change(set_attribute(:consolidation_policy, arg(:consolidation_policy)))
    end

    read :by_path do
      get?(true)
      argument(:tenant_id, :string, allow_nil?: false)
      argument(:user_id, :uuid, allow_nil?: true)
      argument(:path, :string, allow_nil?: false)

      filter(
        expr(
          tenant_id == ^arg(:tenant_id) and path == ^arg(:path) and
            ((is_nil(user_id) and is_nil(^arg(:user_id))) or user_id == ^arg(:user_id))
        )
      )
    end

    read :for_user do
      argument(:tenant_id, :string, allow_nil?: false)
      argument(:user_id, :uuid, allow_nil?: false)
      filter(expr(tenant_id == ^arg(:tenant_id) and user_id == ^arg(:user_id)))
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
      constraints(one_of: [:default, :local_only, :disabled])
    end

    attribute :consolidation_policy, :atom do
      allow_nil?(false)
      public?(true)
      default(:disabled)
      constraints(one_of: [:default, :local_only, :disabled])
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
    belongs_to :user, JidoClaw.Accounts.User do
      define_attribute?(false)
      attribute_writable?(true)
    end

    belongs_to :project, JidoClaw.Projects.Project do
      define_attribute?(false)
      attribute_writable?(true)
    end
  end

  identities do
    identity(:unique_user_path_authed, [:tenant_id, :user_id, :path],
      where: expr(not is_nil(user_id))
    )

    identity(:unique_user_path_cli, [:tenant_id, :path], where: expr(is_nil(user_id)))
  end
end
