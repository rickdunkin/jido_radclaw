defmodule JidoClaw.Tools.GetAgentResultTest do
  use ExUnit.Case, async: false

  alias JidoClaw.Tools.GetAgentResult

  defmodule FakeJido do
    @moduledoc false

    def whereis("missing"), do: nil
    def whereis(_agent_id), do: self()
  end

  defmodule FakeAwait do
    @moduledoc false

    def completion(_pid, _timeout) do
      case Process.get(:fake_await_result) do
        {:raise, exception} -> raise exception
        result -> result
      end
    end
  end

  setup do
    original_jido = Application.get_env(:jido_claw, :jido_runtime)
    original_await = Application.get_env(:jido_claw, :jido_await)

    Application.put_env(:jido_claw, :jido_runtime, FakeJido)
    Application.put_env(:jido_claw, :jido_await, FakeAwait)

    on_exit(fn ->
      restore_env(:jido_runtime, original_jido)
      restore_env(:jido_await, original_await)
      Process.delete(:fake_await_result)
    end)

    :ok
  end

  test "returns ok only for completed agents" do
    Process.put(:fake_await_result, {:ok, %{status: :completed, last_answer: "done"}})

    assert {:ok, %{status: "completed", result: "done"}} =
             GetAgentResult.run(%{agent_id: "agent-1"}, %{})
  end

  test "returns error when the agent is still running" do
    Process.put(:fake_await_result, {:error, :timeout})

    assert {:error, %{code: :execution_error, message: message, details: details}} =
             GetAgentResult.run(%{agent_id: "agent-1", timeout: 1}, %{})

    assert message =~ "hasn't finished"
    assert details.agent_id == "agent-1"
    assert details.status == "still_running"
    assert details.code == :still_running
    assert details.phase == :timeout
  end

  test "returns error for agent failure tuples" do
    Process.put(:fake_await_result, {:error, :crashed})

    assert {:error, %{code: :execution_error, message: "Agent failed.", details: details}} =
             GetAgentResult.run(%{agent_id: "agent-1"}, %{})

    assert details.agent_id == "agent-1"
    assert details.status == "failed"
    assert details.code == :failed
    assert details.error == ":crashed"
  end

  test "returns error when await reports terminal failed status" do
    Process.put(:fake_await_result, {:ok, %{status: :failed, error: :tool_failed}})

    assert {:error, %{code: :execution_error, message: "Agent failed.", details: details}} =
             GetAgentResult.run(%{agent_id: "agent-1"}, %{})

    assert details.agent_id == "agent-1"
    assert details.status == "failed"
    assert details.code == :failed
    assert details.error == ":tool_failed"
  end

  test "returns error when awaiting raises" do
    Process.put(:fake_await_result, {:raise, RuntimeError.exception("boom")})

    assert {:error, %{code: :execution_error, message: "boom", details: details}} =
             GetAgentResult.run(%{agent_id: "agent-1"}, %{})

    assert details.agent_id == "agent-1"
    assert details.status == "error"
    assert details.code == :error
  end

  test "returns error when agent is not found" do
    assert {:error, %{code: :validation_error, message: message, details: details}} =
             GetAgentResult.run(%{agent_id: "missing"}, %{})

    assert message =~ "not found"
    assert details.field == :agent
    assert details.value == "missing"
  end

  defp restore_env(key, nil), do: Application.delete_env(:jido_claw, key)
  defp restore_env(key, value), do: Application.put_env(:jido_claw, key, value)
end
