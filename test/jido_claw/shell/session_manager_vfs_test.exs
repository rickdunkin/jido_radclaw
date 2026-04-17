defmodule JidoClaw.Shell.SessionManagerVFSTest do
  # async: false — SessionManager is a singleton GenServer.
  use ExUnit.Case, async: false

  alias JidoClaw.Shell.SessionManager
  alias JidoClaw.VFS.Workspace

  setup do
    workspace_id = "test-sm-vfs-#{System.unique_integer([:positive])}"

    tmp =
      Path.join(
        System.tmp_dir!(),
        "jido_claw_sm_vfs_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)
    File.write!(Path.join(tmp, "README.md"), "# from /project")
    File.write!(Path.join(tmp, "mix.exs"), "mix.exs contents")

    on_exit(fn ->
      _ = SessionManager.stop_session(workspace_id)
      _ = Workspace.teardown(workspace_id)
      File.rm_rf!(tmp)
    end)

    {:ok, workspace_id: workspace_id, tmp: tmp}
  end

  describe "classifier" do
    setup %{workspace_id: ws, tmp: tmp} do
      # Bootstrap the workspace so MountTable has /project mapped to tmp.
      {:ok, _} = Workspace.ensure_started(ws, tmp)
      :ok
    end

    test "routes `cat /project/README.md` to the VFS session", %{workspace_id: ws} do
      assert SessionManager.classify("cat /project/README.md", ws) == :vfs
    end

    test "routes `git status` to host (not in sandbox allowlist)", %{workspace_id: ws} do
      assert SessionManager.classify("git status", ws) == :host
    end

    test "routes `cat /project/x | head` to host (pipe token)", %{workspace_id: ws} do
      assert SessionManager.classify("cat /project/README.md | head", ws) == :host
    end

    test "routes `cat /tmp/foo` to host (no mount covers /tmp)", %{workspace_id: ws} do
      assert SessionManager.classify("cat /tmp/foo", ws) == :host
    end

    test "routes mixed host + mount args to host (no mixing)", %{workspace_id: ws} do
      assert SessionManager.classify("cat /project/README.md /tmp/foo", ws) == :host
    end

    test "routes bare `ls` (no args) to host", %{workspace_id: ws} do
      assert SessionManager.classify("ls", ws) == :host
    end

    test "routes `echo '|'` to host (accepted false positive)", %{workspace_id: ws} do
      # Tokenizer strips quote info; `|` is a host-forcing token.
      assert SessionManager.classify("echo '|'", ws) == :host
    end

    test "routes chained `cd /project && cat /project/mix.exs` to vfs", %{workspace_id: ws} do
      assert SessionManager.classify("cd /project && cat /project/mix.exs", ws) == :vfs
    end

    test "routes commands with $(...) to host", %{workspace_id: ws} do
      assert SessionManager.classify("cat $(echo /project/README.md)", ws) == :host
    end

    test "routes embedded pipe `cat /project/x|head` to host", %{workspace_id: ws} do
      assert SessionManager.classify("cat /project/README.md|head", ws) == :host
    end

    test "routes embedded redirect `cat /project/x>out` to host", %{workspace_id: ws} do
      assert SessionManager.classify("cat /project/README.md>out", ws) == :host
    end

    test "routes embedded append `cat /project/x>>log` to host", %{workspace_id: ws} do
      assert SessionManager.classify("cat /project/README.md>>log", ws) == :host
    end

    test "routes embedded input redirect `cat</project/in` to host", %{workspace_id: ws} do
      assert SessionManager.classify("cat</project/in", ws) == :host
    end

    test "routes embedded ampersand `foo&bar` to host", %{workspace_id: ws} do
      assert SessionManager.classify("foo&bar", ws) == :host
    end

    test "regression: `cat /project/README.md || true` stays host-only", %{workspace_id: ws} do
      assert SessionManager.classify("cat /project/README.md || true", ws) == :host
    end
  end

  describe "run/4 routing" do
    test "cat /project/mix.exs returns file contents via VFS session", %{
      workspace_id: ws,
      tmp: tmp
    } do
      assert {:ok, %{output: out, exit_code: 0}} =
               SessionManager.run(ws, "cat /project/mix.exs", 5_000, project_dir: tmp)

      assert out =~ "mix.exs contents"
    end

    test "git --version returns through host session unchanged", %{
      workspace_id: ws,
      tmp: tmp
    } do
      assert {:ok, %{output: out}} =
               SessionManager.run(ws, "git --version", 5_000, project_dir: tmp)

      assert out =~ "git version"
    end

    test "force: :host sends a sandbox-allowlisted command to host anyway", %{
      workspace_id: ws,
      tmp: tmp
    } do
      # Host's cwd is tmp — `cat README.md` (relative) works there.
      assert {:ok, %{output: out, exit_code: 0}} =
               SessionManager.run(ws, "cat README.md", 5_000,
                 project_dir: tmp,
                 force: :host
               )

      assert out =~ "from /project"
    end

    test "force: :vfs drives the VFS session for a command that classifier would punt to host",
         %{workspace_id: ws, tmp: tmp} do
      # Bare `ls` classifies to host. With force: :vfs it hits the sandbox
      # session whose cwd is /project — ls should return the file names.
      assert {:ok, %{output: out, exit_code: 0}} =
               SessionManager.run(ws, "ls", 5_000, project_dir: tmp, force: :vfs)

      assert out =~ "README.md"
      assert out =~ "mix.exs"
    end
  end

  describe "session lifecycle" do
    test "host and VFS sessions start with distinct cwds", %{workspace_id: ws, tmp: tmp} do
      # Trigger session bootstrap
      {:ok, _} = SessionManager.run(ws, "true", 5_000, project_dir: tmp, force: :host)

      assert {:ok, host_cwd} = SessionManager.cwd(ws, :host)
      assert {:ok, vfs_cwd} = SessionManager.cwd(ws, :vfs)

      assert host_cwd == tmp
      assert vfs_cwd == "/project"
    end

    test "reusing workspace_id with a different project_dir rebuilds sessions", %{
      workspace_id: ws,
      tmp: tmp
    } do
      {:ok, _} = SessionManager.run(ws, "true", 5_000, project_dir: tmp, force: :host)

      tmp2 =
        Path.join(
          System.tmp_dir!(),
          "jido_claw_sm_vfs_rebuild_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp2)
      File.write!(Path.join(tmp2, "other.txt"), "other")
      on_exit(fn -> File.rm_rf!(tmp2) end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          {:ok, _} = SessionManager.run(ws, "true", 5_000, project_dir: tmp2, force: :host)
        end)

      assert log =~ "project_dir drift"
      assert {:ok, ^tmp2} = SessionManager.cwd(ws, :host)
    end

    test "stop_session tears down both sessions + the VFS workspace", %{
      workspace_id: ws,
      tmp: tmp
    } do
      {:ok, _} = SessionManager.run(ws, "true", 5_000, project_dir: tmp, force: :host)
      assert Workspace.mounts(ws) != []

      :ok = SessionManager.stop_session(ws)

      assert Workspace.mounts(ws) == []
      assert {:error, :no_session} = SessionManager.cwd(ws, :host)
    end
  end
end
