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
  reload the (now-terminal, frozen-`claimed_by`) run and route the kill to the
  owning node: `resolve_kill_target/3` resolves `:local` (call
  `RunExecution.kill_local/2` synchronously), `{:remote, node}` (fire-and-forget
  `GenServer.cast` to that node's `RunTerminator`, which calls `kill_local/2`
  there), or `:unroutable` (no-op — WS3 reclaim covers a gone/disconnected
  owner). The kill is a latency/waste optimization; the durable decision is the
  guarantee. **Never a kill after a failed durable decision.**

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

  alias JidoClaw.Cluster
  alias JidoClaw.Orchestration.AgentCase
  alias JidoClaw.Orchestration.Cases
  alias JidoClaw.Orchestration.RunExecution
  alias JidoClaw.Orchestration.RunPubSub
  alias JidoClaw.Orchestration.RunTerminator
  alias JidoClaw.Orchestration.WorkflowEvent.Projection
  alias JidoClaw.Orchestration.WorkflowLease
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
        # Reload once after the terminal commits, then route + broadcast off the
        # SAME fresh struct. The post-append `claimed_by` is frozen (no new stamp
        # can win once terminal — `WorkflowLease.stamp/4` gates on
        # status IN ('pending','running')), so routing on it is authoritative and
        # closes the stale-`claimed_by` race; the reload also feeds the broadcast,
        # collapsing what was two reads into one. A freak reload failure degrades
        # to the entry-time struct (the durable cancel already won).
        reloaded = reload(run, tenant, actor)
        kill_if_live(reloaded)
        finish(reloaded)

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

  @doc """
  Resolve where a run's executor should be killed: pure routing decision over
  the run's `claimed_by` (the WS1 lease-owner identity, or `nil` when
  unclaimed), this node's identity (`WorkflowLease.node_identity/0`), and the
  connected remote nodes (`Cluster.nodes/0`).

    * `:local` — unclaimed (`nil`) or owned by this node ⇒ kill here.
      Byte-identical to the pre-WS5 unconditional local kill.
    * `{:remote, node}` — owned by a connected node ⇒ route the kill there.
    * `:unroutable` — owner gone/disconnected ⇒ no-op (WS3 reclaim covers it).

  Matches node *strings* against the candidate atoms (never
  `String.to_existing_atom/1`, which would crash on an unknown node name).
  Pure (identity strings + node atoms in, decision out) so it is unit-tested
  directly, like `JidoClaw.Cluster.Leader.elect/1`.
  """
  @spec resolve_kill_target(String.t() | nil, String.t(), [node()]) ::
          :local | {:remote, node()} | :unroutable
  def resolve_kill_target(nil, _self_identity, _other_nodes), do: :local

  def resolve_kill_target(claimed_by, self_identity, other_nodes) do
    if claimed_by == self_identity do
      :local
    else
      case Enum.find(other_nodes, &(to_string(&1) == claimed_by)) do
        nil -> :unroutable
        node -> {:remote, node}
      end
    end
  end

  # Route the post-append kill to the node that owns the run (WS5), via the pure
  # `resolve_kill_target/3` + the shared `cast_kill/2` dispatch. Cancellation
  # routes on the freshly-reloaded `claimed_by`; `WorkflowRecovery`'s reclaim
  # kill-cast (C-H1) routes on the reclaimed run's PRIOR owner instead — same
  # dispatch, different target source — so the dispatch arm is public + shared.
  defp kill_if_live(%WorkflowRun{} = run) do
    run.claimed_by
    |> resolve_kill_target(WorkflowLease.node_identity(), Cluster.nodes())
    |> cast_kill(run)
  end

  @doc """
  Dispatch a resolved kill `target` (from `resolve_kill_target/3`) for `run`.

    * `:local` — `RunExecution.kill_local/2` synchronously (single-node path,
      byte-identical to pre-WS5).
    * `{:remote, node}` — fire-and-forget a cast to that node's `RunTerminator`,
      which calls `kill_local/2` there. The durable decision is the guarantee, so
      a bounded cross-node `call` would only add a timeout failure surface for
      zero correctness gain (matching `Cron.Owner`'s follower cast, not its
      `call`-based `trigger/2`).
    * `:unroutable` — no-op (owner gone/disconnected — WS3 reclaim covers it).

  Public + shared: `WorkflowRecovery`'s reclaim kill-cast (C-H1) calls it with a
  target resolved off the run's PRIOR owner. The tenant pin and the registry-miss
  no-op both live in `RunExecution.kill_local/2`, so a lost or wrong-node cast is
  harmless.
  """
  @spec cast_kill(:local | {:remote, node()} | :unroutable, WorkflowRun.t()) :: :ok
  def cast_kill(:local, %WorkflowRun{} = run), do: RunExecution.kill_local(run.id, run.tenant_id)

  def cast_kill({:remote, node}, %WorkflowRun{} = run) do
    Logger.debug("[Cancellation] routing kill for #{run.id} to #{node}")
    GenServer.cast({RunTerminator, node}, {:kill, run.id, run.tenant_id})
  end

  def cast_kill(:unroutable, %WorkflowRun{}), do: :ok

  # Broadcast the post-cancel terminal in the runner's backstop shape and return
  # the run. Takes the already-reloaded struct — `cancel_live/4` reloads once
  # after the terminal commits and reuses it for both routing and this
  # broadcast. WorkflowsLive refreshes synchronously today; the broadcast exists
  # for a live-update follow-up.
  defp finish(%WorkflowRun{} = reloaded) do
    RunPubSub.broadcast_run_terminal(reloaded, :run_cancelled, :cancelled)
    {:ok, reloaded}
  end

  defp reload(run, tenant, actor) do
    case WorkflowRun.by_id(run.id, tenant: tenant, actor: actor) do
      {:ok, %WorkflowRun{} = reloaded} -> reloaded
      _other -> run
    end
  end
end
