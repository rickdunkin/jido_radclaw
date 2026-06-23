defmodule JidoClaw.Tools.SearchCodeTest do
  use ExUnit.Case, async: false

  alias JidoClaw.Tools.SearchCode
  alias JidoClaw.VFS.Sandbox
  alias JidoClaw.VFS.Workspace

  setup do
    dir = Path.join(System.tmp_dir!(), "jido_search_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, dir: dir}
  end

  defp write(dir, name, content) do
    path = Path.join(dir, name)
    File.write!(path, content)
    path
  end

  defp context(dir), do: %{tool_context: %{project_dir: dir}}

  describe "run/2 basic matching" do
    test "should find pattern and return matching lines with file paths", %{dir: dir} do
      write(dir, "source.ex", "defmodule Foo do\n  def bar, do: :ok\nend\n")

      assert {:ok, result} = SearchCode.run(%{pattern: "defmodule", path: dir}, context(dir))

      assert result.total_matches >= 1
      assert result.matches =~ "defmodule"
      assert result.matches =~ "source.ex"
    end

    test "should include line numbers in match output", %{dir: dir} do
      write(dir, "numbered.ex", "line one\ntarget line\nline three\n")

      assert {:ok, result} = SearchCode.run(%{pattern: "target", path: dir}, context(dir))

      assert result.matches =~ ":2:"
    end

    test "should return zero matches when pattern is not found in any file", %{dir: dir} do
      write(dir, "nothing.ex", "alpha beta gamma\n")

      assert {:ok, result} =
               SearchCode.run(%{pattern: "zzz_no_match_zzz", path: dir}, context(dir))

      assert result.total_matches == 0
      assert result.matches == ""
    end

    test "should match across multiple files", %{dir: dir} do
      write(dir, "a.ex", "hello from a\n")
      write(dir, "b.ex", "hello from b\n")

      assert {:ok, result} = SearchCode.run(%{pattern: "hello", path: dir}, context(dir))

      assert result.total_matches == 2
      assert result.matches =~ "a.ex"
      assert result.matches =~ "b.ex"
    end

    test "should support regex pattern", %{dir: dir} do
      # Uses basic regex (grep -rn without -E); [0-9][0-9][0-9] is portable across grep variants
      write(dir, "regex.ex", "foo123\nbar456\nbaz789\n")

      assert {:ok, result} =
               SearchCode.run(%{pattern: "[0-9][0-9][0-9]", path: dir}, context(dir))

      assert result.total_matches == 3
    end
  end

  describe "run/2 glob filter" do
    test "should return only matches from files matching glob filter", %{dir: dir} do
      write(dir, "module.ex", "look here\n")
      write(dir, "notes.md", "look here too\n")

      assert {:ok, result} =
               SearchCode.run(%{pattern: "look", path: dir, glob: "*.ex"}, context(dir))

      assert result.matches =~ "module.ex"
      refute result.matches =~ "notes.md"
    end

    test "should return zero matches when glob excludes all relevant files", %{dir: dir} do
      write(dir, "only.txt", "important content\n")

      assert {:ok, result} =
               SearchCode.run(%{pattern: "important", path: dir, glob: "*.ex"}, context(dir))

      assert result.total_matches == 0
    end

    test "should match files with exs extension when glob is *.exs", %{dir: dir} do
      write(dir, "config.exs", "config :app, key: :value\n")
      write(dir, "app.ex", "config :app, key: :value\n")

      assert {:ok, result} =
               SearchCode.run(
                 %{pattern: "config :app", path: dir, glob: "*.exs"},
                 context(dir)
               )

      assert result.matches =~ "config.exs"
      refute result.matches =~ "app.ex"
    end
  end

  describe "run/2 max_results" do
    test "should truncate results exceeding max_results", %{dir: dir} do
      content = Enum.map_join(1..20, "\n", &"match line #{&1}")
      write(dir, "many_matches.txt", content)

      assert {:ok, result} =
               SearchCode.run(%{pattern: "match line", path: dir, max_results: 5}, context(dir))

      lines =
        result.matches
        |> String.split("\n", trim: true)
        |> Enum.reject(&String.contains?(&1, "truncated"))

      assert Enum.count(lines) == 5
      assert result.matches =~ "more matches truncated"
    end

    test "should not add truncation note when results fit within max_results", %{dir: dir} do
      write(dir, "few.txt", "one match\n")

      assert {:ok, result} =
               SearchCode.run(%{pattern: "one match", path: dir, max_results: 50}, context(dir))

      refute result.matches =~ "truncated"
    end

    test "should report total_matches as full count before truncation", %{dir: dir} do
      content = Enum.map_join(1..10, "\n", &"hit #{&1}")
      write(dir, "hits.txt", content)

      assert {:ok, result} =
               SearchCode.run(%{pattern: "hit", path: dir, max_results: 3}, context(dir))

      assert result.total_matches == 10
    end
  end

  describe "AR-8b sketch jail fails closed (review P2)" do
    test "a sandbox context with no project_dir refuses to search the real tree" do
      assert {:error, _} =
               SearchCode.run(
                 %{pattern: "defmodule JidoClaw"},
                 %{tool_context: %{sandbox: :prototype}}
               )
    end

    test "a sandbox context with a non-.prototypes project_dir is rejected", %{dir: dir} do
      write(dir, "f.ex", "defmodule Foo do\nend\n")

      assert {:error, _} =
               SearchCode.run(
                 %{pattern: "defmodule", path: dir},
                 %{tool_context: %{project_dir: dir, sandbox: :prototype}}
               )
    end

    test "a valid .prototypes sandbox root still searches jailed", %{dir: dir} do
      {:ok, %{dir: proto}} = Sandbox.create_prototype_dir(dir)
      write(proto, "src.ex", "defmodule Sketch do\nend\n")

      assert {:ok, result} =
               SearchCode.run(
                 %{pattern: "defmodule", path: proto},
                 %{tool_context: %{project_dir: proto, sandbox: :prototype}}
               )

      assert result.total_matches >= 1
      assert result.matches =~ "src.ex"
    end
  end

  describe "run/2 path routing" do
    test "rejects absolute paths outside the project directory", %{dir: dir} do
      outside =
        Path.join(System.tmp_dir!(), "jido_search_outside_#{System.unique_integer([:positive])}")

      File.mkdir_p!(outside)
      write(outside, "secret.txt", "outside secret\n")

      on_exit(fn -> File.rm_rf!(outside) end)

      assert {:error, %{message: message}} =
               SearchCode.run(%{pattern: "outside secret", path: outside}, context(dir))

      assert message =~ "Cannot search"
      assert message =~ "path_outside_project"
    end

    test "searches a mounted /project path through the VFS resolver", %{dir: dir} do
      workspace_id = "search-code-vfs-#{System.unique_integer([:positive])}"
      write(dir, "mounted.ex", "defmodule Mounted do\nend\n")

      {:ok, _} = Workspace.ensure_started(workspace_id, dir)

      on_exit(fn -> Workspace.teardown(workspace_id) end)

      assert {:ok, result} =
               SearchCode.run(
                 %{pattern: "defmodule", path: "/project"},
                 %{tool_context: %{workspace_id: workspace_id, project_dir: dir}}
               )

      assert result.total_matches == 1
      assert result.matches =~ "/project/mounted.ex:1:defmodule Mounted do"
    end
  end
end
