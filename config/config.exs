import Config

# Register Ollama models in LLMDB catalog (latest 2025 models)
config :llm_db,
  custom: %{
    ollama: [
      name: "Ollama",
      models: %{
        "qwen3.5:35b" => %{
          name: "Qwen 3.5 35B",
          capabilities: %{
            chat: true,
            tools: %{enabled: true, streaming: false, strict: false, parallel: false},
            streaming: %{text: true, tool_calls: false}
          },
          limits: %{context: 131_072, output: 8192}
        },
        "qwen3.5:27b" => %{
          name: "Qwen 3.5 27B",
          capabilities: %{
            chat: true,
            tools: %{enabled: true, streaming: false, strict: false, parallel: false},
            streaming: %{text: true, tool_calls: false}
          },
          limits: %{context: 131_072, output: 8192}
        },
        "qwen3-coder-next:latest" => %{
          name: "Qwen 3 Coder Next",
          capabilities: %{
            chat: true,
            tools: %{enabled: true, streaming: false, strict: false, parallel: false},
            streaming: %{text: true, tool_calls: false}
          },
          limits: %{context: 131_072, output: 16384}
        },
        "qwen3-next:80b" => %{
          name: "Qwen 3 Next 80B",
          capabilities: %{
            chat: true,
            tools: %{enabled: true, streaming: false, strict: false, parallel: false},
            streaming: %{text: true, tool_calls: false}
          },
          limits: %{context: 131_072, output: 8192}
        },
        "devstral-small-2:24b" => %{
          name: "Devstral Small 2 24B",
          capabilities: %{
            chat: true,
            tools: %{enabled: true, streaming: false, strict: false, parallel: false},
            streaming: %{text: true, tool_calls: false}
          },
          limits: %{context: 131_072, output: 16384}
        },
        "nemotron-cascade-2:30b" => %{
          name: "Nemotron Cascade 2 30B (MoE 3B active)",
          capabilities: %{
            chat: true,
            tools: %{enabled: true, streaming: false, strict: false, parallel: false},
            streaming: %{text: true, tool_calls: false}
          },
          limits: %{context: 131_072, output: 8192}
        },
        "glm-4.7-flash:latest" => %{
          name: "GLM 4.7 Flash",
          capabilities: %{
            chat: true,
            tools: %{enabled: true, streaming: false, strict: false, parallel: false},
            streaming: %{text: true, tool_calls: false}
          },
          limits: %{context: 131_072, output: 8192}
        },
        "qwen3:32b" => %{
          name: "Qwen 3 32B",
          capabilities: %{
            chat: true,
            tools: %{enabled: true, streaming: false, strict: false, parallel: false},
            streaming: %{text: true, tool_calls: false}
          },
          limits: %{context: 131_072, output: 8192}
        },
        "nemotron-3-super:cloud" => %{
          name: "Nemotron 3 Super 120B (MoE 12B active, cloud)",
          capabilities: %{
            chat: true,
            tools: %{enabled: true, streaming: false, strict: false, parallel: false},
            streaming: %{text: true, tool_calls: false}
          },
          limits: %{context: 262_144, output: 16384}
        },
        "nemotron-3-super:latest" => %{
          name: "Nemotron 3 Super 120B (MoE 12B active)",
          capabilities: %{
            chat: true,
            tools: %{enabled: true, streaming: false, strict: false, parallel: false},
            streaming: %{text: true, tool_calls: false}
          },
          limits: %{context: 262_144, output: 16384}
        },
        "qwen3-coder:480b" => %{
          name: "Qwen 3 Coder 480B (cloud)",
          capabilities: %{
            chat: true,
            tools: %{enabled: true, streaming: false, strict: false, parallel: false},
            streaming: %{text: true, tool_calls: false}
          },
          limits: %{context: 262_144, output: 32768}
        },
        "deepseek-v3.1:671b" => %{
          name: "DeepSeek V3.1 671B (cloud)",
          capabilities: %{
            chat: true,
            tools: %{enabled: true, streaming: false, strict: false, parallel: false},
            streaming: %{text: true, tool_calls: false}
          },
          limits: %{context: 131_072, output: 16384}
        },
        "qwen3.5:72b" => %{
          name: "Qwen 3.5 72B",
          capabilities: %{
            chat: true,
            tools: %{enabled: true, streaming: false, strict: false, parallel: false},
            streaming: %{text: true, tool_calls: false}
          },
          limits: %{context: 131_072, output: 8192}
        },
        "llama4-maverick:latest" => %{
          name: "Llama 4 Maverick",
          capabilities: %{
            chat: true,
            tools: %{enabled: true, streaming: false, strict: false, parallel: false},
            streaming: %{text: true, tool_calls: false}
          },
          limits: %{context: 1_048_576, output: 16384}
        },
        "kimi-k2.5:latest" => %{
          name: "Kimi K2.5",
          capabilities: %{
            chat: true,
            tools: %{enabled: true, streaming: false, strict: false, parallel: false},
            streaming: %{text: true, tool_calls: false}
          },
          limits: %{context: 131_072, output: 8192}
        }
      }
    ]
  }

# Register Ollama as a custom ReqLLM provider
config :req_llm,
  custom_providers: [JidoClaw.Providers.Ollama]

# Extra commands loaded by the patched Jido.Shell.Command.Registry
# (see lib/jido_claw/core/jido_shell_registry_patch.ex). Compile-time
# config is resolved before SessionManager boots, so the classifier
# sees the full extension set on the first command it routes.
config :jido_shell, :extra_commands, %{
  "jido" => JidoClaw.Shell.Commands.Jido
}

# Model aliases — these get overridden by .jido/config.yaml at boot time
config :jido_ai,
  model_aliases: %{
    fast: "ollama:nemotron-3-super:cloud",
    capable: "ollama:nemotron-3-super:cloud",
    thinking: "ollama:qwen3-next:80b"
  }

config :jido_ai,
  llm_defaults: %{
    text: %{model: :fast, temperature: 0.2, max_tokens: 8192, timeout: 120_000},
    stream: %{model: :fast, temperature: 0.2, max_tokens: 8192, timeout: 120_000}
  }

# Suppress noisy warnings from deps
config :jido_ai, :react_token_secret, "jido_claw_local_secret"

config :logger,
  level: :warning

# -- JidoClaw Platform Config --

# Mode: :cli (REPL only), :gateway (HTTP/WS only), :both (default)
config :jido_claw,
  mode: :both,
  gateway_port: 4000,
  cluster_enabled: false,
  cluster_strategy: :gossip,
  embeddings_strict_boot: true

# Tool-call approval gate (JidoClaw.Security.ToolApproval). A require-listed —
# or param-pattern-triggered — tool call is intercepted in the shared
# Tools.Action wrapper, opens a durable pending AgentCase (kind :tool_call),
# and returns a non-retryable approval_pending error the LLM relays to the
# operator. Approvals are single-use; rejections are deny-once. `enabled?` is
# the kill switch. The conservative default require list is single-sourced in
# `JidoClaw.Security.ToolApproval.default_require/0`
# (network_share, kill_agent, schedule_task, unschedule_task, git_commit,
# forget, replay_workflow); add `require: ~w(...)` here to override it. The
# shell param-pattern triggers (e.g. `git commit` via run_command) also live
# in-module so a config typo can never disable them.
#
# `mcp_require_approval` (default true) is the GLOBAL posture for external MCP
# tools: each `mcp_*` proxy is gated unless its server is explicitly trusted
# (`require_approval: false` in `mcp_servers`, below) or this is flipped to
# false. An unknown `mcp_`-prefixed name (lost/unset policy) falls back to this
# global default — gated by default, so the gate fails CLOSED, never to native.
config :jido_claw, :tool_approval, enabled?: true, mcp_require_approval: true

# AR-8 triage model (JidoClaw.Triage.LLM). A DIRECT model spec passed straight to
# `Jido.AI.generate_object/3` — the `:fast` atom resolves through the user's
# configured model (the REPL aliases `:fast`), and a literal binary like
# "anthropic:claude-haiku-4-5" bypasses `model_aliases` entirely (REPL-safe, no
# alias plumbing). Override to a cheap model to make per-turn triage near-free.
config :jido_claw, :triage_model, :fast

# AR-8 triage: a `:secrets`-signalled code/system turn launches its composer run
# marked sensitive (the scrubber redacts derived plaintext in every durable sink)
# and bounded by this wall-clock deadline (ms) — which also caps how long
# secret-bearing request-correlation state lives. A marked run REQUIRES a positive
# deadline (RouteComposer.validate_sensitive_deadline/2), so the two are set
# together in JidoClaw.FrontDoor. Non-secrets runs stay unmarked and unbounded.
config :jido_claw, :triage_sensitive_deadline_ms, 1_800_000

# External MCP servers to consume (JidoClaw.MCP). Declared in
# `.jido/config.yaml` under `mcp_servers:`; discovered at boot, their tools
# wrapped in the full host safety pipeline and exposed as `mcp_<server>_<tool>`.
# Inert when absent. Example `.jido/config.yaml`:
#
#     mcp_servers:
#       - name: tidewave                 # ^[a-z][a-z0-9_]*$ — also the mcp_ prefix root
#         transport: streamable_http     # stdio | sse | streamable_http
#         url: "http://localhost:4000/tidewave/mcp"
#         require_approval: false        # trusts this server (default: gated)
#       - name: filesystem
#         transport: stdio
#         command: ["npx", "-y", "@modelcontextprotocol/server-filesystem", "/dir"]
#         cwd: "/path/to/project"        # subprocess working dir (optional)
#         env: {FOO: "bar"}              # operator overrides LAYERED ON TOP of the
#                                        # patched transport's default-deny env scrub
#                                        # (omit ⇒ pure default-deny: no host secrets)
#
# Discovery/registration timeouts and the self-heal cadence are tunable under
# `config :jido_claw, :mcp` (production keeps the in-code defaults):
#   - `ready_timeout_ms`, `list_tools_timeout_ms`, `server_prep_timeout_ms`
#   - `reprep_max_attempts` (5), `reprep_backoff_ms` (1_000),
#     `reprep_backoff_max_ms` (30_000) — bounded exponential-backoff re-prep
#     after a hard prep crash, then a terminal tool-less `:failed`
#   - `rediscovery_interval_ms` (300_000; `0` disables auto-arming) — periodic
#     re-discovery that re-syncs each live agent's external tool set

# Boot-time workflow recovery (JidoClaw.Orchestration.WorkflowRecovery).
# Enabled by default; gated off at runtime when clustered or in MCP mode so
# only the single owning node reconciles stranded runs. Disabled in test —
# tests drive WorkflowRecovery.reconcile_all/0 directly inside the sandbox.
config :jido_claw, :workflow_recovery, enabled?: true

# WS1 workflow lease (JidoClaw.Orchestration.WorkflowLease). Durable owner-fence
# for a WorkflowRun: a run is self-claimed on launch and the lease heartbeat
# renews every `renew_seconds`; a fenced (superseded) executor is killed before
# it can write a terminal. Single-node stays byte-identical (nothing expires).
# `lease_seconds` is the claim window; `renew_seconds` the heartbeat interval.
config :jido_claw, :workflow_lease, lease_seconds: 60, renew_seconds: 15

# AR-5 central doctrine injection (JidoClaw.Doctrine → spawn/skill sub-agents).
# Kill switch: disabling restores legacy no-doctrine worker behavior.
config :jido_claw, :doctrine, enabled?: true

# AR-6 persona block, gated WITHIN the (`:doctrine`-master-gated) sub-agent prompt. Toggling
# `:psychology` adds/removes ONLY the `## PSYCHOLOGY` section; it does NOT re-enable injection
# when `:doctrine` is off — `:doctrine` remains the master injection switch.
config :jido_claw, :psychology, enabled?: true

# Tool output shaping (JidoClaw.Tools.OutputShaper). Format-aware compression
# of verbose command output — success noise becomes counts, error detail stays
# verbatim — with the full captured output stored under a ref retrievable via
# the `fetch_output` tool. `enabled?` is the single kill switch: reversibility
# is part of shaping (no separate store toggle), so disabling it restores the
# legacy blind head-truncation behavior byte-for-byte.
config :jido_claw, :output_shaping,
  enabled?: true,
  # outputs smaller than this pass through untouched
  min_shape_bytes: 2_048,
  # SessionManager capture when shaping is on (non-streaming)
  capture_bytes: 512 * 1024,
  ref_ttl_days: 7,
  # verbatim failure blocks budget; remainder counted
  failures_budget_bytes: 24 * 1024,
  generic_head_bytes: 2_048,
  generic_tail_bytes: 4_096

# Destination policy for LLM-controlled egress (JidoClaw.Security.DestinationPolicy,
# gating the browse_web tool). The headless browser otherwise navigates to ANY
# model-supplied URL — an injected page can steer it at loopback / RFC-1918 /
# link-local / tailnet services (local dashboard, admin endpoints, 169.254.169.254
# cloud metadata) and quote their content into the transcript. `enabled?` is the
# kill switch. `allowed_cidrs` punches explicit holes in the built-in deny set
# (allow beats deny) — e.g. browsing your own dashboard on localhost:4000 needs
# ["127.0.0.0/8", "::1/128"]. The post-navigation re-check re-resolves the final
# hostname even when the URL string is unchanged, so typical TTL-0 DNS rebinds
# are caught before any response is quoted (an alternating resolver can still
# slip between checks). Non-goals (documented in the module): the browser's own
# internal *request* — it resolves and fetches out of process; the gate blocks
# response leakage into the transcript, not the fetch itself.
config :jido_claw, :destination_policy,
  enabled?: true,
  allowed_cidrs: []

# Phoenix endpoint — secure-by-default in EVERY env: bind loopback and pin
# WebSocket origins to local hosts. External exposure (e.g. Tailscale) is
# opt-in via PHX_HOST, applied at app start by JidoClaw.Web.GatewayExposure
# (after .env loads — runtime.exs evaluates too early to see it).
# check_origin entries are scheme-agnostic but MUST stay pinned to
# http[:port]: a port-less "//localhost" is an any-port wildcard in Phoenix,
# letting a page on e.g. localhost:3000 open a cookie-bearing socket here.
config :jido_claw, JidoClaw.Web.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  url: [host: "localhost"],
  server: true,
  render_errors: [formats: [json: JidoClaw.Web.ErrorJSON]],
  pubsub_server: JidoClaw.PubSub,
  live_view: [signing_salt: "jidoclaw_lv"],
  check_origin: ["//localhost:4000", "//127.0.0.1:4000", "//[::1]:4000"]

# Dashboard JS bundle (mix assets.build / the dev watcher). NODE_PATH=deps
# resolves the bare "phoenix" / "phoenix_live_view" / "phoenix_html" imports
# from the hex packages' shipped JS — no npm. Output is gitignored
# (priv/static/assets/); `mix setup` builds it.
config :esbuild,
  version: "0.25.0",
  jido_claw: [
    args: ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

# Channel adapters (configure via env vars)
# Discord: DISCORD_BOT_TOKEN, DISCORD_GUILD_ID

# Nostrum (Discord) — only configured when DISCORD_BOT_TOKEN is present
if System.get_env("DISCORD_BOT_TOKEN") do
  config :nostrum,
    token: System.get_env("DISCORD_BOT_TOKEN"),
    gateway_intents: :all,
    num_shards: :auto
end

# -- Ash Framework Config --
config :jido_claw,
  ecto_repos: [JidoClaw.Repo],
  ash_domains: [
    JidoClaw.Accounts,
    JidoClaw.Projects,
    JidoClaw.Security,
    JidoClaw.Forge.Domain,
    JidoClaw.Orchestration,
    JidoClaw.GitHub,
    JidoClaw.Reasoning.Domain,
    JidoClaw.Tenants,
    JidoClaw.Workspaces,
    JidoClaw.Conversations,
    JidoClaw.Solutions.Domain,
    JidoClaw.Embeddings.Domain,
    JidoClaw.Memory.Domain,
    JidoClaw.Audit,
    JidoClaw.Cron,
    JidoClaw.Trace.Domain
  ],
  trace: [
    # JidoClaw.Trace.Collector ring + persistence defaults. See
    # `JidoClaw.Trace.Collector` and `JidoClaw.Trace.Persistence`
    # moduledocs for the bound rationale.
    enabled?: true,
    max_traces: 100,
    max_events_per_trace: 300,
    persist?: true,
    persist_sync?: false,
    # Trace.Policy redaction + sampling (see `JidoClaw.Trace.Policy`).
    # Keep-all sampling, deterministic per-trace via `:erlang.phash2`; accepts 1.
    sample_rate: 1.0,
    # Durable-write target (`JidoClaw.Trace.Sink`). Default delegates to
    # Trace.Persistence; swap to Trace.Sink.InMemory for assertion-only tests.
    sink: JidoClaw.Trace.Sink.Postgres,
    # Additive "[OMITTED]"/"[REDACTED]" key names layered onto the built-in
    # Policy floor (atoms/strings, case-insensitive). Cannot un-redact a built-in.
    extra_omit_keys: [],
    extra_redact_keys: [],
    # Durable retention: trace_runs (and their events) whose `updated_at` is
    # older than this many days are pruned by JidoClaw.Trace.RetentionSweeper.
    # Keyed on updated_at (last activity), so live traces never age out
    # mid-flight. nil / non-positive / non-integer disables sweeping.
    retention_days: 30
  ],
  # AR-8b-2 C3: opt-in TTL sweep of stale `.prototypes/<uuid>/` sketch sandboxes
  # by JidoClaw.VFS.PrototypeRetentionSweeper. DISABLED by default (durability
  # over tidiness — the same posture as the trace `retention_days` note and
  # ComposerArtifact retention): `.prototypes/` is `.gitignore`d, so prototypes
  # never pollute the repo. Set a positive `max_age_days` to enable; a dir is
  # deleted only when stale by effective mtime AND not referenced by a live run.
  prototype_retention: [max_age_days: nil],
  # Per-leaf byte cap applied by WorkflowEvent.Changes.Allocate to persisted
  # event payload/metadata and the raw projection stash (WorkflowRun.result /
  # WorkflowStep.output). 64 KB — deliberately above the 32 KB tool output
  # cap, since a step legitimately aggregates multiple tool outputs.
  workflow_event_payload_max_bytes: 65_536,
  # Max byte size of the serialized replay_inputs blob ReactorRunner persists
  # at launch; an over-cap blob is omitted (run completes but is not
  # replayable — surfaces as {:not_replayable, :no_inputs}).
  workflow_replay_inputs_max_bytes: 1_048_576,
  # Per-command output cap in Core.OsCmd — bounds BEAM memory per external
  # command. Past the cap the OS process tree is killed and the cap-sized
  # output prefix returned; HostShell/Docker map it to exit status 153
  # (Sandbox.output_limit_exit_status/0). Positive integers only —
  # `:infinity` is honored solely as a per-call option, and invalid values
  # normalize to the default, so config can never silently disable the cap.
  os_cmd_max_output_bytes: 10_000_000,
  # Opt-in HostShell resource limits (default off; Docker has cgroups).
  # CPU seconds via `ulimit -t` (portable) and virtual memory KB via
  # `ulimit -v` (enforced on Linux; macOS accepts but does not enforce).
  # Best-effort prelude — a rejected limit never aborts the command.
  # forge_ulimit_cpu_seconds: 600,
  # forge_ulimit_virtual_memory_kb: 2_097_152,
  base_resources: [JidoClaw.Resource]

config :spark, :formatter,
  "JidoClaw.Resource": [
    type: Ash.Resource,
    extensions: [AshPostgres.DataLayer, Ash.Policy.Authorizer]
  ]

# Postgrex types module — registers the pgvector extension so Postgrex
# encodes/decodes :vector columns. Defined at lib/jido_claw/postgrex_types.ex.
config :jido_claw, JidoClaw.Repo, types: JidoClaw.PostgrexTypes

config :ash,
  allow_forbidden_field_for_relationships_by_default?: true,
  include_embedded_source_by_default?: false,
  show_keysets_for_all_actions?: false,
  default_page_type: :keyset,
  policies: [no_filter_static_forbidden_reads?: false],
  default_actions_require_atomic?: true,
  bulk_actions_default_to_errors?: true,
  known_types: [AshPostgres.Timestamptz, AshPostgres.TimestamptzUsec],
  tracer: [JidoClaw.Audit.AshTracer]

config :phoenix, :json_library, Jason

# Timezone database for cron scheduling (JidoClaw.Cron.NextRun). Provided by
# :time_zone_info — data pre-shipped (priv/data.etf), `update: :disabled` so it
# never touches the network or filesystem. Set in all envs (above the trailing
# import_config), so :test resolves zones too. `"Etc/UTC"` short-circuits via
# Elixir's built-in UTCOnlyTimeZoneDatabase and never consults this database.
config :elixir, :time_zone_database, TimeZoneInfo.TimeZoneDatabase

# -- Memory consolidator (v0.6.3 phase 3b) --
#
# Pool sizing note: with `max_concurrent_scopes: 4` the Repo pool
# must accommodate four pinned advisory-lock connections plus the
# rest of the system's reads/writes. Bump
# `config :jido_claw, JidoClaw.Repo, pool_size: N` if base sizing
# is tight (default Ecto pool is 10).
config :jido_claw, JidoClaw.Memory.Consolidator,
  enabled: true,
  cadence: "0 */6 * * *",
  min_input_count: 10,
  max_concurrent_scopes: 4,
  max_candidates_per_tick: 100,
  max_messages_per_run: 500,
  max_facts_per_run: 500,
  max_clusters_per_run: 20,
  # `:harness` accepts `:claude_code | :codex | :fake`. Both CLI
  # harnesses are functional; pick the one the deployment has
  # credentials for.
  harness: :claude_code,
  harness_options: [
    sandbox_mode: :local,
    timeout_ms: 600_000,
    max_turns: 60,
    claude_code: [
      model: "claude-opus-4-7",
      thinking_effort: "xhigh"
    ],
    codex: [
      model: "gpt-5-codex"
    ]
  ],
  write_skip_rows: true

# Environment-specific overrides (test.exs, dev.exs, prod.exs).
# Must be last so env config can override defaults set above.
import_config "#{config_env()}.exs"
