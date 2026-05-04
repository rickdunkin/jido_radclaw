defmodule JidoClaw.Conversations.TranscriptEnvelope do
  @moduledoc """
  JSON-safe normalizer for tool result tuples and arbitrary metadata.

  Tool results from Jido actions are arbitrary Elixir terms — they may
  carry tuples, atoms, structs, PIDs, refs, anything the action chose
  to return. The Recorder needs to write these into a Postgres `:map`
  column, which goes through `Jason.encode`. Most of these terms aren't
  natively JSON-encodable, so we normalize them into a canonical
  envelope shape before persisting.

  ## Output shape

      %{
        status: :ok | :error,
        value: <normalized term> | nil,
        error: <normalized term> | nil,
        effects: <normalized term> | nil,
        raw_inspect: <inspect string> | nil
      }

  Or, for arbitrary non-tuple terms (e.g. metadata maps, argument
  payloads), the recursively normalized term itself.

  ## Normalization rules

    * Atoms (except `nil`, `true`, `false`) → `":atom_name"` (string
      with leading colon, so the round-trip is unambiguous).
    * Tuples → `%{__tuple__: [<normalized elements>]}` so JSON
      consumers can reconstruct or visually identify them.
    * Maps → recursive value normalization, atom keys preserved as
      atom strings via Jason's default behavior.
    * Lists → recursive element normalization.
    * Structs implementing `Jason.Encoder` → encoded then decoded so
      the natural JSON shape is preserved (e.g. `DateTime` →
      ISO-8601 string).
    * Other structs / PIDs / Refs / Functions → `inspect/2` placed in
      the `raw_inspect` field of the envelope; the value/error slots
      get `nil`.
    * Strings, numbers, booleans, `nil` → unchanged.
  """

  @doc """
  Normalize an arbitrary term into a JSON-safe value.

  When the input is a 2-tuple matching `{:ok, value}` or
  `{:error, reason}`, or a 3-tuple matching
  `{:ok, value, effects}`, the result is a structured envelope.
  Otherwise the result is the recursively normalized term.
  """
  @spec normalize(term()) :: term()
  def normalize({:ok, value}), do: envelope(:ok, value, nil, nil)
  def normalize({:ok, value, effects}), do: envelope(:ok, value, nil, effects)
  def normalize({:error, reason}), do: envelope(:error, nil, reason, nil)
  def normalize(other), do: walk(other)

  # ---------------------------------------------------------------------------
  # Envelope shape
  # ---------------------------------------------------------------------------

  defp envelope(status, value, error, effects) do
    %{
      status: status,
      value: walk(value),
      error: walk(error),
      effects: walk(effects),
      raw_inspect: nil
    }
  end

  # ---------------------------------------------------------------------------
  # Recursive walker
  # ---------------------------------------------------------------------------

  defp walk(nil), do: nil
  defp walk(true), do: true
  defp walk(false), do: false
  defp walk(value) when is_binary(value), do: value
  defp walk(value) when is_number(value), do: value

  defp walk(atom) when is_atom(atom), do: ":" <> Atom.to_string(atom)

  defp walk(tuple) when is_tuple(tuple) do
    %{__tuple__: tuple |> Tuple.to_list() |> Enum.map(&walk/1)}
  end

  defp walk(list) when is_list(list), do: Enum.map(list, &walk/1)

  defp walk(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp walk(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
  defp walk(%Date{} = d), do: Date.to_iso8601(d)
  defp walk(%Time{} = t), do: Time.to_iso8601(t)

  defp walk(%_struct{} = value) do
    if jason_encoder?(value) do
      case Jason.encode(value) do
        {:ok, json} -> Jason.decode!(json) |> walk()
        _ -> %{status: :error, value: nil, error: nil, effects: nil, raw_inspect: inspect(value)}
      end
    else
      %{status: :error, value: nil, error: nil, effects: nil, raw_inspect: inspect(value)}
    end
  end

  defp walk(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {normalize_key(k), walk(v)} end)
  end

  defp walk(other) do
    %{status: :error, value: nil, error: nil, effects: nil, raw_inspect: inspect(other)}
  end

  defp normalize_key(k) when is_atom(k), do: k
  defp normalize_key(k) when is_binary(k), do: k
  defp normalize_key(k), do: inspect(k)

  defp jason_encoder?(value) do
    case Jason.Encoder.impl_for(value) do
      Jason.Encoder.Any -> false
      _ -> true
    end
  end
end
