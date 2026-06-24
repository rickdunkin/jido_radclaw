defmodule JidoClaw.Tools.ListRealDirectory do
  @moduledoc """
  List a directory in the **real project tree, read-only** (AR-8b-2 F3).

  A sketch worker runs jailed to `<real>/.prototypes/<uuid>/`; this tool lets it
  *explore* the real project's layout without being able to mutate it. Listings
  are jailed to the real base (`JidoClaw.Tools.RealTree.resolver_opts/1`) and
  fail **closed** unless the call carries a `sandbox: :prototype` context. Local
  paths only — remote schemes are forbidden (the shared listing core's remote
  branch is gated by `local_only`).

  Reuses `JidoClaw.Tools.ListDirectory.list/2`, so it matches `list_directory`'s
  current behavior exactly.
  """

  use JidoClaw.Tools.Action,
    name: "list_real_directory",
    description:
      "List files and directories in the REAL project tree (read-only). Use to explore the real project's layout to inform a sandbox prototype — you cannot write to the real tree. Returns file names with type indicators. Local paths only.",
    category: "filesystem",
    tags: ["io", "read"],
    output_schema: [
      path: [type: :string, required: true],
      entries: [type: :string, required: true],
      total: [type: :integer, required: true]
    ],
    schema: [
      path: [
        type: :string,
        default: ".",
        doc: "Directory path to list in the real project tree (local only)"
      ],
      pattern: [type: :string, doc: "Optional glob pattern (e.g. '**/*.ex')"],
      max_results: [type: :integer, default: 200, doc: "Max entries to return"]
    ]

  alias JidoClaw.Tools.ListDirectory
  alias JidoClaw.Tools.MCPScope
  alias JidoClaw.Tools.RealTree

  @impl Jido.Action
  def run(params, context) do
    MCPScope.wrap(:list_real_directory, params, context, fn enriched ->
      case RealTree.resolver_opts(get_in(enriched, [:tool_context])) do
        {:ok, ws_opts} -> ListDirectory.list(params, ws_opts)
        {:error, message} -> {:error, message}
      end
    end)
  end
end
