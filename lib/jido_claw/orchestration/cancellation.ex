defmodule JidoClaw.Orchestration.Cancellation do
  @moduledoc """
  The single decision point for stopping a live `WorkflowRun` — the operator
  kill switch for a `:running` workflow (a stuck LLM loop, a hung tool call).
  Dashboard-only surface (`JidoClaw.Web.WorkflowsLive`), mirroring the
  replay-overrides-are-dashboard-only precedent: deliberately not exposed via
  the CLI or MCP.

  ## Routing (`cancel/2`)

    * Terminal run → `{:error, :already_terminal}` — nothing to stop.
    * `:awaiting_approval` with a pending case → delegates to
      `Cases.abandon/3`: a parked run has nothing executing by construction,
      and its terminal is `:abandoned`, **not** `:cancelled` (the projection's
      AR-1 rule). The delegation carries the operator audit field
      (`decided_by_id` from the actor's uuid `user_id`, when present) —
      audit parity with the ApprovalsLive abandon path. A parked run with
      *no* pending case (recovery-class orphan) falls through to the live
      path — `run_cancelled` is legal from `:awaiting_approval`.
    * `:pending` / `:running` → the durable-first live path below.

  ## Durable-decision-first (the ordering invariant)

  The live path appends `run_cancelled` — terminating the run AND cancelling
  any pending cases in **one transaction** via
  `WorkflowLog.terminate_cancelling_cases/4` (a resumed multi-gate run can
  hold a pending case while `:running`) — and only after that commit does it
  kill the executor (`RunExecution.lookup/1` → `Process.exit(pid, :kill)`,
  with a defensive tenant check on the registry value). **Never a kill after
  a failed durable decision.**

  ## Races (all resolve to durable truth)

    * **Cancel vs completion**: the run completing between the entry load and
      the append makes `run_cancelled` an illegal transition — the append
      fails, the reload sees a terminal, and the caller gets the clean
      `{:error, :already_terminal}` (never the raw Ash error, and no kill).
    * **Append-then-kill window**: a run completing in the gap stays
      `:cancelled` (first terminal wins under the per-run `FOR UPDATE` lock);
      the executor's late terminal append propagates `{:error, _}` out of
      `Reactor.run`, which `ReactorRunner`'s reload-first finalize maps to
      `{:error, :cancelled, run}`.
    * **Cancel before the executor registers**: the kill is skipped (registry
      miss) but the late task's `run_started` append is illegal from
      `:cancelled`, so the reactor never runs a step — the durable decision
      wins against registration timing. The resume leg is covered the same
      way: a resumed reactor's `run_resumed` append fails and
      `ReactorMiddleware` reloads, sees the terminal status, and hard-stops
      before any downstream step.
    * **Stranded `:running` run** (no live pid): the cancel still lands
      durably; the kill is a no-op.

  Killing the executor orphans already-started async-step work (it may run to
  completion into the void) — see `RunExecution`'s moduledoc; bounded to
  in-flight work, nothing new schedules.
  """

  require Logger

  alias JidoClaw.Orchestration.AgentCase
  alias JidoClaw.Orchestration.Cases
  alias JidoClaw.Orchestration.RunExecution
  alias JidoClaw.Orchestration.RunPubSub
  alias JidoClaw.Orchestration.WorkflowEvent.Projection
  alias JidoClaw.Orchestration.WorkflowLog
  alias JidoClaw.Orchestration.WorkflowRun

  # Folds onto `WorkflowEvent.Projection`'s terminal set — the compile-time call
  # bakes the literal list into the `status in @terminal` guards below: a run
  # that can no longer make progress has nothing to cancel.
  @terminal Projection.terminal_statuses()

  @default_reason "cancelled by operator"

  @doc """
  Cancel the run identified by `run_or_id` (a `%WorkflowRun{}` or an id).

  Required opts: `:tenant`, `:actor` (missing → `{:error,
  :missing_required_opt}` — never raises). Optional `:reason` (default
  `"#{@default_reason}"`) lands in the `run_cancelled` payload and on any
  cancelled/abandoned cases.

  Returns `{:ok, run}` with the run's resulting state — `:cancelled` for a
  live run, `:abandoned` for a parked one — or `{:error, reason}`
  (`:already_terminal` · `:not_found` · a `Cases.abandon/3` refusal · a
  genuine append failure).
  """
  @spec cancel(WorkflowRun.t() | String.t(), keyword()) ::
          {:ok, WorkflowRun.t()} | {:error, term()}
  def cancel(run_or_id, opts \\ []) do
    with {:ok, tenant} <- Keyword.fetch(opts, :tenant),
         {:ok, actor} <- Keyword.fetch(opts, :actor) do
      reason = Keyword.get(opts, :reason) || @default_reason
      do_cancel(run_id(run_or_id), reason, tenant, actor)
    else
      :error -> {:error, :missing_required_opt}
    end
  end

  # -- Internal --

  defp run_id(%WorkflowRun{id: id}), do: id
  defp run_id(id), do: id

  # Route on the FRESH status — the caller's struct may be stale. The
  # tenant-scoped read gives tenant isolation for free: a cross-tenant id is
  # filtered by the read policy and lands in the not-found clause (Replay
  # precedent).
  defp do_cancel(run_id, reason, tenant, actor) do
    case WorkflowRun.by_id(run_id, tenant: tenant, actor: actor) do
      {:ok, %WorkflowRun{status: status}} when status in @terminal ->
        {:error, :already_terminal}

      {:ok, %WorkflowRun{status: :awaiting_approval} = run} ->
        cancel_parked(run, reason, tenant, actor)

      {:ok, %WorkflowRun{} = run} ->
        cancel_live(run, reason, tenant, actor)

      _missing_or_unreadable ->
        {:error, :not_found}
    end
  end

  # A parked run ends :abandoned via the one-transaction case+run semantics in
  # Cases.abandon (never a hand-rolled duplicate here). Parked-with-no-case is
  # the recovery-class orphan — the live path cancels it durably.
  defp cancel_parked(run, reason, tenant, actor) do
    case AgentCase.pending_for_run(run.id, tenant: tenant, actor: actor) do
      {:ok, [%AgentCase{id: case_id} | _]} ->
        Cases.abandon(
          case_id,
          %{cancellation_reason: reason, decided_by_id: actor_user_id(actor)},
          tenant: tenant,
          actor: actor
        )

      {:ok, []} ->
        cancel_live(run, reason, tenant, actor)

      {:error, error} ->
        {:error, error}
    end
  end

  # The operator audit field for the abandon delegation — the same action from
  # ApprovalsLive's "Abandon run" button records `decided_by_id` from the
  # actor, and a dashboard cancel of a parked run must match. UUID-validated
  # (`decided_by_id` is a `:uuid` attribute) so system actors (`user_id: nil`)
  # and non-uuid internal/test actor shapes degrade to nil — the attribute
  # allows nil — rather than surfacing a cast error out of abandon.
  defp actor_user_id(%{user_id: id}) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  defp actor_user_id(_actor), do: nil

  # Durable first: the one-transaction terminal + pending-case net commits
  # BEFORE any kill. A failed append is re-routed through a reload (a
  # completion race reads as :already_terminal, never the raw Ash error) and
  # is NEVER followed by a kill.
  defp cancel_live(run, reason, tenant, actor) do
    case WorkflowLog.terminate_cancelling_cases(
           run,
           [{:run_cancelled, %{reason: reason}}],
           reason,
           tenant: tenant,
           actor: actor
         ) do
      {:ok, _event} ->
        kill_if_live(run)
        finish(run, tenant, actor)

      {:error, error} ->
        explain_append_failure(run, error, tenant, actor)
    end
  end

  # A reload that still reads non-terminal (or, freak case, fails — reload
  # falls back to the entry-time struct) means the append failure was genuine.
  defp explain_append_failure(run, error, tenant, actor) do
    if reload(run, tenant, actor).status in @terminal do
      {:error, :already_terminal}
    else
      {:error, error}
    end
  end

  # Kill the live executor iff the registry value (the tenant the executor
  # registered with) matches the run's tenant — a defensive cross-tenant
  # guard. A registry miss is a no-op: the cancel already landed durably.
  defp kill_if_live(%WorkflowRun{tenant_id: run_tenant} = run) do
    case RunExecution.lookup(run.id) do
      {:ok, pid, ^run_tenant} ->
        Process.exit(pid, :kill)
        :ok

      {:ok, pid, other_tenant} ->
        Logger.warning(
          "[Cancellation] registry tenant mismatch for run #{run.id}: " <>
            "registered #{inspect(other_tenant)}, run has #{inspect(run_tenant)} — " <>
            "not killing #{inspect(pid)}"
        )

        :ok

      :error ->
        :ok
    end
  end

  # Reload for the authoritative post-cancel state (in-memory fallback on a
  # freak read failure — the durable cancel has already committed), broadcast
  # in the runner's backstop shape, return the run. WorkflowsLive refreshes
  # synchronously today; the broadcast exists for a live-update follow-up.
  defp finish(run, tenant, actor) do
    reloaded = reload(run, tenant, actor)

    RunPubSub.broadcast(
      reloaded.id,
      {:run_cancelled, reloaded.id,
       %{
         tenant_id: reloaded.tenant_id,
         name: reloaded.name,
         workflow_type: reloaded.workflow_type,
         status: :cancelled,
         completed_at: reloaded.completed_at
       }}
    )

    {:ok, reloaded}
  end

  defp reload(run, tenant, actor) do
    case WorkflowRun.by_id(run.id, tenant: tenant, actor: actor) do
      {:ok, %WorkflowRun{} = reloaded} -> reloaded
      _other -> run
    end
  end
end
