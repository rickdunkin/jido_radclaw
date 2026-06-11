defmodule JidoClaw.Trace.Resources.TraceEvent do
  @moduledoc """
  Durable per-event record. One row per `%JidoClaw.Trace.Event{}`.

  Written by `JidoClaw.Trace.Persistence` on every event, idempotently
  upserted by `(trace_id, seq)`. `:append_event` configures
  `upsert_fields: []` so a duplicate re-emission is a no-op rather
  than rewriting an already-persisted row.

  `source`/`category`/`event`/`phase`/`status` are stored as **strings**
  (not constrained atoms or open `:atom`) so future trace categories
  do not require a migration. The in-memory `%Trace.Event{}` keeps
  atoms; the conversion happens at the persistence boundary.

  Globally-unique `(trace_id, seq)` identity (`all_tenants?: true`) so
  the index is portable across tenants — same reasoning as
  `JidoClaw.Trace.Resources.TraceRun`'s `unique_trace_id`.
  """

  use Ash.Resource,
    otp_app: :jido_claw,
    domain: JidoClaw.Trace.Domain,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("trace_events")
    repo(JidoClaw.Repo)

    custom_indexes do
      index([:trace_id, :seq])
      index([:request_id], where: "request_id IS NOT NULL")
      index([:run_id], where: "run_id IS NOT NULL")
    end
  end

  multitenancy do
    strategy(:attribute)
    attribute(:tenant_id)
    global?(true)
  end

  code_interface do
    define(:append_event, action: :append_event)
    define(:for_trace, action: :for_trace, args: [:trace_id])
    define(:read, action: :read)
    define(:sweep_delete, action: :sweep_delete)
  end

  actions do
    defaults([:read])

    create :append_event do
      description("Idempotent append of a trace event row.")
      primary?(true)

      accept([
        :tenant_id,
        :trace_id,
        :seq,
        :at_ms,
        :schema_version,
        :source,
        :category,
        :event,
        :phase,
        :name,
        :status,
        :duration_ms,
        :request_id,
        :run_id,
        :span_id,
        :parent_span_id,
        :measurements,
        :metadata
      ])

      upsert?(true)
      upsert_identity(:unique_trace_seq)
      # Events are immutable. An empty upsert_fields list means the
      # `(trace_id, seq)` collision is silently ignored — duplicate
      # emissions are safe.
      upsert_fields([])
      return_skipped_upsert?(true)
    end

    read :for_trace do
      description("List trace events for a trace_id, ordered by seq ascending.")
      argument(:trace_id, :string, allow_nil?: false)
      filter(expr(trace_id == ^arg(:trace_id)))
      prepare(build(sort: [seq: :asc]))
    end

    # Maintenance-only delete for the retention sweeper (see
    # `TraceRun.sweep_expired/1`). Named and private for the same reason as
    # TraceRun's: no authorizers here, so no generic `:destroy` default.
    destroy :sweep_delete do
      description("Retention-sweeper delete of an expired trace's events.")
      public?(false)
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute :tenant_id, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :trace_id, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :seq, :integer do
      allow_nil?(false)
      public?(true)
    end

    attribute :at_ms, :integer do
      allow_nil?(false)
      public?(true)
    end

    # Normalized-event contract version (mirrors `JidoClaw.Trace.Event`).
    # Nullable + default 1 so the additive migration is O(1) metadata-only
    # on a populated table and pre-migration rows coerce cleanly on read.
    attribute :schema_version, :integer do
      allow_nil?(true)
      default(1)
      public?(true)
    end

    attribute :source, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :category, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :event, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :phase, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :name, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :status, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :duration_ms, :integer do
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

    attribute :span_id, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :parent_span_id, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :measurements, :map do
      allow_nil?(true)
      public?(true)
      default(%{})
    end

    attribute :metadata, :map do
      allow_nil?(true)
      public?(true)
      default(%{})
    end

    create_timestamp(:inserted_at)
  end

  identities do
    identity(:unique_trace_seq, [:trace_id, :seq], all_tenants?: true)
  end
end
