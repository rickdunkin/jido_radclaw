defmodule JidoClaw.Conversations.TranscriptEnvelopeTest do
  use ExUnit.Case, async: true

  alias JidoClaw.Conversations.TranscriptEnvelope

  # Test fixture for the un-encodable struct case. `@derive Jason.Encoder`
  # in test modules is a no-op once protocols are consolidated, so we use
  # the standard-library `Decimal` (compile-time consolidated impl) for
  # the encodable case below.
  defmodule UnderivedStruct do
    defstruct [:label, :count]
  end

  describe "normalize/1" do
    test "wraps a 2-tuple :ok in the canonical envelope" do
      assert %{status: :ok, value: 42, error: nil, effects: nil, raw_inspect: nil} =
               TranscriptEnvelope.normalize({:ok, 42})
    end

    test "wraps a 3-tuple :ok with effects" do
      assert %{status: :ok, value: 1, effects: 2} =
               TranscriptEnvelope.normalize({:ok, 1, 2})
    end

    test "wraps an :error in the canonical envelope" do
      assert %{status: :error, value: nil, error: ":boom", effects: nil} =
               TranscriptEnvelope.normalize({:error, :boom})
    end

    test "atoms are stringified with leading colon" do
      assert TranscriptEnvelope.normalize(:foo) == ":foo"
      assert TranscriptEnvelope.normalize(nil) == nil
      assert TranscriptEnvelope.normalize(true) == true
    end

    test "tuples are wrapped in __tuple__ marker" do
      assert TranscriptEnvelope.normalize({1, 2}) == %{__tuple__: [1, 2]}
    end

    test "DateTime is encoded to ISO-8601" do
      dt = ~U[2026-05-01 10:00:00Z]
      assert TranscriptEnvelope.normalize(dt) == "2026-05-01T10:00:00Z"
    end

    test "nested map of arbitrary atoms recursively normalized" do
      input = %{a: :b, c: [1, :d, {3, 4}]}
      out = TranscriptEnvelope.normalize(input)
      assert out == %{a: ":b", c: [1, ":d", %{__tuple__: [3, 4]}]}
    end

    test "non-encodable structs fall back to raw_inspect" do
      ref = make_ref()

      assert %{status: :error, raw_inspect: insp} = TranscriptEnvelope.normalize(ref)
      assert is_binary(insp)
    end

    test "JSON encoding succeeds on the normalized output" do
      input = %{result: {:ok, %{tool: :read_file, args: [:foo, :bar]}, [side_effect: :wrote]}}
      normalized = TranscriptEnvelope.normalize(input)
      assert {:ok, _} = Jason.encode(normalized)
    end

    # Regression for the P1 fix: jason_encoder?/1 collapses to a two-clause
    # case under consolidated protocols. A struct that has a real
    # Jason.Encoder impl must round-trip through Jason; a struct without
    # one must fall back to the raw_inspect envelope. DateTime can't pin
    # this — it has its own walk/1 clause and never reaches
    # jason_encoder?/1, so we use a Decimal (which routes through
    # `walk(%_struct{})` and has a non-Any encoder impl) plus a custom
    # underived struct.
    test "struct with a real Jason.Encoder impl is round-tripped through Jason" do
      assert TranscriptEnvelope.normalize(Decimal.new(42)) == "42"
    end

    test "struct without Jason.Encoder falls back to raw_inspect envelope" do
      value = %UnderivedStruct{label: "x", count: 3}

      assert %{status: :error, value: nil, error: nil, effects: nil, raw_inspect: insp} =
               TranscriptEnvelope.normalize(value)

      assert is_binary(insp)
      assert insp =~ "UnderivedStruct"
    end
  end
end
