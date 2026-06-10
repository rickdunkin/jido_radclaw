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
config :jido_claw, JidoClaw.Web.Endpoint,
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:jido_claw, ~w(--sourcemap=inline --watch)]}
  ]
