defmodule JidoClaw.Tools.SearchCodeTest do
  use ExUnit.Case, async: true

  alias JidoClaw.Tools.SearchCode

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

  describe "run/2 basic matching" do
    test "should find pattern and return matching lines with file paths", %{dir: dir} do
      write(dir, "source.ex", "defmodule Foo do\n  def bar, do: :ok\nend\n")

      assert {:ok, result} = SearchCode.run(%{pattern: "defmodule", path: dir}, %{})

      assert result.total_matches >= 1
      assert result.matches =~ "defmodule"
      assert result.matches =~ "source.ex"
    end

    test "should include line numbers in match output", %{dir: dir} do
      write(dir, "numbered.ex", "line one\ntarget line\nline three\n")

      assert {:ok, result} = SearchCode.run(%{pattern: "target", path: dir}, %{})

      assert result.matches =~ ":2:"
    end

    test "should return zero matches when pattern is not found in any file", %{dir: dir} do
      write(dir, "nothing.ex", "alpha beta gamma\n")

      assert {:ok, result} = SearchCode.run(%{pattern: "zzz_no_match_zzz", path: dir}, %{})

      assert result.total_matches == 0
      assert result.matches == ""
    end

    test "should match across multiple files", %{dir: dir} do
      write(dir, "a.ex", "hello from a\n")
      write(dir, "b.ex", "hello from b\n")

      assert {:ok, result} = SearchCode.run(%{pattern: "hello", path: dir}, %{})

      assert result.total_matches == 2
      assert result.matches =~ "a.ex"
      assert result.matches =~ "b.ex"
    end

    test "should support regex pattern", %{dir: dir} do
      # Uses basic regex (grep -rn without -E); [0-9][0-9][0-9] is portable across grep variants
      write(dir, "regex.ex", "foo123\nbar456\nbaz789\n")

      assert {:ok, result} = SearchCode.run(%{pattern: "[0-9][0-9][0-9]", path: dir}, %{})

      assert result.total_matches == 3
    end
  end

  describe "run/2 glob filter" do
    test "should return only matches from files matching glob filter", %{dir: dir} do
      write(dir, "module.ex", "look here\n")
      write(dir, "notes.md", "look here too\n")

      assert {:ok, result} = SearchCode.run(%{pattern: "look", path: dir, glob: "*.ex"}, %{})

      assert result.matches =~ "module.ex"
      refute result.matches =~ "notes.md"
    end

    test "should return zero matches when glob excludes all relevant files", %{dir: dir} do
      write(dir, "only.txt", "important content\n")

      assert {:ok, result} =
               SearchCode.run(%{pattern: "important", path: dir, glob: "*.ex"}, %{})

      assert result.total_matches == 0
    end

    test "should match files with exs extension when glob is *.exs", %{dir: dir} do
      write(dir, "config.exs", "config :app, key: :value\n")
      write(dir, "app.ex", "config :app, key: :value\n")

      assert {:ok, result} =
               SearchCode.run(%{pattern: "config :app", path: dir, glob: "*.exs"}, %{})

      assert result.matches =~ "config.exs"
      refute result.matches =~ "app.ex"
    end
  end

  describe "run/2 max_results" do
    test "should truncate results exceeding max_results", %{dir: dir} do
      content = Enum.map_join(1..20, "\n", &"match line #{&1}")
      write(dir, "many_matches.txt", content)

      assert {:ok, result} =
               SearchCode.run(%{pattern: "match line", path: dir, max_results: 5}, %{})

      lines =
        result.matches
        |> String.split("\n", trim: true)
        |> Enum.reject(&String.contains?(&1, "truncated"))

      assert length(lines) == 5
      assert result.matches =~ "more matches truncated"
    end

    test "should not add truncation note when results fit within max_results", %{dir: dir} do
      write(dir, "few.txt", "one match\n")

      assert {:ok, result} =
               SearchCode.run(%{pattern: "one match", path: dir, max_results: 50}, %{})

      refute result.matches =~ "truncated"
    end

    test "should report total_matches as full count before truncation", %{dir: dir} do
      content = Enum.map_join(1..10, "\n", &"hit #{&1}")
      write(dir, "hits.txt", content)

      assert {:ok, result} = SearchCode.run(%{pattern: "hit", path: dir, max_results: 3}, %{})

      assert result.total_matches == 10
    end
  end
end
