defmodule JidoClaw.Tools.OutputShaper.GitDiffTest do
  use ExUnit.Case, async: true

  alias JidoClaw.Tools.OutputShaper.GitDiff, as: Parser

  @budget 24 * 1024

  defp file_chunk(path, added_lines, removed_lines) do
    added = Enum.map_join(1..added_lines//1, "\n", &"+added line #{&1}")
    removed = Enum.map_join(1..removed_lines//1, "\n", &"-removed line #{&1}")

    """
    diff --git a/#{path} b/#{path}
    index 111111..222222 100644
    --- a/#{path}
    +++ b/#{path}
    @@ -1,#{removed_lines} +1,#{added_lines} @@
    #{removed}
    #{added}
    """
  end

  test "stat header summarizes files and line counts; chunks kept under budget" do
    text = file_chunk("lib/foo.ex", 3, 1) <> file_chunk("lib/bar.ex", 2, 2)

    assert {:ok, parsed} = Parser.parse(text, @budget)

    assert parsed.body =~ "git diff — 2 files changed, +5/−3"
    assert parsed.body =~ "lib/foo.ex | +3 −1"
    assert parsed.body =~ "lib/bar.ex | +2 −2"
    # Both chunks fit the budget — kept verbatim.
    assert parsed.body =~ "diff --git a/lib/foo.ex b/lib/foo.ex"
    assert parsed.body =~ "+added line 1"

    assert parsed.summary.files_changed == 2
    assert parsed.summary.insertions == 5
    assert parsed.summary.deletions == 3
    assert [%{path: "lib/foo.ex"}, %{path: "lib/bar.ex"}] = parsed.summary.files
  end

  test "+++/--- header lines are not counted as insertions/deletions" do
    text = file_chunk("lib/foo.ex", 1, 1)

    assert {:ok, parsed} = Parser.parse(text, @budget)
    assert parsed.summary.insertions == 1
    assert parsed.summary.deletions == 1
  end

  test "chunks beyond the budget are elided with a count line" do
    text = file_chunk("lib/a.ex", 50, 0) <> file_chunk("lib/b.ex", 50, 0)
    [chunk_a, _] = String.split(text, "diff --git a/lib/b.ex", parts: 2)

    assert {:ok, parsed} = Parser.parse(text, byte_size(chunk_a) + 10)

    assert parsed.body =~ "diff --git a/lib/a.ex"
    refute parsed.body =~ "diff --git a/lib/b.ex"
    assert parsed.body =~ "... [1 more files:"
    # The stat header still lists EVERY file.
    assert parsed.body =~ "lib/b.ex | +50 −0"
  end

  test "binary files are flagged in the stat line" do
    text = """
    diff --git a/assets/logo.png b/assets/logo.png
    index 111111..222222 100644
    Binary files a/assets/logo.png and b/assets/logo.png differ
    """

    assert {:ok, parsed} = Parser.parse(text, @budget)
    assert parsed.body =~ "assets/logo.png | binary"
  end

  test "renames show both paths" do
    text = """
    diff --git a/lib/old_name.ex b/lib/new_name.ex
    similarity index 95%
    rename from lib/old_name.ex
    rename to lib/new_name.ex
    """

    assert {:ok, parsed} = Parser.parse(text, @budget)
    assert parsed.body =~ "lib/old_name.ex → lib/new_name.ex"
  end

  test "text without diff headers is :nomatch" do
    assert Parser.parse("", @budget) == :nomatch
    assert Parser.parse("no diff content here", @budget) == :nomatch
  end
end
