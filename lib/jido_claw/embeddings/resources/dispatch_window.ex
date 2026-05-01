defmodule JidoClaw.Embeddings.DispatchWindow do
  @moduledoc """
  Cluster-global Voyage rate-budget counter row.

  Composite primary key `(model, window_started_at)` — Voyage RPM/TPM
  is per-API-key, not per-tenant, so this resource carries NO
  `tenant_id`. The `JidoClaw.Embeddings.RatePacer` GenServer issues a
  conditional UPSERT against this table before each Voyage request:
  zero rows returned ⇒ rejection (counter unchanged), one row ⇒
  budget consumed.

  GC drops rows older than `:cluster_window_gc_after_seconds`
  (default 60).
  """

  use Ash.Resource,
    otp_app: :jido_claw,
    domain: JidoClaw.Embeddings.Domain,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("embedding_dispatch_window")
    repo(JidoClaw.Repo)
  end

  code_interface do
    define(:read_window, action: :read_window, args: [:model, :window_started_at])
  end

  actions do
    defaults([:read, :destroy])

    read :read_window do
      get?(true)
      argument(:model, :string, allow_nil?: false)
      argument(:window_started_at, :utc_datetime_usec, allow_nil?: false)

      filter(expr(model == ^arg(:model) and window_started_at == ^arg(:window_started_at)))
    end
  end

  attributes do
    attribute :model, :string do
      allow_nil?(false)
      public?(true)
      primary_key?(true)
      writable?(true)
    end

    attribute :window_started_at, :utc_datetime_usec do
      allow_nil?(false)
      public?(true)
      primary_key?(true)
      writable?(true)
    end

    attribute :request_count, :integer do
      allow_nil?(false)
      public?(true)
      default(0)
    end

    attribute :token_count, :integer do
      allow_nil?(false)
      public?(true)
      default(0)
    end

    timestamps()
  end
end
