defmodule JidoClaw.Shell.BackendHostTest do
  # async: false — env-scrubbing tests mutate the global process env.
  use ExUnit.Case, async: false

  alias JidoClaw.Security.Redaction.Env
  alias JidoClaw.Shell.BackendHost

  setup do
    supervisor = start_supervised!(Task.Supervisor)

    var = "JIDO_TEST_#{System.unique_integer([:positive])}_TOKEN"
    System.put_env(var, "leaked-secret")
    on_exit(fn -> System.delete_env(var) end)

    tmp =
      Path.join(
        System.tmp_dir!(),
        "backend_host_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)

    %{supervisor: supervisor, var: var, tmp: tmp}
  end

  test "commands do not see sensitive parent env vars", %{supervisor: supervisor, var: var} do
    {:ok, state} = BackendHost.init(%{session_pid: self(), task_supervisor: supervisor})

    assert {:ok, _task, _state} = BackendHost.execute(state, ~s(printf %s "$#{var}"), [], [])
    assert collect_output() == ""
  end

  test "session env wins over scrubbing", %{supervisor: supervisor} do
    {:ok, state} =
      BackendHost.init(%{
        session_pid: self(),
        task_supervisor: supervisor,
        env: %{"SESSION_TOKEN" => "ok"}
      })

    assert {:ok, _task, _state} =
             BackendHost.execute(state, ~s(printf %s "$SESSION_TOKEN"), [], [])

    assert collect_output() == "ok"
  end

  test "exec_opts env wins over scrubbing", %{supervisor: supervisor} do
    {:ok, state} = BackendHost.init(%{session_pid: self(), task_supervisor: supervisor})

    assert {:ok, _task, _state} =
             BackendHost.execute(state, ~s(printf %s "$EXEC_TOKEN"), [],
               env: %{"EXEC_TOKEN" => "ok"}
             )

    assert collect_output() == "ok"
  end

  # All three abort paths (timeout, cancel, output limit) must kill the
  # OS process tree, not just the BEAM side. Commands are passed as a
  # full shell line with `args = []` — `command_line/2` joins command
  # and args with spaces, and BackendHost wraps the line in `sh -c`
  # itself, so this is not argv execution.
  describe "OS process-tree reaping" do
    test "timeout kills the process tree", %{supervisor: supervisor, tmp: tmp} do
      {:ok, state} = BackendHost.init(%{session_pid: self(), task_supervisor: supervisor})
      marker = Path.join(tmp, "timeout.pid")

      assert {:ok, _task, _state} =
               BackendHost.execute(state, "sleep 30 & echo $! > #{marker}; wait", [],
                 timeout: 1_000
               )

      assert_receive {:command_finished, {:error, "Command timed out after 1000ms"}}, 5_000

      assert_eventually(fn -> marker_pid(marker) != nil end)
      pid = marker_pid(marker)
      assert_eventually(fn -> not os_pid_alive?(pid) end, 2_000)
    end

    test "cancel kills the process tree", %{supervisor: supervisor, tmp: tmp} do
      {:ok, state} = BackendHost.init(%{session_pid: self(), task_supervisor: supervisor})
      marker = Path.join(tmp, "cancel.pid")

      assert {:ok, task, _state} =
               BackendHost.execute(state, "sleep 30 & echo $! > #{marker}; wait", [], [])

      # `execute/4` returns as soon as the task starts — prove the OS
      # child exists before cancelling, or a too-fast cancel could hit
      # before the port spawns and pass vacuously.
      assert_eventually(fn -> marker_pid(marker) != nil end, 2_000)
      pid = marker_pid(marker)
      assert os_pid_alive?(pid)

      assert :ok = BackendHost.cancel(state, task)

      assert_eventually(fn -> not os_pid_alive?(pid) end, 2_000)

      # A cancelled task must stay silent: by now the session server has
      # demonitored and cleared `current_command`, so a late
      # `{:command_finished, ...}` would be re-broadcast under whatever
      # command runs next, shifting later commands' output by one.
      refute_receive {:command_finished, _}, 1_000
    end

    test "output-limit abort kills the process tree", %{supervisor: supervisor, tmp: tmp} do
      {:ok, state} = BackendHost.init(%{session_pid: self(), task_supervisor: supervisor})
      marker = Path.join(tmp, "limit.pid")

      # Background sleep + pid marker, then blow past the 1 KB limit.
      line = "sleep 30 & echo $! > #{marker}; yes | head -c 65536; wait"

      assert {:ok, _task, _state} =
               BackendHost.execute(state, line, [], output_limit: 1_000)

      assert_receive {:command_finished,
                      {:error, %Jido.Shell.Error{code: {:command, :output_limit_exceeded}}}},
                     5_000

      assert_eventually(fn -> marker_pid(marker) != nil end)
      pid = marker_pid(marker)
      assert_eventually(fn -> not os_pid_alive?(pid) end, 2_000)
    end
  end

  defp collect_output(acc \\ "") do
    receive do
      {:command_event, {:output, chunk}} -> collect_output(acc <> chunk)
      {:command_event, {:exit_status, _code}} -> collect_output(acc)
      {:command_finished, {:ok, 0}} -> acc
      {:command_finished, other} -> flunk("command did not succeed: #{inspect(other)}")
    after
      5_000 -> flunk("timed out waiting for command to finish")
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
