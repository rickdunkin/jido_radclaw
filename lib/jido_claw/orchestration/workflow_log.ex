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
  alias JidoClaw.Orchestration.AgentCaseEvent
  alias JidoClaw.Orchestration.WorkflowEvent
  alias JidoClaw.Orchestration.WorkflowRun

  @recovery_reason "recovered after restart"

  @doc """
  Append one event for `run`. `tenant`/`actor` default to the run's own
  tenant + a system actor; `metadata` defaults to `%{}`.

  WS1 lease: an optional `:claim_fence_token` opt is forwarded to
  `WorkflowEvent.append` via the action `context:` (NOT the payload — it must
  not be persisted), where `Allocate`'s in-txn fence B compares it to the run's
  current `claim_token` and rejects a stale-owner status-authority write — a
  terminal (`run_completed`/`run_failed`) OR the gate flip `approval_requested`
  (forwarded by `gate_open/3`). Only the leased-executor producers pass it; the
  other helpers (operator cancel/decide, recovery) never fence their writes.
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

    event_opts =
      [tenant: tenant(run, opts), actor: actor(run, opts)] ++
        fence_context(Keyword.get(opts, :claim_fence_token))

    WorkflowEvent.append(attrs, event_opts)
  end

  # The fence token rides the action `context:` so fence B can read it off
  # `changeset.context` without persisting it. Absent/nil ⇒ no context key ⇒ the
  # fence is a no-op (the catch-all in `Allocate.claim_fenced?`).
  defp fence_context(token) when is_binary(token), do: [context: %{claim_fence_token: token}]
  defp fence_context(_token), do: []

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
  operator-facing `AgentCase` (pending), append the `approval_requested`
  status event (which flips the run to `:awaiting_approval`), and append the
  case's `:opened` timeline event. Either all three persist or none do.

  Returns `{:ok, agent_case}` on success or `{:error, reason}` on the first
  failure (whole transaction rolled back). Like `append_all/3`, the
  transaction function returns the bare record on success — `Ash.transact`
  wraps it `{:ok, _}` — and any `{:error, reason}` from the `with` bubbles up
  to roll back cleanly (never a match-fail).

  WS1 fence B: an optional `:claim_fence_token` opt is forwarded **only** to the
  `approval_requested` append (not `AgentCase.create`/`case_event` — those are
  not `WorkflowEvent` appends, and the surrounding transaction rolls them back
  with it). `GateStep` passes the held lease token, so a stale owner that reaches
  a gate after a reclaimer rotated the token has its whole `gate_open` rolled
  back — no duplicate `AgentCase`, no `:awaiting_approval` flip — instead of
  opening a duplicate gate. nil ⇒ the fence no-ops (degraded/legacy run).

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

    Ash.transact([AgentCase, AgentCaseEvent, WorkflowEvent], fn ->
      with {:ok, gate} <- AgentCase.create(agent_case_attrs, tenant: tenant, actor: actor),
           {:ok, _event} <-
             append(
               run,
               :approval_requested,
               %{agent_case_id: gate.id, step_name: gate.step_name, kind: gate.kind},
               tenant: tenant,
               actor: actor,
               # WS1 fence B: a stale owner's gate flip is rejected in-txn, rolling
               # back the whole gate_open (no duplicate case, no status flip). nil
               # (operator/legacy callers) ⇒ no-op.
               claim_fence_token: Keyword.get(opts, :claim_fence_token)
             ),
           {:ok, _case_event} <-
             case_event(
               gate,
               :opened,
               %{step_name: gate.step_name, kind: gate.kind, workflow_run_id: run.id},
               tenant,
               actor
             ) do
        gate
      end
    end)
  end

  @doc """
  Append one immutable `AgentCaseEvent` to `gate`'s timeline. Must be called
  inside the same transaction as the case-status flip it records — every
  caller is one of the single-transaction choke-points (`gate_open/3`,
  `Cases` decision/abandon/retract commits, `terminate_cancelling_cases/5`).
  """
  @spec case_event(AgentCase.t(), atom(), map(), String.t(), term()) ::
          {:ok, AgentCaseEvent.t()} | {:error, term()}
  def case_event(gate, type, data, tenant, actor) do
    AgentCaseEvent.append(
      %{agent_case_id: gate.id, type: type, data: data || %{}},
      tenant: tenant,
      actor: actor
    )
  end

  @doc """
  Terminate `run` AND cancel its pending `AgentCase`(s) in one transaction:
  cancel every pending case with `case_reason` (each appending a `:cancelled`
  timeline event), then append `events` — a `{kind, payload}` list whose final
  element must be a terminal event the projection folds to a terminal status
  (clearing the checkpoint per Decision 7). Either everything persists or
  nothing does, so run status, the operator inbox, and the case timelines
  never disagree. Shared by the runner's gate-pause failure path and
  recovery's dangling-gate branch (which passes the
  `[{:run_recovered, …}, {:run_failed, …}]` recovery pair).
  """
  @spec terminate_cancelling_cases(WorkflowRun.t(), [{atom(), map()}], String.t(), keyword()) ::
          {:ok, WorkflowEvent.t()} | {:error, term()}
  def terminate_cancelling_cases(run, events, case_reason, opts \\ []) when is_list(events) do
    tenant = tenant(run, opts)
    actor = actor(run, opts)

    Ash.transact([AgentCase, AgentCaseEvent, WorkflowEvent], fn ->
      with {:ok, _} <- cancel_pending_cases(run, case_reason, tenant, actor),
           {:ok, event} <- append_each(run, events, tenant: tenant, actor: actor) do
        event
      end
    end)
  end

  # Sequential appends inside the caller's transaction; returns the last event.
  defp append_each(_run, [], _opts), do: {:error, :no_events}

  defp append_each(run, events, opts) do
    Enum.reduce_while(events, {:error, :no_events}, fn {kind, payload}, _acc ->
      case append(run, kind, payload, opts) do
        {:ok, event} -> {:cont, {:ok, event}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp cancel_pending_cases(run, reason, tenant, actor) do
    case AgentCase.pending_for_run(run.id, tenant: tenant, actor: actor) do
      {:ok, cases} ->
        Enum.reduce_while(cases, {:ok, :done}, fn agent_case, _acc ->
          case cancel_case(agent_case, reason, tenant, actor) do
            {:ok, _} -> {:cont, {:ok, :done}}
            {:error, r} -> {:halt, {:error, r}}
          end
        end)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Cancel one pending case + its `:cancelled` timeline event, atomically with
  # the surrounding transaction.
  defp cancel_case(agent_case, reason, tenant, actor) do
    with {:ok, cancelled} <-
           AgentCase.cancel(agent_case, %{cancellation_reason: reason},
             tenant: tenant,
             actor: actor
           ),
         {:ok, _case_event} <-
           case_event(cancelled, :cancelled, %{reason: reason}, tenant, actor) do
      {:ok, cancelled}
    end
  end

  # The 3-arg `Keyword.get/3` applies the default only when the key is *absent*,
  # so an explicit `actor: nil` (which the runner passes via
  # `Keyword.get(opts, :actor)`) would defeat the `Actor.system/1` fallback. The
  # `|| default` form falls back on `nil` too.
  defp tenant(run, opts), do: Keyword.get(opts, :tenant) || run.tenant_id
  defp actor(run, opts), do: Keyword.get(opts, :actor) || Actor.system(run.tenant_id)
end
