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
  tool_approval_mode: :off,
  embeddings_strict_boot: true

# Boot-time workflow recovery (JidoClaw.Orchestration.WorkflowRecovery).
# Enabled by default; gated off at runtime when clustered or in MCP mode so
# only the single owning node reconciles stranded runs. Disabled in test —
# tests drive WorkflowRecovery.reconcile_all/0 directly inside the sandbox.
config :jido_claw, :workflow_recovery, enabled?: true

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
    # Durable retention: trace_runs (and their events) whose `updated_at` is
    # older than this many days are pruned by JidoClaw.Trace.RetentionSweeper.
    # Keyed on updated_at (last activity), so live traces never age out
    # mid-flight. nil / non-positive / non-integer disables sweeping.
    retention_days: 30
  ],
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
