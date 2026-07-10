defmodule JidoClaw.Network.Node do
  @moduledoc """
  GenServer representing this agent's network presence.

  Manages identity initialisation, PubSub subscription, peer tracking, and
  routing of incoming network messages. All blocking client calls are safe to
  call when the server is not running — they return sensible defaults.

  PubSub topic: `"jido:network"`

  Signals emitted:
    - `jido_claw.network.connected`
    - `jido_claw.network.disconnected`
    - `jido_claw.network.solution_shared`
  """

  use GenServer
  require Logger

  alias JidoClaw.Agent.Identity
  alias JidoClaw.Network.PeerDirectory
  alias JidoClaw.Network.Protocol
  alias JidoClaw.SignalBus
  alias JidoClaw.Solutions.{Matcher, NetworkFacade}
  alias JidoClaw.Solutions.Reputation
  alias JidoClaw.Workspaces.Resolver

  @pubsub JidoClaw.PubSub
  @topic "jido:network"

  defstruct [
    :agent_id,
    :identity,
    :project_dir,
    :tenant_id,
    :workspace_id,
    status: :disconnected,
    peers: MapSet.new(),
    seen_messages: %{},
    relay_url: nil
  ]

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  # `:name` defaults to the module singleton (the client API targets
  # it); tests pass `name: nil` to start an unregistered instance.
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc """
  Initialise the Ed25519 identity for this node, subscribe to the network
  PubSub topic, and transition status to `:connected`.

  Safe to call when server is not running — returns `:ok` immediately.
  """
  @spec connect() :: :ok | {:error, term()}
  def connect do
    case GenServer.whereis(__MODULE__) do
      nil -> :ok
      _pid -> GenServer.call(__MODULE__, :connect)
    end
  end

  @doc """
  Unsubscribe from the network PubSub topic and transition status to
  `:disconnected`.

  Safe to call when server is not running — returns `:ok` immediately.
  """
  @spec disconnect() :: :ok
  def disconnect do
    case GenServer.whereis(__MODULE__) do
      nil -> :ok
      _pid -> GenServer.call(__MODULE__, :disconnect)
    end
  end

  @doc """
  Return a status summary for this node.

  Returns `%{status: atom, agent_id: string | nil, peer_count: integer}`.
  """
  @spec status() :: %{status: atom(), agent_id: String.t() | nil, peer_count: non_neg_integer()}
  def status do
    case GenServer.whereis(__MODULE__) do
      nil -> %{status: :not_running, agent_id: nil, peer_count: 0}
      _pid -> GenServer.call(__MODULE__, :status)
    end
  end

  @doc """
  Return the list of known peer agent IDs.
  """
  @spec peers() :: [String.t()]
  def peers do
    case GenServer.whereis(__MODULE__) do
      nil -> []
      _pid -> GenServer.call(__MODULE__, :peers)
    end
  end

  @doc """
  Broadcast a solution by id to all network peers as a `:share` message.

  Looks up the solution via `JidoClaw.Solutions.NetworkFacade.find_local/2`. If the solution is not
  found or the node is disconnected, returns `{:error, reason}`.
  """
  @spec broadcast_solution(String.t()) :: :ok | {:error, atom()}
  def broadcast_solution(solution_id) when is_binary(solution_id) do
    case GenServer.whereis(__MODULE__) do
      nil -> {:error, :not_running}
      _pid -> GenServer.call(__MODULE__, {:broadcast_solution, solution_id})
    end
  end

  @doc """
  Broadcast a `:request` message asking peers for solutions to a problem.

  Responses arrive asynchronously via PubSub and are stored automatically.
  Returns `:ok` immediately.
  """
  @spec request_solutions(String.t(), keyword()) :: :ok | {:error, atom()}
  def request_solutions(problem_description, opts \\ []) when is_binary(problem_description) do
    case GenServer.whereis(__MODULE__) do
      nil -> {:error, :not_running}
      _pid -> GenServer.call(__MODULE__, {:request_solutions, problem_description, opts})
    end
  end

  # ---------------------------------------------------------------------------
  # Server Callbacks
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    project_dir = Keyword.fetch!(opts, :project_dir)
    relay_url = Keyword.get(opts, :relay_url)

    tenant_id =
      Keyword.get(opts, :tenant_id) || Application.get_env(:jido_claw, :network_tenant) ||
        "default"

    workspace_id =
      Keyword.get(opts, :workspace_id) ||
        case Resolver.ensure_workspace(tenant_id, project_dir) do
          {:ok, %{id: id}} -> id
          _ -> nil
        end

    state = %__MODULE__{
      project_dir: project_dir,
      relay_url: relay_url,
      tenant_id: tenant_id,
      workspace_id: workspace_id
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call(:connect, _from, state) do
    case Identity.init(state.project_dir) do
      {:ok, identity} ->
        :ok = Phoenix.PubSub.subscribe(@pubsub, @topic)

        unless PeerDirectory.configured?() do
          Logger.warning(
            "[Network.Node] No trusted peer keys configured (JIDOCLAW_NETWORK_PEERS) — " <>
              "all inbound network messages will be dropped; outbound sharing still works"
          )
        end

        new_state = %{
          state
          | identity: identity,
            agent_id: identity.agent_id,
            status: :connected
        }

        SignalBus.emit("jido_claw.network.connected", %{agent_id: identity.agent_id})
        Logger.info("[Network.Node] Connected as #{identity.agent_id}")

        {:reply, :ok, new_state}

      {:error, reason} ->
        Logger.warning("[Network.Node] Failed to initialize identity: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  @impl GenServer
  def handle_call(:disconnect, _from, state) do
    if state.status == :connected do
      Phoenix.PubSub.unsubscribe(@pubsub, @topic)
      SignalBus.emit("jido_claw.network.disconnected", %{agent_id: state.agent_id})
      Logger.info("[Network.Node] Disconnected")
    end

    {:reply, :ok, %{state | status: :disconnected}}
  end

  @impl GenServer
  def handle_call(:status, _from, state) do
    result = %{
      status: state.status,
      agent_id: state.agent_id,
      peer_count: MapSet.size(state.peers)
    }

    {:reply, result, state}
  end

  @impl GenServer
  def handle_call(:peers, _from, state) do
    {:reply, MapSet.to_list(state.peers), state}
  end

  @impl GenServer
  def handle_call({:broadcast_solution, solution_id}, _from, state) do
    if state.status != :connected or is_nil(state.identity) do
      {:reply, {:error, :not_connected}, state}
    else
      node_state = node_state(state)

      case NetworkFacade.find_local(solution_id, node_state) do
        {:ok, solution} ->
          solution_map = NetworkFacade.to_wire(solution)
          message = Protocol.share_message(solution_map, state.identity)

          Phoenix.PubSub.broadcast(@pubsub, @topic, {:solution_shared, message})

          SignalBus.emit("jido_claw.network.solution_shared", %{
            solution_id: solution_id,
            agent_id: state.agent_id
          })

          {:reply, :ok, state}

        :not_found ->
          {:reply, {:error, :solution_not_found}, state}
      end
    end
  end

  @impl GenServer
  def handle_call({:request_solutions, description, opts}, _from, state) do
    if state.status != :connected or is_nil(state.identity) do
      {:reply, {:error, :not_connected}, state}
    else
      message = Protocol.request_message(description, opts, state.identity)
      Phoenix.PubSub.broadcast(@pubsub, @topic, {:solution_requested, message})
      {:reply, :ok, state}
    end
  end

  # ---------------------------------------------------------------------------
  # PubSub message handling
  # ---------------------------------------------------------------------------

  @impl GenServer
  def handle_info({:solution_shared, message}, state) do
    # Ignore messages we broadcast ourselves
    if same_agent?(message, state) do
      {:noreply, state}
    else
      {:noreply, verified_dispatch(message, "share", state, &handle_solution_shared/2)}
    end
  end

  @impl GenServer
  def handle_info({:solution_requested, message}, state) do
    if same_agent?(message, state) or state.status != :connected do
      {:noreply, state}
    else
      {:noreply, verified_dispatch(message, "request", state, &handle_solution_requested/2)}
    end
  end

  @impl GenServer
  def handle_info({:solution_response, message}, state) do
    if same_agent?(message, state) do
      {:noreply, state}
    else
      {:noreply, verified_dispatch(message, "response", state, &handle_solution_response/2)}
    end
  end

  @impl GenServer
  def handle_info(_msg, state), do: {:noreply, state}

  # Run `handler` only when the message passes the protocol boundary
  # (Protocol.verify_and_normalize/3): envelope decode + validation,
  # expected-type assertion (Node dispatches on the attacker-chosen
  # PubSub tuple tag, so a peer's validly signed "share" could
  # otherwise be re-wrapped as a response), trusted-peer signature
  # verification, and payload canonicalization to plain JSON data —
  # clustered PubSub delivers raw BEAM terms, so without the round-trip
  # handlers would consume atom keys/structs/tuples that JSON decoding
  # could never produce. Otherwise log and drop — no store, no response
  # broadcast, no add_peer, no Reputation.record_share.
  #
  defp verified_dispatch(message, expected_type, state, handler) do
    case Protocol.verify_and_normalize(message, expected_type, &fetch_peer_key/1) do
      {:ok, canonical} ->
        replay_key = {canonical["from"], canonical["id"]}

        if seen_message?(state, replay_key) do
          state
        else
          canonical
          |> handler.(state)
          |> remember_message(replay_key)
        end

      {:error, reason} ->
        log_drop(reason, expected_type, message)
        state
    end
  end

  @seen_message_limit 10_000
  @seen_message_ttl_ms 5 * 60 * 1_000

  defp seen_message?(state, {from, id}) when is_binary(from) and is_binary(id),
    do: Map.has_key?(state.seen_messages, {from, id})

  defp seen_message?(_state, _key), do: true

  defp remember_message(state, replay_key) do
    now = System.monotonic_time(:millisecond)

    seen =
      state.seen_messages
      |> Enum.reject(fn {_message_id, received_at} ->
        now - received_at > @seen_message_ttl_ms
      end)
      |> Map.new()
      |> Map.put(replay_key, now)
      |> trim_seen_messages()

    %{state | seen_messages: seen}
  end

  defp trim_seen_messages(seen) when map_size(seen) <= @seen_message_limit, do: seen

  defp trim_seen_messages(seen) do
    {oldest_id, _received_at} = Enum.min_by(seen, &elem(&1, 1))
    Map.delete(seen, oldest_id)
  end

  defp log_drop(:bad_signature, expected_type, message) do
    Logger.warning(
      "[Network.Node] Dropped #{expected_type} message with invalid signature " <>
        "from #{inspect(message_from(message))}"
    )
  end

  # Unknown-peer drops log at debug — on a shared segment every
  # unconfigured neighbour produces these, and warning-level would be
  # pure noise.
  defp log_drop(reason, expected_type, message) do
    Logger.debug(
      "[Network.Node] Dropped #{expected_type} message (#{inspect(reason)}) " <>
        "from #{inspect(message_from(message))}"
    )
  end

  # `:malformed` drops can carry any term — Access syntax
  # (`message["from"]`) on non-maps raises, taking the Node down
  # mid-log.
  defp message_from(message) when is_map(message), do: Map.get(message, "from")
  defp message_from(_), do: nil

  # ---------------------------------------------------------------------------
  # Message handlers
  # ---------------------------------------------------------------------------

  # Only called with the canonical message from verify_and_normalize/3
  # — "from" is a binary and "payload" is a plain JSON map, so the
  # hard match cannot fail.
  defp handle_solution_shared(message, state) do
    %{"payload" => payload, "from" => from} = message

    case store_received_solution(payload, from, state) do
      {:ok, solution} ->
        Logger.debug("[Network.Node] Stored shared solution #{solution.id} from #{from}")

      {:error, reason} ->
        Logger.debug("[Network.Node] Could not store shared solution: #{inspect(reason)}")
    end

    add_peer(state, message)
  end

  defp handle_solution_requested(message, state) do
    case message do
      # `request_id` is signed as the envelope "id", but its sender-selected
      # shape still needs a binary guard before Protocol.response_message/3.
      %{"payload" => %{"description" => description}, "id" => request_id, "from" => from}
      when is_binary(description) and is_binary(request_id) ->
        opts = sanitize_request_opts(get_in(message, ["payload", "opts"]))

        # Thread the node's tenant + workspace into Matcher so cross-
        # tenant rows are not exposed via network responses. Scope opts
        # first: sanitize_request_opts/1 only emits disjoint keys, but
        # if the whitelist ever grows an overlap, first occurrence wins
        # in Keyword lookups.
        scope_opts = [
          tenant_id: state.tenant_id,
          workspace_id: state.workspace_id,
          local_visibility: [:local, :shared, :public],
          cross_workspace_visibility: [:public]
        ]

        solutions = Matcher.find_solutions(description, scope_opts ++ opts)

        if solutions != [] and not is_nil(state.identity) do
          solution_maps = Enum.map(solutions, fn %{solution: s} -> NetworkFacade.to_wire(s) end)
          response = Protocol.response_message(solution_maps, request_id, state.identity)

          Logger.debug(
            "[Network.Node] Responding to request #{request_id} from #{from} with #{length(solution_maps)} solutions"
          )

          Phoenix.PubSub.broadcast(@pubsub, @topic, {:solution_response, response})
        end

      _ ->
        :ok
    end

    add_peer(state, message)
  end

  defp handle_solution_response(message, state) do
    node_state = node_state(state)

    with %{"payload" => %{"solutions" => solutions, "request_id" => _req_id}, "from" => from} <-
           message,
         true <- is_list(solutions) do
      Enum.each(solutions, fn
        solution_map when is_map(solution_map) ->
          case NetworkFacade.store_inbound(solution_map, from, node_state) do
            {:ok, solution} ->
              Logger.debug("[Network.Node] Stored response solution #{solution.id} from #{from}")
              Reputation.record_share(state.tenant_id, from)

            {:error, reason} ->
              Logger.debug("[Network.Node] Could not store response solution: #{inspect(reason)}")
          end

        other ->
          # Entries are canonical JSON values after the boundary, but
          # their shape is still sender-chosen — the signature covers
          # the payload as a whole, not each "solutions" entry.
          Logger.debug(
            "[Network.Node] Skipped non-map response solution entry from #{from}: #{inspect(other)}"
          )
      end)
    else
      _ -> :ok
    end

    add_peer(state, message)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp same_agent?(%{"from" => from}, %{agent_id: agent_id}) when is_binary(agent_id),
    do: from == agent_id

  defp same_agent?(_, _), do: false

  defp fetch_peer_key(from) do
    case PeerDirectory.fetch(from) do
      {:ok, pubkey} -> {:ok, pubkey}
      :error -> {:error, :unknown_peer}
    end
  end

  # Peer-supplied request opts stay untrusted even when the signature
  # verifies (the peer's software may be buggy or hostile). Whitelist
  # known Matcher/Fingerprint options with valid value types and drop
  # everything else — scope keys (tenant/workspace/visibility) can never
  # be injected, non-binary values can't reach Fingerprint.signature/3,
  # and limit is clamped (Matcher's own default is 5).
  @max_request_limit 25

  defp sanitize_request_opts(opts) when is_map(opts) do
    Enum.flat_map(opts, fn
      {"language", v} when is_binary(v) -> [language: v]
      {"framework", v} when is_binary(v) -> [framework: v]
      {"error_class", v} when is_binary(v) -> [error_class: v]
      {"limit", v} when is_integer(v) and v > 0 -> [limit: min(v, @max_request_limit)]
      {"threshold", v} when is_number(v) -> [threshold: v]
      _ -> []
    end)
  end

  defp sanitize_request_opts(_), do: []

  defp store_received_solution(payload, from, state) when is_map(payload) do
    case NetworkFacade.store_inbound(payload, from, node_state(state)) do
      {:ok, solution} ->
        Reputation.record_share(state.tenant_id, from)
        {:ok, solution}

      other ->
        other
    end
  end

  defp node_state(state) do
    %{tenant_id: state.tenant_id, workspace_id: state.workspace_id}
  end

  defp add_peer(state, %{"from" => from}) when is_binary(from) do
    %{state | peers: MapSet.put(state.peers, from)}
  end

  defp add_peer(state, _), do: state
end
