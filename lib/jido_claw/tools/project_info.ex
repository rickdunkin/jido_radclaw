defmodule JidoClaw.Tools.ProjectInfo do
  @moduledoc false
  use JidoClaw.Tools.Action,
    name: "project_info",
    description:
      "Get information about the current project: type, structure, git status, and key files.",
    category: "project",
    tags: ["project", "read"],
    output_schema: [
      cwd: [type: :string, required: true],
      project_type: [type: :string, required: true],
      git_branch: [type: :string, required: true],
      git_dirty: [type: :boolean, required: true],
      top_level_files: [type: :string, required: true],
      has_jido_md: [type: :boolean, required: true]
    ],
    schema: []

  alias JidoClaw.ProjectType
  alias JidoClaw.Tools.MCPScope

  @impl true
  def run(params, context) do
    MCPScope.wrap(:project_info, params, context, fn enriched ->
      enriched
      |> JidoClaw.ToolContext.project_dir()
      |> do_run()
    end)
  end

  defp do_run(cwd) do
    {:ok,
     %{
       cwd: cwd,
       project_type: ProjectType.detect(cwd),
       git_branch: detect_git_branch(cwd),
       git_dirty: detect_git_dirty(cwd),
       top_level_files: detect_top_level_files(cwd),
       has_jido_md: File.exists?(Path.join([cwd, ".jido", "JIDO.md"]))
     }}
  end

  defp detect_git_branch(cwd) do
    case System.cmd("git", ["branch", "--show-current"], cd: cwd, stderr_to_stdout: true) do
      {b, 0} -> String.trim(b)
      _ -> "not a git repo"
    end
  end

  defp detect_git_dirty(cwd) do
    case System.cmd("git", ["status", "--porcelain"], cd: cwd, stderr_to_stdout: true) do
      {"", 0} -> false
      {_, 0} -> true
      _ -> false
    end
  end

  # Enum.sort |> Enum.take(30) intentionally yields the lexicographically-first
  # 30 entries; no idiomatic partial top-k reproduces that exact ordering for
  # such tiny input, so the full sort is the simplest correct form. File-level
  # scope (the only eager_pattern finding here) survives anchor drift.
  # reach:disable-for-this-file eager_pattern
  defp detect_top_level_files(cwd) do
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
  end
end
