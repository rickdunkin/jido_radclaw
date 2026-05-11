defmodule JidoClaw.Web.ForgeLive do
  use JidoClaw.Web, :live_view

  @impl true
  def mount(_params, _session, socket) do
    sessions = JidoClaw.Forge.list_sessions()
    {:ok, assign(socket, page_title: "Forge", sessions: sessions)}
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
              <th>Status</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={session_id <- @sessions}>
              <td style="font-family: monospace;">{session_id}</td>
              <td><.status_badge status={:running} /></td>
            </tr>
            <tr :if={@sessions == []}>
              <td colspan="2" style="text-align: center; color: var(--muted); padding: 2rem;">
                No active forge sessions
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end
end
