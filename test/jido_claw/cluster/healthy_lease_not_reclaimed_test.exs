defmodule JidoClaw.Cluster.HealthyLeaseNotReclaimedTest do
  @moduledoc """
  WS6 Phase 3, Proof 3 — the WS3 rolling-deploy-overlap rider (OpenHelm dig,
  OH3-2): a rejoining/freshly-booted node must NOT reclaim runs whose lease is
  healthy merely because the node itself just booted. Peer A owns a leased run
  whose sidecar renews every 1s; peer B runs the reclaim pooler LOOP live
  (`enabled?: true`, 500ms poll, zero initial delay — polling exactly like a
  production node that just joined), and the run outlives a FULL original
  lease window untouched: still A's, same token, expiry advanced by renewal.

  The window is proven on the DB clock (`await_db_clock_past!/1` — every lease
  comparison in production is against `now()`), never the test BEAM's. No
  kill; the pooler's steady 0-drain IS the proof.
  """

  use JidoClaw.ClusterCase,
    async: false,
    peer_overrides: [
      workflow_lease: [lease_seconds: 5, renew_seconds: 1, pending_grace_seconds: 60],
      reclaim_pooler: [enabled?: true, poll_interval_ms: 500, initial_delay_ms: 0]
    ]

  import JidoClaw.Cluster.PollHelpers, only: [await_db_clock_past!: 1, await_run!: 2]

  alias JidoClaw.Cluster.RunFixtures
  alias JidoClaw.Orchestration.RunExecution

  test "a healthy 1s-renewing lease survives a full lease window of live peer polling", ctx do
    %{node_a: node_a} = ctx

    assert {:ok, run_id} = call(node_a, RunFixtures, :launch_blocking, [ctx.ctx], 30_000)
    neutralize_leaked_executor_on_exit(ctx.nodes, run_id, ctx.tenant)

    await_run!(run_id, &(&1.claimed_by == to_string(node_a) and &1.status == :running))
    stamped = reload_global(run_id)
    original_expiry = stamped.claim_expires_at

    # Outlive the whole original lease window (plus margin) on the DB clock,
    # with BOTH peers' pooler loops polling throughout — if boot-adjacent
    # polling could steal a healthy lease, this window is where it would.
    await_db_clock_past!(DateTime.add(original_expiry, 2, :second))

    # Untouched: still A's run, same token, executor still live on A — and the
    # expiry moved FORWARD past the original window (the 1s renewal cadence),
    # so the lease was live the entire time, not merely un-polled.
    survived = reload_global(run_id)
    assert survived.status == :running
    assert survived.claimed_by == to_string(node_a)
    assert survived.claim_token == stamped.claim_token
    assert DateTime.compare(survived.claim_expires_at, original_expiry) == :gt
    assert {:ok, _pid, _tenant} = call(node_a, RunExecution, :lookup, [run_id])

    # No recovery audit of any kind — the pooler never drained this run.
    assert kinds(run_id, ctx.ctx) == [:run_started, :step_started]
  end

  # Best-effort per-test hardening: the blocking executor outlives the test
  # (truncation clears rows, not processes) — kill it on every node.
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
