defmodule JidoClaw.Web.ForgeLive do
  use JidoClaw.Web, :live_view

  alias JidoClaw.Forge.PubSub, as: ForgePubSub
  alias JidoClaw.ForgeView

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: ForgePubSub.subscribe_sessions()

    {:ok, assign(socket, page_title: "Forge", sessions: sessions(socket))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 1.5rem;">
        <h1 style="font-size: 1.5rem; font-weight: 700;">Forge</h1>
        <.button variant="primary">New Session</.button>
      </div>

      <div class="card">
        <table>
          <thead>
            <tr>
              <th>Session ID</th>
              <th>Phase</th>
              <th>Runner</th>
              <th>Executions</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={session <- @sessions}>
              <td style="font-family: monospace;">{session.session_id}</td>
              <td><.status_badge status={session.phase} /></td>
              <td style="color: var(--muted);">{session.runner_type || "—"}</td>
              <td>{session.execution_count}</td>
            </tr>
            <tr :if={@sessions == []}>
              <td colspan="4" style="text-align: center; color: var(--muted); padding: 2rem;">
                No active forge sessions
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  @impl true
  def handle_info({:session_started, _id, _scope}, socket) do
    {:noreply, assign(socket, sessions: sessions(socket))}
  end

  def handle_info({:session_recovering, _id, _scope}, socket) do
    {:noreply, assign(socket, sessions: sessions(socket))}
  end

  def handle_info({:session_recovery_exhausted, _id, _scope}, socket) do
    {:noreply, assign(socket, sessions: sessions(socket))}
  end

  def handle_info({:session_stopped, _id, _reason, _scope}, socket) do
    {:noreply, assign(socket, sessions: sessions(socket))}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp sessions(socket) do
    case ForgeView.list(%{tenant_id: current_tenant_id(socket)}) do
      {:ok, view} -> view.sessions
      {:error, _} -> []
    end
  end

  defp current_tenant_id(%{assigns: %{current_actor: %{tenant_id: tenant_id}}}), do: tenant_id
  defp current_tenant_id(_), do: nil
end
