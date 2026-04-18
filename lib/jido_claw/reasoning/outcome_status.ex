defmodule JidoClaw.Reasoning.OutcomeStatus do
  @moduledoc """
  Terminal status captured by `Telemetry.with_outcome/4` for a strategy
  execution: `:ok`, `:error`, or `:timeout`.
  """

  use Ash.Type.Enum, values: [:ok, :error, :timeout]
end
