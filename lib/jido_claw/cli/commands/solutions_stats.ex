defmodule JidoClaw.CLI.Commands.SolutionsStats do
  @moduledoc """
  Replaces the v0.5.x `Solutions.Store.stats/0` GenServer call with a
  scoped read against the new Postgres-backed Solutions corpus.

  Returns `%{total: int, by_language: map, by_framework: map}`
  filtered to the caller's `(tenant_id, workspace_id)` and to non-
  soft-deleted rows.
  """

  alias JidoClaw.Repo

  @doc """
  Fetch counts for the given workspace.
  """
  @spec fetch(String.t(), String.t()) ::
          %{total: non_neg_integer(), by_language: map(), by_framework: map()}
  def fetch(tenant_id, workspace_id)
      when is_binary(tenant_id) and is_binary(workspace_id) do
    case Repo.query(
           """
           SELECT language, framework, COUNT(*)::bigint
             FROM solutions
            WHERE tenant_id = $1
              AND workspace_id = $2
              AND deleted_at IS NULL
            GROUP BY language, framework
           """,
           [tenant_id, Ecto.UUID.dump!(workspace_id)]
         ) do
      {:ok, %Postgrex.Result{rows: rows}} -> aggregate(rows)
      _ -> %{total: 0, by_language: %{}, by_framework: %{}}
    end
  end

  defp aggregate(rows) do
    Enum.reduce(rows, %{total: 0, by_language: %{}, by_framework: %{}}, fn [lang, fw, n], acc ->
      acc
      |> Map.update!(:total, &(&1 + n))
      |> Map.update!(:by_language, fn m -> Map.update(m, lang, n, &(&1 + n)) end)
      |> Map.update!(:by_framework, fn m ->
        if is_binary(fw), do: Map.update(m, fw, n, &(&1 + n)), else: m
      end)
    end)
  end
end
