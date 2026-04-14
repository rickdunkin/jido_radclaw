defmodule JidoClaw.Tools.StoreSolution do
  @moduledoc """
  Tool that stores a verified coding solution for future reuse.
  Solutions are indexed by problem fingerprint and searchable by language,
  framework, and content.
  """

  use Jido.Action,
    name: "store_solution",
    description:
      "Store a verified coding solution for future reuse. " <>
        "Solutions are indexed by problem fingerprint and searchable by language, framework, and content.",
    category: "solutions",
    tags: ["solutions", "write"],
    output_schema: [
      id: [type: :string, required: true],
      signature: [type: :string, required: true],
      status: [type: :string, required: true]
    ],
    schema: [
      problem_description: [
        type: :string,
        required: true,
        doc: "Description of the problem this solution solves"
      ],
      solution_content: [
        type: :string,
        required: true,
        doc: "The solution code or approach"
      ],
      language: [
        type: :string,
        required: true,
        doc: "Programming language (e.g. elixir, python, typescript)"
      ],
      framework: [
        type: :string,
        required: false,
        doc: "Framework if applicable (e.g. phoenix, react, django)"
      ],
      tags: [
        type: {:list, :string},
        required: false,
        doc: "Tags for categorization"
      ]
    ]

  @impl true
  def run(params, _context) do
    signature =
      JidoClaw.Solutions.Fingerprint.signature(
        params.problem_description,
        params.language,
        Map.get(params, :framework)
      )

    attrs = %{
      problem_description: params.problem_description,
      solution_content: params.solution_content,
      language: params.language,
      framework: Map.get(params, :framework),
      tags: Map.get(params, :tags, []),
      problem_signature: signature
    }

    case JidoClaw.Solutions.Store.store_solution(attrs) do
      {:ok, solution} ->
        {:ok, %{id: solution.id, signature: signature, status: "stored"}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
