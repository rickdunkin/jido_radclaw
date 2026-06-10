defmodule JidoClaw.Tools.EditFile do
  @moduledoc false
  @max_content_bytes 5 * 1024 * 1024

  use JidoClaw.Tools.Action,
    name: "edit_file",
    description:
      "Edit a file by replacing an exact string match. The old_string must be unique in the file. Read the file first to get the exact text.",
    category: "filesystem",
    tags: ["io", "write"],
    output_schema: [
      path: [type: :string, required: true],
      diff: [type: :string, required: true],
      status: [type: :string, required: true]
    ],
    schema:
      Zoi.object(%{
        path: Zoi.string(description: "File path to edit"),
        old_string:
          Zoi.max(
            Zoi.string(description: "Exact text to find (must be unique in file)"),
            @max_content_bytes,
            message: "old_string must be at most #{@max_content_bytes} bytes"
          ),
        new_string:
          Zoi.max(
            Zoi.string(description: "Replacement text"),
            @max_content_bytes,
            message: "new_string must be at most #{@max_content_bytes} bytes"
          )
      })

  alias JidoClaw.Error
  alias JidoClaw.Tools.FilePayloadLimit
  alias JidoClaw.Tools.MCPScope
  alias JidoClaw.VFS.Resolver

  @impl Jido.Action
  def run(%{path: path, old_string: old_str, new_string: new_str} = params, context) do
    with :ok <- FilePayloadLimit.validate(:old_string, old_str),
         :ok <- FilePayloadLimit.validate(:new_string, new_str) do
      MCPScope.wrap(:edit_file, params, context, fn enriched ->
        edit_with_context(path, old_str, new_str, enriched)
      end)
    end
  end

  defp edit_with_context(path, old_str, new_str, enriched) do
    workspace_id = get_in(enriched, [:tool_context, :workspace_id])
    project_dir = get_in(enriched, [:tool_context, :project_dir]) || File.cwd!()
    opts = [workspace_id: workspace_id, project_dir: project_dir]

    case Resolver.read(path, opts) do
      {:ok, content} ->
        replace_unique_match(path, content, old_str, new_str, opts)

      {:error, reason} ->
        {:error,
         Error.execution_error("Cannot read #{path}: #{inspect(reason)}",
           phase: :read,
           details: %{path: path, reason: inspect(reason)}
         )}
    end
  end

  defp replace_unique_match(path, content, old_str, new_str, opts) do
    case count_occurrences(content, old_str) do
      0 ->
        {:error,
         Error.validation_error(
           "old_string not found in #{path}. Read the file first to get the exact text.",
           field: :old_string,
           details: %{path: path, reason: :not_found}
         )}

      1 ->
        write_edit(path, content, old_str, new_str, opts)

      occurrences ->
        {:error,
         Error.validation_error(
           "old_string found #{occurrences} times in #{path}. Provide more surrounding context to make it unique.",
           field: :old_string,
           details: %{path: path, reason: :non_unique, occurrences: occurrences}
         )}
    end
  end

  defp write_edit(path, content, old_str, new_str, opts) do
    new_content = String.replace(content, old_str, new_str, global: false)

    case Resolver.atomic_write(path, new_content, opts) do
      :ok ->
        diff = build_diff(old_str, new_str)
        {:ok, %{path: path, diff: diff, status: "edited"}}

      {:error, reason} ->
        {:error,
         Error.execution_error("Failed to write #{path}: #{inspect(reason)}",
           phase: :write,
           details: %{path: path, reason: inspect(reason)}
         )}
    end
  end

  defp count_occurrences(content, pattern) do
    content
    |> String.split(pattern)
    |> length()
    |> Kernel.-(1)
  end

  defp build_diff(old_str, new_str) do
    old_lines = Enum.map(String.split(old_str, "\n"), &"- #{&1}")
    new_lines = Enum.map(String.split(new_str, "\n"), &"+ #{&1}")
    Enum.join(old_lines ++ new_lines, "\n")
  end
end
