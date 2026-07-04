defmodule JidoClaw.Forge.Runner.HostShellTest do
  use ExUnit.Case, async: false

  alias JidoClaw.Core.OsCmd
  alias JidoClaw.Forge.Runner.HostShell
  alias JidoClaw.Forge.Sandbox
  alias JidoClaw.Security.Redaction.Env

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

  describe "output cap" do
    test "exec/3 maps the output cap to exit status 153 with cap-sized output", %{client: client} do
      put_app_env_restoring(:os_cmd_max_output_bytes, 1_000)

      # head bounds the runaway: a broken cap returns {100 KB, 0} and
      # fails the pattern instead of producing unbounded output.
      assert {output, 153} = HostShell.exec(client, "yes x | head -c 100000", [])
      assert byte_size(output) == 1_000
    end

    test "exec_argv without :timeout maps the output cap to exit status 153", %{client: client} do
      put_app_env_restoring(:os_cmd_max_output_bytes, 1_000)

      assert {output, 153} =
               HostShell.exec_argv(client, "sh", ["-c", "yes x | head -c 100000"], [])

      assert byte_size(output) == 1_000
    end
  end

  describe "ulimit (opt-in)" do
    test "no ulimit config means byte-identical argv pass-through" do
      assert HostShell.apply_ulimits("printf", ["%s", "x"]) == {"printf", ["%s", "x"]}
    end

    test "forge_ulimit_cpu_seconds kills a CPU-bound loop with a nonzero status",
         %{client: client} do
      # Genuine platform variance (unlike the seamable sbx branch): some
      # hosts accept `ulimit -t` but never deliver SIGXCPU to a shell
      # busy loop. Probe first; skip with a message when unenforced.
      if ulimit_cpu_enforced?() do
        put_app_env_restoring(:forge_ulimit_cpu_seconds, 1)

        # Timing-sensitive: SIGXCPU lands after ~1s of CPU time. The
        # 10s safety timeout means a NOT-applied ulimit surfaces as
        # {"", :timeout} and fails the integer assertion — it must not
        # hang (which is also why this goes through exec_argv, not the
        # :infinity-timeout exec/3).
        assert {_output, status} =
                 HostShell.exec_argv(client, "sh", ["-c", "while true; do :; done"],
                   timeout: 10_000
                 )

        assert is_integer(status) and status != 0
      else
        IO.puts("[skip] ulimit -t is not enforced for shell busy loops on this host")
      end
    end
  end

  describe "exec/3 timeout" do
    test "honors the caller's :timeout and reports it as exit 124", %{client: client} do
      # exec/3 previously hardcoded `timeout: :infinity`, silently dropping the
      # caller's opt (a `sleep 3` would run to completion). A real timeout must
      # surface as the Docker-parity `{"timeout after <n>ms", 124}` tuple —
      # ForgeBridge matches it exactly and the Behaviour spec is integer-only.
      assert {output, 124} = HostShell.exec(client, "sleep 3", timeout: 500)
      assert output == "timeout after 500ms"
    end
  end

  describe "exec_argv timeout" do
    test "returns {\"\", :timeout} and kills the OS process tree", %{client: client} do
      tmp =
        Path.join(
          System.tmp_dir!(),
          "host_shell_timeout_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)
      marker = Path.join(tmp, "grandchild.pid")

      assert {"", :timeout} =
               HostShell.exec_argv(
                 client,
                 "sh",
                 ["-c", "sleep 30 & echo $! > #{marker}; wait"],
                 timeout: 1_000
               )

      assert_eventually(fn -> marker_pid(marker) != nil end)
      pid = marker_pid(marker)

      # The backgrounded `sleep 30` (a grandchild of the BEAM) must die
      # with the tree — previously only the Task was brutally killed and
      # the OS processes were orphaned.
      assert_eventually(fn -> not os_pid_alive?(pid) end, 2_000)
    end
  end

  defp put_app_env_restoring(key, value) do
    original = Application.get_env(:jido_claw, key, :unset)
    Application.put_env(:jido_claw, key, value)

    on_exit(fn ->
      case original do
        :unset -> Application.delete_env(:jido_claw, key)
        previous -> Application.put_env(:jido_claw, key, previous)
      end
    end)
  end

  # One-shot capability probe: does this host actually deliver SIGXCPU
  # to a shell busy loop under `ulimit -t`? Exit 99 = the limit could
  # not even be set; :timeout = set but unenforced within the window.
  defp ulimit_cpu_enforced? do
    sh = System.find_executable("sh") || flunk("sh not found on PATH")

    case OsCmd.run(
           sh,
           ["-c", "ulimit -t 1 2>/dev/null || exit 99; while true; do :; done"],
           timeout: 10_000
         ) do
      {_out, status} when is_integer(status) and status != 0 and status != 99 -> true
      _unset_or_unenforced -> false
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

  defp marker_pid(marker) do
    case File.read(marker) do
      {:ok, content} ->
        case String.trim(content) do
          "" -> nil
          pid -> pid
        end

      _ ->
        nil
    end
  end

  defp os_pid_alive?(pid) do
    {_out, status} =
      System.cmd("ps", ["-p", pid], stderr_to_stdout: true, env: Env.scrubbed_cmd_env())

    status == 0
  end

  defp assert_eventually(fun, timeout_ms \\ 500) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_assert_eventually(fun, deadline)
  end

  defp do_assert_eventually(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("assert_eventually timed out")

      true ->
        Process.sleep(10)
        do_assert_eventually(fun, deadline)
    end
  end
end
