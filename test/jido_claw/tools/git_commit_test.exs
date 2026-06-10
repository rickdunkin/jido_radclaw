defmodule JidoClaw.Tools.GitCommitTest do
  use ExUnit.Case, async: false

  alias JidoClaw.Security.Redaction.Env
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
             System.cmd("git", ["show", "--name-only", "--format=", "HEAD"],
               cd: dir,
               env: Env.scrubbed_cmd_env()
             )
  end

  test "returns git add errors before committing already-staged files", %{dir: dir} do
    File.write!(Path.join(dir, "staged.txt"), "staged\n")

    assert {"", 0} =
             System.cmd("git", ["add", "--", "staged.txt"], cd: dir, env: Env.scrubbed_cmd_env())

    result =
      GitCommit.run(%{message: "should not commit", files: ["missing.txt"]}, context(dir))

    assert {:error, %{message: message}} = result
    assert message =~ "git add failed"
    assert message =~ "missing.txt"

    assert {_output, nonzero} =
             System.cmd("git", ["rev-parse", "--verify", "HEAD"],
               cd: dir,
               stderr_to_stdout: true,
               env: Env.scrubbed_cmd_env()
             )

    assert nonzero != 0
  end

  test "commit hooks run without seeing sensitive parent env vars", %{dir: dir} do
    var = "JIDO_TEST_#{System.unique_integer([:positive])}_TOKEN"
    System.put_env(var, "leaked-secret")
    on_exit(fn -> System.delete_env(var) end)

    # Pin hooksPath so an ambient global core.hooksPath (e.g. husky)
    # can't shadow the hook this test installs.
    assert {"", 0} =
             System.cmd("git", ["config", "core.hooksPath", ".git/hooks"],
               cd: dir,
               env: Env.scrubbed_cmd_env()
             )

    hook = Path.join([dir, ".git", "hooks", "pre-commit"])
    File.mkdir_p!(Path.dirname(hook))

    File.write!(hook, """
    #!/bin/sh
    printf '%s' "$#{var}" > hook_leak.txt
    """)

    File.chmod!(hook, 0o755)

    File.write!(Path.join(dir, "tracked.txt"), "content\n")

    result = GitCommit.run(%{message: "scrub check", files: ["tracked.txt"]}, context(dir))

    assert {:ok, %{status: "committed"}} = result

    leak_file = Path.join(dir, "hook_leak.txt")
    assert File.exists?(leak_file), "pre-commit hook did not run"
    assert File.read!(leak_file) == ""
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
