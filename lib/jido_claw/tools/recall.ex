defmodule JidoClaw.Tools.Recall do
  @moduledoc """
  Tool that searches persistent memory for past facts, patterns, decisions,
  and preferences stored with the remember tool.
  """

  use Jido.Action,
    name: "recall",
    description:
      "Search persistent memory for past facts, patterns, decisions, and preferences. " <>
        "Use this at the start of a session or task to check what you already know about " <>
        "the project — conventions, decisions, and context from previous sessions.",
    category: "memory",
    tags: ["memory", "read"],
    output_schema: [
      results: [type: :string, required: true],
      count: [type: :integer, required: true]
    ],
    schema: [
      query: [
        type: :string,
        required: true,
        doc: "Search query to find relevant memories (substring match on key, content, and type)"
      ],
      limit: [
        type: :integer,
        required: false,
        doc: "Max results to return (default: 10)"
      ]
    ]

  @impl true
  def run(params, _context) do
    limit = Map.get(params, :limit, 10)
    results = JidoClaw.Memory.recall(params.query, limit: limit)

    if results == [] do
      {:ok, %{results: "No memories found matching '#{params.query}'", count: 0}}
    else
      formatted =
        Enum.map_join(results, "\n\n", fn mem ->
          "[#{mem.type}] #{mem.key}: #{mem.content}"
        end)

      {:ok, %{results: formatted, count: length(results)}}
    end
  end
end
