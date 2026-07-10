defmodule JidoClaw.Cron.Job.FireClaimResult do
  @moduledoc """
  Normalizes the common two-column result of scheduled and interval fire claims.

  The generation/cadence predicates and SQL remain owned by each transition;
  only their byte-identical success, duplicate, and storage-result mapping is
  shared here.
  """

  @doc "Map a fire-claim SQL result back onto its Ash changeset record."
  @spec normalize(term(), Ash.Changeset.t()) :: {:ok, term()} | {:error, term()}
  def normalize(result, changeset) do
    case result do
      {:ok, %{num_rows: 1, rows: [[last_fire_at, updated_at]]}} ->
        {:ok, %{changeset.data | last_fire_at: last_fire_at, updated_at: updated_at}}

      {:ok, %{num_rows: 0}} ->
        {:error, :scheduled_fire_already_claimed}

      {:error, reason} ->
        {:error, reason}
    end
  end
end

defmodule JidoClaw.Cron.Job.ClaimScheduledFire do
  @moduledoc false
  use Ash.Resource.ManualUpdate

  alias Ash.Changeset
  alias JidoClaw.Cron.Job.FireClaimResult
  alias JidoClaw.Repo

  @sql """
  UPDATE cron_jobs
     SET last_fire_at = $1, updated_at = now()
   WHERE id = $2 AND tenant_id = $3
     AND (last_fire_at IS NULL OR last_fire_at <= $4)
     AND disabled_at IS NULL
     AND definition_token = $5::uuid
  RETURNING last_fire_at, updated_at
  """

  @impl Ash.Resource.ManualUpdate
  def update(changeset, _opts, context) do
    window = Changeset.get_argument(changeset, :window)
    cutoff = Changeset.get_argument(changeset, :prior_cutoff)
    definition_token = Changeset.get_argument(changeset, :definition_token)
    id = Ecto.UUID.dump!(changeset.data.id)
    tenant = to_string(context.tenant)

    @sql
    |> Repo.query([window, id, tenant, cutoff, Ecto.UUID.dump!(definition_token)])
    |> FireClaimResult.normalize(changeset)
  end
end

defmodule JidoClaw.Cron.Job.ClaimIntervalFire do
  @moduledoc false
  use Ash.Resource.ManualUpdate

  alias JidoClaw.Cron.Job.FireClaimResult
  alias JidoClaw.Repo

  # `statement_timestamp()` is evaluated by PostgreSQL, once for this
  # statement. A node-local wall clock therefore cannot stamp a future
  # `last_fire_at` or move the cadence cutoff. The row lock/recheck performed
  # by UPDATE leaves exactly one winner when two nodes race.
  @claim_sql """
  WITH claim_clock AS (
    SELECT statement_timestamp() AS db_now
  )
  UPDATE cron_jobs AS jobs
     SET last_fire_at = claim_clock.db_now,
         updated_at = claim_clock.db_now
    FROM claim_clock
   WHERE jobs.id = $1 AND jobs.tenant_id = $2
     AND (
       jobs.last_fire_at IS NULL OR
       jobs.last_fire_at <= claim_clock.db_now - ($3::bigint * INTERVAL '1 millisecond')
     )
     AND jobs.disabled_at IS NULL
     AND jobs.definition_token = $4::uuid
  RETURNING jobs.last_fire_at, jobs.updated_at
  """

  # A failed Ash update can mean a duplicate, a stale definition, or storage
  # failure. Re-evaluate only the claim predicates on the same DB clock before
  # the worker decides whether to advance or retry its local timer.
  @classify_sql """
  SELECT disabled_at IS NOT NULL OR definition_token <> $3::uuid,
         last_fire_at IS NOT NULL AND
           last_fire_at > statement_timestamp() - ($4::bigint * INTERVAL '1 millisecond')
    FROM cron_jobs
   WHERE id = $1 AND tenant_id = $2
  """

  @impl Ash.Resource.ManualUpdate
  def update(changeset, _opts, context) do
    interval_ms = Ash.Changeset.get_argument(changeset, :interval_ms)
    definition_token = Ash.Changeset.get_argument(changeset, :definition_token)
    id = Ecto.UUID.dump!(changeset.data.id)
    tenant = to_string(context.tenant)

    @claim_sql
    |> Repo.query([id, tenant, interval_ms, Ecto.UUID.dump!(definition_token)])
    |> FireClaimResult.normalize(changeset)
  end

  @doc false
  @spec classify_failure(Ecto.UUID.t(), String.t(), Ecto.UUID.t(), pos_integer()) ::
          :stale_definition | :duplicate | :retry
  def classify_failure(id, tenant, definition_token, interval_ms) do
    case Repo.query(@classify_sql, [
           Ecto.UUID.dump!(id),
           tenant,
           Ecto.UUID.dump!(definition_token),
           interval_ms
         ]) do
      {:ok, %{rows: [[true, _recent?]]}} -> :stale_definition
      {:ok, %{rows: [[false, true]]}} -> :duplicate
      _unavailable_or_due -> :retry
    end
  end
end

defmodule JidoClaw.Cron.Job.RecordOutcome do
  @moduledoc false
  use Ash.Resource.ManualUpdate

  alias JidoClaw.Repo

  @success_sql """
  UPDATE cron_jobs
     SET run_count = run_count + 1,
         last_run_at = now(),
         failure_count = 0,
         updated_at = now()
   WHERE id = $1 AND tenant_id = $2 AND definition_token = $3::uuid
  RETURNING run_count, last_run_at, failure_count, disabled_at, updated_at
  """

  @failure_sql """
  UPDATE cron_jobs
     SET run_count = run_count + 1,
         last_run_at = now(),
         failure_count = failure_count + 1,
         disabled_at = CASE
           WHEN failure_count + 1 >= 3 THEN COALESCE(disabled_at, now())
           ELSE disabled_at
         END,
         updated_at = now()
   WHERE id = $1 AND tenant_id = $2 AND definition_token = $3::uuid
  RETURNING run_count, last_run_at, failure_count, disabled_at, updated_at
  """

  @impl Ash.Resource.ManualUpdate
  def update(changeset, opts, context) do
    definition_token = Ash.Changeset.get_argument(changeset, :definition_token)
    id = Ecto.UUID.dump!(changeset.data.id)
    tenant = to_string(context.tenant)
    sql = if opts[:outcome] == :success, do: @success_sql, else: @failure_sql

    case Repo.query(sql, [id, tenant, Ecto.UUID.dump!(definition_token)]) do
      {:ok,
       %{
         num_rows: 1,
         rows: [[run_count, last_run_at, failure_count, disabled_at, updated_at]]
       }} ->
        {:ok,
         %{
           changeset.data
           | run_count: run_count,
             last_run_at: last_run_at,
             failure_count: failure_count,
             disabled_at: disabled_at,
             updated_at: updated_at
         }}

      {:ok, %{num_rows: 0}} ->
        {:error, :stale_cron_definition}

      {:error, reason} ->
        {:error, reason}
    end
  end
end

defmodule JidoClaw.Cron.Job.DisableGeneration do
  @moduledoc false
  use Ash.Resource.ManualUpdate

  alias JidoClaw.Repo

  @sql """
  UPDATE cron_jobs
     SET disabled_at = COALESCE(disabled_at, now()), updated_at = now()
   WHERE id = $1 AND tenant_id = $2 AND definition_token = $3::uuid
  RETURNING disabled_at, updated_at
  """

  @impl Ash.Resource.ManualUpdate
  def update(changeset, _opts, context) do
    definition_token = Ash.Changeset.get_argument(changeset, :definition_token)
    id = Ecto.UUID.dump!(changeset.data.id)
    tenant = to_string(context.tenant)

    case Repo.query(@sql, [id, tenant, Ecto.UUID.dump!(definition_token)]) do
      {:ok, %{num_rows: 1, rows: [[disabled_at, updated_at]]}} ->
        {:ok, %{changeset.data | disabled_at: disabled_at, updated_at: updated_at}}

      {:ok, %{num_rows: 0}} ->
        {:error, :stale_cron_definition}

      {:error, reason} ->
        {:error, reason}
    end
  end
end

defmodule JidoClaw.Cron.Job do
  @moduledoc """
  Persistent cron-job definition row.

  Replaces the legacy `.jido/cron.yaml` file-store. Identity is the
  composite `(tenant_id, job_id)` — `job_id` is user-supplied or
  generated by `Tools.ScheduleTask`'s id helper.

  `disabled_at` is set when the cron worker auto-disables a job
  after 3 consecutive failures. The `:for_tenant` read action
  filters to `is_nil(disabled_at)` so a restart re-loads only
  active rows; `:enable` clears the timestamp and rotates the
  definition-generation token so reconciliation replaces (re-arms)
  any still-alive disabled worker.

  `mode: :system_job` rows are config-driven in v0.6.4 and don't
  flow through this resource yet — kept on the schema for forward
  compatibility.

  `target` (`:agent | :workflow | :mfa`) is the execution-target
  dimension, orthogonal to `mode`. Dispatch is legacy-first:
  `Cron.Dispatcher` routes `mode: :system_job` to MFA *before*
  consulting `target`, so every pre-`target` row keeps working and
  new rows default to `target: :agent`. `:workflow` rows carry a
  `workflow_name` (a skill) and drive a tracked
  `JidoClaw.Orchestration.WorkflowRun`. `run_count`/`last_run_at`
  are system-managed durability counters stamped inside the fenced
  `record_success`/`record_failure` outcome writes. `failure_count` survives worker and
  leader restarts, while `last_fire_at` is the durable scheduled-window claim
  that fences split-brain agent/MFA/workflow dispatch. `:every` claims derive
  their cutoff and stored timestamp from PostgreSQL's statement clock; caller
  wall-clock skew is never durable state.

  `timezone` (IANA name, default `"Etc/UTC"`) is the wall-clock zone a
  `:cron` expression is read in — `"0 9 * * *"` with `"America/New_York"`
  fires at 09:00 local. It is inert for `:every` / `:at` schedules.
  """

  use JidoClaw.Resource, domain: JidoClaw.Cron

  @modes [:main, :isolated, :system_job]
  @targets [:agent, :workflow, :mfa]
  @schedule_kinds [:cron, :every, :at]

  postgres do
    table("cron_jobs")
    repo(JidoClaw.Repo)

    custom_indexes do
      index([:tenant_id, :disabled_at])
    end
  end

  multitenancy do
    strategy(:attribute)
    attribute(:tenant_id)
    global?(false)
  end

  code_interface do
    define(:upsert, action: :upsert)
    define(:by_id, action: :by_id, args: [:id], get?: true)
    define(:by_job_id, action: :by_job_id, args: [:job_id], get?: true)
    define(:by_id_global, action: :by_id_global, args: [:id], get?: true)
    define(:remove, action: :remove)
    define(:disable, action: :disable)
    define(:disable_generation, action: :disable_generation, args: [:definition_token])
    define(:enable, action: :enable)
    define(:record_success, action: :record_success, args: [:definition_token])
    define(:record_failure, action: :record_failure, args: [:definition_token])

    define(:claim_scheduled_fire,
      action: :claim_scheduled_fire,
      args: [:window, :prior_cutoff, :definition_token]
    )

    define(:claim_interval_fire,
      action: :claim_interval_fire,
      args: [:interval_ms, :definition_token]
    )

    define(:for_tenant, action: :for_tenant)
    define(:for_tenant_all, action: :for_tenant_all)
  end

  actions do
    defaults([:read, :destroy])

    create :upsert do
      primary?(true)
      upsert?(true)
      upsert_identity(:unique_job)

      # On conflict the SET-list is this whitelist ∩ attributes actually set on
      # the changeset (ash_postgres `upsert_set/4`) — and static attribute
      # defaults ARE set on create changesets, so a whitelisted defaulted field
      # (e.g. metadata, default %{}) resets to its default when a caller omits
      # it. Only a whitelisted field with NO default that a caller never sets is
      # preserved on conflict. Contract-less writers (/cron add, the migrate
      # task) still pass `metadata: %{}` explicitly rather than riding that
      # default-application subtlety.
      upsert_fields([
        :task,
        :mode,
        :target,
        :workflow_name,
        :workflow_input,
        :schedule_kind,
        :schedule_value,
        :timezone,
        :mfa_module,
        :mfa_function,
        :mfa_args,
        :metadata,
        :definition_token,
        :failure_count,
        # Clearing disabled_at on conflict is what makes re-scheduling an existing
        # job_id re-enable a previously auto-disabled row (WS4a source-of-truth
        # model). disabled_at has no default, so it needs BOTH this whitelist
        # entry AND the `set_attribute(:disabled_at, nil)` change below to be
        # written on conflict.
        :disabled_at,
        :updated_at
      ])

      accept([
        :job_id,
        :task,
        :mode,
        :target,
        :workflow_name,
        :workflow_input,
        :schedule_kind,
        :schedule_value,
        :timezone,
        :mfa_module,
        :mfa_function,
        :mfa_args,
        :metadata
      ])

      # (Re)scheduling a job_id clears any auto-disable so the Owner reloads it —
      # otherwise `for_tenant` (is_nil(disabled_at)) keeps filtering it out. Paired
      # with `:disabled_at` in upsert_fields so the cleared value is written on
      # conflict, not just on insert.
      change(set_attribute(:disabled_at, nil))
      # Every definition write rotates the generation token. A worker carries
      # the token it was hydrated from and the scheduled-fire SQL requires an
      # exact match, so a stale process can never dispatch an old task after an
      # upsert changes the row.
      change(set_attribute(:definition_token, &Ash.UUID.generate/0))
      change(set_attribute(:failure_count, 0))

      # Defense in depth: a bad row can't silently always-fail at dispatch.
      # `where:` ANDs its conditions, so the MFA requirement is two separate
      # statements (target == :mfa OR mode == :system_job) to get OR semantics.
      validate(present(:workflow_name), where: [attribute_equals(:target, :workflow)])
      validate(present([:mfa_module, :mfa_function]), where: [attribute_equals(:target, :mfa)])

      validate(present([:mfa_module, :mfa_function]),
        where: [attribute_equals(:mode, :system_job)]
      )
    end

    update :disable do
      accept([])
      change(set_attribute(:disabled_at, &DateTime.utc_now/0))
    end

    # Worker-originated disable (one-shot completion, elapsed/invalid schedule)
    # is fenced to the definition generation it was hydrated from. The public
    # operator `:disable` action above remains unconditional by row identity.
    update :disable_generation do
      accept([])
      argument(:definition_token, :uuid, allow_nil?: false)
      manual(JidoClaw.Cron.Job.DisableGeneration)
    end

    update :enable do
      accept([])
      change(set_attribute(:disabled_at, nil))
      # Every definition write rotates the generation token — enable included.
      # An auto-disabled worker stays ALIVE (status: :disabled) and reconcile
      # compares only the definition fingerprint, so without rotation an
      # enable lands as an identical fingerprint and the dead worker is
      # retained, never re-armed. Rotation makes `Scheduler.changed?/2` see a
      # new fingerprint so the worker is REPLACED (fresh armed generation),
      # never resumed in-place; a stale copy's claims/outcome writes fence out
      # via the existing `WHERE definition_token = $N` machinery
      # (`stale_cron_definition` → retire). Scheduled-fire risk across the
      # swap is nil (a disabled worker's status guard swallows scheduled
      # ticks, and a stale generation cannot win the durable claim), but a
      # manual `trigger` already queued or racing this enable is an accepted
      # operator-initiated residual: `trigger/2` bypasses worker status and
      # the durable fire claim, so its side effect may execute once — the
      # rotated token fences only its persisted outcome write, not the
      # execution itself.
      change(set_attribute(:definition_token, &Ash.UUID.generate/0))
      change(set_attribute(:failure_count, 0))
    end

    # Durable wall-clock scheduled-window claim. The filter is part of the
    # UPDATE, not an in-memory validation: two leaders racing one row can never
    # both win. Cron/:at pass `window - 1us`, rejecting the exact shared window
    # and all stale predecessors. `:every` uses the DB-clock action below.
    update :claim_scheduled_fire do
      accept([])
      argument(:window, :utc_datetime_usec, allow_nil?: false)
      argument(:prior_cutoff, :utc_datetime_usec, allow_nil?: false)
      argument(:definition_token, :uuid, allow_nil?: false)
      manual(JidoClaw.Cron.Job.ClaimScheduledFire)
    end

    # Recurring interval claims never accept a caller timestamp. PostgreSQL's
    # statement clock supplies both the cadence cutoff and the stored fire time,
    # so skewed nodes cannot move the durable window or both win it.
    update :claim_interval_fire do
      accept([])
      argument(:interval_ms, :integer, allow_nil?: false, constraints: [min: 1])
      argument(:definition_token, :uuid, allow_nil?: false)
      manual(JidoClaw.Cron.Job.ClaimIntervalFire)
    end

    # Outcome persistence is one atomic row update. A worker only disables
    # locally after `record_failure` returns a row with `disabled_at`, so a DB
    # error can never create an enabled row with a permanently-idle worker.
    update :record_success do
      accept([])
      argument(:definition_token, :uuid, allow_nil?: false)
      manual({JidoClaw.Cron.Job.RecordOutcome, outcome: :success})
    end

    update :record_failure do
      accept([])
      argument(:definition_token, :uuid, allow_nil?: false)
      manual({JidoClaw.Cron.Job.RecordOutcome, outcome: :failure})
    end

    destroy :remove do
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

    read :by_job_id do
      get?(true)
      argument(:job_id, :string, allow_nil?: false)
      filter(expr(job_id == ^arg(:job_id)))
    end

    read :for_tenant do
      filter(expr(is_nil(disabled_at)))
      prepare(build(sort: [inserted_at: :asc]))
    end

    # Like :for_tenant but WITHOUT the disabled filter — the read for list views
    # (CLI /cron, list_scheduled_tasks) so a disabled job still shows (with its
    # disabled state) rather than vanishing. The Owner's desired-state read stays
    # :for_tenant (non-disabled only).
    read :for_tenant_all do
      prepare(build(sort: [inserted_at: :asc]))
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute :tenant_id, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :job_id, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :task, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :mode, :atom do
      allow_nil?(false)
      public?(true)
      default(:main)
      constraints(one_of: @modes)
    end

    attribute :target, :atom do
      allow_nil?(false)
      public?(true)
      default(:agent)
      constraints(one_of: @targets)
    end

    attribute :workflow_name, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :workflow_input, :map do
      allow_nil?(true)
      public?(true)
      default(%{})
    end

    attribute :schedule_kind, :atom do
      allow_nil?(false)
      public?(true)
      constraints(one_of: @schedule_kinds)
    end

    attribute :schedule_value, :string do
      allow_nil?(false)
      public?(true)
    end

    # IANA wall-clock zone for interpreting :cron expressions. Only the :cron
    # kind reads it (`JidoClaw.Cron.NextRun`); :every / :at are tz-inert.
    # Default "Etc/UTC" keeps pre-timezone rows firing exactly as before.
    attribute :timezone, :string do
      allow_nil?(false)
      public?(true)
      default("Etc/UTC")
    end

    attribute :mfa_module, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :mfa_function, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :mfa_args, :map do
      allow_nil?(true)
      public?(true)
      default(%{})
    end

    attribute :disabled_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
    end

    attribute :run_count, :integer do
      allow_nil?(false)
      public?(true)
      default(0)
    end

    attribute :last_run_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
    end

    attribute :failure_count, :integer do
      allow_nil?(false)
      public?(true)
      default(0)
      constraints(min: 0)
    end

    attribute :last_fire_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
    end

    attribute :definition_token, :uuid do
      allow_nil?(false)
      public?(true)
      default(&Ash.UUID.generate/0)
    end

    attribute :metadata, :map do
      allow_nil?(false)
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
    identity(:unique_job, [:tenant_id, :job_id])
  end
end
