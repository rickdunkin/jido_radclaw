import Config

config :jido_claw, mode: :cli
config :jido_claw, :reasoning_telemetry_sync, true
config :logger, level: :warning

config :jido_claw, JidoClaw.Repo,
  username: "rhl",
  password: "",
  hostname: "localhost",
  database: "jido_claw_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox
