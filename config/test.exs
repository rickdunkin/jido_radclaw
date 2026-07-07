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

# WS3 reclaim Pooler off in test — tests drive `ReclaimPooler.reclaim_once/0`
# directly inside the Ecto sandbox (like `WorkflowRecovery.reconcile_all/0`), so
# the always-on poll loop never races a test in its own scope. The timing knobs
# keep prod defaults so the bounded-window math is exercised realistically.
config :jido_claw, :reclaim_pooler,
  enabled?: false,
  poll_interval_ms: 15_000,
  initial_delay_ms: 5_000

# WS4a user-cron Owner off in test so the boot singleton can't collide with the
# `start_supervised`-started Owners the owner_test drives explicitly (those pass
# `enabled?: true`), nor touch the SQL sandbox outside the test owner.
config :jido_claw, :cron_owner, enabled?: false

# Output shaping off in test so the existing 10KB-truncation tests stay
# green; shaping tests opt in via Application.put_env + on_exit restore.
config :jido_claw, :output_shaping, enabled?: false

# Doom-loop guard off in test so the broad tool suite isn't guarded; the
# guard's own tests pass explicit opts (pure/store) or opt in via
# Application.put_env + on_exit restore (integration, async: false).
config :jido_claw, :loop_guard, enabled?: false

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

# Deterministic verify (item 5): the runner + git seams point at the test stub
# so any full-catalog composer launch stays hermetic — no subprocess, no real
# git; the stub defaults to exit-0 checks + stable head/porcelain/digest (a
# certified green) and is scripted per-test via :route_composer_verify_stub.
# Timeout/output caps keep prod defaults (the stub never runs anything).
config :jido_claw, :verify,
  runner: JidoClaw.Test.VerifyStub,
  git: JidoClaw.Test.VerifyStub,
  timeout_ms: 900_000,
  max_output_bytes: 10_000_000,
  tail_lines: 40

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

# Recorder flush barrier: the test-support LLM stubs emit the terminal
# `ai.request.completed` / `ai.request.failed` signal themselves (via
# `JidoClaw.Test.TerminalSignal`), so flush returns immediately on stubbed
# paths. The 50ms cap remains as backstop for the paths that intentionally
# don't emit: subagent_transcript_test's direct flush calls, the opted-out
# correlation test (agent_runner_test.exs, `:echo_stub_emit_terminal`
# false), recorder_test's own timeout-contract test, and Recorder
# bus-restart windows. A full serial run hits ~7 flush timeouts (was
# ~500 ≈ 25s of dead wait before the stubs emitted; 159s → 113s serial).
config :jido_claw, :recorder_flush_timeout, 50

# Disarm the memory-consolidator system cron (config.exs arms it
# `0 */6 * * *` UTC): a suite run crossing that boundary gets a tick that
# sweeps EVERY workspace the run has accumulated, fanning out advisory-lock
# tasks that drain the shared sandbox pool and cascade queue-timeout
# failures across whichever module is running (observed: 12
# composer_durable failures at an 18:00 UTC crossing). `enabled` only
# gates the boot-time cron registration (`Scheduler.start_system_jobs/0`);
# consolidator tests drive tick/run_now/RunServer directly and keep the
# rest of this config block via the per-key merge.
config :jido_claw, JidoClaw.Memory.Consolidator, enabled: false

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

# Cluster suite (JIDOCLAW_CLUSTER_TEST=1, via scripts/test-cluster.sh): swap
# the SQL sandbox for the regular pool + a dedicated DB so a real :peer
# cluster shares ONE Postgres across BEAMs — sandbox ownership cannot span
# nodes. Gated so normal `mix test`/precommit keep the sandbox. Merges onto
# the JidoClaw.Repo block above.
if System.get_env("JIDOCLAW_CLUSTER_TEST") == "1" do
  config :jido_claw, JidoClaw.Repo,
    database: "jido_claw_cluster_test",
    pool: DBConnection.ConnectionPool,
    pool_size: 10
end

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
