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
scripts/test-partitioned.sh [N]        # suite in N parallel partitions (default 4, ~2.4x faster; --failed caveat in header; precommit's test phase runs this)
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

JidoClaw exposes 26 tools over MCP stdio transport for use with Claude Code, Cursor, and other MCP-compatible editors. To add it to a project, create or edit `.mcp.json` in the project root:

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

**Exposed surface**: 26 tools + four `jido://` resources (`workflows/catalog`, `workflows/{name}`, `_meta/version`, `bootstrap`). `inspect_workflow`, `workflow_events`, and `replay_workflow` are MCP-only by design, and the served surface is pinned by `JidoClaw.MCPServer.SurfaceVersion` + the golden surface test — a surface change without a deliberate version bump fails precommit. Full tool list, resource semantics, stability contract → [docs/system/mcp-server-surface.md](docs/system/mcp-server-surface.md)

**Known limitations** (anubis_mcp 1.6.2 — patched in `lib/jido_claw/core/`):

- Runtime patch overrides `Anubis.Server.Handlers.Tools` to rescue a Peri validation crash caused by jido_mcp's JSON-Schema-shaped tool schemas, and to atomize known string argument keys before dispatching to Jido actions. Remove once `jido_mcp` either emits Peri-compatible schemas or no longer routes those descriptors through Anubis's pre-dispatch Peri validation path.
- Because Elixir has no per-warning suppression, the `precommit` gate runs **`mix jidoclaw.compile_check`** instead of `compile --warnings-as-errors`: it clean-recompiles and fails on any warning/error **except** an explicit, documented allowlist. The allowlist (in `lib/mix/tasks/jidoclaw.compile_check.ex`) is **currently empty** — `PullRequestCoordinator.do_attempt/5`'s retry/abort `else` branches are now live (its helpers do real, fallible work: `generate_patch/3` carries a terminal `{:generation_failed, _}` and `JidoClaw.GitHub.PatchQuality.validate/1` a retryable `{:quality_failed, _}`), so the two former dead-`else` warnings are gone at the source. The mechanism remains for genuinely-unavoidable warnings (upstream-generated code or intentional scaffolding); add an entry only when justified inline and re-check it on every dep bump / Elixir upgrade.

## Architecture

JidoClaw is an AI agent orchestration platform built on Elixir/OTP and the Jido framework ecosystem. It provides a CLI REPL with ~35 tools, swarm orchestration, sandboxed code execution (Forge), a Phoenix LiveView web dashboard, and multi-provider LLM support.

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
- **Output Shaping**: verbose tool output (`run_command`, `git_diff`) is compressed format-aware by `JidoClaw.Tools.OutputShaper` — the stage between `OutputRedaction` and `OutputLimit` in the shared `Tools.Action` pipeline. Rule: compress the green, never the red — and shaping is always reversible: the full capture is ref-stored tenant-scoped and retrievable via `fetch_output` (ALSO session-scoped on session-meaningful surfaces, S-M2), and anything over the 32KB inline cap is head+tail-elided with the ref footer intact, never ref-less truncated. ANSI stripping lives at the root in `OutputRedaction` (before value redaction and key classification), so escape-split secrets are reassembled and caught for every tool on every path. External MCP proxy results take a parallel generic path (collapse-above-cap, `isError` lifted); disabled/no-tenant/streaming runs pass through unshaped. Mechanics, caps, ref scoping, config, accepted residuals → [docs/system/output-shaping.md](docs/system/output-shaping.md)
- **Context Compaction**: long sessions are compacted live via `JidoClaw.Reasoning.Compactor` — the `JidoClaw.Agent.Defaults` macro injects an `on_before_cmd/2` override on `{:ai_react_start, _}` that runs `Compactor.maybe_compact/3` before delegating to `super`; the main agent and all 16 worker templates carry `compaction: [mode: :auto]`. Each agent compacts its own slice keyed by `Compactor.Identity`, with per-key snapshots persisted under `Session.metadata["compactions"][key]` via atomic `jsonb_set`. Best-effort: storage and summarizer failures are Trace'd and logged, never blocking the agent's forward progress. The LLM-facing trim happens in `Compactor.RequestTransformer` — the app's single COMPOSED transformer (AR-9): besides the compaction `:messages` override it reads the stage-tier key from runtime context and returns per-turn `model:`/`reasoning_effort` overrides (the per-stage tiering seam; `plan-arbiter` is the first declarer). Identity keys, tier threading, premises context (PR-2), telemetry → [docs/system/context-compaction.md](docs/system/context-compaction.md)
- **Gateway Runtime Security**: chat-main agents key on the durable conversation UUID, never a client session name; the OpenAI-compatible endpoint runs a filesystem-read-only, zero-tool stateless agent that bypasses bootstrap/handoff/MCP/triage/composer, applies the concrete response model per turn, validates its stateless marker BEFORE persistence, then tears down its agent, Session worker, shell/VFS state, rows, and race-fenced correlation cache. The PostgreSQL tenant row is the activity authority — ordinary Ash reads/writes and authenticated LiveView mounts require `:active` (reads fold the check into one correlated-EXISTS SQL query), while tenant-matched system actors preserve lifecycle/terminal/recovery writes and lifecycle transitions stop/resume the legacy runtime subtree. The completion endpoint validates the full ordered transcript and configured model, passwords are bounded and pre-bcrypt throttled, `/setup` is admin-only with coalesced async deadline-bounded probes, and test boots strip external credentials/adapters. Config, limits, residual buffered SSE, and the legacy-cache boundary → [docs/system/gateway-runtime-security.md](docs/system/gateway-runtime-security.md)
- **Tool Approval Gate**: a per-tool-call human-approval checkpoint on the conversation axis (complementing the workflow-axis Reactor gate family), run by the shared `Tools.Action` wrapper as its FIRST stage (before redact/shape/cap): a require-listed tool **or** a param-pattern trigger maps a canonical `{tenant, session, tool, args}` fingerprint to a durable run-less `AgentCase` (kind `:tool_call`), and the tool returns a non-retryable `{:error, %{code: :approval_pending | :approval_denied | :approval_unavailable}}` envelope the LLM relays. Approvals are **single-use**, rejections **deny-once**; the FOR-UPDATE re-read in the producer transaction is the real concurrency fence. The `run_command` pattern runs `ShellCommand.analyze/1`, whose fail-closed `:opaque` floor also gates command-runners and interpreter one-liners wrapping a gated root — on the flag/reach alone, never by parsing the wrapped code. Remote writes classify from one VFS-owned adapter registry: only known-local live/config adapters bypass approval, while unknown/non-local adapters gate closed. Absolute writes re-read a bounded stable `.jido/config.yaml` snapshot on every gate and content-digest-cache only the shared typed mount list; malformed containers and uncertainty gate closed. Operators decide via REPL `/gates` / web `/approvals`. Require-list, patterns, fences, shell-floor scopes, documented escape valves → [docs/system/tool-approval.md](docs/system/tool-approval.md)
- **Loop Guard (doom-loop detection)**: `JidoClaw.Agent.LoopGuard` runs inside the shared `Tools.Action` pipeline AFTER the approval gate: identical-call runs halt before execution (the 4th identical call never runs), repeated failure signatures get staged recovery directives then a halt, and a per-key call budget caps runaway sessions. The halt envelope (`code: :doom_loop`, `details.retry: false`, details key `:trigger` never `:reason`) is non-retryable at BOTH retry layers; a clean success of tool T clears only **T's** signatures. The facade fails open and no-tenant/no-session calls pass through unguarded — a budget guard must never break a tool call. Full mechanics, thresholds, port provenance, feed-boundary residuals → [docs/system/loop-guard.md](docs/system/loop-guard.md)
- **Verdict Normalizer (infra ≠ verdict ≠ inconclusive)**: `JidoClaw.Orchestration.Verdict` is the single normalizer every probabilistic judge output passes through, with three exits: `{:verdict, %Verdict{}}` (`clean? = approve AND zero findings` — findings-win), `{:infra, reason}` (**schema drift fails CLOSED to infra**, never a verdict, never clean), and `{:inconclusive, reason}` (consumers fold it into the infra lane). `normalize/2` is total over arbitrary input. Infra retries on the SEPARATE per-stage `infra_cap` budget — it never consumes `rerun_cap`, never reads clean, never summons the fixer with empty feedback — and exhaustion terminalizes `:route_review_infra_failed`. `IterativeStep` re-runs a garbled evaluator only, without burning an iteration (the old `parse_verdict/1` → `:fail` conflation was camus's "#1 cause of runaway loops"). The five trust-boundary laws + the event-sourced durability checklist live in `docs/TRUST-BOUNDARIES.md` (camus C2-8) — the review rubric for orchestration/gate changes. Exit taxonomy, lane A/B mechanics, budgets, observability → [docs/system/verdict-normalizer.md](docs/system/verdict-normalizer.md)
- **Deterministic Verify Authority (engine-run, head-bound, tamper-fenced)**: `JidoClaw.Orchestration.Verify` is the engine-side verifier — the composer runs the repo's verify command itself and reads the **exit code** (law 2 of `docs/TRUST-BOUNDARIES.md`: the verdict never rides an LLM relay), as the catalog's single `{:verify, "default"}` stage (`CatalogValidator` invariant 10 — at most one verify authority), deferred to run LAST in its Kahn level, solo. Command resolution never passes or skips silently (per-run override → `.jido/config.yaml` → mix auto-detect → a loud INCONCLUSIVE) and **no shell, ever** — argv lists via `Core.OsCmd`. Green holds the committed invariant: `clean:verify` and its integrity certificate land in the same commit or not at all — an uncertified green reclassifies `{:inconclusive, "uncertified_green"}`; tampered integrity terminalizes `:route_verify_tampered` and VERIFY_OATH holds (never retried, never fed to the fixer — remediation destroys the evidence). Sealed mode rejects tracked dirt **and nonignored untracked paths**; working-tree certificates bind a domain-separated tracked diff + sorted bounded untracked manifest whose regular content/type/mode and symlink target text are race-fenced (`PORT-C1-2-AUDIT`; failures/bounds ⇒ INCONCLUSIVE, never green). Filesystem captures run behind a deadline plus a small VM-wide supervised ceiling; a timed-out FIFO task stays counted until its dirty-I/O syscall unwinds, and callers fail toward INCONCLUSIVE. The code-route LLM judges diagnose reds but never hold that verdict; the separate authoritative `system_verifier` reverse-check gates every real-host command through an exact, single-use operator approval. Integrity modes, fingerprint bounds, verdict mapping, convergence re-derivation, config, residuals → [docs/system/verify-authority.md](docs/system/verify-authority.md)
- **Honest Terminal Statuses + Stall Detection**: reviewer findings carry a cross-wave identity (`JidoClaw.RouteComposer.FindingKey`, welded per round into the wave commit as a `:finding_keys` marker — the marker IS the durable identity; the findings themselves persist encrypted, and un-keyable findings are excluded rather than fabricated). The fold detects **stuck** and **oscillating** findings; stall evidence or re-review-budget exhaustion suppresses ALL of Hook R (never dispatch a fix its flagged lens has no budget to re-review), and on a **green AND certified** verify the composer parks at a `:review_stall` gate — a parent-stays-`:running`, child-less park raising a durable run-bound `AgentCase` — instead of terminalizing. Approve requires per-finding waive records covering EVERY surviving key (all-or-reject); reject ⇒ `fix_failed`; approval terminalizes `:route_done_with_findings`, the completed-family disposition every surface marks amber, never plain green (verbatim finding bodies never ride the result). Verify-less/red routes keep today's terminals. Key derivation, park/case mechanics, waiver rules, surface rollups, the debt ledger → [docs/system/terminal-statuses.md](docs/system/terminal-statuses.md)
- **External MCP Tool Consumption**: the platform both _serves_ MCP (`JidoClaw.MCPServer`) and _consumes_ it (`JidoClaw.MCP`): operators declare external servers in `.jido/config.yaml` `mcp_servers:`, and `MCP.Consumer` binds a proxy per remote tool that **`use`s `JidoClaw.Tools.Action`** — so the full safety pipeline (approval gate → normalize → redact → shape → cap) wraps every call, with outbound arg scrubbing and the dep's `:tool_error` promotion re-surfaced so a domain `isError` result stays shaped + ref-stored. Server endpoint IDs come from a stable, cumulative 64-atom pool (reorder-safe, never name-derived or reused); proxy identities have a cumulative 1,024-per-VM ceiling, and discovery stays inert until a complete correlated aggregate is accepted. A server's `templates:` allowlist scopes reach at _registration_ (withheld tools the LLM never sees; include `"main"` once any allowlist is used). Approval is default-on: every `mcp_*` tool gates unless its server is trusted, and an unknown `mcp_`-prefixed name **fails CLOSED to gated, never to native**. Trust boundary: the stdio subprocess env is scrubbed default-deny, and tool names/descriptions are prompt-trusted before any call (the gate can't stop description-borne injection). Endpoint/proxy identity, last-known-good discovery, retryable metadata reconciliation, reach, and approval mechanics → [docs/system/mcp-consumption.md](docs/system/mcp-consumption.md)
- **Lua Code-Mode Queries**: `lua_query` + `lua_docs` (on BOTH tool surfaces) run a short **read-only** Lua script server-side so cross-run filter/join/aggregate happens in the sandbox — intermediate rows never enter model context. Seven host bindings live in `JidoClaw.Tools.Lua.Bindings` (the single source; `lua_docs` renders from it); every binding is read-only (`assert_read_only!/0` per eval — a future write binding must clear it deliberately and join the approval require-list; the pair itself is deliberately NOT require-listed). Two checks are deliberately **post-eval** because in-script `pcall` can swallow host raises: budget refusal and the aggregate `max_result_bytes` bound. All `:lua_*` envelopes are non-retryable at both retry layers (`:lua_timeout` deliberately so — same script + same caps re-times-out). Bindings, VM budgets/isolation, policy clamps, config, telemetry → [docs/system/lua-code-mode.md](docs/system/lua-code-mode.md)
- **Deterministic Eval Harness**: `JidoClaw.Eval.{Case,Run}` package `{kind, request, assertions}` cases run via `JidoClaw.Eval.run_case/2` against **production functions only** (no new runtime path) — kinds `:prompt`, `:schema`, `:composer`, `:coherence`. The fake↔live seam is the caller's app-env arming + `run_case` opts, never a test module named in lib; unknown assertion keys fail loudly (a deliberate deviation from jidoka's silent skip). Kinds, failure records, seed-case layout → [docs/system/eval-harness.md](docs/system/eval-harness.md)
- **Ambiguity Clarify Loop (score → ask → fold → re-score, then compose)**: an `ambiguous` `code`/`system` verdict on a `:loop` surface enters `JidoClaw.FrontDoor.Clarify` (`{:clarify, resp}` — no run minted) instead of composing on a misread ask: ouroboros-verbatim scoring (`Q00/ouroboros @ e905a41c`, MIT — pass = ambiguity ≤ 0.2 ∧ four dimension floors ∧ a 2-consecutive-qualifying-round streak; effective ambiguity is `max(llm, deterministic_floor)` so the LLM can't under-report) over an orca OR2-5 question ledger persisted under `metadata["pending_clarify"]` with **result-checked writes, never `safe_write/1`** (open-turn persist or scorer failure fails OPEN to the standard composer; sketch is never gated). At the round cap a required unknown **holds** for the explicit "proceed with defaults" ack — never auto-composed past; compose enriches premises (`clarifications`/`ambiguity_score`/`readiness` + honest `degraded: true`/`unresolved_slots`), drops `:ambiguous` only on a clean pass, clears state only on `{:ok, parent}`, and ORs the sticky lane-entry-redaction sensitivity into `mark_sensitive`. `:one_shot` surfaces (cron BOTH arms; the `chat/4` `clarify:` opt and kind-derived `:api` fallback) never park questions and never continue a live loop — immediate degraded compose; the OpenAI-compatible controller instead bypasses triage/clarify/composer on its zero-tool stateless path. The one-shot CLI maps a parked round to exit 3 `:clarify_pending`. Loop mechanics, scorer contract, port divergences, residuals → [docs/system/ambiguity-clarify.md](docs/system/ambiguity-clarify.md)
- **Structured Premises (typed acceptance criteria + deterministic lint)**: three typed optional premises keys — `acceptance_criteria` (stable 1-based `AC1…` ids, orca OQ-2), `evaluation_principles`, `exit_conditions` — written by the clarify loop and triage (extraction-only, never invented), normalized fail-open at the `build_premises/5` write boundary (`JidoClaw.RouteComposer.Premises`). `Premises.Lint` (ouroboros GradeGate port, signed map `docs/exploration/ouroboros/PORT-OB1-2.md`) is pure with a **mode split**: `:clarify` may emit blockers (exclusively the ledger-derived safety set — high-risk assumptions / open required gaps / high ambiguity; blockers re-open a clarify round below the cap, and degraded premises demote ALL of them — the hold-for-ack ack IS the human confirmation), while `:gate` — and any unknown mode, **fail-closed** — can never return blockers; ALL AC-quality checks (vague/untestable/meaningless/missing/empty) are findings-only, riding the plan/safety-gate payload namespaced under `"premises_lint"` via `GateStep`'s runtime `extra_details` merge (clean ⇒ `%{}` ⇒ byte-identical gate details). Consumers: the premises block renders a dedicated AC-id section, reviewer lenses cite AC ids, `verify_certificate` gets the criteria engine-threaded via ToolContext (never LLM-relayed), the skill `verification_criteria` knob is live on both produce and evaluate sides, and cron agent jobs REQUIRE an `end_state`/`check`/`stop_bound` outcome contract at creation (OpenHelm OH1-3 shape — live at fire time via scheduler hydration + fingerprint; operator CLI and system jobs exempt). Lint table, gate payload, consumer threads, residuals → [docs/system/structured-premises.md](docs/system/structured-premises.md)
- **Evidence Floor (claims vs transcript — findings-only, never a gate)**: `JidoClaw.Orchestration.Verify.Evidence` (ouroboros OB1-3 port, signed map `docs/exploration/ouroboros/PORT-OB1-3.md`; absorbs camus C1-6c + the OpenHelm breach-counting rider) deterministically cross-checks coder/fixer self-reports against the durable tool rows and wave filesystem evidence at every fold. The **conservative override rule** governs everything: only a positive discrepancy (`:unsupported`) becomes a finding — can't-verify skips toward trust, masking (`form_mismatch`) is context-only in v1, and the verdict partition is ouroboros-verbatim (any genuine absence ⇒ `fabrication_suspected`; all-masked ⇒ `form_mismatch`). `tests_passed` needs a matching test invocation + exit 0 + `ShellCommand.exit_code_provenance/1` `:preserved` (the codified no-masked-gates rule: unprotected pipes, `|| true`-class idioms, and skip-flagged runners never prove green); `files_touched` reads the required `files_changed` field and is supported iff the path's status CHANGED between the wave's untracked-inclusive porcelain snapshots **or** an already-dirty path has two bounded content/type/mode fingerprints that differ. Existence is never support, missing fingerprints add no proof, and a missing before-porcelain snapshot still skips the kind. Findings are ENGINE-synthesized on stable stage-scoped keys (`evidence:<stage>:<kind>`) riding Hook R by shape; the RECORD (encrypted artifacts under producer `"evidence"`, the explicit signal pair, the `finding_keys` round, the `:evidence_classified` breach ledger) always welds in the wave commit, while the RE-FIRE (fixer feedback + invalidation) is gated on the same suppression fold as Hook R — the evidence lens's budget IS the fixer's rerun count, a live `findings:evidence` never converges, and exhaustion terminalizes `{:fix_failed, ["evidence", …]}`. Vendor-arm stages skip the transcript kinds (no rows — trust) but files still reconcile; redacted rows skip `:redacted`, never suspicious. Slice 2 (`Evidence.ACExtractor` + `Evidence.Assertions`): acceptance criteria extract ONCE at launch into typed assertions (persisted in parent config — the LLM never rides the fold), deterministically re-verified per producer wave under ported bounds (50KB/100 files/200-char pattern + a per-assertion Task timeout); every can't-verify branch trusts, the ONLY false branch is a compiled pattern absent across scanned existing files, and violations feed the SAME findings path (title `"AC<n> assertion failed: …"`, location = file_hint). Fingerprint/masking bounds, weld order, vendor asymmetry, slice-2 bounds, residuals → [docs/system/evidence-floor.md](docs/system/evidence-floor.md)
- **Executor Seam (template `executor:` binding — item complete, PRs 1–4 + the docker write build)**: every hydrated template carries `executor:` (`:in_process` default — today's in-process `Jido.AI` worker, byte-identical — or `{:forge, :fake | :shell | :codex | :claude_code | :custom}`) + `executor_config:` — **operator-declared config in the `verify_cmd` trust class, never the stage task**. Hydration validation **raises** (the refuse-to-run posture) and `:custom` is refused at dispatch — the camus unknown-backend fail-closed discipline. `access: :write` REQUIRES `session_sandbox: :docker` at hydration (write+local raises), and `session_sandbox: :docker` now DISPATCHES: the vendor session runs inside an sbx microVM with the run's repo mounted same-path (rw only under `access: :write` — the CLI's edits land directly in the real working tree; `:read_only` keeps the restricted CLI flags AND a `:ro` mount), depositing through the scoped endpoint via `host.docker.internal` under a per-sandbox `allow_network` policy rule; the microVM + mount mode is the boundary, so write means the runners' `:full` arms. `typed_output` arrives ONLY through the single-channel schema-validated deposit — a deposit-less lens stage rides the Verdict infra lane, never a fabricated verdict. Cross-vendor review (PR-3, camus C1-1's "no agent grades its own work"): a `.jido/config.yaml` `review:` section binds ONLY the `reviewer` template and is consulted at BOTH seams by `Orchestration.ReviewIndependence` — the composer launch fence (a strict-mode provider collision refuses the run BEFORE any wave) and the dispatch overlay (an invalid/unreadable knob is a step error, never a silent in-process fall-through); the YAML boundary refuses loudly on unknown keys and present-nil. PR-4 adds the per-stage catalog `executor:` override at both seams (precedence: test override > review knob > stage > template) and the `needs_input` answer loop — a runner's question raises a durable `:needs_input` `AgentCase` (the step still errors; no composer park) whose operator-approved answer is claimed **single-use** by the stage's next attempt and injected into the vendor prompt. Prototype/real-tree code search skips counted oversized and non-regular entries and returns deadline-limited matches with an explicit incomplete note instead of discarding prior findings; its configurable local timeout is always capped by the tighter Jido action deadline. Dispatch mechanics, vendor hardwiring, deposit/fixture contracts, independence resolution, residuals → [docs/system/executor-seam.md](docs/system/executor-seam.md)
- **Clustering & Lease Ownership**: multi-node execution is **off by default** (`cluster_enabled: false`); libcluster starts only when enabled AND distribution is up, across four topologies — `:gossip` (default; **raises without `JIDOCLAW_CLUSTER_SECRET`**), `:kubernetes`, `:epmd`, `:none` — with a layered trust model (the gossip secret *encrypts* discovery only; the **distribution cookie gates membership**; Ed25519 signatures authenticate the full network envelope, with sender-scoped replay suppression). Run ownership is a durable DB lease on `WorkflowRun`: a CAS stamp claims, token/status/park-fenced renew heartbeats, reclaim rotates the token, and every terminal revokes it in the same transaction. Gate checkpoint/resume and live-recovery terminals are row/token fenced; self-authored terminals stop their matching sidecar best-effort but always attempt the token-fenced terminal append. Single-node boot recovery is a synchronous barrier that retries recognized DB-infrastructure failures without opening degraded; clustered recovery comes only from the always-on `ReclaimPooler`. Persisted cron fires and their success/failure/disable outcomes carry a definition-generation token; `:every` claims use the DB clock, and non-durable follower windows are consumed rather than replayed after handoff. Five node-local lease telemetry events (claimed/renewed/reclaimed/fenced_out/recovered) + dashboard/observe ownership fields (surface v1.2). Topologies, flip checklist, invariants, and residuals → [docs/system/clustering.md](docs/system/clustering.md)

### Module Namespace Convention

`JidoClaw.<Subsystem>.<Module>` - key subsystems:

| Directory        | Purpose                                                                                                               |
| ---------------- | --------------------------------------------------------------------------------------------------------------------- |
| `agent/`         | Main agent, prompt builder, templates, workers                                                                        |
| `cli/`           | REPL, commands, branding, setup, formatter                                                                            |
| `forge/`         | Sandboxed execution (runners, sandbox backends)                                                                       |
| `tools/`         | All 45 Jido.Action tool modules (35 registered on the main agent)                                                     |
| `platform/`      | Session, Tenant, Channel, Cron, BackgroundProcess                                                                     |
| `reasoning/`     | Strategy + pipeline stores, classifier, telemetry, certificate templates, context compactor                           |
| `security/`      | Encryption vault, secret redaction, browse_web destination-policy gate                                                |
| `web/`           | Phoenix endpoint, controllers, LiveView                                                                               |
| `orchestration/` | Persistent workflow state machine                                                                                     |
| `solutions/`     | Solution fingerprinting, trust scoring, semi-formal verification                                                      |
| `mcp/`           | External MCP tool **consumption** — Consumer, Client, EndpointConfig, ProxyGenerator (vs `MCPServer`, which _serves_) |

### Data Layer

Ash Framework 3.0 + PostgreSQL. Resources in `lib/jido_claw/accounts/`. Test DB uses `Ecto.Adapters.SQL.Sandbox` for parallel isolation.

### Configuration Cascade

1. `config/config.exs` (compile-time, includes LLMDB model catalog)
2. `.jido/config.yaml` (user runtime config: provider, model, strategy)
3. `.env` / env vars (secrets - loaded at app start, env vars take precedence)

### `.jido/` Directory

Project-level config directory. `config.yaml`, `memory.json`, `sessions/` are git-ignored. `agents/`, `skills/`, `strategies/`, and `pipelines/` YAML definitions are committed. Schema details live in the module docs for `JidoClaw.Reasoning.StrategyStore` (user strategies + optional prompt templates) and `JidoClaw.Reasoning.PipelineStore` (user pipelines + optional `max_context_bytes`).

**`system_prompt.md`** is created from `priv/defaults/system_prompt.md` during setup but is not auto-synced afterward. When tools or skills are added to the defaults, manually copy the updated default to `.jido/system_prompt.md` — `mix jidoclaw.system_prompt.check` (in the `precommit` alias) enforces this: it requires the two copies byte-identical, set-compares the swarm template table and the handoff `to_template` enumeration against `Templates.spawnable_names/0` (one check per enumeration surface), and forbids stale storage claims (`memory.json`). The committed **`.jido/JIDO.md`** is guarded by `mix jidoclaw.jido_md.check` (in the `precommit` alias): it set-compares the file's tool/template/skill names and version against the registered truth, so tool/template/skill changes fail precommit until the committed file is updated (`JidoClaw.JidoMd.generate/1` emits the derived sections).

## Documentation

Deep per-subsystem truth lives in `docs/system/` — [docs/system/README.md](docs/system/README.md) is the hub (conventions + index). Each Key Patterns bullet above keeps its load-bearing contract inline and points at its page; mechanics, config, telemetry, and residuals live on the page. Rules: a change touching subsystem X updates `docs/system/<X>.md` in the same change, bumping `verified:`; an AGENTS.md bullet shrinks only in the commit that creates its page — machine-enforced in both directions by `mix jidoclaw.system_docs.check` (in the `precommit` alias); periodic freshness passes ride the doc-reconcile workflow.

## Planning & Implementation Conventions

- **Interview by blast radius**: when drafting a plan, surface its open questions as a short interview, one question at a time — only questions not answerable from the repo or tools (check those yourself first), ordered by how much the answer reshapes the design. The same rule holds mid-implementation: when the work surfaces a genuine open decision the plan didn't anticipate (multiple viable paths, scope or taste calls), present concrete options and ask rather than silently picking. Blocking for _alignment_ is welcome; blocking on something you could run, check, or verify yourself is not — never ask the operator to do what you can do.
- **Deviations log**: when implementing a plan from `docs/plans/`, record every deviation from the plan **as it happens** under a `## Deviations` heading in that plan doc — what the plan assumed, what the code revealed, what was chosen and why, and anything to revisit. Open decisions get surfaced per the interview rule before they're taken; forced corrections (one sensible path) are taken and logged. Either way the entry marks which kind it was. The log commits with the change it explains and is where the next plan learns.
- **Port semantics map**: before implementing a fidelity-critical adoption from the exploration corpus (or any external reference port), write the `PORT-<entry-id>.md` semantics map and get sign-off — anatomy and required-when rules in [docs/exploration/README.md](docs/exploration/README.md). An approved plan does _NOT_ constitute sign-off, the map must be explicitly signed-off.
- **Ephemeral HTML surfaces**: when richer formatting genuinely earns its keep — a throwaway editor for triage/reordering/constraint-aware config with a copy-back export, a one-shot diagram-heavy explainer or briefing, a design mockup to react to — build a self-contained HTML file rather than forcing the job into markdown. HTML is scaffolding, never source of truth: it lives in the session scratchpad (or a git-ignored tmp dir), is never committed, and anything it produces (an ordering, a decision, tuned values) exports back into the session as markdown for the durable record. Durable docs stay markdown in the repo — they are agent-ingested, grepped, diffed, and machine-checked, and HTML composes with none of that. Render from the local file (side panel); hosted artifact uploads are a leakage surface on this tailnet-only project and need an explicit operator ask.

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

Many packages have usage rules, which you should _thoroughly_ consult before taking any
action. These usage rules contain guidelines and rules _directly from the package authors_.
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
