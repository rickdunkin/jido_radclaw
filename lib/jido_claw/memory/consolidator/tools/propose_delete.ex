defmodule JidoClaw.Memory.Consolidator.Tools.ProposeDelete do
  @moduledoc "Stage a Fact invalidation."

  use Jido.Action,
    name: "propose_delete",
    description: "Stage a Fact invalidation.",
    schema: [
      fact_id: [type: :string, required: true],
      reason: [type: :string]
    ]

  alias JidoClaw.Memory.Consolidator.Tools.Helpers

  @impl true
  def run(args, ctx) do
    Helpers.dispatch(ctx, {:propose_delete, args})
  end
end
