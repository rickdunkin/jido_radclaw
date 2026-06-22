defmodule JidoClaw.Tools.InspectWorkflow do
  @moduledoc """
  Inspect a single workflow run by id and return its status, timing, and — for a
  deterministic route-composer run — the live observe view: route, waves,
  held/dropped stages, live signals, available artifacts (names only), and the
  authoritative blocked-on-gate signal (AR-2 Phase 5, §10.2).

  Tenant is read strictly from `context.tool_context.tenant_id` (not an
  MCP-overridable param), the `workflow_status` precedent. The single-run
  complement to the `workflow_status` tenant rollup — the `agent_status` →
  `inspect_agent` convention. Published by `JidoClaw.MCPServer` only;
  deliberately absent from the in-REPL agent's tool list (consistent with
  `workflow_status`).

  The composer view is built seed-free from the durable event log by
  `JidoClaw.RouteComposer.Observe` — it is names/labels only (no artifact
  values), and the base run view is operator-scoped (`Orchestration.Visibility`)
  so `error`/`result_summary` are redacted/truncated like every other MCP
  workflow surface.
  """

  use JidoClaw.Tools.Action,
    name: "inspect_workflow",
    description:
      "Inspect a single workflow run by id (see workflow_status for ids). Returns status, " <>
        "timing, and — for a route-composer run — its live route, waves, held/dropped stages, " <>
        "live signals, and whether it is blocked awaiting a human gate.",
    category: "introspection",
    tags: ["workflow", "read"],
    # Declare only the type-stable top-level fields (jido_action validates only
    # specified fields, and only when present). `composer` is deliberately NOT
    # declared: it is a `JsonSafe.encode/1`d nested map (so STRING-keyed), and
    # NimbleOptions `:map` is `{:map, :atom, :any}` — it would reject string keys.
    # It passes through as an unvalidated extra key, exactly like the other
    # JsonSafe'd nested values below (`result_summary`/`deadline`/timestamps/
    # `error`) — extra response keys are allowed by jido_action and the Anubis
    # JSON-schema layer.
    output_schema: [
      run_id: [type: :string, required: true],
      name: [type: :string, required: false],
      workflow_type: [type: :string, required: false],
      # `run_status`, NOT `status`: the shared `Tools.Error.normalize_result/1`
      # promotes `{:ok, %{status: "failed"}}` to an `{:error, _}` (the soft-fail
      # convention for action tools). A read tool that reports a run's terminal
      # `:failed` status must stay `{:ok, _}` — inspecting a failed run is a
      # normal, successful read — so the run's status rides a non-colliding key.
      run_status: [type: :string, required: false],
      duration_ms: [type: :integer, required: false]
    ],
    schema: [
      run_id: [
        type: :string,
        required: true,
        doc: "Id of the workflow run to inspect (see workflow_status)."
      ]
    ]

  alias JidoClaw.Core.JsonSafe
  alias JidoClaw.WorkflowView

  @impl Jido.Action
  def run(%{run_id: run_id}, context) do
    tool_context = Map.get(context, :tool_context, %{})

    case Map.get(tool_context, :tenant_id) do
      tenant when is_binary(tenant) and tenant != "" ->
        case WorkflowView.snapshot(run_id, %{tenant_id: tenant}) do
          {:ok, snapshot} -> {:ok, project(snapshot)}
          {:error, _} = err -> err
        end

      _ ->
        {:error, :tenant_required}
    end
  end

  # Projection rule (mirrors `tools/inspect_agent.ex`): top-level keys stay ATOMS
  # — `output_schema` splits on atom keys, so a string-keyed top level would fail
  # required-key validation — while every nested term is `JsonSafe.encode/1`d, so
  # no leaf atom / DateTime reaches the MCP boundary (the nested `composer`
  # therefore comes back string-keyed, with `reason`/markers as strings).
  #
  # Optional keys are added ONLY when non-nil. For the schema-declared optionals
  # (`duration_ms`, `name`, …) this is required: jido_action validates a field
  # when PRESENT, so `duration_ms: nil` would fail `:integer`. For `composer`
  # (not schema-declared) it is the intended SHAPE: a non-composer run omits the
  # key entirely (absence = "not a composer run"), never `composer: nil`.
  defp project(s) do
    %{run_id: s.run_id}
    |> put_present(:name, s.name)
    |> put_present(:workflow_type, s.workflow_type)
    |> put_present(:run_status, stringify_nilable(s.status))
    |> put_present(:duration_ms, s.duration_ms)
    |> put_present(:started_at, JsonSafe.encode(s.started_at))
    |> put_present(:completed_at, JsonSafe.encode(s.completed_at))
    |> put_present(:error, s.error)
    |> put_present(:result_summary, JsonSafe.encode(s.result_summary))
    |> put_present(:deadline, JsonSafe.encode(s.deadline))
    |> put_present(:composer, encode_present(Map.get(s, :composer)))
  end

  # Add the key only for a non-nil value (an optional output_schema field is
  # validated when PRESENT, so a present-but-nil value would fail its type).
  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  # Encode only when there's something to encode (keeps `composer` ABSENT on a
  # non-composer run rather than `JsonSafe.encode(nil)`).
  defp encode_present(nil), do: nil
  defp encode_present(value), do: JsonSafe.encode(value)

  # `status` is atom|string|nil; a bare `to_string/1` would emit "nil" (nil is an
  # atom). Mirror `tools/inspect_agent.ex`.
  defp stringify_nilable(nil), do: nil
  defp stringify_nilable(value), do: to_string(value)
end
