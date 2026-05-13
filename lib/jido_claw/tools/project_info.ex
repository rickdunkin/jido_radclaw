defmodule JidoClaw.Tools.ProjectInfo do
  @moduledoc false
  use Jido.Action,
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
    MCPScope.wrap(:project_info, params, context, fn _enriched -> do_run() end)
  end

  defp do_run do
    cwd = File.cwd!()

    {:ok,
     %{
       cwd: cwd,
       project_type: ProjectType.detect(cwd),
       git_branch: detect_git_branch(),
       git_dirty: detect_git_dirty(),
       top_level_files: detect_top_level_files(cwd),
       has_jido_md: File.exists?(Path.join([cwd, ".jido", "JIDO.md"]))
     }}
  end

  defp detect_git_branch do
    case System.cmd("git", ["branch", "--show-current"], stderr_to_stdout: true) do
      {b, 0} -> String.trim(b)
      _ -> "not a git repo"
    end
  end

  defp detect_git_dirty do
    case System.cmd("git", ["status", "--porcelain"], stderr_to_stdout: true) do
      {"", 0} -> false
      {_, 0} -> true
      _ -> false
    end
  end

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
