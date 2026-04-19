defmodule JidoClaw.Reasoning.AutoSelect do
  @moduledoc """
  History- and heuristic-aware strategy selector.

  The single entry point behind `reason(strategy: "auto")`. Profiles the
  prompt via `Classifier`, folds in aggregated outcomes from `Statistics`,
  and falls back to a short LLM tie-breaker when the top two heuristic
  candidates score within `@tiebreak_threshold` of each other.

  ## Windowed history (either/or, no merging)

  First queries `Statistics.best_strategies_for/2` over the recent window
  (`@recent_window_days` days, `:strategy_run` only). If the window has
  at least `@min_history_samples` total samples across returned rows, that
  window is used. Otherwise the window is **discarded** and the query is
  re-run with `since: nil` for all-time. Merging per-strategy aggregates
  double-counts and produces fuzzy semantics; either/or keeps the
  recent-vs-historical choice clean.

  ## react and adaptive are excluded from auto candidates

  Exclusion is **base-level**: `AutoSelect` passes
  `exclude_bases: [:react, :adaptive]` to `Classifier.recommend/2`, which
  drops any candidate whose resolved base is react or adaptive — including
  user aliases that point at those bases via `.jido/strategies/*.yaml`.

    * `react` writes `:react_stub` rows which history queries ignore, and
      the react branch of `Reason` is a structured-prompt stub rather than
      a real runner result — useless as an auto pick. A `react`-based alias
      also crashes `Jido.AI.Actions.Reasoning.RunStrategy` because `:react`
      isn't a valid `RunStrategy` enum value.
    * `adaptive` runs its own inner selection; an adaptive-based alias
      would silently reintroduce the nested selector that v0.4.3 removed.

  Direct `/classify` and other classifier callers keep react in the pool.

  ## Diagnostics

  Returned as the 5th tuple element and persisted into
  `reasoning_outcomes.metadata` via `Telemetry.with_outcome/4`:

      %{
        heuristic_rank: 1,
        history_samples: 12,
        history_window: :recent | :all_time | :empty,
        tie_broken_by_llm?: false,
        alternatives: [{"tot", 0.71}, ...],
        selection_mode: "auto"
      }

  ## Test hooks

  * `skip_history: true` — forces empty history (no DB query).
  * `llm_tiebreak: false` — disables the tie-breaker entirely; the top
    heuristic always wins even on a tie.
  * `history: [...]` — supply pre-computed rows instead of querying
    `Statistics`.
  * `tiebreak_module: mod` — swap the tie-breaker (used by tests to stub
    LLM calls deterministically).
  """

  alias JidoClaw.Reasoning.{Classifier, LLMTiebreaker, Statistics, TaskProfile}

  @tiebreak_threshold 0.05
  @recent_window_days 30
  @min_history_samples 5
  @default_exclude_bases [:react, :adaptive]

  @type diagnostics :: %{
          heuristic_rank: non_neg_integer(),
          history_samples: non_neg_integer(),
          history_window: :recent | :all_time | :empty,
          tie_broken_by_llm?: boolean(),
          alternatives: [{String.t(), float()}],
          selection_mode: String.t()
        }

  @doc """
  Profile, rank, and pick a concrete strategy for `prompt`.

  Returns `{:ok, strategy, confidence, profile, diagnostics}`. Never picks
  `"auto"` or `"adaptive"` — the return is always a dispatchable concrete
  strategy (`"cot"`, `"tot"`, …) that `Reason.run_strategy/3` knows how
  to execute.
  """
  @spec select(String.t(), keyword()) ::
          {:ok, String.t(), float(), TaskProfile.t(), diagnostics()}
  def select(prompt, opts \\ []) when is_binary(prompt) do
    profile = Classifier.profile(prompt, opts)

    {history, window} = load_history(profile.task_type, opts)

    {:ok, ranked} =
      Classifier.recommend(profile,
        history: history,
        exclude_bases: @default_exclude_bases,
        return: :ranked
      )

    {chosen, confidence, tie_broken?, rank, alternatives} =
      pick_from_ranked(ranked, prompt, opts)

    diagnostics = %{
      heuristic_rank: rank,
      history_samples: total_samples(history),
      history_window: window,
      tie_broken_by_llm?: tie_broken?,
      alternatives: alternatives,
      selection_mode: "auto"
    }

    {:ok, chosen, confidence, profile, diagnostics}
  end

  # ---------------------------------------------------------------------------
  # History loading (either/or, no merging)
  # ---------------------------------------------------------------------------

  defp load_history(task_type, opts) do
    cond do
      Keyword.get(opts, :skip_history) == true ->
        {[], :empty}

      Keyword.has_key?(opts, :history) ->
        rows = Keyword.get(opts, :history, [])
        {rows, window_label_for(rows)}

      true ->
        since = DateTime.add(DateTime.utc_now(), -@recent_window_days * 86_400, :second)

        recent = safe_query(task_type, since: since)

        cond do
          total_samples(recent) >= @min_history_samples ->
            {recent, :recent}

          true ->
            all_time = safe_query(task_type, since: nil)
            {all_time, window_label_for(all_time)}
        end
    end
  end

  defp window_label_for([]), do: :empty
  defp window_label_for(_rows), do: :all_time

  defp safe_query(task_type, query_opts) do
    Statistics.best_strategies_for(
      task_type,
      Keyword.merge([execution_kind: :strategy_run], query_opts)
    )
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp total_samples(rows) when is_list(rows) do
    Enum.reduce(rows, 0, fn row, acc ->
      case row do
        %{samples: s} when is_integer(s) -> acc + s
        _ -> acc
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Picking from ranked candidates
  # ---------------------------------------------------------------------------

  defp pick_from_ranked([{name, score} | _rest] = ranked, prompt, opts) do
    alternatives = Enum.map(ranked, fn {n, s} -> {n, s} end)

    case tie_candidates(ranked) do
      [_, _ | _] = tied when length(tied) >= 2 ->
        if Keyword.get(opts, :llm_tiebreak, true) do
          attempt_tiebreak(tied, ranked, prompt, opts, alternatives)
        else
          {name, min(1.0, score), false, 1, alternatives}
        end

      _ ->
        {name, min(1.0, score), false, 1, alternatives}
    end
  end

  defp pick_from_ranked([], _prompt, _opts) do
    # Defensive: Classifier.recommend/2 always returns at least the full
    # registry under :ranked mode, but if someone swaps in an exotic fixture
    # we still need a dispatchable fallback.
    {"cot", 0.25, false, 1, []}
  end

  defp tie_candidates([{_, top_score} | _] = ranked) do
    ranked
    |> Enum.take_while(fn {_, score} -> abs(top_score - score) < @tiebreak_threshold end)
    # Cap LLM prompt size; tiebreaker prompt has no value beyond 3 candidates.
    |> Enum.take(3)
  end

  defp attempt_tiebreak(tied, ranked, prompt, opts, alternatives) do
    tiebreak_mod = Keyword.get(opts, :tiebreak_module, LLMTiebreaker)
    names = Enum.map(tied, fn {name, _} -> name end)

    case tiebreak_mod.choose(prompt, names, opts) do
      {:ok, chosen} ->
        score = score_for(ranked, chosen)
        rank = rank_for(ranked, chosen)
        {chosen, min(1.0, score), true, rank, alternatives}

      _ ->
        # Fall back to heuristic top pick on any tie-break failure.
        [{top_name, top_score} | _] = ranked
        {top_name, min(1.0, top_score), false, 1, alternatives}
    end
  end

  defp score_for(ranked, name) do
    case Enum.find(ranked, fn {n, _} -> n == name end) do
      {_, s} -> s
      nil -> 0.0
    end
  end

  defp rank_for(ranked, name) do
    ranked
    |> Enum.find_index(fn {n, _} -> n == name end)
    |> case do
      nil -> 1
      idx -> idx + 1
    end
  end
end
