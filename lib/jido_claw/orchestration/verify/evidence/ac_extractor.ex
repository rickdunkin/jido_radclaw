defmodule JidoClaw.Orchestration.Verify.Evidence.ACExtractor do
  @moduledoc """
  Slice 2 of the evidence floor (OB1-3): convert the run's acceptance
  criteria into machine-checkable spec assertions — one tool-less
  `Jido.AI.generate_object/3` call at composer launch, never in the per-wave
  fold. Port of ouroboros's `AssertionExtractor` — semantics map
  `docs/exploration/ouroboros/PORT-OB1-3.md` (`Q00/ouroboros @ e905a41c`,
  MIT, © 2025 Q00); their per-seed LRU cache becomes our durable parent
  config (`parent_config` persists the result, `config_then_opts` restores
  it — restart-safe, LLM out of the fold).

  Input is `Premises.criteria_with_ids/1`'s stable `{"AC1", text}` pairs
  (orca OQ-2 — ids are never reconstructed positionally). Output is a list
  of string-keyed, JSON-safe assertion maps:

      %{"ac_id" => "AC1", "assertion" => …, "tier" => "T1_CONSTANT",
        "file_hint" => …, "pattern" => …}

  (`file_hint`/`pattern` keys absent when the extractor gave none). The
  source's `expected_value` field is deliberately dropped — the prompt folds
  the expected value INTO the pattern (`WARMUP\\s*=\\s*10`), so a wrong value
  reads as pattern-absent ⇒ the same `:contradicted` outcome by a simpler
  route (PORT map, schema row).

  Fail-open end to end (the `Clarify.Scorer` posture): a provider error,
  malformed object, raise, or throw is `{:error, reason}` — the caller
  Traces it and runs without slice 2. Every conservative branch downstream
  returns verified=true, so a cheap model (default `:fast`) can only lose
  recall, never manufacture a false finding. Unknown tiers normalize to
  `T4_UNVERIFIABLE` (skipped — the extractor.py:160-162 parse rule);
  assertions citing an unknown `ac_id` are dropped (an assertion not
  traceable to a real AC must never manufacture a finding).
  """

  require Logger

  alias JidoClaw.Error

  @max_tokens 4_096
  @timeout_ms 30_000
  # Bounded fan-out: the verifier scans per assertion, so a runaway
  # extraction (the schema allows 0..n per AC) is capped here.
  @max_assertions 50

  @tiers %{
    "T1_CONSTANT" => "T1_CONSTANT",
    "T2_STRUCTURAL" => "T2_STRUCTURAL",
    "T3_BEHAVIORAL" => "T3_BEHAVIORAL",
    "T4_UNVERIFIABLE" => "T4_UNVERIFIABLE"
  }

  # The tier taxonomy and rules paragraph port the source system prompt
  # (extractor.py:30-60), reshaped for AC ids, the folded expected value,
  # and the 200-char pattern bound the verifier enforces.
  @system """
  You are a spec verification assistant. Given acceptance criteria for a
  software project, extract machine-verifiable assertions.

  For each AC, classify what it needs into a verification tier:
  - T1_CONSTANT: specific values, numbers, or config settings findable via
    regex in source code. Examples: "WARMUP_FRAMES=10", "timeout of 30
    seconds", "maximum 5 retries".
  - T2_STRUCTURAL: specific files, modules, classes, interfaces, or
    functions must exist. Examples: "CameraProvider interface", "tests
    directory", "CLI accepts --verbose flag".
  - T3_BEHAVIORAL: requires running code or tests to verify. Examples:
    "3 calls return median score", "handles errors gracefully".
  - T4_UNVERIFIABLE: subjective or requires human judgment. Examples:
    "UX feels natural", "code is clean".

  Rules:
  - "ac_id": the id of the acceptance criterion the assertion came from,
    exactly as given (e.g. "AC1"). Never invent ids.
  - "assertion": one crisp sentence stating what must hold.
  - "pattern": a regex to search for in source files, under 200 characters.
    Fold any expected value INTO the pattern (e.g. `WARMUP\\s*=\\s*10`, not a
    separate value). For T2, the file, module, or function name pattern.
    Omit for T3/T4.
  - "file_hint": a glob for the files to search (e.g. "*.ex",
    "lib/**/*.ex", "config/*.exs"). Omit if unknown — assertions without a
    hint are skipped rather than scanning the whole tree.
  - One AC may produce 0-3 assertions (an AC with several checkable values
    produces one assertion per value).
  - For T3/T4, still include the entry (they are recorded as skipped) but
    omit pattern and file_hint.
  - Be conservative: if unsure, classify as T3_BEHAVIORAL rather than
    T1/T2 — a wrong T1 pattern manufactures a false contradiction.

  Return ONLY the structured object.
  """

  @doc """
  Extract assertions from the run's `{"AC1", text}` criterion pairs.

  Returns `{:ok, assertions}` (possibly `[]` — no LLM call when the pairs
  are empty) or `{:error, reason}`. Never raises.
  """
  @spec extract([{String.t(), String.t()}]) :: {:ok, [map()]} | {:error, term()}
  def extract(pairs) when is_list(pairs) do
    case Enum.filter(pairs, &valid_pair?/1) do
      [] -> {:ok, []}
      valid -> generate(valid)
    end
  end

  def extract(_pairs), do: {:error, :invalid_criteria}

  defp generate(pairs) do
    known_ids = MapSet.new(pairs, fn {ac_id, _text} -> ac_id end)

    with {:ok, resp} <-
           gen().(input(pairs), zoi(),
             model: resolve_model(),
             system_prompt: @system,
             max_tokens: @max_tokens,
             temperature: 0.0,
             timeout: @timeout_ms
           ),
         {:ok, object} <- ReqLLM.Response.unwrap_object(resp, json_repair: true) do
      {:ok, normalize(object, known_ids)}
    else
      {:error, reason} = err ->
        Logger.debug("[ACExtractor] extract failed: #{Error.summarize_reason(reason)}")
        err

      other ->
        {:error, {:unexpected, other}}
    end
  rescue
    # Fail-open (the Clarify.Scorer posture): extraction can only lose
    # recall, never block a launch.
    # reach:disable-next-line bare_rescue
    e ->
      Logger.debug("[ACExtractor] extract raised: #{Exception.message(e)}")
      {:error, :extractor_failed}
  catch
    kind, payload ->
      Logger.debug("[ACExtractor] extract #{kind}: #{inspect(payload)}")
      {:error, :extractor_failed}
  end

  @doc "The structured-output contract (Zoi MAP form — the precommit-safe shape)."
  @spec zoi() :: Zoi.schema()
  def zoi do
    Zoi.object(%{
      "assertions" =>
        Zoi.array(
          Zoi.object(%{
            "ac_id" => Zoi.string(),
            "assertion" => Zoi.string(),
            "tier" =>
              Zoi.enum(
                t1_constant: "T1_CONSTANT",
                t2_structural: "T2_STRUCTURAL",
                t3_behavioral: "T3_BEHAVIORAL",
                t4_unverifiable: "T4_UNVERIFIABLE"
              ),
            "file_hint" => Zoi.optional(Zoi.string()),
            "pattern" => Zoi.optional(Zoi.string())
          })
        )
    })
  end

  # Seam so tests inject a canned/failing generate_object (the
  # `:clarify_generate` idiom).
  defp gen do
    Application.get_env(:jido_claw, :ac_extract_generate, &Jido.AI.generate_object/3)
  end

  # `:fast` (vs clarify's `:capable`): extraction quality affects recall
  # only — every conservative branch downstream returns verified=true, so a
  # cheap model can never manufacture a false finding.
  defp resolve_model do
    Application.get_env(:jido_claw, :ac_extract_model, :fast)
  end

  defp valid_pair?({ac_id, text}), do: is_binary(ac_id) and is_binary(text)
  defp valid_pair?(_other), do: false

  defp input(pairs) do
    criteria =
      Enum.map_join(pairs, "\n", fn {ac_id, text} -> "#{ac_id}: #{text}" end)

    content = "Extract verifiable assertions from these acceptance criteria:\n\n" <> criteria

    [%{role: :user, content: content}]
  end

  # ---------------------------------------------------------------------------
  # Output normalization — string-keyed, JSON-safe, bounded
  # ---------------------------------------------------------------------------

  # The validated object is string-keyed (Zoi enum atoms are VALUES, not
  # keys — the Scorer precedent).
  defp normalize(object, known_ids) when is_map(object) do
    object
    |> Map.get("assertions")
    |> normalize_assertions(known_ids)
  end

  defp normalize(_object, _known_ids), do: []

  defp normalize_assertions(assertions, known_ids) when is_list(assertions) do
    assertions
    |> Enum.map(&normalize_assertion(&1, known_ids))
    |> Enum.reject(&is_nil/1)
    |> Enum.take(@max_assertions)
  end

  defp normalize_assertions(_assertions, _known_ids), do: []

  defp normalize_assertion(%{} = raw, known_ids) do
    ac_id = trimmed(Map.get(raw, "ac_id"))
    assertion = trimmed(Map.get(raw, "assertion"))

    if is_binary(ac_id) and is_binary(assertion) and MapSet.member?(known_ids, ac_id) do
      %{"ac_id" => ac_id, "assertion" => assertion, "tier" => tier(Map.get(raw, "tier"))}
      |> put_optional("file_hint", trimmed(Map.get(raw, "file_hint")))
      |> put_optional("pattern", trimmed(Map.get(raw, "pattern")))
    end
  end

  defp normalize_assertion(_raw, _known_ids), do: nil

  # Zoi enum validation yields the keyword atoms; json_repair'd raw objects
  # (and seam stubs) may carry strings. Unknown ⇒ T4 (skipped) — the
  # extractor.py:160-162 parse rule.
  defp tier(value) when is_atom(value) and not is_nil(value),
    do: tier(String.upcase(Atom.to_string(value)))

  defp tier(value) when is_binary(value),
    do: Map.get(@tiers, String.upcase(value), "T4_UNVERIFIABLE")

  defp tier(_value), do: "T4_UNVERIFIABLE"

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)

  defp trimmed(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp trimmed(_value), do: nil
end
