defmodule JidoClaw.ClusterTest do
  # Mutates :cluster_strategy/:cluster_secret app env and the
  # JIDOCLAW_CLUSTER_SECRET system env — must not interleave with other
  # tests reading them.
  use ExUnit.Case, async: false

  alias JidoClaw.Cluster

  setup do
    restore_app_env(:cluster_strategy)
    restore_app_env(:cluster_secret)
    restore_system_env("JIDOCLAW_CLUSTER_SECRET")
    :ok
  end

  defp restore_app_env(key) do
    original = Application.fetch_env(:jido_claw, key)

    on_exit(fn ->
      case original do
        {:ok, value} -> Application.put_env(:jido_claw, key, value)
        :error -> Application.delete_env(:jido_claw, key)
      end
    end)
  end

  defp restore_system_env(var) do
    original = System.get_env(var)

    on_exit(fn ->
      case original do
        nil -> System.delete_env(var)
        value -> System.put_env(var, value)
      end
    end)
  end

  # Unset both secret sources. The runner shell may carry
  # JIDOCLAW_CLUSTER_SECRET — delete it so missing-secret tests
  # actually exercise the missing branch.
  defp clear_secret do
    Application.delete_env(:jido_claw, :cluster_secret)
    System.delete_env("JIDOCLAW_CLUSTER_SECRET")
  end

  defp gossip_config(topology) do
    topology[:jido_claw][:config]
  end

  describe "topology/0 with :gossip strategy" do
    test "includes the configured secret" do
      Application.put_env(:jido_claw, :cluster_strategy, :gossip)
      Application.put_env(:jido_claw, :cluster_secret, "s3cret")

      config = gossip_config(Cluster.topology())

      assert config[:secret] == "s3cret"
      assert Keyword.fetch!(config, :port) == 45_892
    end

    test "falls back to the JIDOCLAW_CLUSTER_SECRET env var" do
      Application.put_env(:jido_claw, :cluster_strategy, :gossip)
      Application.delete_env(:jido_claw, :cluster_secret)
      System.put_env("JIDOCLAW_CLUSTER_SECRET", "  env-secret  ")

      assert gossip_config(Cluster.topology())[:secret] == "env-secret"
    end

    test "raises an actionable error when no secret is configured" do
      Application.put_env(:jido_claw, :cluster_strategy, :gossip)
      clear_secret()

      assert_raise RuntimeError, ~r/JIDOCLAW_CLUSTER_SECRET/, fn -> Cluster.topology() end
    end

    test "treats a blank secret as missing" do
      Application.put_env(:jido_claw, :cluster_strategy, :gossip)
      clear_secret()
      Application.put_env(:jido_claw, :cluster_secret, "   ")

      assert_raise RuntimeError, ~r/JIDOCLAW_CLUSTER_SECRET/, fn -> Cluster.topology() end
    end
  end

  describe "topology/0 unknown-strategy fallback" do
    test "defaults to gossip with the configured secret" do
      Application.put_env(:jido_claw, :cluster_strategy, :wat)
      Application.put_env(:jido_claw, :cluster_secret, "s3cret")

      topology = Cluster.topology()

      assert topology[:jido_claw][:strategy] == Elixir.Cluster.Strategy.Gossip
      assert gossip_config(topology)[:secret] == "s3cret"
    end

    test "raises when no secret is configured" do
      Application.put_env(:jido_claw, :cluster_strategy, :wat)
      clear_secret()

      assert_raise RuntimeError, ~r/JIDOCLAW_CLUSTER_SECRET/, fn -> Cluster.topology() end
    end
  end

  describe "topology/0 non-gossip strategies" do
    test ":none returns an empty topology" do
      Application.put_env(:jido_claw, :cluster_strategy, :none)
      clear_secret()

      assert Cluster.topology() == []
    end

    test ":epmd builds an Epmd strategy with hosts and no secret requirement" do
      Application.put_env(:jido_claw, :cluster_strategy, :epmd)
      clear_secret()

      topology = Cluster.topology()

      assert topology[:jido_claw][:strategy] == Elixir.Cluster.Strategy.Epmd
      assert Keyword.has_key?(topology[:jido_claw][:config], :hosts)
    end
  end
end
