defmodule JidoClaw.Orchestration.RunTerminator do
  @moduledoc """
  The per-node receiver for cross-node executor kills (WS5).

  One per node (`name: __MODULE__`), reached cross-node as `{__MODULE__, node}`.
  Its sole job: turn a routed `{:kill, run_id, tenant_id}` cast into a local
  `JidoClaw.Orchestration.RunExecution.kill_local/2`. When
  `JidoClaw.Orchestration.Cancellation` cancels a run owned by a remote node, it
  appends the durable `run_cancelled` event locally and then casts the kill here,
  on the owning node, where the executor's `RunRegistry` entry actually lives.

  Reactive-only and stateless — no timer, no DB, no PubSub. A cast can only
  arrive from a remote `Cancellation` routing decision, so it is as inert as
  `RunRegistry` until one does: **no `enabled?` gate, no `init/1` self-gate**.
  Always-on in every serve mode and on every node (the single-node local cancel
  path routes `:local` and never casts here, but the GenServer is still present),
  so it is deliberately **not** `cluster_enabled`-gated.

  Best-effort, by design. The kill is a latency/waste optimization; the durable
  `run_cancelled` decision already won before any cast, and an unroutable or dead
  owner is covered by WS3 reclaim. The tenant pin (a cross-tenant kill is
  refused) lives in `RunExecution.kill_local/2`, the single source of truth.

  Real cross-BEAM cast *delivery* to a genuinely remote node is exercised by
  WS6's `:peer` multi-node harness; single-node it is only ever reached as
  `{__MODULE__, Node.self()}`.
  """

  use GenServer

  alias JidoClaw.Orchestration.RunExecution

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl GenServer
  def init(_opts), do: {:ok, %{}}

  @impl GenServer
  def handle_cast({:kill, run_id, tenant_id}, state) do
    RunExecution.kill_local(run_id, tenant_id)
    {:noreply, state}
  end
end
