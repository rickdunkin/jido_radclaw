defmodule JidoClaw.Tools.Recall do
  @moduledoc """
  Search persistent memory for past facts, patterns, decisions, and
  preferences stored with `remember`.

  v0.6.3 delegates to `JidoClaw.Memory.recall/2`, which routes through
  `Memory.Retrieval.search/1` (FTS + pgvector + GIN trigram, RRF
  combined). The lexical-pool path uses GIN trigram on
  `lexical_text`, which subsumes the v0.5.x substring scanner — any
  query that matched the old store will still match here.

  Returns the same `[%{key, content, type, created_at, updated_at}]`
  shape the legacy module produced so the formatter below works
  unchanged.
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
  def run(params, context) do
    limit = Map.get(params, :limit, 10)
    tool_context = Map.get(context, :tool_context, %{})

    results =
      JidoClaw.Memory.recall(params.query, tool_context: tool_context, limit: limit)

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
