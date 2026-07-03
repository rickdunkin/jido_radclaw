# JidoClaw

## Build & Development Commands

```bash
mix setup                              # deps.get + ash.setup
mix compile                            # compile project
mix compile --warnings-as-errors       # strict compile (CI)
mix format                             # auto-format (enforced)
mix format --check-formatted           # CI format check
mix test                               # full suite (runs ash.setup --quiet first)
mix test test/jido_claw/foo_test.exs   # single test file
mix test test/path_test.exs:42         # single test by line
mix test --failed                      # re-run failures
scripts/test-partitioned.sh [N]        # suite in N parallel partitions (default 4, ~2.2x faster; --failed caveat in header)
mix jidoclaw                           # run CLI REPL (setup wizard on first run)
mix jidoclaw --mcp                     # run as MCP server (stdio)
mix escript.build                      # build standalone binary
```

**Database** (PostgreSQL required):

```bash
mix ecto.setup    # create + migrate
mix ecto.reset    # drop + create + migrate
```

**Prerequisites**: Elixir >= 1.17, OTP >= 27, PostgreSQL. Ollama recommended for local dev.

**Tidewave MCP**:

Always use Tidewave's tools for evaluating code, querying the database, etc.

Use `get_docs` to access documentation and the `get_source_location` tool to
find module/function definitions.

### MCP Server Mode

JidoClaw exposes 24 tools over MCP stdio transport for use with Claude Code, Cursor, and other MCP-compatible editors. To add it to a project, create or edit `.mcp.json` in the project root:

```json
{
  "mcpServers": {
    "jidoclaw": {
      "command": "mix",
      "args": ["jidoclaw", "--mcp"],
      "cwd": "/absolute/path/to/jido_radclaw"
    }
  }
}
```

The `cwd` must be the absolute path to the JidoClaw project directory (where `mix.exs` lives). The server requires PostgreSQL to be running and `mix ecto.setup` to have been run at least once.

**Exposed tools**: `read_file`, `write_file`, `edit_file`, `list_directory`, `search_code`, `run_command`, `fetch_output`, `git_status`, `git_diff`, `git_commit`, `project_info`, `run_skill`, `store_solution`, `find_solution`, `network_share`, `network_status`, `agent_status`, `inspect_agent`, `swarm_status`, `forge_status`, `workflow_status`, `inspect_workflow`, `replay_workflow`, `workflow_events`. (`inspect_workflow`, `workflow_events`, and `replay_workflow` are MCP-only by design — none is in the in-REPL agent's tool list; `workflow_events` returns a run's raw, byte-paginated `WorkflowEvent` feed (G2-1a); `replay_workflow` additionally exposes no `force`/`allow_irreversible` overrides, replay-gate overrides being dashboard-only.)

**Exposed resources** (AR-2 Phase 5, §10.2): `jido://workflows/catalog` — the deterministic route-composer catalog (every composable stage: unit, routes, inputs/outputs, subscribes/publishes, locks) as `application/json`, so a client can *discover* the composable surface, not just trigger it. `jido://workflows/<stage>` (G2-1b) — the per-stage drill-down: an anubis `component` template resource (`jido://workflows/{name}`, listed under `resources/templates/list`, single-sourcing `Stage.to_map/1` so a stage read is byte-identical to the catalog's entry; unknown stage ⇒ resource not-found). `inspect_workflow` reads a single composer run's live route / waves / held / dropped / live signals + gate-block state; `workflow_status` is the tenant rollup.

**Known limitations** (anubis_mcp 1.6.2 — patched in `lib/jido_claw/core/`):

- Runtime patch overrides `Anubis.Server.Handlers.Tools` to rescue a Peri validation crash caused by jido_mcp's JSON-Schema-shaped tool schemas, and to atomize known string argument keys before dispatching to Jido actions. Remove once `jido_mcp` either emits Peri-compatible schemas or no longer routes those descriptors through Anubis's pre-dispatch Peri validation path.
- Because Elixir has no per-warning suppression, the `precommit` gate runs **`mix jidoclaw.compile_check`** instead of `compile --warnings-as-errors`: it clean-recompiles and fails on any warning/error **except** an explicit, documented allowlist. The allowlist (in `lib/mix/tasks/jidoclaw.compile_check.ex`) is **currently empty** — `PullRequestCoordinator.do_attempt/5`'s retry/abort `else` branches are now live (its helpers do real, fallible work: `generate_patch/3` carries a terminal `{:generation_failed, _}` and `JidoClaw.GitHub.PatchQuality.validate/1` a retryable `{:quality_failed, _}`), so the two former dead-`else` warnings are gone at the source. The mechanism remains for genuinely-unavoidable warnings (upstream-generated code or intentional scaffolding); add an entry only when justified inline and re-check it on every dep bump / Elixir upgrade.

## Architecture

JidoClaw is an AI agent orchestration platform built on Elixir/OTP and the Jido framework ecosystem. It provides a CLI REPL with ~33 tools, swarm orchestration, sandboxed code execution (Forge), a Phoenix LiveView web dashboard, and multi-provider LLM support.

### Supervision Tree

`JidoClaw.Application` starts children in groups:

- **Core**: Registries, Repo, Vault, Forge engine, PubSub, SignalBus, Telemetry, agent runtime (`JidoClaw.Jido`), Memory, Skills, Shell sessions, Display, AgentTracker
- **Gateway**: `JidoClaw.Web.Endpoint` (Phoenix) - started when mode is `:gateway` or `:both`
- **Cluster**: libcluster + `:pg` - started when `:cluster_enabled` is true
- **MCP**: Jido MCP server over stdio - started when `:serve_mode` is `:mcp` (Gateway and Discord are skipped in this mode)
- **Discord**: Nostrum started dynamically only when `DISCORD_BOT_TOKEN` is set and `:skip_discord` is not true

### Key Patterns

- **Tools**: All tools are `Jido.Action` modules (`use Jido.Action` with `name`, `description`, `schema`) in `lib/jido_claw/tools/`. Add new tools there and register in `lib/jido_claw/agent/agent.ex`.
- **Agent templates**: `lib/jido_claw/agent/workers/` - specialized agents (Coder, Reviewer, Researcher, Fixer, the sketch/system workers, etc.) using `use JidoClaw.Agent.Defaults` (which wraps `use Jido.AI.Agent`)
- **Signals**: Internal event routing via `Jido.Signal.Bus` with `jido_claw.<subsystem>.<event>` namespace
- **Stateful processes**: GenServer everywhere - sessions, shell manager, memory, skills, display
- **Swarm**: The main agent can spawn sub-agents dynamically; `AgentTracker` monitors per-agent stats
- **Skills**: YAML-based multi-step workflows in `.jido/skills/` with `depends_on` for DAG execution
- **VFS**: Virtual filesystem (`JidoClaw.VFS.Resolver`) routes `github://`, `s3://`, `git://` paths to backends
- **Output Shaping**: Verbose tool output (`run_command`, `git_diff`) is compressed format-aware by `JidoClaw.Tools.OutputShaper` (stage between `OutputRedaction` and `OutputLimit` in the shared `Tools.Action` pipeline). Rule: compress the green, never the red — `mix test`/`mix compile` success noise becomes counts, failure/warning blocks stay verbatim, unknown formats get head+tail. The full captured output (up to 512KB; `truncated` flagged beyond) is stored tenant-scoped in `Conversations.ToolOutput` under an unguessable ref (`JidoClaw.Refs.mint/1` — 12 random bytes → 24 hex, single-sourced with the `art_…` composer-artifact refs; O-L2) and retrievable via the `fetch_output` tool, so shaping is reversible. The `fetch_output` read is always tenant-scoped and ALSO **session-scoped** (S-M2) on session-meaningful surfaces (`serve_mode != :mcp` with a resolved `session_uuid`) via `ToolOutput.by_ref_scoped` — a session resolves only its OWN rows, blocking a same-tenant cross-session peek. System/cron-minted (`session_id: nil`) refs stay reachable from any session (the `is_nil` filter arm), and under `:mcp` the boot scope stays tenant-wide (the documented REPL-minted-ref drill-in flow). Anything that would exceed `OutputLimit`'s 32KB inline cap — an oversized shaped/all-signal body — is bounded by head+tail elision with the ref footer intact (never ref-less truncated), and `fetch_output` itself clips oversized slices to the cap (direction-aware) and reports honest `clipped`/`selected_lines` metadata. `run_command` requests the larger capture from `SessionManager` via the `:capture_bytes` opt only when `OutputShaper.shapeable?/3` holds (same predicate on capture and shaping sides). Disabled ⇒ byte-identical legacy truncation (`enabled?: false` in test.exs); no-tenant calls pass through unshaped; streaming runs are never shaped. Config under `:output_shaping`; telemetry on `[:jido_claw, :tool, :shaping]` plus `:output` Trace events. **External MCP proxy results** (`mcp_<server>_<tool>`) take a parallel **generic** path (`mcp_shapeable?/2` → `safe_shape_mcp/3`): above the inline cap (or for any unencodable term) the whole result is pretty-serialized, capture-capped with tail-preserving elision, ref-stored, and collapsed to a bounded `:output` wrapper with the spec-standard `isError` lifted (the model's only failure signal); below the cap the structured result passes through. ANSI stripping now lives at the **root in `OutputRedaction`** (`Security.Redaction.Ansi.strip/1`, applied before both value redaction and key classification), so an escape-split secret (`sk-ant-\e[0m…`) or split sensitive key (`api_\e[0mkey`) is reassembled and caught for every tool and every path before the shaper sees the text — the shaper's own strip is now belt-and-suspenders. **Accepted residuals** (this review — documented, not fixed): (S-M3) streamed `run_command` chunks reach the OPERATOR's own terminal un-redacted — the model-facing copy IS redacted, and the threat model is model-input / durable-sink hygiene, not the operator's local echo (streaming runs are never shaped, per above); (S-L2) the memory-consolidator's internal tools bypass this shared `Tools.Action` pipeline — internal-only, and ingest redacts at the sink; (O-L1) the composer's `ensure_parent_live` child-create reload can briefly fail OPEN (`route_composer.ex`), but the wave fold stays fenced at `commit_wave` (the token CAS), so no unfenced write survives.
- **Context Compaction**: Long sessions are compacted live via `JidoClaw.Reasoning.Compactor`. The `JidoClaw.Agent.Defaults` macro accepts `compaction: [...]` opts and injects an `on_before_cmd/2` override on `{:ai_react_start, _}` that runs `Compactor.maybe_compact/3` before delegating to `super`. The main `JidoClaw.Agent` and all 16 worker templates carry `compaction: [mode: :auto]`. Per-agent keying shipped: each agent compacts its own slice keyed by `JidoClaw.Reasoning.Compactor.Identity` (`"main"` for both main surfaces, `"handoff:<uuid>:<tpl>"` for a routed worker, the spawn tag for a sub-agent), with per-key snapshots persisted under `Session.metadata["compactions"][key]` (`key = "<identity>::<context_ref|default>"`) via atomic `jsonb_set`; spawned/handoff sub-agents get coherent durable transcripts via `JidoClaw.Conversations.SubagentTranscript`. (Real `context_ref` lanes remain a no-op follow-up — no producer currently sets `context_ref`, so keys normally trail `::default`, though the code accepts one if it appears in tool context.) Best-effort: storage and summarizer failures are emitted via `:compaction` Trace events and logged, but never block the agent's forward progress. The actual LLM-facing message trim happens in `JidoClaw.Reasoning.Compactor.RequestTransformer` (a `Jido.AI.Reasoning.ReAct.RequestTransformer` implementation) — it filters projected messages by `refs.request_id ∈ snapshot.summarized_request_ids` and injects the summary as a delimited user-role message. **That module is now the app's single COMPOSED transformer** (AR-9): besides the compaction `:messages` override, it reads `runtime_context[stage_tier_key()]` (`:__jido_claw_stage_tier__`) and returns per-turn `model:` / `llm_opts: [reasoning_effort: e]` overrides — the per-stage tiering seam. A tiered composer stage (`%Stage{}` `model`/`effort`, carried by `WaveBuilder` into the step options) reaches it via `AgentRunner.run/6`, which puts the tier map in `tool_context` and pre-sets `request_transformer:` on the ask (same module ⇒ no Compactor collision; `install_overrides` adds to `tool_context` rather than replacing it, preserving the tier key). The `plan-arbiter` stage (AR-9 PR-4, the seam's designed first declarer) now declares `model: :capable, effort: :high`; every other stage stays undeclared (session default). PR-2 of the same program threads composer `premises` into every worker wave's `:extra_context` via `JidoClaw.RouteComposer.PremisesContext` (`compose_extra_context/2` in `route_composer.ex`; empty premises ⇒ byte-identical prompts, gate waves excluded), and `AgentStep` emits `[:jido_claw, :composer, :stage_prompt]` (`bytes` + stage/template) for composer stages only.
- **Tool Approval Gate**: A per-tool-call human-approval checkpoint on the conversation axis (complementing the workflow-axis Reactor gate family). The shared `Tools.Action` wrapper runs `JidoClaw.Security.ToolApproval.gate/4` as its first stage (before redact/shape/cap): a require-listed tool (`config :jido_claw, :tool_approval, require:` — default `network_share, kill_agent, schedule_task, unschedule_task, git_commit, forget, replay_workflow`, single-sourced in `ToolApproval.default_require/0`) **or** a param-pattern trigger (in-module `@require_patterns`, e.g. `run_command` commands matching `git commit`/`git push`/`crontab`) routes through `JidoClaw.Orchestration.ToolApprovals.request/3`. The producer maps a canonical `{tenant, session, tool, args}` fingerprint to a durable run-less `AgentCase` (kind `:tool_call`) and the tool returns a non-retryable `{:error, %{code: :approval_pending | :approval_denied | :approval_unavailable}}` envelope the LLM relays. Approvals are **single-use** (`:consume`), rejections are **deny-once** (`:consume_rejection`); the FOR-UPDATE re-read in the producer transaction is the real concurrency fence (the `change filter` on the case actions is not a DB fence in ash_postgres 2.9), and the named partial unique index `agent_cases_pending_fingerprint_index` collapses the open race. Operators decide via the same surfaces as workflow gates (REPL `/gates`, web `/approvals`) through `Cases.decide/4`'s run-less branch. `enabled?: true` by default; `enabled?: false` in test (tests drive `gate/4` with explicit opts). The `tool_context` nesting the gate relies on is guaranteed by `JidoClaw.ToolContext.ensure_nested/1` in the wrapper (the live ReAct path arrives flat). **Shell-floor reach (S-M1)**: the `run_command` param-pattern runs `JidoClaw.Security.ShellCommand.analyze/1`, whose fail-closed `:opaque` floor also covers command-runners wrapping a gated root/shell (`xargs`/`parallel`/`ssh`/`su -c`/`flock`/`find -exec`, `scope: :runner`) and interpreter one-liners / stdin programs (`python -c`, `node -e/-p`, `perl -e`, `echo … | python`, `python -`, `scope: :interpreter`) — gating on the flag/reach alone, never parsing the wrapped code, and failing closed on any dynamic runner/interpreter arg. Documented **residuals** (conscious `run_command` escape valve, NOT gated): the `npx`/`nix run` family (running an arbitrary package is statically unknowable), interpreter *script-file* invocations (`python foo.py`, `… | python foo.py`), and the pre-existing login-file-alias / script-file-indirection cases (`bash deploy.sh`). The `:docker` shell-floor skip (`tool_approval.ex`) suppresses all of it inside a provisioned microVM.
- **External MCP Tool Consumption**: The platform both *serves* MCP (`JidoClaw.MCPServer`, 24 tools + the `jido://workflows/catalog` resource and the `jido://workflows/{name}` per-stage template) and now *consumes* it (`JidoClaw.MCP`). Operators declare external servers in `.jido/config.yaml` under `mcp_servers:` (stdio/sse/streamable_http); `JidoClaw.MCP.Consumer` (a boot GenServer with off-process, crash-isolated prep) discovers each server's tools and compiles a proxy `Jido.Action` per tool via `JidoClaw.MCP.ProxyGenerator`. **The payoff: generated proxies `use JidoClaw.Tools.Action`** (not bare `Jido.Action` like the dep's `Jido.MCP.JidoAI.ProxyGenerator`, which returns remote data raw), so the full safety pipeline (`ToolApproval.gate → Error.normalize → OutputRedaction → OutputLimit` inside `MCPScope.wrap`) wraps every call automatically — inbound results are **redacted + capped + generically shaped** (an `mcp_`-rooted name takes `OutputShaper`'s `safe_shape_mcp/3` collapse-above-cap path: pretty-serialize → capture-capped ref-store → bounded `:output` wrapper with `isError` lifted; format-aware parsing stays `run_command`/`git_diff`-only), and the proxy adds **outbound arg scrubbing** (now also strips ANSI, via the `OutputRedaction` root pass) plus **re-surfaces jido_mcp's `:tool_error` promotion** — a domain `isError: true` result is a *successful* MCP response per spec, but the dep promotes it to `{:error, %{type: :tool_error, details: <raw result map>}}`; the proxy re-surfaces it to `{:ok, data}` (matching `"isError" => true` in `details`, so transport/protocol/validation errors stay `{:error, _}`) so the headline failure case is shaped + `isError`-lifted + ref-stored rather than buried by `Error.normalize` and ref-lessly head-cut by `OutputLimit`. Names are `mcp_<server>_<tool>`, deduped + 64-char-capped + asserted `mcp_`-rooted; the remote `inputSchema` is passed through directly as the action `schema:` (a JSON-Schema map is an LLM-only pass-through — `Zoi.map()`/`to_zoi` would advertise *no args*). Attach is non-blocking: `attach_to_agent/2` (fire-and-forget, REPL boot + `:prepared`/restart rehydrate from `AgentTracker`) and `ensure_attached/3` (bounded, every agent-turn path — the Consumer defers its reply so the *caller* waits, never the Consumer). **Per-template reach-allowlist** (worker/sub-agent sync): every turn surface — chat (REPL + chat/4), handoff-routed turn, spawn, follow-up, skill-step — runs `ensure_attached(pid, template, 8_000)` keyed by `tool_context.agent_template`, and a server's `templates:` allowlist scopes *which* templates register its tools (`[]`/absent ⇒ all; a list ⇒ only those — withheld at *registration*, so the LLM never sees them; the moment any server uses an allowlist the operator must include `"main"` to keep its tools on the interactive agent). Enforcement is `Consumer.modules_for_template/3` (reach, not gating — `tool_approval.ex` is untouched; a finer per-tool *approval* overlay for MCP stays an explicit non-goal). **Default-on approval**: the Consumer publishes `%{tool_name => true|false|nil}` to `:persistent_term`; `ToolApproval.requirement/3` gates every `mcp_*` tool unless its server is trusted (`require_approval: false`) or the global `mcp_require_approval` is false — and an unknown `mcp_`-prefixed name (lost/unset policy) falls back to the global default (**fails CLOSED to gated, never to native**). **Trust boundary** — two things sit *outside* the per-call gate (`require_approval` gates tool *calls*, not server *startup*): (1) **stdio subprocess env** — `Port.open`'s `{:env}` overlays, not replaces, the host env, so a patched `Jido.MCP.Transport.STDIO` (`lib/jido_claw/core/mcp_stdio_transport_patch.ex`, registered in `DependencyPatches`) builds `:env` via `Env.scrubbed_port_env/1` (default-deny: host secrets unset; endpoint `env:` is the operator override map); (2) **tool names/descriptions are prompt-trusted before any call** (the gate can't stop description-borne injection), so configured servers are trusted for prompt metadata — `ProxyGenerator` only strips control chars + caps description length. Deferred: per-tool (vs per-server) approval overlay for `mcp_*`.
- **Deterministic Eval Harness**: `JidoClaw.Eval.{Case,Run}` package `{kind, request, assertions}` cases run via `JidoClaw.Eval.run_case/2` against **production functions only** (no new runtime path): `:prompt` (the assembled `SubagentPrompt.build/3`), `:schema` (a worker's `strategy_opts()[:output]` via `Jido.AI.Output.parse/2`), `:composer` (`RouteComposer.run_sync/1` through the real gate dance), `:coherence` (doctrine-slice prose ↔ per-token schema probes — the prose-half/schema-half field contracts). The fake↔live seam is the caller's app-env arming + `run_case` opts (`tenant`/`actor`/`context`/`timeout`), never a test module named in lib; unknown assertion keys fail loudly (an `:unknown_assertion` record fails the run — a deliberate deviation from jidoka's silent skip; a malformed assertion value/item fails via `:invalid_assertion_value`, an evaluator raise via `:assertion_raised`). Seed cases pinning the post-AR-9 prompt surface live in `test/jido_claw/eval/`; harness unit tests in `test/jido_claw/eval_test.exs`.

### Module Namespace Convention

`JidoClaw.<Subsystem>.<Module>` - key subsystems:

| Directory        | Purpose                                                                                     |
| ---------------- | ------------------------------------------------------------------------------------------- |
| `agent/`         | Main agent, prompt builder, templates, workers                                              |
| `cli/`           | REPL, commands, branding, setup, formatter                                                  |
| `forge/`         | Sandboxed execution (runners, sandbox backends)                                             |
| `tools/`         | All 32+ Jido.Action tool modules                                                            |
| `platform/`      | Session, Tenant, Channel, Cron, BackgroundProcess                                           |
| `reasoning/`     | Strategy + pipeline stores, classifier, telemetry, certificate templates, context compactor |
| `security/`      | Encryption vault, secret redaction, browse_web destination-policy gate                      |
| `web/`           | Phoenix endpoint, controllers, LiveView                                                     |
| `orchestration/` | Persistent workflow state machine                                                           |
| `solutions/`     | Solution fingerprinting, trust scoring, semi-formal verification                            |
| `mcp/`           | External MCP tool **consumption** — Consumer, Client, EndpointConfig, ProxyGenerator (vs `MCPServer`, which *serves*) |

### Data Layer

Ash Framework 3.0 + PostgreSQL. Resources in `lib/jido_claw/accounts/`. Test DB uses `Ecto.Adapters.SQL.Sandbox` for parallel isolation.

### Configuration Cascade

1. `config/config.exs` (compile-time, includes LLMDB model catalog)
2. `.jido/config.yaml` (user runtime config: provider, model, strategy)
3. `.env` / env vars (secrets - loaded at app start, env vars take precedence)

### `.jido/` Directory

Project-level config directory. `config.yaml`, `memory.json`, `sessions/` are git-ignored. `agents/`, `skills/`, `strategies/`, and `pipelines/` YAML definitions are committed. Schema details live in the module docs for `JidoClaw.Reasoning.StrategyStore` (user strategies + optional prompt templates) and `JidoClaw.Reasoning.PipelineStore` (user pipelines + optional `max_context_bytes`).

**`system_prompt.md`** is created from `priv/defaults/system_prompt.md` during setup but is not auto-synced afterward. When tools or skills are added to the defaults, manually copy the updated default to `.jido/system_prompt.md`.

## Code Style

- `mix format` enforced, no exceptions
- Signal strings: `jido_claw.<subsystem>.<event>` (never `jido_cli`)
- Prefer pattern matching over conditionals
- Commit messages: `feat:`, `fix:`, `refactor:`, `docs:` prefixes

## Testing

- Tests in `test/jido_claw/`, mirroring source structure
- `:docker_sandbox` tag excluded by default
- Supports `MIX_TEST_PARTITION` for CI sharding

<!-- usage-rules-start -->
<!-- usage_rules-start -->
## usage_rules usage
_A config-driven dev tool for Elixir projects to manage AGENTS.md files and agent skills from dependencies_

## Using Usage Rules

Many packages have usage rules, which you should *thoroughly* consult before taking any
action. These usage rules contain guidelines and rules *directly from the package authors*.
They are your best source of knowledge for making decisions.

## Modules & functions in the current app and dependencies

When looking for docs for modules & functions that are dependencies of the current project,
or for Elixir itself, use `mix usage_rules.docs`

```
# Search a whole module
mix usage_rules.docs Enum

# Search a specific function
mix usage_rules.docs Enum.zip

# Search a specific function & arity
mix usage_rules.docs Enum.zip/1
```


## Searching Documentation

You should also consult the documentation of any tools you are using, early and often. The best 
way to accomplish this is to use the `usage_rules.search_docs` mix task. Once you have
found what you are looking for, use the links in the search results to get more detail. For example:

```
# Search docs for all packages in the current application, including Elixir
mix usage_rules.search_docs Enum.zip

# Search docs for specific packages
mix usage_rules.search_docs Req.get -p req

# Search docs for multi-word queries
mix usage_rules.search_docs "making requests" -p req

# Search only in titles (useful for finding specific functions/modules)
mix usage_rules.search_docs "Enum.zip" --query-by title
```


<!-- usage_rules-end -->
<!-- usage_rules:elixir-start -->
## usage_rules:elixir usage
# Elixir Core Usage Rules

## Pattern Matching
- Use pattern matching over conditional logic when possible
- Prefer to match on function heads instead of using `if`/`else` or `case` in function bodies
- `%{}` matches ANY map, not just empty maps. Use `map_size(map) == 0` guard to check for truly empty maps

## Error Handling
- Use `{:ok, result}` and `{:error, reason}` tuples for operations that can fail
- Avoid raising exceptions for control flow
- Use `with` for chaining operations that return `{:ok, _}` or `{:error, _}`

## Common Mistakes to Avoid
- Elixir has no `return` statement, nor early returns. The last expression in a block is always returned.
- Don't use `Enum` functions on large collections when `Stream` is more appropriate
- Avoid nested `case` statements - refactor to a single `case`, `with` or separate functions
- Don't use `String.to_atom/1` on user input (memory leak risk)
- Lists and enumerables cannot be indexed with brackets. Use pattern matching or `Enum` functions
- Prefer `Enum` functions like `Enum.reduce` over recursion
- When recursion is necessary, prefer to use pattern matching in function heads for base case detection
- Using the process dictionary is typically a sign of unidiomatic code
- Only use macros if explicitly requested
- There are many useful standard library functions, prefer to use them where possible

## Function Design
- Use guard clauses: `when is_binary(name) and byte_size(name) > 0`
- Prefer multiple function clauses over complex conditional logic
- Name functions descriptively: `calculate_total_price/2` not `calc/2`
- Predicate function names should not start with `is` and should end in a question mark.
- Names like `is_thing` should be reserved for guards

## Data Structures
- Use structs over maps when the shape is known: `defstruct [:name, :age]`
- Prefer keyword lists for options: `[timeout: 5000, retries: 3]`
- Use maps for dynamic key-value data
- Prefer to prepend to lists `[new | list]` not `list ++ [new]`

## Mix Tasks

- Use `mix help` to list available mix tasks
- Use `mix help task_name` to get docs for an individual task
- Read the docs and options fully before using tasks

## Testing
- Run tests in a specific file with `mix test test/my_test.exs` and a specific test with the line number `mix test path/to/test.exs:123`
- Limit the number of failed tests with `mix test --max-failures n`
- Use `@tag` to tag specific tests, and `mix test --only tag` to run only those tests
- Use `assert_raise` for testing expected exceptions: `assert_raise ArgumentError, fn -> invalid_function() end`
- Use `mix help test` to for full documentation on running tests

## Debugging

- Use `dbg/1` to print values while debugging. This will display the formatted value and other relevant information in the console.

<!-- usage_rules:elixir-end -->
<!-- usage_rules:otp-start -->
## usage_rules:otp usage
# OTP Usage Rules

## GenServer Best Practices
- Keep state simple and serializable
- Handle all expected messages explicitly
- Use `handle_continue/2` for post-init work
- Implement proper cleanup in `terminate/2` when necessary

## Process Communication
- Use `GenServer.call/3` for synchronous requests expecting replies
- Use `GenServer.cast/2` for fire-and-forget messages.
- When in doubt, use `call` over `cast`, to ensure back-pressure
- Set appropriate timeouts for `call/3` operations

## Fault Tolerance
- Set up processes such that they can handle crashing and being restarted by supervisors
- Use `:max_restarts` and `:max_seconds` to prevent restart loops

## Task and Async
- Use `Task.Supervisor` for better fault tolerance
- Handle task failures with `Task.yield/2` or `Task.shutdown/2`
- Set appropriate task timeouts
- Use `Task.async_stream/3` for concurrent enumeration with back-pressure

<!-- usage_rules:otp-end -->
<!-- usage-rules-end -->
