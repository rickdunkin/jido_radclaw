defmodule JidoClaw.Trace.Sanitize do
  @moduledoc """
  Redacts and omits sensitive/large payload values before they enter the
  trace ring or `trace_events` rows.

  Two key classes drive replacement at ingest time:

    * **Large keys** become `"[OMITTED]"` to keep the bounded ring from
      flooding with prompts, messages, raw responses, and tool payloads.
      The `:params` key is included because Jido tool execution telemetry
      (`deps/jido_ai/lib/jido_ai/turn.ex`) carries tool arguments under
      that key.

    * **Sensitive keys** become `"[REDACTED]"`. Match is exact for a
      curated set, plus suffix (`_secret`, `_key`, `_token`, `_password`)
      and substring (`secret_`) rules.

  Sanitization is applied recursively to both `:measurements` and
  `:metadata` at ingest; PIDs and functions are stringified via
  `inspect/1` so they survive serialization to JSON for Postgres.
  """

  @default_preview_bytes 500

  @large_keys MapSet.new([
                "arguments",
                "context",
                "data",
                "llm_opts",
                "messages",
                "params",
                "prompt",
                "query",
                "raw",
                "raw_request",
                "raw_response",
                "request",
                "request_opts",
                "response",
                "result",
                "stacktrace",
                "state"
              ])

  @sensitive_exact MapSet.new([
                     "api_key",
                     "apikey",
                     "password",
                     "secret",
                     "token",
                     "auth_token",
                     "authtoken",
                     "private_key",
                     "privatekey",
                     "access_key",
                     "accesskey",
                     "bearer",
                     "api_secret",
                     "apisecret",
                     "client_secret",
                     "clientsecret"
                   ])
  @sensitive_contains ["secret_"]
  @sensitive_suffixes ["_secret", "_key", "_token", "_password"]

  @doc """
  Replaces large/sensitive keys at every level of a map or list.

  Maps preserve their key types (atom keys stay atoms); only values
  are rewritten. PIDs and funs are inspected so they JSON-serialize.
  """
  @spec payload(term()) :: term()
  def payload(%{} = map) do
    Map.new(map, fn {key, value} ->
      cond do
        large_key?(key) ->
          {key, "[OMITTED]"}

        sensitive_key?(key) ->
          {key, "[REDACTED]"}

        true ->
          {key, payload(value)}
      end
    end)
  end

  def payload(values) when is_list(values), do: Enum.map(values, &payload/1)
  def payload(value) when is_pid(value), do: inspect(value)
  def payload(value) when is_function(value), do: inspect(value)
  def payload(value), do: value

  @doc """
  Produces a bounded printable preview of an arbitrary value.

  Strings are sliced; other values are sanitized then inspected with
  capped `printable_limit` so even pathological payloads stay bounded.
  """
  @spec preview(term(), pos_integer()) :: String.t()
  def preview(value, bytes \\ @default_preview_bytes)

  def preview(value, bytes) when is_binary(value) and is_integer(bytes) and bytes > 0 do
    String.slice(value, 0, bytes)
  end

  def preview(value, bytes) when is_integer(bytes) and bytes > 0 do
    value
    |> payload()
    |> inspect(limit: 20, printable_limit: bytes)
    |> String.slice(0, bytes)
  end

  defp large_key?(key) when is_atom(key), do: key |> Atom.to_string() |> large_key?()
  defp large_key?(key) when is_binary(key), do: MapSet.member?(@large_keys, key)
  defp large_key?(_key), do: false

  defp sensitive_key?(key) when is_atom(key), do: key |> Atom.to_string() |> sensitive_key?()

  defp sensitive_key?(key) when is_binary(key) do
    key = String.downcase(key)

    MapSet.member?(@sensitive_exact, key) or
      Enum.any?(@sensitive_contains, &String.contains?(key, &1)) or
      Enum.any?(@sensitive_suffixes, &String.ends_with?(key, &1))
  end

  defp sensitive_key?(_key), do: false
end
