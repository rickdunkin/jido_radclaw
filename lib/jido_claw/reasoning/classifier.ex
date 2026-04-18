defmodule JidoClaw.Reasoning.Classifier do
  @moduledoc """
  Pure heuristic classifier for reasoning prompts.

  Produces a `TaskProfile` via keyword bucketing + structural signals, and
  recommends a strategy based on the registry's `prefers` metadata. The
  classifier is intentionally deterministic and has no side effects — signal
  emission happens at call sites (e.g., the `/classify` handler) so this
  module stays safe to call from hot paths.

  `opts[:history]` is accepted but unused in 0.4.1; 0.4.3 will feed aggregated
  `Statistics` data into the recommendation.
  """

  alias JidoClaw.Reasoning.{StrategyRegistry, TaskProfile}
  alias JidoClaw.Solutions.Fingerprint

  # Keyword buckets — hits are counted per bucket and fed into task_type voting.
  @task_keywords %{
    planning:
      ~w(plan planning design architect architecture decide decision choose approach strategy propose roadmap),
    debugging:
      ~w(bug fix debug broken crash error exception fail failing failure panic stacktrace traceback regression),
    refactoring:
      ~w(refactor rename extract rewrite restructure cleanup consolidate deduplicate simplify inline),
    exploration:
      ~w(explore investigate understand how why what inspect look survey trace grep find locate),
    verification: ~w(verify prove check validate correctness invariant certify audit guarantee),
    qa: ~w(what is explain define meaning documentation doc summarize summary describe)
  }

  @error_signal_terms ~w(
    traceback stacktrace panic segfault nullpointerexception undefinedfunction
    noroutefound argumenterror keyerror valueerror typeerror
  )

  @constraint_markers ~w(must should cannot mustn't don't do not only without ensure require)

  @code_fence ~r/```/
  @numbered_list ~r/^\s*(\d+|[-*])[\.\)]\s+/m
  @multi_file_hint ~r/(multiple files|across files|several modules|in \d+ files|three files|four files|five files)/i
  @path_pattern ~r/[\w\-_\/\.]+\.(ex|exs|erl|py|js|ts|rs|go|java|rb|c|cc|cpp|h|hs|md)\b/i

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Build a `TaskProfile` from a raw prompt.
  """
  @spec profile(String.t(), keyword()) :: TaskProfile.t()
  def profile(prompt, _opts \\ []) when is_binary(prompt) do
    lower = String.downcase(prompt)
    words = String.split(prompt, ~r/\s+/, trim: true)
    word_count = length(words)

    buckets = keyword_buckets(lower)
    error_signal = Enum.any?(@error_signal_terms, &String.contains?(lower, &1))
    has_code_block = Regex.match?(@code_fence, prompt)
    constraint_count = count_constraints(lower)
    has_enumeration = enumerated?(prompt)
    multiple_files = mentions_multiple_files?(prompt)

    %TaskProfile{
      prompt_length: byte_size(prompt),
      word_count: word_count,
      domain: Fingerprint.extract_domain(prompt),
      target: Fingerprint.extract_target(prompt),
      task_type: pick_task_type(buckets, error_signal),
      complexity:
        bucket_complexity(
          score_complexity(
            prompt,
            buckets,
            constraint_count,
            has_code_block,
            has_enumeration,
            multiple_files
          )
        ),
      has_code_block: has_code_block,
      has_constraints: constraint_count,
      has_enumeration: has_enumeration,
      mentions_multiple_files: multiple_files,
      error_signal: error_signal,
      keyword_buckets: buckets
    }
  end

  @doc """
  Recommend a strategy for a profile. Returns `{:ok, strategy_name, confidence}`
  or `{:error, :no_recommendation}` when no strategy in the registry prefers
  the profile's task type.

  `adaptive` is excluded in 0.4.1 — it relies on `Jido.AI.Reasoning.Adaptive`
  which isn't fully wired end-to-end in the agent loop yet. 0.4.3 re-enables it.
  """
  @spec recommend(TaskProfile.t(), keyword()) ::
          {:ok, String.t(), float()} | {:error, :no_recommendation}
  def recommend(%TaskProfile{} = profile, _opts \\ []) do
    # opts[:history] reserved for 0.4.3; ignored today.
    candidates =
      StrategyRegistry.list()
      |> Enum.reject(&(&1.name == "adaptive"))
      |> Enum.map(fn %{name: name} ->
        prefers = StrategyRegistry.prefers_for(name) || %{task_types: [], complexity: []}
        {name, score_candidate(prefers, profile)}
      end)
      |> Enum.reject(fn {_name, score} -> score == 0.0 end)
      |> Enum.sort_by(fn {name, score} -> {-score, name} end)

    case candidates do
      [{name, score} | _] ->
        confidence = min(1.0, score)
        {:ok, name, confidence}

      [] ->
        {:ok, "cot", 0.25}
    end
  end

  @doc """
  Convenience: profile and recommend in one shot.
  """
  @spec recommend_for(String.t(), keyword()) ::
          {:ok, String.t(), float(), TaskProfile.t()}
  def recommend_for(prompt, opts \\ []) when is_binary(prompt) do
    profile = profile(prompt, opts)
    {:ok, strategy, confidence} = recommend(profile, opts)
    {:ok, strategy, confidence, profile}
  end

  # ---------------------------------------------------------------------------
  # Private — task type
  # ---------------------------------------------------------------------------

  defp keyword_buckets(lower) do
    @task_keywords
    |> Enum.into(%{}, fn {bucket, kws} ->
      {bucket, Enum.count(kws, &String.contains?(lower, &1))}
    end)
  end

  defp pick_task_type(_buckets, true), do: :debugging

  defp pick_task_type(buckets, false) do
    max_hits =
      buckets
      |> Map.values()
      |> Enum.max(fn -> 0 end)

    if max_hits == 0 do
      :open_ended
    else
      # Stable tie-breaker: priority order ensures determinism without needing
      # to sort by atom name (which would be surprising for users).
      priority = [:debugging, :verification, :planning, :refactoring, :qa, :exploration]

      priority
      |> Enum.find(fn b -> Map.get(buckets, b, 0) == max_hits end)
      |> case do
        nil -> :open_ended
        bucket -> bucket
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Private — complexity
  # ---------------------------------------------------------------------------

  defp count_constraints(lower) do
    Enum.count(@constraint_markers, &String.contains?(lower, &1))
  end

  defp enumerated?(prompt) do
    case Regex.scan(@numbered_list, prompt) do
      matches when length(matches) >= 2 -> true
      _ -> false
    end
  end

  defp mentions_multiple_files?(prompt) do
    Regex.match?(@multi_file_hint, prompt) or
      length(Regex.scan(@path_pattern, prompt)) >= 2
  end

  defp score_complexity(
         prompt,
         _buckets,
         constraints,
         has_code_block,
         has_enumeration,
         multi_files
       ) do
    length_score = byte_size(prompt) / 10.0
    constraint_score = 10 * constraints
    code_score = if has_code_block, do: 15, else: 0
    multi_file_score = if multi_files, do: 10, else: 0
    enum_score = if has_enumeration, do: 20, else: 0

    length_score + constraint_score + code_score + multi_file_score + enum_score
  end

  defp bucket_complexity(score) when score < 20, do: :simple
  defp bucket_complexity(score) when score < 50, do: :moderate
  defp bucket_complexity(score) when score <= 80, do: :complex
  defp bucket_complexity(_), do: :highly_complex

  # ---------------------------------------------------------------------------
  # Private — strategy scoring
  # ---------------------------------------------------------------------------

  defp score_candidate(prefers, profile) do
    type_match = score_task_match(prefers, profile.task_type)

    complexity_match =
      if profile.complexity in Map.get(prefers, :complexity, []), do: 0.3, else: 0.0

    signal_bonus =
      cond do
        profile.error_signal and primary_task?(prefers, :debugging) -> 0.1
        profile.has_enumeration and primary_task?(prefers, :planning) -> 0.1
        true -> 0.0
      end

    type_match + complexity_match + signal_bonus
  end

  # Position-weighted: the first task_type in a strategy's list is its primary
  # specialization, later entries are secondary fits. Keeps tie-breaking
  # semantic (tot wins planning over aot) instead of alphabetical.
  defp score_task_match(prefers, task_type) do
    prefers
    |> Map.get(:task_types, [])
    |> Enum.find_index(&(&1 == task_type))
    |> case do
      nil -> 0.0
      idx -> max(0.0, 0.6 - idx * 0.05)
    end
  end

  defp primary_task?(prefers, task_type) do
    case Map.get(prefers, :task_types, []) do
      [^task_type | _] -> true
      _ -> false
    end
  end
end
