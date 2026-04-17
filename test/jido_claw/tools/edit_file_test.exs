defmodule JidoClaw.Tools.EditFileTest do
  use ExUnit.Case

  alias JidoClaw.Tools.EditFile
  alias JidoClaw.VFS.Workspace

  setup do
    dir = Path.join(System.tmp_dir!(), "jido_edit_file_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, dir: dir}
  end

  describe "run/2 success" do
    test "should replace unique string match and return diff", %{dir: dir} do
      path = Path.join(dir, "edit_me.txt")
      File.write!(path, "foo bar baz")

      assert {:ok, result} =
               EditFile.run(%{path: path, old_string: "bar", new_string: "qux"}, %{})

      assert result.path == path
      assert result.status == "edited"
      assert File.read!(path) == "foo qux baz"
    end

    test "should include removal and addition lines in diff", %{dir: dir} do
      path = Path.join(dir, "diff_check.txt")
      File.write!(path, "hello world")

      assert {:ok, result} =
               EditFile.run(%{path: path, old_string: "hello", new_string: "goodbye"}, %{})

      assert result.diff =~ "- hello"
      assert result.diff =~ "+ goodbye"
    end

    test "should replace only the first occurrence when string appears once", %{dir: dir} do
      path = Path.join(dir, "unique.txt")
      File.write!(path, "alpha beta gamma")

      assert {:ok, _result} =
               EditFile.run(%{path: path, old_string: "beta", new_string: "delta"}, %{})

      assert File.read!(path) == "alpha delta gamma"
    end

    test "should handle multi-line old_string and new_string", %{dir: dir} do
      path = Path.join(dir, "multiline.txt")
      File.write!(path, "line one\nline two\nline three")

      assert {:ok, result} =
               EditFile.run(
                 %{path: path, old_string: "line one\nline two", new_string: "replaced"},
                 %{}
               )

      assert result.status == "edited"
      assert File.read!(path) == "replaced\nline three"
    end
  end

  describe "run/2 error" do
    test "should return error when file does not exist", %{dir: dir} do
      path = Path.join(dir, "ghost.txt")

      assert {:error, message} =
               EditFile.run(%{path: path, old_string: "x", new_string: "y"}, %{})

      assert message =~ "Cannot read"
      assert message =~ path
    end

    test "should return error when old_string is not found in file", %{dir: dir} do
      path = Path.join(dir, "no_match.txt")
      File.write!(path, "some content here")

      assert {:error, message} =
               EditFile.run(
                 %{path: path, old_string: "not_present", new_string: "replacement"},
                 %{}
               )

      assert message =~ "not found"
      assert message =~ path
    end

    test "should return error when old_string matches multiple times", %{dir: dir} do
      path = Path.join(dir, "duplicate.txt")
      File.write!(path, "repeat repeat repeat")

      assert {:error, message} =
               EditFile.run(%{path: path, old_string: "repeat", new_string: "once"}, %{})

      assert message =~ "3 times"
      assert message =~ path
    end

    test "should return error mentioning occurrence count for two occurrences", %{dir: dir} do
      path = Path.join(dir, "two_occurrences.txt")
      File.write!(path, "hello world hello")

      assert {:error, message} =
               EditFile.run(%{path: path, old_string: "hello", new_string: "hi"}, %{})

      assert message =~ "2 times"
    end
  end

  describe "run/2 with workspace_id (VFS path)" do
    test "edits a file through a mounted VFS filesystem" do
      workspace_id = "test-editfile-vfs-#{System.unique_integer([:positive])}"

      tmp =
        Path.join(
          System.tmp_dir!(),
          "jido_edit_file_vfs_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp)
      {:ok, _} = Workspace.ensure_started(workspace_id, tmp)
      :ok = Workspace.mount(workspace_id, "/scratch", :in_memory, %{})
      :ok = Jido.Shell.VFS.write_file(workspace_id, "/scratch/doc.txt", "foo bar baz")

      on_exit(fn ->
        _ = Workspace.teardown(workspace_id)
        File.rm_rf!(tmp)
      end)

      assert {:ok, result} =
               EditFile.run(
                 %{path: "/scratch/doc.txt", old_string: "bar", new_string: "qux"},
                 %{tool_context: %{workspace_id: workspace_id, project_dir: tmp}}
               )

      assert result.status == "edited"
      assert {:ok, "foo qux baz"} = Jido.Shell.VFS.read_file(workspace_id, "/scratch/doc.txt")
    end

    test "auto-bootstraps VFS when tool_context carries workspace_id + project_dir" do
      ws = "ws-editfile-autoboot-#{System.unique_integer([:positive])}"

      tmp =
        Path.join(
          System.tmp_dir!(),
          "jido_edit_file_autoboot_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp)
      File.write!(Path.join(tmp, "edit_target.txt"), "foo bar baz")

      on_exit(fn ->
        _ = Workspace.teardown(ws)
        File.rm_rf!(tmp)
      end)

      assert Registry.lookup(JidoClaw.VFS.WorkspaceRegistry, ws) == []

      assert {:ok, result} =
               EditFile.run(
                 %{path: "/project/edit_target.txt", old_string: "bar", new_string: "qux"},
                 %{tool_context: %{workspace_id: ws, project_dir: tmp}}
               )

      assert result.status == "edited"
      assert File.read!(Path.join(tmp, "edit_target.txt")) == "foo qux baz"
    end
  end
end
