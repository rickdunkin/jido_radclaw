defmodule JidoClaw.Memory.Consolidator.Tools.ProposeLink do
  @moduledoc "Stage a graph link between two Facts."

  use Jido.Action,
    name: "propose_link",
    description: "Stage a graph link between two Facts.",
    schema: [
      from_fact_id: [type: :string, required: true],
      to_fact_id: [type: :string, required: true],
      relation: [type: :string, required: true],
      reason: [type: :string],
      confidence: [type: :float]
    ]

  alias JidoClaw.Memory.Consolidator.Tools.Helpers

  @impl true
  def run(args, ctx) do
    Helpers.dispatch(ctx, {:propose_link, args})
  end
end
