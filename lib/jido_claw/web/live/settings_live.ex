defmodule JidoClaw.Web.SettingsLive do
  use JidoClaw.Web, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Settings",
       mode: Application.get_env(:jido_claw, :mode, :both),
       gateway_port: Application.get_env(:jido_claw, :gateway_port, 4000)
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <h1 style="font-size: 1.5rem; font-weight: 700; margin-bottom: 1.5rem;">Settings</h1>

      <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 1.5rem;">
        <div class="card">
          <h2 style="font-weight: 600; margin-bottom: 1rem;">Platform</h2>
          <div style="display: flex; flex-direction: column; gap: 0.75rem;">
            <div style="display: flex; justify-content: space-between;">
              <span style="color: var(--muted);">Mode</span>
              <span><%= @mode %></span>
            </div>
            <div style="display: flex; justify-content: space-between;">
              <span style="color: var(--muted);">Gateway Port</span>
              <span><%= @gateway_port %></span>
            </div>
            <div style="display: flex; justify-content: space-between;">
              <span style="color: var(--muted);">Ash Domains</span>
              <span><%= length(Application.get_env(:jido_claw, :ash_domains, [])) %></span>
            </div>
          </div>
        </div>

        <div class="card">
          <h2 style="font-weight: 600; margin-bottom: 1rem;">API Keys</h2>
          <p style="color: var(--muted); font-size: 0.875rem; margin-bottom: 1rem;">
            Manage API keys for programmatic access
          </p>
          <.button variant="primary">Generate New Key</.button>
        </div>
      </div>
    </div>
    """
  end
end
