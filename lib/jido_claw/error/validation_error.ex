defmodule JidoClaw.Error.ValidationError do
  @moduledoc "Invalid input or schema validation error leaf."
  use Splode.Error, class: :invalid, fields: [:message, :field, :value, :details]

  @impl Exception
  def exception(opts) do
    opts = if is_map(opts), do: Map.to_list(opts), else: opts

    opts
    |> Keyword.put_new(:message, "Invalid JidoClaw input")
    |> Keyword.put_new(:details, %{})
    |> super()
  end
end
