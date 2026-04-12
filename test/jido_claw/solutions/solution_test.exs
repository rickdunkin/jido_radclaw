defmodule JidoClaw.Solutions.SolutionTest do
  use ExUnit.Case, async: true

  alias JidoClaw.Solutions.Solution

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp valid_attrs do
    %{
      solution_content: "defmodule Foo do\n  def bar, do: :ok\nend",
      language: "elixir"
    }
  end

  # ---------------------------------------------------------------------------
  # new/1
  # ---------------------------------------------------------------------------

  describe "new/1" do
    test "should create a solution with required fields (problem_signature, solution_content, language)" do
      s = Solution.new(valid_attrs())

      assert s.solution_content == "defmodule Foo do\n  def bar, do: :ok\nend"
      assert s.language == "elixir"
      assert is_binary(s.problem_signature) and byte_size(s.problem_signature) == 64
    end

    test "should auto-generate id when not provided" do
      s = Solution.new(valid_attrs())

      assert is_binary(s.id)
      # UUID v4 format: 8-4-4-4-12
      assert s.id =~ ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
    end

    test "should not re-generate id when explicitly provided" do
      explicit_id = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
      s = Solution.new(Map.put(valid_attrs(), :id, explicit_id))

      assert s.id == explicit_id
    end

    test "should auto-generate timestamps when not provided" do
      s = Solution.new(valid_attrs())

      assert is_binary(s.inserted_at)
      assert is_binary(s.updated_at)
      # Sanity-check ISO-8601 shape
      assert s.inserted_at =~ ~r/^\d{4}-\d{2}-\d{2}T/
      assert s.updated_at =~ ~r/^\d{4}-\d{2}-\d{2}T/
    end

    test "should compute problem_signature from solution_content + language when not provided" do
      s = Solution.new(valid_attrs())
      expected = Solution.signature(valid_attrs().solution_content, valid_attrs().language)

      assert s.problem_signature == expected
    end

    test "should use provided problem_signature when given" do
      custom_sig = String.duplicate("a", 64)
      s = Solution.new(Map.put(valid_attrs(), :problem_signature, custom_sig))

      assert s.problem_signature == custom_sig
    end

    test "should default tags to empty list" do
      s = Solution.new(valid_attrs())

      assert s.tags == []
    end

    test "should default verification to empty map" do
      s = Solution.new(valid_attrs())

      assert s.verification == %{}
    end

    test "should default trust_score to 0.0" do
      s = Solution.new(valid_attrs())

      assert s.trust_score == 0.0
    end

    test "should default sharing to :local" do
      s = Solution.new(valid_attrs())

      assert s.sharing == :local
    end

    test "should accept string keys in attrs map" do
      attrs = %{
        "solution_content" => "IO.puts(\"hello\")",
        "language" => "elixir",
        "trust_score" => 0.9,
        "sharing" => "shared"
      }

      s = Solution.new(attrs)

      assert s.solution_content == "IO.puts(\"hello\")"
      assert s.language == "elixir"
      assert s.trust_score == 0.9
      assert s.sharing == :shared
    end

    test "should accept optional framework" do
      s = Solution.new(Map.put(valid_attrs(), :framework, "phoenix"))

      assert s.framework == "phoenix"
    end

    test "should accept optional runtime" do
      s = Solution.new(Map.put(valid_attrs(), :runtime, "otp-26"))

      assert s.runtime == "otp-26"
    end

    test "should accept optional agent_id" do
      s = Solution.new(Map.put(valid_attrs(), :agent_id, "agent-007"))

      assert s.agent_id == "agent-007"
    end
  end

  # ---------------------------------------------------------------------------
  # to_map/1
  # ---------------------------------------------------------------------------

  describe "to_map/1" do
    test "should convert Solution struct to map with string keys" do
      s = Solution.new(valid_attrs())
      m = Solution.to_map(s)

      assert is_map(m)
      assert Map.keys(m) |> Enum.all?(&is_binary/1)
    end

    test "should include all fields" do
      s = Solution.new(valid_attrs())
      m = Solution.to_map(s)

      expected_keys = ~w(
        id problem_signature solution_content language framework runtime
        agent_id tags verification trust_score sharing inserted_at updated_at
      )

      for key <- expected_keys do
        assert Map.has_key?(m, key), "Expected key #{key} to be present in to_map/1 output"
      end
    end

    test "should stringify sharing atom" do
      s = Solution.new(Map.put(valid_attrs(), :sharing, :public))
      m = Solution.to_map(s)

      assert m["sharing"] == "public"
    end

    test "should stringify sharing atom :local" do
      s = Solution.new(valid_attrs())
      m = Solution.to_map(s)

      assert m["sharing"] == "local"
    end

    test "should stringify atom keys inside verification map" do
      s =
        Solution.new(Map.put(valid_attrs(), :verification, %{tests_passed: true, lint: "ok"}))

      m = Solution.to_map(s)

      assert Map.has_key?(m["verification"], "tests_passed")
      assert Map.has_key?(m["verification"], "lint")
    end
  end

  # ---------------------------------------------------------------------------
  # from_map/1
  # ---------------------------------------------------------------------------

  describe "from_map/1" do
    test "should reconstruct Solution from a map with string keys" do
      original = Solution.new(valid_attrs())
      round_tripped = original |> Solution.to_map() |> Solution.from_map()

      assert round_tripped.id == original.id
      assert round_tripped.problem_signature == original.problem_signature
      assert round_tripped.solution_content == original.solution_content
      assert round_tripped.language == original.language
      assert round_tripped.trust_score == original.trust_score
      assert round_tripped.sharing == original.sharing
    end

    test "should handle atom keys" do
      attrs = Map.merge(valid_attrs(), %{trust_score: 0.75, sharing: :shared})
      s = Solution.from_map(attrs)

      assert s.trust_score == 0.75
      assert s.sharing == :shared
    end

    test "should coerce string trust_score to float" do
      m =
        valid_attrs()
        |> Map.put(:trust_score, "0.85")
        |> Map.put(:problem_signature, String.duplicate("b", 64))

      s = Solution.from_map(m)

      assert s.trust_score == 0.85
    end

    test "should coerce integer trust_score to float" do
      m =
        valid_attrs()
        |> Map.put(:trust_score, 1)
        |> Map.put(:problem_signature, String.duplicate("c", 64))

      s = Solution.from_map(m)

      assert s.trust_score == 1.0
      assert is_float(s.trust_score)
    end

    test "should coerce string sharing to atom" do
      m =
        valid_attrs()
        |> Map.put(:sharing, "public")
        |> Map.put(:problem_signature, String.duplicate("d", 64))

      s = Solution.from_map(m)

      assert s.sharing == :public
    end

    test "should handle JSON-encoded verification string" do
      json_verification = Jason.encode!(%{"tests_passed" => true, "lint" => "ok"})

      m =
        valid_attrs()
        |> Map.put(:verification, json_verification)
        |> Map.put(:problem_signature, String.duplicate("e", 64))

      s = Solution.from_map(m)

      assert s.verification == %{"tests_passed" => true, "lint" => "ok"}
    end

    test "should default unknown sharing to :local" do
      m =
        valid_attrs()
        |> Map.put(:sharing, "unknown_value")
        |> Map.put(:problem_signature, String.duplicate("f", 64))

      s = Solution.from_map(m)

      assert s.sharing == :local
    end
  end

  # ---------------------------------------------------------------------------
  # signature/3
  # ---------------------------------------------------------------------------

  describe "signature/3" do
    test "should produce deterministic hash for same inputs" do
      sig1 = Solution.signature("implement a GenServer", "elixir", "otp")
      sig2 = Solution.signature("implement a GenServer", "elixir", "otp")

      assert sig1 == sig2
    end

    test "should produce different hash for different inputs" do
      sig1 = Solution.signature("implement a GenServer", "elixir")
      sig2 = Solution.signature("implement a Supervisor", "elixir")

      refute sig1 == sig2
    end

    test "should be case-insensitive" do
      sig1 = Solution.signature("GenServer", "Elixir")
      sig2 = Solution.signature("genserver", "elixir")

      assert sig1 == sig2
    end

    test "should trim leading/trailing whitespace before hashing" do
      sig1 = Solution.signature("  GenServer  ", "elixir")
      sig2 = Solution.signature("GenServer", "elixir")

      assert sig1 == sig2
    end

    test "should handle nil framework" do
      sig1 = Solution.signature("build a router", "elixir", nil)
      sig2 = Solution.signature("build a router", "elixir")

      assert sig1 == sig2
    end

    test "should differ when framework differs" do
      sig1 = Solution.signature("build a router", "elixir", "phoenix")
      sig2 = Solution.signature("build a router", "elixir", "plug")

      refute sig1 == sig2
    end

    test "should produce a 64-character lowercase hex string" do
      sig = Solution.signature("any description", "python")

      assert byte_size(sig) == 64
      assert sig =~ ~r/^[0-9a-f]+$/
    end
  end
end
