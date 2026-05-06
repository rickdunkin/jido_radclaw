defmodule JidoClaw.Memory.Consolidator.Tools.GetCluster do
  @moduledoc "Fetch one cluster's full Fact contents."

  use Jido.Action,
    name: "get_cluster",
    description: "Fetch one cluster's full Fact contents by id.",
    schema: [
      cluster_id: [type: :string, required: true]
    ]

  alias JidoClaw.Memory.Consolidator.Tools.Helpers

  @impl true
  def run(args, ctx) do
    Helpers.dispatch(ctx, {:get_cluster, args})
  end
end
