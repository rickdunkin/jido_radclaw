import Config

config :ash, policies: [show_policy_breakdowns?: true]

config :jido_claw, JidoClaw.Repo,
  username: "rhl",
  password: "",
  hostname: "localhost",
  database: "jido_claw_dev",
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

config :jido_claw, dev_routes: true

# Rebuild the dashboard JS bundle on change while the gateway runs in dev.
# check_origin: the argus Vite dev server (localhost:5173) proxies /argus/ws
# here without rewriting the browser Origin (rewriteWsOrigin is a CSRF
# hazard), so dev allows that origin explicitly — port-pinned like the base
# entries (a port-less "//localhost" would be an any-port wildcard; see
# config.exs). GatewayExposure appends PHX_HOST origins on top.
config :jido_claw, JidoClaw.Web.Endpoint,
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:jido_claw, ~w(--sourcemap=inline --watch)]}
  ],
  check_origin: [
    "//localhost:4000",
    "//127.0.0.1:4000",
    "//[::1]:4000",
    "//localhost:5173"
  ]
