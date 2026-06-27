import Config

config :jido_claw, mode: :cli
config :jido_claw, token_signing_secret: String.duplicate("test_token_signing_secret_", 4)

# server: false lets route tests start_supervised the endpoint without
# binding a port (mode: :cli already keeps it out of the app tree).
config :jido_claw, JidoClaw.Web.Endpoint,
  secret_key_base: String.duplicate("test_secret_key_base_", 4),
  server: false

config :jido_claw, :reasoning_telemetry_sync, true

# Boot recovery off in test — tests drive WorkflowRecovery.reconcile_all/0
# directly inside the Ecto sandbox, so an ungated boot scan never runs.
config :jido_claw, :workflow_recovery, enabled?: false

# WS1 lease: a very large `renew_seconds` so the production auto-renew timer
# never races a test inside its own scope — tests drive the sidecar explicitly
# via the `{:lease_tick, from}` seam. `lease_seconds` keeps the prod default so
# `fence_decision/3`'s lease-window math is exercised realistically.
config :jido_claw, :workflow_lease, lease_seconds: 60, renew_seconds: 86_400

# Output shaping off in test so the existing 10KB-truncation tests stay
# green; shaping tests opt in via Application.put_env + on_exit restore.
config :jido_claw, :output_shaping, enabled?: false

# AR-5 doctrine injection off in test so existing spawn/skill tests run on
# today's no-doctrine behavior; doctrine's own tests opt in via
# Application.put_env + on_exit (async: false).
config :jido_claw, :doctrine, enabled?: false

# AR-6 personas off in test so existing spawn/skill prompt tests stay on today's
# behavior; the persona tests opt in via Application.put_env + on_exit (async: false),
# mirroring :doctrine.
config :jido_claw, :psychology, enabled?: false

# Tool-call approval gate off in test so the broad tool suite isn't gated;
# the gate's own tests drive JidoClaw.Security.ToolApproval.gate/4 with explicit
# `enabled?: true` + `require:` opts (env-free, DestinationPolicy style).
config :jido_claw, :tool_approval, enabled?: false

# External MCP consumption: the suite drives JidoClaw.MCP.Consumer through an
# injectable Stub client (no real transport), and the boot Consumer is gated
# off so consumer_test starts its own under start_supervised (the named
# singleton can't collide with a boot instance).
config :jido_claw, :mcp_client, JidoClaw.MCP.Client.Stub
config :jido_claw, :mcp_consumer_enabled?, false

# Fast-but-observable re-prep backoff; re-discovery is driven manually via
# `send(consumer, :rediscover)` (interval 0 ⇒ no auto-arming) for determinism.
config :jido_claw, :mcp,
  reprep_backoff_ms: 50,
  reprep_backoff_max_ms: 100,
  reprep_max_attempts: 2,
  rediscovery_interval_ms: 0

# Trace persistence is opt-in for tests. The Collector still ingests
# events into the in-memory ring on every run, but
# `JidoClaw.Trace.Persistence.append/2` is a no-op unless a test
# explicitly flips `persist?: true` (and usually `persist_sync?: true`)
# in its setup. This keeps async Persistence writes from outliving the
# `Ecto.Adapters.SQL.Sandbox` owner.
config :jido_claw, :trace, persist?: false

# AR-8 triage: default the impl to the deterministic stub so every chat-path test
# routes through the (talk-by-default) front door without a real LLM call. A test
# that exercises triage flips `:triage_canned_verdict` / injects a custom impl.
config :jido_claw, :triage_impl, JidoClaw.Test.TriageStub

# Recorder flush barrier: tests rarely emit the real `ai.request.completed`
# terminal signal (LLM calls are stubbed), so the dispatcher / sub-agent
# transcript flush would otherwise block on the 30s production default. A
# short timeout keeps the best-effort flush from stalling test runs; tests
# that need a specific value override it locally.
config :jido_claw, :recorder_flush_timeout, 200

# Tests don't have VOYAGE_API_KEY set; the per-call defense in
# `JidoClaw.Embeddings.Voyage` already returns `{:error, :missing_api_key}`
# at the call site, which is what test fixtures rely on.
config :jido_claw, :embeddings_strict_boot, false
# Streaming output cap override: 100 KB for tests so cap-overflow tests
# don't have to generate megabytes of data. Production default is 10 MB.
# Honored only on the streaming branch — non-streaming stays at 50 KB.
config :jido_claw, :test_streaming_max_output_bytes_override, 100_000
config :logger, level: :warning

# Test-only Cloak key. Non-test boots must provide CLOAK_KEY or CLOAK_KEY_FILE
# at runtime; see JidoClaw.Security.VaultConfig.
config :jido_claw, JidoClaw.Security.Vault,
  ciphers: [
    default:
      {Cloak.Ciphers.AES.GCM,
       tag: "AES.GCM.V1",
       key: Base.decode64!("dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHQ="),
       iv_length: 12}
  ]

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
