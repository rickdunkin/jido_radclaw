defmodule JidoClaw.Forge.Runners.ClaudeCodeTest do
  @moduledoc """
  Unit coverage for `JidoClaw.Forge.Runners.ClaudeCode`. Mirrors the
  Codex runner test shape — exercises `init/2` against a stub sandbox
  with `:claude_home_dir` and `:forge_home` injected via app env so
  filesystem effects stay confined to tmp dirs.
  """
  use ExUnit.Case, async: false

  alias JidoClaw.Forge.Runners.ClaudeCode
  alias JidoClaw.Test.StubSandbox

  setup do
    prev_claude = Application.get_env(:jido_claw, :claude_home_dir)
    prev_forge = Application.get_env(:jido_claw, :forge_home)

    on_exit(fn ->
      restore(:claude_home_dir, prev_claude)
      restore(:forge_home, prev_forge)
    end)

    :ok
  end

  describe "init/2 — :no_credentials" do
    test "returns {:error, :no_credentials} when host claude dir is missing" do
      missing = Path.join(System.tmp_dir!(), "no_claude_#{:erlang.unique_integer([:positive])}")
      Application.put_env(:jido_claw, :claude_home_dir, missing)

      {:ok, client, _sid} = StubSandbox.create()

      assert {:error, :no_credentials} = ClaudeCode.init(client, %{})

      events = StubSandbox.events(client)
      refute Enum.any?(events, fn {kind, _} -> kind == :write end)
    end

    test "returns {:error, :no_credentials} when host dir exists but credentials.json is missing" do
      tmp = make_tmpdir!("claude_missing_creds")
      File.write!(Path.join(tmp, "settings.json"), "{}")
      Application.put_env(:jido_claw, :claude_home_dir, tmp)

      {:ok, client, _sid} = StubSandbox.create()

      assert {:error, :no_credentials} = ClaudeCode.init(client, %{})

      on_exit(fn -> File.rm_rf(tmp) end)
    end
  end

  describe "init/2 — happy path" do
    setup do
      host = make_tmpdir!("claude_host")
      File.write!(Path.join(host, "credentials.json"), ~s({"token":"sk-test"}\n))
      File.write!(Path.join(host, "settings.json"), "{}")
      Application.put_env(:jido_claw, :claude_home_dir, host)

      forge_home = make_tmpdir!("forge_home_claude")

      on_exit(fn ->
        File.rm_rf(host)
        File.rm_rf(forge_home)
      end)

      {:ok, host: host, forge_home: forge_home}
    end

    test "syncs ~/.claude into the sandbox and pins permissions settings",
         %{forge_home: forge_home} do
      {:ok, client, _sid} = StubSandbox.create()

      assert {:ok, state} =
               ClaudeCode.init(client, %{
                 forge_home: forge_home,
                 prompt: "do consolidator work"
               })

      assert state.forge_home == forge_home
      assert state.model == "claude-sonnet-4-20250514"

      events = StubSandbox.events(client)

      mkdirs =
        for {:exec, cmd} <- events, String.starts_with?(cmd, "mkdir -p"), do: cmd

      assert Enum.any?(mkdirs, &String.contains?(&1, "#{forge_home}/.claude"))
      assert Enum.any?(mkdirs, &String.contains?(&1, "#{forge_home}/session"))

      sync_cmds =
        for {:exec, cmd} <- events, String.contains?(cmd, "base64 -d"), do: cmd

      assert Enum.any?(sync_cmds, &String.contains?(&1, "#{forge_home}/.claude/credentials.json"))

      # credentials.json gets chmod 600
      assert Enum.any?(events, fn
               {:exec, cmd} -> cmd == "chmod 600 #{forge_home}/.claude/credentials.json"
               _ -> false
             end)

      # The pinned settings.json overwrites whatever the sync wrote.
      pinned = StubSandbox.file(client, "#{forge_home}/.claude/settings.json")
      assert pinned == ~s({"permissions":{"allow":["*"]}})

      # The redacted prompt was dropped at session/context.md.
      assert StubSandbox.file(client, "#{forge_home}/session/context.md") =~ "consolidator work"
    end
  end

  defp make_tmpdir!(prefix) do
    dir = Path.join(System.tmp_dir!(), "#{prefix}_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    dir
  end

  defp restore(key, nil), do: Application.delete_env(:jido_claw, key)
  defp restore(key, value), do: Application.put_env(:jido_claw, key, value)
end
