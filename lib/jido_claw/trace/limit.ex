defmodule JidoClaw.Trace.Limit do
  @moduledoc """
  Shared `Enum.take`-based limit helper used by both `JidoClaw.Trace` and
  `JidoClaw.Trace.Collector`. Kept tiny so the two callers don't drift.
  """

  @doc """
  Takes `Enum.take(values, limit)` when `limit` is a non-negative integer,
  otherwise passes through unchanged.
  """
  @spec take(Enumerable.t(), term()) :: list()
  def take(values, nil), do: as_list(values)

  def take(values, limit) when is_integer(limit) and limit >= 0 do
    values
    |> as_list()
    |> Enum.take(limit)
  end

  def take(values, _limit), do: as_list(values)

  defp as_list(values) when is_list(values), do: values
  defp as_list(values), do: Enum.to_list(values)
end
