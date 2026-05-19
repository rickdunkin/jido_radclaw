defmodule JidoClaw.Error.Internal.UnknownError do
  @moduledoc """
  Fallback leaf for inputs that cannot be classified into a known JidoClaw
  error type. Splode's `unknown_error:` target.
  """
  use Splode.Error, class: :internal, fields: [:message, :details, :error]

  @impl true
  def exception(opts) do
    opts = if is_map(opts), do: Map.to_list(opts), else: opts
    message = Keyword.get(opts, :message) || unknown_message(opts[:error])

    opts
    |> Keyword.put(:message, message)
    |> Keyword.put_new(:details, %{})
    |> super()
  end

  defp unknown_message(error) when is_binary(error), do: error
  defp unknown_message(nil), do: "Unknown JidoClaw error"
  defp unknown_message(error), do: inspect(error)
end
