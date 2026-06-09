defmodule JidoClaw.Orchestration.Gate.Field do
  @moduledoc """
  One operator-facing input field declared in a gate module's
  `gate do fields do ... end end` block (`JidoClaw.Orchestration.Gate.Dsl`).

  The approval surfaces (web `/approvals`, CLI `/gates`) render these as
  typed inputs alongside the decision buttons. `__identifier__` is required
  by Spark's entity-uniqueness verification (`identifier: :name` on the
  entity — two fields with the same name fail at compile time);
  `__spark_metadata__` carries the source annotations Spark expects on every
  entity target.
  """

  defstruct [
    :name,
    :label,
    :__identifier__,
    __spark_metadata__: nil,
    type: :text,
    options: [],
    required?: false
  ]

  @type field_type :: :text | :select | :textarea | :number | :boolean

  @type t :: %__MODULE__{
          name: atom(),
          type: field_type(),
          label: String.t() | nil,
          options: [String.t()],
          required?: boolean()
        }
end
