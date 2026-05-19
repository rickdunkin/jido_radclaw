defmodule JidoClaw.Error.ExecutionError do
  @moduledoc """
  JidoClaw runtime execution error leaf.

  The `:phase` field is a debugging hint (where the failure occurred), NOT a
  machine-readable wire code. The wire layer maps every `ExecutionError` to
  `code: :execution_error` regardless of phase; callers that need a finer code
  should construct a different leaf or set `details.code` explicitly.
  """
  use Splode.Error, class: :execution, fields: [:message, :phase, :details]

  @impl true
  def exception(opts) do
    opts = if is_map(opts), do: Map.to_list(opts), else: opts

    opts
    |> Keyword.put_new(:message, "JidoClaw execution failed")
    |> Keyword.put_new(:details, %{})
    |> super()
  end
end
