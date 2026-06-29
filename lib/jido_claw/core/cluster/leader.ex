defmodule JidoClaw.Cluster.Leader do
  @moduledoc """
  `:pg`-based leader election for always-on singletons (WS4).

  Many always-on processes start on **every** node (the cron `:system_job`
  ticks, the retention sweepers, the embeddings backfill scan). Under
  clustering each would fire N times. This GenServer elects exactly one node
  as **leader**, and `leader?/0` lets those singletons gate their periodic
  work so only the leader runs it.

  ## Algorithm: lowest node-name wins

  Election is deterministic and stateless — every node computes the same
  leader from the same `:pg` membership via `Enum.min/1`
  (`elect/1`). Re-election is automatic: when the lowest node leaves the
  group, the next-lowest becomes leader on the next membership message. No
  consensus protocol, no durable join-order state.

  ## Why `:pg`, not a held advisory lock

  A session-bound `pg_try_advisory_lock` held open by
  `Process.sleep(:infinity)` stalls **all** leader-only work globally if the
  leader's TCP survives but the node is unreachable. `:pg` membership has no
  such partition-stall — when a node becomes unreachable it drops out of the
  group and the next-lowest takes over. We reuse the existing `:pg` scope
  `:jido_claw` via the `JidoClaw.Cluster` wrapper.

  ## Eventual consistency — the standing invariant

  `:pg` membership is eventually-consistent, so a **brief two-leaders window**
  is possible while membership converges (e.g. a healing netsplit). The leader
  gate is therefore **first-line waste-reduction, not a correctness
  guarantee**: every gated unit must stay independently safe — idempotent,
  row-claimed (`FOR UPDATE SKIP LOCKED`), advisory-locked, or
  idempotency-keyed. The consolidator's advisory lock and the cron→workflow
  `cron:<job>:<window>` key are the backstops; the gate only reduces how often
  the safe-by-construction work runs.

  ## Fail-closed

  `leader?/0` is consulted on cron/sweeper ticks, so a wedged or absent leader
  must fail **closed** (return `false`) fast rather than block a tick — a
  skipped tick simply re-arms and the next leader fires on the following
  boundary. On a single node (`cluster_enabled: false`) `leader?/0` is
  trivially `true` and never touches `:pg` or a process, which is what keeps
  single-node behavior byte-identical.

  ## Testability

  `elect/1` and `recompute/2` are pure module functions over **node-name
  lists**, so multi-node selection is tested on a single BEAM without a live
  process (a single BEAM cannot make `node(pid)` return a remote name). The
  `:members_fun` opt is the dependency-injection seam: a test starts the
  Leader with a fun returning controlled node lists and drives `handle_info`
  to exercise recompute + telemetry — no production-only backdoor clause.
  """

  use GenServer

  require Logger

  alias JidoClaw.Cluster

  @group :cluster_leader
  @leader_call_timeout 1_000

  # `members` defaults to `[]` (never nil) so the `@type t` `members: [node()]`
  # holds for the transient struct built in `init/1` before the first recompute.
  defstruct [:ref, :self_node, :leader, :members_fun, members: []]

  @type t :: %__MODULE__{
          ref: reference() | nil,
          self_node: node() | nil,
          leader: node() | nil,
          members: [node()],
          members_fun: (-> [node()]) | nil
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl GenServer
  def init(opts) do
    if cluster_enabled?() do
      members_fun = Keyword.get(opts, :members_fun, &pg_member_nodes/0)

      Cluster.join(@group)
      {ref, _pids} = Cluster.monitor_group(@group)

      {state, _changed?} =
        recompute(
          %__MODULE__{
            ref: ref,
            self_node: Cluster.local_node(),
            members_fun: members_fun
          },
          members_fun.()
        )

      Logger.info(
        "[Cluster.Leader] joined #{inspect(@group)}; leader=#{inspect(state.leader)} " <>
          "members=#{inspect(state.members)}"
      )

      {:ok, state}
    else
      # Self-gate: single node (clustering disabled) ⇒ no process; `leader?/0`
      # answers `true` via its fast path without ever reaching here.
      :ignore
    end
  end

  # `:pg.monitor/2` join/leave. Same-variable `ref` in the message tuple and
  # the state struct enforces the monitor-ref match (a stray monitor message
  # for a different ref falls through to the catch-all). The delivered pid
  # delta is ignored — we recompute from authoritative full membership
  # (`members_fun.()`), so the reducer is always consistent regardless of
  # delivery ordering.
  @impl GenServer
  def handle_info({ref, action, _group, _pids}, %__MODULE__{ref: ref} = state)
      when action in [:join, :leave] do
    {new_state, changed?} = recompute(state, state.members_fun.())

    if changed? do
      Logger.info(
        "[Cluster.Leader] membership #{action}: leader #{inspect(state.leader)} -> " <>
          "#{inspect(new_state.leader)}"
      )

      emit_leader_changed(state.leader, new_state)
    end

    {:noreply, new_state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl GenServer
  def handle_call(:leader?, _from, %__MODULE__{} = state) do
    {:reply, state.leader == state.self_node, state}
  end

  def handle_call(:leader, _from, %__MODULE__{} = state) do
    {:reply, state.leader, state}
  end

  # -- Pure, directly-testable core --

  @doc """
  Elect the leader from a list of node names: the lowest name wins.

  `elect([]) == nil` (no members), otherwise `Enum.min/1`. Pure and
  deterministic — every node computes the same answer from the same
  membership.
  """
  @spec elect([node()]) :: node() | nil
  def elect([]), do: nil
  def elect(nodes), do: Enum.min(nodes)

  @doc """
  Membership reducer: set `members`/`leader` from a node-name list and report
  whether the **leader** changed (not merely membership).

  `handle_info`/`init` call `recompute(state, members_fun.())`; tests call it
  directly with synthetic node-name lists.
  """
  @spec recompute(t(), [node()]) :: {t(), boolean()}
  def recompute(%__MODULE__{} = state, members) do
    members = Enum.uniq(members)
    leader = elect(members)
    {%{state | members: members, leader: leader}, leader != state.leader}
  end

  # -- Public API --

  @doc """
  Whether the local node is the cluster leader.

  Single node (`cluster_enabled: false`) ⇒ trivially `true` (no `:pg`, no
  process call). Clustered ⇒ a bounded call to the live Leader, failing
  **closed** (`false`) if it is absent or wedged. The explicit #{@leader_call_timeout}ms
  timeout (vs `GenServer`'s 5s default) keeps a wedged leader from blocking a
  cron/sweeper tick.
  """
  @spec leader?() :: boolean()
  def leader? do
    if cluster_enabled?() do
      case GenServer.whereis(__MODULE__) do
        nil -> false
        _pid -> safe_call(:leader?, false)
      end
    else
      true
    end
  end

  @doc """
  The current leader node (dashboard/debug).

  Single node ⇒ the local node. Clustered ⇒ the elected node, or `nil` when
  leadership is indeterminate (Leader absent/wedged).
  """
  @spec leader() :: node() | nil
  def leader do
    if cluster_enabled?() do
      case GenServer.whereis(__MODULE__) do
        nil -> nil
        _pid -> safe_call(:leader, nil)
      end
    else
      Cluster.local_node()
    end
  end

  # -- Private --

  defp safe_call(msg, default) do
    GenServer.call(__MODULE__, msg, @leader_call_timeout)
  catch
    # Timeout or no-proc (a race with crash/restart) ⇒ fail closed.
    :exit, _ -> default
  end

  defp pg_member_nodes do
    @group
    |> Cluster.members()
    |> Enum.map(&node/1)
    |> Enum.uniq()
  end

  defp emit_leader_changed(previous, %__MODULE__{} = state) do
    :telemetry.execute(
      [:jido_claw, :cluster, :leader_changed],
      %{count: 1},
      %{leader: state.leader, previous: previous, members: state.members}
    )
  end

  defp cluster_enabled?, do: Application.get_env(:jido_claw, :cluster_enabled, false)
end
