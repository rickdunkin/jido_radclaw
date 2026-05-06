import Config

config :jido_claw, mode: :cli
config :jido_claw, :reasoning_telemetry_sync, true
# Streaming output cap override: 100 KB for tests so cap-overflow tests
# don't have to generate megabytes of data. Production default is 10 MB.
# Honored only on the streaming branch — non-streaming stays at 50 KB.
config :jido_claw, :test_streaming_max_output_bytes_override, 100_000
config :logger, level: :warning

# Ecto's SQL.Sandbox wraps every test in a transaction, so any Ash
# action whose changeset registers `after_transaction` hooks would
# trip the "ongoing transaction still happening" warning on every
# test run. Suppress per Ash's documented option #1 for sandbox-mode
# data layers.
config :ash, warn_on_transaction_hooks?: false

config :jido_claw, JidoClaw.Repo,
  username: "rhl",
  password: "",
  hostname: "localhost",
  database: "jido_claw_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox

# Forge defaults to `/var/local/forge`, which is not writable on most
# CI / dev machines. Per-run consolidator dirs land under this base in
# 3c, so route tests at a tmp path the runner can mkdir into. Tests
# that need a specific tmp dir (e.g., the cleanup regression) override
# via `Application.put_env`.
config :jido_claw,
       :forge_home,
       Path.join(
         System.tmp_dir!(),
         "jido_claw_forge_test#{System.get_env("MIX_TEST_PARTITION", "")}"
       )
