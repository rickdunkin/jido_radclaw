defmodule JidoClaw.Tools.InspectAgent do
  @moduledoc """
  Return a `%JidoClaw.Inspection.Summary{}` for the given target — module,
  session id, or request id.

  Tenant is read strictly from `context.tool_context.tenant_id` (not an
  MCP-overridable param). Bare child-agent ids are intentionally not accepted
  at this MCP boundary; child-agent status is exposed through `swarm_status`,
  which proves tenant ownership before reading `AgentTracker`.

  `:memory` IS exposed (it is tenant-scoped via `Memory.Scope.resolve`,
  tenant read strictly from `tool_context.tenant_id`) but is slimmed to
  `%{scope_kind, blocks_count}` — both the raw-UUID `scope` sub-map and
  the FK embedded in `namespace` (`"session:<uuid>"` would leak the
  session UUID, e.g. on `kind: "request"`) are dropped at the boundary.
  Local Elixir callers keep the full `namespace`/`scope`.
  """

  use JidoClaw.Tools.Action,
    name: "inspect_agent",
    description:
      "Inspect an agent target (module name, session id, or request id) " <>
        "and return a summary of definition + current running state.",
    category: "introspection",
    tags: ["agent", "read"],
    output_schema: [
      system_prompt: [type: :string, required: false],
      model: [type: :string, required: false],
      tool_names: [type: {:list, :string}, required: true],
      mcp_tools: [type: {:list, :string}, required: true],
      context_preview: [type: :string, required: false],
      user_message: [type: :string, required: false],
      handoffs: [type: :map, required: false],
      compaction: [type: :map, required: false],
      memory: [type: :map, required: false],
      usage: [type: :map, required: true],
      duration_ms: [type: :integer, required: false],
      status: [type: :string, required: false],
      error: [type: :map, required: false],
      message_count: [type: :integer, required: false],
      request_id: [type: :string, required: false],
      input_kind: [type: :string, required: true]
    ],
    schema: [
      target: [
        type: :string,
        required: true,
        doc: "Module name (\"JidoClaw.Agent\"), session id, or request id."
      ],
      kind: [
        type: {:in, ~w(module session request)},
        required: false,
        default: "session",
        doc: "Dispatch hint. \"request\" routes to inspect_request."
      ]
    ]

  alias JidoClaw.Core.JsonSafe
  alias JidoClaw.Inspection

  @impl Jido.Action
  def run(params, context) do
    tool_context = Map.get(context, :tool_context, %{})
    tenant_id = Map.get(tool_context, :tenant_id)
    kind = Map.get(params, :kind, "session")
    target = params.target

    case dispatch(kind, target, tenant_id) do
      {:ok, summary} -> {:ok, project(summary)}
      {:error, _} = err -> err
    end
  end

  defp dispatch("module", target, _tenant_id) do
    case to_module(target) do
      {:ok, module} -> Inspection.inspect_agent(module)
      :error -> {:error, :unknown_target}
    end
  end

  defp dispatch("session", target, tenant_id) when is_binary(tenant_id) do
    Inspection.inspect_agent(%{tenant_id: tenant_id, session_id: target})
  end

  defp dispatch("session", _target, _), do: {:error, :tenant_required}

  defp dispatch("request", target, tenant_id) when is_binary(tenant_id) do
    Inspection.inspect_request(target, tenant_id: tenant_id)
  end

  defp dispatch("request", _target, _), do: {:error, :tenant_required}

  defp dispatch(_kind, _target, _tenant_id), do: {:error, :unknown_kind}

  defp to_module(target) when is_binary(target) do
    {:ok, String.to_existing_atom("Elixir." <> target)}
  rescue
    ArgumentError -> :error
  end

  # Projection rule: top-level keys stay atoms (required by `output_schema`
  # and the tool tests), but every nested term is normalized through
  # `JsonSafe.encode/1` so no leaf atom / DateTime / module reaches the
  # MCP boundary. Nested maps (`usage`, `compaction`, `handoffs`, `error`)
  # therefore come back string-keyed.
  defp project(%Inspection.Summary{} = s) do
    memory =
      s.memory
      |> slim_memory()
      |> JsonSafe.encode()

    %{
      system_prompt: s.system_prompt,
      model: stringify_nilable(s.model),
      tool_names: s.tool_names,
      mcp_tools: s.mcp_tools,
      context_preview: s.context_preview,
      # Already clamped to `@context_preview_limit` in `Inspection`; passed
      # through verbatim like `context_preview`, no duplicate length logic.
      user_message: s.user_message,
      handoffs: JsonSafe.encode(s.handoffs),
      compaction: JsonSafe.encode(s.compaction),
      memory: memory,
      usage: JsonSafe.encode(s.usage),
      duration_ms: s.duration_ms,
      status: stringify_nilable(s.status),
      error: JsonSafe.encode(s.error),
      message_count: s.message_count,
      request_id: s.request_id,
      input_kind: Atom.to_string(s.input_kind)
    }
  end

  # `model`/`status` are atom-or-string-or-nil. A bare `to_string/1` would
  # emit `"nil"` (nil is an atom) at the MCP boundary, so preserve nil.
  defp stringify_nilable(nil), do: nil
  defp stringify_nilable(value), do: to_string(value)

  # Expose only the scope *kind* + block count at the MCP boundary — never
  # an FK or raw UUID. Both the `scope` sub-map and the FK embedded in
  # `namespace` are dropped; routing through `JsonSafe.encode/1` (above)
  # then string-keys the result like the other nested maps. Anything that
  # isn't the resolved shape (incl. `nil`) becomes `nil`.
  defp slim_memory(%{blocks_count: count, scope: %{scope_kind: kind}}),
    do: %{scope_kind: to_string(kind), blocks_count: count}

  defp slim_memory(_), do: nil
end
