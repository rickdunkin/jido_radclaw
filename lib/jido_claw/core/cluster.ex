defmodule JidoClaw.Cluster do
  @moduledoc """
  Clustering support via libcluster and :pg process groups.
  Provides node discovery, process group management, and topology configuration.
  """
  require Logger

  @pg_scope :jido_claw

  # -- Node Discovery --

  @doc "List all connected nodes (excluding self)."
  @spec nodes() :: [node()]
  def nodes do
    Node.list()
  end

  @doc "Total node count including self."
  @spec node_count() :: pos_integer()
  def node_count do
    length(Node.list()) + 1
  end

  @doc "Local node name."
  @spec local_node() :: node()
  def local_node, do: Node.self()

  @doc "Check if connected to any other nodes."
  @spec connected?() :: boolean()
  def connected?, do: Node.list() != []

  @doc "Get info about a specific node."
  @spec node_info(node()) :: %{
          name: node(),
          uptime: non_neg_integer(),
          process_count: non_neg_integer(),
          memory: non_neg_integer()
        }
  def node_info(node_name \\ Node.self()) do
    uptime =
      :erlang.statistics(:wall_clock)
      |> elem(0)
      |> div(1000)

    %{
      name: node_name,
      uptime: uptime,
      process_count: :erlang.system_info(:process_count),
      memory: :erlang.memory(:total)
    }
  end

  # -- Process Groups (:pg) --

  @doc "Join a process group."
  @spec join(term(), pid()) :: :ok
  def join(group, pid \\ self()) do
    :pg.join(@pg_scope, group, pid)
  end

  @doc "Leave a process group."
  @spec leave(term(), pid()) :: :ok | :not_joined
  def leave(group, pid \\ self()) do
    :pg.leave(@pg_scope, group, pid)
  end

  @doc "Get all members of a group across the cluster."
  @spec members(term()) :: [pid()]
  def members(group) do
    :pg.get_members(@pg_scope, group)
  end

  @doc """
  Monitor a process group for membership changes.

  Returns `{ref, current_members}`. Subsequent membership changes are
  delivered to the caller as `{ref, :join | :leave, group, [pid()]}`
  messages (OTP 25+). The ref identifies this monitor for the `handle_info`
  match and for `:pg.demonitor/2`.
  """
  @spec monitor_group(term()) :: {reference(), [pid()]}
  def monitor_group(group) do
    :pg.monitor(@pg_scope, group)
  end

  @doc "Get local members only."
  @spec local_members(term()) :: [pid()]
  def local_members(group) do
    :pg.get_local_members(@pg_scope, group)
  end

  @doc "List all active groups."
  @spec groups() :: [term()]
  def groups do
    :pg.which_groups(@pg_scope)
  end

  # -- Leadership --

  @doc """
  Whether the local node is the cluster leader.

  Singletons that should run on exactly one node gate periodic work on this.
  Delegates to `JidoClaw.Cluster.Leader` (the `:cluster_leader_module` seam,
  swappable in tests) — which returns `true` trivially on a single node and
  fails closed (`false`) when leadership is indeterminate. See
  `JidoClaw.Cluster.Leader` for the election algorithm and the standing
  idempotency invariant for gated work.
  """
  @spec leader?() :: boolean()
  def leader?, do: leader_module().leader?()

  @doc """
  The current leader node (single node ⇒ the local node; clustered ⇒ the
  elected node, or `nil` when leadership is indeterminate).

  The cross-node routing facade for run-less singletons like
  `JidoClaw.Cron.Owner` (a follower casts a reconcile/trigger to
  `{Owner, Cluster.leader()}`). Delegates to the same `:cluster_leader_module`
  seam as `leader?/0`, so it is swappable in tests.
  """
  @spec leader() :: node() | nil
  def leader, do: leader_module().leader()

  defp leader_module do
    Application.get_env(:jido_claw, :cluster_leader_module, JidoClaw.Cluster.Leader)
  end

  # -- Topology Configuration --

  @doc """
  Get libcluster topology for the current environment.

  The `:gossip` strategy (default, also the unknown-strategy fallback)
  **requires** a shared secret — `config :jido_claw, :cluster_secret`
  or the `JIDOCLAW_CLUSTER_SECRET` env var — and raises when it is
  missing. Only invoked from `cluster_children/0` when
  `:cluster_enabled` is true (default false), so single-node boots
  never hit the requirement.
  """
  @spec topology() :: keyword()
  def topology do
    env = Application.get_env(:jido_claw, :cluster_strategy, :gossip)

    case env do
      :gossip ->
        gossip_topology()

      :kubernetes ->
        [
          jido_claw: [
            strategy: Cluster.Strategy.Kubernetes,
            config: [
              mode: :dns,
              kubernetes_node_basename:
                Application.get_env(:jido_claw, :k8s_node_basename, "jidoclaw"),
              kubernetes_selector: Application.get_env(:jido_claw, :k8s_selector, "app=jidoclaw"),
              kubernetes_namespace: Application.get_env(:jido_claw, :k8s_namespace, "default"),
              polling_interval: 5_000
            ]
          ]
        ]

      :epmd ->
        [
          jido_claw: [
            strategy: Cluster.Strategy.Epmd,
            config: [
              hosts: Application.get_env(:jido_claw, :cluster_nodes, [])
            ]
          ]
        ]

      :none ->
        []

      _ ->
        Logger.warning("[Cluster] Unknown strategy #{inspect(env)}, defaulting to gossip")
        gossip_topology()
    end
  end

  # The gossip secret encrypts discovery heartbeats (libcluster uses
  # AES-CBC with no MAC, so it is encryption, NOT authentication):
  # cluster *membership* is gated by the Erlang distribution cookie,
  # and network *messages* by peer signatures
  # (JidoClaw.Network.PeerDirectory). Without a secret, heartbeats are
  # plaintext and any host on the multicast segment gets discovered and
  # connect-attempted — hence the hard requirement.
  defp gossip_topology do
    [
      jido_claw: [
        strategy: Cluster.Strategy.Gossip,
        config: [
          port: Application.get_env(:jido_claw, :gossip_port, 45_892),
          if_addr: {0, 0, 0, 0},
          multicast_if: {0, 0, 0, 0},
          multicast_addr: {230, 1, 1, 251},
          multicast_ttl: 1,
          secret: gossip_secret!()
        ]
      ]
    ]
  end

  # App env first (test seam), then the env var read at call time —
  # JidoClaw.Application.load_dotenv/0 runs before cluster_children/0
  # builds the topology, so `.env` values work (runtime.exs is too
  # early). Mirrors JidoClaw.Web.AdminAccess.
  @spec gossip_secret!() :: String.t()
  defp gossip_secret! do
    raw =
      Application.get_env(:jido_claw, :cluster_secret) ||
        System.get_env("JIDOCLAW_CLUSTER_SECRET")

    with secret when is_binary(secret) <- raw,
         trimmed when trimmed != "" <- String.trim(secret) do
      trimmed
    else
      _ ->
        raise """
        A gossip cluster secret is required to start clustering.

        The :gossip strategy multicasts discovery heartbeats; without a shared \
        secret they are sent in plaintext and any host on the multicast segment \
        is discovered and connect-attempted.

        Set the JIDOCLAW_CLUSTER_SECRET env var (or `config :jido_claw, \
        :cluster_secret`) to the same non-empty value on every node. Also set a \
        non-default Erlang distribution cookie — the secret only encrypts \
        discovery; the cookie is what gates cluster membership.

        Not clustering? Set `config :jido_claw, cluster_enabled: false` (the \
        default) instead.
        """
    end
  end
end
