defmodule JidoClaw.Core.MapKeysTest do
  use ExUnit.Case, async: true

  alias JidoClaw.Core.MapKeys

  describe "field/3 — fetch-default semantics" do
    test "atom preferred, both keys present: atom wins" do
      assert MapKeys.field(%{:foo => 1, "foo" => 2}, :foo) == 1
    end

    test "atom preferred, only string key present: string wins" do
      assert MapKeys.field(%{"foo" => 2}, :foo) == 2
    end

    test "string preferred, both keys present: string wins" do
      assert MapKeys.field(%{:foo => 1, "foo" => 2}, "foo") == 2
    end

    test "string preferred, only atom key present: atom wins" do
      assert MapKeys.field(%{foo: 1}, "foo") == 1
    end

    test "atom present and nil: returns nil, NOT string fallback" do
      assert MapKeys.field(%{:foo => nil, "foo" => 2}, :foo) == nil
    end

    test "atom present and false: returns false, NOT string fallback" do
      assert MapKeys.field(%{:foo => false, "foo" => 2}, :foo) == false
    end

    test "neither key present: returns default" do
      assert MapKeys.field(%{other: 1}, :foo, :missing) == :missing
    end

    test "neither key present, no default: returns nil" do
      assert MapKeys.field(%{}, :foo) == nil
    end

    test "non-map input: returns default" do
      assert MapKeys.field(nil, :foo, :default) == :default
      assert MapKeys.field("not a map", :foo, :default) == :default
      assert MapKeys.field([], :foo, :default) == :default
    end

    test "string-preferred with no existing atom: falls back to default" do
      string_key = "definitely_not_an_existing_atom_#{System.unique_integer()}"
      assert MapKeys.field(%{}, string_key, :default) == :default
    end
  end

  describe "coalesce_field/3 — || semantics" do
    test "atom preferred, both keys present: atom wins" do
      assert MapKeys.coalesce_field(%{:foo => 1, "foo" => 2}, :foo) == 1
    end

    test "atom preferred, only string key present: string wins" do
      assert MapKeys.coalesce_field(%{"foo" => 2}, :foo) == 2
    end

    test "string preferred, both keys present: string wins" do
      assert MapKeys.coalesce_field(%{:foo => 1, "foo" => 2}, "foo") == 2
    end

    test "atom present and nil: falls through to string key" do
      assert MapKeys.coalesce_field(%{:foo => nil, "foo" => 2}, :foo) == 2
    end

    test "atom present and false: falls through to string key" do
      assert MapKeys.coalesce_field(%{:foo => false, "foo" => 2}, :foo) == 2
    end

    test "both falsy: returns default" do
      assert MapKeys.coalesce_field(%{:foo => nil, "foo" => false}, :foo, :fallback) ==
               :fallback
    end

    test "neither key present: returns default" do
      assert MapKeys.coalesce_field(%{other: 1}, :foo, :missing) == :missing
    end

    test "non-map input: returns default" do
      assert MapKeys.coalesce_field(nil, :foo, :default) == :default
      assert MapKeys.coalesce_field([], :foo, :default) == :default
    end
  end

  describe "normalize_keys(:string) shallow" do
    test "atom keys become strings" do
      assert MapKeys.normalize_keys(%{foo: 1, bar: 2}, :string) ==
               %{"foo" => 1, "bar" => 2}
    end

    test "string keys pass through" do
      assert MapKeys.normalize_keys(%{"foo" => 1}, :string) == %{"foo" => 1}
    end

    test "mixed keys are unified" do
      assert MapKeys.normalize_keys(%{:foo => 1, "bar" => 2}, :string) ==
               %{"foo" => 1, "bar" => 2}
    end

    test "idempotent on already-string keys" do
      m = %{"foo" => 1, "bar" => %{nested: 2}}
      assert MapKeys.normalize_keys(m, :string) == m
    end

    test "shallow does not recurse" do
      assert MapKeys.normalize_keys(%{foo: %{nested: 1}}, :string) ==
               %{"foo" => %{nested: 1}}
    end
  end

  describe "normalize_keys(:atom_existing) shallow" do
    test "existing atom keys pass through" do
      :existing_atom_key

      assert MapKeys.normalize_keys(%{"existing_atom_key" => 1}, :atom_existing) ==
               %{existing_atom_key: 1}
    end

    test "atom keys pass through" do
      assert MapKeys.normalize_keys(%{existing_atom_key: 1}, :atom_existing) ==
               %{existing_atom_key: 1}
    end

    test "unknown strings are retained as strings by default" do
      string_key = "never_an_atom_#{System.unique_integer([:positive])}"
      out = MapKeys.normalize_keys(%{string_key => 1}, :atom_existing)
      assert out == %{string_key => 1}
    end

    test "unknown strings are dropped with drop_unknown: true" do
      string_key = "never_an_atom_#{System.unique_integer([:positive])}"
      :other_existing_atom

      out =
        MapKeys.normalize_keys(
          %{string_key => 1, "other_existing_atom" => 2},
          :atom_existing,
          drop_unknown: true
        )

      assert out == %{other_existing_atom: 2}
    end
  end

  describe "normalize_keys deep recursion" do
    test ":deep walks nested maps" do
      assert MapKeys.normalize_keys(%{foo: %{bar: 1}}, :string, deep: true) ==
               %{"foo" => %{"bar" => 1}}
    end

    test ":deep walks lists of maps" do
      assert MapKeys.normalize_keys(%{foo: [%{bar: 1}, %{baz: 2}]}, :string, deep: true) ==
               %{"foo" => [%{"bar" => 1}, %{"baz" => 2}]}
    end

    test ":deep recurses into nested lists" do
      input = %{foo: [[%{bar: 1}], %{baz: 2}]}

      assert MapKeys.normalize_keys(input, :string, deep: true) ==
               %{"foo" => [[%{"bar" => 1}], %{"baz" => 2}]}
    end

    test "without :deep nested keys are untouched" do
      assert MapKeys.normalize_keys(%{foo: %{bar: 1}}, :string) ==
               %{"foo" => %{bar: 1}}
    end

    test "is idempotent" do
      input = %{foo: %{bar: [%{baz: 1}]}}
      once = MapKeys.normalize_keys(input, :string, deep: true)
      twice = MapKeys.normalize_keys(once, :string, deep: true)
      assert once == twice
    end
  end

  describe "normalize_keys struct passthrough" do
    test "structs at top level are rejected by the public API" do
      assert_raise FunctionClauseError, fn ->
        MapKeys.normalize_keys(DateTime.utc_now(), :string)
      end
    end

    test "nested DateTime survives :deep" do
      dt = DateTime.utc_now()

      out = MapKeys.normalize_keys(%{inserted_at: dt}, :string, deep: true)
      assert out == %{"inserted_at" => dt}
      assert out["inserted_at"] == dt
    end

    test "nested struct inside a list survives :deep" do
      dt = DateTime.utc_now()
      input = %{events: [%{at: dt}, %{at: dt}]}
      out = MapKeys.normalize_keys(input, :string, deep: true)
      assert out == %{"events" => [%{"at" => dt}, %{"at" => dt}]}
    end

    test "nested NaiveDateTime survives :deep" do
      ndt = NaiveDateTime.utc_now()
      out = MapKeys.normalize_keys(%{at: ndt}, :string, deep: true)
      assert out["at"] == ndt
    end
  end

  describe "normalize_keys collision precedence" do
    test ":atom_existing — atom key wins on collision" do
      :collision_existing_atom_a

      out =
        MapKeys.normalize_keys(
          %{"collision_existing_atom_a" => 2, :collision_existing_atom_a => 1},
          :atom_existing
        )

      assert out == %{collision_existing_atom_a: 1}
    end

    test ":atom_existing — precedence is deterministic across insertion orders" do
      :collision_existing_atom_b

      # String written first, atom second
      m1 =
        %{}
        |> Map.put("collision_existing_atom_b", 99)
        |> Map.put(:collision_existing_atom_b, 1)

      # Atom written first, string second
      m2 =
        %{}
        |> Map.put(:collision_existing_atom_b, 1)
        |> Map.put("collision_existing_atom_b", 99)

      assert MapKeys.normalize_keys(m1, :atom_existing) == %{collision_existing_atom_b: 1}
      assert MapKeys.normalize_keys(m2, :atom_existing) == %{collision_existing_atom_b: 1}
    end

    test ":string — string key wins on collision" do
      assert MapKeys.normalize_keys(%{"foo" => 2, :foo => 1}, :string) == %{"foo" => 2}
    end

    test ":deep — atom-first precedence applies recursively" do
      :collision_nested_atom

      input = %{
        outer: %{"collision_nested_atom" => 2, :collision_nested_atom => 1}
      }

      assert MapKeys.normalize_keys(input, :atom_existing, deep: true) ==
               %{outer: %{collision_nested_atom: 1}}
    end
  end

  describe "safe_existing_atom/1" do
    test "returns {:ok, atom} for an existing atom" do
      :existing_atom_for_test

      assert MapKeys.safe_existing_atom("existing_atom_for_test") ==
               {:ok, :existing_atom_for_test}
    end

    test "returns :error for a non-existing atom string" do
      bogus = "no_such_atom_#{System.unique_integer([:positive])}"
      assert MapKeys.safe_existing_atom(bogus) == :error
    end
  end
end
