defmodule JidoClaw.Tools.GitCommit do
  @moduledoc false
  use JidoClaw.Tools.Action,
    name: "git_commit",
    description:
      "Stage specific files and create a git commit. Always use git_status first to see what changed.",
    category: "git",
    tags: ["vcs", "write"],
    output_schema: [
      output: [type: :string, required: true],
      status: [type: :string, required: true]
    ],
    schema: [
      message: [type: :string, required: true, doc: "Commit message"],
      files: [
        type: {:list, :string},
        required: true,
        doc: "List of file paths to stage and commit"
      ]
    ]

  alias JidoClaw.Tools.MCPScope

  @impl true
  def run(%{message: message, files: files} = params, context) do
    MCPScope.wrap(:git_commit, params, context, fn enriched ->
      project_dir = JidoClaw.ToolContext.project_dir(enriched)
      cmd_opts = [cd: project_dir, stderr_to_stdout: true]

      with :ok <- stage_files(files, cmd_opts) do
        case System.cmd("git", ["commit", "-m", message], cmd_opts) do
          {output, 0} ->
            {:ok, %{output: String.trim(output), status: "committed"}}

          {output, _} ->
            {:error, "git commit failed: #{String.trim(output)}"}
        end
      end
    end)
  end

  defp stage_files(files, cmd_opts) do
    Enum.reduce_while(files, :ok, fn file, :ok ->
      case System.cmd("git", ["add", "--", file], cmd_opts) do
        {_output, 0} ->
          {:cont, :ok}

        {output, code} ->
          message = "git add failed for #{inspect(file)} (exit #{code}): #{String.trim(output)}"
          {:halt, {:error, message}}
      end
    end)
  end
end
