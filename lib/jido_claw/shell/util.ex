defmodule JidoClaw.Shell.Util do
  @moduledoc """
  Shared helpers for the Shell subsystem.
  """

  @doc """
  Structural type hint for shell-config values — never the value itself.

  Used when logging rejected profile values or unexpected server-registry
  entries. A config typo like `DATABASE_PASSWORD: [prod-secret]` should
  log `list/1`, not the secret. Keys fall through the same helper because
  a non-string key could itself be a structured term carrying sensitive
  data.
  """
  @spec type_hint(any()) :: String.t()
  def type_hint(value) when is_binary(value), do: "string"
  def type_hint(value) when is_integer(value), do: "integer"
  def type_hint(value) when is_float(value), do: "float"
  def type_hint(value) when is_boolean(value), do: "boolean"
  def type_hint(nil), do: "nil"
  def type_hint(value) when is_atom(value), do: "atom"
  def type_hint(value) when is_list(value), do: "list/#{length(value)}"
  def type_hint(value) when is_map(value), do: "map/#{map_size(value)}"
  def type_hint(value) when is_tuple(value), do: "tuple/#{tuple_size(value)}"
  def type_hint(_), do: "term"
end
