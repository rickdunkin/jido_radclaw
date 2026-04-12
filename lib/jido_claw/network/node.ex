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
  alias JidoClaw.SignalBus
  alias JidoClaw.Network.Protocol
  alias JidoClaw.Solutions.{Matcher, Solution, Store}

  @pubsub JidoClaw.PubSub
  @topic "jido:network"

  defstruct [
    :agent_id,
    :identity,
    :project_dir,
    status: :disconnected,
    peers: MapSet.new(),
    relay_url: nil
  ]

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Initialise the Ed25519 identity for this node, subscribe to the network
  PubSub topic, and transition status to `:connected`.

  Safe to call when server is not running — returns `:ok` immediately.
  """
  @spec connect() :: :ok
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

  Looks up the solution from `JidoClaw.Solutions.Store`. If the solution is not
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

  @impl true
  def init(opts) do
    project_dir = Keyword.fetch!(opts, :project_dir)
    relay_url = Keyword.get(opts, :relay_url)

    state = %__MODULE__{
      project_dir: project_dir,
      relay_url: relay_url
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:connect, _from, state) do
    case Identity.init(state.project_dir) do
      {:ok, identity} ->
        :ok = Phoenix.PubSub.subscribe(@pubsub, @topic)

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

  @impl true
  def handle_call(:disconnect, _from, state) do
    if state.status == :connected do
      Phoenix.PubSub.unsubscribe(@pubsub, @topic)
      SignalBus.emit("jido_claw.network.disconnected", %{agent_id: state.agent_id})
      Logger.info("[Network.Node] Disconnected")
    end

    {:reply, :ok, %{state | status: :disconnected}}
  end

  @impl true
  def handle_call(:status, _from, state) do
    result = %{
      status: state.status,
      agent_id: state.agent_id,
      peer_count: MapSet.size(state.peers)
    }

    {:reply, result, state}
  end

  @impl true
  def handle_call(:peers, _from, state) do
    {:reply, MapSet.to_list(state.peers), state}
  end

  @impl true
  def handle_call({:broadcast_solution, solution_id}, _from, state) do
    if state.status != :connected or is_nil(state.identity) do
      {:reply, {:error, :not_connected}, state}
    else
      case find_solution_by_id(solution_id) do
        {:ok, solution} ->
          solution_map = Solution.to_map(solution)
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

  @impl true
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

  @impl true
  def handle_info({:solution_shared, message}, state) do
    # Ignore messages we broadcast ourselves
    if same_agent?(message, state) do
      {:noreply, state}
    else
      new_state = handle_solution_shared(message, state)
      {:noreply, new_state}
    end
  end

  @impl true
  def handle_info({:solution_requested, message}, state) do
    if same_agent?(message, state) or state.status != :connected do
      {:noreply, state}
    else
      handle_solution_requested(message, state)
      {:noreply, add_peer(state, message)}
    end
  end

  @impl true
  def handle_info({:solution_response, message}, state) do
    if same_agent?(message, state) do
      {:noreply, state}
    else
      new_state = handle_solution_response(message, state)
      {:noreply, new_state}
    end
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # ---------------------------------------------------------------------------
  # Message handlers
  # ---------------------------------------------------------------------------

  defp handle_solution_shared(message, state) do
    with %{"payload" => payload, "from" => from} <- message,
         true <- valid_or_unverifiable?(message, from),
         {:ok, solution} <- store_received_solution(payload, from) do
      Logger.debug("[Network.Node] Stored shared solution #{solution.id} from #{from}")
    else
      false ->
        Logger.warning(
          "[Network.Node] Dropped share message with invalid signature from #{message["from"]}"
        )

      {:error, reason} ->
        Logger.debug("[Network.Node] Could not store shared solution: #{inspect(reason)}")

      _ ->
        :ok
    end

    add_peer(state, message)
  end

  defp handle_solution_requested(message, state) do
    with %{"payload" => %{"description" => description}, "id" => request_id, "from" => from} <-
           message do
      opts_raw = get_in(message, ["payload", "opts"]) || %{}
      opts = Enum.map(opts_raw, fn {k, v} -> {String.to_existing_atom(k), v} end)

      solutions = Matcher.find_solutions(description, opts)

      if solutions != [] and not is_nil(state.identity) do
        solution_maps = Enum.map(solutions, fn %{solution: s} -> Solution.to_map(s) end)
        response = Protocol.response_message(solution_maps, request_id, state.identity)

        Logger.debug(
          "[Network.Node] Responding to request #{request_id} from #{from} with #{length(solution_maps)} solutions"
        )

        Phoenix.PubSub.broadcast(@pubsub, @topic, {:solution_response, response})
      end
    else
      _ -> :ok
    end
  rescue
    # String.to_existing_atom may raise for unknown option keys
    ArgumentError -> :ok
  end

  defp handle_solution_response(message, state) do
    with %{"payload" => %{"solutions" => solutions, "request_id" => _req_id}, "from" => from} <-
           message,
         true <- is_list(solutions) do
      Enum.each(solutions, fn solution_map ->
        attrs = Map.put(solution_map, "agent_id", from)

        case Store.store_solution(attrs) do
          {:ok, solution} ->
            Logger.debug("[Network.Node] Stored response solution #{solution.id} from #{from}")

          {:error, reason} ->
            Logger.debug("[Network.Node] Could not store response solution: #{inspect(reason)}")
        end
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

  # Returns true when the signature is valid, or when we have no public key to
  # verify against (peer unknown). Drops messages only when verification
  # explicitly fails.
  defp valid_or_unverifiable?(message, _from) do
    # We don't maintain a peer key registry yet, so we accept unverifiable
    # messages as potentially valid. Future: look up public key from a key
    # directory keyed by agent_id and call Protocol.verify_message/2.
    _ = message
    true
  end

  defp store_received_solution(payload, from) when is_map(payload) do
    attrs = Map.put(payload, "agent_id", from)
    Store.store_solution(attrs)
  end

  defp find_solution_by_id(id) do
    Store.find_by_id(id)
  end

  defp add_peer(state, %{"from" => from}) when is_binary(from) do
    %{state | peers: MapSet.put(state.peers, from)}
  end

  defp add_peer(state, _), do: state
end
