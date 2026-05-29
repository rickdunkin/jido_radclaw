defmodule JidoClaw.Core.JsonSafeTest do
  use ExUnit.Case, async: true

  alias JidoClaw.Core.JsonSafe

  describe "encode/1 — map keys are all stringified" do
    test "atom keys become strings; binary keys pass through" do
      assert JsonSafe.encode(%{:status => :ok, "already" => 1}) ==
               %{"status" => "ok", "already" => 1}
    end

    test "non-binary, non-atom keys are stringified via inspect and stay JSON-encodable" do
      out = JsonSafe.encode(%{{:tuple, :key} => :value, 7 => "x"})

      assert out["{:tuple, :key}"] == "value"
      assert out["7"] == "x"
      # The contract: the result is always a valid JSON object.
      assert {:ok, _json} = Jason.encode(out)
    end

    test "non-binary keys nested inside the value are also stringified" do
      out = JsonSafe.encode(%{outer: %{[1, 2] => :v}})
      assert {:ok, _json} = Jason.encode(out)
    end
  end

  describe "encode/1 — value normalization (shared-normalizer regression guard)" do
    test "DateTime → ISO-8601, MapSet → list, module dropped, atoms → strings, nil/bool kept" do
      {:ok, dt, _offset} = DateTime.from_iso8601("2026-05-28T00:00:00Z")

      out =
        JsonSafe.encode(%{
          at: dt,
          tags: MapSet.new([:a, :b]),
          mod: JidoClaw.Core.JsonSafe,
          status: :ok,
          keep: true,
          nada: nil
        })

      assert out["at"] == "2026-05-28T00:00:00Z"
      assert Enum.sort(out["tags"]) == ["a", "b"]
      # Module-valued entries are dropped entirely.
      refute Map.has_key?(out, "mod")
      assert out["status"] == "ok"
      assert out["keep"] == true
      assert out["nada"] == nil
      assert {:ok, _json} = Jason.encode(out)
    end

    test "a bare module atom encodes to nil (leaf), not a string" do
      assert JsonSafe.encode(JidoClaw.Core.JsonSafe) == nil
      assert JsonSafe.encode(:plain_atom) == "plain_atom"
    end

    test "pids/refs/functions become nil in lists and at the top level; dropped as map values" do
      assert JsonSafe.encode(self()) == nil
      assert JsonSafe.encode(make_ref()) == nil
      assert JsonSafe.encode(fn -> :x end) == nil

      out = JsonSafe.encode(%{procs: [self(), :keep], ref: make_ref()})

      # In a list → nil element (parallel to a module atom in a list).
      assert out["procs"] == [nil, "keep"]
      # As a direct map value → the entry is dropped entirely.
      refute Map.has_key?(out, "ref")
      assert {:ok, _json} = Jason.encode(out)
    end

    test "tuples (incl. keyword lists) encode as lists" do
      assert JsonSafe.encode({:ok, 1}) == ["ok", 1]
      # A keyword list is a list of 2-tuples.
      assert JsonSafe.encode(timeout: 5, retries: 3) == [["timeout", 5], ["retries", 3]]
    end

    test "arbitrary nested Elixir terms normalize to Jason-encodable JSON (totality)" do
      term = %{
        tuple: {:pid, self()},
        keyword: [ok: self()],
        nested: [%{{:tuple, :key} => {:error, make_ref()}}],
        fun: fn -> :x end
      }

      out = JsonSafe.encode(term)

      assert {:ok, _json} = Jason.encode(out)
      assert out["tuple"] == ["pid", nil]
      assert out["keyword"] == [["ok", nil]]
      refute Map.has_key?(out, "fun")
    end
  end
end
