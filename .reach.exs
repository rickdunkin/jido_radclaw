# Reach configuration — https://hexdocs.pm/reach/configuration.html
#
# Goal: drive `mix reach.check --arch --smells --strict` to zero, then add it to
# the `precommit` alias so we stay at zero. Architecture coverage is intentionally
# NOT required (checks.layer_coverage defaults off), so only the modules named in
# `layers` participate — everything else is unconstrained.
[
  # ── Architectural layers ──────────────────────────────────────────────────
  # Real namespaces (verified against lib/): the web tier is `JidoClaw.Web.*`
  # (NOT `JidoClawWeb`), and the persistence tier is the Repo + Ash domains.
  layers: [
    web: "JidoClaw.Web.*",
    data: [
      "JidoClaw.Repo",
      "JidoClaw.Accounts.*",
      "JidoClaw.Audit.*",
      "JidoClaw.Trace.*"
    ]
  ],

  # ── Forbidden cross-layer dependencies ────────────────────────────────────
  # The one invariant that is unambiguously true today: persistence / Ash
  # resources must never reach "up" into the web tier. (A `domain` layer can be
  # added later by enumerating core business namespaces — left out of the first
  # cut to avoid the `JidoClaw.*` catch-all overlapping `JidoClaw.Web.*`.)
  deps: [
    forbidden: [
      {:data, :web}
    ]
  ],

  # ── Removed-code guards (forward-looking) ─────────────────────────────────
  # Matches nothing today; keeps a deleted `Legacy` namespace from reappearing.
  source: [
    forbidden_modules: ["JidoClaw.Legacy.*"],
    forbidden_files: ["lib/jido_claw/legacy/**"]
  ],

  # ── Test hints (surface in `mix reach.check --changed`) ───────────────────
  # Source-file -> tests. All paths verified to exist.
  tests: [
    hints: [
      {"lib/jido_claw/agent_view.ex", ["test/jido_claw/agent_view_test.exs"]},
      {"lib/jido_claw/inspection.ex", ["test/jido_claw/inspection_test.exs"]},
      {"lib/jido_claw/inspection/summary.ex", ["test/jido_claw/inspection/summary_test.exs"]},
      {"lib/jido_claw/tools/agent_status.ex", ["test/jido_claw/tools/agent_status_test.exs"]},
      {"lib/jido_claw/tools/inspect_agent.ex", ["test/jido_claw/tools/inspect_agent_test.exs"]},
      {"lib/jido_claw/web/live/agents_live.ex", ["test/jido_claw/web/live/agents_live_test.exs"]},
      {"lib/jido_claw/core/mcp_server.ex", ["test/jido_claw/mcp_server_test.exs"]}
    ]
  ],

  # ── Smell scopes ──────────────────────────────────────────────────────────
  # Cross-file `fixed_shape_map` findings: shapes that legitimately recur across
  # modules and so cannot be pinned by an inline pragma (reach's anchor for an
  # aggregated shape drifts between runs). Each group is a real contract — Ash
  # action attrs, a library/external input shape, a surface-neutral projection,
  # an internal accumulator, or a canonical scope/stats rollup — scoped here per
  # the recorded "fix real data, scope the rest" policy. The two genuine wins
  # were instead fixed structurally: the 10-site audit duplication now flows
  # through `JidoClaw.Audit.EventAttrs.new/1`, and the setup credential check is
  # a `JidoClaw.Setup.CredentialCheck` struct. Single-file shapes are scoped at
  # their source with `# reach:disable-for-this-file fixed_shape_map` instead.
  smells: [
    fixed_shape_map: [
      ignore: [
        modules: [
          # error-normalizer result shapes (Error.Normalize subsystem internals)
          "JidoClaw.Error.Normalize",
          "JidoClaw.Error.Normalize.Common",
          # `/solutions` stats + strategy-stats rollups
          "JidoClaw.CLI.Commands",
          "JidoClaw.CLI.Commands.SolutionsStats",
          "JidoClaw.Reasoning.Statistics",
          # token-usage rollup {cost, input_tokens, output_tokens}
          "JidoClaw.Inspection",
          "JidoClaw.Inspection.Summary",
          # solution match result {solution, score, match_type}
          "JidoClaw.Solutions.Matcher",
          "JidoClaw.Tools.FindSolution",
          # Jido.AI RunStrategy call params {strategy, prompt, timeout}
          "JidoClaw.Tools.Reason",
          "JidoClaw.Tools.RunPipeline",
          "JidoClaw.Tools.VerifyCertificate",
          "JidoClaw.Reasoning.LLMTiebreaker",
          # workflow step params {template, task, project_dir, name}
          "JidoClaw.Skills",
          "JidoClaw.Workflows.SkillWorkflow",
          "JidoClaw.Workflows.PlanWorkflow",
          "JidoClaw.Workflows.StepAction",
          "JidoClaw.Workflows.IterativeWorkflow",
          "JidoClaw.Agent.Handoff.Router",
          "JidoClaw.CLI.Repl",
          # surface-neutral conversation/message projections + agent-view context
          "JidoClaw",
          "JidoClaw.AgentView",
          "JidoClaw.Session.Worker",
          "Mix.Tasks.Jidoclaw.Migrate.Conversations",
          "Mix.Tasks.Jidoclaw.Export.Conversations",
          # Ash Conversations.Message create attrs
          "JidoClaw.Tools.MCPScope",
          "JidoClaw.Conversations.Recorder",
          # Ash Memory.Block create attrs + canonical runtime-scope map
          # (block.ex nests its Ash change/preparation modules, hence the glob)
          "JidoClaw.Memory.Block",
          "JidoClaw.Memory.Block.*",
          "JidoClaw.Memory.Consolidator.RunServer",
          "JidoClaw.Memory.Consolidator",
          "JidoClaw.Memory.Scope",
          "Mix.Tasks.Jidoclaw.Export.Memory"
        ]
      ]
    ],
    behaviour_candidate: [
      ignore: [
        modules: [
          # Forge runners already implement `@behaviour JidoClaw.Forge.Runner` —
          # the shared init/2, run_iteration/3, apply_input/3 ARE its callbacks,
          # so reach's "extract a behaviour" suggestion is a false positive.
          "JidoClaw.Forge.Runners.*",
          # Deliberate surface-neutral parallel view projections (list/1,
          # snapshot/2, to_mcp_map/1) — not interchangeable implementations of a
          # shared contract; imposing a behaviour would over-couple them.
          "JidoClaw.ForgeView",
          "JidoClaw.SwarmView",
          "JidoClaw.WorkflowView"
        ]
      ]
    ]
  ]
]
