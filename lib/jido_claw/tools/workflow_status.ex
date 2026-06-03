defmodule JidoClaw.Tools.WorkflowStatus do
  @moduledoc """
  Return tenant-scoped workflow run status.
  """

  use JidoClaw.Tools.Action,
    name: "workflow_status",
    description: "Return tenant-scoped workflow active and recent run status.",
    category: "introspection",
    tags: ["workflow", "read"],
    output_schema: [
      tenant_id: [type: :string, required: true],
      active_count: [type: :integer, required: true],
      active_runs: [type: {:list, :map}, required: true],
      recent_completions: [type: {:list, :map}, required: true],
      generated_at: [type: :string, required: true]
    ],
    schema: []

  alias JidoClaw.WorkflowView

  @impl true
  def run(_params, context) do
    tool_context = Map.get(context, :tool_context, %{})

    case Map.get(tool_context, :tenant_id) do
      tenant_id when is_binary(tenant_id) and tenant_id != "" ->
        case WorkflowView.list(%{tenant_id: tenant_id}) do
          {:ok, view} -> {:ok, WorkflowView.to_mcp_map(view)}
          {:error, _} = err -> err
        end

      _ ->
        {:error, :tenant_required}
    end
  end
end
