defmodule JidoClaw.Forge.Runner.HostShellTest do
  use ExUnit.Case, async: false

  alias JidoClaw.Forge.Runner.HostShell
  alias JidoClaw.Forge.Sandbox

  setup do
    {:ok, client, shell_id} = HostShell.create(%{})
    on_exit(fn -> HostShell.destroy(client, shell_id) end)
    %{client: client, shell_id: shell_id}
  end

  test "is the default Forge execution backend when Docker is not configured" do
    original = Application.get_env(:jido_claw, :forge_sandbox, :unset)
    Application.delete_env(:jido_claw, :forge_sandbox)

    on_exit(fn ->
      case original do
        :unset -> Application.delete_env(:jido_claw, :forge_sandbox)
        value -> Application.put_env(:jido_claw, :forge_sandbox, value)
      end
    end)

    assert Sandbox.impl_module() == HostShell
  end

  test "executes commands from its per-run host working directory", %{client: client} do
    assert {"", 0} = HostShell.exec(client, "printf shell > marker.txt", [])
    assert {:ok, "shell"} = HostShell.read_file(client, "marker.txt")
  end

  test "rejects absolute and traversing file API paths", %{client: client} do
    outside =
      Path.join(System.tmp_dir!(), "host_shell_outside_#{System.unique_integer([:positive])}.txt")

    assert {:error, {:unsafe_path, ^outside}} = HostShell.write_file(client, outside, "outside")
    assert {:error, {:unsafe_path, ^outside}} = HostShell.read_file(client, outside)
    refute File.exists?(outside)

    assert {:error, {:unsafe_path, "../escape.txt"}} =
             HostShell.write_file(client, "../escape.txt", "escape")

    assert {:error, {:unsafe_path, "../escape.txt"}} =
             HostShell.read_file(client, "../escape.txt")
  end

  test "exec_argv does not interpret shell metacharacters", %{client: client} do
    assert {"hello; echo injected", 0} =
             HostShell.exec_argv(client, "printf", ["%s", "hello; echo injected"], [])
  end

  test "reports missing executables without opening a broken port", %{client: client} do
    assert {:error, :command_not_found} =
             HostShell.spawn(client, "definitely-not-a-real-command", [], [])
  end

  describe "env scrubbing" do
    setup do
      var = "JIDO_TEST_#{System.unique_integer([:positive])}_TOKEN"
      System.put_env(var, "leaked-secret")
      on_exit(fn -> System.delete_env(var) end)
      %{var: var}
    end

    test "exec does not leak sensitive parent env vars", %{client: client, var: var} do
      assert {"", 0} = HostShell.exec(client, ~s(printf %s "$#{var}"), [])
    end

    test "injected sandbox env wins over scrubbing", %{client: client} do
      assert :ok = HostShell.inject_env(client, %{"INJECTED_TOKEN" => "ok"})
      assert {"ok", 0} = HostShell.exec(client, ~s(printf %s "$INJECTED_TOKEN"), [])
    end

    test "spawn port does not leak sensitive parent env vars", %{client: client, var: var} do
      assert {:ok, port} = HostShell.spawn(client, "sh", ["-c", ~s(printf %s "$#{var}")], [])
      assert collect_port_output(port) == ""
    end
  end

  defp collect_port_output(port, acc \\ "") do
    receive do
      {^port, {:data, chunk}} -> collect_port_output(port, acc <> chunk)
      {^port, {:exit_status, _status}} -> acc
    after
      5_000 -> flunk("timed out waiting for spawned port to exit")
    end
  end
end
