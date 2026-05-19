defmodule JidoClaw.Tools.SendToAgentTest do
  use ExUnit.Case, async: false

  alias JidoClaw.Tools.SendToAgent

  defmodule FakeJido do
    @moduledoc false

    def whereis("missing"), do: nil
    def whereis(_agent_id), do: self()
  end

  defmodule FakeTracker do
    @moduledoc false

    def get_agent("docs_writer_123"), do: %{template: "docs_writer"}
    def get_agent("untracked_123"), do: nil
  end

  defmodule FakeTemplates do
    @moduledoc false

    def get("docs_writer"), do: {:ok, %{module: JidoClaw.Tools.SendToAgentTest.FakeWorker}}
    def get(name), do: {:error, {:unknown_template, name}}
  end

  defmodule FakeWorker do
    @moduledoc false

    def ask_sync(pid, message, opts) do
      send(Application.fetch_env!(:jido_claw, :send_to_agent_test_pid), {
        :ask_sync,
        __MODULE__,
        pid,
        message,
        opts
      })

      :ok
    end
  end

  setup do
    original_jido = Application.get_env(:jido_claw, :jido_runtime)
    original_tracker = Application.get_env(:jido_claw, :agent_tracker)
    original_templates = Application.get_env(:jido_claw, :agent_templates)
    original_test_pid = Application.get_env(:jido_claw, :send_to_agent_test_pid)

    Application.put_env(:jido_claw, :jido_runtime, FakeJido)
    Application.put_env(:jido_claw, :agent_tracker, FakeTracker)
    Application.put_env(:jido_claw, :agent_templates, FakeTemplates)
    Application.put_env(:jido_claw, :send_to_agent_test_pid, self())

    on_exit(fn ->
      restore_env(:jido_runtime, original_jido)
      restore_env(:agent_tracker, original_tracker)
      restore_env(:agent_templates, original_templates)
      restore_env(:send_to_agent_test_pid, original_test_pid)
    end)

    :ok
  end

  test "uses AgentTracker template metadata for multi-word template ids" do
    assert {:ok, %{status: "message_sent"}} =
             SendToAgent.run(
               %{agent_id: "docs_writer_123", message: "please expand docs"},
               %{tool_context: %{agent_id: "main"}}
             )

    assert_receive {:ask_sync, FakeWorker, pid, "please expand docs", opts}

    assert pid == self()
    assert opts[:tool_context].agent_id == "docs_writer_123"
    assert opts[:request_id]
  end

  test "does not fall back to the main agent when tracker metadata is missing" do
    assert {:error, %{code: :execution_error, message: message, details: details}} =
             SendToAgent.run(%{agent_id: "untracked_123", message: "hello"}, %{})

    assert message =~ "not registered in AgentTracker"
    assert details.phase == :tracker_lookup
    assert details.reason == :not_registered
    assert details.agent_id == "untracked_123"
  end

  test "returns error when the agent process is missing" do
    assert {:error, %{message: "Agent 'missing' not found."}} =
             SendToAgent.run(%{agent_id: "missing", message: "hello"}, %{})
  end

  defp restore_env(key, nil), do: Application.delete_env(:jido_claw, key)
  defp restore_env(key, value), do: Application.put_env(:jido_claw, key, value)
end
