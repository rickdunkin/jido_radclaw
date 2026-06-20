defmodule JidoClaw.Orchestration.ComposerArtifact.Envelope do
  @moduledoc """
  Versioned, `[:safe]`-decodable encoding for a composer artifact value
  (AR-2 Phase 2b).

  A `JidoClaw.Orchestration.ComposerArtifact`'s decrypted `value` column is
  NOT a raw term — it is `:erlang.term_to_binary({@artifact_version,
  normalized_term})`, where `normalized_term` has first been run through
  `normalize/1`. `normalize/1` is the **no-novel-atom** coercion: every atom
  outside `true`/`false`/`nil` is stringified (`inspect/1` for values,
  `Atom.to_string/1` for keys — never `String.to_atom/1`, which would create
  atoms). That guarantee is what makes `decode/1`'s `binary_to_term(blob,
  [:safe])` sound on any VM: `[:safe]` raises `ArgumentError` on an atom
  absent from the post-reboot table, and `normalize/1` ensures none survive.

  Mirrors `JidoClaw.Orchestration.Replay.decode_blob/1` and
  `ReactorRunner.encode_checkpoint/3` (`@checkpoint_version`): an all-data
  outer tuple, a version guard, and an `ArgumentError` rescue. Bump
  `@artifact_version` on any envelope shape change; any other shape (or
  unknown version) decodes as `{:error, :corrupt_artifact}`.

  `normalize/1` is shared with `JidoClaw.RouteComposer.Emit.DefaultMapper` so
  the mapper's inline coercion and the encoder's belt-and-suspenders pass use
  one definition (single source of truth, no clone).
  """

  # Bump together with any envelope shape change. A v2 encoder pairs with a
  # v2 clause in `decode/1`; an unknown version refuses as corrupt.
  @artifact_version 1

  # Default size guard on the decoded blob (1 MB) — mirrors
  # `ReactorRunner`'s `@default_replay_inputs_cap`. An oversized blob is
  # never handed to `binary_to_term/2` (decode-bomb amplification guard).
  @default_max_bytes 1_048_576

  @doc """
  Encode `term` as the durable artifact blob:
  `term_to_binary({@artifact_version, normalize(term)})`.
  """
  @spec encode(term()) :: binary()
  def encode(term), do: :erlang.term_to_binary({@artifact_version, normalize(term)})

  @doc """
  Decode a stored artifact blob back to its term.

  Returns `{:ok, term}` (the original value — `nil` is a real, valid
  artifact value), or `{:error, reason}` for an over-cap blob
  (`{:artifact_too_large, bytes}`), a non-binary input (`:not_a_binary`),
  or any malformed/wrong-version/novel-atom payload (`:corrupt_artifact`).
  """
  @spec decode(binary()) :: {:ok, term()} | {:error, term()}
  def decode(blob) when is_binary(blob) do
    if byte_size(blob) > max_bytes() do
      {:error, {:artifact_too_large, byte_size(blob)}}
    else
      decode_safe(blob)
    end
  end

  def decode(_other), do: {:error, :not_a_binary}

  defp decode_safe(blob) do
    case :erlang.binary_to_term(blob, [:safe]) do
      {@artifact_version, term} -> {:ok, term}
      _other -> {:error, :corrupt_artifact}
    end
  rescue
    # `[:safe]` raises ArgumentError on a novel atom — sound only because
    # `normalize/1` stringified every atom but true/false/nil. Treat as
    # corrupt rather than letting it escape.
    ArgumentError -> {:error, :corrupt_artifact}
  end

  @doc """
  No-novel-atom, JSON-safe normalizer (AR-2 §6, P3). `true`/`false`/`nil`
  stay (always interned); every other atom value becomes `inspect/1`, every
  atom key becomes `Atom.to_string/1`. Lists/maps recurse; structs collapse
  to `inspect/1`.
  """
  @spec normalize(term()) :: term()
  def normalize(value)
      when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
      do: value

  def normalize(value) when is_list(value), do: Enum.map(value, &normalize/1)
  def normalize(value) when is_struct(value), do: inspect(value)

  def normalize(value) when is_map(value),
    do: Map.new(value, fn {k, v} -> {normalize_key(k), normalize(v)} end)

  def normalize(value), do: inspect(value)

  # Atom keys stringify via `Atom.to_string/1` (the no-atom-creation
  # direction); a string key passes through; anything else is `inspect/1`-ed.
  defp normalize_key(k) when is_binary(k), do: k
  defp normalize_key(k) when is_atom(k), do: Atom.to_string(k)
  defp normalize_key(k), do: inspect(k)

  defp max_bytes do
    case Application.get_env(:jido_claw, :composer_artifact_max_bytes, @default_max_bytes) do
      cap when is_integer(cap) and cap > 0 -> cap
      _invalid -> @default_max_bytes
    end
  end
end
