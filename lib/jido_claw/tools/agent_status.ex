defmodule JidoClaw.Tools.AgentStatus do
  @moduledoc """
  Return the live `%JidoClaw.AgentView{}` snapshot for a session — agent
  template, status, recent events, handoff state, compaction.

  Tenant is read strictly from `context.tool_context.tenant_id` (not an
  MCP-overridable param), matching the convention used by the other
  tenant-aware tools.
  """

  use JidoClaw.Tools.Action,
    name: "agent_status",
    description:
      "Return the live AgentView snapshot for a session: agent template, status, " <>
        "recent events, handoff state, compaction.",
    category: "introspection",
    tags: ["agent", "read"],
    output_schema: [
      tenant_id: [type: :string, required: true],
      session_id: [type: :string, required: true],
      agent_template: [type: :string, required: false],
      status: [type: :string, required: true],
      request_id: [type: :string, required: false],
      message_count: [type: :integer, required: true],
      summary: [type: :map, required: false],
      handoff: [type: :map, required: false],
      compaction: [type: :map, required: false],
      recent_events: [type: {:list, :map}, required: true]
    ],
    schema: [
      session_id: [
        type: :string,
        required: true,
        doc: "Runtime session_id (external_id)."
      ],
      events_limit: [
        type: :pos_integer,
        required: false,
        doc: "Cap on returned events (after category filter). Default 100."
      ]
    ]

  alias JidoClaw.AgentView

  @impl true
  def run(params, context) do
    tool_context = Map.get(context, :tool_context, %{})

    case Map.get(tool_context, :tenant_id) do
      tenant_id when is_binary(tenant_id) ->
        snapshot(tenant_id, params)

      _ ->
        {:error, :tenant_required}
    end
  end

  defp snapshot(tenant_id, params) do
    opts =
      []
      |> maybe_put(:events_limit, Map.get(params, :events_limit))

    case AgentView.snapshot(
           %{tenant_id: tenant_id, session_id: params.session_id},
           opts
         ) do
      {:ok, view} ->
        {:ok, to_output(view)}

      {:error, _} = err ->
        err
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp to_output(%AgentView{} = view) do
    full = AgentView.to_mcp_map(view)

    %{
      tenant_id: full["tenant_id"],
      session_id: full["session_id"],
      agent_template: full["agent_template"],
      status: full["status"],
      request_id: full["request_id"],
      message_count: full["message_count"] || 0,
      summary: full["summary"] || %{},
      handoff: full["handoff_owner"],
      compaction: full["compaction"],
      recent_events: full["events"] || []
    }
  end
end
