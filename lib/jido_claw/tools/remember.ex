defmodule JidoClaw.Tools.Remember do
  @moduledoc """
  Save a fact, pattern, decision, or preference to persistent memory.

  v0.6.3 routes through `JidoClaw.Memory.remember_from_model/2`, which
  writes a `Memory.Fact` row with `source: :model_remember`,
  `trust_score: 0.4`. Returns `:ok` on every persistence path; the
  always-`:ok` contract is part of the legacy contract that lets a
  tool call survive a transient DB hiccup without crashing the agent.

  Schema-compatibility shim: the old API took `key` / `content` /
  `type`. The new resource keeps `key → label`, `content → content`,
  and folds `type` into the `tags` list (single element). The schema
  exposed to the model is unchanged.
  """

  use Jido.Action,
    name: "remember",
    description:
      "Save a fact, pattern, decision, or preference to persistent memory. " <>
        "Memories persist across sessions. Use this to record project conventions, " <>
        "architectural decisions, user preferences, and recurring patterns you discover.",
    category: "memory",
    tags: ["memory", "write"],
    output_schema: [
      key: [type: :string, required: true],
      type: [type: :string, required: true],
      status: [type: :string, required: true]
    ],
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
  def run(params, context) do
    type = Map.get(params, :type, "fact")
    tool_context = Map.get(context, :tool_context, %{})

    JidoClaw.Memory.remember_from_model(
      %{key: params.key, content: params.content, type: type},
      tool_context
    )

    {:ok, %{key: params.key, type: type, status: "remembered"}}
  end
end
