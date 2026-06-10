defmodule JidoClaw.Tools.GitProjectDirTest do
  use ExUnit.Case, async: false

  alias JidoClaw.Security.Redaction.Env
  alias JidoClaw.Tools.GitDiff
  alias JidoClaw.Tools.GitStatus
  alias JidoClaw.Tools.ProjectInfo

  setup do
    dir =
      Path.join(System.tmp_dir!(), "jido_git_project_dir_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    init_repo!(dir)

    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, dir: dir}
  end

  test "git_status runs in tool_context.project_dir", %{dir: dir} do
    File.write!(Path.join(dir, "scoped.txt"), "scoped\n")

    assert {:ok, %{status: status}} = GitStatus.run(%{}, context(dir))
    assert status =~ "?? scoped.txt"
  end

  test "git_diff runs in tool_context.project_dir", %{dir: dir} do
    File.write!(Path.join(dir, "tracked.txt"), "old\n")

    assert {"", 0} =
             System.cmd("git", ["add", "--", "tracked.txt"], cd: dir, env: Env.scrubbed_cmd_env())

    assert {_output, 0} =
             System.cmd("git", ["commit", "-m", "base"], cd: dir, env: Env.scrubbed_cmd_env())

    File.write!(Path.join(dir, "tracked.txt"), "changed\n")

    assert {:ok, %{diff: diff}} = GitDiff.run(%{path: "tracked.txt"}, context(dir))
    assert diff =~ "+changed"
  end

  test "project_info reports the scoped project directory", %{dir: dir} do
    File.mkdir_p!(Path.join(dir, ".jido"))
    File.write!(Path.join([dir, ".jido", "JIDO.md"]), "# scoped\n")
    File.write!(Path.join(dir, "dirty.txt"), "dirty\n")

    assert {:ok, info} = ProjectInfo.run(%{}, context(dir))
    assert info.cwd == dir
    assert info.git_dirty == true
    assert info.has_jido_md == true
    assert info.top_level_files =~ "dirty.txt"
  end

  defp init_repo!(dir) do
    assert {_output, 0} =
             System.cmd("git", ["init"],
               cd: dir,
               stderr_to_stdout: true,
               env: Env.scrubbed_cmd_env()
             )

    assert {"", 0} =
             System.cmd("git", ["config", "user.email", "test@example.com"],
               cd: dir,
               env: Env.scrubbed_cmd_env()
             )

    assert {"", 0} =
             System.cmd("git", ["config", "user.name", "Test User"],
               cd: dir,
               env: Env.scrubbed_cmd_env()
             )
  end

  defp context(dir), do: %{tool_context: %{project_dir: dir}}
end
