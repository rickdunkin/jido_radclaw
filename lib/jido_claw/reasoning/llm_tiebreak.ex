defmodule JidoClaw.Reasoning.LLMTiebreaker do
  @moduledoc """
  Deterministic LLM-backed tie-breaker for `AutoSelect`.

  When the heuristic classifier can't distinguish between 2–3 candidate
  strategies (score gap below `@tiebreak_threshold`), `AutoSelect` asks this
  module to pick one with a short, structured LLM call. A single LLM pick
  breaks ties that heuristics + history don't resolve.

  The call uses `Jido.AI.Actions.Reasoning.RunStrategy` with a short
  `:cod` (chain-of-draft) strategy to minimize tokens and latency. On
  timeout/error/parse-failure, the caller falls back to the top heuristic
  candidate — this module never blocks selection.

  Telemetry events:
    * `[:jido_claw, :reasoning, :tiebreak, :invoked]`
    * `[:jido_claw, :reasoning, :tiebreak, :chose]`
    * `[:jido_claw, :reasoning, :tiebreak, :failed]`
  """

  alias JidoClaw.Reasoning.StrategyRegistry

  @default_runner Jido.AI.Actions.Reasoning.RunStrategy
  @default_timeout_ms 10_000

  @type opts :: [
          runner: module(),
          timeout_ms: non_neg_integer(),
          tool_context: map()
        ]

  @doc """
  Pick the best strategy from `candidates` for the given `prompt`.

  `candidates` is a list of strategy name strings (e.g. `["cot", "tot"]`);
  the LLM is asked to reply with exactly one name. Returns `{:ok, name}`
  on a clean parse, `{:error, reason}` otherwise.
  """
  @spec choose(String.t(), [String.t()], opts()) ::
          {:ok, String.t()} | {:error, term()}
  def choose(prompt, candidates, opts \\ [])
      when is_binary(prompt) and is_list(candidates) and candidates != [] do
    runner = Keyword.get(opts, :runner, @default_runner)
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    :telemetry.execute(
      [:jido_claw, :reasoning, :tiebreak, :invoked],
      %{system_time: System.system_time()},
      %{candidates: candidates}
    )

    structured_prompt = build_prompt(prompt, candidates)

    run_params = %{
      strategy: :cod,
      prompt: structured_prompt,
      timeout: timeout_ms
    }

    try do
      case runner.run(run_params, %{}) do
        {:ok, %{output: output}} ->
          output_str = extract_text(output)

          case parse_choice(output_str, candidates) do
            {:ok, name} ->
              :telemetry.execute(
                [:jido_claw, :reasoning, :tiebreak, :chose],
                %{},
                %{chosen: name, candidates: candidates}
              )

              {:ok, name}

            :error ->
              emit_failed(:unparseable, candidates)
              {:error, :unparseable}
          end

        {:error, reason} ->
          emit_failed(reason, candidates)
          {:error, reason}

        other ->
          emit_failed({:unexpected_result, other}, candidates)
          {:error, {:unexpected_result, other}}
      end
    rescue
      e ->
        emit_failed({:raised, Exception.message(e)}, candidates)
        {:error, {:raised, Exception.message(e)}}
    catch
      :exit, reason ->
        emit_failed({:exit, reason}, candidates)
        {:error, {:exit, reason}}
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp emit_failed(reason, candidates) do
    :telemetry.execute(
      [:jido_claw, :reasoning, :tiebreak, :failed],
      %{},
      %{reason: inspect(reason), candidates: candidates}
    )
  end

  defp build_prompt(user_prompt, candidates) do
    descriptions =
      candidates
      |> Enum.map_join("\n", fn name ->
        desc = strategy_description(name)
        "- #{name}: #{desc}"
      end)

    names_csv = Enum.join(candidates, ", ")

    """
    Pick the single best reasoning strategy for the task below.

    Task:
    #{user_prompt}

    Candidate strategies:
    #{descriptions}

    Reply with exactly one name from this list and nothing else: #{names_csv}
    """
  end

  defp strategy_description(name) do
    StrategyRegistry.list()
    |> Enum.find(&(&1.name == name))
    |> case do
      %{description: desc} when is_binary(desc) -> desc
      _ -> name
    end
  end

  defp extract_text(text) when is_binary(text), do: text

  defp extract_text(%{result: r}) when is_binary(r), do: r
  defp extract_text(%{answer: a}) when is_binary(a), do: a
  defp extract_text(%{conclusion: c}) when is_binary(c), do: c
  defp extract_text(other), do: inspect(other)

  defp parse_choice(text, candidates) when is_binary(text) do
    normalized = text |> String.trim() |> String.downcase()

    # Prefer a last-token match (model may emit rationale before the answer).
    # Fall back to first-occurrence scan so single-word replies still work.
    last_token =
      normalized
      |> String.split(~r/[^a-z0-9_]+/, trim: true)
      |> List.last()

    cond do
      last_token in candidates ->
        {:ok, last_token}

      match = Enum.find(candidates, fn c -> String.contains?(normalized, c) end) ->
        {:ok, match}

      true ->
        :error
    end
  end
end
