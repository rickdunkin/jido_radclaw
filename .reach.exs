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
      "JidoClaw.Folio.*",
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
  ]
]
