defmodule JidoClaw.Orchestration.Reason do
  @moduledoc """
  Normalizes an arbitrary failure reason — an exception, a list of errors, a
  string, or any other term — into a single log-safe string suitable for a
  `WorkflowEvent` error payload and the projected `WorkflowRun.error` column.

  Shared by the reactor producers (`JidoClaw.Orchestration.ReactorMiddleware`
  and `JidoClaw.Orchestration.ReactorRunner`); `WorkflowRunner` keeps its own
  narrower variant.
  """

  @doc "Format `reason` as a single log-safe error string."
  @spec format(term()) :: String.t()
  def format(%{__exception__: true} = error), do: Exception.message(error)
  def format(reason) when is_binary(reason), do: reason
  def format(reasons) when is_list(reasons), do: Enum.map_join(reasons, "; ", &format/1)
  def format(reason), do: inspect(reason)
end
