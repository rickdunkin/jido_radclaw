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

**Exposed tools**: `read_file`, `write_file`, `edit_file`, `list_directory`, `search_code`, `run_command`, `fetch_output`, `git_status`, `git_diff`, `git_commit`, `project_info`, `run_skill`, `store_solution`, `find_solution`, `network_share`, `network_status`, `agent_status`, `inspect_agent`, `swarm_status`, `forge_status`, `workflow_status`, `inspect_workflow`, `replay_workflow`, `workflow_events`, `lua_query`, `lua_docs`. (`inspect_workflow`, `workflow_events`, and `replay_workflow` are MCP-only by design — none is in the in-REPL agent's tool list; `workflow_events` returns a run's raw, byte-paginated `WorkflowEvent` feed (G2-1a); `replay_workflow` additionally exposes no `force`/`allow_irreversible` overrides, replay-gate overrides being dashboard-only.)

**Exposed resources** (AR-2 Phase 5, §10.2): `jido://workflows/catalog` — the deterministic route-composer catalog (every composable stage: unit, routes, inputs/outputs, subscribes/publishes, locks) as `application/json`, so a client can *discover* the composable surface, not just trigger it. `jido://workflows/<stage>` (G2-1b) — the per-stage drill-down: an anubis `component` template resource (`jido://workflows/{name}`, listed under `resources/templates/list`, single-sourcing `Stage.to_map/1` so a stage read is byte-identical to the catalog's entry; unknown stage ⇒ resource not-found). `jido://_meta/version` (pad PD1-1, next-ten #6) — the served-surface version facts: `app_version` (single-sourced `SurfaceVersion.app_version/0` over `Application.spec/2`; `server_info/0` is hand-defined to carry the same — never a hand-rolled literal, the old "0.2.0" rot lesson), `surface_version` (`JidoClaw.MCPServer.SurfaceVersion` — the stability contract clients pin against, bump rules + changelog in its moduledoc; the golden `served_surface_golden_test.exs` set-compares tool names / static resource URIs / template URIs / the version string per enumeration surface against the committed `test/fixtures/mcp_surface/served_surface.json`, so a surface change without a deliberate bump fails precommit), and `tool_count`. `jido://bootstrap` (PD2-1, slim) — one-read client orientation: versions + sorted tool names + a bounded tenant snapshot (identity, pending-gates count, `active_runs`/`recent_completions` as `Visibility.run_view` rows capped at 5 with `*_overflow_count` from a cap+1 read — ≥1 means "more exist", never a total; an unresolved MCP scope reads `available: false` with a reason, and a failed read inside a resolved tenant flips that block's `*_available: false` flag — honesty over fabricated zeros, the deliberate inversion of the dashboard rollup's degrade-to-zero). `inspect_workflow` reads a single composer run's live route / waves / held / dropped / live signals + gate-block state; `workflow_status` is the tenant rollup.

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
- **Output Shaping**: Verbose tool output (`run_command`, `git_diff`) is compressed format-aware by `JidoClaw.Tools.OutputShaper` (stage between `OutputRedaction` and `OutputLimit` in the shared `Tools.Action` pipeline). Rule: compress the green, never the red — `mix test`/`mix compile` success noise becomes counts, failure/warning blocks stay verbatim, unknown formats get head+tail. The full captured output (up to 512KB; `truncated` flagged beyond) is stored tenant-scoped in `Conversations.ToolOutput` under an unguessable ref (`JidoClaw.Refs.mint/1` — 12 random bytes → 24 hex, single-sourced with the `art_…` composer-artifact refs; O-L2) and retrievable via the `fetch_output` tool, so shaping is reversible. The `fetch_output` read is always tenant-scoped and ALSO **session-scoped** (S-M2) on session-meaningful surfaces (`serve_mode != :mcp` with a resolved `session_uuid`) via `ToolOutput.by_ref_scoped` — a session resolves only its OWN rows, blocking a same-tenant cross-session peek. System/cron-minted (`session_id: nil`) refs stay reachable from any session (the `is_nil` filter arm), and under `:mcp` the boot scope stays tenant-wide (the documented REPL-minted-ref drill-in flow). Anything that would exceed `OutputLimit`'s 32KB inline cap — an oversized shaped/all-signal body — is bounded by head+tail elision with the ref footer intact (never ref-less truncated), and `fetch_output` itself clips oversized slices to the cap (direction-aware) and reports honest `clipped`/`selected_lines` metadata. `run_command` requests the larger capture from `SessionManager` via the `:capture_bytes` opt only when `OutputShaper.shapeable?/3` holds (same predicate on capture and shaping sides). Disabled ⇒ byte-identical legacy truncation (`enabled?: false` in test.exs); no-tenant calls pass through unshaped; streaming runs are never shaped. Config under `:output_shaping`; telemetry on `[:jido_claw, :tool, :shaping]` plus `:output` Trace events. **External MCP proxy results** (`mcp_<server>_<tool>`) take a parallel **generic** path (`mcp_shapeable?/2` → `safe_shape_mcp/3`): above the inline cap (or for any unencodable term) the whole result is pretty-serialized, capture-capped with tail-preserving elision, ref-stored, and collapsed to a bounded `:output` wrapper with the spec-standard `isError` lifted (the model's only failure signal); below the cap the structured result passes through. ANSI stripping now lives at the **root in `OutputRedaction`** (`Security.Redaction.Ansi.strip/1`, applied before both value redaction and key classification), so an escape-split secret (`sk-ant-\e[0m…`) or split sensitive key (`api_\e[0mkey`) is reassembled and caught for every tool and every path before the shaper sees the text — the shaper's own strip is now belt-and-suspenders. **Accepted residuals** (this review — documented, not fixed): (S-M3) streamed `run_command` chunks reach the OPERATOR's own terminal un-redacted — the model-facing copy IS redacted, and the threat model is model-input / durable-sink hygiene, not the operator's local echo (streaming runs are never shaped, per above); (S-L2) the memory-consolidator's internal tools bypass this shared `Tools.Action` pipeline — internal-only, and ingest redacts at the sink; (O-L1) the composer's `ensure_parent_live` child-create reload can briefly fail OPEN (`route_composer.ex`), but the wave fold stays fenced at `commit_wave` (the token CAS), so no unfenced write survives.
- **Context Compaction**: Long sessions are compacted live via `JidoClaw.Reasoning.Compactor`. The `JidoClaw.Agent.Defaults` macro accepts `compaction: [...]` opts and injects an `on_before_cmd/2` override on `{:ai_react_start, _}` that runs `Compactor.maybe_compact/3` before delegating to `super`. The main `JidoClaw.Agent` and all 16 worker templates carry `compaction: [mode: :auto]`. Per-agent keying shipped: each agent compacts its own slice keyed by `JidoClaw.Reasoning.Compactor.Identity` (`"main"` for both main surfaces, `"handoff:<uuid>:<tpl>"` for a routed worker, the spawn tag for a sub-agent), with per-key snapshots persisted under `Session.metadata["compactions"][key]` (`key = "<identity>::<context_ref|default>"`) via atomic `jsonb_set`; spawned/handoff sub-agents get coherent durable transcripts via `JidoClaw.Conversations.SubagentTranscript`. (Real `context_ref` lanes remain a no-op follow-up — no producer currently sets `context_ref`, so keys normally trail `::default`, though the code accepts one if it appears in tool context.) Best-effort: storage and summarizer failures are emitted via `:compaction` Trace events and logged, but never block the agent's forward progress. The actual LLM-facing message trim happens in `JidoClaw.Reasoning.Compactor.RequestTransformer` (a `Jido.AI.Reasoning.ReAct.RequestTransformer` implementation) — it filters projected messages by `refs.request_id ∈ snapshot.summarized_request_ids` and injects the summary as a delimited user-role message. **That module is now the app's single COMPOSED transformer** (AR-9): besides the compaction `:messages` override, it reads `runtime_context[stage_tier_key()]` (`:__jido_claw_stage_tier__`) and returns per-turn `model:` / `llm_opts: [reasoning_effort: e]` overrides — the per-stage tiering seam. A tiered composer stage (`%Stage{}` `model`/`effort`, carried by `WaveBuilder` into the step options) reaches it via `AgentRunner.run/6`, which puts the tier map in `tool_context` and pre-sets `request_transformer:` on the ask (same module ⇒ no Compactor collision; `install_overrides` adds to `tool_context` rather than replacing it, preserving the tier key). The `plan-arbiter` stage (AR-9 PR-4, the seam's designed first declarer) now declares `model: :capable, effort: :high`; every other stage stays undeclared (session default). PR-2 of the same program threads composer `premises` into every worker wave's `:extra_context` via `JidoClaw.RouteComposer.PremisesContext` (`compose_extra_context/2` in `route_composer.ex`; empty premises ⇒ byte-identical prompts, gate waves excluded), and `AgentStep` emits `[:jido_claw, :composer, :stage_prompt]` (`bytes` + stage/template) for composer stages only.
- **Tool Approval Gate**: A per-tool-call human-approval checkpoint on the conversation axis (complementing the workflow-axis Reactor gate family). The shared `Tools.Action` wrapper runs `JidoClaw.Security.ToolApproval.gate/4` as its first stage (before redact/shape/cap): a require-listed tool (`config :jido_claw, :tool_approval, require:` — default `network_share, kill_agent, schedule_task, unschedule_task, git_commit, forget, replay_workflow`, single-sourced in `ToolApproval.default_require/0`) **or** a param-pattern trigger (in-module `@require_patterns`, e.g. `run_command` commands matching `git commit`/`git push`/`crontab`) routes through `JidoClaw.Orchestration.ToolApprovals.request/3`. The producer maps a canonical `{tenant, session, tool, args}` fingerprint to a durable run-less `AgentCase` (kind `:tool_call`) and the tool returns a non-retryable `{:error, %{code: :approval_pending | :approval_denied | :approval_unavailable}}` envelope the LLM relays. Approvals are **single-use** (`:consume`), rejections are **deny-once** (`:consume_rejection`); the FOR-UPDATE re-read in the producer transaction is the real concurrency fence (the `change filter` on the case actions is not a DB fence in ash_postgres 2.9), and the named partial unique index `agent_cases_pending_fingerprint_index` collapses the open race. Operators decide via the same surfaces as workflow gates (REPL `/gates`, web `/approvals`) through `Cases.decide/4`'s run-less branch. `enabled?: true` by default; `enabled?: false` in test (tests drive `gate/4` with explicit opts). The `tool_context` nesting the gate relies on is guaranteed by `JidoClaw.ToolContext.ensure_nested/1` in the wrapper (the live ReAct path arrives flat). **Shell-floor reach (S-M1)**: the `run_command` param-pattern runs `JidoClaw.Security.ShellCommand.analyze/1`, whose fail-closed `:opaque` floor also covers command-runners wrapping a gated root/shell (`xargs`/`parallel`/`ssh`/`su -c`/`flock`/`find -exec`, `scope: :runner`) and interpreter one-liners / stdin programs (`python -c`, `node -e/-p`, `perl -e`, `echo … | python`, `python -`, `scope: :interpreter`) — gating on the flag/reach alone, never parsing the wrapped code, and failing closed on any dynamic runner/interpreter arg. Documented **residuals** (conscious `run_command` escape valve, NOT gated): the `npx`/`nix run` family (running an arbitrary package is statically unknowable), interpreter *script-file* invocations (`python foo.py`, `… | python foo.py`), and the pre-existing login-file-alias / script-file-indirection cases (`bash deploy.sh`). The `:docker` shell-floor skip (`tool_approval.ex`) suppresses all of it inside a provisioned microVM.
- **Loop Guard (doom-loop detection)**: `JidoClaw.Agent.LoopGuard` (osa OS1-2 port @ f60e933b, Apache-2.0 — detection thresholds, halt texts, and suggestion table verbatim; integration rewritten) runs inside the shared `Tools.Action` pipeline AFTER the approval gate: a pre-execution `check/4` (a doomed call is blocked before it runs) and a post-normalize `observe_result/5` (reads the canonical `%{code, message, details}`; skip-lists `approval_*`/`doom_loop` codes — non-executions never count). Three mechanisms per `{tenant, session, agent}` key (`Reasoning.Compactor.Identity`; state in `LoopGuard.Store`, in-memory **per node** — clustered cron `:agent` jobs fire on every node, so the worst-case budget scales with node count): (1) a trailing run of ≥4 identical `{tool, sha256(args)}` calls in the last 8 halts immediately, success-agnostic — the 4th call never executes; (2) any failure signature (`{tool, first-100-chars}`; typed classification — `{:error, _}` tuples, run_command's `{:ok, %{exit_code: n}}` with `n != 0`, or the MCP proxies' re-surfaced `{:ok, %{"isError" => true}}` domain failures, never error-string sniffing) reaching 3 in the last 20 error results triggers a staged response: a recovery directive appended to the field the LLM reads (`message`, `output` for the nonzero-exit OK shape, or an appended `content` text item for the MCP isError shape) twice, then a halt — and a clean success of tool T clears only **T's** signatures (deliberate deviation from OSA's documented clear-all, which would mask the edit-fail → read-ok → edit-fail repair loop); (3) 100 executed calls per key cap the budget — the 101st is blocked, with a one-time log+Trace warn at 80% (never injected into results). Halts are sticky for `halt_ttl_ms` (5 min), then the key resets fresh; idle keys expire after `idle_ttl_ms` (30 min). The halt envelope `{:error, %{code: :doom_loop, message: …, details: %{retry: false, trigger: …}}}` is non-retryable at BOTH retry layers (the ForgeBridge precedent; details key `:trigger`, never `:reason`), proven by an Exec/Turn-driven contract test; 3-tuple results keep their effects. **Feed-boundary residuals** (documented + test-pinned): `Jido.Exec`/`Turn` wrap AROUND `run/2`, so param-validation failures, Exec/Turn timeouts, and raised exceptions bypass observation (under-detection), and an output-schema validation failure after `{:ok, _}` records a **false success** — neutralized cross-tool by per-tool clearing, with same-tool identical-args repeats still caught pre-execution; residual is varied-args output-validation loops only. No-tenant/no-session calls pass through unguarded (the OutputShaper posture) and the facade fails open (`try/rescue` + `catch :exit` → pass-through): a budget guard must never break a tool call. Config under `:loop_guard` (`enabled?: false` in test); telemetry counter `jido_claw.loop_guard.total` plus `:guardrail` Trace events — the channel's first producer.
- **Verdict Normalizer (infra ≠ verdict ≠ inconclusive)**: `JidoClaw.Orchestration.Verdict` (camus C1-3 port @ 53da91b3, MIT — next-ten #4) is the single normalizer every probabilistic judge output passes through, with three exits: `{:verdict, %Verdict{}}` (`clean? = approve AND zero findings` — findings-win), `{:infra, reason}` (empty/non-map/drifted-enum/self-contradicting output — **schema drift fails CLOSED to infra**, never a verdict, never clean), and `{:inconclusive, reason}` (produced by the item-5 deterministic verify — refusals + the composer's `"uncertified_green"` reclassification; consumers fold it into the infra lane). `normalize/2` is total over arbitrary input (it is also item 7's deposit-tool contract); Review-kind field coverage is **routing-critical only** (`overall`, findings list-ness, finding map-ness, `severity`) — prose fields pass through unvalidated, and Zoi still enforces the full schema on the LLM path. Consumers: `DefaultMapper` dispatches on **lens presence, not output shape** — an infra'd reviewer becomes an emission with no signals/artifacts and `outcome: {:infra, reason}` (`StageEmission.outcome`, fail-closed decode on the DB trust boundary), which the composer never folds into `ran`; instead the stage retries on the SEPARATE per-stage `infra_cap` budget (default 2 ⇒ 3 attempts, camus's INFRA_RETRIES; persisted in parent config so a restart keeps a caller's override) via durable `:stage_infra` events — Lane A (unusable verdict) welds the marker into the wave commit (stage names only, no reasons — redaction posture); Lane B (a **lens-only** cohort's wave-execution error, incl. the recovered-failed-child dedupe arm and — post-review P1 — the dedupe-hit observe arms: observed-failed / observe-timeout / observe-reload, where the composer still has no trustworthy verdict for the lens even though the immediate failure came from observation/recovery machinery) appends it with `closed_wave_index` so a restart rebuilds past the failed wave instead of deduping onto the corpse (mixed/producer cohorts keep today's loud `route_failed`; an observed worker `:cancelled`/`:abandoned` stays an operator decision, never infra). Exhaustion terminalizes `:route_review_infra_failed` (disposition `"review_infra_failed"`, outranking fix/verify_failed at the budget gate) — infra never consumes `rerun_cap`, never reads clean, never summons the fixer with empty feedback. `IterativeStep` routes evaluator output through `normalize(:iterative_eval, _)`: a garbled/tokenless verdict (or an evaluator `AgentRunner` error) re-runs the **evaluator only** on `infra_retries` (default 2) without burning an iteration — the old `parse_verdict/1` → `:fail` conflation was camus's "#1 cause of runaway loops". Observability: `:composer` Trace events (bounded reasons, `run_id`-indexed, tenant-stamped — post-review P2 attached the channel in the collector and made the timeline reachable via `Trace.list({:tenant, …})`) + the `jido_claw.composer.infra.total` counter; `Observe`/`WorkflowView` treat any `closed_wave_index`-bearing event as closing its wave. The five trust-boundary laws + the event-sourced durability checklist live in `docs/TRUST-BOUNDARIES.md` (camus C2-8) — the review rubric for orchestration/gate changes.
- **Deterministic Verify Authority (engine-run, head-bound, tamper-fenced)**: `JidoClaw.Orchestration.Verify` (camus C1-2 + C1-6a port @ 53da91b3, MIT — next-ten #5) is the engine-side verifier: the composer runs the repo's verify command itself and reads the **exit code** (law 2 of `docs/TRUST-BOUNDARIES.md` — the verdict never rides an LLM relay), dispatched as the catalog's `{:verify, "default"}` stage (`Reactors.VerifyStage`, the gate-reactor shape minus the park; `VerifyReactors` is the closed name→module seam) which `Loop.defer_solo_verify/2` — the INVERSE of the gate peel — makes run LAST in its Kahn level, solo; a catalog holds **at most one** verify stage (`CatalogValidator` invariant 10 — `verified_integrity` is a single latest-wins certificate, so a second verify authority would ping-pong retract/re-verify at convergence; multi-check needs belong in one stage's named `checks:`). Command resolution (`Verify.Config`, the OQ-4 design note of record): per-run `verify_override` (persisted in parent config) → `.jido/config.yaml` `verify_cmd:`/`verify:` (incl. the orca OR2-2 registry-lite named `checks:`; an override naming an unknown check refuses loudly, and a non-map `verify:` value refuses loudly too — never a silent fall-through to autodetect) → mix auto-detect (`precommit` alias ⇒ `mix precommit`, else `mix test`) → a loud INCONCLUSIVE envelope — never a pass, never a silent skip, and **no shell, ever**: argv lists via `Core.OsCmd` with execvp-style argv0 resolution (scalars whitespace-split only when metacharacter-free and not env-assignment-led; config errors ride the infra lane, never a wave failure). Two integrity modes, auto-selected by the engine-observed `sealed_head` (C1-6b: the composer welds `:head_observed` markers at wave boundaries — first = durable baseline, a change = seal — and `Tools.GitCommit` returns engine facts: rev-parse before/after, `committed` ⇔ head moved, staged-empty ⇒ explicit `no_changes` success): **sealed** is camus-verbatim (dirty tracked tree before checks ⇒ RED `uncommitted_state`, checks never run; HEAD≠seal ⇒ `head_moved`), **working_tree** (today's non-committing default) records dirty-before as an envelope FACT and fences mid-verify integrity via HEAD stability + a content-addressed `git diff --no-ext-diff --no-textconv --binary` sha256 digest (porcelain can't see content edits to already-dirty files). Verdict mapping: green ⇒ `clean:verify` + a welded `:verify_certified` marker (`{head, tree_digest, mode}` — the committed invariant: `clean:verify` and its certificate land in the same commit or not at all; an uncertified green is reclassified `{:inconclusive, "uncertified_green"}` BEFORE the fold, report preserved via the non-routing `:verify_report_recorded` marker); red ⇒ `findings:verify` + `findings`/`action_needed` artifacts riding the existing Hook R fixer re-fire (exhaustion ⇒ `:route_verify_failed`); inconclusive (`missing_tool`/`no_tests`/`timeout`/`output_limit`/`integrity_unavailable` — a would-be green with a FAILED git capture downgrades here, the law-4 correction of camus's degrade-open) rides the #4 infra lane and stores NO report; tampered ⇒ the `:route_verify_tampered` terminal via a welded `:stage_tampered` marker (report ref on the marker, NEVER `artifacts_produced` — a tamper report must not look routable; the tick checks `tampered_stages` AHEAD of every other terminal branch, and VERIFY_OATH holds: never retried, never fed to the fixer — remediation destroys the evidence). Convergence re-derives the MODE-SPECIFIC integrity tuple against the folded `verified_integrity` before `:converged` (mismatch or unreadable capture ⇒ retract + re-verify; `stages_invalidated` covering the verify stage clears the certificate; Hook F retracts a live `clean:verify` in the same welded batch when a fixer runs). The three LLM verification judges (`verifier`/`system_verifier`/`test_runner`) carry the verbatim `verify_oath` doctrine slice + read-only `lua_query`/`lua_docs` evidence (OpenHelm OH1-3) — they diagnose reds, never hold the verdict. Config under `:verify` (`timeout_ms`/`max_output_bytes`/`tail_lines`; NO `enabled?` — registration is the switch; test.exs points `runner:`/`git:` at the hermetic stub); runner output is redacted-in-full (ANSI-strip → patterns) BEFORE tailing; telemetry counter `jido_claw.verify.total` + `:composer` Trace events (bounded — log tails live only inside the encrypted `verify-report`). Documented residuals: `verify_cmd` is operator-owned config a mid-run fix loop could edit (camus C2-7, parked); untracked-file mutation is invisible to tracked-only integrity (camus-consistent); engine verify runs outside the tool pipeline (no approval gate / loop guard — it is engine code, law 1).
- **Honest Terminal Statuses + Stall Detection (finding identity, review_stall gate, done_with_findings)**: camus C1-4 + C1-5 (next-ten #6). Reviewer findings carry a cross-wave identity: a required short `title` + `JidoClaw.RouteComposer.FindingKey` — `{:v1, normalized-location-file, downcased-title}` through `Core.CanonicalHash.sha256_term/1` (title downcased, file NOT; un-keyable findings excluded — never a fabricated identity) — welded per reviewer round into the wave commit as a `:finding_keys` marker (hex keys + enum severity/confidence marks only; findings persist as encrypted `ComposerArtifact` rows the projection never decrypts, so the marker IS the durable identity; a clean round welds `keys: []` to advance the lens round). The fold detects **stuck** (key survives its own fix round) and **oscillating** (key reappears after absence) findings; `fix_stop_lenses/1` (stall evidence ++ re-review-budget exhaustion — never dispatch a fix its flagged lens has no budget to re-review) suppresses ALL of Hook R, and on a **green AND certified** verify (`verify_green_certified?/1`) the composer parks at a `:review_stall` gate instead of terminalizing: a **parent-stays-`:running`, child-less park** raising a durable run-bound `AgentCase` (fingerprint over the sorted keyable keys; raise-time decrypt → `Transcript.redact` → per-field bounds on the case details; camus C3-2 `resume_hint` included; deadline TTL abandons, committed-decision-beats-deadline) decided through kind-dispatched `Cases.decide/4`/`abandon/3` branches — never `GateStep`/`GateResume`. Approve requires **per-finding waive records covering every surviving key** (all-or-reject, `{:error, :incomplete_waiver}` — orca OQ-1 as decided; completeness validated PRE-transaction, the `Ash.transact`-wraps-errors-opaque precedent), recorded on the case's `:approved` timeline event; reject ⇒ `fix_failed`. Approval terminalizes `:route_done_with_findings` — the **completed-family** disposition (`result.disposition = "done_with_findings"` + keys/counts/severity histogram/trend/certified head; verbatim finding bodies never ride the result — redaction posture). Every surface marks it, never plain green: `Visibility.run_view` carries `disposition`/`findings_deferred_count` (every downstream surface inherits), the web badge renders amber "completed · findings", `WorkflowView` rolls up `findings_deferred` over its recent-completions window, CLI text/JSON mark the disposition (headless exit stays 0). The waived-debt ledger is `Cases.waived_findings_ledger/2` (a filter over gate decisions — no new table) + the `jido.debt` Lua binding; the adjacent disposition vocabulary (traycer TR3-2 `superseded`, pad PD3-3 lineage badges, bosun BO2-6 retry verbs) is deliberately named-not-built in the `Gate.Kinds` moduledoc. Verify-less/red routes keep today's terminals (a red-verify stall lands `fix_failed`); recovery re-derives the park from the rebuilt state and resolves by fingerprint with zero recovery-code changes. Telemetry: `jido_claw.composer.stall.total` (per-lens :stuck/:oscillating/:exhausted) + one bounded `:composer` `:fix_stopped` Trace event (hex keys only).
- **External MCP Tool Consumption**: The platform both *serves* MCP (`JidoClaw.MCPServer`, 26 tools + the `jido://workflows/catalog` resource and the `jido://workflows/{name}` per-stage template) and now *consumes* it (`JidoClaw.MCP`). Operators declare external servers in `.jido/config.yaml` under `mcp_servers:` (stdio/sse/streamable_http); `JidoClaw.MCP.Consumer` (a boot GenServer with off-process, crash-isolated prep) discovers each server's tools and compiles a proxy `Jido.Action` per tool via `JidoClaw.MCP.ProxyGenerator`. **The payoff: generated proxies `use JidoClaw.Tools.Action`** (not bare `Jido.Action` like the dep's `Jido.MCP.JidoAI.ProxyGenerator`, which returns remote data raw), so the full safety pipeline (`ToolApproval.gate → Error.normalize → OutputRedaction → OutputLimit` inside `MCPScope.wrap`) wraps every call automatically — inbound results are **redacted + capped + generically shaped** (an `mcp_`-rooted name takes `OutputShaper`'s `safe_shape_mcp/3` collapse-above-cap path: pretty-serialize → capture-capped ref-store → bounded `:output` wrapper with `isError` lifted; format-aware parsing stays `run_command`/`git_diff`-only), and the proxy adds **outbound arg scrubbing** (now also strips ANSI, via the `OutputRedaction` root pass) plus **re-surfaces jido_mcp's `:tool_error` promotion** — a domain `isError: true` result is a *successful* MCP response per spec, but the dep promotes it to `{:error, %{type: :tool_error, details: <raw result map>}}`; the proxy re-surfaces it to `{:ok, data}` (matching `"isError" => true` in `details`, so transport/protocol/validation errors stay `{:error, _}`) so the headline failure case is shaped + `isError`-lifted + ref-stored rather than buried by `Error.normalize` and ref-lessly head-cut by `OutputLimit`. Names are `mcp_<server>_<tool>`, deduped + 64-char-capped + asserted `mcp_`-rooted; the remote `inputSchema` is passed through directly as the action `schema:` (a JSON-Schema map is an LLM-only pass-through — `Zoi.map()`/`to_zoi` would advertise *no args*). Attach is non-blocking: `attach_to_agent/2` (fire-and-forget, REPL boot + `:prepared`/restart rehydrate from `AgentTracker`) and `ensure_attached/3` (bounded, every agent-turn path — the Consumer defers its reply so the *caller* waits, never the Consumer). **Per-template reach-allowlist** (worker/sub-agent sync): every turn surface — chat (REPL + chat/4), handoff-routed turn, spawn, follow-up, skill-step — runs `ensure_attached(pid, template, 8_000)` keyed by `tool_context.agent_template`, and a server's `templates:` allowlist scopes *which* templates register its tools (`[]`/absent ⇒ all; a list ⇒ only those — withheld at *registration*, so the LLM never sees them; the moment any server uses an allowlist the operator must include `"main"` to keep its tools on the interactive agent). Enforcement is `Consumer.modules_for_template/3` (reach, not gating — `tool_approval.ex` is untouched; a finer per-tool *approval* overlay for MCP stays an explicit non-goal). **Default-on approval**: the Consumer publishes `%{tool_name => true|false|nil}` to `:persistent_term`; the private `ToolApproval.requirement/4` gates every `mcp_*` tool unless its server is trusted (`require_approval: false`) or the global `mcp_require_approval` is false — and an unknown `mcp_`-prefixed name (lost/unset policy) falls back to the global default (**fails CLOSED to gated, never to native**). **Trust boundary** — two things sit *outside* the per-call gate (`require_approval` gates tool *calls*, not server *startup*): (1) **stdio subprocess env** — `Port.open`'s `{:env}` overlays, not replaces, the host env, so a patched `Jido.MCP.Transport.STDIO` (`lib/jido_claw/core/mcp_stdio_transport_patch.ex`, registered in `DependencyPatches`) builds `:env` via `Env.scrubbed_port_env/1` (default-deny: host secrets unset; endpoint `env:` is the operator override map); (2) **tool names/descriptions are prompt-trusted before any call** (the gate can't stop description-borne injection), so configured servers are trusted for prompt metadata — `ProxyGenerator` only strips control chars + caps description length. Deferred: per-tool (vs per-server) approval overlay for `mcp_*`.
- **Lua Code-Mode Queries**: `lua_query` + `lua_docs` (amber AM-1 + jidoka V2-7; on BOTH tool surfaces) run a short **read-only** Lua script server-side so cross-run filter/join/aggregate happens in the sandbox — intermediate rows never enter model context. Seven host bindings in `JidoClaw.Tools.Lua.Bindings` (the single source; `lua_docs` renders from it): `jido.runs` (new `WorkflowView.runs/2`, honest `:runs_unavailable`), `jido.run` (snapshot), `jido.events` (byte-bounded feed), `jido.cases` (pending approvals, fixed-field projection), `jido.solutions` (**lexical-only** — passes the `resolve_embedding?: false` Matcher opt so a sandbox read can never trigger Voyage egress), `jido.output` (stored-ref slices via the shared `Tools.OutputRef`, inheriting fetch_output's S-M2 session scoping exactly), `jido.debt` (the waived-findings ledger — `Cases.waived_findings_ledger/2`, next-ten #6's BO2-6 fold-in). Every binding is read-only (`assert_read_only!/0` per eval — a future write binding must clear it deliberately and join the approval require-list; the pair itself is deliberately NOT require-listed) and every callback threads the post-`Lua.encode!` VM state back. `JidoClaw.Tools.Lua.Runner` lifts LuaEval's task-isolation hardening (unlinked task + watchdog + heap kill + deadline gate) and adds the lua-1.0 VM budgets (`max_instructions`, `max_string_bytes` — the VM is a from-scratch pure-Elixir implementation, NOT Luerl) under `JidoClaw.Tools.Lua.Policy` clamps (jidoka port @ 9469dc09, Apache-2.0, `max_parallel_calls` dropped); `print`/`debug` are sandboxed post-`Lua.new` (the default sandbox misses them, and `print` writes model text to host `IO.puts`). Two checks are deliberately **post-eval** because in-script `pcall` can swallow host raises: budget refusal (latched in `CallTrace.refused?/1` → `:lua_call_budget_exceeded` even over a "successful" eval) and the aggregate `max_result_bytes` bound (`:lua_result_too_large` — load-bearing: `OutputLimit` caps string leaves only, nothing else bounds a big structured result). All `:lua_*` envelopes are non-retryable at both retry layers (`details.retry: false`; `:lua_timeout` deliberately so — same script + same caps re-times-out); missing tenant stays a bare `:tenant_required` (the workflow_status precedent). Config under `:lua` (caps only — **no `enabled?`**: registration is the switch, clamps make bad values safe; no test.exs entry — tests pass explicit opts). Telemetry counter `jido_claw.lua_eval.total` + `:guardrail` Trace events (one terminal `:eval` per run + a discrete `:budget_refused`).
- **Deterministic Eval Harness**: `JidoClaw.Eval.{Case,Run}` package `{kind, request, assertions}` cases run via `JidoClaw.Eval.run_case/2` against **production functions only** (no new runtime path): `:prompt` (the assembled `SubagentPrompt.build/3`), `:schema` (a worker's `strategy_opts()[:output]` via `Jido.AI.Output.parse/2`), `:composer` (`RouteComposer.run_sync/1` through the real gate dance), `:coherence` (doctrine-slice prose ↔ per-token schema probes — the prose-half/schema-half field contracts). The fake↔live seam is the caller's app-env arming + `run_case` opts (`tenant`/`actor`/`context`/`timeout`), never a test module named in lib; unknown assertion keys fail loudly (an `:unknown_assertion` record fails the run — a deliberate deviation from jidoka's silent skip; a malformed assertion value/item fails via `:invalid_assertion_value`, an evaluator raise via `:assertion_raised`). Seed cases pinning the post-AR-9 prompt surface live in `test/jido_claw/eval/`; harness unit tests in `test/jido_claw/eval_test.exs`.

### Module Namespace Convention

`JidoClaw.<Subsystem>.<Module>` - key subsystems:

| Directory        | Purpose                                                                                     |
| ---------------- | ------------------------------------------------------------------------------------------- |
| `agent/`         | Main agent, prompt builder, templates, workers                                              |
| `cli/`           | REPL, commands, branding, setup, formatter                                                  |
| `forge/`         | Sandboxed execution (runners, sandbox backends)                                             |
| `tools/`         | All 45 Jido.Action tool modules (35 registered on the main agent)                           |
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

**`system_prompt.md`** is created from `priv/defaults/system_prompt.md` during setup but is not auto-synced afterward. When tools or skills are added to the defaults, manually copy the updated default to `.jido/system_prompt.md` — `mix jidoclaw.system_prompt.check` (in the `precommit` alias) enforces this: it requires the two copies byte-identical, set-compares the swarm template table and the handoff `to_template` enumeration against `Templates.spawnable_names/0` (one check per enumeration surface), and forbids stale storage claims (`memory.json`). The committed **`.jido/JIDO.md`** is guarded by `mix jidoclaw.jido_md.check` (in the `precommit` alias): it set-compares the file's tool/template/skill names and version against the registered truth, so tool/template/skill changes fail precommit until the committed file is updated (`JidoClaw.JidoMd.generate/1` emits the derived sections).

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
