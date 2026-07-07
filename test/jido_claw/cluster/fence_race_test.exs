defmodule JidoClaw.Cluster.FenceRaceTest do
  @moduledoc """
  The WS1 fence race across REAL BEAM nodes — the cross-BEAM proof the
  single-BEAM lease suite's moduledoc left as an IOU. One claimable run in the
  shared DB, two peers race the claim, and the DB decides
  (`FOR UPDATE SKIP LOCKED` + token CAS): exactly one winner, the loser never
  executes. No kill, no expiry, no timing window.

  The smoke test is deliberately separate so a harness failure (boot, mesh,
  shared DB, `:pg`) never masquerades as a fence-race failure, and the bare
  claim race (test 2) is separate from the production reclaim path (test 3):
  if 2 is green and 3 is red, the bug is in reclaim/recovery, not the claim.
  """

  use JidoClaw.ClusterCase, async: false

  describe "harness smoke" do
    test "peers run the app, mesh, share the DB, and agree on a :pg leader", ctx do
      %{node_a: node_a, node_b: node_b, nodes: nodes} = ctx

      for node <- nodes do
        assert {:ok, _apps} = call(node, Application, :ensure_all_started, [:jido_claw])
      end

      assert node_b in call(node_a, Node, :list, [])
      assert node_a in call(node_b, Node, :list, [])

      run = seed_run(ctx.ctx)

      assert {:ok, %WorkflowRun{id: fetched_id}} =
               call(node_a, WorkflowRun, :by_id_global, [run.id])

      assert fetched_id == run.id

      # Black-box :pg propagation proof via the public API (the Leader's :pg
      # group name is private — don't reach into it): cross-peer leader
      # agreement is only possible once the :jido_claw scope synced over the
      # peer-to-peer mesh.
      assert :ok =
               await(
                 fn ->
                   leader_a = call(node_a, JidoClaw.Cluster, :leader, [])
                   leader_b = call(node_b, JidoClaw.Cluster, :leader, [])
                   leader_a != nil and leader_a == leader_b
                 end,
                 30_000
               )

      leaders = Enum.filter(nodes, &call(&1, JidoClaw.Cluster, :leader?, []))
      assert [_exactly_one_leader] = leaders
    end
  end

  describe "claim race (the WS1 primitive)" do
    test "exactly one peer claims; the loser sees :none; nothing executes", ctx do
      run = seed_run(ctx.ctx)
      backdate_inserted!(run.id, WorkflowLease.pending_grace_seconds() + 60)

      results = race([ctx.node_a, ctx.node_b], WorkflowLease, :claim_next, [[]])

      pairs = Enum.zip([ctx.node_a, ctx.node_b], results)

      {wins, losses} =
        Enum.split_with(pairs, fn {_node, result} -> match?({:ok, _, _}, result) end)

      # Any interleaving lands here: row-locked ⇒ SKIP LOCKED ⇒ :none; already
      # rotated ⇒ fresh lease ⇒ not claimable.
      assert [{winner_node, {:ok, won, nil}}] = wins
      assert [{_loser_node, :none}] = losses

      reloaded = reload_global(run.id)
      assert reloaded.claimed_by == to_string(winner_node)
      assert reloaded.claim_token == won.claim_token
      assert reloaded.status == :pending
      assert kinds(run.id, ctx.ctx) == []
    end
  end

  describe "reclaim race (the production path)" do
    test "claim then reclaim disposes the run exactly once across peers", ctx do
      run = seed_run(ctx.ctx)
      backdate_inserted!(run.id, WorkflowLease.pending_grace_seconds() + 60)

      counts = race([ctx.node_a, ctx.node_b], ReclaimPooler, :reclaim_once, [])

      # Decisive winner/loser straight from the return values.
      assert Enum.sort(counts) == [0, 1]

      assert reload_global(run.id).status == :failed
      assert kinds(run.id, ctx.ctx) == [:run_recovered, :run_failed]
    end
  end

  # Fire the same MFA on every node concurrently and collect results in node
  # order — the race primitive shared by tests 2 and 3.
  defp race(nodes, module, fun, args) do
    nodes
    |> Enum.map(fn node -> Task.async(fn -> call(node, module, fun, args, 30_000) end) end)
    |> Task.await_many(60_000)
  end
end
