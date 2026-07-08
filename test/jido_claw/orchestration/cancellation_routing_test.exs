defmodule JidoClaw.Orchestration.CancellationRoutingTest do
  @moduledoc """
  WS5 — the pure cross-node kill-routing decision,
  `Cancellation.resolve_kill_target/3`. Driven with synthetic identity strings
  + atom node lists (a single BEAM cannot make `node(pid)` return a remote name,
  so the resolver is tested in isolation, exactly like `Cluster.Leader.elect/1`).

  The actual `GenServer.cast({RunTerminator, remote_node}, …)` *delivery* to a
  genuinely remote node is proven by WS6's `:peer` multi-node
  `JidoClaw.Cluster.CrossNodeCancelTest` — out of scope here.
  """
  use ExUnit.Case, async: true

  alias JidoClaw.Orchestration.Cancellation

  describe "resolve_kill_target/3" do
    test "nil claimed_by (unclaimed) resolves :local" do
      assert Cancellation.resolve_kill_target(nil, "a@h", [:b@h, :c@h]) == :local
    end

    test "claimed_by matching this node's identity resolves :local" do
      assert Cancellation.resolve_kill_target("a@h", "a@h", [:b@h, :c@h]) == :local
    end

    test "claimed_by matching a connected remote node resolves {:remote, node}" do
      assert Cancellation.resolve_kill_target("b@h", "a@h", [:b@h, :c@h]) == {:remote, :b@h}
    end

    test "claimed_by matching neither self nor a connected node resolves :unroutable" do
      assert Cancellation.resolve_kill_target("ghost@h", "a@h", [:b@h, :c@h]) == :unroutable
    end

    test "a stale claim with no connected nodes resolves :unroutable" do
      assert Cancellation.resolve_kill_target("b@h", "a@h", []) == :unroutable
    end
  end
end
