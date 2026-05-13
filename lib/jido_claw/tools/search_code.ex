defmodule JidoClaw.Tools.SearchCode do
  @moduledoc false
  use Jido.Action,
    name: "search_code",
    description:
      "Search for a pattern in files using grep. Returns matching lines with file paths and line numbers.",
    category: "filesystem",
    tags: ["io", "read"],
    output_schema: [
      matches: [type: :string, required: true],
      total_matches: [type: :integer, required: true]
    ],
    schema: [
      pattern: [type: :string, required: true, doc: "Search pattern (regex supported)"],
      path: [type: :string, default: ".", doc: "Directory to search in"],
      glob: [type: :string, doc: "File pattern filter (e.g. '*.ex', '*.ts')"],
      max_results: [type: :integer, default: 50, doc: "Max results to return"]
    ]

  alias JidoClaw.Tools.MCPScope

  @impl true
  def run(%{pattern: pattern} = params, context) do
    MCPScope.wrap(:search_code, params, context, fn _enriched ->
      path = Map.get(params, :path, ".")
      max_results = Map.get(params, :max_results, 50)

      glob_args =
        case Map.get(params, :glob) do
          nil -> []
          g -> ["--include=#{g}"]
        end

      args = Enum.concat([["-rn", "--color=never"], glob_args, [pattern, path]])

      case System.cmd("grep", args, stderr_to_stdout: true) do
        {output, 0} ->
          lines = String.split(output, "\n", trim: true)
          truncated = Enum.take(lines, max_results)
          total = length(lines)
          content = Enum.join(truncated, "\n")

          note =
            if total > max_results,
              do: "\n(#{total - max_results} more matches truncated)",
              else: ""

          {:ok, %{matches: content <> note, total_matches: total}}

        {_, 1} ->
          {:ok, %{matches: "", total_matches: 0}}

        {output, _code} ->
          {:error, "grep failed: #{String.slice(output, 0, 500)}"}
      end
    end)
  end
end
