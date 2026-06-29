defmodule JidoClaw.ClusterLeaderStub do
  @moduledoc """
  Test stub for the `:cluster_leader_module` seam (WS4 leader gate).

  Install with
  `Application.put_env(:jido_claw, :cluster_leader_module, JidoClaw.ClusterLeaderStub)`
  and control the answer with
  `Application.put_env(:jido_claw, :cluster_leader_stub_result, true | false)`
  (default `true`). `JidoClaw.Cluster.leader?/0` then delegates here, so a gate
  test drives follower/leader behavior without a live `:pg` scope. Restore both
  app-env keys in `on_exit`.

  A single configurable module — not a `Leader`/`Follower` pair — so it cannot
  read as a `behaviour_candidate` smell.
  """

  @spec leader?() :: boolean()
  def leader?, do: Application.get_env(:jido_claw, :cluster_leader_stub_result, true)
end
