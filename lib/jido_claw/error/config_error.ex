defmodule JidoClaw.Error.ConfigError do
  @moduledoc "Invalid JidoClaw configuration error leaf."
  use Splode.Error, class: :config, fields: [:message, :field, :value, :details]

  @impl true
  def exception(opts) do
    opts = if is_map(opts), do: Map.to_list(opts), else: opts

    opts
    |> Keyword.put_new(:message, "Invalid JidoClaw configuration")
    |> Keyword.put_new(:details, %{})
    |> super()
  end
end
