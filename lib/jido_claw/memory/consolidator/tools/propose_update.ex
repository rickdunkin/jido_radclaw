defmodule JidoClaw.Memory.Consolidator.Tools.ProposeUpdate do
  @moduledoc "Stage a Fact update (invalidate + new row at same label)."

  use Jido.Action,
    name: "propose_update",
    description: "Stage a Fact update (invalidate + new row at same label).",
    schema: [
      fact_id: [type: :string, required: true],
      new_content: [type: :string, required: true],
      tags: [type: {:list, :string}, default: []]
    ]

  alias JidoClaw.Memory.Consolidator.Tools.Helpers

  @impl true
  def run(args, ctx) do
    Helpers.dispatch(ctx, {:propose_update, args})
  end
end
