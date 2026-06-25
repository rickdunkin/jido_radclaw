defmodule JidoClaw.Tools.ReadRealFile do
  @moduledoc """
  Read a file from the **real project tree, read-only** (AR-8b-2 F3).

  A sketch worker runs jailed to `<real>/.prototypes/<uuid>/`; this tool lets it
  be *informed* by the real project without being able to *mutate* it — there is
  deliberately **no write/edit counterpart**, so mutation is structurally
  impossible (every write still lands in the sandbox via `write_file`). Reads are
  jailed to the real base (`JidoClaw.Tools.RealTree.resolver_opts/1`) and fail
  **closed** unless the call carries a `sandbox: :prototype` or `:docker`
  context. Local paths only — remote schemes (`github://`, `s3://`, `git://`)
  are forbidden.

  Preserves `read_file`'s `FilePayloadLimit` cap + numbered-line formatting by
  reusing `JidoClaw.Tools.ReadFile.read_numbered/4`.
  """

  use JidoClaw.Tools.Action,
    name: "read_real_file",
    description:
      "Read a file from the REAL project tree (read-only). Use to inform a sandbox prototype with the real project — you cannot write to the real tree (no write counterpart; all writes land in the sandbox). Returns numbered lines. Local paths only.",
    category: "filesystem",
    tags: ["io", "read"],
    output_schema: [
      path: [type: :string, required: true],
      content: [type: :string, required: true],
      total_lines: [type: :integer, required: true]
    ],
    schema: [
      path: [
        type: :string,
        required: true,
        doc: "Absolute or relative file path in the real project tree (local only)"
      ],
      offset: [type: :non_neg_integer, default: 0, doc: "Start line (0-indexed)"],
      limit: [type: :non_neg_integer, default: 2000, doc: "Max lines to read"]
    ]

  alias JidoClaw.Tools.MCPScope
  alias JidoClaw.Tools.ReadFile
  alias JidoClaw.Tools.RealTree

  @impl Jido.Action
  def run(%{path: path} = params, context) do
    MCPScope.wrap(:read_real_file, params, context, fn enriched ->
      with {:ok, opts} <- RealTree.resolver_opts(get_in(enriched, [:tool_context])) do
        ReadFile.read_numbered(
          path,
          opts,
          Map.get(params, :offset, 0),
          Map.get(params, :limit, 2000)
        )
      end
    end)
  end
end
