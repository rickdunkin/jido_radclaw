defmodule JidoClaw.Solutions.Reads.HybridSearch do
  @moduledoc """
  Manual read implementing the `:search` action on
  `JidoClaw.Solutions.Solution`. Wraps
  `JidoClaw.Solutions.HybridSearchSql.run/1` so callers reach the
  hybrid retrieval path through the resource layer instead of
  hand-rolling the SQL call.

  The combined score is attached to each row via
  `Ash.Resource.put_metadata(sol, :combined_score, score)`. The action
  argument `:threshold` is enforced here (Elixir-side) — the SQL
  itself doesn't filter on combined_score.

  Embedding computation is the caller's responsibility: pass
  `:query_embedding` (nullable). The Matcher computes it via the
  policy resolver and threads it through.
  """

  use Ash.Resource.ManualRead

  alias JidoClaw.Solutions.HybridSearchSql

  @impl true
  def read(query, _module, _opts, _context) do
    args = build_args(query)
    threshold = Map.get(args, :threshold, 0.0)

    rows =
      args
      |> Map.delete(:threshold)
      |> HybridSearchSql.run()

    solutions =
      rows
      |> Enum.filter(fn %{combined_score: score} -> score >= threshold end)
      |> Enum.map(fn %{solution: sol, combined_score: score} ->
        Ash.Resource.put_metadata(sol, :combined_score, score)
      end)

    {:ok, solutions}
  end

  defp build_args(query) do
    %{
      query: Ash.Query.get_argument(query, :query),
      query_embedding: Ash.Query.get_argument(query, :query_embedding),
      language: Ash.Query.get_argument(query, :language),
      framework: Ash.Query.get_argument(query, :framework),
      limit: Ash.Query.get_argument(query, :limit) || 10,
      threshold: Ash.Query.get_argument(query, :threshold) || 0.0,
      workspace_id: Ash.Query.get_argument(query, :workspace_id),
      tenant_id: query.tenant,
      local_visibility:
        Ash.Query.get_argument(query, :local_visibility) || [:local, :shared, :public],
      cross_workspace_visibility:
        Ash.Query.get_argument(query, :cross_workspace_visibility) || [:public]
    }
  end
end
