defmodule JidoClaw.Web.Router do
  use Phoenix.Router
  import Phoenix.LiveDashboard.Router
  import Phoenix.LiveView.Router
  import AshAdmin.Router

  pipeline :api do
    plug(:accepts, ["json"])
  end

  pipeline :api_auth do
    plug(JidoClaw.Web.Plugs.ApiKeyAuth)
  end

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {JidoClaw.Web.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  pipeline :require_browser_auth do
    plug(JidoClaw.Web.Plugs.RequireAuth)
  end

  pipeline :require_admin do
    plug(JidoClaw.Web.Plugs.RequireAdmin)
  end

  # Admin panel — gated by the JIDOCLAW_ADMIN_EMAILS allowlist at two layers:
  # the :require_admin plug gates the disconnected render (which mints the
  # signed LiveView session used to join the live_session over WS), and the
  # :live_admin_required on_mount hook independently gates WebSocket mounts
  # and reconnects. This gate is the security boundary: AshAdmin's in-UI
  # actor/authorizing toggles are client-controlled by design, so anything
  # past this point runs unauthorized. Revocation: removing an email takes
  # effect on the next HTTP request / LV mount / reconnect — an
  # already-connected AshAdmin LiveView keeps its process until disconnect.
  scope "/" do
    pipe_through([:browser, :require_browser_auth, :require_admin])
    ash_admin("/admin", on_mount: [{JidoClaw.Web.LiveUserAuth, :live_admin_required}])
  end

  # Unauthenticated API routes
  scope "/", JidoClaw.Web do
    pipe_through(:api)

    get("/health", HealthController, :index)
  end

  # Authenticated API routes
  scope "/", JidoClaw.Web do
    pipe_through([:api, :api_auth])

    post("/v1/chat/completions", ChatController, :create)
  end

  # GitHub webhooks (HMAC verified in controller)
  scope "/webhooks", JidoClaw.Web do
    pipe_through(:api)
    post("/github", WebhookController, :github)
  end

  # Auth controller routes
  scope "/auth", JidoClaw.Web do
    pipe_through(:browser)

    post("/sign-in", AuthController, :sign_in)
    delete("/sign-out", AuthController, :sign_out)
  end

  # Public LiveView routes (no auth)
  scope "/", JidoClaw.Web do
    pipe_through(:browser)

    live_session :no_auth, on_mount: [{JidoClaw.Web.LiveUserAuth, :live_no_user}] do
      live("/sign-in", SignInLive)
    end

    live_session :optional_auth, on_mount: [{JidoClaw.Web.LiveUserAuth, :live_user_optional}] do
      live("/setup", SetupLive)
    end
  end

  # Authenticated LiveView routes
  scope "/", JidoClaw.Web do
    pipe_through(:browser)

    live_session :require_auth, on_mount: [{JidoClaw.Web.LiveUserAuth, :live_user_required}] do
      live("/", DashboardLive)
      live("/dashboard", DashboardLive)
      live("/forge", ForgeLive)
      live("/workflows", WorkflowsLive)
      live("/approvals", ApprovalsLive)
      live("/agents", AgentsLive)
      live("/projects", ProjectsLive)
      live("/settings", SettingsLive)
    end
  end

  # Phoenix LiveDashboard (dev only)
  if Mix.env() == :dev do
    scope "/" do
      pipe_through([:browser, :require_browser_auth])

      live_dashboard("/live-dashboard",
        metrics: JidoClaw.Telemetry,
        ecto_repos: []
      )
    end
  end
end
