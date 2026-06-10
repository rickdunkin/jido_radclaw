# In-Depth Code Review

**Date:** 2026-06-10
**Scope:** Full review of `lib/` (441 files, ~75K LOC), `config/`, and `lib/mix/tasks/` across security, correctness, OTP/concurrency, resource management, and data-layer integrity.
**Method:** Thirteen parallel read-only subsystem reviews (security/data, forge, tools, agent layer, reasoning, memory, orchestration, CLI/mix tasks, shell/core patches, web, platform/conversations, solutions/trace/error, infra/network), followed by independent re-verification of every HIGH finding against source by the orchestrating reviewer. Findings marked **✓ verified** were re-confirmed line-by-line; others carry the subsystem reviewer's stated confidence.

**Baseline gates (all green at HEAD `9918c1f`):**

- `mix jidoclaw.compile_check` — OK (2 tolerated, 0 blocking; the two documented dead-`else` branches in `PullRequestCoordinator`)
- `mix format --check-formatted` — clean
- `mix credo --strict` — 0 issues across 696 files
- `mix test` — **2487 passed, 11 excluded** (~77s)

Because the mechanical gates are this strong, everything below is in the category static analysis and the current test suite cannot see.

## Relationship to the 2026-05-16 audit

This review is a follow-up to [codebase-audit-2026-05-16.md](codebase-audit-2026-05-16.md). Several of that audit's criticals are now fixed and were re-verified as solid during this review:

- **C1 (tool outputs never redacted)** — closed by the `JidoClaw.Tools.Action` macro pipeline: every tool result now flows through normalize → redact → truncate and individual tools cannot opt out.
- **C3 (VFS resolver has no path-jail)** — closed by `VFS.Resolver.resolve_project_path/3`: realpath-based symlink resolution with a depth cap and real-root containment for both reads and writes; verified against absolute-path, `..`, and symlink escapes.
- **C2 (local sandbox is `sh -c` as host user)** — partially mitigated (env scrubbing, prompt/output redaction, `Path.safe_relative` guards) but `:local`/HostShell remains the default execution path and the env scrub has gaps (see H9, M13).

## Threat-model calibration

The May audit scored against a **single-user, Tailscale-only** deployment where the primary adversary is the LLM itself. This review scored severities assuming the Phoenix gateway may be exposed and/or multi-user, because the default `serve_mode` is `:both` and the endpoint binds `0.0.0.0:4000` — the dashboard is on by default.

If the single-user/Tailscale assumptions still hold:

- **Deprioritize:** H1 (AshAdmin), H3 (RpcChannel leak), H16 (Folio authorization) — all require a second authenticated user or an attacker already on the tailnet.
- **Keep at HIGH:** H2 (`check_origin: false`) — the attack vector is the *operator's own browser* visiting a malicious page, which the tailnet does not mitigate.
- **Conditional:** H4/H5 (network/cluster) apply only when `:cluster_enabled` is true; H6 (trust gaming) is reachable by the LLM via the solution store even single-user.
- **Keep:** all reliability/correctness highs (H10–H15) and the secrets-at-rest highs (H7–H9) — these are LLM-adversary or accidental-leakage findings, exactly the categories the May threat model keeps.

## TL;DR

- **16 HIGH** findings: 6 boundary-trust security issues (surfaces in front of a carefully-policied data layer), 3 secrets-handling gaps, 7 reliability/correctness bugs that degrade the core agent loop in normal operation.
- **~18 MEDIUM** and **~20 LOW** findings.
- The dominant pattern: the *data layer* enforces tenancy and authorization rigorously, but several *surfaces* in front of it (admin UI, a WebSocket channel, the clustered solution-sharing bus, the sandbox env boundary) don't gate as tightly as the layer behind them assumes.
- The second pattern: a handful of "best-effort, never blocks the agent" paths that aren't as safe as their docs claim (compactor exception safety, memory duplicate-key retry, ResearchCoordinator rescue).

**Most urgent given default `:both` serve mode:** H1 + H2 together make the privileged surface reachable. After that, H10 (spawn-cap lockout) and H11 (compactor exception safety) are the highest-value reliability fixes.

---

## HIGH — security: surfaces in front of the data layer

### H1. AshAdmin is reachable by any authenticated user and runs with authorization disabled ✓ verified

**Where:** `lib/jido_claw/web/router.ex:29-31`, `lib/jido_claw/web/plugs/require_auth.ex:14-35`

**What:** `/admin` is gated only by `:require_browser_auth`, and that plug authorizes *any* logged-in user — there is no admin/superuser role check. AshAdmin defaults `authorizing: false` (`deps/ash_admin/lib/ash_admin/actor_plug/plug.ex:24`) and the router configures no actor session, so AshAdmin runs actor-less with policies off. Since tenancy is one-tenant-per-user (`Authorization.Actor.build/1` sets `tenant_id = to_string(user.id)`), any registered user can browse/mutate **every tenant's** rows from `/admin`, bypassing the `forbid_if(always())` policies on `User`/`Token`/`SecretRef`. Encrypted columns stay hidden (`public?: false`), but emails, token subjects/JTIs, secret-ref names/categories/owners, and all domain data across tenants are exposed and editable.

**Fix:** Add an admin-role authorization plug in front of `ash_admin` (not mere "is authenticated"), and configure AshAdmin to enforce authorization with the request actor (set the actor session keys via `AshAdmin.Router` options, force `authorize?: true`) so the existing policies apply.

### H2. `check_origin: false` is the base config; only prod overrides it ✓ verified

**Where:** `config/config.exs:206` (prod override at `config/runtime.exs:64`)

**What:** In dev/staging/`:both`, WebSocket origin checks are off and the endpoint binds `0.0.0.0:4000`. With `same_site: "Lax"` session cookies (which do not block JS-initiated WebSocket upgrades), any site a logged-in operator visits can open an authenticated `/live` or `/ws` socket cross-origin (CSWSH) and drive privileged events — workflow replay/force-replay, gate decisions, `sessions.sendMessage`.

**Fix:** Make `check_origin: true` (or a host allowlist) the base default in `config.exs`; opt into `false` only in `dev.exs` if needed; bind dev to `http: [ip: {127,0,0,1}, port: 4000]`.

### H3. `RpcChannel "sessions.list"` leaks every tenant's session IDs ✓ verified

**Where:** `lib/jido_claw/web/channels/rpc_channel.ex:26-39`

**What:** The handler runs an unscoped `Registry.select` over `JidoClaw.SessionRegistry` (keyed `{tenant_id, session_id}`) and returns all tenants' pairs to any authenticated socket. Every other RPC handler derives tenant from `socket.assigns.current_user`; this one does not.

**Fix:** Filter to the caller's tenant (mirror `Session.Supervisor.list_sessions/1`, which already scopes by tenant). Related hardening: the catch-all `join("rpc:" <> _topic, ...)` admits any subtopic with no per-topic authorization (L-class today since handlers ignore the topic, but a latent footgun).

### H4. Unauthenticated solution injection over clustered PubSub ✓ verified

**Where:** `lib/jido_claw/network/node.ex:385-389`

**What:** `valid_or_unverifiable?/2` is a stub that **always returns `true`** ("We don't maintain a peer key registry yet"), so every inbound `:solution_shared` / `:solution_response` message is stored without signature verification. The transport is `Phoenix.PubSub.PG2`, which broadcasts across all connected BEAM nodes. Combined with H5, any node that joins the cluster can inject attacker-controlled "shared" solutions, which later surface to the LLM via `find_solution` — a data-poisoning / prompt-injection vector (not direct RCE; solution content is never executed). `Protocol.verify_message/2` exists and is unused.

**Fix:** Maintain a peer pubkey directory keyed by `agent_id`, verify with `Protocol.verify_message/2`, and **drop** unverifiable messages — accept-if-unknown is backwards for a trust boundary. At minimum gate the network subscriber off unless an explicit peer-key allowlist is configured.

### H5. libcluster gossip configured with no `secret` ✓ verified

**Where:** `lib/jido_claw/core/cluster.ex:96-104, 140-148`

**What:** Both the `:gossip` branch and the fallback build the topology with no `secret:` key and `if_addr: {0,0,0,0}`. libcluster docs: nodes not sharing the same encryption key will not be connected — with no secret, any host on the multicast segment can discover and attempt to join. The repo sets no Erlang distribution cookie anywhere, so deployments fall back to `~/.erlang.cookie` (often predictable/shared in container setups). Distributed Erlang membership = full code execution on peers.

**Fix:** Require a gossip `secret` from env; refuse to start clustering when `:cluster_enabled` is true but no secret is set; document/enforce a non-default distribution cookie.

### H6. Solution trust score is self-asserted, not earned — gameable on two paths ✓ verified

**Where:** `lib/jido_claw/solutions/network_facade.ex:22-30`, `lib/jido_claw/solutions/resources/solution.ex:106-137`

**What:** `store_inbound/2` strips scope + embedding keys but **not** `trust_score`, `verification`, `tags`, or `agent_id`; the `:store` create action `accept`s `:trust_score` and `:verification` and runs no `RecomputeTrustScore` change. A peer (or any internal/legacy caller) can store `trust_score: 1.0, verification: %{"status" => "passed"}` with hostile content; it ranks top in cross-workspace `find_solution` (`ORDER BY ... trust_score DESC`) and is rendered verbatim to the agent. The in-REPL `StoreSolution` tool sets neither field, but the action contract permits it.

**Fix:** Add `:trust_score`/`:verification` to `@forced_inbound_keys`, and drop `:trust_score` from `:store`'s `accept` (or add `RecomputeTrustScore` to `:store`) so trust is always derived server-side.

---

## HIGH — secrets at rest / in transit

### H7. Setup writes API keys to `.env` world-readable ✓ verified

**Where:** `lib/jido_claw/cli/setup.ex:300-317`

**What:** `persist_env_var/3` — the sink for `VOYAGE_API_KEY` and any key the user pastes, and the documented secret store loaded at boot — does `File.write!(tmp, ...)` + `File.rename!` with no `File.chmod`, so `.env` is created at the process umask (typically `0644`, readable by every local user). Verified: zero `chmod` calls in the file.

**Fix:** `File.chmod!(tmp, 0o600)` before the rename; defensively `File.chmod(env_path, 0o600)` when the file already exists.

### H8. Conversation migration imports content with no redaction ✓ verified

**Where:** `lib/jido_claw/conversations/resources/message.ex:167-190`, `lib/mix/tasks/jidoclaw.migrate.conversations.ex:207-227`

**What:** The `:append` action runs `Changes.RedactContent`; the `:import` action used by the migrator runs only `ValidateCrossTenantFk`. Solutions (`:import_legacy`) and the memory migrator both redact on import — conversations are the lone gap. Any raw secret in a legacy v0.5.x `.jido/sessions/*.jsonl` is persisted verbatim and later re-exported verbatim by `jidoclaw.export.conversations`.

**Aggravating factor (M-class on its own):** `test/mix/tasks/jidoclaw_conversations_export_test.exs:75-166` *claims* migration redacts ("the migrate task redacts user/assistant content at the storage boundary") but uses a fixture that is already scrubbed, so its `refute content =~ ~r/sk-.../` passes trivially. Change the fixture to a raw `sk-...` key and the test will fail, exposing this finding.

**Fix:** Add `RedactContent` to the `:import` action (or redact in the migrator before `Message.import/1`), and fix the test fixture to actually exercise it.

### H9. Forge's secret env-scrubbing denylist has exploitable gaps ✓ verified

**Where:** `lib/jido_claw/security/redaction/env.ex:40-42, 127-131` (consumed by every `System.cmd`/Port spawn in `forge/runner/host_shell.ex` and `forge/sandbox/docker.ex`)

**What:** `System.cmd`'s `:env` option *merges with* the inherited parent environment; scrubbing only unsets keys matching `~r/_(KEY|TOKEN|SECRET|PASSWORD|PASS|PAT)$/i`, `~r/^(AWS_SECRET_.*|AWS_SESSION_TOKEN|DATABASE_URL|DB_URL)$/i`, or an exact lowercase list. Confirmed misses: `SECRET_KEY_BASE` (ends `_BASE`) and `ONECLI_AGENT_TOKENS` (plural; regex anchors `_TOKEN$`). Any unconventionally-named host secret is inherited verbatim by every sandbox — including the **default** `:local`/HostShell backend that runs LLM-driven `claude`/`codex` CLIs.

**Fix:** Build the child env as an explicit allowlist instead of inherit+denylist. Failing that, broaden the suffix set (`_TOKENS`, `_BASE`, `_CREDENTIALS`) and also scrub by *value* (run inherited values through `Patterns.redact/1`, unset on change).

---

## HIGH — reliability / correctness

### H10. AgentTracker never prunes terminal agents → spawn cap permanently consumed ✓ verified

**Where:** `lib/jido_claw/agent_tracker.ex:262-269, 300-337`, `lib/jido_claw/tools/spawn_agent.ex:153-182`

**What:** `child_count/1` counts every non-main entry regardless of status. `mark_complete` and the `:DOWN` handler only flip `status`/`finished_at` in place — nothing ever `Map.delete`s an entry, there is no sweep, and `reset/0` has zero production callers (verified by grep). `enforce_spawn_limits/2` gates on `current_children >= max_children` (default 8). Net effect: after **8 cumulative spawns** in a scope — even fully sequential, all `:done` — every further `spawn_agent` fails with `:max_children` until the OS process restarts, and the `agents` map grows unboundedly over long sessions.

**Fix:** Count only `status == :running` in `child_count`, evict entries on `:DOWN`, and add a TTL sweep for `:done`/`:error` entries.

### H11. Context compactor is not exception-safe — a raise crashes the live agent turn ✓ verified

**Where:** `lib/jido_claw/reasoning/compactor.ex` (zero `rescue`/`catch` in the file — verified), `lib/jido_claw/agent/defaults.ex:73-80`

**What:** AGENTS.md and the moduledoc promise compaction "never blocks the agent's forward progress," but the `Defaults` hook only compensates for `{:ok,_}`/`{:error,_}` *return values*. `maybe_compact/3` has no `try/rescue`: `Storage.latest` and `load_slice_count` run uncaught, and `Reasoning.Telemetry.with_compaction` deliberately **reraises** exceptions. A raised `DBConnection`/pool error under load propagates through `on_before_cmd` and crashes the agent's ReAct turn.

**Fix:** Wrap the non-`:off` body of `maybe_compact/3` in `try/rescue/catch` that logs + emits an error Trace event and returns `{:ok, action}`, mirroring `Reasoning.Telemetry.with_outcome/4`.

### H12. Session metadata: non-atomic writers clobber the atomic compaction snapshot ✓ verified

**Where:** `lib/jido_claw/conversations/resources/session.ex:124-138, 162-177`

**What:** `set_compaction_snapshot` is correctly atomic (single-key `jsonb_set` via an `atomic/3` change). But `set_prompt_snapshot` and `set_current_agent_template` are `require_atomic?(false)` function changes that read the **loaded record's** `metadata`, mutate in memory, and `force_change_attribute(:metadata, full_map)` — replacing the entire column. A handoff's `set_current_agent_template` (loaded before any `compactions` key existed) committing after a concurrent compaction write silently drops the snapshot. The AGENTS.md "two agents persisting different keys concurrently both survive" claim holds only for compaction-vs-compaction.

**Fix:** Convert both writers to single-key `jsonb_set` atomic changes on the same pattern as `SetCompactionSnapshot`.

### H13. `ShellSessionServer` patch dropped `trap_exit` → leaked SSH connections on teardown ✓ verified

**Where:** `lib/jido_claw/core/jido_shell_session_server_patch.ex` (zero `trap_exit` occurrences) vs `deps/jido_shell/lib/jido_shell/shell_session_server.ex:98` (pinned ref `bace81a` has it)

**What:** The patch was forked from an older jido_shell than the pinned ref and omits `Process.flag(:trap_exit, true)` plus the `{:EXIT, _, _}` handle_info clause the dep added specifically so `terminate/2 → Backend.SSH.terminate/1` runs on supervised shutdown. Every `stop_session`/`drop_sessions`/`invalidate_ssh_sessions`/project-dir-drift rebuild now kills the session without closing the underlying `:ssh` connection process (separately supervised, not linked) — one leaked SSH connection per teardown. `test/jido_claw/shell/session_manager_ssh_test.exs:532-534` even documents the divergence.

**Fix:** Re-port `trap_exit` as the first line of the patched `init/1` and the `{:EXIT, _pid, _reason} -> {:noreply, state}` clause, restoring equivalence to the shadowed dep version.

### H14. Telegram channel adapter is non-functional ✓ verified

**Where:** `lib/jido_claw/platform/channel/telegram.ex:29`, `lib/jido_claw/platform/channel/worker.ex:56-84`

**What:** `Telegram.connect/1` does `send(self(), :poll)` (self = the `Channel.Worker` process) and the moduledoc says polling is "called via handle_info in Worker" — but the worker has only `:connect` and `{:inbound, _}` clauses and no catch-all. The stray `:poll` raises `FunctionClauseError` (crashing the worker) or, at best, the poll loop never runs; `Telegram.poll/1` has no caller. Telegram receives no messages either way.

**Fix:** Add the poll loop to `Channel.Worker` (handle `:poll`, call `adapter.poll/1`, dispatch updates through `handle_inbound`, re-arm with `Process.send_after`), or move polling into the adapter's own process.

### H15. Forge timeout/brutal-kill orphans OS grandchildren — high|medium confidence

**Where:** `lib/jido_claw/forge/runner/host_shell.ex:133`, `lib/jido_claw/forge/sandbox/docker.ex:249`; same class in `lib/jido_claw/shell/backend_host.ex:128`

**What:** Commands run as `sh -c <command>`. `Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill)` kills the BEAM task and closes the port, which at best SIGKILLs the immediate `sh` — the grandchild (the actual `claude`/`codex`/user command) is reparented and keeps consuming CPU/memory past the timeout with no reaper.

**Fix:** Spawn via a process-group wrapper (`setsid` + kill the negative pgid on timeout), or `exec` in the shell string so no intermediate `sh` remains, and kill via `Port.info(port, :os_pid)` on the timeout branch.

### H16. Folio resources have no authorization — any user reads every user's data ✓ verified

**Where:** `lib/jido_claw/folio/project.ex`, `lib/jido_claw/folio/action.ex`, `lib/jido_claw/folio/inbox_item.ex` (verified: zero `authorizers`/`policies` in all three; plain `use Ash.Resource`)

**What:** The read actions filter only on `status`, never `user_id`. `FolioLive.mount` passes `actor:`, but with no authorizer it is inert — every authenticated web user sees (and can mutate) every other user's inbox items, next-actions, and projects.

**Fix:** Add `authorizers: [Ash.Policy.Authorizer]` and policies scoping reads/writes to `actor.id == user_id` (or filter the read actions by `^actor(:id)`).

---

## MEDIUM

### Secrets / redaction

- **M1. `Memory.Block` content is never redacted** — `lib/jido_claw/memory/resources/block.ex:134-153`. `Fact.record` runs `RedactContent` (fact.ex:177); Block's `:write` runs validation/cap changes only (✓ verified). Blocks are the one tier rendered verbatim into the system prompt every turn (`agent/prompt.ex:263`), so a secret curated into a block reaches the provider in plaintext. `Security.Redaction.Memory`'s own moduledoc says it covers Blocks. Add `RedactContent` to `:write` and the revise path.
- **M2. Logger *metadata* is never redacted** — `lib/jido_claw/security/redaction/log_redactor.ex:18-35`. The filter rewrites only `event.msg`; `Logger.metadata(api_key: key)` or structured Logger calls pass secrets to backends unscrubbed. Map over `event.meta` too, keyed by `Redaction.Env.sensitive_key?/1`.
- **M3. Forge Docker `inject_env` writes resolved secrets to host disk in cleartext** — `lib/jido_claw/forge/sandbox/docker.ex:151`. `<workspace_dir>/.forge_env` is written at default umask, lives for the session, and is only removed by `destroy` — a crash before `terminate` leaves cleartext secrets under `/tmp/jidoclaw_forge`. Values are also not newline-escaped (env-file line injection). Write mode 600, reap independently of `terminate`, reject/encode newlines.
- **M4. Trace sanitizer omit-list misses content-bearing keys** — `lib/jido_claw/trace/sanitize.ex:25-43`. `@large_keys` omits `messages`/`prompt`/`params`/`response` etc. but not `content`, `text`, `thinking_content`, `output`, `input` — keys jido_ai's turn shape uses. First-party `Trace.emit` sites are clean (verified by the reviewer), so this is defense-in-depth against upstream emitters. Add the content keys or run trace metadata through `Redaction.Transcript`.

### Correctness / reliability

- **M5. Concurrent same-`(scope,label)` memory write silently drops the newer value** — `lib/jido_claw/memory.ex:276-290` (✓ verified). The duplicate-key branch logs at debug and returns `:ok`; the `InvalidatePriorActiveLabel` moduledoc claims a `{:error, :duplicate_key}` caller-retry path that does not exist anywhere. Re-run `do_remember` once on a duplicate-key conflict, and fix the doc.
- **M6. `WorkflowView` omits `:abandoned` from terminal statuses** — `lib/jido_claw/workflow_view.ex:15` (✓ verified). Abandoned runs (a real terminal status) appear in neither `active_runs` nor `recent_completions`, so they vanish from the MCP `workflow_status` tool and `inspect_agent`; the dashboard (`workflows_live.ex:14`) gets it right. Add `:abandoned`.
- **M7. Durable `trace_runs`/`trace_events` grow without bound** — `lib/jido_claw/trace/persistence.ex`. The in-memory ring is capped (100 traces × 300 events) but every event with `persist?: true` (prod default, `config.exs:242`) writes rows, and no prune/retention exists anywhere in the tree. Add a retention sweeper on the existing cron machinery.
- **M8. Workflow step/run payloads persisted unbounded into the append-only log** — `lib/jido_claw/orchestration/reactor_middleware.ex:204, 339`. Full LLM-text step results land in `WorkflowEvent.payload` (redacted but never truncated); recovery/replay/retract all re-read `for_run`. Cap payload bytes at append time in `Allocate`.
- **M9. Discord/Telegram hardcode the `"default"` tenant** — `lib/jido_claw/platform/channel/discord.ex:49-52`, `telegram.ex:47-50`. All external-channel traffic collapses into one tenant/session namespace despite the worker carrying a real `tenant_id`. Thread the worker's tenant (and per-author user) through `handle_inbound`/`chat`.
- **M10. Discord/Telegram send failures swallowed; no message-size handling** — `discord.ex:64-75`, `telegram.ex:53`. `Message.create` result ignored (Discord rejects >2000 chars); Telegram uses `parse_mode: "Markdown"` on unescaped agent text (400s on stray `_`/`*`). Check returns, chunk to platform limits, drop/escape Markdown.
- **M11. Cron `:at` jobs re-fire on every restart; `:cron`/`:every` miss fires while down** — `lib/jido_claw/platform/cron/worker.ex:244-254`. `next_run` is recomputed from the clock at `init` and never persisted; a past one-shot clamps delay to 0 and fires on each boot (restart loop ⇒ repeated execution). Persist last-fired/next-run; skip and disable elapsed one-shots.
- **M12. Reputation migration double-counts on interrupted re-run** — `lib/mix/tasks/jidoclaw.migrate.solutions.ex:239-267`. Per-row counters are *summed* into existing rows but the SHA idempotency record is written only after the full reduce; a mid-run crash means re-running re-sums everything. Record the SHA in the same transaction, or make per-agent merges idempotent.
- **M13. No CPU/memory limits on HostShell; unbounded output buffering** — `lib/jido_claw/forge/runner/host_shell.ex:40, 75`, `docker.ex:74`. The default consolidator path runs LLM CLIs with no `ulimit`/cgroup and `System.cmd(..., stderr_to_stdout: true)` accumulates entire stdout in BEAM memory (truncation to 10KB happens only at DB-persistence time). Cap output at the port-read layer; wrap HostShell in `ulimit`; prefer Docker when secrets are present.
- **M14. Trace Collector rebuilds all indexes on every event** — `lib/jido_claw/trace/collector.ex:288-312, 600-658`. `record_event/4` calls `rebuild_indexes/1` (full reduce over all traces) per event, plus O(n) `append_order`; all tenants' events serialize through one GenServer. Bounded by `max_traces: 100` but a hot-path bottleneck under swarm load. Maintain indexes incrementally.
- **M15. `ResearchCoordinator` rescue cannot catch the failure it documents** — `lib/jido_claw/github/agents/research_coordinator.ex:14, 27-32`. `Task.await_many/2` **exits** on task crash/timeout; `rescue` never fires (masked today because sub-tasks are stubs). Use `try/catch :exit` or `Task.yield_many` + `Task.shutdown`.
- **M16. Internal error reasons leaked verbatim to API/RPC clients** — `lib/jido_claw/web/controllers/chat_controller.ex:74,122`, `rpc_channel.ex:73,97`. `inspect(reason)` returns raw Ash/exit terms to authenticated-but-untrusted callers. Log server-side; return a stable generic error code (the webhook controller already does this right).
- **M17. Sub-agent orchestration runs in a bare unsupervised `spawn`** — `lib/jido_claw/tools/spawn_agent.ex:88` (similarly `send_to_agent.ex:50`). If the orchestrator process dies outside `SubagentTranscript.run/5`'s rescue (e.g. in `record_task`/`record_result`), `mark_complete` never fires and the tracker entry strands as `:running` (compounding H10). Use a `Task.Supervisor` with a monitor forcing terminal state.
- **M18. "Semi-formal verification" confidence is LLM self-graded and flows into trust at 0.85 weight** — `lib/jido_claw/tools/verify_certificate.ex:218-227`, `lib/jido_claw/solutions/trust.ex:158-164`. The certificate's `confidence` is whatever the model emitted (range-checked only); even a `FAIL` verdict with high confidence scores `c * 0.85`. Gate `semi_formal` trust on `verdict == "PASS"` and/or cap its contribution well below `passed`.

---

## LOW

- **L1. Tenant registry resource is default-allow for all action types** — `lib/jido_claw/tenants/resources/tenant.ex:37-41`. Documented as deferred to v0.7+, but combined with H1 it is a live cross-tenant lever (suspend/archive another tenant).
- **L2. `.env` parser does not strip `export ` prefix** — `lib/jido_claw/application.ex:453-468`. `docs/SETUP.md` and README show `export FOO=...` lines; pasting those into `.env` silently fails to set the key.
- **L3. Byte-boundary truncations can emit invalid UTF-8** — `lib/jido_claw/forge/persistence.ex:598` (`binary_part` tail-slice; Postgres rejects the row, silently dropping the exec record) and `lib/jido_claw/agent/handoff/router.ex:537` (clamp bypasses `OutputLimit.valid_utf8_prefix/1`). Cut on codepoint boundaries.
- **L4. Terminal escape-sequence injection** — `lib/jido_claw/cli/formatter.ex:9-14`, `lib/jido_claw/display.ex:583-600`, `cli/commands.ex:223-224,360-361`. Model output, streamed shell chunks, and memory/solution rows print raw — crafted content can move the cursor, clear the screen, or spoof a fake `jidoclaw>` prompt. Strip C0/C1 + CSI/OSC at the print chokepoints.
- **L5. `recall` blocks the agent turn on a synchronous Voyage HTTP call with no explicit timeout** — `lib/jido_claw/memory/retrieval.ex:74,130-147`. Inherits Req's ~15s default; degrades correctly to FTS+lexical on failure. Set a 3–5s `receive_timeout`.
- **L6. Voyage embedding dimension never validated before the DB write** — `lib/jido_claw/embeddings/backfill_worker.ex:325-345`. A non-1024 vector raises in `Repo.query!`, is swallowed by the dispatch rescue, and the row retries forever without consuming attempts. Validate length and route through `on_failure`.
- **L7. `duplicate_key?/1` classifies conflicts by substring-matching `inspect(err)`** — `lib/jido_claw/memory.ex:317-327`. Brittle against Ash error-rendering changes; would also defeat any retry added for M5. Match structured error fields.
- **L8. Boot recovery resumes stranded runs strictly sequentially with no per-run timeout** — `lib/jido_claw/orchestration/workflow_recovery.ex:102`. One blocking downstream step stalls reconciliation of all later stranded runs on the node.
- **L9. Replay re-persists arbitrarily large decoded inputs** — `lib/jido_claw/orchestration/replay.ex:343`, `reactor_runner.ex:226`. Same family as M8; operator-triggered, loopable. Guard serialized blob size before `create_run`.
- **L10. `read_file` loads the whole file before applying offset/limit** — `lib/jido_claw/tools/read_file.ex:53-56`. No read-side size cap (writes cap at 5MB); a multi-GB file exhausts the heap before `OutputLimit` runs. Check `File.stat` size or stream with early cap.
- **L11. `run_command`'s model-controllable `workspace_id` fallback** — `lib/jido_claw/tools/run_command.ex:91-94`. `tool_context.workspace_id` correctly wins; only when context lacks it can the model's param select another session's persistent shell (cwd/env crosstalk; FS jail still applies). Derive from `session_id` instead.
- **L12. `Handoff.error_to_string/1` is a partial function (binary-only)** — `lib/jido_claw/tools/handoff.ex:389-390`. All current error paths return strings; any future non-binary reason raises *inside the failure-telemetry handler*. Add an `inspect/1` fallback clause.
- **L13. Status tools declare `required: true` output fields that can be `nil`** — e.g. `lib/jido_claw/tools/network_status.ex:32-37`, `agent_status.ex:84-90`. Contract is misleading for downstream consumers. Coalesce or drop `required`.
- **L14. Handoff preamble interpolates agent-authored text into a fixed delimiter block without escaping the closing marker** — `lib/jido_claw/agent/handoff/router.ex:185`. Contained prompt-injection surface (byte-capped, agent-internal). Escape or randomize the fence.
- **L15. Spawned/handed-off agents are `restart: :permanent` and never stopped after their task** — `lib/jido_claw/tools/spawn_agent.ex:56`. Finished agents persist (feeding H10); a crashed finished agent is pointlessly resurrected. Stop after the terminal transcript row, or use `restart: :temporary`.
- **L16. Webhook controller hard-matches a fallible body read** — `lib/jido_claw/web/controllers/webhook_controller.ex:10`. `{:ok, raw_body} = CacheBodyReader.raw_body(conn)` raises `MatchError` (opaque 500) if the cache plug didn't run. Handle `{:error, :not_cached}` with a 400.
- **L17. `IssueCommentClient` posts with an empty Bearer token instead of failing fast** — `lib/jido_claw/github/issue_comment_client.ex:9-19,34-36`. Also a default-arg subtlety: explicit `github_token: nil` config overrides the env var. Return `{:error, :no_github_token}` when blank.
- **L18. Network request opts atomized then merged into Matcher options** — `lib/jido_claw/network/node.ex:315-327`. `String.to_existing_atom` is rescue-guarded (no atom DoS), and `scope_opts` append-order protects tenancy, but a peer can inject arbitrary *known* option atoms. Whitelist permitted request-option keys.
- **L19. `Desktop.Sidecar` is dead code that would set `check_origin: false`** — `lib/jido_claw/desktop/sidecar.ex:22-42`. No callers (verified); also `String.to_integer(JIDOCLAW_PORT)` crashes on non-numeric input. Delete or guard before wiring up.
- **L20. Session worker mirrors full chat history in memory with O(n²) append** — `lib/jido_claw/platform/session/worker.ex:212` (`messages ++ to_view(message)`, never trimmed). Cap to a recent window; cold reads already hit Postgres.
- **L21. `BackgroundProcess.Registry` is started but unused, with latent reaping bugs** — `lib/jido_claw/platform/background_process/registry.ex:133-190`. Nothing calls register/deregister; cleanup keys on `started_at` (not finish time) and no path sets `:exited`. Fix when wiring up.
- **L22. `Platform.Approval.check/3` spec advertises a `{:pending, reference()}` return that never occurs** — `lib/jido_claw/platform/approval.ex:17-35`. The call blocks up to ~125s and returns bare atoms; the async-looking contract misleads callers.
- **L23. `:policy_denied` audit emission is self-amplifying against deny-by-default resources** — `lib/jido_claw/audit/ash_tracer.ex:81-145`. Each denied probe on `forbid always()` resources spawns a Task + DB write. Rate-limit or skip statically-forbidden denials.
- **L24. Forge codex MCP-URL interpolated into TOML without escaping; `extra_mounts`/`bootstrap_steps` unvalidated** — `lib/jido_claw/forge/runners/codex.ex:135`, `forge/sandbox/docker.ex:376-392`. Operator-supplied today (no live exploit); validate before Forge becomes reachable from untrusted tool calls.
- **L25. `/cron add` accepts unbounded interval values** — `lib/jido_claw/cli/commands.ex:1635`. Regex-guarded parse (no crash) but `every 999999999999999d` persists unvalidated. Add a sanity cap.

---

## Strengths worth preserving

- **Workflow state machine** (`orchestration/`) — single projection-owned writer, per-run `FOR UPDATE` serialization, transition legality checked *before* persistence, exhaustive `(status, checkpoint)` crash-recovery classification, multi-approver and retract-vs-resume races fenced in the database. Replay overrides correctly confined to the dashboard: the MCP `replay_workflow` tool exposes no `force`/`allow_irreversible` (AGENTS.md claim verified), and the namespace-fenced `to_existing_atom` checkpoint decode is genuinely adversarial-minded.
- **Compactor persistence** (`reasoning/compactor/`) — the `SetCompactionSnapshot` atomic `jsonb_set` has no read-modify-write window; the multi-agent coherence test proves concurrent per-key writes don't clobber each other (the gap is the *other* metadata writers, H12). Summarizer failure isolation (async_nolink + hard timeout + retry classification) is exemplary.
- **Path-jail** (`vfs/resolver.ex`) — realpath-based symlink resolution with a depth cap and real-root containment for both reads and writes (nearest-existing-ancestor walk for new files), independently re-normalized by jido_shell. Verified against absolute-path, `..`, and symlink escapes. This closes the May audit's C3.
- **Centralized tool output hygiene** (`tools/action.ex`) — every tool result flows normalize → redact → truncate; `Error.sanitize_details/1` closes the struct-leak gap. This closes the May audit's C1.
- **Memory retrieval** (`memory/hybrid_search_sql.ex`) — scope/source dedup applied *before* the per-pool limit inside SQL with documented rationale; all raw SQL uniformly `$N`-bound with compile-time allowlisted identifier interpolation.
- **Supervision tree** (`application.ex`) — child-ordering invariants documented inline and correct; `rest_for_one` used precisely where lower children depend on higher ones; boot initializers `restart: :transient`; LogRedactor installed before `.env` load.
- **Security primitives where it counts** — GitHub webhook HMAC via constant-time `secure_compare` with length guard, signature-before-parse; Cloak vault key bootstrap validates base64+length and raises on missing/invalid with no silent fallback; no `String.to_atom` or `:erlang.binary_to_term` on external input anywhere (every conversion site uses guarded `to_existing_atom`); `Cron.NextRun` DST gap/ambiguity handling is textbook.
- **Test discipline** — 2487 tests including dedicated suites for path-jail escapes, compaction coherence across agents, SSH error classification, DST transitions, trust scoring branches, and redaction patterns.

---

## Suggested priority order

1. **H1 + H2** — gate the admin surface and fix the WebSocket origin default (small diffs, eliminate the exposed privileged surface).
2. **H10 + H11 + H12** — agent-loop reliability: spawn-cap lockout, compactor exception safety, metadata clobber (all small, well-localized fixes).
3. **H7 + H8 + H9 + M1 + M2** — the secrets cluster (chmod, import redaction, env allowlist, block redaction, logger metadata).
4. **H13 + H14 + H15** — patch drift, Telegram wiring, process-group reaping.
5. **H4 + H5 + H6** — before ever enabling clustering: peer verification, gossip secret, trust-score hardening.
6. Mediums opportunistically; the migration/CLI ones (M11, M12) before the next data migration; M7/M8 before long-running production use.

## Appendix: per-subsystem notes

One-line test-coverage/risk impressions from the subsystem reviews:

| Subsystem | Quality | Coverage notes |
| --- | --- | --- |
| security/accounts/audit | Strong; honest documented trade-offs | Vault, redaction patterns, async writer, actor classifier all tested |
| forge | Defense-conscious; runner/sandbox split clean | Thin on failure/timeout/leak paths; denylist untested for odd secret names |
| tools | Macro pipeline is the standout | 26 test files incl. dedicated path-jail escape suites |
| agent layer | Defaults/Compactor composition verified correct end-to-end | AgentTracker and Heartbeat have no dedicated tests |
| reasoning | Disciplined; AGENTS.md compaction claims hold (except H11) | 27 test files; no projected tool-pair transformer test |
| memory/embeddings | Mature bitemporal design; SQL precedence correct | No dedicated `hybrid_search_sql` or `memory.ex` recall/forget tests |
| orchestration | Exceptionally engineered event-sourced SM | ~4.2k test lines across 14 files |
| CLI/mix tasks | Good error boundaries; real Display backpressure | Export test gives false redaction assurance (H8 note) |
| shell/core patches | ETS-mirror deadlock avoidance exemplary; anubis patch safe | trap_exit drift documented in a test rather than fixed |
| web | Auth defense-in-depth on mutating events | RpcChannel/UserSocket, WorkflowsLive, RequireAuth untested |
| platform/conversations/cron | Conversations + cron strong; channel adapters scaffolding-grade | Channel adapters and Folio have no tests |
| solutions/trace/error | Error taxonomy exemplary; trust pure-logic well tested | Trust *integrity* (who may assert it) is the gap, not the math |
| infra/network | Supervision tree careful; webhook textbook | Network layer has stubbed security boundaries (H4/H5) |
