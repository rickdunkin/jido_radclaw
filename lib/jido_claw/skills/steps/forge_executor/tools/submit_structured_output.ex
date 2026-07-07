defmodule JidoClaw.Skills.Steps.ForgeExecutor.Tools.SubmitStructuredOutput do
  @moduledoc """
  The deposit lane's single MCP tool: a vendor CLI submits its final
  structured result here, and the step-scoped `Deposit` box validates it
  against the template's declared output contract.

  The schema is the JSON-Schema MAP form (the MCP-proxy pass-through class:
  advertisement-only, `Jido.Exec` skips param validation) deliberately: the
  keyword `type: :map` form validates as NimbleOptions' atom-keyed map and
  would reject every real CLI deposit (JSON arrives string-keyed; only the
  TOP-LEVEL `output` key is atomized by the anubis patch). The `output` arg
  advertises `{"type": "object"}` — the real per-template schema rides the
  step prompt + box validation, forced by the single-static-server model
  (exactly the consolidator's constraint), and the missing-arg guard lives in
  `run/2`. A validation failure returns `{:error, _}`, which jido_mcp maps to
  an `isError` tool result the CLI can read and retry on — the in-session
  repair loop that is the structural advantage over a stdout relay.
  """

  use Jido.Action,
    name: "submit_structured_output",
    description:
      "Submit the final structured result object for this step. The object is " <>
        "validated against the step's declared output schema (shown in your " <>
        "instructions); on a validation error, fix the object and call again.",
    schema: %{
      "type" => "object",
      "properties" => %{
        "output" => %{
          "type" => "object",
          "description" =>
            "The structured output object for this step, matching the JSON " <>
              "schema in the step instructions."
        }
      },
      "required" => ["output"]
    }

  alias JidoClaw.MCP.ScopedForward
  alias JidoClaw.Skills.Steps.ForgeExecutor.Deposit

  @impl Jido.Action
  def run(args, ctx) do
    case ScopedForward.scope_id(ctx, :executor_deposit_ref) do
      ref when is_binary(ref) and ref != "" ->
        submit_payload(ref, output_arg(args))

      _ ->
        {:error, "no active deposit ref on this connection"}
    end
  end

  # The anubis patch atomizes known top-level keys, but a clause per key shape
  # keeps the tool total over the pre-patch string form too (the consolidator
  # Helpers precedent).
  defp output_arg(%{output: value}), do: value
  defp output_arg(%{"output" => value}), do: value
  defp output_arg(_args), do: nil

  # The pass-through schema class skips Jido.Exec's required-arg validation,
  # so the guard lives here.
  defp submit_payload(_ref, nil), do: {:error, "missing required argument: output"}
  defp submit_payload(ref, payload), do: Deposit.submit(ref, payload)
end
