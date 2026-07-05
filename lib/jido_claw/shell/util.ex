defmodule JidoClaw.Shell.Util do
  @moduledoc """
  Shared helpers for the Shell subsystem.
  """

  require Logger

  @doc """
  Path of the project's shell config file (`.jido/config.yaml`).
  """
  @spec config_path(String.t()) :: String.t()
  def config_path(project_dir), do: Path.join([project_dir, ".jido", "config.yaml"])

  @doc """
  Fold one `{key, value}` env entry into `acc`: string values pass
  through, integers are coerced to strings, anything else is skipped
  with a warning under `context` (e.g. `"[ProfileManager] profile
  'staging'"`). A rejected key or value is only ever logged as its
  `type_hint/1` — a structured term could carry a secret.
  """
  @spec coerce_env_entry(map(), String.t(), term(), term()) :: map()
  def coerce_env_entry(acc, context, key, value) do
    cond do
      not is_binary(key) ->
        Logger.warning("#{context}: non-string key (got: #{type_hint(key)}) — skipping entry")

        acc

      is_binary(value) ->
        Map.put(acc, key, value)

      is_integer(value) ->
        Map.put(acc, key, Integer.to_string(value))

      true ->
        Logger.warning(
          "#{context}: non-string value for #{key} (got: #{type_hint(value)}) — skipping entry"
        )

        acc
    end
  end

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
