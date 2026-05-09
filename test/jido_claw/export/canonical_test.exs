defmodule JidoClaw.Export.CanonicalTest do
  @moduledoc """
  Coverage for the deterministic JSON encoder used by the export
  tasks. Round-trip exports rely on these properties:

    * Object keys sorted lexicographically (recursively).
    * Datetimes formatted as ISO8601 with microsecond precision.
    * No pretty-printing.
  """

  use ExUnit.Case, async: true

  alias JidoClaw.Export.Canonical

  test "encode!/1 sorts object keys recursively" do
    payload = %{"b" => %{"z" => 1, "a" => 2}, "a" => 3}
    encoded = Canonical.encode!(payload)
    assert encoded == ~s({"a":3,"b":{"a":2,"z":1}})
  end

  test "encode!/1 produces identical output across permutations" do
    a = %{"a" => 1, "b" => [%{"y" => 2, "x" => 1}], "c" => "x"}
    b = %{"c" => "x", "b" => [%{"x" => 1, "y" => 2}], "a" => 1}

    assert Canonical.encode!(a) == Canonical.encode!(b)
  end

  test "encode!/1 formats DateTime to ISO8601 microseconds" do
    {:ok, dt, _} = DateTime.from_iso8601("2026-05-07T12:00:00.123456Z")
    assert Canonical.encode!(%{"t" => dt}) == ~s({"t":"2026-05-07T12:00:00.123456Z"})
  end

  test "to_jsonl/1 emits one canonical record per line" do
    rows = [%{"b" => 1, "a" => 2}, %{"z" => "x"}]
    out = Canonical.to_jsonl(rows)
    assert out == ~s({"a":2,"b":1}\n{"z":"x"}\n)
  end
end
