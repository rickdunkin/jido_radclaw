defmodule JidoClaw.Network.Protocol do
  @moduledoc """
  Pure functional message protocol for agent network communication.

  Handles building, signing, decoding, and verifying network messages.
  All functions are stateless — no process required.

  Message shape:
    %{
      id:        uuid string,
      type:      "share" | "request" | "response" | "ping" | "pong",
      from:      agent_id string,
      payload:   map,
      signature_version: 2,
      signature: base64 string (Ed25519 over canonical envelope bytes),
      timestamp: ISO-8601 UTC string
    }

  `verify_and_normalize/3` is the inbound boundary: receivers must not
  consume raw transport terms directly — clustered PubSub delivers BEAM
  terms verbatim, so an inbound message can carry shapes plain JSON
  could never produce (atom keys, structs, tuples). The boundary
  verifies the signature and then replaces the payload with its JSON
  round-trip, so handlers only ever see canonical string-keyed plain
  data.
  """

  alias JidoClaw.Agent.Identity
  alias JidoClaw.Core.MapKeys

  @valid_types ~w(share request response ping pong)
  @signature_version 2
  @max_message_age_seconds 300
  @max_future_skew_seconds 30

  # ---------------------------------------------------------------------------
  # Core encode / decode
  # ---------------------------------------------------------------------------

  @doc """
  Build a signed message map.

  Builds the full envelope (UUID id, type, sender, payload, signature version,
  and ISO-8601 timestamp), canonicalizes it, and signs those bytes with
  `identity`'s private key.

  Returns a plain map with string keys suitable for JSON serialisation.
  """
  @spec encode(atom() | String.t(), map(), Identity.t()) :: map()
  def encode(type, payload, %{__struct__: Identity} = identity) do
    type = normalize_type!(type)

    unsigned = %{
      "id" => generate_id(),
      "type" => type,
      "from" => identity.agent_id,
      "payload" => payload,
      "signature_version" => @signature_version,
      "timestamp" => utc_now_iso()
    }

    Map.put(unsigned, "signature", Identity.sign(signing_bytes!(unsigned), identity.private_key))
  end

  @doc """
  Parse a raw message map (atom or string keys) into a validated map with
  string keys.

  Returns `{:ok, message}` or `{:error, reason}`. Non-map input —
  including structs — returns `{:error, :not_a_map}`.
  """
  @spec decode(term()) :: {:ok, map()} | {:error, atom() | {:missing | :invalid, String.t()}}
  def decode(raw) when is_map(raw) and not is_struct(raw) do
    normalised = MapKeys.normalize_keys(raw, :string)

    with {:ok, type} <- fetch_valid_type(normalised),
         {:ok, from} <- fetch_string(normalised, "from"),
         {:ok, payload} <- fetch_map(normalised, "payload"),
         {:ok, signature_version} <- fetch_signature_version(normalised),
         {:ok, signature} <- fetch_string(normalised, "signature"),
         {:ok, timestamp} <- fetch_string(normalised, "timestamp"),
         {:ok, id} <- fetch_string(normalised, "id") do
      message = %{
        "id" => id,
        "type" => type,
        "from" => from,
        "payload" => payload,
        "signature_version" => signature_version,
        "signature" => signature,
        "timestamp" => timestamp
      }

      {:ok, message}
    end
  end

  def decode(_), do: {:error, :not_a_map}

  @doc """
  Verify the signature of a decoded message against a known public key.

  Canonicalizes the complete signed envelope and checks the Ed25519 signature.
  Returns `true` when valid, `false` otherwise (including on encode errors).
  """
  @spec verify_message(map(), binary()) :: boolean()
  def verify_message(message, public_key) when is_map(message) and is_binary(public_key) do
    with {:ok, decoded} <- decode(message),
         {:ok, bytes} <- signing_bytes(decoded) do
      Identity.verify(bytes, decoded["signature"], public_key)
    else
      _error -> false
    end
  end

  def verify_message(_, _), do: false

  @doc """
  Verify an inbound message and canonicalize it to plain JSON data —
  the boundary every receiver must pass raw transport terms through
  before handling them.

  The signature authenticates the canonical envelope, but a validly signed
  payload can still arrive as a BEAM shape that a real JSON transport could
  never produce; clustered PubSub delivers terms verbatim. Steps:

    1. `decode/1` validates and string-normalizes the envelope,
    2. the envelope `type` must equal `expected_type` — receivers
       dispatch on an attacker-chosen transport tag, so without this a
       validly signed "share" could be replayed as a "response",
    3. `fetch_key.(from)` resolves the sender's trusted public key
       (`{:ok, pubkey}` or a passed-through `{:error, reason}`),
    4. the Ed25519 signature is verified over canonical bytes covering
       signature version, id, type, from, timestamp, and payload,
    5. the signed timestamp must fall within the freshness/skew window,
    6. the payload is replaced by its JSON round-trip: atom keys and
       structs collapse into the plain string-keyed data a real wire
       transport would have produced. A payload whose JSON form is not
       an object (e.g. a struct that encodes to a scalar) is rejected
       as `:malformed`.

  Returns `{:ok, message}` with the canonicalized payload, or
  `{:error, reason}`.
  """
  @spec verify_and_normalize(
          term(),
          String.t(),
          (String.t() -> {:ok, binary()} | {:error, term()})
        ) :: {:ok, map()} | {:error, term()}
  def verify_and_normalize(raw, expected_type, fetch_key)
      when is_binary(expected_type) and is_function(fetch_key, 1) do
    with {:ok, decoded} <- decode(raw),
         :ok <- check_expected_type(decoded, expected_type),
         {:ok, pubkey} <- fetch_key.(decoded["from"]),
         {:ok, payload_json} <- encode_payload(decoded["payload"]),
         {:ok, bytes} <- signing_bytes(decoded),
         :ok <- check_envelope_signature(bytes, decoded["signature"], pubkey),
         :ok <- check_timestamp(decoded["timestamp"]) do
      canonicalize_payload(decoded, payload_json)
    end
  end

  defp check_expected_type(%{"type" => type}, type), do: :ok
  defp check_expected_type(_decoded, _expected_type), do: {:error, :type_mismatch}

  defp encode_payload(payload) do
    case Jason.encode(payload) do
      {:ok, payload_json} -> {:ok, payload_json}
      {:error, _} -> {:error, :malformed}
    end
  end

  defp check_envelope_signature(bytes, signature, pubkey) do
    if Identity.verify(bytes, signature, pubkey) do
      :ok
    else
      {:error, :bad_signature}
    end
  end

  defp check_timestamp(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, datetime, _offset} ->
        age = DateTime.diff(DateTime.utc_now(), datetime, :second)

        cond do
          age > @max_message_age_seconds -> {:error, :stale_message}
          age < -@max_future_skew_seconds -> {:error, :future_message}
          true -> :ok
        end

      _invalid ->
        {:error, :malformed_timestamp}
    end
  end

  defp canonicalize_payload(decoded, payload_json) do
    case Jason.decode(payload_json) do
      {:ok, payload} when is_map(payload) -> {:ok, %{decoded | "payload" => payload}}
      _ -> {:error, :malformed}
    end
  end

  @doc false
  @spec signing_bytes(map()) :: {:ok, binary()} | {:error, :malformed}
  def signing_bytes(message) when is_map(message) do
    unsigned =
      Map.take(message, [
        "signature_version",
        "id",
        "type",
        "from",
        "timestamp",
        "payload"
      ])

    with {:ok, json} <- Jason.encode(unsigned),
         {:ok, canonical} <- Jason.decode(json) do
      {:ok, :erlang.term_to_binary(canonical, [:deterministic])}
    else
      _error -> {:error, :malformed}
    end
  end

  def signing_bytes(_message), do: {:error, :malformed}

  defp signing_bytes!(message) do
    case signing_bytes(message) do
      {:ok, bytes} -> bytes
      {:error, :malformed} -> raise ArgumentError, "network message is not JSON-encodable"
    end
  end

  # ---------------------------------------------------------------------------
  # Convenience constructors
  # ---------------------------------------------------------------------------

  @doc """
  Build a `:share` message advertising a solution to peers.

  `solution_map` should be the output of `JidoClaw.Solutions.NetworkFacade.to_wire/1`.
  """
  @spec share_message(map(), Identity.t()) :: map()
  def share_message(solution_map, %{__struct__: Identity} = identity) do
    encode(:share, solution_map, identity)
  end

  @doc """
  Build a `:request` message asking peers for solutions to a problem.

  `opts` may include `:language`, `:framework`, `:limit`, etc.
  """
  @spec request_message(String.t(), keyword(), Identity.t()) :: map()
  def request_message(problem_description, opts \\ [], %{__struct__: Identity} = identity) do
    payload = %{
      "description" => problem_description,
      "opts" => Map.new(opts, fn {k, v} -> {to_string(k), v} end)
    }

    encode(:request, payload, identity)
  end

  @doc """
  Build a `:response` message returning solutions to a requester.

  `solutions` is a list of solution maps. `request_id` ties the response back
  to the originating `:request` message id.
  """
  @spec response_message([map()], String.t(), Identity.t()) :: map()
  def response_message(solutions, request_id, %{__struct__: Identity} = identity)
      when is_list(solutions) and is_binary(request_id) do
    payload = %{
      "solutions" => solutions,
      "request_id" => request_id
    }

    encode(:response, payload, identity)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp generate_id do
    <<a::32, b::16, _::4, c::12, _::2, d::30, e::32>> = :crypto.strong_rand_bytes(16)

    <<a::32, b::16, 4::4, c::12, 2::2, d::30, e::32>>
    |> Base.encode16(case: :lower)
    |> then(fn hex ->
      Enum.join(
        [
          binary_part(hex, 0, 8),
          binary_part(hex, 8, 4),
          binary_part(hex, 12, 4),
          binary_part(hex, 16, 4),
          binary_part(hex, 20, 12)
        ],
        "-"
      )
    end)
  end

  defp utc_now_iso, do: DateTime.to_iso8601(DateTime.utc_now())

  defp normalize_type!(type) when is_atom(type) or is_binary(type) do
    normalized = String.downcase(to_string(type))

    if normalized in @valid_types do
      normalized
    else
      raise ArgumentError, "invalid network message type: #{inspect(type)}"
    end
  end

  defp fetch_valid_type(map) do
    case Map.fetch(map, "type") do
      {:ok, t} when is_binary(t) ->
        t = String.downcase(t)

        if t in @valid_types do
          {:ok, t}
        else
          {:error, :invalid_type}
        end

      {:ok, t} when is_atom(t) ->
        ts = to_string(t)

        if ts in @valid_types do
          {:ok, ts}
        else
          {:error, :invalid_type}
        end

      _ ->
        {:error, :missing_type}
    end
  end

  defp fetch_string(map, key) do
    case Map.fetch(map, key) do
      {:ok, v} when is_binary(v) -> {:ok, v}
      :error -> {:error, {:missing, key}}
      _ -> {:error, {:invalid, key}}
    end
  end

  defp fetch_map(map, key) do
    case Map.fetch(map, key) do
      {:ok, v} when is_map(v) -> {:ok, v}
      :error -> {:ok, %{}}
      _ -> {:error, {:invalid, key}}
    end
  end

  defp fetch_signature_version(map) do
    case Map.fetch(map, "signature_version") do
      {:ok, @signature_version} -> {:ok, @signature_version}
      {:ok, _other} -> {:error, :unsupported_signature_version}
      :error -> {:error, {:missing, "signature_version"}}
    end
  end
end
