defmodule JidoClaw.Solutions.SearchEscapeTest do
  use ExUnit.Case, async: true

  alias JidoClaw.Solutions.SearchEscape

  describe "escape_like/1" do
    test "downcases input" do
      assert SearchEscape.escape_like("FooBar") == "foobar"
    end

    test "escapes literal % so it can't be used as a wildcard" do
      assert SearchEscape.escape_like("100%") == "100\\%"
    end

    test "escapes literal _ so it can't match any single char" do
      assert SearchEscape.escape_like("foo_bar") == "foo\\_bar"
    end

    test "escapes the backslash itself before the metacharacters" do
      # Source-side: input contains one literal backslash
      # `"\\"`. After escaping, that single backslash is doubled to
      # `"\\\\"` so the SQL LIKE engine sees `\\` (one literal `\`)
      # instead of treating it as an escape lead.
      assert SearchEscape.escape_like("\\") == "\\\\"
    end

    test "escapes mixed metachars in one pass" do
      # `100%_x\\` → lower → backslash doubled first, then % and _.
      assert SearchEscape.escape_like("100%_X\\") == "100\\%\\_x\\\\"
    end

    test "is a no-op on input with no metachars" do
      assert SearchEscape.escape_like("hello world") == "hello world"
    end
  end

  describe "lower_only/1" do
    test "downcases without escaping — feeds similarity()" do
      assert SearchEscape.lower_only("100%") == "100%"
      assert SearchEscape.lower_only("FooBar") == "foobar"
      assert SearchEscape.lower_only("foo_bar") == "foo_bar"
    end
  end
end
