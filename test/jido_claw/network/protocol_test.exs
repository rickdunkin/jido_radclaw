defmodule JidoClaw.Network.ProtocolTest do
  use ExUnit.Case, async: true

  alias JidoClaw.Agent.Identity
  alias JidoClaw.Network.Protocol

  # ---------------------------------------------------------------------------
  # Setup — generate a fresh Ed25519 keypair for each test
  # ---------------------------------------------------------------------------

  setup do
    {pub, priv} = Identity.generate_keypair()
    agent_id = Identity.derive_agent_id(pub)

    identity = %Identity{
      agent_id: agent_id,
      public_key: pub,
      private_key: priv,
      created_at: DateTime.to_iso8601(DateTime.utc_now())
    }

    {:ok, identity: identity, pub: pub, priv: priv}
  end

  # ---------------------------------------------------------------------------
  # encode/3
  # ---------------------------------------------------------------------------

  describe "encode/3" do
    test "should return a map with all required fields", %{identity: identity} do
      message = Protocol.encode(:share, %{"key" => "value"}, identity)

      assert is_map(message)
      assert Map.has_key?(message, "id")
      assert Map.has_key?(message, "type")
      assert Map.has_key?(message, "from")
      assert Map.has_key?(message, "payload")
      assert Map.has_key?(message, "signature")
      assert Map.has_key?(message, "timestamp")
    end

    test "should set type to the stringified atom", %{identity: identity} do
      message = Protocol.encode(:share, %{}, identity)
      assert message["type"] == "share"
    end

    test "should set from to the identity's agent_id", %{identity: identity} do
      message = Protocol.encode(:request, %{}, identity)
      assert message["from"] == identity.agent_id
    end

    test "should embed the payload map in the message", %{identity: identity} do
      payload = %{"problem" => "how to GenServer", "lang" => "elixir"}
      message = Protocol.encode(:share, payload, identity)
      assert message["payload"] == payload
    end

    test "should sign the payload with the identity's private key", %{identity: identity} do
      payload = %{"content" => "abc"}
      message = Protocol.encode(:share, payload, identity)

      payload_json = Jason.encode!(payload)
      assert Identity.verify(payload_json, message["signature"], identity.public_key)
    end

    test "should produce a UUID-formatted id", %{identity: identity} do
      message = Protocol.encode(:ping, %{}, identity)
      id = message["id"]

      assert is_binary(id)
      # UUID format: 8-4-4-4-12 hex characters separated by dashes
      assert String.match?(
               id,
               ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[0-9a-f]{4}-[0-9a-f]{12}$/
             )
    end

    test "should produce a unique id for each call", %{identity: identity} do
      m1 = Protocol.encode(:ping, %{}, identity)
      m2 = Protocol.encode(:ping, %{}, identity)

      refute m1["id"] == m2["id"]
    end

    test "should produce an ISO 8601 timestamp", %{identity: identity} do
      message = Protocol.encode(:pong, %{}, identity)
      ts = message["timestamp"]

      assert is_binary(ts)
      assert {:ok, _, _} = DateTime.from_iso8601(ts)
    end

    test "should accept a string type as well as atom", %{identity: identity} do
      message = Protocol.encode("response", %{}, identity)
      assert message["type"] == "response"
    end
  end

  # ---------------------------------------------------------------------------
  # decode/1
  # ---------------------------------------------------------------------------

  describe "decode/1" do
    test "should parse a valid message map with string keys", %{identity: identity} do
      encoded = Protocol.encode(:share, %{"data" => 1}, identity)

      assert {:ok, decoded} = Protocol.decode(encoded)
      assert decoded["type"] == "share"
      assert decoded["from"] == identity.agent_id
    end

    test "should handle atom keys by normalising them to string keys", %{identity: identity} do
      encoded = Protocol.encode(:request, %{"q" => "hello"}, identity)

      atom_keyed = %{
        id: encoded["id"],
        type: encoded["type"],
        from: encoded["from"],
        payload: encoded["payload"],
        signature: encoded["signature"],
        timestamp: encoded["timestamp"]
      }

      assert {:ok, decoded} = Protocol.decode(atom_keyed)
      assert decoded["type"] == "request"
      assert decoded["from"] == encoded["from"]
    end

    test "should return {:error, :invalid_type} for unknown message type",
         %{identity: identity} do
      encoded = Protocol.encode(:share, %{}, identity)
      bad = Map.put(encoded, "type", "unknown_type")

      assert {:error, :invalid_type} = Protocol.decode(bad)
    end

    test "should return {:error, :missing_type} when type key is absent",
         %{identity: identity} do
      encoded = Protocol.encode(:share, %{}, identity)
      bad = Map.delete(encoded, "type")

      assert {:error, :missing_type} = Protocol.decode(bad)
    end

    test "should return error when 'from' field is missing", %{identity: identity} do
      encoded = Protocol.encode(:share, %{}, identity)
      bad = Map.delete(encoded, "from")

      assert {:error, _reason} = Protocol.decode(bad)
    end

    test "should return error when 'signature' field is missing", %{identity: identity} do
      encoded = Protocol.encode(:share, %{}, identity)
      bad = Map.delete(encoded, "signature")

      assert {:error, _reason} = Protocol.decode(bad)
    end

    test "should return error when 'timestamp' field is missing", %{identity: identity} do
      encoded = Protocol.encode(:share, %{}, identity)
      bad = Map.delete(encoded, "timestamp")

      assert {:error, _reason} = Protocol.decode(bad)
    end

    test "should return error when 'id' field is missing", %{identity: identity} do
      encoded = Protocol.encode(:share, %{}, identity)
      bad = Map.delete(encoded, "id")

      assert {:error, _reason} = Protocol.decode(bad)
    end

    test "should return {:error, :not_a_map} for non-map input" do
      assert {:error, :not_a_map} = Protocol.decode("not a map")
      assert {:error, :not_a_map} = Protocol.decode(42)
      assert {:error, :not_a_map} = Protocol.decode(nil)
      assert {:error, :not_a_map} = Protocol.decode([:list])
    end

    test "should return {:error, :not_a_map} for a struct envelope" do
      # Structs satisfy is_map but would crash MapKeys.normalize_keys/2.
      assert {:error, :not_a_map} = Protocol.decode(DateTime.utc_now())
    end

    test "should default missing payload to empty map", %{identity: identity} do
      encoded = Protocol.encode(:ping, %{}, identity)
      no_payload = Map.delete(encoded, "payload")

      assert {:ok, decoded} = Protocol.decode(no_payload)
      assert decoded["payload"] == %{}
    end

    test "should accept all valid type strings", %{identity: identity} do
      for type <- ~w(share request response ping pong) do
        encoded = Protocol.encode(type, %{}, identity)
        assert {:ok, decoded} = Protocol.decode(encoded)
        assert decoded["type"] == type
      end
    end
  end

  # ---------------------------------------------------------------------------
  # verify_message/2
  # ---------------------------------------------------------------------------

  describe "verify_message/2" do
    test "should return true for a message with a valid signature", %{
      identity: identity,
      pub: pub
    } do
      message = Protocol.encode(:share, %{"solution" => "use GenServer"}, identity)

      assert Protocol.verify_message(message, pub) == true
    end

    test "should return false for a tampered payload", %{identity: identity, pub: pub} do
      message = Protocol.encode(:share, %{"original" => "content"}, identity)
      tampered = Map.put(message, "payload", %{"tampered" => "payload"})

      assert Protocol.verify_message(tampered, pub) == false
    end

    test "should return false when the wrong public key is used", %{identity: identity} do
      message = Protocol.encode(:share, %{"data" => "value"}, identity)

      {wrong_pub, _} = Identity.generate_keypair()
      assert Protocol.verify_message(message, wrong_pub) == false
    end

    test "should return false for a corrupted signature", %{identity: identity, pub: pub} do
      message = Protocol.encode(:share, %{"data" => "value"}, identity)
      corrupted = Map.put(message, "signature", "aW52YWxpZHNpZ25hdHVyZQ==")

      assert Protocol.verify_message(corrupted, pub) == false
    end

    test "should return false when called with non-map or missing fields" do
      assert Protocol.verify_message(%{}, <<0::32>>) == false
      assert Protocol.verify_message("not a map", <<0::32>>) == false
    end
  end

  # ---------------------------------------------------------------------------
  # verify_and_normalize/3
  # ---------------------------------------------------------------------------

  describe "verify_and_normalize/3" do
    test "should canonicalize a signed atom-keyed payload to plain JSON data", %{
      identity: identity,
      pub: pub
    } do
      payload = %{agent_id: "spoof", nested: %{deep: 1}, list: [%{a: 1}]}
      message = Protocol.encode(:share, payload, identity)

      assert {:ok, canonical} =
               Protocol.verify_and_normalize(message, "share", fn _ -> {:ok, pub} end)

      assert canonical["from"] == identity.agent_id

      assert canonical["payload"] == %{
               "agent_id" => "spoof",
               "nested" => %{"deep" => 1},
               "list" => [%{"a" => 1}]
             }
    end

    test "should pass the decoded from to the key fetcher", %{identity: identity, pub: pub} do
      message = Protocol.share_message(%{"a" => 1}, identity)
      expected_from = identity.agent_id

      assert {:ok, _} =
               Protocol.verify_and_normalize(message, "share", fn from ->
                 assert from == expected_from
                 {:ok, pub}
               end)
    end

    test "should reject a signed struct payload whose JSON form is not an object", %{
      identity: identity,
      pub: pub
    } do
      # DateTime is a map, Jason-encodes (to a string), and signs fine —
      # but its JSON form is a scalar, not an object.
      message = Protocol.share_message(DateTime.utc_now(), identity)

      assert {:error, :malformed} =
               Protocol.verify_and_normalize(message, "share", fn _ -> {:ok, pub} end)
    end

    test "should reject a handcrafted payload that cannot encode to JSON", %{
      identity: identity,
      pub: pub
    } do
      # A reference has no Jason.Encoder impl — Jason.encode returns an
      # error tuple (it does not raise), which the boundary maps to
      # :malformed.
      message =
        %{Protocol.share_message(%{"a" => 1}, identity) | "payload" => %{"a" => make_ref()}}

      assert {:error, :malformed} =
               Protocol.verify_and_normalize(message, "share", fn _ -> {:ok, pub} end)
    end

    test "should reject a handcrafted tuple-bearing payload", %{identity: identity, pub: pub} do
      # Tuples ARE Jason-encodable in this project (tentacat ships a
      # Jason.Encoder impl for Tuple), so this re-encodes to bytes that
      # differ from the signed ones and dies at the signature check
      # instead of the encode step. If that impl ever disappears, the
      # reason flips to :malformed — either way the message is dropped
      # without crashing.
      message = %{Protocol.share_message(%{"a" => 1}, identity) | "payload" => %{"a" => {:t, 1}}}

      assert {:error, :bad_signature} =
               Protocol.verify_and_normalize(message, "share", fn _ -> {:ok, pub} end)
    end

    test "should reject a type mismatch (cross-type replay)", %{identity: identity, pub: pub} do
      message = Protocol.share_message(%{"a" => 1}, identity)

      assert {:error, :type_mismatch} =
               Protocol.verify_and_normalize(message, "response", fn _ -> {:ok, pub} end)
    end

    test "should propagate the key fetcher's error without verifying", %{identity: identity} do
      message = Protocol.share_message(%{"a" => 1}, identity)

      assert {:error, :unknown_peer} =
               Protocol.verify_and_normalize(message, "share", fn _ -> {:error, :unknown_peer} end)
    end

    test "should reject a tampered payload as :bad_signature", %{identity: identity, pub: pub} do
      message = %{Protocol.share_message(%{"a" => 1}, identity) | "payload" => %{"a" => 2}}

      assert {:error, :bad_signature} =
               Protocol.verify_and_normalize(message, "share", fn _ -> {:ok, pub} end)
    end

    test "should reject non-map and struct envelopes before key lookup" do
      fetch_key = fn _ -> flunk("key fetcher must not be called") end

      assert {:error, :not_a_map} = Protocol.verify_and_normalize(42, "share", fetch_key)

      assert {:error, :not_a_map} =
               Protocol.verify_and_normalize(DateTime.utc_now(), "share", fetch_key)
    end
  end

  # ---------------------------------------------------------------------------
  # share_message/2
  # ---------------------------------------------------------------------------

  describe "share_message/2" do
    test "should create a message with type 'share'", %{identity: identity} do
      solution_map = %{"solution_content" => "use Task.async", "language" => "elixir"}
      message = Protocol.share_message(solution_map, identity)

      assert message["type"] == "share"
    end

    test "should embed the solution map as the payload", %{identity: identity} do
      solution_map = %{"solution_content" => "use Task.async", "language" => "elixir"}
      message = Protocol.share_message(solution_map, identity)

      assert message["payload"] == solution_map
    end

    test "should be verifiable with the identity's public key", %{identity: identity, pub: pub} do
      message = Protocol.share_message(%{"code" => "hello"}, identity)

      assert Protocol.verify_message(message, pub) == true
    end
  end

  # ---------------------------------------------------------------------------
  # request_message/3
  # ---------------------------------------------------------------------------

  describe "request_message/3" do
    test "should create a message with type 'request'", %{identity: identity} do
      message = Protocol.request_message("how to handle GenServer crash", [], identity)

      assert message["type"] == "request"
    end

    test "should include description in payload", %{identity: identity} do
      desc = "how to implement ETS caching"
      message = Protocol.request_message(desc, [], identity)

      assert message["payload"]["description"] == desc
    end

    test "should include opts in payload as string-keyed map", %{identity: identity} do
      message = Protocol.request_message("problem", [language: "elixir", limit: 3], identity)
      opts = message["payload"]["opts"]

      assert opts["language"] == "elixir"
      assert opts["limit"] == 3
    end

    test "should produce an empty opts map when no opts are given", %{identity: identity} do
      message = Protocol.request_message("problem", [], identity)

      assert message["payload"]["opts"] == %{}
    end

    test "should be verifiable with the identity's public key", %{identity: identity, pub: pub} do
      message = Protocol.request_message("test problem", [], identity)

      assert Protocol.verify_message(message, pub) == true
    end
  end

  # ---------------------------------------------------------------------------
  # response_message/3
  # ---------------------------------------------------------------------------

  describe "response_message/3" do
    test "should create a message with type 'response'", %{identity: identity} do
      message = Protocol.response_message([], "req-id-abc", identity)

      assert message["type"] == "response"
    end

    test "should include solutions list in payload", %{identity: identity} do
      solutions = [%{"language" => "elixir", "content" => "def hello, do: :ok"}]
      message = Protocol.response_message(solutions, "req-id-abc", identity)

      assert message["payload"]["solutions"] == solutions
    end

    test "should include request_id in payload", %{identity: identity} do
      request_id = "original-request-uuid-1234"
      message = Protocol.response_message([], request_id, identity)

      assert message["payload"]["request_id"] == request_id
    end

    test "should be verifiable with the identity's public key", %{identity: identity, pub: pub} do
      message = Protocol.response_message([], "req-id", identity)

      assert Protocol.verify_message(message, pub) == true
    end

    test "should handle an empty solutions list", %{identity: identity} do
      message = Protocol.response_message([], "req-id", identity)

      assert message["payload"]["solutions"] == []
    end

    test "should handle multiple solutions in the list", %{identity: identity} do
      solutions = [
        %{"language" => "elixir", "content" => "use GenServer"},
        %{"language" => "elixir", "content" => "use Agent"}
      ]

      message = Protocol.response_message(solutions, "req-id", identity)
      assert [_, _] = message["payload"]["solutions"]
    end
  end
end
