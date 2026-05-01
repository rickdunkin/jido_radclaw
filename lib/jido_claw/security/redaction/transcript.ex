defmodule JidoClaw.Security.Redaction.Transcript do
  @moduledoc """
  Recursive transcript scrubber.

  Walks an arbitrary term:

    * **strings** — passed through `Patterns.redact/1`.
    * **maps** — recursed; values under sensitive key names (matched by
      `Redaction.Env.sensitive_key?/1`) are replaced wholesale with
      `"[REDACTED]"`.
    * **lists** — recursed element-wise.
    * **other terms** — returned unchanged.

  ## JSON-decode gating (`:json_aware_keys`)

  Some LLM-shaped payloads embed JSON inside string-typed fields
  (`"arguments"`, `"input"`, `"tool_input"`, `"content"`). For those,
  the redactor accepts an opt:

      Transcript.redact(map, json_aware_keys: ["arguments", "input"])

  When the walker hits a string value under a key in that list, it
  attempts `Jason.decode/1`; if the decode succeeds and the result is
  a map or list, the redactor recurses into the decoded shape and
  re-encodes. Otherwise the string is treated as opaque content and
  scrubbed by `Patterns.redact/1` only.

  **Default is `[]`** — Solution.solution_content and Memory.Fact.body
  must NEVER be speculatively decoded. The §1.8 acceptance gates pin
  this restriction so Phase 2/3 don't accidentally widen it.

  Idempotent: re-redacting an already-redacted term is a no-op.
  """

  alias JidoClaw.Security.Redaction.{Env, Patterns}

  @doc """
  Redact `term`, returning a new term of the same shape with secrets
  scrubbed.

  ## Options

    * `:json_aware_keys` — list of string keys whose string values
      should be JSON-decoded before recursive redaction. Default `[]`.
  """
  @spec redact(term(), keyword()) :: term()
  def redact(term, opts \\ []) do
    json_aware_keys = Keyword.get(opts, :json_aware_keys, [])
    walk(term, %{json_aware_keys: json_aware_keys, parent_key: nil})
  end

  # ---------------------------------------------------------------------------
  # Walk
  # ---------------------------------------------------------------------------

  defp walk(value, ctx) when is_binary(value) do
    cond do
      json_aware_key?(ctx) -> redact_json_aware(value, ctx)
      true -> Patterns.redact(value)
    end
  end

  defp walk(value, ctx) when is_map(value) do
    Map.new(value, fn {k, v} -> {k, walk_value(k, v, ctx)} end)
  end

  defp walk(value, ctx) when is_list(value) do
    Enum.map(value, &walk(&1, %{ctx | parent_key: nil}))
  end

  defp walk(value, _ctx), do: value

  # Apply key-aware sensitive-key replacement BEFORE descending. Once
  # replaced with "[REDACTED]" the sensitive value never recurses.
  defp walk_value(key, value, ctx) do
    if sensitive_key?(key) do
      "[REDACTED]"
    else
      walk(value, %{ctx | parent_key: stringify(key)})
    end
  end

  # ---------------------------------------------------------------------------
  # JSON-aware path
  # ---------------------------------------------------------------------------

  defp json_aware_key?(%{json_aware_keys: []}), do: false
  defp json_aware_key?(%{parent_key: nil}), do: false

  defp json_aware_key?(%{json_aware_keys: keys, parent_key: parent_key}) do
    parent_key in keys
  end

  defp redact_json_aware(value, ctx) do
    case Jason.decode(value) do
      {:ok, decoded} when is_map(decoded) or is_list(decoded) ->
        decoded
        |> walk(%{ctx | parent_key: nil})
        |> Jason.encode!()

      _ ->
        Patterns.redact(value)
    end
  end

  # ---------------------------------------------------------------------------
  # Sensitive-key detection
  # ---------------------------------------------------------------------------

  defp sensitive_key?(key) when is_atom(key), do: Env.sensitive_key?(Atom.to_string(key))
  defp sensitive_key?(key) when is_binary(key), do: Env.sensitive_key?(key)
  defp sensitive_key?(_), do: false

  defp stringify(k) when is_atom(k), do: Atom.to_string(k)
  defp stringify(k) when is_binary(k), do: k
  defp stringify(k), do: inspect(k)
end
