defmodule JidoClaw.Memory.Consolidator.Tools.CommitProposals do
  @moduledoc "Commit all staged proposals — triggers the publish step in the RunServer."

  use Jido.Action,
    name: "commit_proposals",
    description: "Commit all staged proposals (publish step).",
    schema: []

  alias JidoClaw.Memory.Consolidator.Tools.Helpers

  @impl true
  def run(_args, ctx) do
    Helpers.dispatch(ctx, :commit_proposals)
  end
end
