defmodule JidoClaw.Reasoning.ExecutionKind do
  @moduledoc """
  Discriminator for rows in `reasoning_outcomes`. Separates general strategy
  runs (used by `Statistics.best_strategies_for/2`) from special-purpose
  executions like the `react` stub, certificate verification, and pipeline
  stages.

  Values:
    * `:strategy_run` — a direct reasoning-strategy invocation (e.g. `reason tool`).
    * `:react_stub` — the structured-prompt react branch (react is the agent's
      native loop, this tool just emits a scaffold).
    * `:certificate_verification` — `verify_certificate` wraps CoT.
    * `:pipeline_run` — one stage of a `run_pipeline` invocation. Rows carry
      `pipeline_name` + `pipeline_stage` + `metadata.stage_index`/`stage_total`
      for ordering and aggregation.
  """

  use Ash.Type.Enum,
    values: [:strategy_run, :react_stub, :certificate_verification, :pipeline_run]
end
