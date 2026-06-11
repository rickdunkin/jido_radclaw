defmodule JidoClaw.Network.NodeTest do
  # async: false — mutates the :network_peer_keys app env and relies on
  # the shared sandbox mode so the supervised Node transparently shares
  # the test's DB connection.
  use JidoClaw.SolutionsCase, async: false

  import ExUnit.CaptureLog

  alias JidoClaw.Agent.Identity
  alias JidoClaw.Network
  alias JidoClaw.Network.Protocol
  alias JidoClaw.Repo

  @moduletag :tmp_dir

  @topic "jido:network"
  @pubsub JidoClaw.PubSub

  # An isolated supervised Node instance with explicit tenant/workspace
  # opts (bypassing Resolver.ensure_workspace) — the app singleton booted
  # against project_dir()-resolved scope that doesn't exist in the
  # per-test sandbox, so its writes couldn't be asserted against
  # test-seeded rows. A per-test tmp `project_dir` because `:connect`
  # writes `.jido/identity.json`.
  setup context do
    tenant_id = unique_tenant_id()
    ws = workspace_fixture(tenant_id)

    node =
      start_supervised!(
        {Network.Node,
         name: nil, project_dir: context.tmp_dir, tenant_id: tenant_id, workspace_id: ws.id}
      )

    %{tenant_id: tenant_id, ws: ws, node: node, peer: peer_identity()}
  end

  defp peer_identity do
    {pub, priv} = Identity.generate_keypair()

    %Identity{
      agent_id: Identity.derive_agent_id(pub),
      public_key: pub,
      private_key: priv,
      created_at: DateTime.to_iso8601(DateTime.utc_now())
    }
  end

  defp set_peer_keys(keys_b64) do
    original = Application.fetch_env(:jido_claw, :network_peer_keys)
    Application.put_env(:jido_claw, :network_peer_keys, keys_b64)

    on_exit(fn ->
      case original do
        {:ok, value} -> Application.put_env(:jido_claw, :network_peer_keys, value)
        :error -> Application.delete_env(:jido_claw, :network_peer_keys)
      end
    end)
  end

  defp trust_peer(%Identity{public_key: pub}), do: set_peer_keys([Base.encode64(pub)])

  # Sending then calling gives a processed-mailbox barrier: the call
  # reply proves the prior info message was handled (and that the
  # process survived it).
  defp deliver(node, tagged_message) do
    send(node, tagged_message)
    GenServer.call(node, :status)
  end

  defp hostile_share_payload do
    sig =
      Base.encode16(:crypto.hash(:sha256, "sig-#{System.unique_integer([:positive])}"),
        case: :lower
      )

    %{
      "problem_signature" => sig,
      "solution_content" => "use GenServer for stateful network handling",
      "language" => "elixir",
      "tags" => ["network"],
      "trust_score" => 0.9,
      "verification" => %{"status" => "passed"}
    }
  end

  defp solution_count(tenant_id) do
    {:ok, %{rows: [[count]]}} =
      Repo.query("SELECT COUNT(*) FROM solutions WHERE tenant_id = $1", [tenant_id])

    count
  end

  describe ":solution_shared gating" do
    test "stores a trusted peer's signed share — with locally-defaulted trust", ctx do
      trust_peer(ctx.peer)

      message = Protocol.share_message(hostile_share_payload(), ctx.peer)
      status = deliver(ctx.node, {:solution_shared, message})

      assert status.peer_count == 1

      {:ok, [solution]} = Solution.list(tenant: ctx.tenant_id, actor: actor_for(ctx.tenant_id))
      assert solution.sharing == :shared
      assert solution.agent_id == ctx.peer.agent_id
      assert solution.workspace_id == ctx.ws.id
      # H6 tie-in: the peer-asserted trust_score/verification were stripped.
      assert solution.trust_score == 0.0
      assert solution.verification == %{}
    end

    test "drops a validly signed share from an unknown peer", ctx do
      set_peer_keys([])

      message = Protocol.share_message(hostile_share_payload(), ctx.peer)
      status = deliver(ctx.node, {:solution_shared, message})

      assert status.peer_count == 0
      assert solution_count(ctx.tenant_id) == 0
    end

    test "drops a tampered payload from a trusted peer with a warning", ctx do
      trust_peer(ctx.peer)

      message =
        hostile_share_payload()
        |> Protocol.share_message(ctx.peer)
        |> put_in(["payload", "solution_content"], "tampered content")

      log = capture_log(fn -> deliver(ctx.node, {:solution_shared, message}) end)

      assert log =~ "invalid signature"
      assert solution_count(ctx.tenant_id) == 0
      assert GenServer.call(ctx.node, :status).peer_count == 0
    end

    test "drops a signed share re-wrapped as a response (cross-type replay)", ctx do
      trust_peer(ctx.peer)

      share = Protocol.share_message(hostile_share_payload(), ctx.peer)
      status = deliver(ctx.node, {:solution_response, share})

      assert status.peer_count == 0
      assert solution_count(ctx.tenant_id) == 0
    end

    test "drops a share whose signed payload is a struct", ctx do
      trust_peer(ctx.peer)

      # A struct is a map, Jason-encodes, and signs/verifies fine — but
      # its JSON form is a scalar, so canonicalization rejects it.
      # Pre-fix it sailed through to the facade and crashed
      # MapKeys.normalize_keys/3 (struct-excluding guard).
      message = Protocol.share_message(DateTime.utc_now(), ctx.peer)
      status = deliver(ctx.node, {:solution_shared, message})

      assert status.peer_count == 0
      assert solution_count(ctx.tenant_id) == 0
    end
  end

  describe ":solution_requested gating" do
    test "responds to a trusted peer's signed request", ctx do
      trust_peer(ctx.peer)
      :ok = GenServer.call(ctx.node, :connect)
      :ok = Phoenix.PubSub.subscribe(@pubsub, @topic)

      solution_fixture(ctx.tenant_id, ctx.ws.id, "genserver timeout retry deadline handling",
        sharing: :shared
      )

      request =
        Protocol.request_message("genserver timeout retry deadline handling", [], ctx.peer)

      send(ctx.node, {:solution_requested, request})

      assert_receive {:solution_response, response}, 2_000
      assert response["payload"]["request_id"] == request["id"]
      assert [solution_map | _] = response["payload"]["solutions"]
      assert solution_map["solution_content"] =~ "genserver timeout"
      # to_wire/1 no longer transmits trust fields.
      refute Map.has_key?(solution_map, "trust_score")
      refute Map.has_key?(solution_map, "verification")
    end

    test "ignores a request from an unknown peer", ctx do
      set_peer_keys([])

      capture_log(fn -> :ok = GenServer.call(ctx.node, :connect) end)
      :ok = Phoenix.PubSub.subscribe(@pubsub, @topic)

      solution_fixture(ctx.tenant_id, ctx.ws.id, "genserver timeout retry deadline handling",
        sharing: :shared
      )

      request =
        Protocol.request_message("genserver timeout retry deadline handling", [], ctx.peer)

      deliver(ctx.node, {:solution_requested, request})

      refute_receive {:solution_response, _}, 300
    end

    test "survives a trusted request whose opts carry non-string keys", ctx do
      trust_peer(ctx.peer)
      :ok = GenServer.call(ctx.node, :connect)

      # Atom keys crash String.to_existing_atom/1 with FunctionClauseError
      # (which the old ArgumentError rescue missed).
      payload = %{
        "description" => "genserver timeout",
        "opts" => %{limit: 3, weird_key: "x"}
      }

      request = Protocol.encode(:request, payload, ctx.peer)
      status = deliver(ctx.node, {:solution_requested, request})

      assert status.status == :connected
    end

    test "sanitizes hostile opts values and still responds", ctx do
      trust_peer(ctx.peer)
      :ok = GenServer.call(ctx.node, :connect)
      :ok = Phoenix.PubSub.subscribe(@pubsub, @topic)

      solution_fixture(ctx.tenant_id, ctx.ws.id, "genserver timeout retry deadline handling",
        sharing: :shared
      )

      payload = %{
        "description" => "genserver timeout retry deadline handling",
        "opts" => %{"language" => :elixir, "limit" => "wat", "threshold" => "high"}
      }

      request = Protocol.encode(:request, payload, ctx.peer)
      send(ctx.node, {:solution_requested, request})

      assert_receive {:solution_response, _response}, 2_000
    end
  end

  describe ":solution_response gating" do
    test "stores response solutions from a trusted peer", ctx do
      trust_peer(ctx.peer)

      response = Protocol.response_message([hostile_share_payload()], "req-123", ctx.peer)
      status = deliver(ctx.node, {:solution_response, response})

      assert status.peer_count == 1
      assert solution_count(ctx.tenant_id) == 1
    end

    test "drops response solutions from an unknown peer", ctx do
      set_peer_keys([])

      response = Protocol.response_message([hostile_share_payload()], "req-123", ctx.peer)
      status = deliver(ctx.node, {:solution_response, response})

      assert status.peer_count == 0
      assert solution_count(ctx.tenant_id) == 0
    end

    test "skips non-map response entries from a trusted peer and stores the valid ones", ctx do
      trust_peer(ctx.peer)

      # The signature covers the payload map as a whole — individual
      # "solutions" entries are not shape-checked by verification, so a
      # trusted peer can sign garbage entries. Pre-fix the first one
      # crashed the node via a store_inbound FunctionClauseError.
      entries = [42, "junk", [1, 2], hostile_share_payload()]
      response = Protocol.response_message(entries, "req-123", ctx.peer)
      status = deliver(ctx.node, {:solution_response, response})

      assert status.peer_count == 1
      assert solution_count(ctx.tenant_id) == 1
    end

    test "skips struct response entries from a trusted peer", ctx do
      trust_peer(ctx.peer)

      # Structs satisfy is_map and Jason-encode, so they sign and
      # verify — canonicalization collapses this one to its JSON form
      # (an ISO-8601 string), which the non-map entry skip drops.
      # Pre-fix the struct reached MapKeys.normalize_keys/3 and crashed
      # the node.
      response = Protocol.response_message([DateTime.utc_now()], "req-123", ctx.peer)
      status = deliver(ctx.node, {:solution_response, response})

      assert status.peer_count == 1
      assert solution_count(ctx.tenant_id) == 0
    end
  end

  describe "agent_id spoof resistance (P1)" do
    # An atom-keyed :agent_id wins MapKeys.normalize_keys collisions
    # inside the facade, so pre-fix it beat the node's string-keyed
    # attribution overwrite and the spoofed id was stored.
    test "a trusted peer cannot attribute a shared solution to another agent", ctx do
      trust_peer(ctx.peer)

      payload = Map.put(hostile_share_payload(), :agent_id, "agent-someone-else")
      message = Protocol.share_message(payload, ctx.peer)
      deliver(ctx.node, {:solution_shared, message})

      {:ok, [solution]} = Solution.list(tenant: ctx.tenant_id, actor: actor_for(ctx.tenant_id))
      assert solution.agent_id == ctx.peer.agent_id
    end

    test "a trusted peer cannot attribute a response solution to another agent", ctx do
      trust_peer(ctx.peer)

      payload = Map.put(hostile_share_payload(), :agent_id, "agent-someone-else")
      response = Protocol.response_message([payload], "req-123", ctx.peer)
      deliver(ctx.node, {:solution_response, response})

      {:ok, [solution]} = Solution.list(tenant: ctx.tenant_id, actor: actor_for(ctx.tenant_id))
      assert solution.agent_id == ctx.peer.agent_id
    end
  end

  describe "malformed message handling" do
    # The drop path logs at debug while every env pins the global level
    # at :warning — the pre-fix crash (`message["from"]` on a non-map)
    # sat inside that debug interpolation, so the module level must be
    # raised for the regression to bite.
    test "survives non-map messages on all three inbound paths", ctx do
      # Connect so {:solution_requested, _} reaches verified_dispatch
      # instead of short-circuiting on status != :connected.
      capture_log(fn -> :ok = GenServer.call(ctx.node, :connect) end)

      Logger.put_module_level(Network.Node, :all)
      on_exit(fn -> Logger.delete_module_level(Network.Node) end)

      log =
        capture_log([level: :debug], fn ->
          for message <- [
                :not_a_map,
                [1, 2, 3],
                "binary",
                42,
                {:nested, :tuple},
                DateTime.utc_now()
              ],
              tag <- [:solution_shared, :solution_response, :solution_requested] do
            # The call barrier inside deliver/2 proves survival —
            # pre-fix the GenServer dies and the call exits.
            assert %{status: :connected} = deliver(ctx.node, {tag, message})
          end
        end)

      assert log =~ "(:not_a_map) from nil"
      assert solution_count(ctx.tenant_id) == 0
    end
  end
end
