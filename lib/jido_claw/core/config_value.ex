defmodule JidoClaw.Core.ConfigValue do
  @moduledoc """
  Shared config-value normalization.

  `positive_integer/2` deliberately does NOT coerce (a string `"5"` falls to
  the default): it validates an already-typed config value, replacing the
  three per-module copies in the auth rate limiter, workflow recovery, and
  the trace collector. Semantic variants (ceilings, nil fallbacks) stay with
  their callers.
  """

  @doc "The value when it is a positive integer, otherwise `default`."
  @spec positive_integer(term(), integer()) :: integer()
  def positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  def positive_integer(_value, default), do: default
end
