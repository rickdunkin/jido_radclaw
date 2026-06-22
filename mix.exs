defmodule JidoClaw.MixProject do
  use Mix.Project

  @version "0.6.4"

  def project do
    [
      app: :jido_claw,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      consolidate_protocols: Mix.env() != :dev,
      elixirc_paths: elixirc_paths(Mix.env()),
      listeners: [Phoenix.CodeReloader],
      # Intentionally redefining four upstream modules — silences the
      # resulting "redefining module" warnings globally so
      # `--warnings-as-errors` stays green:
      #   - lib/jido_claw/core/anubis_tools_handler_patch.ex
      #     (Anubis.Server.Handlers.Tools 1.6.2 — rescues Peri crash on
      #     jido_mcp JSON Schema, atomizes arguments for Jido actions)
      #   - lib/jido_claw/core/jido_shell_registry_patch.ex
      #     (Jido.Shell.Command.Registry — :extra_commands hook)
      #   - lib/jido_claw/core/jido_shell_session_patch.ex
      #     (Jido.Shell.ShellSession — public update_env/2 wrapper)
      #   - lib/jido_claw/core/jido_shell_session_server_patch.ex
      #     (Jido.Shell.ShellSessionServer — :update_env call handler)
      # Trade-off: accidental shadow of an existing module anywhere else
      # won't warn either; mitigation is code review on new defmodule
      # statements. Remove this line once all four patches above are
      # retired (upstream fixes or forks).
      elixirc_options: [ignore_module_conflict: true],
      deps: deps(),
      escript: escript(),
      releases: releases(),
      compilers: compilers(),
      aliases: aliases(),
      usage_rules: usage_rules(),
      dialyzer: [
        plt_local_path: "priv/plts/dialyzer.plt",
        plt_core_path: "priv/plts/dialyzer-core.plt",
        plt_add_apps: [:ex_unit, :mix, :nostrum, :llm_db],
        flags: [:error_handling, :unknown, :no_opaque],
        ignore_warnings: ".dialyzer_ignore.exs"
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      extra_applications: [:logger, :inets, :ssl, :runtime_tools],
      mod: {JidoClaw.Application, []}
      # Nostrum is started conditionally — see channel_children() in application.ex
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test, "jidoclaw.system_prompt.check": :test]
    ]
  end

  defp escript do
    [
      main_module: JidoClaw.CLI.Main,
      name: "jidoclaw",
      embed_elixir: true
    ]
  end

  defp releases do
    [
      jido_claw: [
        include_executables_for: [:unix],
        applications: [runtime_tools: :permanent]
      ]
    ]
  end

  defp compilers do
    Enum.flat_map(Mix.compilers(), fn
      :app -> [:jidoclaw_release_patches, :app]
      compiler -> [compiler]
    end)
  end

  defp usage_rules do
    # Example for those using claude.
    [
      file: "AGENTS.md",
      # rules to include directly in AGENTS.md
      # :usage_rules itself provides rules for search_docs, docs, etc.
      # use a regex to match multiple deps, or atoms/strings for specific ones
      usage_rules: [:usage_rules],
      # or use skills
      skills: [
        location: ".agents/skills",
        deps: [:req],
        # build skills that combine multiple usage rules
        build: [
          "ash-framework": [
            # The description tells people how to use this skill.
            description:
              "Use this skill working with Ash Framework or any of its extensions. Always consult this when making any domain changes, features or fixes.",
            # Include all Ash dependencies
            usage_rules: [:ash, ~r/^ash_/]
          ],
          "phoenix-framework": [
            description:
              "Use this skill working with Phoenix Framework. Consult this when working with the web layer, controllers, views, liveviews etc.",
            # Include all Phoenix dependencies
            usage_rules: [:phoenix, ~r/^phoenix_/]
          ],
          "jido-framework": [
            description:
              "Use this skill working with Jido Framework. Consult this when working with the agent layer, agents, prompts, templates, workers etc.",
            # Include all Jido dependencies
            usage_rules: [:jido, ~r/^jido_/]
          ]
        ]
      ]
    ]
  end

  defp deps do
    [
      {:makeup_js, "~> 0.1", only: [:dev, :test]},
      {:makeup_elixir, "~> 1.0", only: [:dev, :test]},
      {:makeup, "~> 1.0", only: [:dev, :test]},
      {:reach, "~> 2.2", only: [:dev, :test], runtime: false},
      {:ash_credo, "~> 0.12", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.2", only: [:dev, :test], runtime: false},
      {:ex_dna, "~> 1.3", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_harness, "~> 0.1", only: [:dev, :test], runtime: false},
      {:usage_rules, "~> 1.0", only: [:dev]},
      {:tidewave, "~> 0.5", only: :dev},
      {:igniter, "~> 0.5", only: [:dev, :test]},
      # Jido framework (agent engine) — overrides for cross-repo compatibility
      {:jido, "~> 2.1", override: true},
      {:jido_ai, "~> 2.0", override: true},
      {:jido_action, "~> 2.0", override: true},
      {:req_llm, "~> 1.14", override: true},
      {:libgraph,
       github: "zblanco/libgraph", ref: "32280656f808090df85f0facabac27a51a6d2f92", override: true},

      # Jido ecosystem — full stack
      {:jido_signal, "~> 2.0", override: true},
      {:jido_mcp, "~> 1.0", override: true},
      {:jido_browser, "~> 2.0"},
      {:jido_chat, "~> 1.0", override: true},
      {:jido_skill,
       github: "agentjido/jido_skill",
       ref: "cc5ec5aaf5ae1c362952cb71949e759e570ddb82",
       override: true},
      {:jido_composer, "~> 0.3"},
      {:jido_messaging, "~> 1.0", override: true},
      {:jido_shell,
       github: "agentjido/jido_shell",
       ref: "18d892d16e1366fe152048ba6f60e8cda1b1de4b",
       override: true},
      {:jido_vfs, "~> 1.0", override: true},

      # Data
      {:jason, "~> 1.4"},
      {:yaml_elixir, "~> 2.12"},
      {:glob_ex, "~> 0.1"},
      # Pure-BEAM parser combinator; substrate for the shell-aware run_command
      # approval analyzer (JidoClaw.Security.ShellCommand). Already resolved at
      # 1.4.2 transitively (makeup, abnf_parsec, time_zone_info) — declared
      # direct so `deps.unlock --unused` keeps it and the use is explicit.
      {:nimble_parsec, "~> 1.4"},

      # Phoenix gateway
      {:phoenix, "~> 1.7"},
      # Dashboard JS bundler (mix assets.build / the dev watcher). The
      # `mix esbuild` task auto-downloads the binary on first run.
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:phoenix_html, "~> 4.0"},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_live_dashboard, "~> 0.8"},
      {:bandit, "~> 1.5"},
      {:phoenix_pubsub, "~> 2.1"},

      # Telemetry
      {:certifi, "~> 2.15", override: true},
      {:telemetry, "~> 1.2", override: true},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.1"},

      # Scheduling
      {:crontab, "~> 1.1"},
      # Timezone database for cron firing (JidoClaw.Cron.NextRun). Transitive
      # via :jido; declared explicitly to decouple from jido's tree. Ships
      # priv/data.etf (IANA v2026b) and defaults to `update: :disabled` — no
      # network/fs at runtime. Already resolved, so `deps.unlock --unused` keeps it.
      {:time_zone_info, "~> 0.7"},

      # Clustering
      {:libcluster, "~> 3.4"},

      # HTTP client
      {:finch, "~> 0.19"},
      {:req, "~> 0.5"},

      # Discord (optional — only starts when DISCORD_BOT_TOKEN is set).
      # Excluded from the test env entirely: nostrum crashes at startup without a
      # valid token and the Discord adapter guards calls with Code.ensure_loaded/1.
      {:nostrum, "~> 0.10", optional: true, runtime: false},

      # Ash framework and extensions
      {:ash, "~> 3.0"},
      {:ash_phoenix, "~> 2.0"},
      {:ash_postgres, "~> 2.0"},
      {:ash_json_api, "~> 1.0"},
      {:ash_authentication, "~> 4.0"},
      {:ash_authentication_phoenix, "~> 2.0"},
      {:ash_admin, "~> 1.0"},
      {:ash_archival, "~> 2.0"},
      {:ash_paper_trail, "~> 0.5"},
      {:ash_cloak, "~> 0.2"},
      {:ash_state_machine, "~> 0.2"},

      # Database
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},

      # Security & encryption
      {:bcrypt_elixir, "~> 3.0"},
      {:cloak, "~> 1.0"},

      # Ash utilities
      {:picosat_elixir, "~> 0.2"},
      {:splode, "~> 0.3"}
    ]
  end

  defp aliases do
    [
      # assets.build is in setup because the gateway dashboard needs
      # priv/static/assets/app.js to exist (the bundle is gitignored); any
      # clean checkout must run it before the dashboard has working JS.
      setup: ["deps.get", "ash.setup", "assets.build"],
      "assets.build": ["esbuild jido_claw"],
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ash.setup --quiet", "test"],
      precommit: [
        "jidoclaw.compile_check",
        "jidoclaw.system_prompt.check",
        "deps.unlock --unused",
        "format --check-formatted",
        "reach.check --arch --smells --strict",
        "credo --strict",
        "dialyzer --format short",
        "test"
      ]
    ]
  end
end
