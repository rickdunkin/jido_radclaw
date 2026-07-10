defmodule JidoClaw.Tools.SearchRealCode do
  @moduledoc """
  Search the **real project tree, read-only** (AR-8b-2 F3).

  A sketch worker runs jailed to `<real>/.prototypes/<uuid>/`; this tool lets it
  *find* patterns in the real project (e.g. existing APIs to model a prototype
  on) without being able to mutate it. Searches are jailed to the real base
  (`JidoClaw.Tools.RealTree.resolver_opts/1`) and fail **closed** unless the call
  carries a `sandbox: :prototype` or `:docker` context. Local paths only —
  remote schemes are forbidden.

  Reuses `JidoClaw.Tools.SearchCode.search/2`, including its per-file,
  traversal, aggregate-byte, regex-work, output-retention, and deadline budgets,
  including explicit partial-result notes for oversized files and deadlines.
  """

  use JidoClaw.Tools.Action,
    name: "search_real_code",
    description:
      "Search the REAL project tree recursively with bounded regex/traversal budgets (read-only). Oversized files are skipped and deadline-limited results are explicitly marked partial. Use to find existing APIs/patterns to model a sandbox prototype on — you cannot write to the real tree. Returns matching lines with file paths and line numbers. Local paths only.",
    category: "filesystem",
    tags: ["io", "read"],
    output_schema: [
      matches: [type: :string, required: true],
      total_matches: [type: :integer, required: true]
    ],
    schema: [
      pattern: [type: :string, required: true, doc: "Search pattern (regex supported)"],
      path: [type: :string, default: ".", doc: "Directory to search in (real project tree)"],
      glob: [type: :string, doc: "File pattern filter (e.g. '*.ex', '*.ts')"],
      max_results: [type: :integer, default: 50, doc: "Max results to return"]
    ]

  alias JidoClaw.Tools.MCPScope
  alias JidoClaw.Tools.RealTree
  alias JidoClaw.Tools.SearchCode

  @impl Jido.Action
  def run(%{pattern: _pattern} = params, context) do
    MCPScope.wrap(:search_real_code, params, context, fn enriched ->
      with {:ok, opts} <- RealTree.resolver_opts(get_in(enriched, [:tool_context])) do
        SearchCode.search(params, SearchCode.with_deadline(opts, enriched))
      end
    end)
  end
end
