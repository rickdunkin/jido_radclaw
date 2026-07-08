defmodule JidoClaw.Cluster.CrossNodeCancelTest do
  @moduledoc """
  WS6 Phase 3, Proof 1 — cross-node cancellation across REAL BEAM nodes (WS5):
  peer B owns and is mid-step in a leased run; the cancel lands on peer A (the
  NON-owner); A appends the durable `run_cancelled` first, then routes the kill
  `{:remote, node_b}` — a `GenServer.cast` to B's `RunTerminator`, which kills
  B's executor locally (tenant-pinned). The executor disappearing on B is the
  cast-*delivery* proof the single-BEAM suites left as IOUs
  (`cancellation_routing_test.exs`, `run_terminator_test.exs` — one BEAM can
  neither resolve `{:remote, _}` for itself nor receive a remote cast).

  No kill, no overrides: `RunTerminator` is ungated/always-on, and no lease
  expiry is involved — the durable decision, not the lease, ends the run.
  """

  use JidoClaw.ClusterCase, async: false

  import JidoClaw.Cluster.PollHelpers, only: [await_executor_gone!: 2, await_run!: 2]

  alias JidoClaw.Cluster.RunFixtures
  alias JidoClaw.Orchestration.Cancellation
  alias JidoClaw.Orchestration.RunExecution

  test "a cancel on the non-owner kills the owner's executor via the terminator route", ctx do
    %{node_a: node_a, node_b: node_b} = ctx

    assert {:ok, run_id} = call(node_b, RunFixtures, :launch_blocking, [ctx.ctx], 30_000)
    neutralize_leaked_executor_on_exit(ctx.nodes, run_id, ctx.tenant)

    # B owns the lease, is mid-step, and holds a LIVE registered executor —
    # the thing Phase 2's stale-fence proof could never kill remotely (its
    # executor was already dead when the kill-cast fired).
    await_run!(run_id, &(&1.claimed_by == to_string(node_b) and &1.status == :running))
    assert {:ok, _pid, _tenant} = call(node_b, RunExecution, :lookup, [run_id])

    # Cancel on A, the non-owner: durable `run_cancelled` appended on A first,
    # then `resolve_kill_target(claimed_by_B, self_A, nodes)` → {:remote, B} →
    # cast to B's RunTerminator → `RunExecution.kill_local/2` there.
    assert {:ok, %WorkflowRun{status: :cancelled}} =
             call(
               node_a,
               Cancellation,
               :cancel,
               [run_id, [tenant: ctx.tenant, actor: ctx.actor, reason: "cross-node proof"]],
               30_000
             )

    # The delivery/promptness proof: B's registry entry is gone well before any
    # lease machinery could be involved (the lease never expires in this test).
    await_executor_gone!(node_b, run_id)

    # The durable decision is the guarantee: exactly one terminal, no failure
    # audit, and the lease frozen exactly as B last stamped it (no new stamp
    # can win once terminal).
    cancelled = reload_global(run_id)
    assert cancelled.status == :cancelled
    assert cancelled.claimed_by == to_string(node_b)
    assert kinds(run_id, ctx.ctx) == [:run_started, :step_started, :run_cancelled]

    # A cancelled run is not reclaim-fodder: `:claimable` selects only
    # non-terminal statuses, so a full drain on A touches nothing.
    assert 0 == call(node_a, ReclaimPooler, :reclaim_once, [], 30_000)
  end

  # Best-effort per-test hardening: if the cancel/kill choreography ever fails
  # mid-test, the blocking executor would outlive the test (truncation clears
  # rows, not processes) — kill it on every surviving node. Dead nodes raise;
  # swallowed.
  defp neutralize_leaked_executor_on_exit(nodes, run_id, tenant) do
    on_exit(fn ->
      Enum.each(nodes, fn node ->
        try do
          call(node, RunExecution, :kill_local, [run_id, tenant])
        catch
          _kind, _reason -> :ok
        end
      end)
    end)
  end
end
