defmodule JidoClaw.Tools.ProjectInfo do
  use Jido.Action,
    name: "project_info",
    description:
      "Get information about the current project: type, structure, git status, and key files.",
    schema: []

  @impl true
  def run(_params, _context) do
    cwd = File.cwd!()

    project_type =
      cond do
        File.exists?(Path.join(cwd, "mix.exs")) -> "elixir"
        File.exists?(Path.join(cwd, "package.json")) -> "node"
        File.exists?(Path.join(cwd, "Cargo.toml")) -> "rust"
        File.exists?(Path.join(cwd, "go.mod")) -> "go"
        File.exists?(Path.join(cwd, "pyproject.toml")) -> "python"
        true -> "unknown"
      end

    git_branch =
      case System.cmd("git", ["branch", "--show-current"], stderr_to_stdout: true) do
        {b, 0} -> String.trim(b)
        _ -> "not a git repo"
      end

    git_dirty =
      case System.cmd("git", ["status", "--porcelain"], stderr_to_stdout: true) do
        {"", 0} -> false
        {_, 0} -> true
        _ -> false
      end

    top_level_files =
      case File.ls(cwd) do
        {:ok, files} ->
          files
          |> Enum.reject(&String.starts_with?(&1, "."))
          |> Enum.sort()
          |> Enum.take(30)
          |> Enum.join(", ")

        _ ->
          ""
      end

    has_jido_md = File.exists?(Path.join([cwd, ".jido", "JIDO.md"]))

    {:ok,
     %{
       cwd: cwd,
       project_type: project_type,
       git_branch: git_branch,
       git_dirty: git_dirty,
       top_level_files: top_level_files,
       has_jido_md: has_jido_md
     }}
  end
end
