defmodule JidoClaw.Tools.OutputShaper.MixCompileTest do
  use ExUnit.Case, async: true

  alias JidoClaw.Tools.OutputShaper.MixCompile, as: Parser

  test "clean compile collapses to a counts header" do
    text = """
    Compiling 12 files (.ex)
    Generated my_app app
    """

    assert {:ok, parsed} = Parser.parse(text)
    assert parsed.body == "mix compile — 12 files compiled, 0 warnings, 0 errors"
    assert parsed.summary == %{files_compiled: 12, warnings: 0, errors: 0}
  end

  test "per-file verbose progress lines are dropped and counted" do
    files = Enum.map_join(1..30, "\n", &"Compiling lib/my_app/module_#{&1}.ex")

    text = """
    #{files}
    Generated my_app app
    """

    assert {:ok, parsed} = Parser.parse(text)
    assert parsed.summary.files_compiled == 30
    refute parsed.body =~ "Compiling lib/my_app/module_1.ex"
    assert parsed.compressed?
  end

  test "warnings are kept verbatim" do
    text = """
    Compiling 3 files (.ex)
        warning: variable "unused" is unused
        │
      4 │   unused = 1
        │   ~
        │
        └─ lib/foo.ex:4:3: Foo.bar/0

    Generated my_app app
    """

    assert {:ok, parsed} = Parser.parse(text)
    assert parsed.summary.warnings == 1
    assert parsed.body =~ ~s(warning: variable "unused" is unused)
    assert parsed.body =~ "└─ lib/foo.ex:4:3: Foo.bar/0"
    refute parsed.body =~ "Compiling 3 files"
  end

  test "compilation errors are kept verbatim" do
    text = """
    Compiling 2 files (.ex)
    == Compilation error in file lib/broken.ex ==
    ** (CompileError) lib/broken.ex:5: undefined function nope/0
    """

    assert {:ok, parsed} = Parser.parse(text)
    assert parsed.summary.errors >= 1
    assert parsed.body =~ "** (CompileError) lib/broken.ex:5: undefined function nope/0"
  end

  test "output with no compile markers at all is :nomatch" do
    assert Parser.parse("just some random program output\nwith no compile shape") == :nomatch
  end
end
