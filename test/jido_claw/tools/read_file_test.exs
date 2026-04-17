defmodule JidoClaw.Tools.ReadFileTest do
  use ExUnit.Case, async: false

  alias JidoClaw.Tools.ReadFile
  alias JidoClaw.VFS.Workspace

  setup do
    dir = Path.join(System.tmp_dir!(), "jido_read_file_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, dir: dir}
  end

  describe "run/2 success" do
    test "should return numbered lines when file exists", %{dir: dir} do
      path = Path.join(dir, "sample.txt")
      File.write!(path, "alpha\nbeta\ngamma")

      assert {:ok, result} = ReadFile.run(%{path: path}, %{})

      assert result.path == path
      assert result.total_lines == 3
      assert result.content =~ "   1 │ alpha"
      assert result.content =~ "   2 │ beta"
      assert result.content =~ "   3 │ gamma"
    end

    test "should pad line numbers to four characters", %{dir: dir} do
      path = Path.join(dir, "padded.txt")
      File.write!(path, "only one line")

      assert {:ok, result} = ReadFile.run(%{path: path}, %{})

      assert result.content =~ "   1 │ only one line"
    end

    test "should respect offset param by skipping leading lines", %{dir: dir} do
      path = Path.join(dir, "offset.txt")
      File.write!(path, "line1\nline2\nline3\nline4")

      assert {:ok, result} = ReadFile.run(%{path: path, offset: 2}, %{})

      refute result.content =~ "│ line1"
      refute result.content =~ "│ line2"
      assert result.content =~ "│ line3"
      assert result.content =~ "│ line4"
    end

    test "should respect limit param by capping returned lines", %{dir: dir} do
      path = Path.join(dir, "limit.txt")
      content = Enum.map_join(1..10, "\n", &"line#{&1}")
      File.write!(path, content)

      assert {:ok, result} = ReadFile.run(%{path: path, limit: 3}, %{})

      lines = String.split(result.content, "\n", trim: true)
      assert length(lines) == 3
    end

    test "should apply offset and limit together", %{dir: dir} do
      path = Path.join(dir, "combined.txt")
      content = Enum.map_join(1..10, "\n", &"line#{&1}")
      File.write!(path, content)

      assert {:ok, result} = ReadFile.run(%{path: path, offset: 3, limit: 2}, %{})

      assert result.content =~ "│ line4"
      assert result.content =~ "│ line5"
      refute result.content =~ "│ line3"
      refute result.content =~ "│ line6"
    end

    test "should report total_lines regardless of offset or limit", %{dir: dir} do
      path = Path.join(dir, "total.txt")
      File.write!(path, "a\nb\nc\nd\ne")

      assert {:ok, result} = ReadFile.run(%{path: path, offset: 2, limit: 1}, %{})

      assert result.total_lines == 5
    end

    test "should handle empty file", %{dir: dir} do
      path = Path.join(dir, "empty.txt")
      File.write!(path, "")

      assert {:ok, result} = ReadFile.run(%{path: path}, %{})

      assert result.total_lines == 1
      assert result.content =~ "│"
    end
  end

  describe "run/2 with workspace_id in tool_context (VFS path)" do
    test "reads through an InMemory mount when path is under the mount" do
      workspace_id = "test-readfile-vfs-#{System.unique_integer([:positive])}"

      tmp =
        Path.join(
          System.tmp_dir!(),
          "jido_read_file_vfs_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp)
      File.write!(Path.join(tmp, "hello.txt"), "vfs-backed")

      {:ok, _} = Workspace.ensure_started(workspace_id, tmp)

      on_exit(fn ->
        _ = Workspace.teardown(workspace_id)
        File.rm_rf!(tmp)
      end)

      assert {:ok, result} =
               ReadFile.run(
                 %{path: "/project/hello.txt"},
                 %{tool_context: %{workspace_id: workspace_id, project_dir: tmp}}
               )

      assert result.content =~ "vfs-backed"
      assert result.total_lines == 1
    end
  end

  describe "run/2 error" do
    test "should return error when file does not exist", %{dir: dir} do
      path = Path.join(dir, "no_such_file.txt")

      assert {:error, message} = ReadFile.run(%{path: path}, %{})

      assert message =~ "Cannot read"
      assert message =~ path
    end

    test "should return error when path is a directory", %{dir: dir} do
      assert {:error, message} = ReadFile.run(%{path: dir}, %{})

      assert message =~ "Cannot read"
    end
  end

  describe "run/2 auto-bootstrap via tool_context" do
    test "auto-bootstraps VFS when tool_context carries workspace_id + project_dir" do
      # The reviewer's repro: a fresh agent has never called run_command,
      # so SessionManager hasn't bootstrapped the workspace. Resolver must
      # bootstrap on its own using the :project_dir we thread through.
      ws = "ws-no-mount-#{System.unique_integer([:positive])}"

      tmp =
        Path.join(
          System.tmp_dir!(),
          "jido_read_file_autoboot_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp)
      File.write!(Path.join(tmp, "mix.exs"), "# fake mix.exs")

      on_exit(fn ->
        _ = JidoClaw.VFS.Workspace.teardown(ws)
        File.rm_rf!(tmp)
      end)

      assert Registry.lookup(JidoClaw.VFS.WorkspaceRegistry, ws) == []

      assert {:ok, result} =
               ReadFile.run(
                 %{path: "/project/mix.exs"},
                 %{tool_context: %{workspace_id: ws, project_dir: tmp}}
               )

      assert result.content =~ "fake mix.exs"
    end

    test "workspace reuse with a different project_dir picks up the new mount" do
      ws = "ws-reuse-#{System.unique_integer([:positive])}"

      dir_a =
        Path.join(
          System.tmp_dir!(),
          "jido_read_file_reuse_a_#{System.unique_integer([:positive])}"
        )

      dir_b =
        Path.join(
          System.tmp_dir!(),
          "jido_read_file_reuse_b_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(dir_a)
      File.mkdir_p!(dir_b)
      File.write!(Path.join(dir_a, "only_a.txt"), "from A")
      File.write!(Path.join(dir_b, "only_b.txt"), "from B")

      on_exit(fn ->
        _ = JidoClaw.VFS.Workspace.teardown(ws)
        File.rm_rf!(dir_a)
        File.rm_rf!(dir_b)
      end)

      assert {:ok, result_a} =
               ReadFile.run(
                 %{path: "/project/only_a.txt"},
                 %{tool_context: %{workspace_id: ws, project_dir: dir_a}}
               )

      assert result_a.content =~ "from A"

      # Second call with a different project_dir must rebuild the workspace
      # and find only_b.txt in the new mount.
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, result_b} =
                   ReadFile.run(
                     %{path: "/project/only_b.txt"},
                     %{tool_context: %{workspace_id: ws, project_dir: dir_b}}
                   )

          assert result_b.content =~ "from B"
        end)

      assert log =~ "project_dir drift"
    end
  end
end
