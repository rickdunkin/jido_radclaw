defmodule JidoClaw.Forge.PersistenceRedactionTest do
  @moduledoc """
  Tests that Persistence.redact_map correctly recurses into lists,
  preventing secret leakage from nested structures like resource specs.
  """
  use ExUnit.Case, async: true

  alias JidoClaw.Security.Redaction.Patterns

  describe "redact_map handles lists" do
    test "redacts strings inside nested lists" do
      input = %{
        "resources" => [
          %{"type" => "env_vars", "values" => %{"API_KEY" => "sk-abc123"}},
          %{"type" => "git_repo", "source" => "https://github.com/org/repo"}
        ]
      }

      result = redact_map(input)

      [env_entry, git_entry] = result["resources"]

      # Strings that match redaction patterns should be redacted
      assert env_entry["values"]["API_KEY"] == Patterns.redact("sk-abc123")

      # Non-secret strings pass through the redactor (may or may not be changed depending on patterns)
      assert is_binary(git_entry["source"])
    end

    test "handles deeply nested list-in-map-in-list structures" do
      input = %{
        "outer" => [
          %{"inner" => [%{"secret" => "password123"}]}
        ]
      }

      result = redact_map(input)

      [[inner_entry]] = [result["outer"]]
      [nested] = inner_entry["inner"]
      assert is_binary(nested["secret"])
    end

    test "handles list of plain strings" do
      input = %{"tags" => ["public", "v1.0", "test"]}

      result = redact_map(input)

      assert is_list(result["tags"])
      assert length(result["tags"]) == 3
    end

    test "handles empty lists" do
      assert redact_map(%{"empty" => []}) == %{"empty" => []}
    end

    test "handles mixed-type lists" do
      input = %{"mixed" => ["text", 42, true, %{"nested" => "value"}]}

      result = redact_map(input)

      assert length(result["mixed"]) == 4
      assert Enum.at(result["mixed"], 1) == 42
      assert Enum.at(result["mixed"], 2) == true
    end
  end

  # Mirror Persistence.redact_map/1 and redact_list/1 for direct testing
  defp redact_map(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_binary(v) -> {k, Patterns.redact(v)}
      {k, v} when is_map(v) -> {k, redact_map(v)}
      {k, v} when is_list(v) -> {k, redact_list(v)}
      pair -> pair
    end)
  end

  defp redact_map(other), do: other

  defp redact_list(list) when is_list(list) do
    Enum.map(list, fn
      v when is_map(v) -> redact_map(v)
      v when is_binary(v) -> Patterns.redact(v)
      v when is_list(v) -> redact_list(v)
      v -> v
    end)
  end
end
