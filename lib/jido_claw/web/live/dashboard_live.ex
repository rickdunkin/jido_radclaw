defmodule JidoClaw.Web.DashboardLive do
  use JidoClaw.Web, :live_view

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      JidoClaw.Forge.PubSub.subscribe_sessions()
      JidoClaw.Orchestration.RunPubSub.subscribe_all()
    end

    {:ok,
     assign(socket,
       page_title: "Dashboard",
       forge_sessions: length(JidoClaw.Forge.list_sessions()),
       workflow_summary: JidoClaw.Orchestration.RunSummaryFeed.get_summary(),
       uptime: get_uptime()
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <h1 style="font-size: 1.5rem; font-weight: 700; margin-bottom: 1.5rem;">Dashboard</h1>

      <div style="display: grid; grid-template-columns: repeat(4, 1fr); gap: 1rem; margin-bottom: 2rem;">
        <.stat_card label="Forge Sessions" value={to_string(@forge_sessions)} />
        <.stat_card label="Active Workflows" value={to_string(@workflow_summary.active_count)} />
        <.stat_card label="Uptime" value={@uptime} />
        <.stat_card label="Status" value="Online" />
      </div>

      <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 1.5rem;">
        <div class="card">
          <h2 style="font-size: 1rem; font-weight: 600; margin-bottom: 1rem; color: var(--muted);">Recent Workflows</h2>
          <div :if={@workflow_summary.recent_completions == []} style="color: var(--muted); font-size: 0.875rem;">
            No recent workflow completions
          </div>
          <div :for={run <- Enum.take(@workflow_summary.recent_completions, 5)} style="padding: 0.5rem 0; border-bottom: 1px solid var(--border);">
            <span><%= Map.get(run, :name, "unnamed") %></span>
            <.status_badge status={Map.get(run, :status, :completed)} />
          </div>
        </div>

        <div class="card">
          <h2 style="font-size: 1rem; font-weight: 600; margin-bottom: 1rem; color: var(--muted);">Quick Actions</h2>
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

  @impl true
  def handle_info(_msg, socket) do
    {:noreply,
     assign(socket,
       forge_sessions: length(JidoClaw.Forge.list_sessions()),
       workflow_summary: JidoClaw.Orchestration.RunSummaryFeed.get_summary()
     )}
  end

  defp get_uptime do
    case Application.get_env(:jido_claw, :started_at) do
      nil ->
        "N/A"

      started ->
        seconds = System.monotonic_time(:second) - started
        hours = div(seconds, 3600)
        mins = div(rem(seconds, 3600), 60)
        "#{hours}h #{mins}m"
    end
  end
end
