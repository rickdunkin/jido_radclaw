defmodule JidoClaw.Cluster do
  @moduledoc """
  Clustering support via libcluster and :pg process groups.
  Provides node discovery, process group management, and topology configuration.
  """
  require Logger

  @pg_scope :jido_claw

  # -- Node Discovery --

  @doc "List all connected nodes (excluding self)."
  def nodes do
    Node.list()
  end

  @doc "Total node count including self."
  def node_count do
    length(Node.list()) + 1
  end

  @doc "Local node name."
  def local_node, do: Node.self()

  @doc "Check if connected to any other nodes."
  def connected?, do: Node.list() != []

  @doc "Get info about a specific node."
  def node_info(node_name \\ Node.self()) do
    %{
      name: node_name,
      uptime: :erlang.statistics(:wall_clock) |> elem(0) |> div(1000),
      process_count: :erlang.system_info(:process_count),
      memory: :erlang.memory(:total)
    }
  end

  # -- Process Groups (:pg) --

  @doc "Join a process group."
  def join(group, pid \\ self()) do
    :pg.join(@pg_scope, group, pid)
  end

  @doc "Leave a process group."
  def leave(group, pid \\ self()) do
    :pg.leave(@pg_scope, group, pid)
  end

  @doc "Get all members of a group across the cluster."
  def members(group) do
    :pg.get_members(@pg_scope, group)
  end

  @doc "Get local members only."
  def local_members(group) do
    :pg.get_local_members(@pg_scope, group)
  end

  @doc "List all active groups."
  def groups do
    :pg.which_groups(@pg_scope)
  end

  # -- Topology Configuration --

  @doc "Get libcluster topology for the current environment."
  def topology do
    env = Application.get_env(:jido_claw, :cluster_strategy, :gossip)

    case env do
      :gossip ->
        [
          jido_claw: [
            strategy: Cluster.Strategy.Gossip,
            config: [
              port: Application.get_env(:jido_claw, :gossip_port, 45892),
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
              port: 45892,
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
