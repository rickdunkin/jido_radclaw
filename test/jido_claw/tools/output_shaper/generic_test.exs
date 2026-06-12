defmodule JidoClaw.Tools.OutputShaper.GenericTest do
  use ExUnit.Case, async: true

  alias JidoClaw.Tools.OutputShaper.Generic

  test "keeps head and tail with an elision marker between" do
    head = String.duplicate("H", 100)
    middle = String.duplicate("m", 1_000)
    tail = String.duplicate("T", 100)
    text = head <> middle <> tail

    assert {:ok, body} = Generic.head_tail(text, 100, 100)

    assert String.starts_with?(body, head)
    assert String.ends_with?(body, tail)
    assert body =~ "... [elided 1000 bytes] ..."
    assert byte_size(body) < byte_size(text)
  end

  test "text within the combined budget signals no-compress" do
    assert Generic.head_tail("short output", 100, 100) == :nocompress
    assert Generic.head_tail(String.duplicate("x", 200), 100, 100) == :nocompress
  end

  test "head cut is UTF-8 safe when it lands mid-codepoint" do
    # '€' is 3 bytes; a 100-byte head cut lands inside the 34th '€'.
    text = String.duplicate("€", 200)

    assert {:ok, body} = Generic.head_tail(text, 100, 50)
    assert String.valid?(body)

    [head_part | _] = String.split(body, "\n\n... [elided")
    assert byte_size(head_part) <= 100
    assert String.valid?(head_part)
  end

  test "tail cut is UTF-8 safe when it lands mid-codepoint" do
    text = String.duplicate("€", 200)

    assert {:ok, body} = Generic.head_tail(text, 99, 100)
    assert String.valid?(body)

    [_, tail_part] = String.split(body, "bytes] ...\n\n", parts: 2)
    assert byte_size(tail_part) <= 100
    assert String.valid?(tail_part)
    assert String.ends_with?(body, "€")
  end

  test "valid_utf8_suffix drops leading continuation bytes" do
    # Cutting "a€b" after byte 2 lands mid-'€': two continuation bytes lead.
    <<_::binary-size(2), rest::binary>> = "a€b"
    refute String.valid?(rest)

    assert Generic.valid_utf8_suffix(rest) == "b"
  end

  describe "fit/2" do
    test "text within the budget signals no-compress" do
      assert Generic.fit("short output", 100) == :nocompress
      assert Generic.fit(String.duplicate("x", 100), 100) == :nocompress
    end

    test "oversized text fits within the budget, marker included" do
      text =
        String.duplicate("H", 500) <> String.duplicate("m", 5_000) <> String.duplicate("T", 500)

      assert {:ok, body} = Generic.fit(text, 1_000)

      assert byte_size(body) <= 1_000
      assert String.valid?(body)
      assert String.starts_with?(body, "HH")
      assert String.ends_with?(body, "TT")
      assert body =~ "... [elided"
    end

    test "split is tail-weighted at 1:2 of the usable budget" do
      text = String.duplicate("a", 10_000)

      assert {:ok, body} = Generic.fit(text, 1_000)

      assert [head_part, tail_part] =
               String.split(body, ~r/\n\n\.\.\. \[elided \d+ bytes\] \.\.\.\n\n/)

      # 64-byte marker allowance off the budget, then head = usable/3.
      usable = 1_000 - 64
      assert byte_size(head_part) == div(usable, 3)
      assert byte_size(tail_part) == usable - div(usable, 3)
    end

    test "never exceeds the budget across a range of budgets" do
      text = String.duplicate("x", 4_096)

      for budget <- [0, 1, 10, 63, 64, 65, 100, 256, 1_000, 4_095] do
        assert {:ok, body} = Generic.fit(text, budget)
        assert byte_size(body) <= budget
      end
    end

    test "degenerate budget floors to a suffix of the input, no marker" do
      text = "abcdefghijklmnopqrstuvwxyz0123456789"

      assert {:ok, body} = Generic.fit(text, 10)

      assert body == "0123456789"
      refute body =~ "elided"
    end

    test "budget of zero returns an empty body" do
      assert Generic.fit("anything at all", 0) == {:ok, ""}
    end

    test "degenerate-budget suffix is UTF-8 safe with multi-byte input" do
      # '€' is 3 bytes; a 10-byte suffix cut lands mid-codepoint and must
      # floor to the last 3 whole codepoints (9 bytes).
      text = String.duplicate("€", 50)

      assert {:ok, body} = Generic.fit(text, 10)

      assert byte_size(body) <= 10
      assert String.valid?(body)
      assert body == String.duplicate("€", 3)
    end
  end
end
