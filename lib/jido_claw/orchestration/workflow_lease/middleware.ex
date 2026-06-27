defmodule JidoClaw.Orchestration.WorkflowLease.Middleware do
  @moduledoc """
  The `Reactor.Middleware` that claims a run's durable lease at execution start.

  `init/1` is the **only** callback (cleanup is monitor-driven by the
  `Sidecar`). The runner normalizes the middleware list to
  `[WorkflowLease.Middleware, ReactorMiddleware | rest]`, so this `init/1` runs
  **first** — the row is stamped at `:pending`, before `ReactorMiddleware`
  appends `run_started`. A crash in the gap therefore leaves a clean
  `:pending` + claimed + expiry row (which `:claimable` selects), never an
  ambiguous `:running`-unclaimed crack.

  The stamp is a **compare-and-swap on the prior token** (`WorkflowLease.stamp/4`),
  reached only by the process that won `RunRegistry` registration
  (`RunExecution.run_killable/4`). So a same-node duplicate never stamps, and a
  cross-node duplicate that does reach here loses the CAS (`{:ok, :lost}`) and
  aborts with no terminal — fence A maps `{:lease_lost, _}` to the clean
  no-terminal envelope.

  ## Degraded vs fail-closed

  A claim/sidecar failure (`{:error, _}` from the DB, or a sidecar that won't
  arm) **fails closed under clustering** — `{:error, _}` aborts the run before
  any step — but **degrades** single-node (`cluster_enabled: false`): it logs
  and proceeds unleased, byte-identical to the pre-lease world. A `{:ok, :lost}`
  aborts in **either** mode (someone else, or a terminal, owns the row).

  A context with no `:claim_token` (a degraded/legacy caller) is a no-op
  `{:ok, ctx}` — byte-identical.
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
    case WorkflowLease.stamp(id, token, run.claim_token, tenant: tid) do
      {:ok, :claimed} ->
        # Readiness is part of the claim — a dead sidecar means an unmonitored
        # executor, which fence-from-the-outside cannot stop.
        case WorkflowLease.start_sidecar(self(), id, tid, token) do
          :ok -> {:ok, ctx}
          {:error, reason} -> fail_or_degrade({:lease_sidecar, reason}, ctx)
        end

      # Another owner — OR a terminal/parked row — landed first. Abort regardless
      # of mode; fence A turns `{:lease_lost, _}` into a no-terminal stop.
      {:ok, :lost} ->
        {:error, {:lease_lost, id}}

      {:error, reason} ->
        fail_or_degrade({:lease_claim, reason}, ctx)
    end
  end

  # No token (degraded/legacy caller) → unleased, byte-identical.
  def init(ctx), do: {:ok, ctx}

  # Under clustering a claim that can't be made safe must abort; single-node has
  # no contender, so it logs and runs unleased (the WS3 reclaim loop is the net).
  defp fail_or_degrade(reason, ctx) do
    if cluster_enabled?() do
      {:error, reason}
    else
      Logger.warning(
        "[WorkflowLease] degraded (single-node), running unleased: #{inspect(reason)}"
      )

      {:ok, ctx}
    end
  end

  defp cluster_enabled?, do: Application.get_env(:jido_claw, :cluster_enabled, false)
end
