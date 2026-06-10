defmodule JidoClaw.Shell.BackendHostTest do
  # async: false — env-scrubbing tests mutate the global process env.
  use ExUnit.Case, async: false

  alias JidoClaw.Shell.BackendHost

  setup do
    supervisor = start_supervised!(Task.Supervisor)

    var = "JIDO_TEST_#{System.unique_integer([:positive])}_TOKEN"
    System.put_env(var, "leaked-secret")
    on_exit(fn -> System.delete_env(var) end)

    %{supervisor: supervisor, var: var}
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
end
