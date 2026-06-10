defmodule JidoClaw.Forge.HarnessIterationMonitorTest.CrashingRunner do
  @moduledoc false
  @behaviour JidoClaw.Forge.Runner

  @impl JidoClaw.Forge.Runner
  def init(_client, _config), do: :ok

  @impl JidoClaw.Forge.Runner
  def run_iteration(_client, _state, _opts), do: raise("runner boom")

  @impl JidoClaw.Forge.Runner
  def apply_input(_client, _input, _state), do: :ok
end

defmodule JidoClaw.Forge.HarnessIterationMonitorTest do
  use ExUnit.Case, async: false

  alias JidoClaw.Forge
  alias JidoClaw.Forge.PubSub, as: ForgePubSub

  @timeout 10_000

  setup do
    prev = Application.get_env(:jido_claw, JidoClaw.Forge.Persistence, [])
    Application.put_env(:jido_claw, JidoClaw.Forge.Persistence, enabled: false)

    session_id = "harness-monitor-#{System.unique_integer([:positive])}"
    ForgePubSub.subscribe(session_id)

    {:ok, _handle} =
      Forge.start_session(session_id, %{
        runner: JidoClaw.Forge.HarnessIterationMonitorTest.CrashingRunner,
        sandbox: :fake
      })

    assert_receive {:ready, ^session_id}, @timeout

    on_exit(fn ->
      Application.put_env(:jido_claw, JidoClaw.Forge.Persistence, prev)
      _ = Forge.stop_session(session_id)
    end)

    %{session_id: session_id}
  end

  test "runner task crashes reply to caller and reset harness to ready", %{session_id: sid} do
    assert {:error, {:iteration_task_failed, reason}} = Forge.run_iteration(sid, timeout: 1_000)
    assert inspect(reason) =~ "runner boom"

    assert_receive {:error, %{reason: {:iteration_task_failed, _}}}, @timeout

    assert {:ok, status} = Forge.status(sid)
    assert status.state == :ready
  end

  test "unexpected info messages do not crash the harness", %{session_id: sid} do
    assert {:ok, %Forge.SessionHandle{pid: pid}} = Forge.get_handle(sid)

    send(pid, {:unexpected_info, self()})
    Process.sleep(10)

    assert {:ok, status} = Forge.status(sid)
    assert status.state == :ready
  end
end
