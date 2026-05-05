# Phase 3c — Memory: Codex Sibling Runner

**Goal:** add `JidoClaw.Forge.Runners.Codex` as a sibling to
`JidoClaw.Forge.Runners.ClaudeCode` so the consolidator (Phase 3b)
can be configured with `harness: :codex`. After 3c, operators can
swap harnesses without touching consolidator code, and the
provenance row written by every consolidator run records which
harness produced its proposals.

## 3c.0 Scope and dependencies

### What 3c ships

- `lib/jido_claw/forge/runners/codex.ex` — implements the
  `JidoClaw.Forge.Runner` behaviour (`init/2`, `run_iteration/3`,
  `apply_input/3`); spawns the `codex` CLI with the same
  `--mcp-config <path>` flag injection and stream-json output
  parsing that 3b added to `ClaudeCode`.
- `sync_host_codex_config/1` — mirrors
  `JidoClaw.Forge.Runners.ClaudeCode.sync_host_claude_config/1`'s
  shape, against `~/.codex/` instead of `~/.claude/`. Reads a
  whitelist of credentials/settings, base64-encodes them, writes
  into the sandbox's `/var/local/forge/.codex/`.
- Runtime registration: the `harness:` config knob in
  `JidoClaw.Memory.Consolidator`'s app-env block (introduced in
  3b) now resolves `:codex` to the new runner; until 3c, a
  deployment with `harness: :codex` returns
  `:no_runner_configured` from the consolidator and writes
  `status: :failed, error: :no_runner_configured` on every run.
- Cross-runner acceptance gate: a consolidator opt-out / harness
  invocation round-trip that mirrors §3.19's existing gates but
  drives `harness: :codex` instead of `:claude_code`.

### Out of scope

- Codex-specific tool surface customisation (the consolidator's
  scoped tool list from 3b applies unchanged — both harnesses see
  the same eleven `propose_*` / `commit_proposals` / etc. tools).
- Per-runner stream-json schema differences. Both Claude Code and
  Codex emit JSON-Lines compatible with the `tool_use` /
  `tool_result` event shapes the runner-extension code in 3b
  parses; if Codex's output proves incompatible during
  implementation, that's a 3c bug, not a re-design.
- Auto-detection of which runner is available at boot. Operators
  configure `harness:` explicitly via `config :jido_claw,
  JidoClaw.Memory.Consolidator, harness: ...`.

### Dependencies

- **Phase 3b:** `JidoClaw.Memory.Consolidator`, the scoped MCP
  server, the `Cron.Scheduler.start_system_jobs/0` entry, the
  per-session `sandbox_mode` knob, and the `ClaudeCode` runner
  extensions (especially the `--mcp-config` injection and the
  stream-json `tool_use` / `tool_result` parser). 3c reuses every
  one of those — Codex slots into the same orchestration as a
  drop-in.
- **Pre-existing baseline:** `JidoClaw.Forge.Runner` behaviour
  (`init/2`, `run_iteration/3`, `apply_input/3`). The `codex` CLI
  binary on the host (or in the sandbox image) — runtime
  prerequisite, validated at first run.

### Implementation discoveries (additions to source plan)

The source plan §3.15 mentions Codex four times: in the
`config :jido_claw, JidoClaw.Memory.Consolidator` example
(`harness: :claude_code | :codex`), in the
`sync_host_codex_config/1` paragraph, in the §3.9
`ConsolidationRun.harness` attribute table, and in the cost-control
telemetry caveat. Specifics surfaced during reconnaissance:

- **No `Runners.Codex` exists today.** `lib/jido_claw/forge/runners/`
  contains `claude_code.ex`, `custom.ex`, `shell.ex`,
  `workflow.ex`. 3c creates `codex.ex` from scratch by mirroring
  the `ClaudeCode` shape — both runners implement the same
  behaviour and receive the same prompt + tool surface.
- **Auth surface symmetry.** Claude Code reads `~/.claude/`;
  Codex reads `~/.codex/`. Whitelist entries for `sync_host_codex_config/1`
  follow the same shape as `@syncable_entries` in
  `claude_code.ex` — credentials, settings, any per-host
  configuration the harness expects to find at startup.
- **`:no_credentials` failure mode.** If `~/.codex/credentials.json`
  (or whichever file Codex actually uses for auth) is missing,
  the runner returns `{:error, :no_credentials}` so the
  consolidator can write `status: :failed, error: :no_credentials`
  per source plan §3.15. The same shape Claude Code uses.
- **No silent fallback.** If `harness: :codex` is configured but
  the runner is unavailable (Codex CLI not on `$PATH`, or
  `~/.codex/` not readable), the consolidator writes
  `status: :failed, error: :runner_unavailable` rather than
  silently using `:claude_code`. Operators see a failure they
  can fix; no surprise harness substitution.

---

## 3c.1 Implementation outline

The runner module itself:

```elixir
defmodule JidoClaw.Forge.Runners.Codex do
  @behaviour JidoClaw.Forge.Runner

  # Mirror of ClaudeCode's shape; CLI-specific bits differ.
  def init(spec, sandbox), do: ...
  def run_iteration(state, sandbox, _opts), do: ...
  def apply_input(state, input, sandbox), do: ...

  # Host-side config sync, called from init/2.
  def sync_host_codex_config(sandbox), do: ...
end
```

The runner spawn invocation pattern:

```elixir
codex_args = [
  "-p", state.prompt,
  "--model", state.model,
  "--mcp-config", state.mcp_config_path,
  "--output-format", "stream-json",
  "--max-turns", to_string(state.max_turns)
]
```

The exact flag names will track Codex's actual CLI surface; the
above is the Claude Code shape that 3b's runner extension
already wires through, so 3c's job is to map equivalent flags
where Codex's CLI differs. If a flag has no Codex equivalent,
3c documents the substitute (or no-op) inline.

---

## 3.19 Acceptance gates (3c additions)

- **Codex round-trip via `:fake` runner not exercised.** 3c does
  not add a `:fake` shape for Codex — the `:fake` runner from
  3b's test suite is harness-agnostic by construction; tests
  configure `harness: :fake` and the Codex CLI is never invoked
  during `mix test`.
- **Live Codex round-trip is operator-validated.** A real
  `harness: :codex` consolidator run is exercised in staging
  before `v0.6.3c` ships. The acceptance gate is a manual
  walkthrough captured in the release notes — `mix test` cannot
  drive the actual `codex` CLI binary in CI without bundling
  credentials.
- **Cross-harness `ConsolidationRun.harness` attribute test.**
  Run the consolidator twice in the same scope: once with
  `harness: :claude_code` (configurable per run via the
  `run_now/1` override added in 3b), once with `harness: :codex`.
  Assert the two `ConsolidationRun` rows record the correct
  `harness` and `harness_model` values (e.g.
  `:claude_code`/`"claude-opus-4-7"` and `:codex`/<codex-model>).
  Pins the §3.9 attribute contract that the operative knob is
  captured per-run, not read from config at audit time.
- **`:no_credentials` egress.** With `~/.codex/` empty (or
  unreadable), configure `harness: :codex` and trigger a run.
  Assert the `ConsolidationRun` row has `status: :failed, error:
  :no_credentials` and that the harness CLI was never invoked
  (no subprocess spawned). Mirrors the existing Claude Code
  `:no_credentials` gate from 3b.
