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

    assert {:error, %{code: :still_running, message: message, details: %{context: context}}} =
             GetAgentResult.run(%{agent_id: "agent-1", timeout: 1}, %{})

    assert message =~ "hasn't finished"
    assert context.agent_id == "agent-1"
    assert context.status == "still_running"
  end

  test "returns error for agent failure tuples" do
    Process.put(:fake_await_result, {:error, :crashed})

    assert {:error, %{code: :failed, message: ":crashed", details: %{context: context}}} =
             GetAgentResult.run(%{agent_id: "agent-1"}, %{})

    assert context.agent_id == "agent-1"
    assert context.status == "failed"
  end

  test "returns error when await reports terminal failed status" do
    Process.put(:fake_await_result, {:ok, %{status: :failed, error: :tool_failed}})

    assert {:error, %{code: :failed, message: ":tool_failed", details: %{context: context}}} =
             GetAgentResult.run(%{agent_id: "agent-1"}, %{})

    assert context.agent_id == "agent-1"
    assert context.status == "failed"
  end

  test "returns error when awaiting raises" do
    Process.put(:fake_await_result, {:raise, RuntimeError.exception("boom")})

    assert {:error, %{code: :error, message: "boom", details: %{context: context}}} =
             GetAgentResult.run(%{agent_id: "agent-1"}, %{})

    assert context.agent_id == "agent-1"
    assert context.status == "error"
  end

  test "returns error when agent is not found" do
    assert {:error, %{message: message}} = GetAgentResult.run(%{agent_id: "missing"}, %{})

    assert message =~ "not found"
  end

  defp restore_env(key, nil), do: Application.delete_env(:jido_claw, key)
  defp restore_env(key, value), do: Application.put_env(:jido_claw, key, value)
end
