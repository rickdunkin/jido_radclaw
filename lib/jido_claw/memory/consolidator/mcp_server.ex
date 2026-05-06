defmodule JidoClaw.Memory.Consolidator.MCPServer do
  @moduledoc """
  Scoped MCP server for the memory consolidator harness.

  A single static server registered at app boot. The harness reaches
  it through a per-run Bandit endpoint that mints a `run_id` URL
  segment and stamps `:consolidator_run_id` into `frame.assigns`.

  Each tool reads the run id, looks up the corresponding RunServer
  via the RunRegistry, and dispatches the proposal to that
  GenServer's staging buffer. `commit_proposals` triggers the
  publish step.
  """

  use Jido.MCP.Server,
    name: "memory_consolidator",
    version: "0.6.0",
    publish: %{
      tools: [
        JidoClaw.Memory.Consolidator.Tools.ListClusters,
        JidoClaw.Memory.Consolidator.Tools.GetCluster,
        JidoClaw.Memory.Consolidator.Tools.GetActiveBlocks,
        JidoClaw.Memory.Consolidator.Tools.FindSimilarFacts,
        JidoClaw.Memory.Consolidator.Tools.ProposeAdd,
        JidoClaw.Memory.Consolidator.Tools.ProposeUpdate,
        JidoClaw.Memory.Consolidator.Tools.ProposeDelete,
        JidoClaw.Memory.Consolidator.Tools.ProposeBlockUpdate,
        JidoClaw.Memory.Consolidator.Tools.ProposeLink,
        JidoClaw.Memory.Consolidator.Tools.DeferCluster,
        JidoClaw.Memory.Consolidator.Tools.CommitProposals
      ]
    }
end
