defmodule JidoClaw.Web.DashboardLive do
  use JidoClaw.Web, :live_view

  alias JidoClaw.Forge.PubSub, as: ForgePubSub
  alias JidoClaw.Orchestration.RunPubSub
  alias JidoClaw.RuntimeOverview

  # Forge/run events arrive in bursts; coalesce rebuilds (each ≥3 DB queries)
  # behind a single delayed :refresh_overview, mirroring the Display swarm
  # header debounce.
  @overview_debounce_ms 250

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      ForgePubSub.subscribe_sessions()
      RunPubSub.subscribe_all()
    end

    {:ok,
     assign(socket,
       page_title: "Dashboard",
       overview: overview(socket),
       overview_refresh_pending: false
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <h1 style="font-size: 1.5rem; font-weight: 700; margin-bottom: 1.5rem;">Dashboard</h1>

      <div style="display: grid; grid-template-columns: repeat(4, 1fr); gap: 1rem; margin-bottom: 2rem;">
        <.stat_card label="Forge Sessions" value={to_string(@overview.forge.active_count)} />
        <.stat_card label="Active Workflows" value={to_string(@overview.workflows.active_count)} />
        <.stat_card label="Uptime" value={format_uptime(@overview.uptime.seconds)} />
        <.stat_card label="Status" value="Online" />
      </div>

      <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 1.5rem;">
        <div class="card">
          <h2 style="font-size: 1rem; font-weight: 600; margin-bottom: 1rem; color: var(--muted);">
            Recent Workflows
          </h2>
          <div
            :if={@overview.workflows.recent_completions == []}
            style="color: var(--muted); font-size: 0.875rem;"
          >
            No recent workflow completions
          </div>
          <div
            :for={run <- Enum.take(@overview.workflows.recent_completions, 5)}
            style="padding: 0.5rem 0; border-bottom: 1px solid var(--border);"
          >
            <span>{Map.get(run, :name, "unnamed")}</span>
            <.status_badge status={Map.get(run, :status, :completed)} />
          </div>
        </div>

        <div class="card">
          <h2 style="font-size: 1rem; font-weight: 600; margin-bottom: 1rem; color: var(--muted);">
            Quick Actions
          </h2>
          <div style="display: flex; flex-direction: column; gap: 0.5rem;">
            <.button navigate="/forge">New Forge Session</.button>
            <.button navigate="/workflows">View Workflows</.button>
            <.button navigate="/folio">Folio Inbox</.button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # Forge session events — each schedules a coalesced overview rebuild.
  @impl true
  def handle_info({:session_started, _id, _scope}, socket) do
    {:noreply, schedule_overview_refresh(socket)}
  end

  @impl true
  def handle_info({:session_recovering, _id, _scope}, socket) do
    {:noreply, schedule_overview_refresh(socket)}
  end

  @impl true
  def handle_info({:session_recovery_exhausted, _id, _scope}, socket) do
    {:noreply, schedule_overview_refresh(socket)}
  end

  @impl true
  def handle_info({:session_stopped, _id, _reason, _scope}, socket) do
    {:noreply, schedule_overview_refresh(socket)}
  end

  # Run events (RunPubSub — broadcast by JidoClaw.Orchestration.WorkflowRunner)
  @impl true
  def handle_info({:run_started, _id, _info}, socket) do
    {:noreply, schedule_overview_refresh(socket)}
  end

  @impl true
  def handle_info({:run_completed, _id, _info}, socket) do
    {:noreply, schedule_overview_refresh(socket)}
  end

  @impl true
  def handle_info({:run_failed, _id, _info}, socket) do
    {:noreply, schedule_overview_refresh(socket)}
  end

  # Coalesced rebuild — fires once after a burst of events settles.
  @impl true
  def handle_info(:refresh_overview, socket) do
    {:noreply, assign(socket, overview: overview(socket), overview_refresh_pending: false)}
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  # Debounce: the first event in a burst arms a single timer + sets the
  # pending flag; subsequent events are no-ops until :refresh_overview clears
  # it. Overview stays as-is until the timer fires.
  defp schedule_overview_refresh(%{assigns: %{overview_refresh_pending: true}} = socket),
    do: socket

  defp schedule_overview_refresh(socket) do
    Process.send_after(self(), :refresh_overview, @overview_debounce_ms)
    assign(socket, overview_refresh_pending: true)
  end

  defp overview(socket) do
    tenant_id = current_tenant_id(socket)

    case RuntimeOverview.snapshot(%{tenant_id: tenant_id}) do
      {:ok, overview} -> overview
      {:error, _} -> empty_overview(tenant_id)
    end
  end

  defp current_tenant_id(%{assigns: %{current_actor: %{tenant_id: tenant_id}}}), do: tenant_id
  defp current_tenant_id(_), do: nil

  defp empty_overview(tenant_id) do
    %RuntimeOverview{
      tenant_id: tenant_id,
      swarm: %JidoClaw.SwarmView{},
      forge: %JidoClaw.ForgeView{},
      workflows: %JidoClaw.WorkflowView{},
      uptime: %{seconds: 0, agents_spawned: 0},
      generated_at: DateTime.utc_now()
    }
  end

  defp format_uptime(seconds) when is_integer(seconds) do
    hours = div(seconds, 3600)
    mins = div(rem(seconds, 3600), 60)
    "#{hours}h #{mins}m"
  end

  defp format_uptime(_), do: "N/A"
end
