# Codebase audit — 2026-07-04

Scope: full `lib/` (571 files, ~110K LOC), `test/` (~415 files), top-level docs, committed
`.jido/`, `priv/defaults/`, config, mix tasks, and cross-cutting wiring (config keys,
signals, telemetry, PubSub, deps). Explicitly **not** a security review. Method: 12
parallel subsystem auditors + an independent xref/grep pass + tooling checks; every
**bug** below was re-verified by hand; dead-code items carry the auditors' repo-wide
caller-grep evidence. `docs/exploration/` (incl. the in-flight argus/pms work) excluded.

Confidence: `[H]` verified end-to-end; `[M]` strong, one step unverified.

## Health snapshot (what's fine)

- `mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix deps.unlock
  --check-unused` all green; zero real TODO/FIXME markers in lib.
- `mix jidoclaw.system_prompt.check` green — `.jido/system_prompt.md` and
  `priv/defaults/system_prompt.md` are byte-identical and the 35-tool catalog matches
  the registered set.
- **AGENTS.md is remarkably accurate** (verified: 26 MCP tools, 35 REPL tools, 16 worker
  templates, tool-approval require-list, LoopGuard/OutputShaper/Lua defaults, ~30 cited
  symbols). docs/TRUST-BOUNDARIES.md also checks out.
- All `.jido/agents/*.yaml` + `.jido/skills/*.yaml` tool/template refs resolve; doctrine
  and persona files are consistent with worker schemas.
- No skipped tests, no commented-out test blocks, no legacy `jido_cli.` signal strings,
  no config keys that can crash at boot, no dual-spelled config keys.
- All four dependency patches in `core/` (anubis, 3× jido_shell) verified still needed at
  the pinned dep refs.

Ground-truth counts (several docs disagree, see §4): **45** tool modules exist, **35**
registered on the main agent, **26** exposed over MCP, **16** worker templates,
**16** Ash domains.

---

## 1. Bugs (all hand-verified)

> **Status — updated 2026-07-04.** Eleven of these bugs — **1.1–1.8, 1.10, 1.11, 1.13** —
> are fixed in a single migration-free batch bugfix PR, each carrying a red→green regression
> test (plan: `.claude/plans/please-review-docs-reports-codebase-audi-lexical-crown.md`).
> Per-entry `✅ Fixed` markers, plus a `Resolved:` note wherever the implementation diverged
> from the suggested fix, are inline below. **1.9** is **deferred** (needs a wire-vs-delete
> product call + a DB migration) — findings preserved in
> `docs/reports/forge-session-fields-1.9-followup.md`. **1.12** shipped with the
> 2026-07-05 §3 doc-sweep PR (generator now derives from the registries);
> **1.14** is left as-is (dead code inside the §2.1
> GitHub pipeline — only matters if that pipeline is revived).

### 1.1 `[H]` AgentTracker double-counts tool calls — ✅ Fixed
`lib/jido_claw/agent_tracker.ex:295,310,415` — both the `[:jido,:ai,:tool,:execute,:start]`
and `:stop` telemetry handlers call `track_tool/2` (the `:stop` clause's own comment says
"redundant but ensures count"), and the cast increments `tool_calls` unconditionally.
`deps/jido_ai` fires both events on success (`turn.ex:190/207`), so every successful call
counts **2×** in the swarm UI and `swarm_status` MCP output — while timeouts (`:exception`,
no `:stop`) count 1×, so the factor isn't even consistent. Fix: drop `track_tool` from the
`:stop` handler.

### 1.2 `[H]` Five LiveDashboard metrics can never fire (event-name mismatch) — ✅ Fixed
`lib/jido_claw/core/telemetry.ex:27,33,40,70,96` — `Telemetry.Metrics` derives the event
as all-but-the-last name segment (verified in `deps/telemetry_metrics`:561). So
`summary("jido_claw.session.duration")` listens on `[:jido_claw, :session]`, but the emit
is `[:jido_claw, :session, :stop]`. Same for `provider.request.duration`,
`tool.execute.duration`, `cron.job.duration`, and `last_value("jido_claw.tenant.count")`
(emit is `[:jido_claw, :tenant, :count]`). The counter siblings are correct — only these
five are dead charts. Fix: rename to `…stop.duration` / give `tenant.count` an explicit
`event_name:`. **Compounding:** the seven provider/tool emit helpers are themselves dead
(§2.8), so `provider.request.*` / `tool.execute.*` events are never emitted at all —
those dashboard rows are doubly dead. Impact is dev-only (`/live-dashboard` is dev-only).

> **Resolved:** an explicit `event_name:` was added to all five metrics. **3 of 5** tiles
> now fire (session, cron, tenant); the `provider.request.*` / `tool.execute.*` tiles stay
> empty because their emit helpers are dead (§2.8) — wiring or deleting those is a separate
> decision.

### 1.3 `[H]` `replay_workflow` reports a failed replay as a tool *error* — ✅ Fixed
`lib/jido_claw/tools/replay_workflow.ex:29,112` — the tool returns `status:
to_string(run.status)`, and the shared wrapper's `Error.normalize_result/1`
(`tools/error.ex:81-84`) promotes `{:ok, %{status: s}} when s in [:failed, "failed",
:error, "error"]` to an error envelope. A synchronously-failed module-reactor replay
(`orchestration/replay.ex:274` — only skills run async) therefore violates the tool's own
documented contract (lines 103-106: "a run that launched and then failed still reports
success-with-status") and buries `new_run_id`. The sibling read tools use `run_status`
for exactly this reason (`inspect_workflow.ex:42-46`). Fix: `status` → `run_status` in
`summarize/1` + `output_schema`.

### 1.4 `[H]` Release patch registries desynced — STDIO patch beam not relocated in prod — ✅ Fixed
`lib/mix/tasks/compile.jidoclaw_release_patches.ex:5-10` lists 4 patched dep beams;
`lib/jido_claw/core/dependency_patches.ex:4-10` registers **5** — the missing one is
`{Jido.MCP.Transport.STDIO, :jido_mcp}`, i.e. the MCP-subprocess env-scrubbing patch.
Under `MIX_ENV=prod` its patched beam is never relocated over the dep's, which is the
exact failure mode this compiler exists to prevent for the other four. Fix: add the
STDIO entry to `@patched_dependency_beams`.

> **Resolved via a DRY single-source refactor** (not the minimal one-tuple add):
> `DependencyPatches.patched_modules/0` is now the one patch inventory, and the compile
> task's new `patched_beams/0` reads it; the `mix.exs` `ignore_module_conflict` comment was
> corrected four→five. **Severity reframed:** the real impact is release *hygiene*, not a
> missing runtime patch — `DependencyPatches.ensure_loaded!/0` (`application.ex:31`) already
> force-loads the STDIO patch at boot in every env, so the env-scrub behavior held in prod
> regardless; the bug was that prod shipped two beams for the module.

### 1.5 `[H]` Consolidator reports `blocks_revised: 0` forever — ✅ Fixed
`lib/jido_claw/memory/consolidator/run_server.ex:781,836-895` — `apply_block_updates/1`
folds both `Block.write` and `Block.revise` outcomes into one accumulator reported as
`blocks_written`, and `blocks_revised:` is a hardcoded `0`. A run that revises N blocks
reports `written=N, revised=0` to the operator CLI (`cli/commands.ex:306`) and telemetry
(`run_server.ex:1181`). Fix: split the accumulator by which branch ran.

> **Resolved:** the accumulator is split by branch (`{:ok, :written | :revised, block}`).
> Intended semantic change — `blocks_written` now counts writes **only** (a revise of an
> existing active block increments `blocks_revised` instead of being conflated in).

### 1.6 `[H]` Boot banner hardcodes "6 agent types" — ✅ Fixed
`lib/jido_claw/cli/branding.ex:90` — sibling lines compute counts dynamically; this one is
a stale literal (16 templates exist). Fix: derive from `Agent.Templates`.

### 1.7 `[H]` `HostShell.exec/3` silently drops the caller's timeout — ✅ Fixed
`lib/jido_claw/forge/runner/host_shell.ex:69,87` — `exec(_, command, _opts)` hardcodes
`timeout: :infinity` while siblings `exec_argv/4` and `run/4` honor `opts[:timeout]`, and
the harness passes opts straight through (`harness.ex:515`). A Forge exec with a timeout
never times out on the HostShell backend. Fix: `Keyword.get(opts, :timeout, :infinity)`.

> **Resolved — bigger than the audit's one-liner:** besides honoring `opts[:timeout]`, a
> `{_partial, :timeout} -> {"timeout after …ms", 124}` case arm was added; without it a real
> timeout raises `CaseClauseError` (caught by the `rescue`) and is misreported as exit 1.

### 1.8 `[M]` Docker timeouts misclassified by the claude_code/codex runners — ✅ Fixed
`lib/jido_claw/forge/runners/claude_code.ex:86`, `codex.ex:128` — both match
`{_, :timeout}` → `harness_timeout`, but only HostShell returns that atom; the Docker
backend maps a timeout to `{"timeout after …ms", 124}` (`docker.ex:389-391`), which falls
through to the generic "cli failed" arm. Since these runners target the real Docker
sandbox, a timeout there is always misreported. Fix: also match exit 124 (and 153, the
output-limit status), or normalize in `Sandbox.run`.

> **Resolved via central normalization in `Sandbox.run/4`** (not per-runner 124-matching):
> only the exact `{"timeout after #{t}ms", 124}` tuple Docker manufactures for the timeout in
> play is rewritten to `{…, :timeout}`, so a genuine exit-124 command is never misread; the
> `exec` path (which ForgeBridge matches on the literal 124) and exit 153 are untouched.

### 1.9 `[H]` Forge session UI fields that can only ever be 0 / nil — ⏸ Deferred
`lib/jido_claw/forge/resources/session.ex:82,95,220` — `execution_count`'s only writer is
`set_attribute(:execution_count, 0)` in `:start` (and it's in `upsert_fields`, so a
re-upsert re-zeroes); `:mark_failed` (the only non-nil writer of `last_error`) has zero
callers — failures go through `Persistence.update_session_phase`. Both fields are
rendered (`forge_view.ex:126,130`, `forge_live.ex:38`) and always show `0` / `nil`.
Fix: increment on execution completion + route failures through `:mark_failed`, or drop
the attributes.

> **Deferred** from the batch (needs a product wire-vs-delete call + a DB migration). Full
> re-verified findings and both resolution paths are captured in
> `docs/reports/forge-session-fields-1.9-followup.md`.

### 1.10 `[M]` UTF-8-unsafe byte truncation in compaction persistence — ✅ Fixed
`lib/jido_claw/reasoning/compactor/snapshot.ex:157` and
`…/compactor/summarizer.ex:210` — both truncate with a raw
`<<head::binary-size(^limit), _rest::binary>>`, which can split a multibyte codepoint and
produce an invalid binary; `Snapshot.preview` byte-cuts at 200 on nearly every
compaction. Invalid UTF-8 then fails Jason/Postgrex encoding in `Storage.persist`,
silently dropping that (best-effort) compaction. The module already ships
`utf8_safe_prefix/2` (`compactor.ex:553`) — use it in both places.

> **Resolved:** the audit's "use it in both places" wasn't directly possible — that helper
> was **private** to `compactor.ex`. It was extracted into a new public module
> `JidoClaw.Reasoning.Compactor.Text` and all three call sites migrated (compactor,
> snapshot, summarizer), so no duplicate-clone / trivial-forwarder gate trips.

### 1.11 `[H]` LiveView load errors written to assigns that are never rendered — ✅ Fixed
- `lib/jido_claw/web/live/workflows_live.ex:33` (+ :116,172,180,488) — `runs_error` is
  assigned in six places and `@runs_error` appears in no template; a runs-load failure
  renders as the "No workflow runs yet" empty state.
- `lib/jido_claw/web/live/projects_live.ex:21` — same pattern for `projects_error`
  ("No projects yet").
Fix: render them like `@steps_error` (workflows_live.ex:301) — or drop the assigns.

> **Resolved:** both LiveViews now render an error row (mirroring `@steps_error`), gated
> above the empty-state row. Minor audit correction — `workflows_live` has **5** `runs_error`
> assign sites, not 6.

### 1.12 `[M]` JIDO.md generator emits self-contradictory template info — ✅ Fixed (2026-07-05 doc-sweep PR)
`lib/jido_claw/platform/jido_md.ex:105-108` vs `:146-147` — the per-template detail
section includes `verifier`, but the "Available template names:" summary lists only 6
names without it. Every freshly-generated JIDO.md disagrees with itself. Fix: align the
two lists (ideally derive both from `Agent.Templates`).
**Resolved:** the generator now derives the template detail blocks, the spawnable/
composer-internal name lines (split via `Templates.composer_private_template?/1`),
the built-in skills list, and a new line-anchored `## Tools (N total)` section from
`Agent.Templates` / `Skills.default_skill_entries/0` / `Agent.tool_modules/0` — with a
red→green regression test (`test/jido_claw/platform/jido_md_test.exs`) plus a
generate→check round-trip pinning that fresh output always passes the new
`mix jidoclaw.jido_md.check` guard.

### 1.13 `[M]` `Inspection.skills_summary/0` mislabels a field — ✅ Fixed
`lib/jido_claw/inspection.ex:363` — builds `version: Map.get(s, :max_iterations)`; the
Skill struct has no `:version`, so the iterative-loop cap is shipped under a wrong name
(local callers only — the MCP projection drops `skills`). Fix: rename the key.

### 1.14 `[M]` `rescue` that claims to catch an exit (inside dead code) — ⏭ Not fixed (dead code, §2.1)
`lib/jido_claw/github/agents/research_coordinator.ex:27-31` — documented to convert a
`Task.await_many` crash into `{:error, :research_failed}`, but a crashed task **exits**
the caller; `rescue` can't catch it (needs `catch :exit`). Only matters if the orphaned
GitHub pipeline (§2.1) is ever revived.

---

## 2. Dead code — subsystem-scale (decide: wire it or delete it)

These are coherent features that are built, in some cases supervised at boot, and
reachable from nothing. Each is a product decision, not a mechanical cleanup.

1. `[H]` **GitHub issue→PR agent pipeline** — `WebhookPipeline.route_event/3`
   (`github/webhook_pipeline.ex:39`) broadcasts `{:github_event, …}` on `"github:webhooks"`
   which has **zero subscribers**; `CoordinatorAgent.run/1` has zero callers, making
   `coordinator_agent.ex`, `triage_agent.ex`, `research_coordinator.ex`,
   `pull_request_coordinator.ex`, `patch_quality.ex` unreachable;
   `github/issue_comment_client.ex` (only function `post_comment/3`) has zero callers;
   the `IssueAnalysis` resource (`github/issue_analysis.ex`) is never written or read —
   its table is permanently empty (the `github.ex` moduledoc claims the agents persist to
   it; they return in-memory maps). Live triage is the separate `JidoClaw.Triage`.
   Note: if deleted, update the AGENTS.md `compile_check` allowlist narrative, which
   cites `PullRequestCoordinator.do_attempt/5`'s branches as live.
2. `[H]` **CodeServer** — the whole conversation API (`code_server.ex:15-65`,
   `code_server/runtime.ex`) has zero production callers; `application.ex:230,406-407`
   boot a `RuntimeRegistry` + `RuntimeSupervisor` nothing populates; runtime state fields
   are write-only; the `code_server:` PubSub topic is only self-subscribed.
3. `[H]` **Desktop** — `desktop/port_finder.ex` referenced by nothing;
   `desktop/sidecar.ex`'s `maybe_configure_endpoint/0` invoked by nothing at boot (only a
   doc mention in `gateway_exposure.ex:22` + its own test); Sidecar even reimplements
   PortFinder's logic inline. (Previously deferred as "L19" in
   docs/reports/code-review-2026-06-10.md — the deferral never made it to AGENTS.md.)
4. `[H]` **BackgroundProcess.Registry** (`platform/background_process/registry.ex`) —
   started at `application.ex:250`, zero callers; superseded by the Shell/SessionManager
   background path. (AGENTS.md's platform/ table row mentions BackgroundProcess — update
   if removed.)
5. `[M]` **JidoClaw.Messaging** (`platform/messaging.ex`) — a `use Jido.Messaging`
   runtime started at `application.ex:259`; only callers are its own canary tests; the
   Discord path calls `JidoClaw.chat` directly.
6. `[H]` **Tenant lifecycle** — `Tenant.Manager.suspend_tenant/resume_tenant/destroy_tenant`
   (`platform/tenant/manager.ex:43-56,156-180`, plus `InstanceSupervisor.stop_instance/1`
   and `Telemetry.emit_tenant_destroy/1`) have zero callers; `Tenants.Tenant.suspend/
   resume/archive` actions are test-only. Consequence: nothing in production can ever set
   a tenant non-active, which also makes `Cron.Owner`'s inactive-tenant prune branch
   unreachable. Also `[M]`: the per-tenant `tool_sup` Task.Supervisor
   (`instance_supervisor.ex:40,57-58`) is started and never used.
7. `[M]` **SecretRef** (`security/secret_ref.ex`) — resource + full code_interface with
   zero action callers and a `forbid_if(always())` policy; `voyage.ex:16` notes the real
   secret path bypasses it.
8. `[M]` **Observability stubs** —
   - `core/stats.ex`: `track_solution_stored/found`, `track_network_share` have zero
     callers and `track_tokens`/`track_agent_spawn` are test-only → **5 of 7 counters in
     `Stats.get/0` never move**, yet render in `repl.ex:926`, `heartbeat.ex:63`,
     `runtime_overview.ex:106`, `commands.ex:41/73`. Its `memory.*`/`skill.*` SignalBus
     subscriptions (`stats.ex:102-103`) have no producers, and `signal_bus.ex:14-16`
     documents those signals as "emitted when…" (they never are).
   - `core/telemetry.ex:146-199`: seven provider/tool emit helpers with zero callers
     (see §1.2).
   - `trace.ex:96` `agent_id_key/0` + attribute — documents a tool-context attribution
     mechanism that was never built (collector reads `metadata[:agent_id]`);
     `trace.ex:200` `events/2` zero callers; `history/1`, `list/2`, `spans/2` (+5 private
     helpers) test-only.
   - `trace/collector.ex:100`: 4 of 12 attached channels (`memory`, `subagent`, `mcp`,
     `schedule`) have no producer and `hook` is test-only — their label clauses and
     summary counters are unreachable/always-0. AGENTS.md's "the channel's first
     producer" framing suggests reserved taxonomy, so treat as *reserve or prune*, but
     fix the `trace.ex:6-8` moduledoc either way (it omits the live `composer` channel
     and lists five producer-less ones).
9. `[M]` **Network** — `node.ex:128-134,251-260` `request_solutions/2` + handler dead
   (the node can answer requests but never initiate); `relay_url` field write-only;
   `protocol.ex` `ping`/`pong` advertised in `@valid_types` but never produced/handled;
   `verify_message/2` superseded by `verify_and_normalize/3` (test-only).
10. `[M]` **Forge scaffolding** — `runners/custom.ex` unreachable (nothing sets
    `runner: :custom`; its fn-valued keys can't survive the jsonb spec round-trip);
    `runners/workflow.ex` (~140-line step engine) never instantiated;
    `forge/error.ex` (5 Splode structs + `classify/1`) unwired forward-scaffolding;
    `forge/context_builder.ex` + `Persistence.context_for_resume/get_events` cluster
    test-only; `forge/step_handler.ex` behaviour has zero implementors;
    `forge.ex` `cmd/4` + `shell_escape`, `run_loop/2` + `do_run_loop/4` (sole consumer of
    `Runner.blocked/1`) all dead; `Runner.handle_output/3` optional callback has no
    implementor; `sandbox.ex:19-22,44-47` facade wrappers `spawn/4`/`read_file/2` unused;
    `bootstrap.ex:5-19` `opts`/`on_step` never exercised;
    `persistence.record_session_started/2`, `forge_view.snapshot/2`,
    `manager.get_session/1` test-only.
11. `[M]` **Error toolkit surface** — `error/normalize.ex`: 5 of 6 domain entrypoints
    test-only (only `compaction_error/2` is wired); `normalize/common.ex:19`
    `passthrough_or_validation/4` zero callers; `error.ex` constructors `config_error/2`,
    `invalid_argument/3`, `timeout/3`, `missing_required/2` test-only. Related doc bug:
    `error.ex:28` + `normalize.ex:38` claim tool errors route through
    `Normalize.tool_error/2`; the live pipeline uses `JidoClaw.Tools.Error.normalize_result/1`.

### Dead Ash actions / code_interface defines (mechanical deletes)

- `orchestration/workflow_step.ex:135-168` (+ defines :44-48,53-54) — `create/start/
  complete/fail/skip` lifecycle actions dead (live path = `record_*` upserts); dead
  `:skip` also makes the `:skipped` status unreachable. `[H]`
- `orchestration/workflow_run.ex:198` `:by_project` + `list_by_project` define. `[M]`
- `conversations/resources/message.ex:125,250-255` `:by_tool_call`. `[H]`
- `workspaces/resources/workspace.ex` `:rename`, `:archive`, `:for_user`. `[M]`
- `cron/resources/job.ex:60,134-137` `:enable` (prod re-enable is via `:upsert`). `[M]`
- `audit/resources/event.ex:107-146` `:for_target`/`:for_actor` (test-only; forward API
  judgment call). `[M]`
- `forge/resources/session.ex:44-48,95,112` `:mark_failed`, `:cancel`, `:list_active`
  (see §1.9). `[H]`
- `solutions/resources/solution.ex` `:stats` (:85,192-197), `:with_deleted` (:89,212-214),
  `:transition_embedding_status` (:88,229-239 — backfill worker uses raw SQL; the
  same-named action on `Memory.Fact` IS live). `[H]/[M]`
- `solutions/resources/reputation.ex:61,100-104` `:top`. `[H]`
- `memory/resources/`: whole `fact_episode.ex` resource (unwired provenance scaffolding);
  `episode.ex:55-56` `for_consolidator`/`for_fact` + preparations; `link.ex:52,81`
  `for_fact`; `fact.ex:220` `:promote` + `MarkPromoted` (consolidator writes fresh rows —
  `promoted_at` never populated in prod); `fact.ex:246` `:invalidate_by_label`
  (`Memory.forget/2` uses `invalidate_by_id`, contra `memory.ex:30` doc). `[H]/[M]`
- `embeddings/resources/dispatch_window.ex:29,35` `read_window` (runtime uses raw SQL). `[M]`

### Dead functions / clauses / fields (mechanical deletes)

- `route_composer/gate_reactors.ex:43-49` `signal/1`. `[H]`
- `gates/irreversible_write_gate.ex` — test-only module; `SafetyGate` supplies the
  `:irreversible_write` kind. `[H]`
- `agent/identity.ex:109-124,186` `sign_solution/2` + `verify_solution/3` + `agent_id/1`
  — coherent signing feature never wired into solutions trust. `[M]`
- `persona.ex:16` + `priv/defaults/persona/user-advocate.md` — persona loaded but mapped
  to no stage/template; unreachable via `resolve/2`. `[M]`
- `agent_tracker.ex:261-262,475-477` — SignalBus subscriptions feeding a no-op
  `handle_info` (real accounting is telemetry; `core/stats.ex` consumes those topics). `[M]`
- `agent_view.ex:94,120,375` `streaming_message` field — always nil, never read. `[M]`
- `memory/consolidator/run_server.ex:63,436` `harness_task_pid` and `:70,437`
  `run_forge_home` — write-only state fields. `[H]`
- `embeddings/policy_resolver.ex:63` `model_for_storage/1` (write path hardcodes the
  model); `embeddings/voyage.ex:41,61` arity-1 wrappers. `[H]/[M]`
- `reasoning/strategy_registry.ex:112` `plugin_for/1`. `[M]`
- `reasoning/compactor/snapshot.ex:180-185` `atomize_strategy/1` binary clause —
  unreachable-arm no-op. `[M]`
- `security/redaction/ui_redaction.ex` — whole module, zero references. `[H]`
- `security/redaction/env.ex:112` `redact_env/1` test-only. `[M]`
- `security/shell_command/git.ex:60` `Invocation.subcommand` write-only field. `[H]`
- `security/cross_tenant_fk.ex:104` — `parent_domain` tuple element destructured, guarded,
  discarded at every call site. `[M]`
- `vfs/resolver.ex:501` unreachable fallback clause; `vfs/workspace.ex:288,312`
  `maybe_hint_github/2` no-op stub called for a side effect it doesn't have. `[M]`
- Shell: reload trio with no production caller — `profile_manager.ex:189` `reload/0`,
  `server_registry.ex:152` `reload/0`, `session_manager.ex:298`
  `invalidate_ssh_sessions/1` (no `/profile reload` command exists); `session_manager.ex:219`
  `cwd/1`; `session_manager.ex:471` `:DOWN` clause with no monitors to fire it. `[M]`
- CLI/Display/Web dead render paths: `cli/formatter.ex:27-73` (six functions —
  `Display` superseded), `cli/branding.ex:154,161,296,311` (`tool_*` + spinner frames),
  `cli/presenters.ex:40,59,133` (pre-`RuntimeOverview` clauses + `session_lines/1`),
  `display/swarm_box.ex:25,72,96` + `display/status_bar.ex:167` (pre-SwarmView map
  clauses + arity-2 `render_agents`), `setup/prerequisite_checker.ex:24`
  `all_required_met?/0`, `cli/setup.ex:236` ignored third param, `cli/repl.ex:302`
  unmatchable clause, `cli/commands.ex:1069` unreachable catch-all,
  `web.ex:11` `static_paths/0` (endpoint hardcodes the same list — drift risk) and
  `:14,24,53,62` unused `__using__` clauses, `web/live/approvals_live.ex:161-162`
  unreachable `approve`/`reject` handlers (UI submits `decide`),
  `web/live/sign_in_live.ex:10` dead `password` assign. `[H]/[M]`
- `core/config.ex:46-56,167-169` `strategy_descriptions/0` + map. `[H]`
- `core/cluster.ex:19-51,86-96` `node_count/connected?/node_info/groups/local_members`. `[M]`
- `solutions/fingerprint.ex:11-20,192,215` — 6 of 8 struct fields + `match_score/2` +
  `jaccard/2` test-only (superseded by SQL RRF); `network_facade.ex:44`
  `:embedding_model` isn't a Solution attribute. `[M]`
- `mix/tasks/jidoclaw.migrate.cron.ex:166-168,171` — four unreachable `parse_mode/1`
  clauses. `[H]`
- `platform/cron/worker.ex:104-108,142-146` `disable/2` cast + handler;
  `:110-114` `get_state/2` wrapper (test seam); `platform/cron/scheduler.ex:17-46`
  `load_persistent_jobs/2` superseded by the WS4a Owner reconcile. `[H]/[M]`
- `orchestration/gate/dsl.ex:93-96` gate DSL `workflow` field never set (+ unused
  `gate_workflow/1` accessor); `workflow_view.ex:106-108` `active_statuses/0`;
  `orchestration/replay/diagnostics.ex:155-157` `statuses/0`. `[M]`
- `jido_claw.ex:244-248` — actor fallback in `run_chat_turn` duplicates `chat/4`'s
  resolution; `chat/4` always injects `:actor` into opts (:113) before the only call
  site, so the fallback can't fire. `[M]`
- Config/deps: `config/dev.exs:14` `dev_routes: true` read by nothing; mix.exs deps
  `jido_composer`, `ash_paper_trail`, `ash_state_machine` have zero code references and
  no transitive requirer. `[M]`
- Tests: `test/support/jido_claw/trace_test_helpers.ex:22,36` `emit_request_start/1` +
  `emit_tool_complete/1` zero callers. `[H]`

---

## 3. Doc drift — in-repo documentation

> **Status — updated 2026-07-05.** Everything below is fixed in the 2026-07-05
> doc-truth-sweep PR (one PR: §3 + §3b + the JIDO.md cluster + §1.12 + the §4 drift-guard
> deferral). Current-state claims corrected; versioned release notes / completed-milestone
> text kept historical (annotated only where confusion was likely). `.jido/JIDO.md` stays
> committed, refreshed, and is now guarded by `mix jidoclaw.jido_md.check` in precommit
> (version + name-set comparisons for tools/templates/skills + machine-path and
> entry-point checks). Per-entry ✅ markers inline.

Top-level docs have rotted hard while AGENTS.md stayed current. Recurring axis: tool
count (27 vs actual 35), template count (6/7 vs 16), retired v0.4/v0.5 designs still
documented as current.

**README.md** `[H]` ✅ Fixed: "27 tools" at 9+ sites → 35; tools table omits `fetch_output,
forget, run_pipeline, verify_certificate, handoff, lua_query, lua_docs, search_web`;
browser tool is `browse_web` not `browse`; `:827` documents a `tool_approval_mode:
:on_miss` config that doesn't exist (real: `:tool_approval` with
`enabled?`/`require`/`mcp_require_approval`); "7 types" → 16 templates; sandbox
behaviour "7 callbacks" → 8 required (omits `exec_argv/4`); `Core.MCP` → `MCPServer`;
"9 regex patterns" → 10 (and the enumerated private-keys pattern doesn't exist);
"8 skills" → 10 (`sfr_review`, `verified_feature` undocumented); `JIDOCLAW_MODE` (also
`.env.example:35`) is read by no code.

**docs/ARCHITECTURE.md** `[H]` ✅ Fixed: root supervisor is `:one_for_one`, not `rest_for_one`
(:36,721); "27 tools" → 35; Solutions.Store/Reputation described as ETS+JSON GenServers —
retired v0.6.1, Postgres now (:71-72,457-474); Memory described as supervised ETS+JSON —
now an Ash domain with no process (:73,690,732); `Orchestration.ApprovalGate` resource
doesn't exist — approvals are `AgentCase` kind `:tool_call` (:113,228-231); strategy
default is `"auto"`, not `"react"` (:531); `JidoClaw.Repl/Commands` → `CLI.*`
(:338,340,736); `Jido.MCP.Server` → `JidoClaw.MCPServer` (:88); lists dead `StepHandler`
and mis-groups `ContextBuilder` (:191-192).

**CONTRIBUTING.md** `[H]` ✅ Fixed: "27 tools" → 35; "6 built-in templates" → 16; the whole
Extension Points walkthrough (:145-227) cites pre-refactor paths (`lib/jido_claw/agent.ex`,
`agents/`, `templates.ex`, `commands.ex`, `branding.ex`, `config.ex`, `setup.ex`,
`skills.ex`, `jido_md.ex` — all moved into subsystem dirs); Key Modules table uses moved
bare namespaces; channel behaviour path missing `platform/`.

**docs/SETUP.md** `[H]` ✅ Fixed: `./jido` → the escript is `jidoclaw` (:60-61,193);
`JIDOCLAW_MODE=both|gateway` is a dead knob — nothing reads it (:199,213); LiveDashboard
is at `/live-dashboard`, dev-only — `/dashboard` is the app's own dashboard (:206).

**docs/ROADMAP.md** `[H]` ✅ Fixed: v0.6 memory/solutions DB migration marked "Planned" — Phases
1-3 shipped; "Current State: 27 tools / 6 domains" → 35 / 16; the
file-to-database-migration table (:400-410) lists shipped work as future; the
`persistence: backend: ecto|file` fallback (:359-368) never shipped (design went
Postgres-required). **docs/BACKLOG.md** `[M]` ✅ Fixed: SearchCode "local filesystem only" — it
routes through `VFS.Resolver` (github/s3/git) already.

**docs/PLAN-docker-sandbox-onecli.md** `[H]` ✅ Fixed: the `SpriteClient` design shipped as
`Forge.Sandbox.*` (renamed; 10 callbacks; Docker backend; OneCLI wired) — mark Parts 1-2
done. **docs/PLAN-v0.6-memory.md** `[M]` ✅ Fixed: runbook commands use `mix jido_claw.export.*`
/ `migrate.*` — shipped tasks are `jidoclaw.*`; the documented commands fail.

**.jido/JIDO.md** (committed; read by the agent at boot; regenerated only when absent)
`[H]` ✅ Fixed (refreshed; now guarded by `mix jidoclaw.jido_md.check` — note `Stats` turned
out to exist and stay supervised, so it was kept): "33 tools" → 35 (omits
`lua_query`/`lua_docs`); supervision tree lists retired
`Solutions.Store`/`Reputation` and nonexistent `Stats`/`Tool.Approval` (:44-63); stale
entry-point paths (:17-18,298); "Version: 0.3.0" vs 0.6.4, plus a foreign machine path
(:12). Related improvement: unlike `system_prompt.md` (check task + sync marker +
precommit wiring), JIDO.md has **no drift guard** — `JidoMd.ensure/1` writes only when
absent, so the committed snapshot rots by design. Add a `jidoclaw.jido_md.check` or stop
committing it.

**AGENTS.md** `[M]` ✅ Fixed: only real nit — `:92` cites `ToolApproval.requirement/3`; it's a
private `requirement/4`. ("All 32+ tool modules" in the dir table is a true-but-stale
floor; 45 exist.) If §2 deletions happen, also update the BackgroundProcess table row and
the PullRequestCoordinator compile_check narrative.

## 3b. Doc drift — moduledocs/comments citing things that don't exist

> **Status — updated 2026-07-05.** All items below are fixed in the 2026-07-05
> doc-truth-sweep PR (✅ per entry). Comment-only except `tools/get_agent_result.ex`
> (the two phantom `output_schema` fields were deleted — no test changes needed) and
> the vestigial `{:error, :no_recommendation}` spec arm in `classifier.ex` (nothing
> matched it). `policy_resolver.ex` was reworded to the nuanced truth (the write path
> gates on `resolve/1` but hardcodes its stored model) — `model_for_storage/1`
> wire-or-delete remains a §2 decision.

- `workers/output_schema.ex:107`, `sketch_reviewer.ex:13`, `system_verifier.ex:7` — cite
  `DefaultMapper.reviewer_verdict/3`; the real function is private `verdict/2`. `[H]` ✅
- `security/redaction/embedding.ex:9-10` — cites `Embeddings.Local.embed_for_*`; no
  `Local` module exists. `[H]` ✅
- `security/redaction/memory.ex:30` — cites `Conversations.Redaction.Transcript`; real
  module is `Security.Redaction.Transcript`. `[H]` ✅
- `reasoning/yaml_store.ex:42` — cites `PipelineRegistry`; real module is `PipelineStore`. `[H]` ✅
- `error.ex:28` + `error/normalize.ex:38` — claim the tool path uses
  `Normalize.tool_error/2`; it uses `Tools.Error.normalize_result/1`. `[H]` ✅
- `agent/defaults.ex:7-9` — "seven specialized workers" + stale list → 16. `[H]` ✅
- `reasoning/compactor.ex:48-51` + `compactor/config.ex:7,97` — "all seven workers" →
  15 + main. `[H]` ✅
- `doctrine.ex:133` — "10 NON-reviewer templates" → 13. `[H]` ✅
- `agent_tracker.ex:25` — "Two invariants" followed by three. `[H]` ✅
- `tool_context.ex:108` — "seven canonical keys" → 14. `[H]` ✅
- `memory.ex:30` — `forget/2` "wraps invalidate_by_label" → uses `invalidate_by_id`;
  `memory.ex:23` + `fact.ex:8` — `Retrieval.search/2` → `search/1`; `memory.ex:143-154`
  — `list_recent/2` "used by the legacy prompt builder" → only the `/memory` CLI. `[H]/[M]` ✅
- `memory/retrieval.ex:11-14` — describes an Episode search tier that doesn't exist. `[H]` ✅
- `memory/resources/block_revision.ex:8-10` — cites a `Block.:revise` action; it's a
  plain function + `:invalidate` hook. `[M]` ✅
- `embeddings/backfill_worker.ex:11` — "default 30 in dev, 300 in prod" — always 30s,
  no prod override exists; `rate_pacer.ex:39,386` — names a `:rate_limits` config key
  that doesn't exist (real: `:rpm`/`:tpm`); `policy_resolver.ex:7-11` — claims the write
  path consults it (it hardcodes). `[H]/[M]` ✅
- `reasoning/resources/outcome.ex:10-16` — "reserved … without a runtime producer" — all
  four execution kinds now have live producers; `classifier.ex:141` — spec lists
  `:no_recommendation`, never returned; `compactor.ex:785` — "REPL command, scheduled
  job" callers don't exist. `[M]` ✅
- `orchestration/workflow_event.ex:121-123` — frames Phase-4/AR-4 producers as future;
  all shipped. `[M]` ✅
- `conversations/request_correlation/cache.ex:14-20` — claims `lookup` goes through
  `GenServer.call`; it's a direct client-side `:ets.lookup`. `[M]` ✅
- `platform/session/worker.ex:10-12` — cites `append!/1`; the write is `append/2`. `[M]` ✅
- `tools/recall.ex:33` — param doc describes the removed substring scanner. `[M]` ✅
- `tools/get_agent_result.ex:17-18` — output_schema `message`/`error` fields no success
  path produces (superseded soft-fail design). `[H]` ✅
- `vfs/resolver.ex:8` — `git://repo-path/file` example needs the double-slash form. `[M]` ✅
- `security/tool_approval.ex:239` — `native_requirement/3` → `/4`. `[M]` ✅
- `solutions/search_escape.ex:16` — `$12` → `$11`; `solutions/trust.ex:54-60` — doc table
  omits the live `semi_formal → confidence * 0.85` case. `[M]` ✅
- `mcp/consumer.ex:77-81` — cites a ProxyGenerator moduledoc note that isn't there. `[M]` ✅
- `mix/tasks/jidoclaw.export.conversations.ex:36-37` — manifest also includes `:system`
  rows. `[M]` ✅
- `web/gateway_exposure.ex:22` — holds up the never-invoked Sidecar as the pattern
  exemplar. `[M]` ✅
- `cli/commands.ex:903` — breadcrumb points at `repl.ex:506` (now unrelated code). `[M]` ✅
- `test/support/jido_claw/route_composer/composer_stubs.ex:144` — cites
  `agent_runner.ex:179`; the referenced code is at `:342`. `[H]` ✅
- `core/signal_bus.ex:14-16` — documents `memory.saved`/`skill.started`/`skill.completed`
  signals that nothing emits. `[M]` ✅

---

## 4. Easy improvements

> **Status — updated 2026-07-05.** Everything below except three deliberate deferrals is
> implemented in a single migration-free batch PR (plan:
> `.claude/plans/please-read-docs-reports-codebase-audit-serene-hoare.md`); per-entry
> `✅ Done` / `⏭` markers inline. Deferred: the two test-suite dedups (`eventually` +
> `kinds/2` — a 30+-file test-only churn, split into its own follow-up PR) and the
> `~w(talk sketch code system)` pair (port-fidelity skip). The JIDO.md drift guard
> shipped with the §3 doc-sweep PR. Wherever removed code could be mistaken for load-bearing,
> a new test pins the contract (canonical encode determinism, redaction-key subsumption,
> `primary_fk_or_nil/1` nil-totality, cold-snapshot cap/count, stdio scrub exit status,
> help entries). Two shared modules were introduced: `JidoClaw.Tools.Projection` and
> `JidoClaw.Forge.Runners.FileSync`.

**Duplication:**
- `eventually`-style polling helper hand-rolled in **15 test files** — extract one
  `test/support` helper. `[H]` ⏭ **Deferred** to a follow-up test-support dedup PR
  (plan-time census: **19** files, not 15).
- `defp kinds/2` duplicated in 13 composer/orchestration test files while
  `LeaseHelpers.kinds/2` exists (one file imports LeaseHelpers and still redefines it). `[M]`
  ⏭ **Deferred** to the same follow-up PR.
- `forge/harness.ex:255,863,1129` — the provision block triplicated verbatim. `[M]`
  ✅ **Done** — extracted as `create_default_sandbox/1`, which ends right after `new_state`
  is built so the three callers keep their divergent log/record/dispatch tails
  (`recover_provision/1` deliberately never logs `sandbox.provisioned`).
- `runners/claude_code.ex:183` / `codex.ex:312` — byte-identical `sync_file/3` (both
  already carry ex_dna pragmas). `[M]` ✅ **Done** — single-sourced as
  `JidoClaw.Forge.Runners.FileSync.sync_file/5` (auth-file + log label parameterized);
  both ex_dna pragmas deleted with the copies.
- `vfs/sandbox.ex:202-207` `under?/2` duplicates `Resolver.under_path?/2` — a
  containment check worth single-sourcing. `[M]` ✅ **Done** — `Resolver.under_path?/2`
  promoted public (`@spec` + doc, the `realpath/1` precedent); Sandbox calls it and its
  mirror is deleted.
- `route_composer/router.ex:37` + `catalog_validator.ex:60` — `~w(talk sketch code
  system)` duplicated (desync risk; port-fidelity caveat noted). `[M]` ⏭ **Skipped
  deliberately** — the two files are 1:1 ports of *separate* Alp River upstream files
  (`route.py`, `check_catalog.py`); single-sourcing would couple the ports. Stays as
  documented duplication unless port-fidelity stops binding.
- `platform/tenant.ex:33-35` / `tenants/resources/tenant.ex:152-154` — `generate_id/0`
  byte-identical twice. `[M]` ✅ **Done** — `JidoClaw.Tenant.generate_id/0` made public;
  the Ash resource's attribute default points at it and the resource-local copy is deleted.
- `cli/commands.ex:993,1494` — `primary_fk/1` duplicates `Memory.Scope.primary_fk/1`
  (already aliased + called in the same file), plus a third near-copy. `[M]` ✅ **Done** —
  both commands.ex locals deleted; the nil-tolerant third copy became
  `Memory.Scope.primary_fk_or_nil/1` at the canonical source, with explicit clauses (a
  guard-on-kind delegate would still raise on a partial map, since `primary_fk/1`'s heads
  also match the FK field) + nil-totality tests.
- `stringify_nilable/1` copy-pasted in three MCP projection tools, each with a "Mirror"
  comment (`inspect_agent.ex:136`, `inspect_workflow.ex:114`, `workflow_events.ex:102`). `[M]`
  ✅ **Done** — single-sourced in the new `JidoClaw.Tools.Projection`; all three copies +
  "Mirror" comment chains deleted.
- `shell/profile_manager.ex:551,502` / `server_registry.ex:466,315` — env coercion and
  `config_path/1` duplicated; both alias `ShellUtil` already. `[M]` ✅ **Done** — both
  promoted to `Shell.Util` (`config_path/1`; `coerce_env_entry/4` takes a caller context
  label with unified lowercase log wording — the two pinned profile-manager log assertions
  updated to match).

**Wasted work / no-ops:**
- `agent_view.ex:348-349` — identical `for_session_primary` query runs twice per cold
  snapshot (list + count). `[M]` ✅ **Done** — a `messages_and_count/3` dispatcher keeps
  warm/mixed paths byte-identical and runs the cold read once; the count stays the PRE-cap
  filtered total (new cold-path test: 60 seeded messages → 50 rendered, `message_count` 60).
- `shell/session_manager.ex:781` — SSH secrets resolved twice per session build. `[M]`
  ✅ **Done** — the discarded-result `resolve_server_secrets` gate deleted
  (`ServerRegistry.build_ssh_config/3` re-resolves internally and returns the same
  `{:error, {:missing_env, _}}`), along with the then-dead private wrapper.
- `export/canonical.ex:43` — sort immediately discarded by `Map.new/1` (re-sorted at
  encode). `[M]` ✅ **Done** — plus a pinning test for what the sort could be mistaken for
  providing (atom/string-key equivalence, byte-identical output across input key orderings).
- `embeddings/rate_pacer.ex:365` — both `if` branches identical; `reasoning/auto_select.ex:173`
  — identity `Enum.map`; `reasoning/telemetry.ex:289` — `Map.merge(%{}, m)` no-op;
  `forge/manager.ex:221,225` — `event_scope` computed twice. `[M]` ✅ **All four done.**
- `forge/sandbox/docker.ex:575` — `resolve_agent_token/2` ignores `_sandbox_id`
  (name implies per-sandbox selection). `[M]` ✅ **Done** — the dead `sandbox_id` thread
  removed end-to-end (`resolve_agent_token/1`, `onecli_env/0`, `inject_onecli_env/2`);
  the public test-facing `maybe_inject_onecli_env/4` keeps its arity with the param
  underscored.
- `security/redaction/memory.ex:22-23` — `auth_token`/`credentials` subsumed by
  `token`/`credential` under contains-matching. `[low]` ✅ **Done** — removed; a new
  `security/redaction/memory_test.exs` pins the subsumption (`auth_token`/`credentials`/
  `token` all still redact) so a future removal of the short forms can't silently
  un-redact the long ones.

**Test hygiene:**
- `test/jido_claw/mcp/stdio_env_scrub_test.exs:44` — printenv-absent branch is a bare
  `assert true` (test passes asserting nothing on hosts without printenv). `[M]`
  ✅ **Done** — rewritten to spawn POSIX-guaranteed `/bin/sh -c env` (no `find_executable`
  fallback that can silently pass); the port collector now also returns the exit status,
  asserted `== 0`.

**Process:**
- Add a JIDO.md drift guard (see §3) — the only generated-doc surface without one.
  ✅ **Done** (2026-07-05 doc-sweep PR) — `mix jidoclaw.jido_md.check` wired into
  `precommit` after `system_prompt.check`: validates version + tool/template/skill
  **name sets** (not just counts), the spawnable summary line, no machine-absolute
  paths, and live entry-point paths (`JidoClaw.JidoMd.Check.problems/2`).
- CLI help: `/gates`, `/profile`, `/workspace` are routed but absent from
  `Branding.help_text/0` (missing rather than wrong — noted for completeness).
  ✅ **Done** — one entry each (`/gates` → Platform, `/profile` → Servers, `/workspace` →
  Memory), width-matched to section neighbors; `/exit`/`/config` stay omitted as pure
  aliases of `/quit`/`/setup`. A new branding test pins presence + ANSI-stripped width
  parity with a sibling line per section (the box is pre-existingly ragged — full
  realignment to one interior width is a separate cosmetic follow-up).

---

## Suggested triage order

1. **Small verified bug fixes** (§1.1-1.13): ✅ **done** — 1.1–1.8, 1.10, 1.11, 1.13 are
   implemented in the 2026-07-04 batch bugfix PR (each with a regression test). Remaining:
   **1.9** deferred (product call + DB migration; see
   `docs/reports/forge-session-fields-1.9-followup.md`), **1.12** folded into the step-2 doc
   sweep, **1.14** left as dead code (§2.1).
2. **Doc sweep** (§3): ✅ **done** — the 2026-07-05 doc-truth-sweep PR fixes §3 + §3b +
   the JIDO.md cluster (incl. §1.12 and the §4 drift-guard deferral): README/
   ARCHITECTURE/CONTRIBUTING/SETUP/ROADMAP/BACKLOG/PLAN docs corrected, the committed
   `.jido/JIDO.md` refreshed and guarded by the new `mix jidoclaw.jido_md.check` in
   precommit, and all §3b moduledoc one-liners fixed.
3. **Subsystem decisions** (§2.1-2.11): wire-or-delete calls only the owner can make —
   GitHub pipeline, CodeServer, desktop, Messaging, BackgroundProcess.Registry, tenant
   lifecycle, SecretRef, network initiation, forge scaffolding, error toolkit.
4. **Mechanical dead-code deletes** (§2 lists): safe once (3) is decided; delete
   test-only Ash actions with their tests.
5. **Improvements** (§4): ✅ **done** — the 2026-07-05 §4 batch PR implements everything
   except the deferred test-suite dedups (`eventually`/`kinds/2` — own follow-up PR) and
   the port-fidelity-skipped `~w(talk sketch code system)` pair; the JIDO.md drift guard
   shipped with step 2's doc-sweep PR.
