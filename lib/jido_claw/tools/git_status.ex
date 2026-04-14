defmodule JidoClaw.Tools.GitStatus do
  use Jido.Action,
    name: "git_status",
    description: "Show git repository status. Returns modified, staged, and untracked files.",
    category: "git",
    tags: ["vcs", "read"],
    output_schema: [
      status: [type: :string, required: true],
      branch: [type: :string, required: true]
    ],
    schema: []

  @impl true
  def run(_params, _context) do
    case System.cmd("git", ["status", "--porcelain"], stderr_to_stdout: true) do
      {output, 0} ->
        branch =
          case System.cmd("git", ["branch", "--show-current"], stderr_to_stdout: true) do
            {b, 0} -> String.trim(b)
            _ -> "unknown"
          end

        {:ok, %{status: output, branch: branch}}

      {output, _} ->
        {:error, "git status failed: #{String.trim(output)}"}
    end
  end
end
