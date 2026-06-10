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

  # -- Topology Configuration --

  @doc "Get libcluster topology for the current environment."
  @spec topology() :: keyword()
  def topology do
    env = Application.get_env(:jido_claw, :cluster_strategy, :gossip)

    case env do
      :gossip ->
        [
          jido_claw: [
            strategy: Cluster.Strategy.Gossip,
            config: [
              port: Application.get_env(:jido_claw, :gossip_port, 45_892),
              if_addr: {0, 0, 0, 0},
              multicast_if: {0, 0, 0, 0},
              multicast_addr: {230, 1, 1, 251},
              multicast_ttl: 1
            ]
          ]
        ]

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

        [
          jido_claw: [
            strategy: Cluster.Strategy.Gossip,
            config: [
              port: 45_892,
              if_addr: {0, 0, 0, 0},
              multicast_if: {0, 0, 0, 0},
              multicast_addr: {230, 1, 1, 251},
              multicast_ttl: 1
            ]
          ]
        ]
    end
  end
end
