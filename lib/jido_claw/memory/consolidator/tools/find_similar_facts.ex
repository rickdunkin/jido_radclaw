defmodule JidoClaw.Memory.Consolidator.Tools.FindSimilarFacts do
  @moduledoc "Search the Fact tier for rows similar to a query within this run's scope."

  use Jido.Action,
    name: "find_similar_facts",
    description: "Search the Fact tier for similar rows within this run's scope.",
    schema: [
      query: [type: :string, required: true],
      limit: [type: :integer, default: 10]
    ]

  alias JidoClaw.Memory.Consolidator.Tools.Helpers

  @impl true
  def run(args, ctx) do
    Helpers.dispatch(ctx, {:find_similar_facts, args})
  end
end
