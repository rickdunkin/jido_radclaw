defmodule JidoClaw.Tools.WriteFile do
  @moduledoc """
  Create or overwrite a file via the VFS resolver.

  Supports local paths and remote URIs:
  - `github://owner/repo/path` — writes to GitHub (creates a commit)
  - `s3://bucket/key`          — writes to S3
  - `git://repo-path//file`    — writes to a Git repository
  - All other paths             — writes to the local filesystem
  """

  use Jido.Action,
    name: "write_file",
    description:
      "Create or overwrite a file. Creates parent directories if needed. Supports github://, s3://, git:// URIs.",
    category: "filesystem",
    tags: ["io", "write"],
    output_schema: [
      path: [type: :string, required: true],
      lines_written: [type: :integer, required: true]
    ],
    schema: [
      path: [
        type: :string,
        required: true,
        doc: "File path to write, or remote URI (github://, s3://, git://)"
      ],
      content: [type: :string, required: true, doc: "File content"]
    ]

  alias JidoClaw.VFS.Resolver

  @impl true
  def run(%{path: path, content: content}, _context) do
    case Resolver.write(path, content) do
      :ok ->
        lines = content |> String.split("\n") |> length()
        {:ok, %{path: path, lines_written: lines}}

      {:error, reason} ->
        {:error, "Cannot write #{path}: #{inspect(reason)}"}
    end
  end
end
