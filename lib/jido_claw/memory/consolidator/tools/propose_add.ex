defmodule JidoClaw.Memory.Consolidator.Tools.ProposeAdd do
  @moduledoc "Stage a new Fact for this run."

  use Jido.Action,
    name: "propose_add",
    description: "Stage a new Fact for this run.",
    schema: [
      content: [type: :string, required: true],
      tags: [type: {:list, :string}, default: []],
      label: [type: :string]
    ]

  alias JidoClaw.Memory.Consolidator.Tools.Helpers

  @impl true
  def run(args, ctx) do
    Helpers.dispatch(ctx, {:propose_add, args})
  end
end
