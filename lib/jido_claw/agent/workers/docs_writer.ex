defmodule JidoClaw.Agent.Workers.DocsWriter do
  use Jido.AI.Agent,
    name: "jido_claw_docs_writer",
    description:
      "Writes documentation, module docs, function specs, and inline comments. Reads existing code and writes updated files.",
    tools: [
      JidoClaw.Tools.ReadFile,
      JidoClaw.Tools.WriteFile,
      JidoClaw.Tools.SearchCode
    ],
    model: :fast,
    max_iterations: 15,
    streaming: false,
    tool_timeout_ms: 30_000
end
