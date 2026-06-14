defmodule JidoClaw.Skills.Steps.RetryBudget do
  @moduledoc """
  Shared `retry:` budget helpers for the compiled-skill step modules
  (`AgentStep`, `IterativeStep`).

  Reactor treats a bare `{:error, _}` as terminal regardless of `max_retries`,
  so the YAML `retry:` budget is implemented as a `compensate/4` policy in each
  step: while the declared budget and the per-attempt `retries_remaining` are
  both positive, the step returns `:retry`. These two helpers read those two
  values.
  """

  @doc """
  The declared `retry:` budget from a step's impl options.

  Returns the non-negative integer `retry` option, or `0` when absent or
  malformed (a bad value must not silently grant retries).
  """
  @spec retry_budget(keyword()) :: non_neg_integer()
  def retry_budget(options) do
    case Keyword.get(options, :retry, 0) do
      retry when is_integer(retry) and retry >= 0 -> retry
      _ -> 0
    end
  end

  @doc """
  True while a step has retries left.

  `:infinity` always has remaining budget; a positive integer counts down;
  anything else (exhausted or malformed) is `false`.
  """
  @spec positive_remaining?(term()) :: boolean()
  def positive_remaining?(:infinity), do: true
  def positive_remaining?(remaining) when is_integer(remaining), do: remaining > 0
  def positive_remaining?(_), do: false
end
