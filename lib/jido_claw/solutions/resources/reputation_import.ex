defmodule JidoClaw.Solutions.ReputationImport do
  @moduledoc """
  Idempotency ledger for one-shot legacy `.jido/reputation.json` imports.

  Each row records a successful import keyed by
  `(tenant_id, source_sha256)`. The migration task
  `Mix.Tasks.Jidoclaw.Migrate.Solutions` consults the ledger before
  reading a JSON file: a hit means "already imported" and the file is
  skipped. The single bundled-PR cutover plan does NOT rely on this
  ledger to bound a re-import within one shot — but operators
  occasionally re-run the migration after the cutover to merge a
  long-running detached worktree, and the ledger keeps that idempotent.
  """

  use Ash.Resource,
    otp_app: :jido_claw,
    domain: JidoClaw.Solutions.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  # ReputationImport defines only `:record_import` and `:find_by_hash` —
  # no `:by_id_global`. Omit the bypass.
  policies do
    policy action_type([:create, :update, :destroy]) do
      authorize_if(JidoClaw.Authorization.Checks.ActorTenantMatches)
    end

    policy action_type(:read) do
      authorize_if(expr(tenant_id == ^actor(:tenant_id)))
    end
  end

  postgres do
    table("reputation_imports")
    repo(JidoClaw.Repo)
  end

  multitenancy do
    strategy(:attribute)
    attribute(:tenant_id)
    global?(false)
  end

  code_interface do
    define(:record_import, action: :record_import)
    define(:find_by_hash, action: :find_by_hash, args: [:source_sha256], get?: true)
  end

  actions do
    defaults([:read, :destroy])

    create :record_import do
      description("Record that a reputation.json file with this SHA-256 has been imported.")
      primary?(true)

      accept([
        :source_sha256,
        :source_path,
        :imported_at,
        :rows_imported,
        :metadata
      ])
    end

    read :find_by_hash do
      description("Look up an import ledger entry by source SHA-256.")
      get?(true)
      argument(:source_sha256, :string, allow_nil?: false)

      filter(expr(source_sha256 == ^arg(:source_sha256)))
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute :tenant_id, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :source_sha256, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :source_path, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :imported_at, :utc_datetime_usec do
      allow_nil?(false)
      public?(true)
    end

    attribute :rows_imported, :integer do
      allow_nil?(false)
      public?(true)
      default(0)
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
  end

  identities do
    identity(:unique_tenant_source, [:tenant_id, :source_sha256])
  end
end
