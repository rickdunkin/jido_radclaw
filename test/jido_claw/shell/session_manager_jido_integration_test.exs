defmodule JidoClaw.Shell.SessionManagerJidoIntegrationTest do
  # Exercises the full shell path end-to-end: registry patch + classifier
  # + command module all cooperating through SessionManager.run/4.
  # A unit test can't catch a classifier regression that silently routes
  # `jido` to host.
  use ExUnit.Case, async: false

  alias JidoClaw.Shell.SessionManager
  alias JidoClaw.VFS.Workspace

  setup do
    workspace_id = "test-sm-jido-int-#{System.unique_integer([:positive])}"

    tmp =
      Path.join(
        System.tmp_dir!(),
        "jido_claw_sm_jido_int_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)

    on_exit(fn ->
      _ = SessionManager.stop_session(workspace_id)
      _ = Workspace.teardown(workspace_id)
      File.rm_rf!(tmp)
    end)

    {:ok, workspace_id: workspace_id, tmp: tmp}
  end

  test "`jido status` executes through the VFS session and emits the status header",
       %{workspace_id: ws, tmp: tmp} do
    assert {:ok, %{output: out, exit_code: 0}} =
             SessionManager.run(ws, "jido status", 5_000, project_dir: tmp)

    assert out =~ "JidoClaw Status"
    assert out =~ "uptime"
  end

  test "`help` lists `jido` alongside built-ins", %{workspace_id: ws, tmp: tmp} do
    assert {:ok, %{output: out, exit_code: 0}} =
             SessionManager.run(ws, "help", 5_000, project_dir: tmp)

    assert out =~ "jido"
    assert out =~ "ls"
    assert out =~ "Available commands"
  end

  test "`help jido` renders the command's moduledoc", %{workspace_id: ws, tmp: tmp} do
    assert {:ok, %{output: out, exit_code: 0}} =
             SessionManager.run(ws, "help jido", 5_000, project_dir: tmp)

    assert out =~ "JidoClaw introspection"
    assert out =~ "memory search"
  end

  test "`jido bogus` emits usage and returns a non-zero exit code",
       %{workspace_id: ws, tmp: tmp} do
    assert {:ok, %{output: out, exit_code: code}} =
             SessionManager.run(ws, "jido bogus", 5_000, project_dir: tmp)

    assert out =~ "Usage: jido"
    assert out =~ "unknown sub-command"
    assert code != 0
  end
end
