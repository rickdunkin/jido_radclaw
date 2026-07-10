defmodule JidoClaw.VFS.AdapterPolicyTest do
  use ExUnit.Case, async: true

  alias JidoClaw.VFS.AdapterPolicy

  test "parses exactly the adapters exposed through workspace config" do
    for key <- [:local, :in_memory, :github, :s3, :git] do
      assert {:ok, ^key} = AdapterPolicy.parse_config_key(key)
      assert {:ok, ^key} = AdapterPolicy.parse_config_key(Atom.to_string(key))
    end

    assert {:error, {:unknown_adapter, "sprite"}} =
             AdapterPolicy.parse_config_key("sprite")

    assert {:error, :invalid_adapter} = AdapterPolicy.parse_config_key(42)
  end

  test "only explicitly registered local modules bypass remote approval classification" do
    refute AdapterPolicy.module_remote?(Jido.VFS.Adapter.Local)
    refute AdapterPolicy.module_remote?(Jido.VFS.Adapter.InMemory)
    refute AdapterPolicy.module_remote?(Jido.VFS.Adapter.ETS)

    assert AdapterPolicy.module_remote?(Jido.VFS.Adapter.GitHub)
    assert AdapterPolicy.module_remote?(Jido.VFS.Adapter.S3)
    assert AdapterPolicy.module_remote?(Jido.VFS.Adapter.Git)
    assert AdapterPolicy.module_remote?(Jido.VFS.Adapter.Sprite)
    assert AdapterPolicy.module_remote?(__MODULE__.FutureAdapter)
  end

  test "unknown config adapters fail closed while known local adapters remain local" do
    refute AdapterPolicy.config_remote?(:local)
    refute AdapterPolicy.config_remote?("in_memory")
    assert AdapterPolicy.config_remote?("github")
    assert AdapterPolicy.config_remote?("future_remote")
    assert AdapterPolicy.config_remote?(nil)
  end

  test "remote URI recognition comes from the same registry" do
    assert AdapterPolicy.remote_uri?("github://owner/repo/file")
    assert AdapterPolicy.remote_uri?("s3://bucket/key")
    assert AdapterPolicy.remote_uri?("git:///repo//file")
    refute AdapterPolicy.remote_uri?("/project/local")
    refute AdapterPolicy.remote_uri?(nil)
  end
end
