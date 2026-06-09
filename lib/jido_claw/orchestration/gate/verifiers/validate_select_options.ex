defmodule JidoClaw.Orchestration.Gate.Verifiers.ValidateSelectOptions do
  @moduledoc """
  Compile-time check that every `type: :select` gate field declares non-empty
  `options:` — the one cross-field rule the entity schema cannot express. A
  select with no choices would render as an empty dropdown the operator can
  never satisfy.
  """

  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier
  alias Spark.Error.DslError

  @impl true
  def verify(dsl_state) do
    dsl_state
    |> Verifier.get_entities([:gate, :fields])
    |> Enum.find(fn field -> field.type == :select and field.options == [] end)
    |> case do
      nil ->
        :ok

      field ->
        {:error,
         DslError.exception(
           module: Verifier.get_persisted(dsl_state, :module),
           path: [:gate, :fields, :field, field.name],
           message:
             "select field #{inspect(field.name)} must declare non-empty options " <>
               "(e.g. `options: [\"yes\", \"no\"]`)"
         )}
    end
  end
end
