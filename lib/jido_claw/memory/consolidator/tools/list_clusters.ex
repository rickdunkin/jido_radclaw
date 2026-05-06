defmodule JidoClaw.Memory.Consolidator.Tools.ListClusters do
  @moduledoc "List the clusters discovered for this consolidator run."

  use Jido.Action,
    name: "list_clusters",
    description: "List the clusters of related Facts discovered for this consolidator run.",
    schema: []

  alias JidoClaw.Memory.Consolidator.Tools.Helpers

  @impl true
  def run(_args, ctx) do
    Helpers.dispatch(ctx, :list_clusters)
  end
end
