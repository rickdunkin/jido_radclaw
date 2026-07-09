defmodule JidoClaw.Orchestration.Verify.Evidence.ACExtractorTest do
  @moduledoc """
  The AC-assertion extractor's LLM boundary via a canned
  `:ac_extract_generate` seam (the `Clarify.ScorerTest` idiom): happy
  normalization, the fail-open branches (PORT-OB1-3 rows — garbled output ⇒
  no assertions, unknown tier ⇒ T4, seam failure ⇒ error), and knob
  forwarding. No real LLM.

  Non-async: mutates `:ac_extract_generate` / `:ac_extract_model` app env.
  """
  use ExUnit.Case, async: false

  alias JidoClaw.Orchestration.Verify.Evidence.ACExtractor

  setup do
    on_exit(fn ->
      Application.delete_env(:jido_claw, :ac_extract_generate)
      Application.delete_env(:jido_claw, :ac_extract_model)
    end)

    :ok
  end

  defp resp(object) do
    %ReqLLM.Response{id: "test", model: "test", context: nil, object: object}
  end

  defp stub(fun), do: Application.put_env(:jido_claw, :ac_extract_generate, fun)

  defp pairs do
    [{"AC1", "warmup frames default to 10"}, {"AC2", "a CameraProvider module exists"}]
  end

  defp object do
    %{
      "assertions" => [
        %{
          "ac_id" => "AC1",
          "assertion" => "WARMUP defaults to 10",
          "tier" => "T1_CONSTANT",
          "file_hint" => "lib/**/*.ex",
          "pattern" => "WARMUP\\s*=\\s*10"
        },
        %{
          "ac_id" => "AC2",
          "assertion" => "CameraProvider module exists",
          "tier" => "T2_STRUCTURAL",
          "pattern" => "defmodule\\s+CameraProvider"
        }
      ]
    }
  end

  test "happy path: normalizes to string-keyed JSON-safe assertion maps" do
    stub(fn _input, _schema, _opts -> {:ok, resp(object())} end)

    assert {:ok, [first, second]} = ACExtractor.extract(pairs())

    assert first == %{
             "ac_id" => "AC1",
             "assertion" => "WARMUP defaults to 10",
             "tier" => "T1_CONSTANT",
             "file_hint" => "lib/**/*.ex",
             "pattern" => "WARMUP\\s*=\\s*10"
           }

    # Absent optional keys stay ABSENT (JSONB round-trip stability).
    assert second["ac_id"] == "AC2"
    refute Map.has_key?(second, "file_hint")
  end

  test "empty criteria: {:ok, []} without touching the seam" do
    stub(fn _input, _schema, _opts -> raise "must not be called" end)

    assert {:ok, []} = ACExtractor.extract([])
    assert {:ok, []} = ACExtractor.extract([{nil, "junk"}, {"AC1", 42}])
  end

  test "tier tolerance: Zoi enum atoms and lowercase strings normalize; unknown ⇒ T4" do
    for {wire, expected} <- [
          {:t1_constant, "T1_CONSTANT"},
          {"t2_structural", "T2_STRUCTURAL"},
          {"T3_BEHAVIORAL", "T3_BEHAVIORAL"},
          {"garbage", "T4_UNVERIFIABLE"},
          {nil, "T4_UNVERIFIABLE"}
        ] do
      assertions = [%{"ac_id" => "AC1", "assertion" => "a", "tier" => wire}]
      stub(fn _input, _schema, _opts -> {:ok, resp(%{"assertions" => assertions})} end)

      assert {:ok, [%{"tier" => ^expected}]} = ACExtractor.extract(pairs())
    end
  end

  test "assertions citing an unknown or invented ac_id are dropped" do
    assertions = [
      %{"ac_id" => "AC9", "assertion" => "invented", "tier" => "T1_CONSTANT"},
      %{"ac_id" => "AC1", "assertion" => "real", "tier" => "T1_CONSTANT"}
    ]

    stub(fn _input, _schema, _opts -> {:ok, resp(%{"assertions" => assertions})} end)

    assert {:ok, [%{"ac_id" => "AC1"}]} = ACExtractor.extract(pairs())
  end

  test "malformed entries and a malformed object normalize to no assertions" do
    stub(fn _input, _schema, _opts -> {:ok, resp(%{"assertions" => "junk"})} end)
    assert {:ok, []} = ACExtractor.extract(pairs())

    stub(fn _input, _schema, _opts ->
      {:ok, resp(%{"assertions" => ["junk", %{"ac_id" => "AC1"}, %{"assertion" => "orphan"}]})}
    end)

    assert {:ok, []} = ACExtractor.extract(pairs())
  end

  test "blank strings trim to absent; blank ac_id/assertion drop the entry" do
    assertions = [
      %{
        "ac_id" => "AC1",
        "assertion" => "a",
        "tier" => "T1_CONSTANT",
        "pattern" => "  ",
        "file_hint" => ""
      },
      %{"ac_id" => "  ", "assertion" => "b", "tier" => "T1_CONSTANT"}
    ]

    stub(fn _input, _schema, _opts -> {:ok, resp(%{"assertions" => assertions})} end)

    assert {:ok, [only]} = ACExtractor.extract(pairs())
    assert only["ac_id"] == "AC1"
    refute Map.has_key?(only, "pattern")
    refute Map.has_key?(only, "file_hint")
  end

  test "seam failure, raise, and throw all land {:error, _} — never a raise out" do
    stub(fn _input, _schema, _opts -> {:error, :provider_down} end)
    assert {:error, :provider_down} = ACExtractor.extract(pairs())

    stub(fn _input, _schema, _opts -> raise "boom" end)
    assert {:error, :extractor_failed} = ACExtractor.extract(pairs())

    stub(fn _input, _schema, _opts -> throw(:tantrum) end)
    assert {:error, :extractor_failed} = ACExtractor.extract(pairs())
  end

  test "forwards the AC ids verbatim, the model knob, and temperature 0" do
    parent = self()

    stub(fn input, _schema, opts ->
      send(parent, {:gen, input, opts})
      {:ok, resp(%{"assertions" => []})}
    end)

    Application.put_env(:jido_claw, :ac_extract_model, :capable)

    assert {:ok, []} = ACExtractor.extract(pairs())

    assert_received {:gen, [%{role: :user, content: content}], opts}
    assert content =~ "AC1: warmup frames default to 10"
    assert content =~ "AC2: a CameraProvider module exists"
    assert opts[:model] == :capable
    assert opts[:temperature] == 0.0
    assert is_binary(opts[:system_prompt])
  end

  test "the assertion fan-out is capped at 50" do
    many =
      for n <- 1..80 do
        %{"ac_id" => "AC1", "assertion" => "assertion #{n}", "tier" => "T1_CONSTANT"}
      end

    stub(fn _input, _schema, _opts -> {:ok, resp(%{"assertions" => many})} end)

    assert {:ok, assertions} = ACExtractor.extract(pairs())
    assert Enum.count(assertions) == 50
  end
end
