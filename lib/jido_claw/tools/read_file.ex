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
    schema: [
      path: [
        type: :string,
        required: true,
        doc: "Absolute or relative file path, or remote URI (github://, s3://, git://)"
      ],
      offset: [type: :integer, default: 0, doc: "Start line (0-indexed)"],
      limit: [type: :integer, default: 2000, doc: "Max lines to read"]
    ]

  alias JidoClaw.VFS.Resolver

  @impl true
  def run(%{path: path} = params, _context) do
    offset = Map.get(params, :offset, 0)
    limit = Map.get(params, :limit, 2000)

    case Resolver.read(path) do
      {:ok, content} ->
        lines = String.split(content, "\n")
        total = length(lines)

        numbered =
          lines
          |> Enum.with_index(1)
          |> Enum.drop(offset)
          |> Enum.take(limit)
          |> Enum.map(fn {line, n} ->
            "#{String.pad_leading(Integer.to_string(n), 4)} │ #{line}"
          end)
          |> Enum.join("\n")

        {:ok, %{path: path, content: numbered, total_lines: total}}

      {:error, reason} ->
        {:error, "Cannot read #{path}: #{inspect(reason)}"}
    end
  end
end
