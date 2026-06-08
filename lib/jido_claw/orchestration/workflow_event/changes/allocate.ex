defmodule JidoClaw.Orchestration.WorkflowEvent.Changes.Allocate do
  @moduledoc """
  The `WorkflowEvent.:append` change — sole `seq` allocator, payload
  redactor, and (for status-authority kinds) the materialized
  `WorkflowRun.status` writer. Runs entirely inside the `:append` action's
  transaction.

  ## Tenant threading

  Every internal read/update threads `tenant: changeset.tenant` (the tenant
  the append was called with, which equals the event's `tenant_id`).
  `authorize?: false` drops the *policy* but NOT the multitenancy *filter*,
  so an attribute-multitenant read/update without `tenant:` would fail or
  silently cross the tenant boundary.

  ## before_action

    1. Lock + read the parent run (`FOR UPDATE`) so concurrent appends for
       one run serialize. A missing run (or a tenant mismatch the filter
       drops) becomes a clean changeset error, not a crash on `nil`.
    2. Stash `run.status` and the **raw** payload in changeset context for
       the after_action — *before* redaction.
    3. Allocate `seq = max(existing) + 1` (after the lock) and redact the
       persisted `payload`/`metadata`. The unique `(workflow_run_id, seq)`
       index is the backstop.

  ## after_action (status-authority kinds only)

    1. Transition guard via `Projection.next_status/2`; an `:illegal`
       transition returns `{:error, …}` so the whole append rolls back —
       the event is NOT persisted and status is unchanged.
    2. Update the run via its private `:set_status` action, sourcing
       `occurred_at` from the created event and `result`/`error` from the
       raw stashed payload, in the same transaction.
  """

  use Ash.Resource.Change

  require Ash.Query, as: Query

  alias Ash.Changeset
  alias Ash.Error.Changes.InvalidChanges
  alias JidoClaw.Orchestration.WorkflowEvent
  alias JidoClaw.Orchestration.WorkflowEvent.Projection
  alias JidoClaw.Orchestration.WorkflowRun
  alias JidoClaw.Security.Redaction.Transcript

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> Changeset.before_action(&allocate/1)
    |> Changeset.after_action(&maybe_update_status/2)
  end

  defp allocate(changeset) do
    run_id = Changeset.get_attribute(changeset, :workflow_run_id)
    tenant = changeset.tenant

    case lock_run(run_id, tenant) do
      {:ok, run} ->
        raw_payload = Changeset.get_attribute(changeset, :payload) || %{}
        raw_metadata = Changeset.get_attribute(changeset, :metadata) || %{}

        changeset
        |> Changeset.set_context(%{
          workflow_event: %{current_status: run.status, raw_payload: raw_payload}
        })
        |> Changeset.force_change_attribute(:seq, next_seq(run_id, tenant))
        |> Changeset.force_change_attribute(:payload, Transcript.redact(raw_payload))
        |> Changeset.force_change_attribute(:metadata, Transcript.redact(raw_metadata))

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
  defp lock_run(run_id, tenant) do
    WorkflowRun
    |> Query.filter(id == ^run_id)
    |> Query.lock("FOR UPDATE")
    |> Ash.read_one(tenant: tenant, authorize?: false)
    |> case do
      {:ok, %WorkflowRun{} = run} -> {:ok, run}
      _ -> :error
    end
  end

  defp next_seq(run_id, tenant) do
    WorkflowEvent
    |> Query.filter(workflow_run_id == ^run_id)
    |> Query.sort(seq: :desc)
    |> Query.limit(1)
    |> Ash.read_one(tenant: tenant, authorize?: false)
    |> case do
      {:ok, %WorkflowEvent{seq: seq}} -> seq + 1
      _ -> 1
    end
  end

  defp maybe_update_status(changeset, event) do
    if Projection.status_authority?(event.kind) do
      %{current_status: current_status, raw_payload: raw_payload} =
        changeset.context[:workflow_event]

      update_status(event, current_status, raw_payload, changeset.tenant)
    else
      {:ok, event}
    end
  end

  defp update_status(event, current_status, raw_payload, tenant) do
    case Projection.next_status(current_status, event.kind) do
      {:ok, _new_status} ->
        attrs = Projection.status_attrs(event.kind, raw_payload, event.occurred_at)
        apply_status(event, attrs, tenant)

      :illegal ->
        {:error,
         InvalidChanges.exception(
           fields: [:kind],
           message: "illegal status transition: #{event.kind} from #{inspect(current_status)}"
         )}
    end
  end

  defp apply_status(event, attrs, tenant) do
    with {:ok, run} <- load_run(event.workflow_run_id, tenant),
         {:ok, _updated} <-
           run
           |> Changeset.for_update(:set_status, attrs, tenant: tenant, authorize?: false)
           |> Ash.update() do
      {:ok, event}
    else
      :error -> {:error, "workflow run vanished during status update"}
      {:error, reason} -> {:error, reason}
    end
  end

  # Re-read within the held FOR UPDATE lock (same transaction) for the
  # status update; cheap and avoids stashing a struct through context.
  defp load_run(run_id, tenant) do
    WorkflowRun
    |> Query.filter(id == ^run_id)
    |> Ash.read_one(tenant: tenant, authorize?: false)
    |> case do
      {:ok, %WorkflowRun{} = run} -> {:ok, run}
      _ -> :error
    end
  end
end
