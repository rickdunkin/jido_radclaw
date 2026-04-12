defmodule JidoClaw.Workflows.StepResult do
  @moduledoc """
  Internal step result struct used during workflow execution.

  Carries the step name, template, result text, and any dynamic artifacts
  discovered at runtime. Converted to `{label, text}` tuples at the
  workflow output boundary by `RunSkill.build_result/2`.
  """

  @type t :: %__MODULE__{
          name: String.t(),
          template: String.t() | nil,
          result: String.t(),
          artifacts: map()
        }

  defstruct [:name, :template, :result, artifacts: %{}]
end
