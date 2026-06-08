defmodule JidoClaw.Orchestration.WorkflowLog do
  @moduledoc """
  Ergonomic append seam over `WorkflowEvent` that every producer and the
  recovery reconciler share.

  Coerces `nil` payload/metadata to `%{}`, threads `tenant:`/`actor:`, and
  offers an atomic multi-append (`append_all/3`) for batches that must
  commit together (e.g. recovery's `run_recovered` + `run_failed`).
  """

  alias JidoClaw.Authorization.Actor
  alias JidoClaw.Orchestration.AgentCase
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

  @doc """
  Open a human approval gate for `run` in **one transaction**: create the
  operator-facing `AgentCase` (pending) and append the `approval_requested`
  status event, which flips the run to `:awaiting_approval` in the same
  transaction. Either both persist or neither does.

  Returns `{:ok, agent_case}` on success or `{:error, reason}` on the first
  failure (whole transaction rolled back). Like `append_all/3`, the
  transaction function returns the bare record on success — `Ash.transact`
  wraps it `{:ok, _}` — and any `{:error, reason}` from the `with` bubbles up
  to roll back cleanly (never a match-fail).

  Deliberately does **NOT** broadcast: a gate is announced only after its
  durable resume checkpoint exists, so the runner's `finalize` broadcasts
  `{:gate_requested, …}` *after* persisting the checkpoint (Step 5) — closing
  the approve-before-checkpoint race from the producer side.
  """
  @spec gate_open(WorkflowRun.t(), map(), keyword()) ::
          {:ok, AgentCase.t()} | {:error, term()}
  def gate_open(run, agent_case_attrs, opts \\ []) do
    tenant = tenant(run, opts)
    actor = actor(run, opts)

    Ash.transact([AgentCase, WorkflowEvent], fn ->
      with {:ok, gate} <- AgentCase.create(agent_case_attrs, tenant: tenant, actor: actor),
           {:ok, _event} <-
             append(
               run,
               :approval_requested,
               %{agent_case_id: gate.id, step_name: gate.step_name, kind: gate.kind},
               tenant: tenant,
               actor: actor
             ) do
        gate
      end
    end)
  end

  @doc """
  Terminate `run` AND cancel its pending `AgentCase`(s) in one transaction:
  cancel every pending case with `case_reason`, then append `kind` (a terminal
  event the projection folds to a terminal status, clearing the checkpoint per
  Decision 7). Either both persist or neither does, so run status and the
  operator inbox never disagree. Shared by the runner's gate-pause failure path
  and recovery's dangling-gate branch.
  """
  @spec terminate_cancelling_cases(WorkflowRun.t(), atom(), map(), String.t(), keyword()) ::
          {:ok, WorkflowEvent.t()} | {:error, term()}
  def terminate_cancelling_cases(run, kind, payload, case_reason, opts \\ []) do
    tenant = tenant(run, opts)
    actor = actor(run, opts)

    Ash.transact([AgentCase, WorkflowEvent], fn ->
      with {:ok, _} <- cancel_pending_cases(run, case_reason, tenant, actor),
           {:ok, event} <- append(run, kind, payload, tenant: tenant, actor: actor) do
        event
      end
    end)
  end

  defp cancel_pending_cases(run, reason, tenant, actor) do
    case AgentCase.pending_for_run(run.id, tenant: tenant, actor: actor) do
      {:ok, cases} ->
        Enum.reduce_while(cases, {:ok, :done}, fn agent_case, _acc ->
          case AgentCase.cancel(agent_case, %{cancellation_reason: reason},
                 tenant: tenant,
                 actor: actor
               ) do
            {:ok, _} -> {:cont, {:ok, :done}}
            {:error, r} -> {:halt, {:error, r}}
          end
        end)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The 3-arg `Keyword.get/3` applies the default only when the key is *absent*,
  # so an explicit `actor: nil` (which the runner passes via
  # `Keyword.get(opts, :actor)`) would defeat the `Actor.system/1` fallback. The
  # `|| default` form falls back on `nil` too.
  defp tenant(run, opts), do: Keyword.get(opts, :tenant) || run.tenant_id
  defp actor(run, opts), do: Keyword.get(opts, :actor) || Actor.system(run.tenant_id)
end
