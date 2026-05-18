defmodule JidoClaw.Tools.GitStatus do
  @moduledoc false
  use JidoClaw.Tools.Action,
    name: "git_status",
    description: "Show git repository status. Returns modified, staged, and untracked files.",
    category: "git",
    tags: ["vcs", "read"],
    output_schema: [
      status: [type: :string, required: true],
      branch: [type: :string, required: true]
    ],
    schema: []

  alias JidoClaw.Tools.MCPScope

  @impl true
  def run(params, context) do
    MCPScope.wrap(:git_status, params, context, fn enriched ->
      project_dir = JidoClaw.ToolContext.project_dir(enriched)
      cmd_opts = [cd: project_dir, stderr_to_stdout: true]

      case System.cmd("git", ["status", "--porcelain"], cmd_opts) do
        {output, 0} ->
          branch =
            case System.cmd("git", ["branch", "--show-current"], cmd_opts) do
              {b, 0} -> String.trim(b)
              _ -> "unknown"
            end

          {:ok, %{status: output, branch: branch}}

        {output, _} ->
          {:error, "git status failed: #{String.trim(output)}"}
      end
    end)
  end
end
