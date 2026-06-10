defmodule JidoClaw.Web.AgentsLive do
  @moduledoc """
  Lists the live `%JidoClaw.AgentView{}` snapshots for the authenticated
  user's tenant. Each card shows agent template, status, message count,
  and the latest event name. Awaiting-handoff sessions get a banner.

  v1: 5-second polling. PubSub-driven refresh is deferred.
  """

  use JidoClaw.Web, :live_view

  alias JidoClaw.AgentView

  @refresh_interval_ms 5_000

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    tenant_id = current_tenant_id(socket)

    socket =
      socket
      |> assign(:page_title, "Agents")
      |> assign(:tenant_id, tenant_id)
      |> assign(:agent_views, list_views(tenant_id))

    if connected?(socket) and is_binary(tenant_id) do
      Process.send_after(self(), :refresh, @refresh_interval_ms)
    end

    {:ok, socket}
  end

  @impl Phoenix.LiveView
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_interval_ms)
    {:noreply, assign(socket, :agent_views, list_views(socket.assigns.tenant_id))}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div>
      <h1 style="font-size: 1.5rem; font-weight: 700; margin-bottom: 1.5rem;">Agents</h1>

      <div :if={@agent_views == []} style="color: var(--muted); font-size: 0.875rem;">
        No active agents in this tenant.
      </div>

      <div style="display: grid; grid-template-columns: repeat(3, 1fr); gap: 1rem;">
        <div :for={view <- @agent_views} class="card">
          <h3 style="font-weight: 600; margin-bottom: 0.5rem;">
            {view.agent_template || "main"}
          </h3>
          <p style="color: var(--muted); font-size: 0.875rem; margin-bottom: 0.5rem;">
            session: {view.session_id}
          </p>
          <p style="color: var(--muted); font-size: 0.875rem; margin-bottom: 1rem;">
            messages: {view.message_count} · last event: {latest_event_name(view)}
          </p>
          <div
            :if={view.status == :awaiting_handoff}
            class="badge badge-yellow"
            style="margin-bottom: 0.5rem;"
          >
            awaiting handoff
          </div>
          <.status_badge status={view.status} />
        </div>
      </div>
    </div>
    """
  end

  defp current_tenant_id(%{assigns: %{current_user: %{id: id}}}) when not is_nil(id),
    do: to_string(id)

  defp current_tenant_id(_), do: nil

  defp list_views(nil), do: []

  defp list_views(tenant_id) when is_binary(tenant_id) do
    AgentView.list(tenant_id)
  end

  defp latest_event_name(%AgentView{events: []}), do: "-"

  defp latest_event_name(%AgentView{events: events}) do
    ev = Enum.max_by(events, & &1.seq)
    ev.name || to_string(ev.event)
  end
end
