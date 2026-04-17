defmodule JidoClaw.VFS.WorkspaceTest do
  # async: false — Jido.Shell.VFS.MountTable is global ETS state.
  use ExUnit.Case, async: false

  alias JidoClaw.VFS.Workspace

  setup do
    workspace_id = "test-workspace-#{System.unique_integer([:positive])}"

    tmp =
      Path.join(
        System.tmp_dir!(),
        "jido_claw_workspace_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)
    File.write!(Path.join(tmp, "hello.txt"), "hi")

    on_exit(fn ->
      _ = Workspace.teardown(workspace_id)
      File.rm_rf!(tmp)
    end)

    {:ok, workspace_id: workspace_id, tmp: tmp}
  end

  describe "ensure_started/2" do
    test "bootstraps the default /project mount from project_dir", %{
      workspace_id: ws,
      tmp: tmp
    } do
      assert {:ok, pid} = Workspace.ensure_started(ws, tmp)
      assert is_pid(pid)

      mounts = Workspace.mounts(ws)
      assert [%{path: "/project"}] = mounts

      assert {:ok, "hi"} = Jido.Shell.VFS.read_file(ws, "/project/hello.txt")
    end

    test "is idempotent — subsequent calls return the same pid", %{
      workspace_id: ws,
      tmp: tmp
    } do
      {:ok, pid1} = Workspace.ensure_started(ws, tmp)
      {:ok, pid2} = Workspace.ensure_started(ws, tmp)

      assert pid1 == pid2
    end

    test "errors when /project bootstrap fails (project_dir option invalid)", %{
      workspace_id: ws
    } do
      # Empty string is a rejected prefix — Jido.VFS.Adapter.Local requires
      # a path, and the Workspace's adapter-option translation returns
      # :local_missing_path for blank input.
      assert {:error, {:default_mount_failed, :local_missing_path}} =
               Workspace.ensure_started(ws, "")
    end

    test "no drift: same project_dir returns the original pid", %{
      workspace_id: ws,
      tmp: tmp
    } do
      {:ok, pid1} = Workspace.ensure_started(ws, tmp)
      {:ok, pid2} = Workspace.ensure_started(ws, tmp)
      assert pid1 == pid2
      assert Process.alive?(pid1)
    end

    test "drift detection rebuilds the workspace and points /project at the new dir", %{
      workspace_id: ws,
      tmp: dir_a
    } do
      File.write!(Path.join(dir_a, "only_in_a.txt"), "a-only")

      dir_b =
        Path.join(
          System.tmp_dir!(),
          "jido_claw_workspace_drift_b_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(dir_b)
      File.write!(Path.join(dir_b, "only_in_b.txt"), "b-only")
      on_exit(fn -> File.rm_rf!(dir_b) end)

      {:ok, pid_a} = Workspace.ensure_started(ws, dir_a)
      ref = Process.monitor(pid_a)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, pid_b} = Workspace.ensure_started(ws, dir_b)
          assert pid_b != pid_a
        end)

      assert log =~ "project_dir drift"
      assert_receive {:DOWN, ^ref, :process, ^pid_a, _}, 1_000

      assert {:ok, "b-only"} = Jido.Shell.VFS.read_file(ws, "/project/only_in_b.txt")
      assert {:error, _} = Jido.Shell.VFS.read_file(ws, "/project/only_in_a.txt")
    end

    test "drift detection invalidates SessionManager sessions for the workspace", %{
      workspace_id: ws,
      tmp: dir_a
    } do
      alias JidoClaw.Shell.SessionManager

      dir_b =
        Path.join(
          System.tmp_dir!(),
          "jido_claw_workspace_drift_sessions_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(dir_b)

      on_exit(fn ->
        _ = SessionManager.stop_session(ws)
        File.rm_rf!(dir_b)
      end)

      # Bootstrap the workspace + both shell sessions via SessionManager
      {:ok, _} = SessionManager.run(ws, "true", 5_000, project_dir: dir_a, force: :host)
      assert {:ok, ^dir_a} = SessionManager.cwd(ws, :host)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          {:ok, _pid} = Workspace.ensure_started(ws, dir_b)
        end)

      assert log =~ "project_dir drift"
      # Sessions were dropped — the next run_command would rebuild them.
      assert {:error, :no_session} = SessionManager.cwd(ws, :host)
    end

    test "tolerates a stale registry entry whose pid has already died", %{
      workspace_id: ws,
      tmp: tmp
    } do
      # Grab the pid, terminate the underlying process out-of-band, then
      # immediately call ensure_started/2. The Registry may still hold the
      # stale entry for a brief moment — the new code must not crash on a
      # :get_project_dir call against a dead pid.
      {:ok, pid} = Workspace.ensure_started(ws, tmp)
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000

      # Call immediately; even if the Registry is slow to prune, the
      # try/catch must route us into start_fresh/2 rather than exiting.
      assert {:ok, new_pid} = Workspace.ensure_started(ws, tmp)
      assert is_pid(new_pid)
      assert new_pid != pid
      assert {:ok, "hi"} = Jido.Shell.VFS.read_file(ws, "/project/hello.txt")
    end

    test "no self-call deadlock when SessionManager itself triggers drift", %{
      workspace_id: ws,
      tmp: dir_a
    } do
      # Scenario: a file tool bootstraps ws with dir_a. No SessionManager
      # sessions exist yet. Then SessionManager.run is called for the same
      # ws with dir_b — SessionManager.start_new_session/3 will call
      # Workspace.ensure_started(ws, dir_b) from *inside* the SessionManager
      # GenServer. The drift branch must not GenServer.call SessionManager
      # from within itself (that used to exit with
      # "process attempted to call itself").
      alias JidoClaw.Shell.SessionManager

      dir_b =
        Path.join(
          System.tmp_dir!(),
          "jido_claw_workspace_self_call_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(dir_b)
      File.write!(Path.join(dir_b, "b.txt"), "from B")

      on_exit(fn ->
        _ = SessionManager.stop_session(ws)
        File.rm_rf!(dir_b)
      end)

      # Bootstrap the workspace as a file tool would (no SessionManager sessions).
      {:ok, _} = Workspace.ensure_started(ws, dir_a)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          # This used to crash with "process attempted to call itself".
          assert {:ok, _} =
                   SessionManager.run(ws, "true", 5_000, project_dir: dir_b, force: :host)
        end)

      assert log =~ "project_dir drift"
      assert {:ok, ^dir_b} = SessionManager.cwd(ws, :host)
    end
  end

  describe "mount/4" do
    test "mounts an in-memory filesystem that round-trips", %{workspace_id: ws, tmp: tmp} do
      {:ok, _} = Workspace.ensure_started(ws, tmp)

      assert :ok = Workspace.mount(ws, "/scratch", :in_memory, %{})

      :ok = Jido.Shell.VFS.write_file(ws, "/scratch/note.txt", "scratch content")
      assert {:ok, "scratch content"} = Jido.Shell.VFS.read_file(ws, "/scratch/note.txt")
    end

    test "fail-soft: unknown adapter logs + returns :ok so bootstrap continues", %{
      workspace_id: ws,
      tmp: tmp
    } do
      {:ok, _} = Workspace.ensure_started(ws, tmp)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok = Workspace.mount(ws, "/nope", :not_a_real_adapter, %{})
        end)

      assert log =~ "Mount /nope"
      assert log =~ "failed"

      # /project mount still present, workspace still usable
      assert Enum.any?(Workspace.mounts(ws), fn m -> m.path == "/project" end)
    end

    test "fail-soft: S3 with missing bucket option does not crash workspace", %{
      workspace_id: ws,
      tmp: tmp
    } do
      {:ok, _} = Workspace.ensure_started(ws, tmp)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok = Workspace.mount(ws, "/artifacts", :s3, %{})
        end)

      assert log =~ "Mount /artifacts"
    end
  end

  describe "teardown/1" do
    test "unmounts everything and stops the workspace process", %{
      workspace_id: ws,
      tmp: tmp
    } do
      {:ok, pid} = Workspace.ensure_started(ws, tmp)
      :ok = Workspace.mount(ws, "/scratch", :in_memory, %{})
      assert length(Workspace.mounts(ws)) == 2

      ref = Process.monitor(pid)
      :ok = Workspace.teardown(ws)

      # Registry cleanup is async — waiting for the DOWN proves the process
      # is gone; `ensure_started` then starts a fresh workspace, proving the
      # registry entry was evicted.
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000

      assert Workspace.mounts(ws) == []

      {:ok, new_pid} = Workspace.ensure_started(ws, tmp)
      assert new_pid != pid
    end

    test "is safe to call for a never-started workspace", %{workspace_id: ws} do
      assert :ok = Workspace.teardown(ws)
    end
  end
end
