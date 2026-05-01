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
    data_layer: AshPostgres.DataLayer

  postgres do
    table("reputation_imports")
    repo(JidoClaw.Repo)
  end

  code_interface do
    define(:record_import, action: :record_import)
    define(:find_by_hash, action: :find_by_hash, args: [:tenant_id, :source_sha256], get?: true)
  end

  actions do
    defaults([:read, :destroy])

    create :record_import do
      primary?(true)

      accept([
        :tenant_id,
        :source_sha256,
        :source_path,
        :imported_at,
        :rows_imported,
        :metadata
      ])
    end

    read :find_by_hash do
      get?(true)
      argument(:tenant_id, :string, allow_nil?: false)
      argument(:source_sha256, :string, allow_nil?: false)

      filter(expr(tenant_id == ^arg(:tenant_id) and source_sha256 == ^arg(:source_sha256)))
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

  identities do
    identity(:unique_tenant_source, [:tenant_id, :source_sha256])
  end
end
