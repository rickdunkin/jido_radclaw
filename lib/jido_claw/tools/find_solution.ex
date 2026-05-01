defmodule JidoClaw.Tools.FindSolution do
  @moduledoc """
  Tool that searches for previously stored solutions matching a
  problem description.

  Routes through `JidoClaw.Solutions.Matcher.find_solutions/2` —
  which combines exact-match (via `Solution.by_signature`) with
  hybrid retrieval (FTS + pgvector + pg_trgm via the `:search`
  action). Returns ranked results by relevance and trust score.

  ## Required scope

  Reads `context.tool_context.workspace_uuid` and
  `context.tool_context.tenant_id`. Fails loudly with
  `:missing_scope` when scope is absent.
  """

  use Jido.Action,
    name: "find_solution",
    description:
      "Search for previously stored solutions matching a problem description. " <>
        "Returns ranked results by relevance and trust score.",
    category: "solutions",
    tags: ["solutions", "read"],
    output_schema: [
      results: [type: :string, required: true],
      count: [type: :integer, required: true]
    ],
    schema: [
      problem_description: [
        type: :string,
        required: true,
        doc: "Description of the problem to find solutions for"
      ],
      language: [
        type: :string,
        required: false,
        doc: "Filter by language"
      ],
      framework: [
        type: :string,
        required: false,
        doc: "Filter by framework"
      ],
      limit: [
        type: :integer,
        required: false,
        doc: "Max results (default: 5)"
      ]
    ]

  alias JidoClaw.Solutions.Matcher
  alias JidoClaw.Tools.MCPScope

  @impl true
  def run(params, context) do
    context = MCPScope.with_default(context)
    tool_context = Map.get(context, :tool_context, %{})
    tenant_id = Map.get(tool_context, :tenant_id)
    workspace_uuid = Map.get(tool_context, :workspace_uuid)

    cond do
      is_nil(tenant_id) -> {:error, :missing_scope_tenant}
      is_nil(workspace_uuid) -> {:error, :missing_scope_workspace}
      true -> search(params, tenant_id, workspace_uuid)
    end
  end

  defp search(params, tenant_id, workspace_uuid) do
    limit = Map.get(params, :limit, 5)

    opts =
      [
        language: Map.get(params, :language),
        framework: Map.get(params, :framework),
        limit: limit,
        tenant_id: tenant_id,
        workspace_id: workspace_uuid,
        local_visibility: [:local, :shared, :public],
        cross_workspace_visibility: [:public]
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    results = Matcher.find_solutions(params.problem_description, opts)

    if results == [] do
      {:ok, %{results: "No matching solutions found", count: 0}}
    else
      formatted = format_results(results)
      {:ok, %{results: formatted, count: length(results)}}
    end
  end

  defp format_results(results) do
    results
    |> Enum.with_index(1)
    |> Enum.map_join("\n\n", fn {%{solution: s, score: score, match_type: match_type}, idx} ->
      fw = if s.framework, do: "/#{s.framework}", else: ""
      header = "[#{idx}] #{s.language}#{fw} — score: #{Float.round(score, 3)} (#{match_type})"
      solution = "Solution:\n#{s.solution_content}"
      Enum.join([header, solution], "\n")
    end)
  end
end
