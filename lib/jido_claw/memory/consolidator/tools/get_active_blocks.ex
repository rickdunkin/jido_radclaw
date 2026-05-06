defmodule JidoClaw.Memory.Consolidator.Tools.GetActiveBlocks do
  @moduledoc "Read the currently active Block-tier rows for this scope chain."

  use Jido.Action,
    name: "get_active_blocks",
    description: "Read the currently active Block-tier rows for this scope chain.",
    schema: []

  alias JidoClaw.Memory.Consolidator.Tools.Helpers

  @impl true
  def run(_args, ctx) do
    Helpers.dispatch(ctx, :get_active_blocks)
  end
end
