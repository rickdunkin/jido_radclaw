defmodule JidoClaw.Inspection.SummaryTest do
  use ExUnit.Case, async: true

  alias JidoClaw.Inspection.Summary

  test "default struct has zero-valued usage and empty lists" do
    s = %Summary{}
    assert s.system_prompt == nil
    assert s.skills == []
    assert s.tool_names == []
    assert s.mcp_tools == []
    assert s.subagents == []
    assert s.workflows == []
    assert s.usage == %{input_tokens: 0, output_tokens: 0, cost: nil}
    assert s.input_kind == :agent_id
  end

  test "accepts the documented field shape" do
    s = %Summary{
      system_prompt: "prompt",
      tool_names: ["read_file"],
      mcp_tools: ["read_file"],
      subagents: [%{id: "child-1", status: :running, template: "coder", last_tool: nil}],
      workflows: [%{id: "wf-1", name: "n", status: :running, started_at: nil}],
      handoffs: %{template: "reviewer", from_template: "main", message: "m", updated_at_ms: 1},
      usage: %{input_tokens: 10, output_tokens: 20, cost: nil},
      duration_ms: 42,
      input_kind: :pid,
      resolved_at_ms: 7
    }

    assert s.duration_ms == 42
    assert s.handoffs.template == "reviewer"
    assert s.usage.input_tokens == 10
  end
end
