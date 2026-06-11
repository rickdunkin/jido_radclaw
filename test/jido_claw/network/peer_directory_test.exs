defmodule JidoClaw.Network.PeerDirectoryTest do
  # Mutates the :network_peer_keys app env and the JIDOCLAW_NETWORK_PEERS
  # system env — must not interleave with other tests reading them.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias JidoClaw.Agent.Identity
  alias JidoClaw.Network.PeerDirectory

  setup do
    restore_app_env(:network_peer_keys)
    restore_system_env("JIDOCLAW_NETWORK_PEERS")

    Application.delete_env(:jido_claw, :network_peer_keys)
    System.delete_env("JIDOCLAW_NETWORK_PEERS")
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

  defp generate_pub do
    {pub, _priv} = Identity.generate_keypair()
    pub
  end

  describe "configured?/0" do
    test "false when neither source is set" do
      refute PeerDirectory.configured?()
    end

    test "false for an empty list / blank env var" do
      Application.put_env(:jido_claw, :network_peer_keys, [])
      refute PeerDirectory.configured?()

      Application.delete_env(:jido_claw, :network_peer_keys)
      System.put_env("JIDOCLAW_NETWORK_PEERS", "  ,  ")
      refute PeerDirectory.configured?()
    end

    test "false when only invalid entries are configured" do
      Application.put_env(:jido_claw, :network_peer_keys, [
        "%%%not-base64%%%",
        Base.encode64(:crypto.strong_rand_bytes(16))
      ])

      capture_log(fn -> refute PeerDirectory.configured?() end)
    end

    test "true with at least one valid key" do
      Application.put_env(:jido_claw, :network_peer_keys, [Base.encode64(generate_pub())])
      assert PeerDirectory.configured?()
    end
  end

  describe "fetch/1" do
    test "round-trips a configured key by derived agent id" do
      pub = generate_pub()
      Application.put_env(:jido_claw, :network_peer_keys, [Base.encode64(pub)])

      assert {:ok, ^pub} = PeerDirectory.fetch(Identity.derive_agent_id(pub))
    end

    test "returns :error for an unknown agent id" do
      Application.put_env(:jido_claw, :network_peer_keys, [Base.encode64(generate_pub())])

      assert :error = PeerDirectory.fetch("jido_stranger")
    end

    test "skips invalid entries with a warning while a valid sibling still resolves" do
      pub = generate_pub()

      Application.put_env(:jido_claw, :network_peer_keys, [
        "%%%not-base64%%%",
        Base.encode64(:crypto.strong_rand_bytes(16)),
        Base.encode64(pub)
      ])

      log =
        capture_log(fn ->
          assert {:ok, ^pub} = PeerDirectory.fetch(Identity.derive_agent_id(pub))
        end)

      assert log =~ "Skipping invalid peer key entry"
    end

    test "app env takes precedence over JIDOCLAW_NETWORK_PEERS" do
      pub_app = generate_pub()
      pub_env = generate_pub()

      System.put_env("JIDOCLAW_NETWORK_PEERS", Base.encode64(pub_env))
      Application.put_env(:jido_claw, :network_peer_keys, [Base.encode64(pub_app)])

      assert {:ok, ^pub_app} = PeerDirectory.fetch(Identity.derive_agent_id(pub_app))
      assert :error = PeerDirectory.fetch(Identity.derive_agent_id(pub_env))
    end

    test "env var parses comma-separated entries with surrounding whitespace" do
      pub1 = generate_pub()
      pub2 = generate_pub()

      System.put_env(
        "JIDOCLAW_NETWORK_PEERS",
        " #{Base.encode64(pub1)} , #{Base.encode64(pub2)} ,"
      )

      assert {:ok, ^pub1} = PeerDirectory.fetch(Identity.derive_agent_id(pub1))
      assert {:ok, ^pub2} = PeerDirectory.fetch(Identity.derive_agent_id(pub2))
      assert PeerDirectory.configured?()
    end
  end
end
