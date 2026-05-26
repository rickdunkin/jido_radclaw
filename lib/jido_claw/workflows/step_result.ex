defmodule JidoClaw.Workflows.StepResult do
  @moduledoc """
  Internal step result struct used during workflow execution.

  Carries the step name, template, result text, optional typed output
  (populated when the spawning worker carried a structured `:output`
  schema and validation succeeded), and any dynamic artifacts discovered
  at runtime. Converted to `{label, text}` tuples at the workflow output
  boundary by `RunSkill.build_result/2`.
  """

  @type t :: %__MODULE__{
          name: String.t(),
          template: String.t() | nil,
          result: String.t(),
          typed_output: map() | nil,
          artifacts: map()
        }

  defstruct [:name, :template, :result, :typed_output, artifacts: %{}]
end
