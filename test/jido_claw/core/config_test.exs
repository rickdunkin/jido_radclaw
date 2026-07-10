defmodule JidoClaw.ConfigTest do
  @moduledoc """
  Config accessors that aren't covered by the loader's own tests, plus the
  two-lane read contract: `read_user_config/1` (strict — a present-but-broken
  `.jido/config.yaml` fails CLOSED, only `:enoent` reads as absent, and the
  map comes back RAW/unmerged) vs. `load/1` (tolerant — every read/parse
  failure collapses to the defaults for boot/wizard surfaces).
  """
  use ExUnit.Case, async: true

  alias JidoClaw.Config

  defp project!(yaml_or_nil) do
    dir = Path.join(System.tmp_dir!(), "jido_cfg_#{System.unique_integer([:positive])}")

    if yaml_or_nil do
      File.mkdir_p!(Path.join(dir, ".jido"))
      File.write!(Path.join([dir, ".jido", "config.yaml"]), yaml_or_nil)
    else
      File.mkdir_p!(dir)
    end

    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  test "mcp_servers/1 defaults to [] and passes a list through" do
    assert Config.mcp_servers(%{}) == []
    assert Config.mcp_servers(%{"mcp_servers" => "not-a-list"}) == []

    servers = [%{"name" => "s", "transport" => "stdio", "command" => "x"}]
    assert Config.mcp_servers(%{"mcp_servers" => servers}) == servers
  end

  describe "vfs_mounts/1" do
    test "normalizes absent, list, and single-map mount collections" do
      assert {:ok, []} = Config.vfs_mounts(%{})
      assert {:ok, []} = Config.vfs_mounts(%{"vfs" => %{}})

      mounts = [%{"path" => "/publish", "adapter" => "github"}]
      assert {:ok, ^mounts} = Config.vfs_mounts(%{"vfs" => %{"mounts" => mounts}})

      [mount] = mounts
      assert {:ok, [^mount]} = Config.vfs_mounts(%{vfs: %{mounts: mount}})
    end

    test "contains malformed vfs and mounts containers as typed errors" do
      assert {:error, :invalid_vfs_config} = Config.vfs_mounts(%{"vfs" => "not-a-map"})
      assert {:error, :invalid_vfs_config} = Config.vfs_mounts(%{"vfs" => nil})

      assert {:error, :invalid_vfs_mounts} =
               Config.vfs_mounts(%{"vfs" => %{"mounts" => "not-a-collection"}})
    end
  end

  describe "read_user_config/1 (the strict lane)" do
    test "an absent file (or .jido dir) is {:ok, %{}} — nothing configured" do
      assert {:ok, %{}} == Config.read_user_config(project!(nil))
    end

    test "valid YAML returns the RAW map — no defaults merged" do
      dir = project!("provider: anthropic\n")

      assert {:ok, config} = Config.read_user_config(dir)
      assert config == %{"provider" => "anthropic"}
      refute Map.has_key?(config, "providers")
    end

    test "an empty file is {:ok, %{}} — parse succeeded, provably no keys" do
      assert {:ok, %{}} == Config.read_user_config(project!(""))
    end

    test "malformed YAML fails closed" do
      dir = project!("review:\n  independence: [\n")

      assert {:error, msg} = Config.read_user_config(dir)
      assert msg =~ "parse"
      assert msg =~ "config.yaml"
    end

    test "a non-map root fails closed, describing the type only" do
      dir = project!("- a\n- b\n")

      assert {:error, msg} = Config.read_user_config(dir)
      assert msg =~ "must be a map"
      # The type word, never the value — a whole-file dump could carry secrets.
      refute msg =~ "- a"
    end

    test "an unreadable path (config.yaml as a directory) fails closed" do
      dir = project!(nil)
      File.mkdir_p!(Path.join([dir, ".jido", "config.yaml"]))

      assert {:error, msg} = Config.read_user_config(dir)
      assert msg =~ "cannot read"
    end
  end

  describe "load/1 tolerance (the boot/wizard lane)" do
    test "an absent file collapses to the defaults" do
      config = Config.load(project!(nil))
      assert Config.provider(config) == "ollama"
    end

    test "malformed YAML collapses to the defaults" do
      config = Config.load(project!("review:\n  independence: [\n"))
      assert Config.provider(config) == "ollama"
    end

    test "a non-map root collapses to the defaults" do
      # The one mapping where read_user_config errors but load must still
      # collapse byte-identically to the pre-refactor behavior.
      config = Config.load(project!("- a\n- b\n"))
      assert Config.provider(config) == "ollama"
    end
  end
end
