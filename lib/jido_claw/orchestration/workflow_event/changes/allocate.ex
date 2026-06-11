defmodule JidoClaw.Orchestration.WorkflowEvent.Changes.Allocate do
  @moduledoc """
  The `WorkflowEvent.:append` change — sole `seq` allocator, payload
  redactor, and (for status-authority kinds) the materialized
  `WorkflowRun.status` writer. Runs entirely inside the `:append` action's
  transaction.

  ## Tenant & actor threading

  Every internal read/update threads `tenant: changeset.tenant` (the tenant
  the append was called with, which equals the event's `tenant_id`) plus the
  appending caller's actor, falling back to a tenant-bound system actor when
  the caller supplied none. Any actor that reached `:append` already passed
  the event's own `ActorTenantMatches` create policy for this tenant, so the
  internal reads/writes authorize identically; the multitenancy *filter*
  still comes solely from `tenant:`.

  ## before_action

    1. Lock + read the parent run (`FOR UPDATE`) so concurrent appends for
       one run serialize. A missing run (or a tenant mismatch the filter
       drops) becomes a clean changeset error, not a crash on `nil`.
    2. Stash `run.status` and the **raw** payload (size-capped per leaf, but
       *not* redacted) in changeset context for the after_action.
    3. Allocate `seq = max(existing) + 1` (after the lock) and redact-then-cap
       the persisted `payload`/`metadata` — redaction always sees the full
       original (capping first could cut a secret below the redaction regex's
       match threshold). The unique `(workflow_run_id, seq)` index is the
       backstop. The cap (`:workflow_event_payload_max_bytes`, default 64 KB)
       is per-leaf, not a whole-payload budget.

  ## after_action (status-authority kinds only)

    1. Transition guard via `Projection.next_status/2`; an `:illegal`
       transition returns `{:error, …}` so the whole append rolls back —
       the event is NOT persisted and status is unchanged.
    2. Update the run via its private `:set_status` action, sourcing
       `occurred_at` from the created event and `result`/`error` from the
       raw stashed payload, in the same transaction.

  ## after_action (step kinds only) — best-effort step projection

  `step_started`/`step_completed`/`step_failed` additionally upsert the
  per-step `WorkflowStep` read-model row (identity `(workflow_run_id, name)`),
  in the same transaction so rows ride the per-run `FOR UPDATE` lock. Unlike
  the status projection this **never rolls back the append**: the write is
  deterministic-safe by construction (identity upsert — no unique-violation
  class; parent-run FK held under the lock) and wrapped in an explicit
  savepoint, because a surprise SQL error would otherwise poison the whole
  append transaction. Failures log and are repairable by replaying the run's
  `step_*` events.
  """

  use Ash.Resource.Change

  require Ash.Query, as: Query
  require Logger

  alias Ash.Changeset
  alias Ash.Error.Changes.InvalidChanges
  alias JidoClaw.Authorization.Actor
  alias JidoClaw.Orchestration.WorkflowEvent
  alias JidoClaw.Orchestration.WorkflowEvent.Projection
  alias JidoClaw.Orchestration.WorkflowRun
  alias JidoClaw.Orchestration.WorkflowStep
  alias JidoClaw.Repo
  alias JidoClaw.Security.Redaction.Transcript
  alias JidoClaw.Tools.OutputLimit

  @default_payload_leaf_cap 65_536

  # The kinds that project a WorkflowStep row. `step_retried` deliberately
  # does NOT write (the retry's own `step_started` resets the row);
  # `step_compensated`/`step_undone` are saga provenance, not row status.
  @step_projection_kinds [:step_started, :step_completed, :step_failed]

  # SAVEPOINT names cannot be bound as SQL parameters, and the name is a
  # compile-time constant — so the three statements are pre-built here, and
  # the `Repo.query` call sites take literal strings (no runtime
  # interpolation).
  @savepoint "workflow_step_projection"
  @savepoint_sql "SAVEPOINT #{@savepoint}"
  @release_savepoint_sql "RELEASE SAVEPOINT #{@savepoint}"
  @rollback_savepoint_sql "ROLLBACK TO SAVEPOINT #{@savepoint}"

  @impl Ash.Resource.Change
  def change(changeset, _opts, context) do
    caller_actor = context.actor

    changeset
    |> Changeset.before_action(&allocate(&1, effective_actor(&1, caller_actor)))
    |> Changeset.after_action(&maybe_update_status(&1, &2, effective_actor(&1, caller_actor)))
    |> Changeset.after_action(&maybe_project_step(&1, &2, effective_actor(&1, caller_actor)))
  end

  # Preserve the real caller for the internal reads/writes; a tenant-bound
  # system actor only covers actor-less internal callers.
  defp effective_actor(changeset, caller_actor),
    do: caller_actor || Actor.system(changeset.tenant)

  defp allocate(changeset, actor) do
    run_id = Changeset.get_attribute(changeset, :workflow_run_id)
    tenant = changeset.tenant

    case lock_run(run_id, tenant, actor) do
      {:ok, run} ->
        raw_payload = Changeset.get_attribute(changeset, :payload) || %{}
        raw_metadata = Changeset.get_attribute(changeset, :metadata) || %{}

        # Capped raw → context stash (bounds WorkflowRun.result /
        # WorkflowStep.output, which store raw by design — size-only,
        # no redaction). Redact-the-ORIGINAL-then-cap → persisted columns:
        # truncating first could cut a long secret below the redaction
        # regex's match threshold and persist an unredacted partial secret.
        # This is a per-leaf bound, NOT a whole-payload budget — many
        # under-cap leaves can still grow; current payload shapes are
        # single-large-LLM-text leaves.
        changeset
        |> Changeset.set_context(%{
          workflow_event: %{current_status: run.status, raw_payload: capped(raw_payload)}
        })
        |> Changeset.force_change_attribute(:seq, next_seq(run_id, tenant, actor))
        |> Changeset.force_change_attribute(:payload, capped(Transcript.redact(raw_payload)))
        |> Changeset.force_change_attribute(:metadata, capped(Transcript.redact(raw_metadata)))

      :error ->
        Changeset.add_error(changeset,
          field: :workflow_run_id,
          message: "workflow run not found for tenant"
        )
    end
  end

  # FOR UPDATE on the parent run row is the per-run serialization point:
  # concurrent appends for one run block here until the prior append commits,
  # so seq allocation is gap-free and strictly increasing in commit order.
  defp lock_run(run_id, tenant, actor) do
    WorkflowRun
    |> Query.filter(id == ^run_id)
    |> Query.lock("FOR UPDATE")
    |> Ash.read_one(tenant: tenant, actor: actor)
    |> case do
      {:ok, %WorkflowRun{} = run} -> {:ok, run}
      _ -> :error
    end
  end

  defp next_seq(run_id, tenant, actor) do
    WorkflowEvent
    |> Query.filter(workflow_run_id == ^run_id)
    |> Query.sort(seq: :desc)
    |> Query.limit(1)
    |> Ash.read_one(tenant: tenant, actor: actor)
    |> case do
      {:ok, %WorkflowEvent{seq: seq}} -> seq + 1
      _ -> 1
    end
  end

  defp maybe_update_status(changeset, event, actor) do
    if Projection.status_authority?(event.kind) do
      %{current_status: current_status, raw_payload: raw_payload} =
        changeset.context[:workflow_event]

      update_status(event, current_status, raw_payload, changeset.tenant, actor)
    else
      {:ok, event}
    end
  end

  defp update_status(event, current_status, raw_payload, tenant, actor) do
    case Projection.next_status(current_status, event.kind) do
      {:ok, _new_status} ->
        attrs = Projection.status_attrs(event.kind, raw_payload, event.occurred_at)
        apply_status(event, attrs, tenant, actor)

      :illegal ->
        {:error,
         InvalidChanges.exception(
           fields: [:kind],
           message: "illegal status transition: #{event.kind} from #{inspect(current_status)}"
         )}
    end
  end

  defp apply_status(event, attrs, tenant, actor) do
    with {:ok, run} <- load_run(event.workflow_run_id, tenant, actor),
         {:ok, _updated} <-
           run
           |> Changeset.for_update(:set_status, attrs, tenant: tenant, actor: actor)
           |> Ash.update() do
      {:ok, event}
    else
      :error -> {:error, "workflow run vanished during status update"}
      {:error, reason} -> {:error, reason}
    end
  end

  # Re-read within the held FOR UPDATE lock (same transaction) for the
  # status update; cheap and avoids stashing a struct through context.
  defp load_run(run_id, tenant, actor) do
    WorkflowRun
    |> Query.filter(id == ^run_id)
    |> Ash.read_one(tenant: tenant, actor: actor)
    |> case do
      {:ok, %WorkflowRun{} = run} -> {:ok, run}
      _ -> :error
    end
  end

  # ---------------------------------------------------------------------------
  # WorkflowStep projection (read-model, best-effort)
  # ---------------------------------------------------------------------------

  # Always `{:ok, event}` — the step row is a read model; only the status
  # projection keeps rollback-on-error semantics.
  defp maybe_project_step(changeset, event, actor) do
    if event.kind in @step_projection_kinds do
      project_step(changeset, event, actor)
    end

    {:ok, event}
  end

  # Projects from the RAW stashed payload (atom keys; the persisted event
  # payload is redacted), tolerating string keys for foreign producers. A
  # payload with no usable identity (`name` nor `step`) is skipped — there is
  # nothing to key the row on.
  defp project_step(changeset, event, actor) do
    raw_payload =
      case changeset.context[:workflow_event] do
        %{raw_payload: payload} when is_map(payload) -> payload
        _ -> %{}
      end

    case step_name(raw_payload) do
      nil ->
        :ok

      name ->
        attrs = step_attrs(event, name, raw_payload)
        upsert_step(event, step_action(event.kind), attrs, changeset.tenant, actor)
    end
  end

  defp step_action(:step_started), do: :record_started
  defp step_action(:step_completed), do: :record_completed
  defp step_action(:step_failed), do: :record_failed

  # The human YAML name when the middleware threaded one; the positional
  # Reactor id (`":step_1"`) as the documented fallback identity.
  defp step_name(payload) do
    case fetch(payload, :name) do
      name when is_binary(name) and name != "" -> name
      _ -> fallback_step_name(payload)
    end
  end

  defp fallback_step_name(payload) do
    case fetch(payload, :step) do
      step when is_binary(step) and step != "" -> step
      _ -> nil
    end
  end

  # Static step metadata (`step_type`/`sequence`/`deadline`/`depends_on`)
  # projects on EVERY step kind, not just `step_started` — a row can be
  # created by a completed/failed event when the started event was missed,
  # and the metadata must survive that path. Re-writing the same static value
  # per event is safe.
  defp step_attrs(event, name, payload) do
    %{name: name, workflow_run_id: event.workflow_run_id}
    |> put_valid(:step_type, fetch(payload, :step_type), &is_binary/1)
    |> put_valid(:sequence, parse_sequence(fetch(payload, :step)), &is_integer/1)
    |> put_valid(:deadline, fetch(payload, :deadline), &valid_policy_map?/1)
    |> put_valid(:depends_on, fetch(payload, :depends_on), &binary_list?/1)
    |> Map.merge(kind_attrs(event, payload))
  end

  defp valid_policy_map?(value), do: is_map(value) and not is_struct(value)

  defp binary_list?(value), do: is_list(value) and Enum.all?(value, &is_binary/1)

  defp kind_attrs(%{kind: :step_started} = event, _payload),
    do: %{started_at: event.occurred_at}

  defp kind_attrs(%{kind: :step_completed} = event, payload) do
    put_valid(
      %{completed_at: event.occurred_at},
      :output,
      fetch(payload, :output),
      &(is_map(&1) and not is_struct(&1))
    )
  end

  defp kind_attrs(%{kind: :step_failed} = event, payload) do
    put_valid(%{completed_at: event.occurred_at}, :error, fetch(payload, :error), &is_binary/1)
  end

  # `":step_N"` (the inspect'd positional id) -> N; anything else has no
  # derivable sequence and keeps the column default.
  defp parse_sequence(":step_" <> rest) do
    case Integer.parse(rest) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp parse_sequence(_), do: nil

  # The savepoint fence: a surprise SQL error inside the upsert would poison
  # the append transaction (aborted until rollback), so the attempt is bracketed
  # by SAVEPOINT/ROLLBACK TO SAVEPOINT on the same connection. A failure to even
  # create the savepoint skips the projection entirely (append unharmed).
  defp upsert_step(event, action, attrs, tenant, actor) do
    case Repo.query(@savepoint_sql, []) do
      {:ok, _} ->
        attempt_step_upsert(event, action, attrs, tenant, actor)

      {:error, reason} ->
        log_step_projection_failure(event, {:savepoint_failed, reason})
    end
  end

  defp attempt_step_upsert(event, action, attrs, tenant, actor) do
    WorkflowStep
    |> Changeset.for_create(action, attrs, tenant: tenant, actor: actor)
    |> Ash.create()
    |> case do
      {:ok, _step} ->
        Repo.query(@release_savepoint_sql, [])
        :ok

      {:error, reason} ->
        Repo.query(@rollback_savepoint_sql, [])
        log_step_projection_failure(event, reason)
    end
  rescue
    # reach:disable-next-line bare_rescue
    error ->
      # Best-effort invariant: ANY raise (Postgrex/DBConnection/Ash) must roll
      # back to the savepoint — the txn is aborted until then — and must never
      # escape into the append path.
      Repo.query(@rollback_savepoint_sql, [])
      log_step_projection_failure(event, error)
  end

  defp log_step_projection_failure(event, reason) do
    Logger.warning(
      "[WorkflowEvent.Allocate] step projection failed for run " <>
        "#{event.workflow_run_id} (#{event.kind} seq #{event.seq}): #{inspect(reason)}"
    )

    :ok
  end

  defp capped(map), do: OutputLimit.truncate(map, payload_leaf_cap())

  # Normalize the env value: only a positive integer is honored. A nil cap
  # would silently fail open (`byte_size(v) > nil` is false under Erlang term
  # ordering, disabling truncation entirely); a negative one would truncate
  # every leaf to marker-only.
  defp payload_leaf_cap do
    case Application.get_env(
           :jido_claw,
           :workflow_event_payload_max_bytes,
           @default_payload_leaf_cap
         ) do
      cap when is_integer(cap) and cap > 0 -> cap
      _invalid -> @default_payload_leaf_cap
    end
  end

  defp put_valid(map, _key, nil, _valid?), do: map

  defp put_valid(map, key, value, valid?) do
    if valid?.(value), do: Map.put(map, key, value), else: map
  end

  defp fetch(payload, key) when is_map(payload) do
    Map.get(payload, key) || Map.get(payload, Atom.to_string(key))
  end
end
