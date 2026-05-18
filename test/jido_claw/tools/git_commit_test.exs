defmodule JidoClaw.Tools.GitCommitTest do
  use ExUnit.Case, async: false

  alias JidoClaw.Tools.GitCommit

  setup do
    dir = Path.join(System.tmp_dir!(), "jido_git_commit_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    init_repo!(dir)

    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, dir: dir}
  end

  test "stages paths after -- so dash-prefixed filenames are committed", %{dir: dir} do
    File.write!(Path.join(dir, "--looks-like-option"), "content\n")

    result =
      GitCommit.run(
        %{message: "add dash file", files: ["--looks-like-option"]},
        context(dir)
      )

    assert {:ok, %{status: "committed"}} = result

    assert {"--looks-like-option\n", 0} =
             System.cmd("git", ["show", "--name-only", "--format=", "HEAD"], cd: dir)
  end

  test "returns git add errors before committing already-staged files", %{dir: dir} do
    File.write!(Path.join(dir, "staged.txt"), "staged\n")
    assert {"", 0} = System.cmd("git", ["add", "--", "staged.txt"], cd: dir)

    result =
      GitCommit.run(%{message: "should not commit", files: ["missing.txt"]}, context(dir))

    assert {:error, %{message: message}} = result
    assert message =~ "git add failed"
    assert message =~ "missing.txt"

    assert {_output, nonzero} =
             System.cmd("git", ["rev-parse", "--verify", "HEAD"], cd: dir, stderr_to_stdout: true)

    assert nonzero != 0
  end

  defp init_repo!(dir) do
    assert {_output, 0} = System.cmd("git", ["init"], cd: dir, stderr_to_stdout: true)
    assert {"", 0} = System.cmd("git", ["config", "user.email", "test@example.com"], cd: dir)
    assert {"", 0} = System.cmd("git", ["config", "user.name", "Test User"], cd: dir)
  end

  defp context(dir), do: %{tool_context: %{project_dir: dir}}
end
