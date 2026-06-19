defmodule JidoClaw.Workflows.StepIds do
  @moduledoc """
  Shared compile-time pool of positional atom ids (`:step_1` … `:step_256`) for
  Reactor step and argument names.

  Reactor step/argument names must be **atoms**, but workflow step names (LLM-
  authored YAML skills) and route-composer stage names are **strings** — and
  `String.to_atom/1` on those leaks the atom table. This module is the single
  source of the bounded atom pool both `JidoClaw.Skills.Compiler` and
  `JidoClaw.RouteComposer.WaveBuilder` draw from, plus the cap (`max/0`) each
  validates against up front so an oversized graph is an `{:error, _}` rather
  than a `String.to_atom/1` or a function-clause crash.

  It lives in `JidoClaw.Workflows` (beside `StepResult` / `ContextBuilder`), not
  under either consumer, so both depend *down* onto it — the skills compiler
  never points *up* into the composer.
  """

  @max 256
  @ids List.to_tuple(Enum.map(1..@max, &:"step_#{&1}"))

  @doc "The maximum number of step ids in the pool (the per-graph step cap)."
  @spec max() :: pos_integer()
  def max, do: @max

  @doc """
  Fetch the positional step id for a 1-based `index`.

  Returns `{:ok, atom}` for an index in `1..max/0`, or `{:error,
  :out_of_bounds}` past the cap (an oversized graph is an error tuple, never a
  function-clause crash). Callers validate the count against `max/0` up front,
  so the error tuple is the defensive backstop, not the hot path.
  """
  @spec fetch(integer()) :: {:ok, atom()} | {:error, :out_of_bounds}
  def fetch(index) when is_integer(index) and index >= 1 and index <= @max,
    do: {:ok, elem(@ids, index - 1)}

  def fetch(index) when is_integer(index), do: {:error, :out_of_bounds}
end
