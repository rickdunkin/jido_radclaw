defmodule JidoClaw.Tools.WriteFile do
  @moduledoc """
  Create or overwrite a file via the VFS resolver.

  Supports local paths and remote URIs:
  - `github://owner/repo/path` — writes to GitHub (creates a commit)
  - `s3://bucket/key`          — writes to S3
  - `git://repo-path//file`    — writes to a Git repository
  - All other paths             — writes to the local filesystem
  """

  @max_content_bytes 5 * 1024 * 1024

  use JidoClaw.Tools.Action,
    name: "write_file",
    description:
      "Create or overwrite a file. Creates parent directories if needed. Supports github://, s3://, git:// URIs.",
    category: "filesystem",
    tags: ["io", "write"],
    output_schema: [
      path: [type: :string, required: true],
      lines_written: [type: :integer, required: true]
    ],
    schema:
      Zoi.object(%{
        path:
          Zoi.string(description: "File path to write, or remote URI (github://, s3://, git://)"),
        content:
          Zoi.string(description: "File content")
          |> Zoi.max(@max_content_bytes,
            message: "content must be at most #{@max_content_bytes} bytes"
          )
      })

  alias JidoClaw.Tools.FilePayloadLimit
  alias JidoClaw.Tools.MCPScope
  alias JidoClaw.VFS.Resolver

  @impl true
  def run(%{path: path, content: content} = params, context) do
    with :ok <- FilePayloadLimit.validate(:content, content) do
      MCPScope.wrap(:write_file, params, context, fn enriched ->
        workspace_id = get_in(enriched, [:tool_context, :workspace_id])
        project_dir = get_in(enriched, [:tool_context, :project_dir]) || File.cwd!()

        case Resolver.write(path, content, workspace_id: workspace_id, project_dir: project_dir) do
          :ok ->
            lines =
              content
              |> String.split("\n")
              |> length()

            {:ok, %{path: path, lines_written: lines}}

          {:error, reason} ->
            {:error, "Cannot write #{path}: #{inspect(reason)}"}
        end
      end)
    end
  end
end
