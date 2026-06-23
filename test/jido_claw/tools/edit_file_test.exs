defmodule JidoClaw.Tools.EditFileTest do
  use ExUnit.Case, async: false
  @max_content_bytes 5 * 1024 * 1024
  import JidoClaw.ToolSchemaHelpers

  alias Jido.Shell.VFS
  alias JidoClaw.Tools.EditFile
  alias JidoClaw.VFS.Sandbox
  alias JidoClaw.VFS.Workspace

  setup do
    dir = Path.join(System.tmp_dir!(), "jido_edit_file_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, dir: dir}
  end

  defp context(dir), do: %{tool_context: %{project_dir: dir}}

  describe "run/2 success" do
    test "should replace unique string match and return diff", %{dir: dir} do
      path = Path.join(dir, "edit_me.txt")
      File.write!(path, "foo bar baz")

      assert {:ok, result} =
               EditFile.run(%{path: path, old_string: "bar", new_string: "qux"}, context(dir))

      assert result.path == path
      assert result.status == "edited"
      assert File.read!(path) == "foo qux baz"
    end

    test "should include removal and addition lines in diff", %{dir: dir} do
      path = Path.join(dir, "diff_check.txt")
      File.write!(path, "hello world")

      assert {:ok, result} =
               EditFile.run(
                 %{path: path, old_string: "hello", new_string: "goodbye"},
                 context(dir)
               )

      assert result.diff =~ "- hello"
      assert result.diff =~ "+ goodbye"
    end

    test "should replace only the first occurrence when string appears once", %{dir: dir} do
      path = Path.join(dir, "unique.txt")
      File.write!(path, "alpha beta gamma")

      assert {:ok, _result} =
               EditFile.run(
                 %{path: path, old_string: "beta", new_string: "delta"},
                 context(dir)
               )

      assert File.read!(path) == "alpha delta gamma"
    end

    test "should handle multi-line old_string and new_string", %{dir: dir} do
      path = Path.join(dir, "multiline.txt")
      File.write!(path, "line one\nline two\nline three")

      assert {:ok, result} =
               EditFile.run(
                 %{path: path, old_string: "line one\nline two", new_string: "replaced"},
                 context(dir)
               )

      assert result.status == "edited"
      assert File.read!(path) == "replaced\nline three"
    end
  end

  describe "run/2 error" do
    test "should return error when file does not exist", %{dir: dir} do
      path = Path.join(dir, "ghost.txt")

      assert {:error, %{message: message}} =
               EditFile.run(%{path: path, old_string: "x", new_string: "y"}, context(dir))

      assert message =~ "Cannot read"
      assert message =~ path
    end

    test "should return error when old_string is not found in file", %{dir: dir} do
      path = Path.join(dir, "no_match.txt")
      File.write!(path, "some content here")

      assert {:error, %{message: message}} =
               EditFile.run(
                 %{path: path, old_string: "not_present", new_string: "replacement"},
                 context(dir)
               )

      assert message =~ "not found"
      assert message =~ path
    end

    test "should return error when old_string matches multiple times", %{dir: dir} do
      path = Path.join(dir, "duplicate.txt")
      File.write!(path, "repeat repeat repeat")

      assert {:error, %{message: message}} =
               EditFile.run(
                 %{path: path, old_string: "repeat", new_string: "once"},
                 context(dir)
               )

      assert message =~ "3 times"
      assert message =~ path
    end

    test "should return error mentioning occurrence count for two occurrences", %{dir: dir} do
      path = Path.join(dir, "two_occurrences.txt")
      File.write!(path, "hello world hello")

      assert {:error, %{message: message}} =
               EditFile.run(
                 %{path: path, old_string: "hello", new_string: "hi"},
                 context(dir)
               )

      assert message =~ "2 times"
    end
  end

  describe "replacement size limit" do
    test "advertises caps for old_string and new_string in the tool schema" do
      assert max_length(tool_property_schema(EditFile, :old_string)) == @max_content_bytes
      assert max_length(tool_property_schema(EditFile, :new_string)) == @max_content_bytes
    end

    test "schema validation rejects oversized old_string" do
      oversized = String.duplicate("x", @max_content_bytes + 1)

      assert {:error, _reason} =
               EditFile.validate_params(%{
                 path: "too-large.txt",
                 old_string: oversized,
                 new_string: "ok"
               })
    end

    test "schema validation rejects oversized new_string" do
      oversized = String.duplicate("x", @max_content_bytes + 1)

      assert {:error, _reason} =
               EditFile.validate_params(%{
                 path: "too-large.txt",
                 old_string: "ok",
                 new_string: oversized
               })
    end

    test "run/2 rejects oversized old_string before reading", %{dir: dir} do
      path = Path.join(dir, "too-large-old.txt")
      oversized = String.duplicate("x", @max_content_bytes + 1)

      assert {:error, %{message: message}} =
               EditFile.run(%{path: path, old_string: oversized, new_string: "ok"}, context(dir))

      assert message =~ "old_string exceeds"
      assert message =~ "#{@max_content_bytes} byte limit"
    end

    test "run/2 rejects oversized new_string before reading", %{dir: dir} do
      path = Path.join(dir, "too-large-new.txt")
      oversized = String.duplicate("x", @max_content_bytes + 1)

      assert {:error, %{message: message}} =
               EditFile.run(%{path: path, old_string: "ok", new_string: oversized}, context(dir))

      assert message =~ "new_string exceeds"
      assert message =~ "#{@max_content_bytes} byte limit"
    end
  end

  describe "read size cap" do
    test "refuses to edit a local file over the 5 MB cap (pre-read stat guard)", %{dir: dir} do
      path = Path.join(dir, "big.txt")
      File.write!(path, :binary.copy("x", @max_content_bytes + 1))

      assert {:error, %{message: message}} =
               EditFile.run(%{path: path, old_string: "x", new_string: "y"}, context(dir))

      assert message =~ "read cap"
      assert message =~ "#{@max_content_bytes}"
    end

    test "refuses an edit whose result would exceed the write cap", %{dir: dir} do
      # Both inputs are under the cap; only the resulting content is
      # not (~4 MB file + ~2 MB replacement → ~6 MB result).
      path = Path.join(dir, "grow.txt")
      base = :binary.copy("a", 4 * 1024 * 1024)
      File.write!(path, "MARKER" <> base)

      new_string = :binary.copy("b", 2 * 1024 * 1024)

      assert {:error, %{message: message}} =
               EditFile.run(
                 %{path: path, old_string: "MARKER", new_string: new_string},
                 context(dir)
               )

      assert message =~ "new_content exceeds"
      # Refused before the write — the file is untouched.
      assert File.read!(path) == "MARKER" <> base
    end
  end

  describe "AR-8b sketch jail fails closed (review P2)" do
    test "a sandbox context with no project_dir refuses to edit a real-tree file" do
      sentinel =
        Path.join(File.cwd!(), "sketch_edit_sentinel_#{System.unique_integer([:positive])}.txt")

      File.write!(sentinel, "original")
      on_exit(fn -> File.rm_rf!(sentinel) end)

      assert {:error, _} =
               EditFile.run(
                 %{path: sentinel, old_string: "original", new_string: "tampered"},
                 %{tool_context: %{sandbox: :prototype}}
               )

      assert File.read!(sentinel) == "original"
    end

    test "a sandbox context with a non-.prototypes project_dir is rejected", %{dir: dir} do
      path = Path.join(dir, "f.txt")
      File.write!(path, "foo bar")

      assert {:error, _} =
               EditFile.run(
                 %{path: path, old_string: "bar", new_string: "qux"},
                 %{tool_context: %{project_dir: dir, sandbox: :prototype}}
               )

      assert File.read!(path) == "foo bar"
    end

    test "a valid .prototypes sandbox root still edits jailed", %{dir: dir} do
      {:ok, %{dir: proto}} = Sandbox.create_prototype_dir(dir)
      path = Path.join(proto, "edit_me.txt")
      File.write!(path, "foo bar baz")

      assert {:ok, result} =
               EditFile.run(
                 %{path: path, old_string: "bar", new_string: "qux"},
                 %{tool_context: %{project_dir: proto, sandbox: :prototype}}
               )

      assert result.status == "edited"
      assert File.read!(path) == "foo qux baz"
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
      :ok = VFS.write_file(workspace_id, "/scratch/doc.txt", "foo bar baz")

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
      assert {:ok, "foo qux baz"} = VFS.read_file(workspace_id, "/scratch/doc.txt")
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
