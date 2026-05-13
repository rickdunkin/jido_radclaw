defmodule JidoClaw.Tools.ReadFile do
  @moduledoc """
  Read file contents via the VFS resolver.

  Supports local paths and remote URIs:
  - `github://owner/repo/path` — reads from GitHub
  - `s3://bucket/key`          — reads from S3
  - `git://repo-path//file`    — reads from a Git repository
  - All other paths             — reads from the local filesystem
  """

  use Jido.Action,
    name: "read_file",
    description:
      "Read file contents. Always read a file before editing it. Returns numbered lines. Supports github://, s3://, git:// URIs.",
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
        doc: "Absolute or relative file path, or remote URI (github://, s3://, git://)"
      ],
      offset: [type: :non_neg_integer, default: 0, doc: "Start line (0-indexed)"],
      limit: [type: :non_neg_integer, default: 2000, doc: "Max lines to read"]
    ]

  alias JidoClaw.Tools.MCPScope
  alias JidoClaw.VFS.Resolver

  @impl true
  def run(%{path: path} = params, context) do
    offset = Map.get(params, :offset, 0)
    limit = Map.get(params, :limit, 2000)

    cond do
      offset < 0 -> {:error, "offset must be non-negative"}
      limit < 0 -> {:error, "limit must be non-negative"}
      true -> do_read(path, params, context, offset, limit)
    end
  end

  defp do_read(path, params, context, offset, limit) do
    MCPScope.wrap(:read_file, params, context, fn enriched ->
      workspace_id = get_in(enriched, [:tool_context, :workspace_id])
      project_dir = get_in(enriched, [:tool_context, :project_dir]) || File.cwd!()

      case Resolver.read(path, workspace_id: workspace_id, project_dir: project_dir) do
        {:ok, content} ->
          lines = String.split(content, "\n")
          total = length(lines)

          numbered =
            lines
            |> Enum.with_index(1)
            |> Enum.slice(offset, limit)
            |> Enum.map_join("\n", fn {line, n} ->
              "#{String.pad_leading(Integer.to_string(n), 4)} │ #{line}"
            end)

          {:ok, %{path: path, content: numbered, total_lines: total}}

        {:error, reason} ->
          {:error, "Cannot read #{path}: #{inspect(reason)}"}
      end
    end)
  end
end
