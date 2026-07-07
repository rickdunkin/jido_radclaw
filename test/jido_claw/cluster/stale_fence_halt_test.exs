defmodule JidoClaw.Cluster.StaleFenceHaltTest do
  @moduledoc """
  WS6 Phase 2, Proof B — the WS1 stale-fence halt across REAL BEAM nodes: the
  cross-node lift of `reclaim_pooler_test.exs`'s intra-node fence test. Peer B
  is actively executing a leased run; its fence token is rotated out from
  under it (the documented reclaimer-steal seed — racing a genuine cross-node
  claim against a healthy 1s renew cadence is inherently flaky, so the steal
  is staged and the follow-up reclaim is real); B's sidecar's next REAL renew
  (≤1s cadence, pushed to peers via `peer_overrides`) sees 0 rows and kills
  the executor with NO terminal (fence A); a follow-up reclaim on peer A
  writes the single terminal (fence B honors the rotated token).

  The production sequence — rotate → fence-kill → reclaim disposition — is
  preserved end-to-end; only the rotation itself is seeded.
  """

  use JidoClaw.ClusterCase,
    async: false,
    peer_overrides: [
      workflow_lease: [lease_seconds: 5, renew_seconds: 1, pending_grace_seconds: 60]
    ]

  import JidoClaw.Cluster.PollHelpers, only: [await_executor_gone!: 2, await_run!: 2]

  # A later `import Mod, only:` REPLACES the using-quote's import of the same
  # module (last directive wins), so this list carries EVERYTHING this module
  # uses from LeaseHelpers — the shared readers included.
  import JidoClaw.Orchestration.LeaseHelpers,
    only: [expire_claim!: 1, kinds: 2, reload_global: 1, rotate_token!: 2]

  alias JidoClaw.Cluster.RunFixtures
  alias JidoClaw.Orchestration.RunExecution

  test "a fenced-out executor halts with no terminal; the reclaimer writes the only one", ctx do
    %{node_a: node_a, node_b: node_b} = ctx

    assert {:ok, run_id} = call(node_b, RunFixtures, :launch_blocking, [ctx.ctx], 30_000)
    neutralize_leaked_executor_on_exit(ctx.nodes, run_id, ctx.tenant)

    # B owns the lease and is mid-step (the step_started append is already
    # durable when launch_blocking returns; the claim columns follow within a
    # renew tick).
    await_run!(run_id, &(&1.claimed_by == to_string(node_b) and &1.status == :running))

    # A reclaimer stole the token. B's next real renew returns {:ok, 0} — a
    # clean fence decision, not an {:error, _} (so no @retry_ms back-off) —
    # and the sidecar kills the executor within ~1 renew tick.
    stolen = Ecto.UUID.generate()
    rotate_token!(run_id, stolen)
    await_executor_gone!(node_b, run_id)

    # Fence A: the fenced loser writes NO terminal — the run is left :running
    # and stranded for reclaim.
    fenced = reload_global(run_id)
    assert fenced.status == :running
    refute :run_failed in kinds(run_id, ctx.ctx)
    refute :run_completed in kinds(run_id, ctx.ctx)

    # Expire the stolen lease (keeps claimed_by = B and the rotated token) and
    # drive the production reclaim on peer A — exactly one run drained.
    expire_claim!(run_id)
    assert 1 == call(node_a, ReclaimPooler, :reclaim_once, [], 30_000)

    # Exactly one terminal total, written by the reclaimer. The reclaim's
    # kill-cast routes {:remote, node_b} — delivered but unobservable here,
    # B's executor being already dead; a cross-node kill of a LIVE executor is
    # Phase 3's cancel proof.
    reclaimed = reload_global(run_id)
    assert reclaimed.status == :failed
    assert reclaimed.claimed_by == to_string(node_a)
    assert kinds(run_id, ctx.ctx) == [:run_started, :step_started, :run_recovered, :run_failed]
  end

  # Best-effort per-test hardening: if a fence/kill ever fails to fire, the
  # blocking executor would outlive the test (truncation clears rows, not
  # processes) — kill it on every surviving node. Dead nodes raise; swallowed.
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
