defmodule JidoClaw.Tools.SearchRealCode do
  @moduledoc """
  Search the **real project tree, read-only** (AR-8b-2 F3).

  A sketch worker runs jailed to `<real>/.prototypes/<uuid>/`; this tool lets it
  *find* patterns in the real project (e.g. existing APIs to model a prototype
  on) without being able to mutate it. Searches are jailed to the real base
  (`JidoClaw.Tools.RealTree.resolver_opts/1`) and fail **closed** unless the call
  carries a `sandbox: :prototype` context. Local paths only — remote schemes are
  forbidden.

  Reuses `JidoClaw.Tools.SearchCode.search/2`, so it matches `search_code`'s
  current behavior exactly (including reading files without a `FilePayloadLimit`
  cap — adding one would change existing `search_code` behavior, out of scope).
  """

  use JidoClaw.Tools.Action,
    name: "search_real_code",
    description:
      "Search the REAL project tree for a pattern using grep (read-only). Use to find existing APIs/patterns in the real project to model a sandbox prototype on — you cannot write to the real tree. Returns matching lines with file paths and line numbers. Local paths only.",
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
        SearchCode.search(params, opts)
      end
    end)
  end
end
