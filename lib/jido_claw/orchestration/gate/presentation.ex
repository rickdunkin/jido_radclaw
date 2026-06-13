defmodule JidoClaw.Orchestration.Gate.Presentation do
  @moduledoc """
  Shared gate-DSL presentation.

  Turns a gate module's declared `title`/`description`/`fields` into the
  JSON-native `details` map both producers seed into the `AgentCase` row:
  `JidoClaw.Orchestration.GateStep` (workflow gates) and
  `JidoClaw.Orchestration.ToolApprovals` (tool-call gates). Keys and values are
  normalized to string shapes so the in-memory map equals its jsonb round-trip
  — the approval surfaces (CLI `/gates`, web `/approvals`) read one shape.
  """

  alias JidoClaw.Orchestration.Gate

  @doc """
  The gate DSL's presentation as a JSON-native map:
  `"gate_title"`, optional `"gate_description"`, and `"fields"`.
  """
  @spec details(module()) :: map()
  def details(gate_module) do
    base = %{
      "gate_title" => Gate.Info.gate_title!(gate_module),
      "fields" => Enum.map(Gate.Info.fields(gate_module), &field_to_map/1)
    }

    put_description(base, gate_module)
  end

  defp put_description(details, gate_module) do
    case Gate.Info.gate_description(gate_module) do
      {:ok, description} when is_binary(description) ->
        Map.put(details, "gate_description", description)

      _ ->
        details
    end
  end

  defp field_to_map(%Gate.Field{} = field) do
    %{
      "name" => Atom.to_string(field.name),
      "type" => Atom.to_string(field.type),
      "label" => field.label || humanize(field.name),
      "options" => field.options,
      "required" => field.required?
    }
  end

  defp humanize(name) do
    name
    |> Atom.to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end
end
