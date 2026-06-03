defmodule JidoClaw.Tools.SwarmStatus do
  @moduledoc """
  Return the tenant-scoped child-agent swarm projection.
  """

  use JidoClaw.Tools.Action,
    name: "swarm_status",
    description: "Return the tenant-scoped child-agent swarm rollup.",
    category: "introspection",
    tags: ["agent", "swarm", "read"],
    output_schema: [
      tenant_id: [type: :string, required: true],
      session_id: [type: :string, required: false],
      session_uuid: [type: :string, required: false],
      workspace_id: [type: :string, required: false],
      workspace_uuid: [type: :string, required: false],
      agents: [type: {:list, :map}, required: true],
      running_count: [type: :integer, required: true],
      done_count: [type: :integer, required: true],
      error_count: [type: :integer, required: true],
      total_tokens: [type: :integer, required: true],
      total_tool_calls: [type: :integer, required: true],
      generated_at: [type: :string, required: true]
    ],
    schema: [
      session_id: [
        type: :string,
        required: false,
        doc: "Optional runtime session id filter."
      ],
      workspace_uuid: [
        type: :string,
        required: false,
        doc: "Optional workspace UUID filter (scopes the rollup to one workspace's agents)."
      ],
      workspace_id: [
        type: :string,
        required: false,
        doc:
          "Deprecated alias for `workspace_uuid`; mapped onto the same scope. Prefer `workspace_uuid`."
      ]
    ]

  alias JidoClaw.SwarmView
  alias JidoClaw.Tools.SwarmScope

  @impl true
  def run(params, context) do
    tool_context = Map.get(context, :tool_context, %{})

    with {:ok, scope_opts} <- SwarmScope.scope_from_tool_context(tool_context) do
      scope_opts =
        scope_opts
        |> put_param(:session_id, Map.get(params, :session_id))
        # `workspace_id` is a documented deprecated alias for the canonical
        # `workspace_uuid` param — both land on the `:workspace_uuid` scope key.
        |> put_param(
          :workspace_uuid,
          Map.get(params, :workspace_uuid) || Map.get(params, :workspace_id)
        )

      case SwarmView.list(scope_opts) do
        {:ok, view} -> {:ok, SwarmView.to_mcp_map(view)}
        {:error, _} = err -> err
      end
    end
  end

  defp put_param(opts, _key, nil), do: opts
  defp put_param(opts, key, value), do: Keyword.put(opts, key, value)
end
