defmodule JidoClaw.FrontDoor.Clarify.Score do
  @moduledoc """
  Pure ambiguity-scoring semantics for the clarify loop (queue item 8, OB1-1).

  Constants and formulas are ported **verbatim** from Q00/ouroboros @ e905a41c
  (MIT, © 2025 Q00): weights/floors/threshold/streak/temperature from
  `src/ouroboros/bigbang/ambiguity.py:35-57`, the overall-score formula from
  `:697-713`, and the deterministic anti-gaming floor from
  `src/ouroboros/auto/grading.py:523-547`. Semantics map (divergences included):
  `docs/exploration/ouroboros/PORT-OB1-1.md`.

  Dimensions are the **brownfield** 4-set, always (operator decision: this
  platform always operates on an existing repo + conversation evidence). The
  greenfield 3-dim weights are ported for fidelity but deliberately unused —
  exposed via `greenfield_weights/0` so a future greenfield mode starts from
  the verbatim constants.
  """

  alias JidoClaw.FrontDoor.Clarify.Ledger

  # ouroboros ambiguity.py:35-37 — pass threshold (inclusive) + 2-round streak.
  @ambiguity_threshold 0.2
  @streak_required 2
  # ambiguity.py:56-57 — reproducible scoring.
  @scoring_temperature 0.1

  # Brownfield weights (ambiguity.py:50-54) and per-dimension clarity floors
  # (ambiguity.py:39-43). Keys are the wire dimension names the scorer schema
  # uses; values must sum to 1.0.
  @weights %{
    "goal" => 0.35,
    "constraints" => 0.25,
    "success_criteria" => 0.25,
    "context" => 0.15
  }

  @floors %{
    "goal" => 0.75,
    "constraints" => 0.65,
    "success_criteria" => 0.70,
    "context" => 0.60
  }

  # Greenfield weights (ambiguity.py:45-48) — documented-but-unused, see
  # the moduledoc.
  @greenfield_weights %{"goal" => 0.40, "constraints" => 0.30, "success_criteria" => 0.30}

  @dimensions Enum.sort(Map.keys(@weights))

  @doc "The four brownfield dimension keys (wire strings, sorted)."
  @spec dimensions() :: [String.t()]
  def dimensions, do: @dimensions

  @doc "The pass-gate ambiguity threshold (inclusive) — ouroboros's 0.2."
  @spec threshold() :: float()
  def threshold, do: @ambiguity_threshold

  @doc "Consecutive qualifying rounds required before compose — ouroboros's 2."
  @spec streak_required() :: pos_integer()
  def streak_required, do: @streak_required

  @doc "The reproducible scoring temperature — ouroboros's 0.1."
  @spec temperature() :: float()
  def temperature, do: @scoring_temperature

  @doc "The brownfield dimension weights (always used — operator decision 3)."
  @spec weights() :: %{String.t() => float()}
  def weights, do: @weights

  @doc "The per-dimension clarity floors."
  @spec floors() :: %{String.t() => float()}
  def floors, do: @floors

  @doc "The ported-but-unused greenfield 3-dim weights (fidelity record only)."
  @spec greenfield_weights() :: %{String.t() => float()}
  def greenfield_weights, do: @greenfield_weights

  @doc """
  Coerce a scorer clarity map into the canonical 4-key shape: every dimension
  present, numbers clamped to `[0, 1]`, missing/non-numeric dimensions coerced
  to `0.0` (an unscored dimension reads as unclear, so it fails its floor —
  the same posture as ouroboros's "Goal Clarity missing" floor failure).
  """
  @spec normalize_clarity(term()) :: %{String.t() => float()}
  def normalize_clarity(map) when is_map(map) do
    Map.new(@dimensions, fn dim -> {dim, clamp01(Map.get(map, dim))} end)
  end

  def normalize_clarity(_other), do: Map.new(@dimensions, &{&1, 0.0})

  @doc """
  `ambiguity = 1 − Σ(clarity_i × weight_i)`, rounded to 4 places — the verbatim
  ouroboros formula (`ambiguity.py:697-713`) over the brownfield weights.
  """
  @spec ambiguity(%{String.t() => number()}) :: float()
  def ambiguity(clarity) when is_map(clarity) do
    weighted =
      Enum.reduce(@weights, 0.0, fn {dim, weight}, acc ->
        acc + clamp01(Map.get(clarity, dim)) * weight
      end)

    Float.round(1.0 - weighted, 4)
  end

  @doc """
  The deterministic anti-gaming floor (`grading.py:523-547`):
  `0.05·open + 0.10·conflicting + 0.05·(assumed/total)`, clamped `[0, 1]` —
  counted over our ledger item statuses (divergence (b) in the PORT map).
  A code-computable lower bound the LLM cannot score under.
  """
  @spec deterministic_floor(%{
          open: non_neg_integer(),
          conflicting: non_neg_integer(),
          assumed: non_neg_integer(),
          total: non_neg_integer()
        }) :: float()
  def deterministic_floor(%{open: open, conflicting: conflicting, assumed: assumed, total: total}) do
    ratio = if total > 0, do: assumed / total, else: 0.0
    clamp01(0.05 * open + 0.10 * conflicting + 0.05 * ratio)
  end

  @doc "`max(llm_score, deterministic_floor)` — the LLM cannot under-report."
  @spec effective_ambiguity(number(), float()) :: float()
  def effective_ambiguity(llm_score, floor), do: max(clamp01(llm_score), floor)

  @doc """
  The pass gate: effective ambiguity ≤ #{@ambiguity_threshold} (inclusive) AND
  every dimension's clarity ≥ its floor (inclusive) — one strong dimension
  cannot mask a weak one (`qualifies_for_seed_completion`,
  `ambiguity.py:216-248`).
  """
  @spec qualifies?(float(), %{String.t() => number()}) :: boolean()
  def qualifies?(effective_ambiguity, clarity) when is_map(clarity) do
    effective_ambiguity <= @ambiguity_threshold and
      Enum.all?(@floors, fn {dim, floor} -> clamp01(Map.get(clarity, dim)) >= floor end)
  end

  @doc """
  The orca OR2-5 readiness verdict over the ledger (wire strings — this value
  rides premises): any unresolved `user_input_required` item ⇒
  `"blocked_needs_user_input"`; any other unresolved or assumed item ⇒
  `"ready_with_assumptions"`; else `"ready_for_tasks"`.
  """
  @spec readiness([Ledger.item()]) :: String.t()
  def readiness(ledger) when is_list(ledger) do
    counts = Ledger.counts(ledger)

    cond do
      Ledger.open_required?(ledger) -> "blocked_needs_user_input"
      counts.open + counts.conflicting + counts.assumed > 0 -> "ready_with_assumptions"
      true -> "ready_for_tasks"
    end
  end

  defp clamp01(n) when is_number(n) do
    float = n * 1.0
    min(max(float, 0.0), 1.0)
  end

  defp clamp01(_other), do: 0.0
end
