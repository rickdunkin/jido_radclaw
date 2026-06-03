defmodule JidoClaw.Tools.ForgeStatus do
  @moduledoc """
  Return tenant-scoped Forge session status.
  """

  use JidoClaw.Tools.Action,
    name: "forge_status",
    description: "Return tenant-scoped Forge active session status.",
    category: "introspection",
    tags: ["forge", "read"],
    output_schema: [
      tenant_id: [type: :string, required: true],
      workspace_id: [type: :string, required: false],
      active_count: [type: :integer, required: true],
      sessions: [type: {:list, :map}, required: true],
      generated_at: [type: :string, required: true]
    ],
    schema: [
      workspace_id: [
        type: :string,
        required: false,
        doc: "Optional workspace UUID filter."
      ]
    ]

  alias JidoClaw.ForgeView

  @impl true
  def run(params, context) do
    tool_context = Map.get(context, :tool_context, %{})

    case Map.get(tool_context, :tenant_id) do
      tenant_id when is_binary(tenant_id) and tenant_id != "" ->
        scope =
          %{
            tenant_id: tenant_id,
            workspace_id:
              Map.get(params, :workspace_id) ||
                Map.get(tool_context, :workspace_uuid) ||
                Map.get(tool_context, :workspace_id)
          }

        case ForgeView.list(scope) do
          {:ok, view} -> {:ok, ForgeView.to_mcp_map(view)}
          {:error, _} = err -> err
        end

      _ ->
        {:error, :tenant_required}
    end
  end
end
