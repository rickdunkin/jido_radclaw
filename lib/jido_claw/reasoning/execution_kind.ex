defmodule JidoClaw.Reasoning.ExecutionKind do
  @moduledoc """
  Discriminator for rows in `reasoning_outcomes`. Separates general strategy
  runs (used by `Statistics.best_strategies_for/2`) from special-purpose
  executions like the `react` stub and certificate verification.

  In 0.4.1, only `:strategy_run` rows are produced. `:certificate_verification`
  and `:react_stub` values are reserved for 0.4.2+ (when `verify_certificate`
  is wrapped) and possible future use respectively.
  """

  use Ash.Type.Enum, values: [:strategy_run, :react_stub, :certificate_verification]
end
