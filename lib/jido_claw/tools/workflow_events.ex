defmodule JidoClaw.Tools.WorkflowEvents do
  @moduledoc """
  Read a workflow run's raw `WorkflowEvent` feed (seq / kind / occurred_at /
  payload / metadata) in seq order — the `get_logs_on_task` analogue, the raw
  complement to `inspect_workflow`'s *derived* composer summary (G2-1a).

  Tenant is read strictly from `context.tool_context.tenant_id` (not an
  MCP-overridable param), the `workflow_status` / `inspect_workflow` precedent.
  Published by `JidoClaw.MCPServer` only; deliberately absent from the in-REPL
  agent's tool list (consistent with `workflow_status` / `inspect_workflow`).

  The feed is **byte-paginated**: `WorkflowView.event_feed/3` bounds both the
  whole page and every individual event against a serialized-size budget, so an
  oversized event's `payload`/`metadata` collapse to a bounded
  `"truncated" => true` marker rather than blowing the context. Page forward by
  passing the returned `next_seq` back as `after_seq`; `next_seq` is `nil` on the
  final page. Event payloads are redacted at append time and re-scrubbed +
  leaf-capped by the shared tool wrapper. A read failure on an existing run
  surfaces `:event_feed_unavailable`, never a misleading empty page.
  """

  use JidoClaw.Tools.Action,
    name: "workflow_events",
    description:
      "Read a workflow run's raw event feed (seq, kind, occurred_at, payload, metadata) in " <>
        "seq order (see workflow_status/inspect_workflow for run ids). Byte-bounded and " <>
        "paginated: pass the returned next_seq back as after_seq to page forward until it is null.",
    category: "introspection",
    tags: ["workflow", "read"],
    # Declare only the type-stable top-level scalars (jido_action validates a
    # field only when present). `events` is deliberately NOT declared: it is a
    # list of STRING-keyed, `JsonSafe`'d maps, and NimbleOptions `:map` is
    # `{:map, :atom, :any}` — `{:list, :map}` would reject string keys. It passes
    # through as an unvalidated extra key (the `inspect_workflow` `composer`
    # precedent — extra response keys are allowed by jido_action + the Anubis
    # JSON-schema layer).
    output_schema: [
      run_id: [type: :string, required: true],
      # `run_status`, NOT `status`: the shared `Tools.Error.normalize_result/1`
      # promotes `{:ok, %{status: "failed"}}` to an `{:error, _}`. Reading a
      # failed run's feed is a normal, successful read — so status rides a
      # non-colliding key (the `inspect_workflow` precedent).
      run_status: [type: :string, required: false],
      count: [type: :integer, required: true],
      next_seq: [type: :integer, required: false]
    ],
    schema: [
      run_id: [
        type: :string,
        required: true,
        doc: "Id of the workflow run whose event feed to read (see workflow_status)."
      ],
      after_seq: [
        type: :integer,
        required: false,
        doc: "Return only events with seq > after_seq; pass back the previous next_seq to page."
      ],
      limit: [
        type: :integer,
        required: false,
        doc: "Page target (default 50, capped 200); a page may be smaller as it is byte-bounded."
      ]
    ]

  alias JidoClaw.WorkflowView

  @impl Jido.Action
  def run(%{run_id: run_id} = params, context) do
    tool_context = Map.get(context, :tool_context, %{})

    case Map.get(tool_context, :tenant_id) do
      tenant when is_binary(tenant) and tenant != "" ->
        feed_opts = Map.to_list(Map.take(params, [:after_seq, :limit]))

        case WorkflowView.event_feed(run_id, %{tenant_id: tenant}, feed_opts) do
          {:ok, feed} -> {:ok, project(feed)}
          {:error, _} = err -> err
        end

      _ ->
        {:error, :tenant_required}
    end
  end

  # Top-level keys stay ATOMS (output_schema splits on atom keys); `events` is
  # already a list of string-keyed, `JsonSafe`'d maps from `event_feed/3`, so it
  # rides through unchanged as an unvalidated extra key. Optional keys are added
  # only when non-nil (a present-but-nil `next_seq` would fail its `:integer`).
  defp project(feed) do
    %{run_id: feed.run_id, count: feed.count, events: feed.events}
    |> put_present(:run_status, stringify_nilable(feed.run_status))
    |> put_present(:next_seq, feed.next_seq)
  end

  # Add the key only for a non-nil value (an optional output_schema field is
  # validated when PRESENT, so a present-but-nil value would fail its type).
  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  # `status` is atom|string|nil; a bare `to_string/1` would emit "nil" (nil is an
  # atom). Mirror `tools/inspect_workflow.ex`.
  defp stringify_nilable(nil), do: nil
  defp stringify_nilable(value), do: to_string(value)
end
