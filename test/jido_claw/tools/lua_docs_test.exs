defmodule JidoClaw.Tools.LuaDocsTest do
  use ExUnit.Case, async: true

  alias JidoClaw.Tools.Lua.Bindings
  alias JidoClaw.Tools.Lua.Policy
  alias JidoClaw.Tools.LuaDocs

  describe "catalog" do
    test "serves exactly Bindings.docs() — the single-source assertion" do
      assert {:ok, result} = LuaDocs.run(%{}, %{})
      assert result.bindings == Bindings.docs()
    end

    test "echoes the effective policy caps" do
      assert {:ok, result} = LuaDocs.run(%{}, %{})
      assert result.policy == Policy.public(Policy.resolve([]))
      assert result.policy["mode"] == "read_only"
      assert is_integer(result.policy["max_calls"])
      assert is_integer(result.policy["max_result_bytes"])
    end

    test "carries language notes including the print and pcall caveats" do
      assert {:ok, %{language_notes: notes}} = LuaDocs.run(%{}, %{})

      assert notes["print"] =~ "disabled"
      assert notes["errors"] =~ "pcall"
      assert notes["errors"] =~ "NOT swallowable"
    end

    test "is JSON-encodable end to end" do
      assert {:ok, result} = LuaDocs.run(%{}, %{})
      assert {:ok, _} = Jason.encode(result)
    end
  end

  describe "binding drill-down" do
    test "returns the single matching entry" do
      assert {:ok, result} = LuaDocs.run(%{binding: "jido.output"}, %{})

      assert result.binding["name"] == "jido.output"
      assert result.binding == Enum.find(Bindings.docs(), &(&1["name"] == "jido.output"))
      assert result.policy["mode"] == "read_only"
    end

    test "unknown binding fails loudly with the available names" do
      assert {:error, %{code: :unknown_binding, message: message, details: details}} =
               LuaDocs.run(%{binding: "jido.nope"}, %{})

      assert message =~ "jido.runs"
      assert details.retry == false
    end
  end
end
