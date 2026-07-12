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

  # /gql pipeline: the batch guard runs FIRST — the forward's complexity/
  # token limits apply per batch ELEMENT, so a transport batch's aggregate
  # cost is unbounded; reject it before the gate's DB activity check. Then
  # the tenant-activity gate MUST run before AshGraphql.Plug — the gate 403s
  # suspended tenants (Project is a global resource; its policy alone would
  # let a suspended tenant's valid key read it) and sets the Ash tenant that
  # AshGraphql.Plug then copies into the Absinthe context.
  pipeline :graphql do
    plug(JidoClaw.Web.Plugs.GraphqlBatchGuard)
    plug(JidoClaw.Web.Plugs.GraphqlTenantGate)
    plug(AshGraphql.Plug)
  end

  pipeline :graphiql_guard do
    plug(JidoClaw.Web.Plugs.GraphiqlGuard)
  end

  # Static SPA shell only — no session, no CSRF, no layout; the SPA's data
  # access happens over /gql with its own key auth.
  pipeline :argus do
    plug(:accepts, ["html"])
    plug(:put_secure_browser_headers)
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

  # Read-only GraphQL surface (argus P1) behind the existing API-key auth +
  # the tenant-activity gate. The pinned request-cost controls are the
  # complexity/token limits below PLUS the pipeline's transport-batch
  # rejection (the limits are per-element, so a batch's aggregate would be
  # unbounded) — all proven live by route tests; a router refactor must not
  # silently drop them. `Module.concat` avoids the Router→Schema
  # compile-time dep (AshGraphql-recommended).
  scope "/gql" do
    pipe_through([:api, :api_auth, :graphql])

    # Module.concat over a literal runs once at ROUTER COMPILE (forward opts
    # are compile-time), so no runtime atom creation occurs; safe_concat
    # would instead raise whenever the router compiles before the schema —
    # exactly the compile-order dep this AshGraphql-recommended pattern breaks.
    forward("/", Absinthe.Plug,
      # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
      schema: Module.concat(["JidoClaw.Web.GraphQL.Schema"]),
      analyze_complexity: true,
      max_complexity: 200,
      token_limit: 5_000
    )
  end

  # GraphiQL playground — dev convenience, compiled in test ONLY so the
  # wiring tests can prove the guard (prod never compiles this scope). A
  # sibling path, not /gql/graphiql: a /gql forward swallows /gql/*. The
  # guard halts everything except a bodyless, query-less HTML GET — GraphiQL
  # executes documents itself on any other request shape (see GraphiqlGuard).
  if Mix.env() in [:dev, :test] do
    scope "/graphiql" do
      pipe_through([:graphiql_guard])

      # Same compile-time Module.concat rationale as the /gql forward above.
      forward("/", Absinthe.Plug.GraphiQL,
        # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
        schema: Module.concat(["JidoClaw.Web.GraphQL.Schema"]),
        interface: :playground,
        default_url: "/gql"
      )
    end
  end

  # Node-served argus SPA (argus P3). Plug.Static (endpoint, runs before
  # the router) serves the hashed build assets under /argus; everything
  # else falls through here so client-side routes survive refresh.
  scope "/argus", JidoClaw.Web do
    pipe_through(:argus)

    get("/", ArgusController, :index)
    get("/*path", ArgusController, :index)
  end

  # GitHub webhooks (HMAC verified in controller)
  scope "/webhooks", JidoClaw.Web do
    pipe_through(:api)
    post("/github", WebhookController, :github)
  end

  # Auth controller routes. /account-unavailable is the forced-sign-out
  # landing page (inactive tenant / invalid actor): a public page whose
  # CSRF-protected DELETE form posts to /auth/sign-out on an explicit click —
  # never a GET-clears-session route (top-level cross-site GET navigation can
  # carry the cookie even under SameSite=Lax, and deployments may be
  # internet-facing).
  scope "/auth", JidoClaw.Web do
    pipe_through(:browser)

    post("/sign-in", AuthController, :sign_in)
    delete("/sign-out", AuthController, :sign_out)
    get("/account-unavailable", AuthController, :account_unavailable)
  end

  # Session-preserving 503 landing page: LiveView mounts and RequireAuth
  # redirect here when auth state cannot be determined (DB outage). Outside
  # every live_session and auth pipeline — the session must stay untouched so
  # signed-in browsers recover when the database returns.
  scope "/", JidoClaw.Web do
    pipe_through(:browser)

    get("/service-unavailable", AuthController, :service_unavailable)
  end

  # Public LiveView routes (no auth)
  scope "/", JidoClaw.Web do
    pipe_through(:browser)

    live_session :no_auth, on_mount: [{JidoClaw.Web.LiveUserAuth, :live_no_user}] do
      live("/sign-in", SignInLive)
    end
  end

  # Setup probes local binaries, the database, and configured providers. Keep
  # the diagnostic surface behind the same two-layer admin boundary as
  # AshAdmin (HTTP plug + LiveView reconnect hook).
  scope "/", JidoClaw.Web do
    pipe_through([:browser, :require_browser_auth, :require_admin])

    live_session :setup_admin,
      on_mount: [{JidoClaw.Web.LiveUserAuth, :live_admin_required}] do
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
