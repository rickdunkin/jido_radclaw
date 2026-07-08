defmodule JidoClaw.Cluster.LeaderElectionTest do
  @moduledoc """
  WS6 Phase 3, Proof 2 — `:pg` leader election across REAL BEAM nodes (WS4):
  both peers agree on one leader (the fence-race smoke already proves that
  cross-BEAM agreement); the novel content is RE-ELECTION on a real
  leader-node death — genuine remote `node(pid)` over `:pg`, impossible
  single-BEAM (`leader_test.exs` drives the reducer with synthetic name
  lists). The leader is computed dynamically (lowest-name-wins is the
  algorithm, but the per-run unique peer names make hardcoding a winner
  meaningless).

  EXACTLY ONE test: it kills the leader peer, and peers live for the whole
  module.
  """

  use JidoClaw.ClusterCase, async: false

  # Local imports REPLACE the using-quote's import of the same module (last
  # directive wins), so this list carries everything this module uses.
  import JidoClaw.Cluster.PeerHarness, only: [await: 2, call: 4, kill_peer: 1]

  alias JidoClaw.Cluster

  test "peers agree on one leader; the survivor re-elects on the leader's death", ctx do
    %{nodes: nodes, peers: peers} = ctx

    # Both peers converge on the same non-nil leader once the :pg scope syncs
    # over the mesh (event-driven; the await is only for propagation).
    assert :ok =
             await(
               fn ->
                 leaders = Enum.map(nodes, &call(&1, Cluster, :leader, []))
                 Enum.all?(leaders, &(&1 != nil)) and match?([_], Enum.uniq(leaders))
               end,
               30_000
             )

    # Exactly one node self-identifies as leader, and it is the agreed one.
    leader_node = call(hd(nodes), Cluster, :leader, [])
    assert [^leader_node] = Enum.filter(nodes, &call(&1, Cluster, :leader?, []))

    survivor = Enum.find(nodes, &(&1 != leader_node))
    leader_peer = Enum.find(peers, &(&1.node == leader_node))

    kill_peer(leader_peer)

    # Re-election is event-driven — the dead node's :pg membership drops
    # (nodedown → :leave → `recompute/2`), and the survivor elects itself.
    assert :ok =
             await(
               fn ->
                 call(survivor, Cluster, :leader, []) == survivor and
                   call(survivor, Cluster, :leader?, [])
               end,
               30_000
             )
  end
end
