defmodule JidoClaw.Web.SetupLive do
  use JidoClaw.Web, :live_view

  alias JidoClaw.Setup.Wizard

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    status = Wizard.run()

    {:ok,
     assign(socket,
       page_title: "Setup",
       status: status,
       step: :prerequisites
     )}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div style="max-width: 640px; margin: 0 auto;">
      <h1 style="font-size: 1.5rem; font-weight: 700; margin-bottom: 0.5rem;">JidoClaw Setup</h1>
      <p style="color: var(--muted); margin-bottom: 2rem;">Verify your environment is ready</p>

      <div style="display: flex; gap: 0.25rem; margin-bottom: 1.5rem;">
        <%= for {step, label} <- [prerequisites: "Prerequisites", credentials: "Credentials", database: "Database"] do %>
          <button
            class={"btn #{if @step == step, do: "btn-primary"}"}
            phx-click="step"
            phx-value-step={step}
          >
            {label}
          </button>
        <% end %>
      </div>

      <div :if={@step == :prerequisites} class="card">
        <h2 style="font-weight: 600; margin-bottom: 1rem;">System Prerequisites</h2>
        <div
          :for={{_key, check} <- @status.prerequisites}
          style="display: flex; justify-content: space-between; padding: 0.5rem 0; border-bottom: 1px solid var(--border);"
        >
          <span>{check.name}</span>
          <div style="display: flex; align-items: center; gap: 0.5rem;">
            <span :if={check.version} style="color: var(--muted); font-size: 0.875rem;">
              {check.version}
            </span>
            <span :if={check.ok?} style="color: #4ade80;">✓</span>
            <span :if={!check.ok?} style="color: #f87171;">✗</span>
          </div>
        </div>
      </div>

      <div :if={@step == :credentials} class="card">
        <h2 style="font-weight: 600; margin-bottom: 1rem;">AI Provider Credentials</h2>
        <div
          :for={{_key, cred} <- @status.credentials}
          style="display: flex; justify-content: space-between; padding: 0.5rem 0; border-bottom: 1px solid var(--border);"
        >
          <span>{cred.provider}</span>
          <div>
            <span :if={cred.valid?} style="color: #4ade80;">Connected</span>
            <span :if={cred.configured? and !cred.valid?} style="color: #facc15;">Invalid</span>
            <span :if={!cred.configured?} style="color: var(--muted);">Not configured</span>
          </div>
        </div>
        <p
          :if={!@status.has_ai_provider?}
          style="color: #facc15; font-size: 0.875rem; margin-top: 1rem;"
        >
          At least one AI provider is needed. Set ANTHROPIC_API_KEY, OPENAI_API_KEY, or start Ollama.
        </p>
      </div>

      <div :if={@step == :database} class="card">
        <h2 style="font-weight: 600; margin-bottom: 1rem;">Database</h2>
        <div style="display: flex; justify-content: space-between; padding: 0.5rem 0;">
          <span>PostgreSQL Connection</span>
          <span :if={@status.database.ok?} style="color: #4ade80;">{@status.database.status}</span>
          <span :if={!@status.database.ok?} style="color: #f87171;">{@status.database.status}</span>
        </div>
      </div>

      <div style="margin-top: 2rem; text-align: center;">
        <div :if={@status.ready?} style="color: #4ade80; font-weight: 600; margin-bottom: 1rem;">
          All systems go!
        </div>
        <.button :if={@status.ready?} navigate="/dashboard" variant="primary">
          Go to Dashboard
        </.button>
        <button :if={!@status.ready?} class="btn" phx-click="recheck">Re-check</button>
      </div>
    </div>
    """
  end

  # Explicit literal matching — never String.to_atom on params.
  @impl Phoenix.LiveView
  def handle_event("step", %{"step" => "prerequisites"}, socket),
    do: {:noreply, assign(socket, step: :prerequisites)}

  def handle_event("step", %{"step" => "credentials"}, socket),
    do: {:noreply, assign(socket, step: :credentials)}

  def handle_event("step", %{"step" => "database"}, socket),
    do: {:noreply, assign(socket, step: :database)}

  def handle_event("step", _params, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def handle_event("recheck", _params, socket) do
    {:noreply, assign(socket, status: Wizard.run())}
  end
end
