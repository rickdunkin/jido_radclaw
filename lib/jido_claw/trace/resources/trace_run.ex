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

  require Ash.Query
  require Logger

  alias JidoClaw.Repo
  alias JidoClaw.Trace.Resources.TraceEvent

  @sweep_batch 1_000

  postgres do
    table("trace_runs")
    repo(JidoClaw.Repo)

    custom_indexes do
      index([:request_id], where: "request_id IS NOT NULL")
      index([:run_id], where: "run_id IS NOT NULL")
      index([:agent_id], where: "agent_id IS NOT NULL")
      index([:tenant_id, :inserted_at])
      # Serves the retention sweeper's tenantless `updated_at < ?` scan —
      # all_tenants?: true, or AshPostgres would prepend tenant_id and the
      # cross-tenant read couldn't use it (RequestCorrelation precedent).
      index([:updated_at], all_tenants?: true)
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
    define(:expired, action: :expired, args: [:cutoff])
    define(:sweep_delete, action: :sweep_delete)
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

    read :expired do
      description("List trace_runs whose last activity predates the cutoff.")
      argument(:cutoff, :utc_datetime_usec, allow_nil?: false)
      filter(expr(updated_at < ^arg(:cutoff)))
      prepare(build(sort: [updated_at: :asc]))
    end

    # Maintenance-only delete for the retention sweeper. A NAMED private
    # destroy rather than a generic `:destroy` in `defaults` — this resource
    # has no authorizers, so the action surface stays deliberately narrow.
    destroy :sweep_delete do
      description("Retention-sweeper delete of an expired trace_run.")
      public?(false)
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

  @doc false
  # Public for the lock-pin regression test; not part of the resource's API.
  @spec expired_batch_query(DateTime.t()) :: Ash.Query.t()
  def expired_batch_query(%DateTime{} = cutoff) do
    cutoff
    |> __MODULE__.query_to_expired()
    |> Ash.Query.limit(@sweep_batch)
    # Exact upper-case string: ash_postgres validates the lock
    # case-insensitively but generates SQL by clause-matching the literal;
    # the :for_update atom form emits no SKIP LOCKED at all.
    |> Ash.Query.lock("FOR UPDATE SKIP LOCKED")
  end

  @doc """
  Delete at most #{@sweep_batch} trace_runs whose `updated_at` predates
  `cutoff`, together with their `trace_events`. Returns
  `{:ok, deleted_runs, more?}`; called by `JidoClaw.Trace.RetentionSweeper`.

  `updated_at` is the retention key: `Trace.Persistence` upserts the run row
  on every event (each carries a higher `incoming_last_seq`, so the upsert
  condition passes and AshPostgres refreshes the update timestamp), so a
  long-lived active trace stays fresh and survives.

  The whole batch — selecting read plus both deletes (events first, then
  runs; there is no FK between the tables, `has_many :events` is a logical
  join on the `trace_id` string) — runs in ONE `Repo.transaction`, with
  `FOR UPDATE SKIP LOCKED` on the selection. That closes the TOCTOU where a
  trace revives mid-sweep: a fresh Persistence upsert either bumps
  `updated_at` before the lock (the `FOR UPDATE` predicate re-check drops
  the row from the batch), is in flight (SKIP LOCKED skips the row), or
  arrives after the sweeper holds the lock — then it parks on the row lock
  and, once the sweep commits the delete, inserts a brand-new run row, so
  the revived trace re-materializes as a consistent run+event pair.
  SKIP LOCKED also lets concurrent sweepers (one per node in cluster mode)
  partition batches instead of colliding. Any failure rolls the whole batch
  back — all-or-nothing, retried wholesale on the next tick.

  Residual (accepted): a SKIPPED upsert (stale out-of-order re-emission,
  `incoming_last_seq <= last_seq`) commits without bumping `updated_at`, and
  its follow-up event INSERT never touches the run row, so it can land while
  the sweeper holds the lock and strand that one stale event row. Bounded
  and benign; closing it would need a transaction-wrapped
  `Trace.Persistence.do_persist/2`. Together with out-of-band deletes this
  is why orphan events (run row missing) stay deliberately unswept.

  `more?` is true ONLY when a full batch was cleanly deleted — a
  repeatedly-failing full batch waits for the next hourly tick rather than
  hot-looping the sweeper's immediate-drain re-send.
  """
  @spec sweep_expired(DateTime.t()) :: {:ok, non_neg_integer(), boolean()}
  def sweep_expired(%DateTime{} = cutoff) do
    result =
      Repo.transaction(fn ->
        case Ash.read(expired_batch_query(cutoff)) do
          {:ok, []} -> {0, false}
          {:ok, batch} -> sweep_events_then_runs(batch)
          {:error, reason} -> Repo.rollback({:sweep_read, reason})
        end
      end)

    case result do
      {:ok, {deleted, more?}} ->
        {:ok, deleted, more?}

      {:error, reason} ->
        Logger.warning("[TraceRun] retention sweep rolled back: #{inspect(reason)}")
        {:ok, 0, false}
    end
  end

  # The code-interface calls with a query/list dispatch to `Ash.bulk_destroy`,
  # whose default `transaction: :batch` joins the outer sweep transaction as a
  # savepoint (and `max_concurrency: 0` keeps it on this connection). Any
  # non-success aborts the whole batch via `Repo.rollback`.
  defp sweep_events_then_runs(batch) do
    trace_ids = Enum.map(batch, & &1.trace_id)
    events_query = Ash.Query.filter(TraceEvent, trace_id in ^trace_ids)

    case TraceEvent.sweep_delete(events_query, bulk_options: [return_errors?: true]) do
      %Ash.BulkResult{status: :success} ->
        destroy_runs(batch)

      %Ash.BulkResult{status: status, error_count: errors}
      when status in [:partial_success, :error] ->
        Repo.rollback({:sweep_event_delete, status, errors})
    end
  end

  # Count from the batch, not `BulkResult.records` — with the default
  # `return_records?: false` that field is nil.
  defp destroy_runs(batch) do
    case __MODULE__.sweep_delete(batch, bulk_options: [return_errors?: true]) do
      %Ash.BulkResult{status: :success} ->
        {length(batch), length(batch) == @sweep_batch}

      %Ash.BulkResult{status: status, error_count: errors}
      when status in [:partial_success, :error] ->
        Repo.rollback({:sweep_run_delete, status, errors})
    end
  end
end
