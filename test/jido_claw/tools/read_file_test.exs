defmodule JidoClaw.Tools.ReadFileTest do
  use ExUnit.Case, async: false

  alias JidoClaw.Tools.ReadFile
  alias JidoClaw.VFS.Sandbox
  alias JidoClaw.VFS.Workspace

  setup do
    dir = Path.join(System.tmp_dir!(), "jido_read_file_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, dir: dir}
  end

  defp context(dir), do: %{tool_context: %{project_dir: dir}}

  describe "run/2 success" do
    test "should return numbered lines when file exists", %{dir: dir} do
      path = Path.join(dir, "sample.txt")
      File.write!(path, "alpha\nbeta\ngamma")

      assert {:ok, result} = ReadFile.run(%{path: path}, context(dir))

      assert result.path == path
      assert result.total_lines == 3
      assert result.content =~ "   1 │ alpha"
      assert result.content =~ "   2 │ beta"
      assert result.content =~ "   3 │ gamma"
    end

    test "should pad line numbers to four characters", %{dir: dir} do
      path = Path.join(dir, "padded.txt")
      File.write!(path, "only one line")

      assert {:ok, result} = ReadFile.run(%{path: path}, context(dir))

      assert result.content =~ "   1 │ only one line"
    end

    test "should respect offset param by skipping leading lines", %{dir: dir} do
      path = Path.join(dir, "offset.txt")
      File.write!(path, "line1\nline2\nline3\nline4")

      assert {:ok, result} = ReadFile.run(%{path: path, offset: 2}, context(dir))

      refute result.content =~ "│ line1"
      refute result.content =~ "│ line2"
      assert result.content =~ "│ line3"
      assert result.content =~ "│ line4"
    end

    test "should respect limit param by capping returned lines", %{dir: dir} do
      path = Path.join(dir, "limit.txt")
      content = Enum.map_join(1..10, "\n", &"line#{&1}")
      File.write!(path, content)

      assert {:ok, result} = ReadFile.run(%{path: path, limit: 3}, context(dir))

      lines = String.split(result.content, "\n", trim: true)
      assert [_, _, _] = lines
    end

    test "should apply offset and limit together", %{dir: dir} do
      path = Path.join(dir, "combined.txt")
      content = Enum.map_join(1..10, "\n", &"line#{&1}")
      File.write!(path, content)

      assert {:ok, result} = ReadFile.run(%{path: path, offset: 3, limit: 2}, context(dir))

      assert result.content =~ "│ line4"
      assert result.content =~ "│ line5"
      refute result.content =~ "│ line3"
      refute result.content =~ "│ line6"
    end

    test "should report total_lines regardless of offset or limit", %{dir: dir} do
      path = Path.join(dir, "total.txt")
      File.write!(path, "a\nb\nc\nd\ne")

      assert {:ok, result} = ReadFile.run(%{path: path, offset: 2, limit: 1}, context(dir))

      assert result.total_lines == 5
    end

    test "should handle empty file", %{dir: dir} do
      path = Path.join(dir, "empty.txt")
      File.write!(path, "")

      assert {:ok, result} = ReadFile.run(%{path: path}, context(dir))

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

  describe "run/2 read size cap" do
    @read_cap 5 * 1024 * 1024

    test "refuses a local file over the 5 MB cap (pre-read stat guard)", %{dir: dir} do
      path = Path.join(dir, "big.bin")
      File.write!(path, :binary.copy("x", @read_cap + 1))

      assert {:error, %{message: message}} = ReadFile.run(%{path: path}, context(dir))

      assert message =~ "read cap"
      assert message =~ "#{@read_cap}"
    end

    test "refuses an over-cap file read through a VFS mount (post-read guard)" do
      # /project/... is not under project_dir, so the pre-read stat
      # guard falls through and the unconditional post-read check is
      # what must fire here.
      workspace_id = "test-readfile-cap-#{System.unique_integer([:positive])}"

      tmp =
        Path.join(
          System.tmp_dir!(),
          "jido_read_file_cap_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp)
      File.write!(Path.join(tmp, "big.bin"), :binary.copy("x", @read_cap + 1))

      {:ok, _} = Workspace.ensure_started(workspace_id, tmp)

      on_exit(fn ->
        _ = Workspace.teardown(workspace_id)
        File.rm_rf!(tmp)
      end)

      assert {:error, %{message: message}} =
               ReadFile.run(
                 %{path: "/project/big.bin"},
                 %{tool_context: %{workspace_id: workspace_id, project_dir: tmp}}
               )

      assert message =~ "read cap"
    end

    # The exact ≤cap/>cap boundary is pinned on the shared guard helper
    # (file_payload_limit_test.exs) — pushing an at-cap 5 MB payload
    # through the full tool pipeline is needlessly slow (the output
    # redaction regexes dominate).
  end

  describe "run/2 error" do
    test "should return error when file does not exist", %{dir: dir} do
      path = Path.join(dir, "no_such_file.txt")

      assert {:error, %{message: message}} = ReadFile.run(%{path: path}, context(dir))

      assert message =~ "Cannot read"
      assert message =~ path
    end

    test "should return error when path is a directory", %{dir: dir} do
      assert {:error, %{message: message}} = ReadFile.run(%{path: dir}, context(dir))

      assert message =~ "non-regular local file (directory)"
    end

    test "rejects absolute paths outside the default project directory" do
      outside =
        Path.join(
          System.tmp_dir!(),
          "jido_read_file_outside_#{System.unique_integer([:positive])}.txt"
        )

      File.write!(outside, "outside")
      on_exit(fn -> File.rm(outside) end)

      assert {:error, %{message: message}} = ReadFile.run(%{path: outside}, %{})

      assert message =~ "Cannot read"
      assert message =~ "path_outside_project"
    end

    test "should reject negative offset", %{dir: dir} do
      path = Path.join(dir, "neg_offset.txt")
      File.write!(path, "a\nb\nc")

      assert {:error, %{message: "offset must be non-negative"}} =
               ReadFile.run(%{path: path, offset: -1}, context(dir))
    end

    test "should reject negative limit", %{dir: dir} do
      path = Path.join(dir, "neg_limit.txt")
      File.write!(path, "a\nb\nc")

      assert {:error, %{message: "limit must be non-negative"}} =
               ReadFile.run(%{path: path, limit: -1}, context(dir))
    end

    test "should reject when both offset and limit are negative", %{dir: dir} do
      path = Path.join(dir, "neg_both.txt")
      File.write!(path, "a\nb\nc")

      assert {:error, %{message: "offset must be non-negative"}} =
               ReadFile.run(%{path: path, offset: -1, limit: -1}, context(dir))
    end
  end

  describe "AR-8b sketch jail fails closed (review P2)" do
    test "the reviewer's repro: a sandbox context with no project_dir cannot read mix.exs" do
      assert {:error, _} =
               ReadFile.run(%{path: "mix.exs"}, %{tool_context: %{sandbox: :prototype}})
    end

    test "a sandbox context with a non-.prototypes project_dir is rejected", %{dir: dir} do
      File.write!(Path.join(dir, "f.txt"), "hi")

      assert {:error, _} =
               ReadFile.run(
                 %{path: Path.join(dir, "f.txt")},
                 %{tool_context: %{project_dir: dir, sandbox: :prototype}}
               )
    end

    test "a valid .prototypes sandbox root still reads jailed", %{dir: dir} do
      {:ok, %{dir: proto}} = Sandbox.create_prototype_dir(dir)
      path = Path.join(proto, "note.txt")
      File.write!(path, "inside the jail")

      assert {:ok, result} =
               ReadFile.run(
                 %{path: path},
                 %{tool_context: %{project_dir: proto, sandbox: :prototype}}
               )

      assert result.content =~ "inside the jail"
    end
  end

  describe "run/2 edge cases" do
    test "should return empty content when offset exceeds line count", %{dir: dir} do
      path = Path.join(dir, "past_end.txt")
      File.write!(path, "a\nb\nc")

      assert {:ok, result} = ReadFile.run(%{path: path, offset: 100}, context(dir))

      assert result.content == ""
      assert result.total_lines == 3
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
        _ = Workspace.teardown(ws)
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
        _ = Workspace.teardown(ws)
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
