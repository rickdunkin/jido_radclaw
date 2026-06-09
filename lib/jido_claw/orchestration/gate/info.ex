defmodule JidoClaw.Orchestration.Gate.Info do
  @moduledoc """
  Introspection over the gate DSL (`JidoClaw.Orchestration.Gate.Dsl`).

  `Spark.InfoGenerator` derives `gate_kind/1` + `gate_kind!/1`,
  `gate_title/1` + `gate_title!/1`, `gate_description/1`, `gate_workflow/1`
  from the `gate` section schema; `fields/1` returns the declared
  `%Gate.Field{}` entities.
  """

  use Spark.InfoGenerator,
    extension: JidoClaw.Orchestration.Gate.Dsl,
    sections: [:gate]

  alias JidoClaw.Orchestration.Gate.Field
  alias Spark.Dsl.Extension

  @doc "The gate's declared operator input fields, in declaration order."
  @spec fields(module() | Spark.Dsl.t()) :: [Field.t()]
  def fields(gate_module) do
    Extension.get_entities(gate_module, [:gate, :fields])
  end
end
