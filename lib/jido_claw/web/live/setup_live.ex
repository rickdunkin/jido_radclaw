defmodule JidoClaw.Web.SetupLive do
  use JidoClaw.Web, :live_view

  alias JidoClaw.Web.SetupStatusCache
  alias Phoenix.LiveView.AsyncResult

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Setup", step: :prerequisites)
     |> assign_async(:status, &fetch_status/0, supervisor: JidoClaw.TaskSupervisor)}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div style="max-width: 640px; margin: 0 auto;">
      <h1 style="font-size: 1.5rem; font-weight: 700; margin-bottom: 0.5rem;">JidoClaw Setup</h1>
      <p style="color: var(--muted); margin-bottom: 2rem;">Verify your environment is ready</p>

      <div :if={@status.loading && !@status.ok?} class="card">
        Running bounded setup checks…
      </div>

      <div :if={@status.failed && !@status.ok?} class="card">
        <p style="color: #f87171; margin-bottom: 1rem;">
          Setup checks are temporarily unavailable. No diagnostic result was cached.
        </p>
        <button class="btn" phx-click="recheck">Try again</button>
      </div>

      <div :if={@status.ok?}>
        <% status = @status.result %>

        <p :if={@status.loading} style="color: var(--muted); margin-bottom: 1rem;">
          Re-checking… the last known result remains visible.
        </p>

        <p :if={@status.failed} style="color: #facc15; margin-bottom: 1rem;">
          The latest re-check failed; showing the last known good result.
        </p>

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
            :for={{_key, check} <- status.prerequisites}
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
            :for={{_key, cred} <- status.credentials}
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
            :if={!status.has_ai_provider?}
            style="color: #facc15; font-size: 0.875rem; margin-top: 1rem;"
          >
            At least one AI provider is needed. Set ANTHROPIC_API_KEY, OPENAI_API_KEY, or start Ollama.
          </p>
        </div>

        <div :if={@step == :database} class="card">
          <h2 style="font-weight: 600; margin-bottom: 1rem;">Database</h2>
          <div style="display: flex; justify-content: space-between; padding: 0.5rem 0;">
            <span>PostgreSQL Connection</span>
            <span :if={status.database.ok?} style="color: #4ade80;">{status.database.status}</span>
            <span :if={!status.database.ok?} style="color: #f87171;">{status.database.status}</span>
          </div>
        </div>

        <div style="margin-top: 2rem; text-align: center;">
          <div :if={status.ready?} style="color: #4ade80; font-weight: 600; margin-bottom: 1rem;">
            All systems go!
          </div>
          <.button :if={status.ready?} navigate="/dashboard" variant="primary">
            Go to Dashboard
          </.button>
          <button
            :if={!status.ready?}
            class="btn"
            phx-click="recheck"
            disabled={@status.loading}
          >
            Re-check
          </button>
        </div>
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
    socket = assign(socket, :status, AsyncResult.loading(socket.assigns.status))

    {:noreply,
     start_async(socket, :setup_status_refresh, &SetupStatusCache.refresh/0,
       supervisor: JidoClaw.TaskSupervisor
     )}
  end

  @impl Phoenix.LiveView
  def handle_async(:setup_status_refresh, {:ok, {:ok, status}}, socket) do
    {:noreply, assign(socket, :status, AsyncResult.ok(socket.assigns.status, status))}
  end

  def handle_async(:setup_status_refresh, {:ok, {:error, reason}}, socket) do
    {:noreply, assign(socket, :status, AsyncResult.failed(socket.assigns.status, reason))}
  end

  def handle_async(:setup_status_refresh, {:exit, reason}, socket) do
    {:noreply,
     assign(socket, :status, AsyncResult.failed(socket.assigns.status, {:exit, reason}))}
  end

  defp fetch_status do
    case SetupStatusCache.fetch() do
      {:ok, status} -> {:ok, %{status: status}}
      {:error, reason} -> {:error, reason}
    end
  end
end
