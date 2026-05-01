defmodule JidoClaw.Tools.StoreSolution do
  @moduledoc """
  Tool that stores a verified coding solution for future reuse.

  Solutions are persisted via `JidoClaw.Solutions.Solution.store/1`,
  which:

    1. Validates the cross-tenant FK invariant (workspace and
       optional session must belong to the supplied tenant).
    2. Redacts secrets from `solution_content` via the
       `Redaction.Transcript` walker.
    3. Resolves initial `embedding_status` from the workspace's
       `embedding_policy` (`:disabled` workspaces stamp `:disabled`,
       otherwise `:pending`).
    4. Hints the BackfillWorker via `after_transaction` so the
       embedding lands within ~1s in dev rather than waiting for the
       periodic scan.

  ## Required scope

  Reads `context.tool_context.workspace_uuid` and
  `context.tool_context.tenant_id`. Optional: `:session_uuid`,
  `:user_id` (used to populate `created_by_user_id`). Fails loudly
  with `:missing_scope` when scope is absent — no v0.5.x
  "workspace = nil means everywhere" fallback.
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

  alias JidoClaw.Solutions.Solution
  alias JidoClaw.Tools.MCPScope

  @impl true
  def run(params, context) do
    context = MCPScope.with_default(context)
    tool_context = Map.get(context, :tool_context, %{})
    tenant_id = Map.get(tool_context, :tenant_id)
    workspace_uuid = Map.get(tool_context, :workspace_uuid)
    session_uuid = Map.get(tool_context, :session_uuid)
    created_by_user_id = Map.get(tool_context, :user_id)

    cond do
      is_nil(tenant_id) -> {:error, :missing_scope_tenant}
      is_nil(workspace_uuid) -> {:error, :missing_scope_workspace}
      true -> store(params, tenant_id, workspace_uuid, session_uuid, created_by_user_id)
    end
  end

  defp store(params, tenant_id, workspace_uuid, session_uuid, created_by_user_id) do
    signature =
      JidoClaw.Solutions.Fingerprint.signature(
        params.problem_description,
        params.language,
        Map.get(params, :framework)
      )

    attrs = %{
      problem_signature: signature,
      solution_content: params.solution_content,
      language: params.language,
      framework: Map.get(params, :framework),
      tags: Map.get(params, :tags, []),
      sharing: :local,
      tenant_id: tenant_id,
      workspace_id: workspace_uuid,
      session_id: session_uuid,
      created_by_user_id: created_by_user_id
    }

    case Solution.store(attrs) do
      {:ok, solution} ->
        {:ok, %{id: solution.id, signature: signature, status: "stored"}}

      {:error, reason} ->
        {:error, format_error(reason)}
    end
  end

  defp format_error(%Ash.Error.Invalid{errors: errors}) do
    errors
    |> Enum.map(&inspect/1)
    |> Enum.join("; ")
  end

  defp format_error(reason), do: inspect(reason)
end
