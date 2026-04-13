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
      signature: base64 string (Ed25519 over JSON-encoded payload),
      timestamp: ISO-8601 UTC string
    }
  """

  alias JidoClaw.Agent.Identity

  @valid_types ~w(share request response ping pong)

  # ---------------------------------------------------------------------------
  # Core encode / decode
  # ---------------------------------------------------------------------------

  @doc """
  Build a signed message map.

  Encodes `payload` to JSON, signs the JSON bytes with `identity`'s private
  key, then wraps everything with a UUID id and ISO-8601 timestamp.

  Returns a plain map with string keys suitable for JSON serialisation.
  """
  @spec encode(atom() | String.t(), map(), Identity.t()) :: map()
  def encode(type, payload, %{__struct__: Identity} = identity) do
    payload_json = Jason.encode!(payload)
    signature = Identity.sign(payload_json, identity.private_key)

    %{
      "id" => generate_id(),
      "type" => to_string(type),
      "from" => identity.agent_id,
      "payload" => payload,
      "signature" => signature,
      "timestamp" => utc_now_iso()
    }
  end

  @doc """
  Parse a raw message map (atom or string keys) into a validated map with
  string keys.

  Returns `{:ok, message}` or `{:error, reason}`.
  """
  @spec decode(map()) :: {:ok, map()} | {:error, atom()}
  def decode(raw) when is_map(raw) do
    normalised = normalize_keys(raw)

    with {:ok, type} <- fetch_valid_type(normalised),
         {:ok, from} <- fetch_string(normalised, "from"),
         {:ok, payload} <- fetch_map(normalised, "payload"),
         {:ok, signature} <- fetch_string(normalised, "signature"),
         {:ok, timestamp} <- fetch_string(normalised, "timestamp"),
         {:ok, id} <- fetch_string(normalised, "id") do
      message = %{
        "id" => id,
        "type" => type,
        "from" => from,
        "payload" => payload,
        "signature" => signature,
        "timestamp" => timestamp
      }

      {:ok, message}
    end
  end

  def decode(_), do: {:error, :not_a_map}

  @doc """
  Verify the signature of a decoded message against a known public key.

  Re-encodes the payload to JSON and checks the Ed25519 signature.
  Returns `true` when valid, `false` otherwise (including on encode errors).
  """
  @spec verify_message(map(), binary()) :: boolean()
  def verify_message(%{"payload" => payload, "signature" => sig}, public_key)
      when is_map(payload) and is_binary(sig) and is_binary(public_key) do
    case Jason.encode(payload) do
      {:ok, payload_json} -> Identity.verify(payload_json, sig, public_key)
      {:error, _} -> false
    end
  end

  def verify_message(_, _), do: false

  # ---------------------------------------------------------------------------
  # Convenience constructors
  # ---------------------------------------------------------------------------

  @doc """
  Build a `:share` message advertising a solution to peers.

  `solution_map` should be the output of `JidoClaw.Solutions.Solution.to_map/1`.
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
      [
        binary_part(hex, 0, 8),
        binary_part(hex, 8, 4),
        binary_part(hex, 12, 4),
        binary_part(hex, 16, 4),
        binary_part(hex, 20, 12)
      ]
      |> Enum.join("-")
    end)
  end

  defp utc_now_iso, do: DateTime.utc_now() |> DateTime.to_iso8601()

  # Normalise atom or string keys to string keys for uniform access.
  defp normalize_keys(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {to_string(k), v}
      {k, v} -> {k, v}
    end)
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
end
