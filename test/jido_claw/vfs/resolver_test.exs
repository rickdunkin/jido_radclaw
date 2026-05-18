defmodule JidoClaw.VFS.ResolverTest do
  # async: false — MountTable is global ETS state.
  use ExUnit.Case, async: false

  alias JidoClaw.VFS.Resolver
  alias JidoClaw.VFS.Workspace

  setup do
    workspace_id = "test-resolver-#{System.unique_integer([:positive])}"

    tmp =
      Path.join(
        System.tmp_dir!(),
        "jido_claw_resolver_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)
    File.write!(Path.join(tmp, "project_file.txt"), "from /project mount")

    {:ok, _} = Workspace.ensure_started(workspace_id, tmp)
    :ok = Workspace.mount(workspace_id, "/scratch", :in_memory, %{})

    on_exit(fn ->
      _ = Workspace.teardown(workspace_id)
      File.rm_rf!(tmp)
    end)

    {:ok, workspace_id: workspace_id, tmp: tmp}
  end

  describe "read/2 with workspace_id" do
    test "routes /project paths through the VFS mount", %{workspace_id: ws} do
      assert {:ok, "from /project mount"} =
               Resolver.read("/project/project_file.txt", workspace_id: ws)
    end

    test "round-trips writes + reads via InMemory mount", %{workspace_id: ws} do
      :ok = Resolver.write("/scratch/hello.txt", "yo", workspace_id: ws)
      assert {:ok, "yo"} = Resolver.read("/scratch/hello.txt", workspace_id: ws)
    end

    test "absolute paths outside any mount are blocked when project_dir is supplied", %{
      workspace_id: ws,
      tmp: tmp
    } do
      host_file =
        Path.join(
          System.tmp_dir!(),
          "jido_claw_host_fallback_#{System.unique_integer([:positive])}.txt"
        )

      File.write!(host_file, "host content")
      on_exit(fn -> File.rm(host_file) end)

      assert {:error, {:path_outside_project, _}} =
               Resolver.read(host_file, workspace_id: ws, project_dir: tmp)
    end
  end

  describe "read/2 without workspace_id (legacy callers)" do
    test "routes all paths through local File.*", %{tmp: tmp} do
      path = Path.join(tmp, "project_file.txt")
      assert {:ok, "from /project mount"} = Resolver.read(path)
      assert {:ok, "from /project mount"} = Resolver.read(path, workspace_id: nil)
    end
  end

  describe "project_dir jail" do
    test "allows relative and absolute paths under project_dir", %{tmp: tmp} do
      path = Path.join(tmp, "project_file.txt")

      assert {:ok, "from /project mount"} =
               Resolver.read("project_file.txt", project_dir: tmp)

      assert {:ok, "from /project mount"} =
               Resolver.read(path, project_dir: tmp)
    end

    test "rejects relative traversal outside project_dir", %{tmp: tmp} do
      assert {:error, {:path_outside_project, _}} =
               Resolver.read("../outside.txt", project_dir: tmp)
    end

    test "rejects absolute paths outside project_dir", %{tmp: tmp} do
      host_file =
        Path.join(
          System.tmp_dir!(),
          "jido_claw_outside_#{System.unique_integer([:positive])}.txt"
        )

      File.write!(host_file, "outside")
      on_exit(fn -> File.rm(host_file) end)

      assert {:error, {:path_outside_project, _}} =
               Resolver.read(host_file, project_dir: tmp)
    end

    test "rejects symlink reads that escape project_dir", %{tmp: tmp} do
      outside =
        Path.join(
          System.tmp_dir!(),
          "jido_claw_symlink_outside_#{System.unique_integer([:positive])}.txt"
        )

      link = Path.join(tmp, "linked_secret.txt")

      File.write!(outside, "outside")
      File.ln_s!(outside, link)

      on_exit(fn -> File.rm(outside) end)

      assert {:error, {:path_outside_project, _}} =
               Resolver.read("linked_secret.txt", project_dir: tmp)
    end

    test "rejects writes outside project_dir", %{tmp: tmp} do
      outside =
        Path.join(
          System.tmp_dir!(),
          "jido_claw_write_outside_#{System.unique_integer([:positive])}.txt"
        )

      on_exit(fn -> File.rm(outside) end)

      assert {:error, {:path_outside_project, _}} =
               Resolver.write(outside, "outside", project_dir: tmp)

      refute File.exists?(outside)
    end

    test "rejects writes through symlinked parent directories", %{tmp: tmp} do
      outside_dir =
        Path.join(
          System.tmp_dir!(),
          "jido_claw_symlink_write_outside_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(outside_dir)
      File.ln_s!(outside_dir, Path.join(tmp, "linked_dir"))

      on_exit(fn -> File.rm_rf!(outside_dir) end)

      assert {:error, {:path_outside_project, _}} =
               Resolver.write("linked_dir/secret.txt", "outside", project_dir: tmp)

      refute File.exists?(Path.join(outside_dir, "secret.txt"))
    end
  end

  describe "ls/2 with workspace_id" do
    test "returns a flat list of names (not stat structs)", %{workspace_id: ws} do
      :ok = Resolver.write("/scratch/a.txt", "a", workspace_id: ws)
      :ok = Resolver.write("/scratch/b.txt", "b", workspace_id: ws)

      assert {:ok, names} = Resolver.ls("/scratch", workspace_id: ws)
      assert Enum.sort(names) == ["a.txt", "b.txt"]
    end
  end

  describe "atomic_write/3" do
    test "commits local writes through a temp file in the target directory", %{tmp: tmp} do
      path = Path.join(tmp, "atomic.txt")
      File.write!(path, "old")

      assert :ok = Resolver.atomic_write("atomic.txt", "new", project_dir: tmp)

      assert File.read!(path) == "new"
      assert [] = Path.wildcard(Path.join(tmp, "atomic.txt.*.tmp"))
    end

    test "cleans up staged local writes when rename fails", %{tmp: tmp} do
      target_dir = Path.join(tmp, "directory_target")
      File.mkdir_p!(target_dir)

      assert {:error, _reason} =
               Resolver.atomic_write("directory_target", "new", project_dir: tmp)

      assert File.dir?(target_dir)
      assert [] = Path.wildcard(Path.join(tmp, "directory_target.*.tmp"))
    end

    test "commits VFS writes through the mounted filesystem", %{workspace_id: ws} do
      assert :ok = Resolver.atomic_write("/scratch/atomic.txt", "new", workspace_id: ws)
      assert {:ok, "new"} = Resolver.read("/scratch/atomic.txt", workspace_id: ws)
    end
  end

  describe "URI schemes still work unchanged" do
    test "github:// is still recognised (integration path; no network call)" do
      # Parser-level assertion: remote? returns true.
      assert Resolver.remote?("github://owner/repo/file.md")
      assert Resolver.remote?("s3://bucket/key")
      assert Resolver.remote?("git://repo//file")
      refute Resolver.remote?("/project/foo")
    end
  end

  describe "read/2 auto-bootstrap with :project_dir" do
    test "auto-bootstraps a brand-new workspace when :project_dir is passed" do
      ws = "test-resolver-bootstrap-#{System.unique_integer([:positive])}"

      tmp =
        Path.join(
          System.tmp_dir!(),
          "jido_claw_resolver_bootstrap_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp)
      File.write!(Path.join(tmp, "foo.txt"), "bootstrapped")

      on_exit(fn ->
        _ = Workspace.teardown(ws)
        File.rm_rf!(tmp)
      end)

      # No prior Workspace.ensure_started/2 call — Resolver must bootstrap.
      assert Registry.lookup(JidoClaw.VFS.WorkspaceRegistry, ws) == []

      assert {:ok, "bootstrapped"} =
               Resolver.read("/project/foo.txt", workspace_id: ws, project_dir: tmp)

      assert [{_pid, _}] = Registry.lookup(JidoClaw.VFS.WorkspaceRegistry, ws)
    end

    test "does not bootstrap without :project_dir (legacy mount-check behavior)", %{
      tmp: tmp
    } do
      # A MountTable miss without :project_dir still falls through to local.
      path = Path.join(tmp, "project_file.txt")

      ws_no_mount = "test-resolver-no-pd-#{System.unique_integer([:positive])}"
      on_exit(fn -> _ = Workspace.teardown(ws_no_mount) end)

      assert {:ok, "from /project mount"} = Resolver.read(path, workspace_id: ws_no_mount)
      # No workspace was started for `ws_no_mount`.
      assert Registry.lookup(JidoClaw.VFS.WorkspaceRegistry, ws_no_mount) == []
    end

    test "does not bootstrap for remote URIs even when :project_dir is passed" do
      ws = "test-resolver-no-bootstrap-remote-#{System.unique_integer([:positive])}"
      tmp = Path.join(System.tmp_dir!(), "jido_claw_resolver_no_bootstrap_#{ws}")
      File.mkdir_p!(tmp)

      on_exit(fn ->
        _ = Workspace.teardown(ws)
        File.rm_rf!(tmp)
      end)

      # github:// requests without a GITHUB_TOKEN will fail at the network
      # layer — we don't care about the result, only that no workspace is
      # started in the registry as a side-effect of the opts.
      _ =
        Resolver.read("github://owner/repo/file.md", workspace_id: ws, project_dir: tmp)

      assert Registry.lookup(JidoClaw.VFS.WorkspaceRegistry, ws) == []
    end

    test "surfaces bootstrap failure instead of silently falling through" do
      ws = "test-resolver-bootstrap-fail-#{System.unique_integer([:positive])}"

      on_exit(fn -> _ = Workspace.teardown(ws) end)

      # project_dir: "" is rejected by Workspace.to_adapter_spec(:local, _)
      # as :local_missing_path — bootstrap is attempted and fails.
      assert {:error, {:workspace_bootstrap_failed, _reason}} =
               Resolver.read("/project/anything.txt", workspace_id: ws, project_dir: "")
    end
  end
end
