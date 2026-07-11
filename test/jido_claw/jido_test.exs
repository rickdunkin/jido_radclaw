defmodule JidoClaw.JidoTest do
  # Exercises the real, globally named JidoClaw.Jido.AgentSupervisor — must
  # not run concurrently with other tests poking the same supervisor.
  use ExUnit.Case, async: true

  alias JidoClaw.Jido, as: Runtime

  test "start_subagent/2 starts a :temporary child — a crash is final, no resurrection" do
    id = "temp-sub-#{System.unique_integer([:positive])}"

    assert {:ok, pid} = Runtime.start_subagent(JidoClaw.Test.EchoStub, id: id)

    on_exit(fn ->
      case Runtime.whereis(id) do
        worker when is_pid(worker) -> Runtime.stop_agent(worker)
        nil -> :ok
      end
    end)

    assert Runtime.whereis(id) == pid

    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, _, _}

    # Registry cleanup is asynchronous — poll until the id unregisters...
    wait_until(fn -> Runtime.whereis(id) == nil end)

    # ...then pin that it STAYS down. The dep's AgentServer child_spec is
    # hardcoded `restart: :permanent`; without the start_subagent override a
    # killed sub-agent is resurrected under a fresh pid and re-registered
    # here as an orphan nothing tracks or stops.
    Process.sleep(100)
    assert Runtime.whereis(id) == nil
  end

  defp wait_until(fun, timeout_ms \\ 2_000) do
    wait_until_deadline(fun, System.monotonic_time(:millisecond) + timeout_ms)
  end

  defp wait_until_deadline(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("condition not met within timeout")

      true ->
        Process.sleep(20)
        wait_until_deadline(fun, deadline)
    end
  end
end
