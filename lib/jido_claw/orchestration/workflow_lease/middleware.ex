defmodule JidoClaw.Orchestration.WorkflowLease.Middleware do
  @moduledoc """
  The `Reactor.Middleware` that claims a run's durable lease at execution start.

  `init/1` is the **only** callback (cleanup is monitor-driven by the
  `Sidecar`). The runner normalizes the middleware list to
  `[WorkflowLease.Middleware | rest] ++ [ReactorMiddleware]`, so this `init/1`
  runs **first** and the durable recorder runs last. The row is stamped at
  `:pending` before custom init hooks and `ReactorMiddleware` appends
  `run_started` only after those hooks succeed. A crash in the gap leaves a clean
  `:pending` + claimed + expiry row (which `:claimable` selects), never an
  ambiguous `:running`-unclaimed crack.

  The stamp is a **compare-and-swap on the prior token** (`WorkflowLease.stamp/4`),
  reached only by the process that won `RunRegistry` registration
  (`RunExecution.run_killable/4`). So a same-node duplicate never stamps, and a
  cross-node duplicate that does reach here loses the CAS (`{:ok, :lost}`) and
  aborts with no terminal — fence A maps `{:lease_lost, _}` to the clean
  no-terminal envelope.

  ## Degraded vs fail-closed

  All failure shapes **fail closed under clustering** — `{:error, _}` aborts the
  run before any step. Single-node they diverge, because nothing reclaims an
  *unstamped* row but the always-on `ReclaimPooler` WILL reclaim a stamped row once
  its lease lapses (WS3). Three shapes:

    * A **genesis stamp/claim failure** (`{:error, _}` from `stamp/4` on a run with
      a `nil` prior token — nothing was ever stamped, no claim columns to lapse, no
      fresh-vs-prior token disagreement) degrades single-node by running unleased,
      byte-identical to the pre-lease world; cluster fails closed
      (`stamp_error_degrade/4`, `nil`-prior clause).
    * An **already-claimed stamp/claim failure** (`stamp/4` errored on a *re-stamp*
      — a `GateResume`/recovery resume of a run that ALREADY carries a prior token):
      the failed CAS did not rotate, so the row still holds the PRIOR token while
      this resume holds a FRESH one. Degrading would strand a live executor behind
      fences A/B, so it **fails closed in BOTH modes** — no executor runs, and
      finalize's fence A (prior ≠ fresh) leaves the run `:running` with NO terminal,
      to be re-resumed by reclaim/boot. It first **re-arms** the prior claim
      (`WorkflowLease.release_for_reclaim/2`, a `now() + cooldown` token-fenced push)
      so a NULL-expiry sidecar-degrade residual is Pooler-reclaimable, not boot-only
      (`stamp_error_degrade/4`, binary-prior clause).
    * A **sidecar failure** (the row WAS stamped, `claim_expires_at` is set, but
      the heartbeat won't arm) must NOT just proceed — the stamped lease would
      lapse and the Pooler would reclaim a *live* executor. So single-node routes
      through `WorkflowLease.degrade_gate/2`: it suspends the claim (NULLs the
      expiry, keeps the token → unreclaimable, boot-recovery-only) and proceeds
      unleased **only when the suspend took**; a lost/failed suspend FAILS CLOSED
      even single-node (`suspend_or_fail_closed/4`).

  A `{:ok, :lost}` aborts in **either** mode (someone else, or a terminal, owns
  the row). A context with no `:claim_token` (a degraded/legacy caller) is a no-op
  `{:ok, ctx}` — byte-identical.

  ## Telemetry

  A won CAS emits `[:jido_claw, :orchestration, :claimed]`; a `{:ok, :lost}`
  emits `[:jido_claw, :orchestration, :fenced_out]` with `reason: :claim_lost` —
  which means "claim refused", not "another node fenced us": `stamp/4` returns
  `{:ok, :lost}` both for a lost cross-node CAS *and* for a terminal/parked
  row's status-guard miss. No lease token rides any metadata.
  """

  use Reactor.Middleware

  require Logger

  alias JidoClaw.Orchestration.WorkflowLease
  alias JidoClaw.Orchestration.WorkflowRun

  @impl Reactor.Middleware
  @spec init(Reactor.context()) :: {:ok, Reactor.context()} | {:error, term()}
  def init(%{claim_token: token, workflow_run: %WorkflowRun{id: id, tenant_id: tid} = run} = ctx)
      when is_binary(token) do
    # CAS on the prior token: only the execution winner (cross-node) claims.
    case lease_module().stamp(id, token, run.claim_token, tenant: tid) do
      {:ok, :claimed} ->
        # Emitted before the sidecar arms: claimed = the CAS stamp won.
        emit_claimed(id, tid, run.workflow_type)

        # Readiness is part of the claim — a dead sidecar means an unmonitored
        # executor, which fence-from-the-outside cannot stop.
        case WorkflowLease.start_sidecar(self(), id, tid, token) do
          :ok -> {:ok, ctx}
          {:error, reason} -> suspend_or_fail_closed(id, token, {:lease_sidecar, reason}, ctx)
        end

      # Another owner — OR a terminal/parked row — landed first. Abort regardless
      # of mode; fence A turns `{:lease_lost, _}` into a no-terminal stop.
      {:ok, :lost} ->
        emit_fenced_out(id, tid, :claim_lost)
        {:error, {:lease_lost, id}}

      {:error, reason} ->
        stamp_error_degrade(id, run.claim_token, {:lease_claim, reason}, ctx)
    end
  end

  # No token (degraded/legacy caller) → unleased, byte-identical.
  def init(ctx), do: {:ok, ctx}

  # Genesis (nil prior): nothing was ever stamped — no claim columns, no
  # fresh-vs-prior token disagreement — so a single-node degrade is byte-identical
  # to the pre-lease world (a never-stamped row turns `:running` and is
  # unreclaimable; boot recovery is the net for a genuine crash, NOT the
  # lease-expiry reclaim loop). Cluster still fails closed (unchanged).
  defp stamp_error_degrade(_id, nil, reason, ctx) do
    if cluster_enabled?() do
      {:error, reason}
    else
      Logger.warning(
        "[WorkflowLease] degraded (single-node, genesis), running unleased: #{inspect(reason)}"
      )

      {:ok, ctx}
    end
  end

  # Already-claimed (binary prior — a GateResume/recovery re-stamp): the failed CAS
  # did NOT rotate, so the row still holds the PRIOR token while this resume holds a
  # FRESH one. Proceeding degraded would strand a live executor behind fences A/B.
  # FAIL CLOSED in both modes — no executor runs, and finalize's fence A (prior !=
  # fresh) leaves the run :running with NO terminal. Re-arm the prior claim first so
  # a NULL-expiry (sidecar-degrade) residual is Pooler-reclaimable, not boot-only.
  defp stamp_error_degrade(id, prior, reason, _ctx) when is_binary(prior) do
    WorkflowLease.release_for_reclaim(id, prior)
    {:error, reason}
  end

  # The SIDECAR-failure path: `stamp/4` already succeeded, so `claim_expires_at` is
  # set and the row WOULD be reclaimed by the always-on Pooler once it lapses (WS3).
  # Cluster: do NOT suspend — fail closed ({:error, _} aborts the run; the runner's
  # finalize handles the terminal). Single-node: `degrade_gate/2` suspends + decides
  # — proceed unleased only when the suspend took (NULL expiry, token kept ⇒
  # unreclaimable, boot-recovery-only), else fail closed (the live, sidecar-less,
  # still-stamped run must not be left reclaimable).
  defp suspend_or_fail_closed(id, token, reason, ctx) do
    if cluster_enabled?() do
      {:error, reason}
    else
      case WorkflowLease.degrade_gate(id, token) do
        :degrade ->
          Logger.warning(
            "[WorkflowLease] degraded (single-node), suspended claim + running unleased: " <>
              "#{inspect(reason)}"
          )

          {:ok, ctx}

        :fail_closed ->
          Logger.error(
            "[WorkflowLease] sidecar failed + claim suspend lost/failed (#{inspect(reason)}); " <>
              "failing closed"
          )

          {:error, reason}
      end
    end
  end

  # Metadata carries identities only — never the lease token (fence
  # credentials stay out of telemetry).
  defp emit_claimed(run_id, tenant_id, workflow_type) do
    :telemetry.execute(
      [:jido_claw, :orchestration, :claimed],
      %{count: 1},
      %{
        run_id: run_id,
        tenant_id: tenant_id,
        workflow_type: workflow_type,
        node: WorkflowLease.node_identity()
      }
    )
  end

  # `:claim_lost` = "claim refused" (lost cross-node CAS OR a terminal/parked
  # row's status-guard miss) — see the moduledoc; never a pure fence count.
  defp emit_fenced_out(run_id, tenant_id, reason) do
    :telemetry.execute(
      [:jido_claw, :orchestration, :fenced_out],
      %{count: 1},
      %{
        run_id: run_id,
        tenant_id: tenant_id,
        node: WorkflowLease.node_identity(),
        reason: reason
      }
    )
  end

  defp cluster_enabled?, do: Application.get_env(:jido_claw, :cluster_enabled, false)

  # Test seam for `stamp/4` only: forcing a real `{:error, _}` would need a Postgrex
  # error that poisons the shared sandbox transaction, and the project has no Mox.
  # No config sets `:workflow_lease_module`, so prod resolves to `WorkflowLease`.
  defp lease_module, do: Application.get_env(:jido_claw, :workflow_lease_module, WorkflowLease)
end
