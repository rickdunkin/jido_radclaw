defmodule JidoClaw.Reasoning.Complexity do
  @moduledoc """
  Enum mirror of `JidoClaw.Reasoning.TaskProfile.complexity/0` for the
  `reasoning_outcomes` resource.
  """

  use Ash.Type.Enum, values: [:simple, :moderate, :complex, :highly_complex]
end
