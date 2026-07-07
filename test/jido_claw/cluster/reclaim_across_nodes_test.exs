defmodule JidoClaw.Cluster.ReclaimAcrossNodesTest do
  @moduledoc """
  WS6 Phase 2, Proof A — reclaim across REAL BEAM nodes (WS1 + WS3): peer A
  launches a run and is mid-step; A dies ABRUPTLY (`kill_peer/1` — no
  `Application.stop`, nothing releases the lease); the stale lease row
  survives the death; after REAL lease expiry (the short windows pushed via
  `peer_overrides`) peer B reclaims and disposes the run per shipped WS3
  semantics — terminalize `:failed` with the `run_recovered` + `run_failed`
  audit pair, never re-execute a plain reactor (boot-parity Q1). True resume
  is Proof C (gated checkpoint) and Phase 3's composer proof.

  EXACTLY ONE test: it kills peer A, and peers live for the whole module.
  """

  use JidoClaw.ClusterCase,
    async: false,
    peer_overrides: [
      workflow_lease: [lease_seconds: 5, renew_seconds: 1, pending_grace_seconds: 60]
    ]

  # Local imports REPLACE the using-quote's import of the same module (last
  # directive wins), so each list carries everything this module uses.
  import JidoClaw.Cluster.PeerHarness, only: [call: 4, call: 5, kill_peer: 1]
  import JidoClaw.Cluster.PollHelpers, only: [await_reclaim!: 2, await_run!: 2]
  import JidoClaw.Orchestration.LeaseHelpers, only: [kinds: 2, reload_global: 1]

  alias JidoClaw.Cluster.RunFixtures
  alias JidoClaw.Orchestration.RunExecution

  test "a dead node's stale lease survives; the peer reclaims it to fail-with-audit", ctx do
    %{node_a: node_a, node_b: node_b, peers: [peer_a, _peer_b]} = ctx

    assert {:ok, run_id} = call(node_a, RunFixtures, :launch_blocking, [ctx.ctx], 30_000)
    neutralize_leaked_executor_on_exit(ctx.nodes, run_id, ctx.tenant)

    await_run!(run_id, &(&1.claimed_by == to_string(node_a) and &1.status == :running))
    stamped = reload_global(run_id)

    kill_peer(peer_a)

    # The stale lease survived the death (the WS6 doc's explicit requirement):
    # no terminal was written — the real proof of abruptness — and the claim
    # columns are exactly as A last stamped them. The expiry check is a soft
    # secondary (test-node clock vs DB now(); ≥4s margin at any kill instant).
    survived = reload_global(run_id)
    assert survived.status == :running
    assert survived.claimed_by == to_string(node_a)
    assert survived.claim_token == stamped.claim_token
    assert DateTime.compare(survived.claim_expires_at, DateTime.utc_now()) == :gt
    assert kinds(run_id, ctx.ctx) == [:run_started, :step_started]

    # Real expiry + reclaim on B: reclaim_once returns 0 until the DB clock
    # passes claim_expires_at, then drains exactly this one run. The reclaim's
    # kill-cast to the dead prior owner resolves :unroutable (a no-op).
    await_reclaim!(node_b, run_id)

    # The WS3 disposition: exactly one terminal, exactly one step_started —
    # nothing re-executed.
    reclaimed = reload_global(run_id)
    assert reclaimed.status == :failed
    assert reclaimed.claimed_by == to_string(node_b)
    assert kinds(run_id, ctx.ctx) == [:run_started, :step_started, :run_recovered, :run_failed]
  end

  # Best-effort per-test hardening: if the kill/reclaim choreography ever
  # fails mid-test, the blocking executor would outlive the test (truncation
  # clears rows, not processes) — kill it on every surviving node. Dead nodes
  # raise; swallowed.
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
