defmodule JidoClaw.Memory.Consolidator.Tools.DeferCluster do
  @moduledoc "Mark a cluster deferred — leave its Facts in place; revisit on a future tick."

  use Jido.Action,
    name: "defer_cluster",
    description: "Mark a cluster deferred — Facts stay in place; revisit on a future tick.",
    schema: [
      cluster_id: [type: :string, required: true],
      reason: [type: :string]
    ]

  alias JidoClaw.Memory.Consolidator.Tools.Helpers

  @impl true
  def run(args, ctx) do
    Helpers.dispatch(ctx, {:defer_cluster, args})
  end
end
