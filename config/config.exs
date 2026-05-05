import Config

# Disable tzdata auto-update (escripts can't access priv dirs)
config :tzdata, :autoupdate, :disabled

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
          limits: %{context_window: 131_072, max_output_tokens: 8192}
        },
        "qwen3.5:27b" => %{
          name: "Qwen 3.5 27B",
          capabilities: %{
            chat: true,
            tools: %{enabled: true, streaming: false, strict: false, parallel: false},
            streaming: %{text: true, tool_calls: false}
          },
          limits: %{context_window: 131_072, max_output_tokens: 8192}
        },
        "qwen3-coder-next:latest" => %{
          name: "Qwen 3 Coder Next",
          capabilities: %{
            chat: true,
            tools: %{enabled: true, streaming: false, strict: false, parallel: false},
            streaming: %{text: true, tool_calls: false}
          },
          limits: %{context_window: 131_072, max_output_tokens: 16384}
        },
        "qwen3-next:80b" => %{
          name: "Qwen 3 Next 80B",
          capabilities: %{
            chat: true,
            tools: %{enabled: true, streaming: false, strict: false, parallel: false},
            streaming: %{text: true, tool_calls: false}
          },
          limits: %{context_window: 131_072, max_output_tokens: 8192}
        },
        "devstral-small-2:24b" => %{
          name: "Devstral Small 2 24B",
          capabilities: %{
            chat: true,
            tools: %{enabled: true, streaming: false, strict: false, parallel: false},
            streaming: %{text: true, tool_calls: false}
          },
          limits: %{context_window: 131_072, max_output_tokens: 16384}
        },
        "nemotron-cascade-2:30b" => %{
          name: "Nemotron Cascade 2 30B (MoE 3B active)",
          capabilities: %{
            chat: true,
            tools: %{enabled: true, streaming: false, strict: false, parallel: false},
            streaming: %{text: true, tool_calls: false}
          },
          limits: %{context_window: 131_072, max_output_tokens: 8192}
        },
        "glm-4.7-flash:latest" => %{
          name: "GLM 4.7 Flash",
          capabilities: %{
            chat: true,
            tools: %{enabled: true, streaming: false, strict: false, parallel: false},
            streaming: %{text: true, tool_calls: false}
          },
          limits: %{context_window: 131_072, max_output_tokens: 8192}
        },
        "qwen3:32b" => %{
          name: "Qwen 3 32B",
          capabilities: %{
            chat: true,
            tools: %{enabled: true, streaming: false, strict: false, parallel: false},
            streaming: %{text: true, tool_calls: false}
          },
          limits: %{context_window: 131_072, max_output_tokens: 8192}
        },
        "nemotron-3-super:cloud" => %{
          name: "Nemotron 3 Super 120B (MoE 12B active, cloud)",
          capabilities: %{
            chat: true,
            tools: %{enabled: true, streaming: false, strict: false, parallel: false},
            streaming: %{text: true, tool_calls: false}
          },
          limits: %{context_window: 262_144, max_output_tokens: 16384}
        },
        "nemotron-3-super:latest" => %{
          name: "Nemotron 3 Super 120B (MoE 12B active)",
          capabilities: %{
            chat: true,
            tools: %{enabled: true, streaming: false, strict: false, parallel: false},
            streaming: %{text: true, tool_calls: false}
          },
          limits: %{context_window: 262_144, max_output_tokens: 16384}
        },
        "qwen3-coder:480b" => %{
          name: "Qwen 3 Coder 480B (cloud)",
          capabilities: %{
            chat: true,
            tools: %{enabled: true, streaming: false, strict: false, parallel: false},
            streaming: %{text: true, tool_calls: false}
          },
          limits: %{context_window: 262_144, max_output_tokens: 32768}
        },
        "deepseek-v3.1:671b" => %{
          name: "DeepSeek V3.1 671B (cloud)",
          capabilities: %{
            chat: true,
            tools: %{enabled: true, streaming: false, strict: false, parallel: false},
            streaming: %{text: true, tool_calls: false}
          },
          limits: %{context_window: 131_072, max_output_tokens: 16384}
        },
        "qwen3.5:72b" => %{
          name: "Qwen 3.5 72B",
          capabilities: %{
            chat: true,
            tools: %{enabled: true, streaming: false, strict: false, parallel: false},
            streaming: %{text: true, tool_calls: false}
          },
          limits: %{context_window: 131_072, max_output_tokens: 8192}
        },
        "llama4-maverick:latest" => %{
          name: "Llama 4 Maverick",
          capabilities: %{
            chat: true,
            tools: %{enabled: true, streaming: false, strict: false, parallel: false},
            streaming: %{text: true, tool_calls: false}
          },
          limits: %{context_window: 1_048_576, max_output_tokens: 16384}
        },
        "kimi-k2.5:latest" => %{
          name: "Kimi K2.5",
          capabilities: %{
            chat: true,
            tools: %{enabled: true, streaming: false, strict: false, parallel: false},
            streaming: %{text: true, tool_calls: false}
          },
          limits: %{context_window: 131_072, max_output_tokens: 8192}
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
  tool_approval_mode: :off

# Phoenix endpoint
config :jido_claw, JidoClaw.Web.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  http: [port: 4000],
  url: [host: "localhost"],
  server: true,
  secret_key_base:
    "jidoclaw_dev_secret_key_base_at_least_64_bytes_long_for_signing_and_encryption_purposes",
  render_errors: [formats: [json: JidoClaw.Web.ErrorJSON]],
  pubsub_server: JidoClaw.PubSub,
  live_view: [signing_salt: "jidoclaw_lv"],
  check_origin: false

# Channel adapters (configure via env vars)
# Discord: DISCORD_BOT_TOKEN, DISCORD_GUILD_ID
# Telegram: TELEGRAM_BOT_TOKEN

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
    JidoClaw.Folio,
    JidoClaw.Reasoning.Domain,
    JidoClaw.Workspaces,
    JidoClaw.Conversations,
    JidoClaw.Solutions.Domain,
    JidoClaw.Embeddings.Domain,
    JidoClaw.Memory.Domain
  ],
  token_signing_secret: "jidoclaw_dev_token_signing_secret_at_least_64_bytes_for_security"

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
  known_types: [AshPostgres.Timestamptz, AshPostgres.TimestamptzUsec]

# Cloak Vault for encrypted secret storage
config :jido_claw, JidoClaw.Security.Vault,
  ciphers: [
    default: {
      Cloak.Ciphers.AES.GCM,
      tag: "AES.GCM.V1",
      key: Base.decode64!("dGhpc19pc19hX2Rldl9vbmx5X2tleV8zMl9ieXRlcw=="),
      iv_length: 12
    }
  ]

config :phoenix, :json_library, Jason

# Environment-specific overrides (test.exs, dev.exs, prod.exs).
# Must be last so env config can override defaults set above.
import_config "#{config_env()}.exs"
