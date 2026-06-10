defmodule JidoClaw.Tenants.Tenant do
  @moduledoc """
  Tenant registry row.

  Mirrors the legacy `JidoClaw.Tenant` struct: id, name, status, config,
  archived_at, timestamps. The id column is a string (e.g.
  `"tenant_<base64>"` or the `"default"` / `"system"` reserved names),
  not a UUID — every Phase 0–3 tenant_id text column is promoted to a FK
  pointing at this row, and changing the type now would require a
  cascading rewrite across 14+ tables.

  ## Idempotent ensure

  `register/1` is declared with `upsert? true` and
  `upsert_fields([:updated_at])`. Omitting `upsert_identity` defaults
  to the primary key, so a duplicate-id insert collapses onto the
  existing row and only `updated_at` is touched. `status`, `name`,
  `config`, and `archived_at` survive — a `:suspended` tenant isn't
  reactivated by a routine resolver-layer `ensure/1` call.

  ## No destroy

  Audit.Event rows (Step 2) FK at this row, and a hard delete would
  orphan history. Use `:archive` for soft-disable.
  """

  use Ash.Resource,
    otp_app: :jido_claw,
    domain: JidoClaw.Tenants,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @statuses [:active, :suspended, :terminating]

  # Tenant resource is itself untenanted; admin scoping for
  # archive/suspend is deferred to v0.7+.
  policies do
    policy action_type([:read, :create, :update, :destroy]) do
      authorize_if(always())
    end
  end

  postgres do
    table("tenants")
    repo(JidoClaw.Repo)
  end

  code_interface do
    define(:register, action: :register)
    define(:suspend, action: :suspend)
    define(:resume, action: :resume)
    define(:archive, action: :archive)
    define(:by_id, action: :by_id, args: [:id], get?: true)
    define(:list, action: :list)
    define(:read, action: :read)
  end

  actions do
    defaults([:read])

    create :register do
      description("Idempotently register a tenant row, refreshing updated_at on conflict.")
      primary?(true)
      upsert?(true)
      upsert_fields([:updated_at])

      accept([:id, :name, :status, :config])
    end

    update :suspend do
      description("Suspend a tenant, blocking further activity.")
      accept([])
      change(set_attribute(:status, :suspended))
    end

    update :resume do
      description("Return a suspended tenant to active status.")
      primary?(true)
      accept([])
      change(set_attribute(:status, :active))
    end

    update :archive do
      description("Soft-disable a tenant by marking it terminating and stamping archived_at.")
      accept([])
      change(set_attribute(:status, :terminating))
      change(set_attribute(:archived_at, &DateTime.utc_now/0))
    end

    read :by_id do
      description("Fetch a single tenant row by its string id.")
      get?(true)
      argument(:id, :string, allow_nil?: false)
      filter(expr(id == ^arg(:id)))
    end

    read :list do
      description("List all tenants in insertion order.")
      prepare(build(sort: [inserted_at: :asc]))
    end
  end

  attributes do
    attribute :id, :string do
      primary_key?(true)
      allow_nil?(false)
      public?(true)
      default(&__MODULE__.generate_id/0)
    end

    attribute :name, :string do
      allow_nil?(false)
      public?(true)
      default("default")
    end

    attribute :status, :atom do
      allow_nil?(false)
      public?(true)
      default(:active)
      constraints(one_of: @statuses)
    end

    attribute :config, :map do
      allow_nil?(false)
      public?(true)
      default(%{})
    end

    attribute :archived_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
    end

    timestamps()
  end

  @doc """
  Idempotently ensure a tenant row exists for `id`. Returns the row.
  Used by resolvers (Workspaces.Resolver) before any FK-bearing write
  so the parent row is in place. Concurrent first-writes for the same
  id collapse onto the same row via the primary-key default upsert
  semantics.
  """
  @spec ensure(String.t()) :: {:ok, t()} | {:error, term()}
  def ensure(id) when is_binary(id) do
    register(%{id: id, name: id, status: :active})
  end

  @doc false
  @spec generate_id() :: String.t()
  def generate_id do
    "tenant_" <> Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)
  end
end
