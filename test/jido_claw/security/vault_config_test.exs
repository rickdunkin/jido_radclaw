defmodule JidoClaw.Security.VaultConfigTest do
  use ExUnit.Case, async: false

  alias JidoClaw.Security.Vault
  alias JidoClaw.Security.VaultConfig

  @key Base.encode64(String.duplicate("k", 32))

  setup do
    old_config = Application.get_env(:jido_claw, Vault)
    old_env = System.get_env("CLOAK_KEY")
    old_file = System.get_env("CLOAK_KEY_FILE")

    on_exit(fn ->
      restore_app_env(old_config)
      restore_system_env("CLOAK_KEY", old_env)
      restore_system_env("CLOAK_KEY_FILE", old_file)
    end)

    Application.delete_env(:jido_claw, Vault)
    System.delete_env("CLOAK_KEY")
    System.delete_env("CLOAK_KEY_FILE")

    :ok
  end

  test "configures the vault from CLOAK_KEY" do
    System.put_env("CLOAK_KEY", @key)

    assert :ok = VaultConfig.ensure_configured!()
    assert VaultConfig.configured?()
  end

  test "configures the vault from CLOAK_KEY_FILE" do
    path = Path.join(System.tmp_dir!(), "jidoclaw-cloak-#{System.unique_integer([:positive])}")
    File.write!(path, @key <> "\n")
    System.put_env("CLOAK_KEY_FILE", path)

    on_exit(fn -> File.rm(path) end)

    assert :ok = VaultConfig.ensure_configured!()
    assert VaultConfig.configured?()
  end

  test "raises when no runtime key is available" do
    missing = Path.join(System.tmp_dir!(), "jidoclaw-missing-cloak-key")
    System.put_env("CLOAK_KEY_FILE", missing)

    assert_raise RuntimeError, ~r/CLOAK_KEY is required/, fn ->
      VaultConfig.ensure_configured!()
    end
  end

  test "raises when the runtime key has an invalid length" do
    System.put_env("CLOAK_KEY", Base.encode64("too-short"))

    assert_raise RuntimeError, ~r/invalid_key_length/, fn ->
      VaultConfig.ensure_configured!()
    end
  end

  defp restore_app_env(nil), do: Application.delete_env(:jido_claw, Vault)
  defp restore_app_env(config), do: Application.put_env(:jido_claw, Vault, config)

  defp restore_system_env(name, nil), do: System.delete_env(name)
  defp restore_system_env(name, value), do: System.put_env(name, value)
end
