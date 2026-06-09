defmodule JidoClaw.Gates.ToolCallGate do
  @moduledoc """
  The `:tool_call` gate — a human approval checkpoint before the agent
  executes a sensitive tool invocation (shell command, network mutation,
  credential use).

  Declared-but-unproduced: no reactor wires this kind yet. The tool-approval
  producer (intercepting flagged tool calls into a gate) is future work; the
  kind ships now so the vocabulary, `AgentCase.kind` column, and approval
  surfaces are ready for it.
  """

  use JidoClaw.Orchestration.HumanGate

  gate do
    kind(:tool_call)
    title("Approve tool call")
    description("The agent wants to execute a sensitive tool invocation.")

    fields do
      field(:comment, type: :textarea, label: "Comment")
    end
  end
end
