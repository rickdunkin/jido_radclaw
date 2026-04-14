defmodule JidoClaw.Tools.FindSolution do
  @moduledoc """
  Tool that searches for previously stored solutions matching a problem description.
  Returns ranked results by relevance and trust score.
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

  @impl true
  def run(params, _context) do
    limit = Map.get(params, :limit, 5)

    opts =
      [
        language: Map.get(params, :language),
        framework: Map.get(params, :framework),
        limit: limit
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    results = JidoClaw.Solutions.Matcher.find_solutions(params.problem_description, opts)

    if results == [] do
      {:ok, %{results: "No matching solutions found", count: 0}}
    else
      formatted =
        results
        |> Enum.with_index(1)
        |> Enum.map_join("\n\n", fn {%{solution: s, score: score, match_type: match_type}, idx} ->
          fw = if s.framework, do: "/#{s.framework}", else: ""
          header = "[#{idx}] #{s.language}#{fw} — score: #{Float.round(score, 3)} (#{match_type})"
          solution = "Solution:\n#{s.solution_content}"
          Enum.join([header, solution], "\n")
        end)

      {:ok, %{results: formatted, count: length(results)}}
    end
  end
end
