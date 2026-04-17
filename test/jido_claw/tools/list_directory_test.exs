defmodule JidoClaw.Tools.ListDirectoryTest do
  use ExUnit.Case, async: false

  alias JidoClaw.Tools.ListDirectory
  alias JidoClaw.VFS.Workspace

  setup do
    dir = Path.join(System.tmp_dir!(), "jido_list_dir_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, dir: dir}
  end

  defp touch(path) do
    File.write!(path, "")
  end

  describe "run/2 basic listing" do
    test "should list files with 'file' type indicator", %{dir: dir} do
      touch(Path.join(dir, "file_a.txt"))
      touch(Path.join(dir, "file_b.txt"))

      assert {:ok, result} = ListDirectory.run(%{path: dir}, %{})

      assert result.path == dir
      assert result.entries =~ "file  file_a.txt"
      assert result.entries =~ "file  file_b.txt"
    end

    test "should list subdirectories with 'dir' type indicator", %{dir: dir} do
      File.mkdir_p!(Path.join(dir, "subdir"))

      assert {:ok, result} = ListDirectory.run(%{path: dir}, %{})

      assert result.entries =~ "dir  subdir"
    end

    test "should list both files and directories in the same result", %{dir: dir} do
      touch(Path.join(dir, "readme.md"))
      File.mkdir_p!(Path.join(dir, "src"))

      assert {:ok, result} = ListDirectory.run(%{path: dir}, %{})

      assert result.entries =~ "file  readme.md"
      assert result.entries =~ "dir  src"
    end

    test "should return total count equal to number of entries", %{dir: dir} do
      touch(Path.join(dir, "a.txt"))
      touch(Path.join(dir, "b.txt"))
      File.mkdir_p!(Path.join(dir, "c"))

      assert {:ok, result} = ListDirectory.run(%{path: dir}, %{})

      assert result.total == 3
    end

    test "should return empty entries string for an empty directory", %{dir: dir} do
      assert {:ok, result} = ListDirectory.run(%{path: dir}, %{})

      assert result.entries == ""
      assert result.total == 0
    end
  end

  describe "run/2 glob pattern" do
    test "should return only files matching glob pattern", %{dir: dir} do
      touch(Path.join(dir, "app.ex"))
      touch(Path.join(dir, "app_test.exs"))
      touch(Path.join(dir, "README.md"))

      assert {:ok, result} = ListDirectory.run(%{path: dir, pattern: "*.ex"}, %{})

      assert result.entries =~ "app.ex"
      refute result.entries =~ "app_test.exs"
      refute result.entries =~ "README.md"
    end

    test "should support recursive glob pattern", %{dir: dir} do
      nested = Path.join(dir, "lib/deep")
      File.mkdir_p!(nested)
      touch(Path.join(nested, "module.ex"))
      touch(Path.join(dir, "mix.exs"))

      assert {:ok, result} = ListDirectory.run(%{path: dir, pattern: "**/*.ex"}, %{})

      assert result.entries =~ "module.ex"
      refute result.entries =~ "mix.exs"
    end

    test "should return zero total when no files match pattern", %{dir: dir} do
      touch(Path.join(dir, "notes.txt"))

      assert {:ok, result} = ListDirectory.run(%{path: dir, pattern: "*.ex"}, %{})

      assert result.total == 0
      assert result.entries == ""
    end
  end

  describe "run/2 max_results" do
    test "should respect max_results and truncate excess entries", %{dir: dir} do
      Enum.each(1..10, fn i -> touch(Path.join(dir, "file_#{i}.txt")) end)

      assert {:ok, result} = ListDirectory.run(%{path: dir, max_results: 3}, %{})

      listed_lines = result.entries |> String.split("\n") |> Enum.reject(&(&1 == ""))
      # 3 entry lines + 1 truncation note line
      assert length(listed_lines) == 4
      assert result.entries =~ "more entries truncated"
      assert result.total == 10
    end

    test "should not add truncation note when results fit within max_results", %{dir: dir} do
      touch(Path.join(dir, "only_one.txt"))

      assert {:ok, result} = ListDirectory.run(%{path: dir, max_results: 5}, %{})

      refute result.entries =~ "truncated"
    end
  end

  describe "run/2 error" do
    test "should return error when path does not exist", %{dir: dir} do
      nonexistent = Path.join(dir, "no_such_directory")

      assert {:error, message} = ListDirectory.run(%{path: nonexistent}, %{})

      assert message =~ "Cannot list"
      assert message =~ nonexistent
    end

    test "should return error when path is a file not a directory", %{dir: dir} do
      file_path = Path.join(dir, "a_file.txt")
      touch(file_path)

      assert {:error, message} = ListDirectory.run(%{path: file_path}, %{})

      assert message =~ "Cannot list"
    end
  end

  describe "run/2 with workspace_id (VFS path)" do
    test "lists entries from a mounted VFS filesystem" do
      workspace_id = "test-listdir-vfs-#{System.unique_integer([:positive])}"

      tmp =
        Path.join(
          System.tmp_dir!(),
          "jido_list_dir_vfs_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp)
      File.write!(Path.join(tmp, "one.txt"), "1")
      File.write!(Path.join(tmp, "two.txt"), "2")

      {:ok, _} = Workspace.ensure_started(workspace_id, tmp)

      on_exit(fn ->
        _ = Workspace.teardown(workspace_id)
        File.rm_rf!(tmp)
      end)

      assert {:ok, result} =
               ListDirectory.run(
                 %{path: "/project"},
                 %{tool_context: %{workspace_id: workspace_id, project_dir: tmp}}
               )

      assert result.entries =~ "one.txt"
      assert result.entries =~ "two.txt"
    end

    test "auto-bootstraps VFS when tool_context carries workspace_id + project_dir" do
      ws = "ws-listdir-autoboot-#{System.unique_integer([:positive])}"

      tmp =
        Path.join(
          System.tmp_dir!(),
          "jido_list_dir_autoboot_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp)
      File.write!(Path.join(tmp, "alpha.txt"), "a")
      File.write!(Path.join(tmp, "beta.txt"), "b")

      on_exit(fn ->
        _ = Workspace.teardown(ws)
        File.rm_rf!(tmp)
      end)

      assert Registry.lookup(JidoClaw.VFS.WorkspaceRegistry, ws) == []

      assert {:ok, result} =
               ListDirectory.run(
                 %{path: "/project"},
                 %{tool_context: %{workspace_id: ws, project_dir: tmp}}
               )

      assert result.entries =~ "alpha.txt"
      assert result.entries =~ "beta.txt"
    end

    test "surfaces bootstrap failure instead of silently falling through to local" do
      # Regression: under_workspace_mount?/2 used to convert every bootstrap
      # error into `false`, letting ListDirectory fall through to File.ls/1
      # and hiding the real failure. It must now surface the
      # :workspace_bootstrap_failed error.
      ws = "ws-listdir-boot-fail-#{System.unique_integer([:positive])}"
      on_exit(fn -> _ = Workspace.teardown(ws) end)

      assert {:error, message} =
               ListDirectory.run(
                 %{path: "/project/anything"},
                 %{tool_context: %{workspace_id: ws, project_dir: ""}}
               )

      assert message =~ "Cannot list /project/anything"
      assert message =~ "workspace_bootstrap_failed"
    end
  end
end
