defmodule JidoClaw.RouteComposer.FindingKeyTest do
  @moduledoc """
  Camus C1-5 (next-ten #6) — the cross-wave finding identity: a versioned
  canonical term over (normalized location-file, normalized title) hashed via
  `JidoClaw.Core.CanonicalHash`. Pins the normalization rules (line-suffix
  drop, `./` strip, title-only downcase), the un-keyable fail-safe, and that
  distinct findings never collide.
  """
  use ExUnit.Case, async: true

  alias JidoClaw.Core.CanonicalHash
  alias JidoClaw.RouteComposer.FindingKey

  defp finding(title, location), do: %{"title" => title, "location" => location}

  test "deterministic: same finding → same key, and the key is the recipe hash" do
    f = finding("missing nil check", "lib/auth.ex:42")

    assert FindingKey.key(f) == FindingKey.key(f)

    assert FindingKey.key(f) ==
             CanonicalHash.sha256_term({:v1, "lib/auth.ex", "missing nil check"})

    assert FindingKey.key(f) =~ ~r/^[0-9a-f]{64}$/
  end

  test "atom-keyed (live Zoi) and string-keyed (JSONB round-trip) findings key identically" do
    assert FindingKey.key(%{title: "T", location: "lib/a.ex"}) ==
             FindingKey.key(%{"title" => "T", "location" => "lib/a.ex"})
  end

  test "line and line:col suffixes are dropped — a moved finding keeps its identity" do
    base = FindingKey.key(finding("off-by-one", "lib/win.ex"))

    assert FindingKey.key(finding("off-by-one", "lib/win.ex:8")) == base
    assert FindingKey.key(finding("off-by-one", "lib/win.ex:8:12")) == base
    assert FindingKey.key(finding("off-by-one", "lib/win.ex:914")) == base
  end

  test "a leading ./ is stripped and whitespace collapsed on both halves" do
    base = FindingKey.key(finding("dup logic", "lib/a.ex"))

    assert FindingKey.key(finding("dup logic", "./lib/a.ex")) == base
    assert FindingKey.key(finding("dup  logic", "  lib/a.ex ")) == base
    assert FindingKey.key(finding("dup\nlogic", "lib/a.ex:3")) == base
  end

  test "title downcases; the file half NEVER does (case-sensitive filesystems)" do
    assert FindingKey.key(finding("Missing Nil Check", "lib/a.ex")) ==
             FindingKey.key(finding("missing nil check", "lib/a.ex"))

    refute FindingKey.key(finding("t", "lib/A.ex")) == FindingKey.key(finding("t", "lib/a.ex"))
  end

  test "a non-line-suffix colon location (host:/etc) is preserved" do
    assert FindingKey.key(finding("t", "host:/etc")) ==
             CanonicalHash.sha256_term({:v1, "host:/etc", "t"})
  end

  test "un-keyable findings → nil (missing/blank title or location, non-map)" do
    refute FindingKey.keyable?(%{"location" => "lib/a.ex", "description" => "d"})
    refute FindingKey.keyable?(%{"title" => "t"})
    refute FindingKey.keyable?(finding("", "lib/a.ex"))
    refute FindingKey.keyable?(finding("   ", "lib/a.ex"))
    refute FindingKey.keyable?(finding("t", ""))
    refute FindingKey.keyable?(finding(nil, "lib/a.ex"))
    refute FindingKey.keyable?(finding("t", 42))
    assert FindingKey.key("not a map") == nil
    assert FindingKey.key(nil) == nil
  end

  test "distinct findings never collide (different title OR different file)" do
    keys = [
      FindingKey.key(finding("missing nil check", "lib/auth.ex:42")),
      FindingKey.key(finding("missing nil check", "lib/user.ex:42")),
      FindingKey.key(finding("unbounded recursion", "lib/auth.ex:42"))
    ]

    assert Enum.all?(keys, &is_binary/1)
    assert [_, _, _] = Enum.uniq(keys)
  end
end
