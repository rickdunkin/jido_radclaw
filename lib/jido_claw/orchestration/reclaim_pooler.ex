defmodule JidoClaw.Orchestration.ReclaimPooler do
  @moduledoc """
  The always-on, per-node claim→dispatch loop for multi-node workflow reclaim (WS3).

  Where `JidoClaw.Orchestration.WorkflowRecovery` is the **boot** one-shot (single
  owning node, nothing live), this `GenServer` runs **continuously alongside live
  launches and executors** and drains the lease-expiry reclaim selector:

      reclaim_once():
        loop:
          case WorkflowLease.claim_next([]) do          # SAFE selector; rotates the token
            :none            -> halt
            {:ok, run}       -> emit [:..., :reclaimed]; WorkflowRecovery.reclaim(run); continue
            {:error, reason} -> log; halt (retry next poll)

  ## Always-on, every mode — because it is claim-gated

  `owns_reclaim?/0` is **just** `reclaim_enabled?/0` (default true; false in test) —
  it carries **no** `serve_mode`/`cluster_enabled` conditions, unlike
  `WorkflowRecovery.owns_recovery?/0`. The boot sweep excludes MCP/clustering because
  it is **unguarded** (concurrent owners would race a blind fail-all); the Pooler
  needs no exclusion because every claim is a `FOR UPDATE SKIP LOCKED` + token-CAS
  (`WorkflowLease.claim_next/1`). MCP launches workflows too (`run_skill` →
  `ReactorRunner.run`), so it MUST be covered. Single-node is safe for the same
  reason — the selector touches only provably-dead (expired-lease or aged
  never-claimed `:pending`) runs, and the `FOR UPDATE` + `:illegal`
  terminal-on-terminal guard makes any overlap with the boot one-shot idempotent;
  `initial_delay_ms` lets the boot one-shot win the first sweep.

  ## Testability

  `reclaim_once/0` is a **stateless module function** (drains to `:none`), so tests
  drive it directly inside the Ecto sandbox — exactly like
  `WorkflowRecovery.reconcile_all/0`. `enabled?: false` in test config keeps the live
  poll loop from racing a test in its own scope.

  ## Telemetry

  `[:jido_claw, :orchestration, :reclaimed]` fires once per claim (the Pooler's own
  event); the per-run **disposition** rides the existing
  `[:jido_claw, :orchestration, :recovered]` branch event emitted inside
  `WorkflowRecovery`.
  """

  use GenServer

  require Logger

  alias JidoClaw.Orchestration.WorkflowLease
  alias JidoClaw.Orchestration.WorkflowRecovery

  @default_poll_interval_ms 15_000
  @default_initial_delay_ms 5_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl GenServer
  def init(_opts) do
    if owns_reclaim?() do
      Process.send_after(self(), :poll, initial_delay_ms())
      {:ok, %{}}
    else
      # Self-gate: not the reclaim owner (disabled — e.g. in test) ⇒ no process.
      :ignore
    end
  end

  @impl GenServer
  def handle_info(:poll, state) do
    # Like boot's `reconcile_all/0`, the sweep is not wrapped — `reclaim/1` and its
    # callees handle their own errors (log + leave the run for the next poll). A rare
    # genuine crash just restarts the `:permanent` GenServer (re-arming after
    # `initial_delay_ms`); it can't spin, because `claim_next/1` already stamped the
    # just-claimed run a fresh lease, so a poison run is not re-claimable for a full
    # lease window.
    reclaim_once()
    Process.send_after(self(), :poll, poll_interval_ms())
    {:noreply, state}
  end

  @doc """
  Drain the reclaim selector to `:none`, routing each claimed run through
  `WorkflowRecovery.reclaim/2` (with the pre-rotation `prior_owner` for the C-H1
  kill-cast), and return the number of runs reclaimed this sweep.

  A stateless module function (like `WorkflowRecovery.reconcile_all/0`) so tests
  drive it directly. Tracks the ids processed this sweep: if `claim_next/1` ever
  returns one already seen — a release-on-defer cooldown that didn't push the expiry
  past this drain — it HALTS rather than re-claiming it, a belt-and-suspenders
  backstop (atop the cooldown itself) against a claim→defer→claim hot-loop.
  """
  @spec reclaim_once() :: non_neg_integer()
  def reclaim_once, do: drain([], 0)

  # `seen` is a plain list (a sweep handles a handful of runs — O(n) membership is
  # fine, and it sidesteps MapSet's opaque-type friction with Dialyzer through the
  # recursion).
  defp drain(seen, count) do
    case WorkflowLease.claim_next([]) do
      :none ->
        count

      {:ok, run, prior_owner} ->
        if run.id in seen do
          # Looped back to an already-handled run (its deferred-cooldown release did
          # not apply) — stop the drain to avoid a spin; the next poll retries.
          count
        else
          emit_reclaimed(run)
          WorkflowRecovery.reclaim(run, prior_owner)
          drain([run.id | seen], count + 1)
        end

      {:error, reason} ->
        Logger.warning(
          "[ReclaimPooler] claim_next failed: #{inspect(reason)}; halting this sweep"
        )

        count
    end
  end

  defp emit_reclaimed(run) do
    :telemetry.execute(
      [:jido_claw, :orchestration, :reclaimed],
      %{count: 1},
      %{
        run_id: run.id,
        tenant_id: run.tenant_id,
        prior_status: run.status,
        workflow_type: run.workflow_type
      }
    )
  end

  @doc "Re-poll cadence in ms (config `:reclaim_pooler[:poll_interval_ms]`, default 15_000)."
  @spec poll_interval_ms() :: pos_integer()
  def poll_interval_ms, do: config()[:poll_interval_ms] || @default_poll_interval_ms

  defp initial_delay_ms, do: config()[:initial_delay_ms] || @default_initial_delay_ms

  # Gate: enabled (default true; false in test). Deliberately a one-liner with NO
  # serve_mode/cluster conditions (the moduledoc explains why) — distinct from
  # `WorkflowRecovery.owns_recovery?/0`.
  defp owns_reclaim?, do: reclaim_enabled?()

  defp reclaim_enabled?, do: config()[:enabled?] != false

  defp config, do: Application.get_env(:jido_claw, :reclaim_pooler, [])
end
