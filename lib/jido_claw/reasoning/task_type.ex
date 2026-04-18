defmodule JidoClaw.Reasoning.TaskType do
  @moduledoc """
  Enum mirror of `JidoClaw.Reasoning.TaskProfile.task_type/0` for the
  `reasoning_outcomes` resource.
  """

  use Ash.Type.Enum,
    values: [:planning, :debugging, :refactoring, :exploration, :verification, :qa, :open_ended]
end
