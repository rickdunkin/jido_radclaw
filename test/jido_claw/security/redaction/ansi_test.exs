defmodule JidoClaw.Security.Redaction.AnsiTest do
  use ExUnit.Case, async: true

  alias JidoClaw.Security.Redaction.Ansi

  describe "strip/1" do
    test "removes CSI color/style sequences" do
      assert Ansi.strip("\e[31mred\e[0m") == "red"
      assert Ansi.strip("\e[1;32mbold green\e[0m text") == "bold green text"
      assert Ansi.strip("plain") == "plain"
    end

    test "removes CSI cursor-movement sequences" do
      assert Ansi.strip("a\e[2Kb\e[1Gc") == "abc"
    end

    test "removes OSC sequences (titles, hyperlinks) with BEL or ST terminator" do
      # OSC terminated by BEL (\a == \x07)
      assert Ansi.strip("\e]0;window title\afoo") == "foo"
      # OSC terminated by ST (ESC \\)
      assert Ansi.strip("\e]8;;https://example.com\e\\link\e]8;;\e\\") == "link"
    end

    test "removes two-byte ESC sequences" do
      # ESC + a byte in the 0x40-0x5f range (here 'M', reverse line feed)
      assert Ansi.strip("before\eMafter") == "beforeafter"
    end

    test "reassembles an ANSI-split secret so the bytes are contiguous" do
      # The escape splits the key mid-string — stripping restores it for the
      # downstream pattern scan.
      split = "sk-ant-\e[0mabcdefghijklmnopqrstuvwx"
      assert Ansi.strip(split) == "sk-ant-abcdefghijklmnopqrstuvwx"
    end

    test "leaves text without escapes untouched, including the empty string" do
      assert Ansi.strip("") == ""
      assert Ansi.strip("no escapes here 123 !@#") == "no escapes here 123 !@#"
    end
  end
end
