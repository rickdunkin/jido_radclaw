defmodule JidoClaw.Memory.Consolidator.Tools.ProposeBlockUpdate do
  @moduledoc """
  Stage a curated Block-tier update at `(scope, label)`.

  Returns a structured success result on overflow rather than
  surfacing a tool error: `{ok: false, error: "char_limit_exceeded",
  char_limit: N, current_value: M}` so the model can parse it and
  retry with shorter content.
  """

  use Jido.Action,
    name: "propose_block_update",
    description: "Stage a curated Block-tier update at (scope, label).",
    schema: [
      label: [type: :string, required: true],
      new_content: [type: :string, required: true],
      description: [type: :string],
      char_limit: [type: :integer, default: 2000],
      pinned: [type: :boolean, default: true],
      position: [type: :integer, default: 0]
    ]

  alias JidoClaw.Memory.Consolidator.Tools.Helpers

  @impl true
  def run(args, ctx) do
    case Helpers.call_run_server(ctx, {:propose_block_update, args}) do
      :ok ->
        {:ok, %{ok: true}}

      {:char_limit_exceeded, current_value, char_limit} ->
        {:ok,
         %{
           ok: false,
           error: "char_limit_exceeded",
           char_limit: char_limit,
           current_value: current_value
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
