# Features Worth Borrowing from the symphony lineage (symphony + OpenSymphony)

Exploration notes — not a plan, not a commitment. Joint inventory **2026-07-04** — the
pms corpus's "one joint targeted read, not two digs"
([DIG-BRIEFS.md](../DIG-BRIEFS.md)): OpenAI's **symphony**
(`~/workspace/research/pms/symphony` — "engineering preview" spec-first autonomous
daemon: polls Linear, one Codex session per issue until PR/handoff) and its community
fork **OpenSymphony** (`~/workspace/research/pms/OpenSymphony`, Swiftyos — generalized
to Codex/Claude Code/OpenCode with label routing, multi-project, multi-account
rotation, an observability stack). Pinned: symphony @ `4cbe3a9` (2026-06-09),
OpenSymphony @ `8d101a0` (2026-04-26) — both refreshed before the dig, zero drift from
the scan pins — jido_radclaw @ `a9629f01`. Cites are firsthand reads of all three
trees, accurate to within a few lines; paths below are
`elixir/lib/symphony_elixir/`-relative unless noted. Nothing was built or executed
this review.

Shape: upstream ~10.0k LOC of lib Elixir + a 2,185-line language-agnostic `SPEC.md`
(the README invites reimplementing from it); fork ~21.6k LOC + its own 2,274-line
SPEC + an `observability/` docker-compose stack (VictoriaMetrics/Logs/Traces, Vector,
Grafana). Both Elixir 1.19.5/OTP 28 via mise, escript CLI + optional minimal Phoenix
(Bandit) dashboard, both `version: 0.1.0`, no tags. Maturity: upstream 23 commits on
main (OpenAI staff + Codex co-authors; both CLIs require an
`--i-understand-that-this-will-be-running-without-the-usual-guardrails` flag —
self-labeled "low-key engineering preview"); fork diverged at `9e89dd9` — upstream
+13 commits since, fork +33, both sides evolved (the scan's "sideways, not behind"
confirmed). Upstream dogfoods symphony on symphony: the `docs/` smoke notes on main
are agent proof-of-work artifacts, and unmerged branches
(`origin/codex/sd-10-claim-leases`, `sd-11-jira-claim-leases`) show where it is
heading — a Jira tracker adapter with **persisted claim leases** ("restarts do not
duplicate active workers"), converging on our WS1 lease design. License: Apache-2.0,
NOTICE "Copyright 2025 OpenAI" (the fork retains it) — **the only same-language,
clean-license subjects in the pms corpus**, so "borrow" here can mean lifting Elixir
nearly verbatim (the osa precedent).

Companion docs: [../README.md](../README.md) (the pms scan this corrects),
[../DIG-BRIEFS.md](../DIG-BRIEFS.md) (the standing questions answered below),
[../../argus/OVERVIEW.md](../../argus/OVERVIEW.md) +
[../../argus/FLOW.md](../../argus/FLOW.md) (the seam map every entry lands on),
[../multica/FEATURES-WORTH-BORROWING.md](../multica/FEATURES-WORTH-BORROWING.md)
(MC1-1's CLI resume stack — the driver entries here compose with it, and the two
subjects ship **different** resume models worth contrasting),
[../../hermes/FEATURES-WORTH-BORROWING.md](../../hermes/FEATURES-WORTH-BORROWING.md)
(T2-13, the prior Codex app-server candidate SY1-1 supersedes),
[../../camus/FEATURES-WORTH-BORROWING.md](../../camus/FEATURES-WORTH-BORROWING.md)
(C1-1 executor seam), and the ades set
([traycer](../../ades/traycer/FEATURES-WORTH-BORROWING.md) /
[emdash](../../ades/emdash/FEATURES-WORTH-BORROWING.md) worktree cribs,
[Xantham](../../ades/Xantham-system-blueprint/FEATURES-WORTH-BORROWING.md) XA2-3 —
whose credential canary SY1-4's probe is the shipped sibling of). Threat-model
weighting as always: personal tailnet — LLM-misbehavior containment and leakage
hygiene over external-attacker hardening.

**Structure note**: one doc for two repos — the umbrella brief prescribed a joint
read, and the fork is unintelligible without the upstream baseline (half the findings
are fork *deltas*, including two capability regressions). A **dig-brief
dispositions** section follows the tiers (the multica precedent), and scan
corrections are folded there plus pushed into [../README.md](../README.md).

## Determination (TL;DR)

**The philosophical inverse of argus, carrying the corpus's most directly liftable
code.** As a system: unattended-by-design, zero gates, zero auth, nothing durable
(in-memory scheduler state; a restart re-dispatches everything and orphans remote
processes), and the daemon **never writes the board** — every Linear state move,
comment, and PR link is performed by the coding agent itself through an injected
`linear_graphql` tool. That is the sharpest available contrast for the three things
argus is building differently (durable gates, platform-detected attention,
event-sourced state), and this read hardened all three. As parts: our language +
Apache-2.0 makes four pieces unusually cheap to take — the **Codex app-server
JSON-RPC client** (the second-executor reference FLOW §4 needs, superseding hermes
T2-13's from-Python translation), the **orchestrator dispatch-hygiene bundle**
(reconcile-before-dispatch-every-tick against external truth, dispatch-time
revalidation, the backoff/stall/caps discipline our cron and landing slices lack),
the **validated-config-contract stack** (DB-less Ecto embedded schemas, fail-closed
boot, last-known-good hot reload, render-fails-on-unknown-variable — the FLOW §9
validation answer; every YAML store we own is warn-and-skip), and the fork's
**multi-account rotation + scheduled rate-limit probe** (the CLI-credential-health
design for argus's CLI engine, and the shipped form of the XA2-3 canary).

| Part of the lineage | As a dependency | What to take |
| --- | --- | --- |
| Upstream daemon (orchestrator + workspace) | No — unattended philosophy, in-memory state, no gates | SY1-2 dispatch hygiene; SY2-2 blocked-input taxonomy; SY2-4 teardown PR sweep; the config-set status semantics as FLOW §7 evidence |
| Codex app-server client + `token_accounting.md` | No, but module-liftable (our language, Apache-2.0) | SY1-1 — protocol machinery near-verbatim at the CLI-engine slice; the token doctrine as contract |
| WORKFLOW.md / `symphony.yml` config stack | No | SY1-3 — the validated-contract pattern (fail-closed boot, last-known-good reload, strict Liquid, allowlisted per-repo overlay) |
| Fork multi-backend drivers (Claude/OpenCode) | No | Driver deltas fold into multica MC1-1's stack; SY2-3 single-source multi-CLI tool generation |
| Fork accounts + rate-limit probe + Prometheus | No | SY1-4 — store layout, six-state health, skip-reasons + `next_available_at`, the probe-as-canary |
| Fork worktree plumbing (`workspace.ex`) | No | SY2-1 — the only same-language git-worktree reference in the corpus (with the bare-repo scan correction) |
| SPEC.md spec-first discipline | No | Contrast only — our doctrine docs + `:coherence` evals are already CI-enforced; theirs is prose policy (and the fork's spec drifted badly) |

## Why not adopt as a dependency

1. **Inverse philosophy.** `approval_policy: never` in the shipped workflow, "Never
   ask a human to perform follow-up actions" in the shipped prompt
   (upstream `elixir/WORKFLOW.md:34,68`), approvals machine-answered or
   turn-failing, no gate objects anywhere. Running this beside JidoClaw would mean
   operating an agent fleet outside the gate family argus exists to extend.
2. **Nothing durable.** No DB by design; `running`/`claimed`/`blocked`/retry state
   is GenServer memory (SPEC §14.3 "resume useful operation by polling tracker
   state"); a restart re-dispatches active issues fresh and **orphans running remote
   processes** (no reattach, no orphan detection). We are event-sourced with leases
   precisely to avoid this class.
3. **Prototype posture, self-declared.** Guardrails-ack CLI flag, auth-none web
   surface (loopback-bind is the only protection), `0.1.0`, "not a supported
   product" banner (`cli.ex:105-144`).
4. **The board is Linear**; argus decided native tasks (FLOW §7). The tracker
   behaviour is two-implementation (Linear + an in-memory test double) with writes
   defined but dead — even upstream flags "first-class tracker write APIs" as an
   unbuilt TODO (SPEC.md:2114).

What survives all four objections is module-level lifting: this is the first pms
subject where the borrow verbs include "copy the Elixir file and rename the module."

## How to read this document

Recommendation vocabulary per `docs/exploration/README.md`: **BORROW-PATTERN**,
**BORROW-REFERENCE**, **BORROW-RUBRIC**, **ALREADY-COVERED**, **TRACK**, **SKIP**.
Initial inventory — no Status lines. Tiers scoped to this codebase: **Tier 1** =
clear gap, high leverage, buildable against a shipped seam or a decided argus slice;
**Tier 2** = valuable, lands with a specific slice or needs a small design decision;
**Tier 3** = garnish. IDs `SY<tier>-<seq>`; `S-n` skips; `OQ-n` open questions.
Entries cite upstream as `up` and the fork as `fk` where they diverge. Every Gap
claim verified against jido_radclaw @ `a9629f01` on 2026-07-04.

---

## Tier 1 — High Impact

### SY1-1. Codex app-server JSON-RPC client — the second-executor reference, in our language

**Recommendation**: BORROW-REFERENCE, with module-level lifting on the table
(Apache-2.0, Elixir). Supersedes hermes T2-13 as the working spec — same protocol,
no translation step. Trigger-bound: argus FLOW slice 6 (`:cli` engine) or the
composer's Forge-executor stage (camus C1-1), whichever fires first.

**Where in symphony**: `codex/app_server.ex` (up 1,098 / fk 1,298 lines). Spawn:
`Port.open({:spawn_executable, bash}, [:binary, :exit_status, :stderr_to_stdout,
args: ["-lc", command], cd: workspace, line: 1_048_576])` (up `189-223`); remote =
the same command over `ssh -T <dest> bash -lc '<cd && exec …>'` (up `212-223`).
Wire: **newline-delimited JSON-RPC** (not LSP framing), fixed request ids
`@initialize_id 1` / `@thread_start_id 2` / `@turn_start_id 3` (up `9-11`);
`initialize` (capabilities `experimentalApi: true`, then an `initialized`
notification, up `241-263`) → `thread/start` (carries `approvalPolicy`, `sandbox`
default `"workspace-write"`, `cwd`, `dynamicTools`, up `280-302`) → `turn/start`
(input items, `sandboxPolicy`, up `304-327`); `session_id` is the synthetic
`"<thread_id>-<turn_id>"` (up `93`). Turn loop (up `329-439`): `turn/completed` is
done, `turn/failed`/`turn/cancelled` are typed errors, everything else dispatches to
approval/tool/notification handlers; undecodable lines are logged and skipped.
Timeouts: per-response `read_timeout_ms` 5s, whole-turn `turn_timeout_ms` 1h
(schema up `180-181`). Approvals: `auto_approve_requests` only when
`approval_policy == "never"` (up `54`) — then `execCommandApproval`/
`applyPatchApproval`/`item/*/requestApproval` reply `"approved_for_session"` /
`"acceptForSession"` (up `526-647`), and `item/tool/requestUserInput` is
auto-answered with approval-style option labels or the constant *"This is a
non-interactive session. Operator input is unavailable."* (up `14`, `835-920`).
Under the **default** policy — a reject-map
`%{"reject" => %{"sandbox_approval" => true, "rules" => true, "mcp_elicitations" =>
true}}` (schema up `168-176`) — any approval that still reaches the client fails
the turn `{:error, {:approval_required | :turn_input_required, payload}}`; upstream
additionally hard-blocks `mcpServer/elicitation/request` (up `1062`). Dynamic
tools: registered in `thread/start`, dispatched on `item/tool/call` via an
injectable `tool_executor`, reply `{"id": id, "result": %{"success", "output",
"contentItems"}}` (up `548-708`). Companion doctrine:
`elixir/docs/token_accounting.md` (304 lines, identical in both repos) — derived
from codex-rs source: **absolute totals over deltas** (`tokenUsage.total` is
authoritative, `last` is never summed), classify usage payloads **by event type,
never by field name**, key accounting by `thread_id`, high-water-mark replacement.
Fork deltas worth reading: OTEL `-c otel.*` argv overrides + scoped env injection
(fk `334-400`), and `codex/trace_log.ex` (opt-in JSONL trace to stderr with a
monotonic `trace_sequence`, `rescue`d so tracing can never break a run).

**What**: a complete, tested (mock-harness frames in `app_server_test.exs`),
dependency-light client for the protocol OpenAI ships as Codex's native agentic
surface — session lifecycle, approval round-trips, dynamic client-side tools, token
semantics, and the kill/cleanup story.

**Gap in jido_radclaw** (verified 2026-07-04): no app-server client exists; our
Codex integration is `forge/runners/codex.ex:90-132` running `codex exec
--ephemeral` **to completion and batch-parsing the output** (`parse_output/1`
`:176-213` splits accumulated stdout on newlines after exit) — no live event
stream, no mid-run approval round-trip, no session reuse (the MC1-1 gap). The
pattern host exists: `jido_mcp`'s stdio transport is already a Port-driven
JSON-RPC-2.0 speaker (`deps/jido_mcp/lib/jido_mcp/transport/stdio.ex:221-229` +
`stdio_buffer.ex` line-framing) — but it is the dep's, MCP-shaped, and
correlation lives in the Anubis client above it. hermes T2-13 remains NOT_ADOPTED;
its Python session machine has three hardening details symphony **lacks** and the
lift should keep: monotonic deadlines, a post-tool wedge watchdog, and
wedged-session retire. Note symphony's own wart: `codex.stall_timeout_ms` is
schema-defined but **never consumed by the codex driver** — stall detection lives
orchestrator-side only (SY1-2); the fork's Claude/OpenCode drivers implement real
stall + first-activity timeouts (fk `claude_code/app_server.ex:289-363` — 250ms
poll, `:turn_start_timeout` 5s, `:stall_timeout` 300s) and the lift should treat
*that* as the timeout spec, not the codex driver.

**Why it matters**: argus FLOW §4's `:cli` threads and the composer's future Forge
executor both need live-streaming, resumable, approval-capable CLI sessions — the
three properties our batch runners lack. This is the only reference in either
corpus written in our language against the protocol we'd target, and its
approval-handling clauses are exactly the seam where our posture inverts theirs:
where symphony auto-answers or fails the turn, we bridge into the `AgentCase`
inbox (FLOW §4's ask-rule bridges).

**Adoption sketch**: `JidoClaw.Forge.Runners.CodexAppServer` (or a new engine
behaviour, OQ-1) — Port + line-buffer + id-correlation lifted from the symphony
client's shape; `turn/start`-per-iteration on a held thread (their continuation
model) replacing accumulated-prompt re-sends; MC1-1's eager session anchoring +
poisoned-session taxonomy on top; approval/`requestUserInput` frames mapped to
`ToolApprovals.request/3` instead of auto-answer (single-use `:consume` semantics
— the XA1-1 grant rule); hermes's monotonic deadlines + wedge watchdog in the
session GenServer; token accounting per the doctrine doc (absolute totals keyed by
thread). Redaction at the durable sink per FLOW §4. Keep their `bash -lc` spawn
**out** — we spawn executables directly (the multica MC2-4 no-shell rule).

### SY1-2. Orchestrator dispatch hygiene — reconcile-before-dispatch, revalidate-at-dispatch, backoff/stall/caps

**Recommendation**: BORROW-PATTERN. The dig-brief Q4 payload: the loop discipline
our cron/automation engine (FLOW §8) and the landing slice's GitHub reconciliation
(FLOW §10) should match. Joins multica MC2-5 (admission gate / visible skip /
breaker) as the second half of the automation-hygiene reference.

**Where in symphony**: `orchestrator.ex` (up 1,951 / fk 2,498 lines; SPEC §7-8 is
the normative mirror with exact numbers). The bundle: (a) **reconciliation runs
before dispatch on every tick** (SPEC:698) — `reconcile_running_issues` re-fetches
tracker state for everything running and **the external source of truth always
wins** (up `302-325`, `413-435`): terminal → kill agent + delete workspace;
unroutable/non-active → kill, keep workspace; vanished-from-tracker → kill (up
`470-490`). (b) **Dispatch-time revalidation** — between candidate selection and
spawn, the issue's state is re-fetched and stale candidates dropped (up
`995-1013`) — closes the poll-vs-dispatch race. (c) **Three-level concurrency
caps**: global `max_concurrent_agents` 10, per-tracker-state
`max_concurrent_agents_by_state`, per-SSH-host `max_concurrent_agents_per_host`
(up `822-840`, `1293-1301`, `1329-1335`). (d) **Two-lane retry**: clean-exit
continuation retries on a flat 1s delay; failure retries on
`min(10_000 * 2^(attempt-1), max_retry_backoff_ms)` capped at 5m (up `13-14`,
`1192-1203`; SPEC:766-768 states both verbatim). (e) **Stall detection with a
blocked carve-out**: no worker event for `stall_timeout_ms` (300s default; `<= 0`
disables) → kill + backoff retry, **unless** the last event classifies as
input-required, in which case the issue is parked as blocked, not retried (up
`574-657` — see SY2-2). (f) Retries **stick to the prior worker host** ("one
worker lifetime never hops machines", up `agent_runner.ex:22`). (g) Priority sort
with stable tiebreaks: Linear priority 1-4, 0/nil ranked last, then oldest
`createdAt`, then identifier (up `784-795`). (h) Micro-garnishes: a `tick_token`
ref so stale timers are ignored (up `75-92`); `POST /api/v1/refresh` coalesces
into an already-due poll (up `1447-1459`); fork adds a **config fingerprint** —
`:erlang.phash2(config)` per cycle, re-running repo preflight only when it changes
(fk `1783-1799`).

**What**: the full hygiene checklist for a loop that dispatches agents against an
external system of record — every rule small, every rule load-bearing, all
numbers specified.

**Gap in jido_radclaw** (verified 2026-07-04): three distinct holes. (1) Cron:
`platform/cron/worker.ex` has no admission gate, swallows missed ticks, and its
3-strike auto-disable is telemetry-only (`:42, 159-185, 236-247` — the MC2-5
finding; FLOW §8 decided skip-and-record + breaker, nothing implements it). (2)
The composer has per-wave timeouts and three retry budgets
(`route_composer.ex:223-227, 3710-3774`) and capped exponential rebuild backoff
(`:1396-1397`) but **no mid-wave inactivity detection** — `AgentTracker`'s sweep
is terminal-TTL only (`agent_tracker.ex:662-674`) and its `:DOWN` monitor catches
death, not wedging (`:448-455`); a live-but-stuck agent runs to the wave timeout.
(3) **Nothing reconciles against an external source of truth** — `github/` is
inbound-webhook-only, `PullRequestCoordinator.submit_pr/2` is a stub returning a
fake URL (`github/agents/pull_request_coordinator.ex:87-94`), so the landing
slice's "merge webhook auto-advances tasks" currently has no missed-webhook
backstop even on paper.

**Why it matters**: argus's landing slice makes GitHub a second system of record
(PR state, merge events); the moment a webhook can be missed, symphony's
reconcile-before-dispatch posture (poll the truth, converge local state, *then*
act) is the correct backstop shape. And FLOW §12's attention triggers need stall
detection to exist before "agent stalled" can ever page a phone.

**Adoption sketch**: (a) fold into the FLOW §8 automation build alongside MC2-5:
admission gate + visible skip (multica) + **revalidate-at-fire** (symphony's
`995-1013` — re-read task/thread state inside the dispatch transaction). (b) Add
an inactivity clock to composer wave execution: last-Trace-event timestamp per
running stage; exceeding `stall_timeout_ms` cancels the wave child with a typed
reason (joins the MC1-4 failure taxonomy) instead of waiting out
`wave_timeout_ms`; `<= 0` disables, per their rule. (c) Landing slice: a
leader-owned GitHub reconcile poll (interval ≥ 60s) over open PR-linked tasks —
webhook-primary, poll-backstop (OQ-3) — with "external truth wins" transition
semantics. (d) Lift the two-lane retry split (flat continuation vs exponential
failure) into the cron/automation retry policy verbatim, numbers and all.

### SY1-3. Validated-config-contract stack — DB-less Ecto schemas, fail-closed boot, last-known-good reload, strict rendering

**Recommendation**: BORROW-PATTERN (mechanism-flexible: the *contract* is the
borrow; Ecto-embedded-schema is one implementation of it). Lands with FLOW §9's
workflow store; also the posture reference for `.jido/*` validation generally.

**Where in symphony**: `config/schema.ex` (up 563 / fk 1,325 lines) — one
`embedded_schema` per config section, `@primary_key false`, no Repo anywhere;
`parse/1` = normalize keys → `cast` + one `cast_embed` per section →
`apply_action(changeset, :validate)` → post-process (env-var resolution for
`$NAME` secrets, path expansion) (up `282-296`, `374-393`). Sections default to
structs (`defaults_to_struct: true`, up `270-280`) so absent config never
nil-crashes; a custom `Ecto.Type` `StringOrMap` (up `14-38`) lets
`approval_policy` accept `"never"` or a rejection map; errors render as
dot-joined paths ("codex.turn_timeout_ms must be greater than 0", up `530-562`).
Fork adds **mode-gated validation**: in `symphony.yml` global mode a top-level
`hooks` key is rejected with "must be defined in repo-local WORKFLOW.md files";
legacy OpenCode keys are rejected by name; `backend == "opencode"` +
`worker.ssh_hosts` is a validation error ("OpenCode v1 is local-only"); duplicate
project slugs error (fk `772-784`, `1210-1268`). The repo-local overlay
(`project_workflow.ex`) is **allowlisted**: only `agent|hooks|codex|opencode|
claude` may appear, unknown keys are a load error, and each section casts against
an all-nil base so only explicitly-set keys survive the merge (fk `11-23`,
`116-142`, `144-290`). Reload: `workflow_store.ex` / `symphony_config_store.ex`
(1s poll; change stamp = `{mtime, size, :erlang.phash2(content)}`; reload failure
logs and **keeps last known good**, up `141-152`) — boot, by contrast, **fails
closed** on invalid config (`Config.validated_settings!` raises). Rendering:
Liquid via Solid, and SPEC makes strictness normative — "Unknown variables MUST
fail rendering. Unknown filters MUST fail rendering." (SPEC:469-470).

**What**: a complete typed-contract treatment of operator config: invalid at boot
= refuse to start; invalid at reload = keep running on the last good version and
say so; template variables that don't exist = a loud error, not silent empty
string; per-repo overlays structurally incapable of overriding global policy.

**Gap in jido_radclaw** (verified 2026-07-04): every YAML store we own is
hand-rolled warn-and-skip. `.jido/skills/*.yaml` parse ignores unknown keys and
drops malformed files with a warning (`platform/skills.ex:442-464`), deferring
structural validation to compile time (`skills/compiler.ex:95-104`);
strategies/pipelines share the warn-and-skip `yaml_store.ex:171-191` base;
`.jido/config.yaml`'s top level is **never validated** — non-map or parse failure
silently becomes `%{}` merged over defaults (`core/config.ex:73-103`). The one
fail-closed-per-entry validator is `MCP.EndpointConfig.parse/1`
(`mcp/endpoint_config.ex:56-87`) — the local exemplar the pattern generalizes.
`embedded_schema`/`apply_action` appear **nowhere** in lib/ (grep clean); Zoi and
NimbleOptions exist but only for LLM-output and tool-param schemas. FLOW §9 wants
a workflow store whose schema is a strict superset of skill YAML with
immutable-append versions — it needs exactly this validation posture, and has no
substrate.

**Why it matters**: argus workflows will be operator-authored DB rows edited from
a phone — silent-drop semantics that are tolerable for local YAML files become
data loss there. And the fork's mode-gated errors ("hooks must be defined in
repo-local files") are the shape FLOW §13's open item 1 needs when repo-committed
skills surface read-only in argus. The last-known-good reload rule is
independently valuable for `.jido/config.yaml` today: currently a truncated write
mid-edit degrades to defaults silently.

**Adoption sketch**: at the FLOW §9 store build — a `Workflows.Definition` schema
validated at write time (Ash changesets give us the changeset half natively; the
borrow is the *behavioral* contract): create/update of an invalid definition is
rejected with dot-path errors; runs pin versions so a bad edit can't wound
in-flight work (already decided); template rendering (we use Liquid via Solid
too, or EEx) configured strict — unknown variable/filter fails the run's
build-prompt step with a typed error. Nearer-term, cheap: give
`.jido/config.yaml` a fail-closed boot check + last-known-good reload via the
EndpointConfig pattern generalized; keep skills warn-and-skip (repo-local files,
compile-time validation exists) but log the drop as an attention item once FLOW
§12 wiring exists.

### SY1-4. Multi-account rotation + scheduled rate-limit probe — CLI credential health as a subsystem

**Recommendation**: BORROW-PATTERN (design + store layout + probe), TRACK for the
full subsystem (trigger: argus CLI-engine slice, or the operator adding a second
Claude/Codex account — whichever first). The probe piece is adoptable **now** as
the shipped form of Xantham XA2-3's credential canary. *(Connective note,
2026-07-04 pass: the later myrlin dig supplied this entry's **file-mechanics
half** — [MY1-1](../myrlin-workbook/FEATURES-WORTH-BORROWING.md)'s credential
lineage guard (cross-machine OAuth refresh-token lineage pinning, rotation
write-back, three-state token health) covers the on-disk credential layer this
subsystem rotates above; myrlin OQ-2 holds the joint open questions, and
OpenHelm's defer-to-reset classification is the second rate-limit-as-state
arrival, per README observation 12.)*

**Where in OpenSymphony** (fork-only): `accounts.ex` (1,784 lines). Six health
states `healthy|unknown|limited|exhausted|paused|disabled` (`:11`; `unknown` is
the fresh default, `paused_until`/`enabled` compute the effective state
`:718-724`). On-disk store, no DB: `~/.symphony/accounts/<backend>/<id>/` with
`metadata.json`, `state.json`, per-backend `rotation.json`, `usage_periods.csv`,
and **per-account credential isolation** — a `codex_home/` dir (`CODEX_HOME`
injected at spawn) or `claude_config/` + OAuth token file
(`CLAUDE_CODE_OAUTH_TOKEN` + `CLAUDE_CONFIG_DIR` injected, and inherited
`ANTHROPIC_API_KEY` **deliberately blanked** to `""` so the account's OAuth wins,
`:281-296`, `:1140-1154`). Selection per dispatch (`select_for_dispatch`
`:252-278`, `select_usable_account` `:472-505`): skip with reasons —
disabled/paused, `exhausted_until` cooldown (default 300s), running-sessions ≥
`max_concurrent_sessions_per_account` (default 1), daily token budget — then
rotate; all-skipped returns `{:error, %{skipped, next_available_at}}` and the
orchestrator parks the issue with a retry delayed to exactly
`next_available_at` (orchestrator fk `756-766`, `1211-1221`). State transitions:
quota-shaped failures mark exhausted (+cooldown), success bumps
`unknown|limited → healthy` (`:392-436`). The **probe**
(`claude_code/rate_limit_probe.ex`): Claude's stream-json transport never
surfaces rate-limit data, so a GenServer poller (default every 15m,
`rate_limit_poller.ex:16-124`) makes a real ~26-token
`POST /v1/messages` (model `claude-haiku-4-5`, `max_tokens: 1`, OAuth bearer +
`anthropic-beta: oauth-2025-04-20`) and parses
`anthropic-ratelimit-unified-{5h,7d}-{status,reset,utilization}` headers into
session/weekly buckets (`:14-209`). Windows roll into `usage_periods.csv`;
`prometheus_metrics.ex` exports it all as `symphony_account_*` gauges feeding a
shipped Grafana "Account Usage" dashboard. Honest warts, theirs: the default
strategy named `usage_aware_round_robin` is **plain round-robin** — only the
non-default `least_usage` reads usage (`:498-501`, scored
`max(session_pct, weekly_pct)` `:574-590`); and OpenCode gets no account
machinery at all.

**What**: provider subscription capacity treated as a first-class, observable,
rotatable resource — with the two ideas that transfer even at N=1 account:
credentials isolated per identity in their own config-dir (never brokered), and
liveness/quota measured by a **scheduled cheap probe** rather than inferred from
production failures.

**Gap in jido_radclaw** (verified 2026-07-04): one account per provider, single
env var each (`core/config.ex:13-44`); zero LLM rate/quota state anywhere (every
`rate_limit|quota|429` hit in lib/ is the Voyage **embeddings** path —
`embeddings/rate_pacer.ex`, `voyage.ex:134-151`); no provider failover (hermes
T1-4 stays NOT_ADOPTED); and `Config.check_provider/1`
(`core/config.ex:240-252`) is exactly the probe's little sibling — a one-shot
reachability check called only from the REPL banner and setup wizard
(`cli/repl.ex:161`, `cli/setup.ex:264`), never scheduled: the XA2-3 gap,
unchanged. Our Forge OAuth file-sync doctrine (credential files are load-bearing;
contain, never broker) is **compatible by construction** — their per-account
`CODEX_HOME`/`CLAUDE_CONFIG_DIR` isolation is that same doctrine multiplied, not
brokering.

**Why it matters**: for a personal tailnet running CLI agents on subscription
auth, the real capacity constraint *is* the account's session/weekly windows —
multica taught the resume mechanics, this teaches the quota mechanics. Argus's
attention feed wants "credentials degraded" as an infra trigger (FLOW §12 cites
XA2-3); this is the only shipped implementation in either corpus, headers and
all.

**Adoption sketch**: now — a leader-owned cron probe (WS4a Owner) running
`Config.check_provider/1`-style checks per configured provider plus, for Claude
OAuth setups, their unified-ratelimit-header parse; result rows feed the CC1-2
attention read-model as infra-degraded items (never the agent path, XA1-2). At
the CLI-engine slice — adopt the store shape (per-account credential dirs under
the Vault-managed secrets root, `state.json` semantics, six states, skip-reasons
with `next_available_at`), wire Forge runner spawn env through
`credential_env/1`-equivalent (including the blank-the-ambient-key trick), and
surface per-account gauges through our existing telemetry. Fix their naming bug
in ours: if the strategy says usage-aware, read the usage.

---

## Tier 2 — Valuable, lands with a specific slice or decision

### SY2-1. Worktrees off a cached clone — the same-language git plumbing reference (and a scan correction)

**Recommendation**: BORROW-REFERENCE for the argus Worktree domain (OVERVIEW
§3.1, FLOW §2/§5) — read alongside multica MC2-3 (bare-cache mechanics), traycer
TR1-3/TR2-1 (schema), emdash EM1-1 (provisioning practice). This is the only
reference in our own language.

**Where in OpenSymphony**: `workspace.ex` (fk 1,248 lines; upstream has **no git
plumbing at all** — plain `mkdir` + operator hooks, the shipped hook doing
`git clone --depth 1` per issue, up `workspace.ex:15-46,81-85` +
`WORKFLOW.md:22-26`). **Correction to the scan (README observation 3): the cache
is NOT a bare repo.** It is a normal full clone with the target branch checked
out — `gh repo clone` / `git clone` with no `--bare|--mirror|--depth` (fk
`905,925,977,997`), then `checkout -f -B <target> origin/<target>` +
`reset --hard` (fk `936-937`) — living at
`<workspace_root>/.symphony-cache/<sanitized-prefix>-<12-hex-of-sha256(url)>`
(fk `1149-1151`, `config.ex:873-893`). Worktree create (fk `1027-1042`):
`git -C "$cache_repo" worktree prune` then
`worktree add --force -B symphony/<sanitized-issue-id> "$workspace"
"origin/$target"` + best-effort upstream tracking; branch template
`symphony/<id>` (fk `1167-1169`). Remove (fk `1061-1081`): resolve
`--git-common-dir` from inside the workspace, `worktree remove --force` +
`prune`; **exit 10 = "not a worktree" → fallback plain `rm -rf`** — removal
degrades instead of failing. Hygiene details: fetch gated by a 5s
`:persistent_term` TTL per cache (fk `705-717`); cluster-guarded
`:global.trans({…, host, root, cache_key, branch}, …)` serializes
clone/fetch/add (fk `697-703`); default-branch resolution ladder
(`origin/HEAD` → `origin/main` → `origin/master` → first non-HEAD ref → error,
fk `1105-1131`); `GH_PROMPT_DISABLED=1` + `GIT_TERMINAL_PROMPT=0` so a
credential prompt can never hang a script (fk `877-878`); boot-time
`preflight_repo_setup!` force-syncs every route's cache and validates its
repo-local WORKFLOW.md before the first dispatch (fk `161-207`,
orchestrator fk `64`).

**What**: the fork-delta the scan flagged, now fully mapped — clone-per-issue
replaced by cache + worktrees, with the serialization, TTL, prompt-suppression,
and degraded-removal edges a from-scratch build hits in week two.

**Gap in jido_radclaw** (verified 2026-07-04): zero worktree code (the sole
`worktree` token in lib/ is a flag name in
`security/shell_command/git.ex:150`). FLOW §2 specifies bare clones + a
read-only reference checkout per node; §4 specifies two naming templates with a
`-{n}` collision counter.

**Why it matters**: third independent confirmation (after multica and the
symphony *upstream→fork* direction itself) that worktrees-off-a-cache wins over
clone-per-task once volume rises — and the first where the delta is legible in
one file of Elixir. The non-bare choice is a real design fork to weigh: their
cache doubles as a checked-out tree (they pay `checkout -f`/`reset --hard`
danger on the cache; multica's bare-cache rationale — `refs/heads/*` reserved
for worktree branches — avoids that class). FLOW §2's bare-clone +
reference-checkout split remains the better shape; take their edges, not their
topology.

**Adoption sketch**: slice 2, composed with MC2-3: bare cache + remote-tracking
refspec (multica) + symphony's `:global.trans` keying, TTL-gated fetch
(lengthen; 5s is dogfood-tuned), prompt-suppression env, default-branch ladder
(both subjects converged on it — lift verbatim including refusal), boot
preflight per participation set, and degraded-removal semantics feeding the FLOW
§5 phased-delete design (their `--force` posture is the opposite of our
dirty-check rule — keep ours, but keep their not-a-worktree fallback arm).

### SY2-2. Blocked-on-input surfacing — the input-required taxonomy and the park-don't-retry rule

**Recommendation**: BORROW-RUBRIC (the classification + the two behavioral
rules), folding into FLOW §12's attention build. Our durable `AgentCase` is
strictly ahead of their in-memory map — the borrow is the *detector*, not the
store. The fork's deletion of the whole subsystem is the cautionary half.

**Where in symphony** (upstream only): `input_required_blocker?/1`
(`orchestrator.ex:652-657`) — a running entry whose last event is
`:turn_input_required`/`:approval_required`, whose completion outcome is
input/approval-shaped, or which hit `mcpServer/elicitation/request`. Such
entries are **parked, not retried**: moved to a `blocked` map with `blocked_at`,
agent killed (`:201-226`); stall detection skips them (`:593-599`);
reconciliation keeps polling their tracker state and releases them when a human
moves the issue (`:327-349`); surfaced as `snapshot.blocked` → dashboard
"Blocked sessions" ("Issues paused because Codex requested operator input or
approval", `dashboard_live.ex:215-287`) and the JSON API. Restart clears the
map (in-memory only — README `:29-32` says so plainly). The **fork deleted all
of it** — no `blocked` state, no classifier, plus the upstream
elicitation-hard-block clause removed from the codex driver (fk
`needs_input?/2` `:1264-1269` vs up `:1062`) — so a fork agent that asks a
question either fails the turn or silently idles toward the 1h turn timeout.

**What**: the platform-side detector for "this run is waiting on a human" — the
exact classification FLOW §12's blocked-on-you and `ended_blocked` triggers
need, shipped and dashboard-wired by the same team whose *prompt* says never to
ask.

**Gap in jido_radclaw** (verified 2026-07-04): our gate family produces durable
`AgentCase` rows when *our* machinery asks (approval gates, review gates), but
nothing classifies an **external CLI's** input-request events into an attention
state — Forge's `:needs_input` broadcasts exist (`forge/harness.ex:662-674`)
and reach no operator surface (the CC1-2 gap, still open). FLOW §12 already
lists Forge `:needs_input` as a trigger; the park-don't-retry and
skip-stall-for-blocked rules are not yet stated anywhere in FLOW.

**Why it matters**: the "unattended by design" team still needed a blocked
lane — the strongest external evidence yet that blocked-on-human is a
first-class run state, not an error. And their in-memory-only store (restart →
blocked issues silently re-dispatch, losing the "a human owes an answer" fact)
is precisely the failure our durable-case posture avoids; the fork deleting the
subsystem shows how easily a capability regression ships when the state isn't
durable or spec'd.

**Adoption sketch**: slice 1 attention build — adopt their two rules verbatim
into the trigger semantics: (1) input-required runs are parked (no retry burn,
no stall kill) with the blocking question attached; (2) reconciliation, not the
agent, releases them. Classifier: map Forge `:needs_input` + (later) app-server
approval/`requestUserInput` frames (SY1-1) into the attention read-model with
kind `blocked_on_you`; durable row, not GenServer memory.

### SY2-3. Single-source multi-CLI tool generation — one module emits every backend's tool artifact

**Recommendation**: BORROW-PATTERN for FLOW §4's CLI-engine slice (the per-CLI
adapter config templates FLOW already assigns to the adapter).

**Where in OpenSymphony**: `linear/graphql_tool.ex` (565 lines) is the single
source for the same Linear tool across all three backends: the JSON schema +
in-daemon executor for Codex's dynamic tool (`:10-25`; upstream's
`codex/dynamic_tool.ex` is now a legacy shim, fk `:6,12-36`), a **generated
node stdio MCP server** written into the workspace for Claude
(`.symphony/claude/linear_graphql_mcp.js`, Content-Length-framed
initialize/tools-list/tools-call, `:145-406`, installed by
`claude_code/tooling.ex:53-58` with `--strict-mcp-config` pointing at it), and
a generated `@opencode-ai/plugin` TypeScript tool (`:61-143`, installed by
`open_code/tooling.ex`). Companion hygiene: generated dirs added to
`.git/info/exclude` (worktree-aware, `tooling.ex:68-93`); secrets reach the
generated tools as **renamed scoped env** (`SYMPHONY_LINEAR_API_KEY`, not
`LINEAR_API_KEY` — deliberate namespacing so ambient credentials are not the
interface, `graphql_tool.ex:72-73,167-168`); remote bootstrap is one SSH
heredoc (`tooling.ex:151-198`). Contrast: upstream executes the tool
**in-daemon** (the subprocess never holds the Linear token) — the fork moved
execution into the agent process and scoped the env instead.

**What**: the write-once answer to "N CLI backends each want the platform tool
in their native format" — schema, executor, and per-CLI packaging generated
from one module, with credential scoping decided per topology.

**Gap in jido_radclaw** (verified 2026-07-04): FLOW §4 plans the stronger
topology — sandboxed CLIs reach platform tools through an HTTP MCP endpoint
with per-session scoped tokens, so tools execute **our-side** (upstream's
model, hardened) rather than agent-side. What FLOW assigns to the adapter but
nothing designs yet is the per-CLI config-template surface: Claude
`--mcp-config`/`--strict-mcp-config` files, Codex `dynamicTools` registration,
OpenCode plugin dirs. No equivalent exists (`mcp/` is consumption; `MCPServer`
is stdio-serving).

**Why it matters**: their `strict-mcp-config` + generated-config approach is
exactly how a sandbox keeps the CLI's tool surface pinned to what we issued
(no ambient MCP servers leaking in), and the git-exclude + renamed-env habits
are cheap leakage hygiene our threat model buys wholesale.

**Adoption sketch**: slice 6 — the CLI adapter owns a
`generate_tool_config/2` per backend (claude mcp.json pointing at our HTTP MCP
endpoint with the per-session token; codex `dynamicTools` mapped to the same
scope; opencode plugin shim if ever supported), written into the sandbox at
provision, git-excluded, tokens via scoped env with our names. Keep execution
our-side per FLOW; their agent-side variant is the fallback if a CLI can't
reach the endpoint.

### SY2-4. Teardown that closes stranded PRs — `before_remove` as a stranded-work sweep

**Recommendation**: BORROW-PATTERN for FLOW §5 teardown + §12 stranded-work
detection. The first shipped stranded-PR answer in either corpus (multica's was
an honest not-found). *(Connective note, 2026-07-04 pass: the three later-dug
subjects supplied the spectrum this entry answers — orca force-deletes with the
branch included, myrlin's record-delete strands worktree + branch with no
reconciliation sweep, bosun's middle keeps branches but sweeps dirs; README
observation 11 assembles the line. SY2-4 stays the only PR-side sweep in either
corpus.)*

**Where in symphony** (identical both repos):
`lib/mix/tasks/workspace.before_remove.ex` — wired as the `before_remove` hook
in the shipped workflows, it looks up **open GitHub PRs for the workspace's
branch and closes them** on terminal-state teardown, gated on `gh` presence +
auth; plus the orchestrator's two sweep sites — terminal-state reconciliation
kills the agent and deletes the workspace (up `orchestrator.ex:413-418,1130`),
and a **startup sweep** deletes workspaces for issues already terminal at boot
(up `1141-1156`, fk `1041-1056`). Hook lifecycle semantics worth keeping
(SPEC:869-892): `after_create`/`before_run` failures are **fatal** to the
attempt; `after_run`/`before_remove` failures are **logged and ignored** —
teardown never blocks on its own hooks. Honest wart: the mix task still
hard-defaults `@default_repo "openai/symphony"` in the fork (`:18`) — an
orphaned constant.

**What**: teardown as an explicit stranded-work checkpoint — when the durable
identity (issue) terminates, its execution residue (workspace, branch, **open
PR**) is swept, with failure-tolerance chosen per hook.

**Gap in jido_radclaw** (verified 2026-07-04): no worktrees yet; Forge cleanup
is lifecycle-scoped; FLOW §5 specifies phased, dirty-checked deletion and §12
lists stranded-work detection, but no design item covers **open PRs attached
to a deleted worktree** — the landing slice creates exactly that residue class
once `PullRequestCoordinator` is built real (today a stub,
`github/agents/pull_request_coordinator.ex:87-94`).

**Why it matters**: on a board-driven flow, "task canceled with a PR still
open" is the most common stranded-work shape; their answer (sweep at teardown,
never block on it) slots directly into our phased-delete design as the phase
after dirty-check.

**Adoption sketch**: slice 4 — worktree deletion's final phase enumerates open
PRs for the branch (via the then-real GitHub client) and offers
close-or-detach in the deletion confirm (operator choice, not automatic —
our HITL posture); cron variant for orphaned `symphony/*`-style branches folds
into per-node housekeeping (FLOW §2). Keep their fatal-vs-ignored hook split
verbatim in the provisioning lifecycle (FLOW §5 setup steps).

---

## Tier 3 — Garnish

### SY3-1. PR-body template lint as a deterministic gate

`pr_body.check.ex` (identical both repos) validates a PR body against
`.github/pull_request_template.md` structurally: required headings present and
**in order**, no leftover `<!-- -->` placeholders, bullet/checkbox sections
non-empty (`:79,101-129`), run in CI on every PR edit
(`pr-description-lint.yml`). **Gap**: our landing slice's PR-metadata review
gate (FLOW §10) is LLM-generated + operator-edited; a deterministic
template-conformance check before the gate opens is cheap and catches the
LLM's format drift without burning operator attention. Adopt as a validation
step inside the landing gate when slice 4 builds it.

### SY3-2. Dispatch ordering with stable tiebreaks

Priority rank (1-4 ascending, 0/nil ranked **last** — "no priority" ≠ "top
priority"), then oldest `createdAt`, then identifier
(up `orchestrator.ex:784-795`; SPEC:738-742). **Gap**: FLOW §7/§8 haven't
specified automation dispatch order for ready-kind tasks. Lift the triple —
deterministic order is what makes "why did B run before A" a non-question.

### SY3-3. Continuation-turn prompt discipline

SPEC normative: first turn sends the full rendered task prompt; continuation
turns send **only continuation guidance**, never re-send the task (SPEC:631-643;
up `agent_runner.ex:141-153`). The session's own memory carries context.
Composes with multica MC3-1 (inject only the new comment) and lands with MC1-1's
warm-resume work — our successor-thread and Forge iteration paths re-send
accumulated context wholesale today (`forge/runners/claude_code.ex:61-88`).

---

**Status (2026-07-11, SY3-3)**: ADOPTED (rider on MC1-1 — pre-argus Wave A
#2). Continuation-turn discipline is contract now: turn 1 sends the full
rendered prompt; every later turn sends GUIDANCE only (the consolidator's
`Prompt.continuation/1`; the runners' continuation floor is a neutral
`"Continue."` nudge, NEVER `state.prompt` — CM2-3-pinned in both vendor argv
tables), and `Forge.run_loop/2` drops the caller's `:prompt` on iterations ≥ 2.
See [docs/system/forge-session-resume.md](../../../system/forge-session-resume.md).

## Skip / Already Covered

- **S-1. The daemon as a product / unattended posture** — SKIP. The inverse of
  argus HITL; its own shipped workflow disables every ask. Useful only as
  contrast, recorded throughout.
- **S-2. SSH remote workers** — SKIP as mechanism (our fabric is Erlang dist +
  `:pg` over the tailnet — `core/cluster.ex`; no `:erpc`/`ssh` dispatch exists in
  lib/ and none is wanted). Record the datapoints: selection is least-loaded by
  **running-count only** with config-order tiebreak (up `1269-1283`), retries
  stick to the prior host because the workspace lives there (de facto
  affinity — convergent with FLOW §2 pinning), **no health checks** (a dead host
  is discovered by spawn failure), per-host caps exist (SY1-2 takes those).
  OpenCode is local-only even when other backends go remote.
- **S-3. Linear as the board** — SKIP; FLOW §7 decided native tasks. Their
  tracker behaviour (5 callbacks, `tracker.ex:8-12`) with writes-defined-but-dead
  is the thinness argus avoids by owning the board.
- **S-4. `mix specs.check` @spec-coverage linter** — ALREADY-COVERED by
  dialyzer + credo-strict in `mix precommit` (mix.exs:255-264); our gates check
  more than presence.
- **S-5. Read-only LiveView dashboard + JSON API + auth-none posture** —
  ALREADY-COVERED (our `/workflows` LiveView + MCP observe tools are richer;
  read-only claim verified — zero `handle_event` in either repo, the one
  mutation is `POST /api/v1/refresh`). The auth-none, loopback-bind-only surface
  re-confirms the argus §4.4 posture (CC2-4 remains the canonical negative
  reference).
- **S-6. In-memory scheduler state / no persistence** — SKIP; the contrast *is*
  the argument for our event-sourced spine (squidie T1-1). Upstream knows —
  "persist retry queue and session metadata across restarts" is their TODO
  (SPEC:2111-2116), and their unmerged Jira branch adds persisted claim leases.
- **S-7. Memory tracker test double** (`tracker/memory.ex`) — ALREADY-COVERED
  (our eval harness fake↔live seam + test doubles).
- **S-8. `codex/trace_log.ex` JSONL tracing** — ALREADY-COVERED by the Trace
  subsystem; the monotonic per-run `trace_sequence` + never-break-a-run rescue
  posture are habits we already follow. The `AGENT_OBSERVABILITY` env-gate shape
  is noted for the Forge transcript pair (agentos borrow) if it ever needs an
  opt-in switch.
- **S-9. OTEL env injection + VictoriaMetrics/Vector/Grafana stack** — SKIP for
  now (our telemetry is in-app + Trace events; a metrics stack is
  infrastructure, not a borrow). `claude_data.md` — their empirical map of what
  Claude Code actually emits over OTEL (`claude_code.token.usage`,
  `.cost.usage`, event types, label-shape gotchas) — is worth remembering as a
  **reference document** if argus ever consumes Claude Code's native telemetry;
  it would save the same week of reverse-engineering it cost them.
- **S-10. SPEC-first discipline as machinery** — mostly ALREADY-COVERED:
  spec↔code alignment is prose policy there (AGENTS.md; `specs.check` is a
  typespec linter, **not** SPEC conformance), while our doctrine slices are
  CI-probed (`Eval` `:coherence` + `mix jidoclaw.system_prompt.check`). Their
  negative half is instructive: the fork downcased upstream's RFC-2119 section
  and its SPEC now omits `symphony.yml`, multi-backend, and label routing
  entirely — unenforced specs drift within one fork generation.

---

## Dig-brief dispositions (the standing questions, answered)

Per [DIG-BRIEFS.md](../DIG-BRIEFS.md) — disposition ∈ answered / contradicted /
absent, with the entry or evidence that carries it.

**symphony + OpenSymphony-specific:**

1. **Codex app-server client protocol surface** — ANSWERED (SY1-1), with one
   sharpening the scan missed: `codex.stall_timeout_ms` is schema-defined but
   never consumed by the codex driver — stall detection is orchestrator-side
   (SY1-2); the client's only clocks are 5s per-response and 1h per-turn. Token
   accounting is passive metadata copy + the `token_accounting.md` doctrine.
   Approval/user-input/elicitation handling fully mapped, including the
   auto-answer constant and the default reject-map policy (auto-approve only
   under explicit `"never"`).
2. **Claude Code headless driver** — ANSWERED (SY1-1 fork deltas + SY2-3).
   Notable vs multica MC1-1: a **different resume model** — one long-lived
   `claude -p --input-format stream-json` process fed successive user messages
   over stdin (client-generated `--session-id`, no `--resume` flag at all),
   where multica re-invokes with `--resume <id>` per turn. Only this driver
   reaps the OS process group (TERM → grace → KILL). Events are re-shaped into
   OpenCode-style envelopes for a uniform downstream. Permission posture is
   delegated entirely to `--permission-mode` (default `bypassPermissions`).
3. **Worktrees off a cached bare repo** — ANSWERED with a CORRECTION (SY2-1):
   worktrees yes, **bare no** — the cache is a normal full clone with the
   target branch checked out (`checkout -f -B` + `reset --hard` on the cache).
   Verbatim scripts, TTL fetch gate, `:global.trans` serialization,
   default-branch ladder, exit-10 fallback removal all captured.
4. **Orchestrator dispatch loop** — ANSWERED (SY1-2): 30s poll,
   reconcile-before-dispatch every tick (external truth wins), dispatch-time
   revalidation, three-level caps, 1s continuation vs 10s·2ⁿ-cap-5m failure
   retries, stall-with-blocked-carve-out, sticky retry host. SPEC §7-8 mirrors
   it normatively with exact numbers.
5. **`WORKFLOW.md` as validated contract** — ANSWERED (SY1-3): Ecto embedded
   schemas + `apply_action(:validate)`, `StringOrMap` custom type, dot-path
   errors, fail-closed boot, 1s-poll hot reload keeping last-known-good, strict
   Liquid (unknown variable/filter fails rendering), fork's allowlisted
   repo-local overlay + mode-gated validation. Full field inventories captured
   both sides.
6. **Placement and capacity trio** — ANSWERED: SSH least-loaded =
   running-count-only with sticky retries and no health checks (S-2); label
   routing resolves single-match backend + `thinking/*` effort labels with
   conflict→default+warning, per-backend effort remap (`max`→codex `xhigh`,
   `xhigh`→opencode `max`); accounts have **six** states (not the scanned
   four — `unknown`, `disabled` added), and the default
   `usage_aware_round_robin` strategy is plain round-robin — only `least_usage`
   reads usage (SY1-4).
7. **The reverted comment-resume (#84 → #85)** — PARTIALLY ANSWERED. The
   mechanism is recoverable (thread links, comment cursors, blocked-input
   tracking, comment-fetch + resume of blocked runs — the multica shape); the
   *rationale is not recorded*: the revert commit says only "the request was to
   revert the merged change … so Symphony main returns to the previous
   workflow" — no technical failure documented. The scan's "tried and backed
   off" negative datapoint softens to "merged, then withdrawn on request,
   reason unrecorded." Related: upstream #66 then shipped the *surfacing* half
   (blocked sessions, SY2-2) without the resume half.

**Cross-cutting (every dig):**

1. **§5 edit-and-resume sweep** — ABSENT in both. No gate objects exist at any
   layer: approvals are machine-answered or fail the turn (driver), the
   orchestrator has no checkpoint/decision machinery, the dashboard is
   read-only (verified — zero `handle_event`), and the one blocked lane parks
   until a *tracker state* changes. **Seventeenth and eighteenth subjects
   verified empty; argus §5 head-promotion stays novel.**
2. **Provisioning lifecycles** — PARTIAL: no setup state machine (traycer keeps
   that crown); what exists is the four-hook lifecycle with per-hook
   fatality semantics (create/run fatal, teardown ignored — SY2-4), 60s hook
   timeouts, fork boot preflight (clone caches + validate workflows before
   first dispatch) and config-fingerprint-triggered re-preflight (SY1-2h).
3. **Branch/directory naming** — ANSWERED: dir =
   `<root>/<sanitized-id>` (charset `[A-Za-z0-9._-]`, SPEC Invariant 3);
   branch = `symphony/<sanitized-id>` (fork; upstream leaves branching to the
   agent's prompt). **No collision counter** — `worktree add --force -B`
   force-resets instead (FLOW §4's `-{n}` counter remains the better UX).
4. **Status/attention taxonomies** — ANSWERED: status semantics via config-set
   membership (`active_states` / `terminal_states`) with handoff states
   (`Human Review`) deliberately in **neither** set — the daemon goes blind to
   them, which *is* the handoff. The shipped board adds `Rework`/`Merging` as
   active (human re-queue = drag back to an active state). The fork made
   `Backlog` *terminal* to keep it inert — a hack our `triage`/`backlog` kinds
   make unnecessary (FLOW §7 evidence, joining MC1-2's). Attention: upstream's
   blocked-sessions surfacing (SY2-2); priority 0 ranks last (SY3-2).
5. **Teardown + stranded-work** — ANSWERED (SY2-4): terminal-state
   reconciliation sweep + startup sweep + the `before_remove` hook closing
   open PRs — the corpus's first stranded-PR answer. No dirty-check anywhere
   (`rm -rf`/`--force` unconditional) — our FLOW §5 phased+dirty-checked rule
   stands against their grain.
6. **Placement & multi-machine addressing** — ANSWERED (S-2, SY1-2): static
   host list, count-based least-loaded selection at dispatch, per-host caps,
   sticky retries (workspace = de facto affinity), no health probes, no
   migration. Host-gone = spawn/port failure → backoff retry on re-selection.
   Their scheduling exists *because* workspaces are disposable; argus's
   durable worktrees are exactly why FLOW §2 pins instead.

---

## Open questions

- **OQ-1 — Where does the app-server client live: Forge runner variant or a new
  engine behaviour?** SY1-1 can ship as a third `Forge.Runner` (alongside
  claude_code/codex exec) or as the first implementation of a
  streaming-session "engine" behaviour that FLOW §4's `:cli` threads formalize.
  The runner route ships sooner and inherits sandbox containment; the behaviour
  route avoids retrofitting streaming onto the batch `Runner` contract
  (`forge/runner.ex:15-33`). Sequence against MC1-1 (resume stack lands first
  either way) and camus C1-1. Decide at slice 6 design.
- **OQ-2 — Probe now or with the accounts subsystem?** The XA2-3 canary slot is
  open today and SY1-4's probe is its shipped shape — but the full
  accounts/rotation build only pays once a second account exists.
  Recommendation embedded in SY1-4: split them — scheduled provider canary now
  (leader-owned cron + attention item), rotation store at the CLI-engine slice
  or on the second-account trigger.
- **OQ-3 — Landing-slice reconciliation direction.** Symphony is poll-primary
  (no webhooks at all); argus is webhook-primary (HMAC ingress exists). The
  open choice is the backstop cadence and scope: reconcile only open
  PR-linked tasks (cheap, bounded) vs. all non-terminal landing state. Decide
  at slice 4 with SY1-2c's "external truth wins" semantics either way.

---

## Cross-references and dependencies

```
SY1-1 (app-server client) ──composes──▶ MC1-1 (resume stack: anchoring, poisoned taxonomy)
      ├─absorbs──▶ hermes T2-13 (supersedes as reference; keep its deadline/watchdog garnish)
      ├─feeds────▶ SY2-3 (tool-config generation rides the same adapter)
      └─gated by─▶ OQ-1 (runner vs engine behaviour), argus slice 6 / camus C1-1
SY1-2 (dispatch hygiene) ──joins──▶ MC2-5 (admission gate/skip/breaker) for FLOW §8
      ├─feeds────▶ OQ-3 (landing reconcile), SY2-2 (stall carve-out is its exception rule)
      └─fixes────▶ composer idle-detection gap (seams: agent_tracker.ex:662-674)
SY1-3 (config contract) ──lands with──▶ FLOW §9 workflow store; near-term .jido/config.yaml hardening
SY1-4 (accounts + probe) ──ships──▶ XA2-3 canary (now) ──then──▶ CLI-engine credential health
      └─composes─▶ Forge OAuth file-sync doctrine (per-account dirs = more sync, never brokering)
SY2-1 (worktree plumbing) ──composes──▶ MC2-3 + traycer TR2-1/2 + emdash EM1-1 (slice 2 reading stack)
SY2-2 (blocked surfacing) ──feeds──▶ FLOW §12 triggers + CC1-2 attention read-model (slice 1)
SY2-4 (teardown PR sweep) ──lands with──▶ slice 4 landing + FLOW §5 phased delete
SY3-1..3 ──ride──▶ slices 4 / 3 / MC1-1 respectively
```

**Suggested first wave** (no argus slice required): **SY1-4's probe half** — the
scheduled provider canary (closes XA2-3, first consumer of the attention
read-model CC1-2 wants) → **SY1-3's near-term half** — fail-closed boot +
last-known-good reload for `.jido/config.yaml` (an afternoon against the
EndpointConfig pattern) → **SY1-2b** — composer wave inactivity clock (typed
stall reason joining MC1-4's taxonomy). Extracted as a grab-ready sequenced
queue in [SY-FIRST-WAVE.md](SY-FIRST-WAVE.md) (sibling doc; per-item done-when
criteria + the reconcile-the-source-entry discipline; also records the SY3-3
rider on MC first wave #2). Everything else is argus-slice-bound:
SY1-1/SY2-3 at slice 6 (after MC1-1), SY1-2a+MC2-5 at slice 3, SY2-1 at slice 2,
SY2-2 at slice 1, SY2-4/SY3-1/OQ-3 at slice 4.

**Collision notes**: nothing here collides with unadopted-next-ten items 4-10
(composer/judgment work) or the MC first wave — SY1-1 deliberately sequences
*after* MC1-1 on the same Forge runner files; SY1-4's probe touches
`core/config.ex` + cron, not the runner files. hermes T2-13's entry should get a
cross-ref note at its next re-review pass (superseded-as-reference by SY1-1, not
yet adopted by either).

## Bottom line

1. **The CLI-engine slice now has its full reference stack, in our language**:
   symphony's app-server client (SY1-1) + multica's resume/poisoned-session
   mechanics (MC1-1) + hermes's session-hardening garnish — protocol, resumption,
   and watchdogs, with our gates replacing their auto-answer at exactly one seam.
2. **Dispatch hygiene is now fully specified by two complementary subjects**:
   multica's admission gate/visible-skip/breaker + symphony's
   reconcile-before-dispatch/revalidate-at-fire/two-lane-retry/stall-with-
   blocked-carve-out (SY1-2, SY2-2). FLOW §8 and the landing slice's
   reconciliation should adopt the merged checklist wholesale.
3. **FLOW §9's validation story has its pattern** (SY1-3): fail-closed at write,
   last-known-good at reload, strict rendering — and our own YAML stores'
   warn-and-skip posture now has a named upgrade path.
4. **The §5 novelty claim survives subjects seventeen and eighteen** — even
   OpenAI's own orchestrator has no durable gate, no edit path, an in-memory
   blocked lane its fork deleted, and a comment-resume that was merged and
   withdrawn. Argus's durable gates + head-promotion + platform-detected
   attention remain the differentiated core; the strongest team in the field
   shipped the inverse and their fork immediately regressed the one
   human-facing lane they had. Build ours.
