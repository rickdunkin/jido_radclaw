defmodule JidoClaw.Core.OsCmdTest do
  # async: false — the timeout/orphan tests inspect the global OS
  # process table (`ps`), and env tests mutate the process environment.
  use ExUnit.Case, async: false

  alias JidoClaw.Core.OsCmd
  alias JidoClaw.Security.Redaction.Env

  setup do
    sh = System.find_executable("sh") || flunk("sh not found on PATH")

    tmp =
      Path.join(
        System.tmp_dir!(),
        "os_cmd_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)

    {:ok, sh: sh, tmp: tmp}
  end

  describe "run/3" do
    test "captures output and exit status", %{sh: sh} do
      assert {"hello", 3} = OsCmd.run(sh, ["-c", "printf hello; exit 3"])
    end

    test "merges stderr into stdout", %{sh: sh} do
      assert {"to-stderr\n", 0} = OsCmd.run(sh, ["-c", "echo to-stderr 1>&2"])
    end

    test "sets env vars from cmd-format env", %{sh: sh} do
      assert {"from-env", 0} =
               OsCmd.run(sh, ["-c", ~s(printf %s "$OS_CMD_TEST_VAR")],
                 env: [{"OS_CMD_TEST_VAR", "from-env"}]
               )
    end

    test "nil env value unsets an inherited var", %{sh: sh} do
      var = "OS_CMD_TEST_UNSET_#{System.unique_integer([:positive])}"
      System.put_env(var, "leaky")
      on_exit(fn -> System.delete_env(var) end)

      assert {"", 0} = OsCmd.run(sh, ["-c", ~s(printf %s "$#{var}")], env: [{var, nil}])
    end

    test "default env (no :env opt) is scrubbed — non-allowlisted parent vars don't leak",
         %{sh: sh} do
      var = "OS_CMD_TEST_LEAK_#{System.unique_integer([:positive])}"
      System.put_env(var, "should-not-leak")
      on_exit(fn -> System.delete_env(var) end)

      assert {"", 0} = OsCmd.run(sh, ["-c", ~s(printf %s "$#{var}")])

      # Allowlisted vars still flow through the default scrub.
      assert {home, 0} = OsCmd.run(sh, ["-c", ~s(printf %s "$HOME")])
      assert home == System.get_env("HOME")
    end

    test "runs in the given cd", %{sh: sh, tmp: tmp} do
      File.write!(Path.join(tmp, "marker.txt"), "from-cd")

      assert {"from-cd", 0} = OsCmd.run(sh, ["-c", "cat marker.txt"], cd: tmp)
    end

    test "explicit :infinity timeout completes normally", %{sh: sh} do
      assert {"done", 0} = OsCmd.run(sh, ["-c", "printf done"], timeout: :infinity)
    end

    test "returns partial output on timeout", %{sh: sh} do
      assert {output, :timeout} =
               OsCmd.run(sh, ["-c", "printf partial; sleep 30"], timeout: 750)

      assert output =~ "partial"
    end

    test "timeout is wall-clock — steady output does not extend it", %{sh: sh} do
      started = System.monotonic_time(:millisecond)

      # Prints every 50ms for up to ~7.5s. Each chunk lands well inside the
      # 750ms window, so an idle-reset implementation never fires (the
      # command completes with status 0 after ~7.5s); a wall-clock deadline
      # returns {:timeout} at ~750ms.
      assert {output, :timeout} =
               OsCmd.run(
                 sh,
                 ["-c", "i=0; while [ $i -lt 150 ]; do echo tick; sleep 0.05; i=$((i+1)); done"],
                 timeout: 750
               )

      elapsed = System.monotonic_time(:millisecond) - started
      assert output =~ "tick"
      # Generous CI headroom above 750ms + post-kill drain, well below the ~7.5s full run.
      assert elapsed < 5_000
    end

    test "timeout kills the whole OS process tree, not just the direct child", %{
      sh: sh,
      tmp: tmp
    } do
      marker = Path.join(tmp, "grandchild.pid")

      assert {_output, :timeout} =
               OsCmd.run(sh, ["-c", "sleep 30 & echo $! > #{marker}; wait"], timeout: 1_000)

      # The marker is written at command start, well inside the timeout
      # window — but poll anyway to dodge a write race.
      assert_eventually(fn -> marker_pid(marker) != nil end)
      pid = marker_pid(marker)

      # The grandchild `sleep 30` must die with the tree. A brief grace
      # window covers init/launchd reaping the re-parented zombie.
      assert_eventually(fn -> not os_pid_alive?(pid) end, 2_000)
    end
  end

  describe "kill_tree/1" do
    test "is :ok for an already-dead pid" do
      # Spawn something short-lived and wait for it to exit so the pid
      # is stale by the time we kill it.
      port = Port.open({:spawn_executable, System.find_executable("true")}, [:exit_status])
      {:os_pid, os_pid} = Port.info(port, :os_pid)

      receive do
        {^port, {:exit_status, _}} -> :ok
      after
        5_000 -> flunk("true did not exit")
      end

      assert :ok = OsCmd.kill_tree(os_pid)
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

  # Polls `fun` until it returns truthy or the deadline expires.
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
