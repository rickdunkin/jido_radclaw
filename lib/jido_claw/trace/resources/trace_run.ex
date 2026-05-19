defmodule JidoClaw.Trace.Resources.TraceRun do
  @moduledoc """
  Durable per-trace record. One row per `trace_id`.

  Written by `JidoClaw.Trace.Persistence` on every event, idempotently
  upserted by `:trace_id`. The `last_seq` column is an ordering guard
  for parallel writers — `upsert_condition expr(incoming_last_seq >
  last_seq)` makes an older snapshot's UPSERT a no-op rather than an
  error, so out-of-order arrivals never clobber a newer terminal
  snapshot.

  Trace IDs are globally unique by construction (Ash.UUID fallback for
  unattributed events; `request_id` / `run_id` otherwise). The
  `unique_trace_id` identity is therefore `all_tenants?: true` so the
  index works across tenant boundaries and the `has_many :events`
  relationship loads cleanly regardless of tenant scope.
  """

  use Ash.Resource,
    otp_app: :jido_claw,
    domain: JidoClaw.Trace.Domain,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("trace_runs")
    repo(JidoClaw.Repo)

    custom_indexes do
      index([:request_id], where: "request_id IS NOT NULL")
      index([:run_id], where: "run_id IS NOT NULL")
      index([:agent_id], where: "agent_id IS NOT NULL")
      index([:tenant_id, :inserted_at])
    end
  end

  multitenancy do
    strategy(:attribute)
    attribute(:tenant_id)
    global?(true)
  end

  code_interface do
    define(:upsert_run, action: :upsert_run)
    define(:by_trace_id, action: :by_trace_id, args: [:trace_id])
    define(:by_request, action: :by_request, args: [:request_id])
    define(:recent, action: :recent)
    define(:read, action: :read)
  end

  actions do
    defaults([:read])

    create :upsert_run do
      description("Idempotent insert/update of a trace_run snapshot.")
      primary?(true)

      accept([
        :trace_id,
        :tenant_id,
        :request_id,
        :run_id,
        :agent_id,
        :status,
        :started_at_ms,
        :completed_at_ms,
        :summary
      ])

      argument(:incoming_last_seq, :integer, allow_nil?: false)

      change(set_attribute(:last_seq, arg(:incoming_last_seq)))

      upsert?(true)
      upsert_identity(:unique_trace_id)
      # Skip the upsert when the incoming snapshot is older than the
      # persisted one. Combined with `return_skipped_upsert? true`,
      # out-of-order events become a `:skipped_upsert` no-op rather
      # than overwriting the newer terminal state.
      upsert_condition(expr(^arg(:incoming_last_seq) > last_seq))

      upsert_fields([
        :status,
        :request_id,
        :run_id,
        :agent_id,
        :started_at_ms,
        :completed_at_ms,
        :summary,
        :last_seq
      ])

      return_skipped_upsert?(true)
    end

    read :by_trace_id do
      description("Look up a trace_run by trace_id (global, all tenants).")
      get?(true)
      argument(:trace_id, :string, allow_nil?: false)
      filter(expr(trace_id == ^arg(:trace_id)))
    end

    read :by_request do
      description("Look up a trace_run by request_id.")
      get?(true)
      argument(:request_id, :string, allow_nil?: false)
      filter(expr(request_id == ^arg(:request_id)))
    end

    read :recent do
      description("Paginated read over the most recent trace_runs.")
      pagination(keyset?: true, default_limit: 50, required?: false)
      prepare(build(sort: [inserted_at: :desc]))
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute :trace_id, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :tenant_id, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :request_id, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :run_id, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :agent_id, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :status, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :started_at_ms, :integer do
      allow_nil?(true)
      public?(true)
    end

    attribute :completed_at_ms, :integer do
      allow_nil?(true)
      public?(true)
    end

    attribute :summary, :map do
      allow_nil?(true)
      public?(true)
      default(%{})
    end

    # NOT NULL with a `0` default keeps the `incoming_last_seq >
    # last_seq` upsert_condition safe — comparing against NULL would
    # silently always be false.
    attribute :last_seq, :integer do
      allow_nil?(false)
      default(0)
      public?(true)
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  identities do
    identity(:unique_trace_id, [:trace_id], all_tenants?: true)
  end

  relationships do
    has_many :events, JidoClaw.Trace.Resources.TraceEvent do
      destination_attribute(:trace_id)
      source_attribute(:trace_id)
    end
  end
end
