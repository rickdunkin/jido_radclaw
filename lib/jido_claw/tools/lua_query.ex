defmodule JidoClaw.Tools.LuaQuery do
  @moduledoc """
  Code-mode query tool (amber AM-1 + jidoka V2-7): run a short read-only
  Lua script server-side against the `jido.*` host bindings, so
  cross-run filter/join/aggregate work happens in the sandbox and the
  intermediate rows never inflate the transcript — one tool call
  replaces a page-and-correlate loop over `workflow_events` /
  `inspect_workflow`.

  Thin by design: scope comes from `context[:tool_context]` (the
  `workflow_status` pattern — the shared `Tools.Action` wrapper already
  runs MCPScope enrichment, the approval gate, the loop guard, and the
  redact/shape/cap tail), and everything else — policy caps, task
  isolation, the sandbox, the binding table, the error taxonomy — lives
  in `JidoClaw.Tools.Lua.Runner`. The schema is `code` only: the model
  cannot raise its own budgets.
  """

  use JidoClaw.Tools.Action,
    name: "lua_query",
    description:
      "Run a short read-only Lua script server-side to filter/join/aggregate workflow " <>
        "runs, events, approval cases, stored solutions, and stored tool outputs in ONE " <>
        "call — bindings: jido.runs(filter), jido.run(id), jido.events(run_id, opts), " <>
        "jido.cases(filter), jido.solutions(query, opts), jido.output(ref, opts). End " <>
        "with `return <value>` and return only the aggregate you need (intermediate " <>
        "rows stay in the sandbox). Call lua_docs first for the binding catalog and caps.",
    category: "introspection",
    tags: ["lua", "workflow", "read"],
    output_schema: [],
    schema: [
      code: [
        type: :string,
        required: true,
        doc:
          "Lua source to execute in the sandbox, typically ending with `return <value>`. " <>
            "No io/os/require/print; jido.* host bindings are read-only."
      ]
    ]

  alias JidoClaw.Tools.Lua.Runner

  @impl Jido.Action
  def run(%{code: code}, context) do
    tool_context = Map.get(context, :tool_context, %{})

    case Map.get(tool_context, :tenant_id) do
      tenant_id when is_binary(tenant_id) and tenant_id != "" ->
        Runner.eval(code, context)

      _ ->
        {:error, :tenant_required}
    end
  end
end
