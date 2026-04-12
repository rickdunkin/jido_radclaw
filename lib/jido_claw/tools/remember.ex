defmodule JidoClaw.Tools.Remember do
  @moduledoc """
  Tool that saves a fact, pattern, decision, or preference to persistent memory.
  Memories survive across sessions and are stored in .jido/memory.json.
  """

  use Jido.Action,
    name: "remember",
    description:
      "Save a fact, pattern, decision, or preference to persistent memory. " <>
        "Memories persist across sessions. Use this to record project conventions, " <>
        "architectural decisions, user preferences, and recurring patterns you discover.",
    schema: [
      key: [
        type: :string,
        required: true,
        doc:
          "Short identifier/topic for this memory (e.g. 'db_schema', 'preferred_style', 'api_base_url')"
      ],
      content: [
        type: :string,
        required: true,
        doc: "The content to remember"
      ],
      type: [
        type: :string,
        required: false,
        doc: "Memory type: fact, pattern, decision, preference (default: fact)"
      ]
    ]

  @impl true
  def run(params, _context) do
    type = Map.get(params, :type, "fact")
    JidoClaw.Memory.remember(params.key, params.content, type)
    {:ok, %{key: params.key, type: type, status: "remembered"}}
  end
end
