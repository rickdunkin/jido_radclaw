defmodule JidoClaw.Tools.KillAgentTest do
  use ExUnit.Case, async: true

  alias JidoClaw.Tools.KillAgent

  test "returns a structured validation error when the agent is not found" do
    assert {:error, %{code: :validation_error, message: message, details: details}} =
             KillAgent.run(%{agent_id: "missing"}, %{tool_context: %{tenant_id: "tenant-kill"}})

    assert message == "Agent 'missing' not found."
    assert details.field == :agent
    assert details.value == "missing"
    assert details.kind == :agent
    assert details.reason == :not_found
  end

  test "requires tenant scope before resolving tracker or runtime state" do
    assert {:error, %{code: :tenant_required}} = KillAgent.run(%{agent_id: "missing"}, %{})
  end
end
