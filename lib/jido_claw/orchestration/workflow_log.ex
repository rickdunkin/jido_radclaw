defmodule JidoClaw.Orchestration.WorkflowLog do
  @moduledoc """
  Ergonomic append seam over `WorkflowEvent` that every producer and the
  recovery reconciler share.

  Coerces `nil` payload/metadata to `%{}`, threads `tenant:`/`actor:`, and
  offers an atomic multi-append (`append_all/3`) for batches that must
  commit together (e.g. recovery's `run_recovered` + `run_failed`).
  """

  alias JidoClaw.Authorization.Actor
  alias JidoClaw.Orchestration.WorkflowEvent
  alias JidoClaw.Orchestration.WorkflowRun

  @recovery_reason "recovered after restart"

  @doc """
  Append one event for `run`. `tenant`/`actor` default to the run's own
  tenant + a system actor; `metadata` defaults to `%{}`.
  """
  @spec append(WorkflowRun.t(), atom(), map() | nil, keyword()) ::
          {:ok, WorkflowEvent.t()} | {:error, term()}
  def append(run, kind, payload, opts \\ []) do
    attrs = %{
      workflow_run_id: run.id,
      kind: kind,
      payload: payload || %{},
      metadata: Keyword.get(opts, :metadata) || %{}
    }

    WorkflowEvent.append(attrs, tenant: tenant(run, opts), actor: actor(run, opts))
  end

  @doc """
  Append a batch of `{kind, payload}` events for `run` in one transaction —
  the atomic multi-append seam. Either all events (and the status changes
  any status-authority kinds imply) persist, or none do.

  Returns `{:ok, last_event}` on success (the terminal event, bare),
  `{:error, reason}` on the first failure (whole batch rolled back), or
  `{:error, :no_events}` for an empty list.
  """
  @spec append_all(WorkflowRun.t(), [{atom(), map()}], keyword()) ::
          {:ok, WorkflowEvent.t()} | {:error, term()}
  def append_all(_run, [], _opts), do: {:error, :no_events}

  def append_all(run, events, opts) when is_list(events) do
    # Ash.transact auto-rolls back when the fn returns {:error, _}; reduce_while
    # short-circuits on the first failure and returns the terminal event (bare)
    # on success.
    Ash.transact(WorkflowEvent, fn ->
      Enum.reduce_while(events, nil, fn {kind, payload}, _acc ->
        case append(run, kind, payload, opts) do
          {:ok, event} -> {:cont, event}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end)
  end

  @doc """
  Append the recovery pair for a stranded `run`: `run_recovered`
  (provenance, carrying `prior_status`) + the terminal `run_failed`, in one
  transaction so neither persists without the other. The projection folds
  `run_failed` to `:failed`. Used only by `WorkflowRecovery`.
  """
  @spec append_recovery(WorkflowRun.t(), atom()) :: {:ok, WorkflowEvent.t()} | {:error, term()}
  def append_recovery(run, prior_status) do
    append_all(
      run,
      [
        {:run_recovered, %{reason: @recovery_reason, prior_status: prior_status}},
        {:run_failed, %{error: @recovery_reason}}
      ],
      tenant: run.tenant_id,
      actor: Actor.system(run.tenant_id)
    )
  end

  defp tenant(run, opts), do: Keyword.get(opts, :tenant, run.tenant_id)
  defp actor(run, opts), do: Keyword.get(opts, :actor, Actor.system(run.tenant_id))
end
