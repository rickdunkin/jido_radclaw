# Features Worth Borrowing from agentos (+ secure-exec)

Exploration notes — not a plan, not a commitment. Deep-dive **2026-07-03**, fulfilling the
sandbox landscape scan's "track, don't adopt" follow-up for agentos. **Two subject repos**:
`~/workspace/research/sandboxes/agentos` (rivet-dev/agentos, HEAD `43c30e5`,
v0.2.0-rc.3) and — cloned mid-review once it became clear the actual VM lives there —
`~/workspace/research/sandboxes/secure-exec` (rivet-dev/secure-exec, detached at
`94f540b3`, v0.3.0-rc.1: **the exact sha agentos's `.github/refs/secure-exec` pins**, so
this review reads precisely what this agentos checkout builds against). jido_radclaw at
`0717a0f6`. Cites are firsthand reads of both trees, accurate to within a few lines;
**nothing was installed or executed** — every latency/benchmark number below is from the
subjects' own committed artifacts, not our runs.

Self-description: *"A portable open-source operating system for AI agents. Near-zero cold
starts (~6 ms) … Built-in ACP agents: Pi, Claude Code, and OpenCode."* Shape: agentos is a
TS+Rust monorepo (~75k TS / ~30k Rust LOC) that is the **ACP/session/product wrapper**;
secure-exec (~294k Rust / ~109k TS) is the engine — a Rust "OS kernel" (VFS, process
table, socket table, PTY, permissions) hosting guest code in **in-process V8 isolates and
V8-executed WASM**, exposed through a native `agentos-sidecar` binary speaking
length-prefixed BARE frames over stdio. Maturity: rc-stage both repos; essentially
single-author (Nathan Flurry: 178/194 and 1,381/1,442 commits); very active (both HEADs
committed the day before this review, 7 seconds apart — lockstep repos); Apache-2.0;
protocol v7 with an explicit no-backwards-compat doctrine. Coverage note: the sidecar's
24k-line `execution.rs` (real-socket egress, host_dir mount plugins) was read only at its
seams; registry native build internals and rivetkit internals were skimmed, not audited.

Companion docs: the [sandbox landscape scan](../README.md) (this answers its category-3
item and corrects it in both directions); [nono](../nono/FEATURES-WORTH-BORROWING.md)
(the host-tier containment program — N2-2 phantom credentials beats agentos's
raw-key-in-VM-env story outright, and AO2-4 below composes with N2-3 denial legibility);
[pi-sbx-llamacpp](../pi-sbx-llamacpp/FEATURES-WORTH-BORROWING.md) (AO2-5 folds into its
PS1-x `allowedDomains` spike as the default-posture half; AO2-3's transport question
rides its PS1-2 host-reach spike);
[coderunner](../coderunner/FEATURES-WORTH-BORROWING.md) (CR2-1's stateful-executor
pattern is the same "durable agent session" itch AO1-1/AO1-2 scratch at the runner
tier); [openshell](../openshell/FEATURES-WORTH-BORROWING.md) (dug the same day — its
OSH1-1 ladder independently lands AO2-5's deny+provider default, recorded in both docs
as the corpus's two-subjects-converging signal, and its OSH1-3 audit rubric is the
store-discipline sibling of AO1-1's transcript rows); and
[crabbox](../crabbox/FEATURES-WORTH-BORROWING.md) (same day — its `timing-safe-auth` CI
needle-test is a second subject data point for AO2-1's guard pattern, crabbox S-6).
Threat model as always (personal, tailnet-only): LLM-misbehavior containment +
secret/data leakage hygiene, not hostile multi-tenant isolation.

## Determination (TL;DR)

**SKIP as a dependency, on three independent grounds — but the richest concept donor in
the sandbox corpus.** The scan's verdict ("concept donor; awkward embed for BEAM; track
the escalation-ladder pattern") survives with its **reasons substantially rewritten**:
the embed is *not* awkward for the reason given (agentos is not "an npm package" — a
native sidecar + a 1:1 Rust client prove non-JS hosts can drive it), and the celebrated
escalation ladder mostly *isn't one* (the "sandbox extension" is manual composition of an
external container, and "~6 ms cold start" is VM-object allocation, not
time-to-first-exec — their own committed benchmark says 772 ms p50 for that). What
actually survives contact is better than what the scan admired: a **transcript
architecture** that names our sharpest verified gap (we parse agent events in Forge
runners, then throw them away), and an **engineering-discipline layer** (CI-enforced
architecture guards, compile-breaking default-deny tests, bounded-by-default limits with
an inventory audit) that is cheap to lift because we already own the house pattern it
extends.

| Part of agentos/secure-exec | As a dependency? | What to take |
| --- | --- | --- |
| VM core (kernel, V8 isolates, WASM commands) | **SKIP** — wrong tier: in-process language-VM walls under our sbx microVMs; host-jailing is *their* "planned layer" and nono already owns that rung for us | The guard-test discipline around it (AO2-1, AO2-2) |
| Native sidecar + BARE stdio protocol | **SKIP** — drivable from the BEAM in principle, but versionless lockstep (v7 + bridge v1 exact match, positional BARE tags, no codegen shipped) = a treadmill against a single-author rc protocol | Nothing; our MCP stdio transport already *is* the Port+scrubbed-env supervision shape it would need |
| ACP transcript chain (normalize → seq → append-only → replay) | No | **AO1-1** — persist the runner events we already parse |
| Tiered session resume (native → transcript-reconstruction preamble) | No | **AO1-2** — the missing half of Forge wake |
| Bindings (host fns as in-VM CLI commands) | No | **AO2-3** — generalize our consolidator precedent, pattern only |
| OS-instructions prompt injection | No | **AO2-4** — tell in-sandbox agents where they are |
| Default egress = LLM-provider allowlist | No | **AO2-5** — FOLD-IN to the planned sbx `allowedDomains` work |
| CI guards: architecture needle-scan, default-deny compile-breaks, limits inventory, bench baselines | No | **AO2-1, AO2-2, AO3-3** — the most borrow-per-line here |
| Cron / queues / workflows / webhooks / multiplayer / mounts | No | ALREADY-COVERED (S-1..S-3) |
| Sandbox extension, ACP-as-our-protocol, registry packaging, browser/wasm | No | SKIP with corrections recorded (S-4..S-9) |

## Why not adopt — and what the scan got wrong in both directions

1. **Wrong isolation tier, by their own doctrine.** The trust model (agentos root
   `CLAUDE.md`, Security Model) is client / sidecar-TCB / executor-adversary, with
   isolation "layered … like Cloudflare Workers" and **"host-level jailing (sandboxing
   the process itself) is a planned additional layer."** Guest code is confined by V8/WASM
   virtualization inside the host process. Our baseline is already a separate kernel (sbx
   microVMs, `docker.ex`), and the tier we actually lack — host-OS containment — is
   nono's, verdict already ADOPT-AS-TOOL. Adopting agentos as a Forge backend would trade
   isolation *down* to gain a speed that (below) is smaller than advertised.
2. **The honesty ledger cuts both ways — which is itself the maturity finding.** Against
   the README: (a) *"Deny-by-default permissions for filesystem, network, and process"* —
   false at the SDK layer for fs/childProcess/process/env/binding; the client default is
   allow-all with the in-code rationale "the VM is itself the isolation boundary"
   (`crates/client/src/agent_os.rs:1291-1314`; TS mirror `agent-os.ts:2905-2908`), and
   omitted axes default allow even when a policy is passed (`agent_os.rs:1235-1288`).
   Only network is deny-by-default. (b) *"~6 ms"* cold start — their committed
   `coldstart-final.json` (secure-exec `packages/benchmarks/results/`) shows sidecar
   spawn 2.8 ms and `vm_create` 1.4 ms, but WASM runtime mount 173 ms and **first exec
   596 ms → cold-start-to-first-exec p50 = 772 ms**; WASM command tax vs host runs
   15–856× (`ls_100` 86×, `sh_pipeline` 139×, `git_init_commit` 128×, `find_1000` 856×).
   (c) actor `close_session` **deletes** the persisted transcript
   (`agentos-actor-plugin/src/actions/session.rs:441-452`) while three doc sites say it's
   kept; actor `resume_session` is unimplemented (`session.rs:592-630`). **In the other
   direction**: agentos's own `crates/CLAUDE.md:8` warns the Node engine is "CURRENTLY
   BROKEN (spawns real host `node` …)" — **stale at the pin**. At `94f540b3` guest
   node/npm/npx run inside the shared in-process V8 runtime (npm's own JS is re-rooted
   into the guest and its registry fetches routed through the kernel socket table,
   `sidecar/src/execution.rs:10414-10469`), the cited deletion commit isn't even in this
   repo's history, and the invariant is CI-enforced (`architecture_guards.rs` bans
   `Command::new`/`tokio::process` with a two-file allowlist). A system whose docs lag
   its code in both directions is moving fast — impressive, and exactly what you don't
   build a dependency on at rc-stage with one author.
3. **The BEAM-embed question, finally settled with evidence.** The scan's *reason* was
   wrong: the sidecar is a standalone native binary (prebuilt darwin/linux ×
   x64/arm64; `AGENTOS_SIDECAR_BIN` override), spoken over stdio in 4-byte-BE
   length-prefixed BARE frames, and `crates/client` is a 1:1 Rust port proving non-JS
   drivability end-to-end (`crates/client/src/lib.rs:5-16`, e2e tests spawn a real
   sidecar). Structurally that is *exactly* our patched MCP stdio transport shape
   (`mcp_stdio_transport_patch.ex:241-259` — Port, scrubbed env, supervised restart). The
   scan's *conclusion* still holds on new grounds: the protocol is deliberately
   versionless — "clients and the sidecar ship in same-version lockstep … never add
   protocol or config versioning" (agentos `CLAUDE.md`), enforced twice (per-frame schema
   name+version check and an Authenticate handshake requiring protocol v7 **and** bridge
   contract v1 exactly, `wire.rs:1145-1153`, `frames.rs:60-79`) — and the 846-line `.bare`
   schema uses **positional union ordinals** with JSON-config blobs embedded in BARE
   strings and a mandatory reverse-callback channel. Hand-maintaining an Elixir codec
   against that, with no codegen shipped, is a treadmill for a backend we don't want
   anyway.
4. **The credential story is behind what we already have planned.** Raw API keys enter
   the VM env by design ("the agent inside the VM sees the key via its environment,"
   `examples/llm-credentials/README.md`; no proxy/phantom machinery anywhere in either
   tree). Mitigations that do hold: the VM never inherits host `process.env`, and default
   egress is deny + a four-host LLM allowlist. nono N2-2 (phantom tokens) strictly beats
   this; AO2-5 takes the one good idea (the default posture).
5. **Fidelity walls for real coding work.** The in-VM toolchain is reimplementations:
   uutils coreutils, brush shell, **a minimal clean-room Rust git** (`sha1`+`flate2`,
   "Minimal git implementation" — not gitoxide, not upstream), no signals (`kill` is a
   stub), no job control, `find` ~50%. A Claude Code doing real repo work inside it hits
   walls our sbx microVMs (real Linux userland) don't have.

**What deserves respect** (and shapes the borrow list): the *kernel* is genuinely
fail-closed — absent callbacks deny, pinned by compile-breaking exhaustive-match tests
(`crates/kernel/tests/default_deny_guards.rs:43-97`); the marketed gap is the SDK
default, not the kernel. The PTY layer is substantially real termios (ISIG→SIGINT,
canonical mode, erase/kill — `kernel/src/pty.rs:950-1177`). The metadata-IP classifier
defeats IPv4-mapped-IPv6 bypasses (`::ffff:169.254.169.254`,
`kernel/src/network_policy.rs:34-84`) — a detail for our N2-4/PS1 spec. And the
engineering-discipline layer (guards, limits audit, bench gates) is CI-enforced, not
aspirational. That discipline is the most transferable thing in either repo.

## How to read this document

Recommendations per the corpus vocabulary: **BORROW-PATTERN**, **FOLD-IN**,
**BORROW-RUBRIC**, **TRACK** (named trigger), **ALREADY-COVERED** (cites the local
equivalent), **SKIP**. No new axes needed. Tiers: **Tier 1** = verified-gap patterns
worth a near-term slice; **Tier 2** = cheap wins and design-gated patterns; **Tier 3** =
parked with triggers. Fields as usual: **Where** (file:line in *their* trees — agentos
paths unprefixed, engine paths prefixed `secure-exec/`), **What**, **Gap in
jido_radclaw** (verified firsthand 2026-07-03), **Why it matters**, **Adoption sketch**.
IDs `AO<tier>-<seq>`; skips `S-n`; open questions `OQ-n`.

---

## Tier 1 — The transcript pair (one program, two entries)

### AO1-1. Persist the normalized agent-event stream Forge runners already produce

**Recommendation**: BORROW-PATTERN — the headline borrow; the gap is verified and the
missing piece is embarrassingly small.

**Where in agentos**: the chain is adapter → normalize to ACP → sequence → append-only →
replay. Per-agent adapters inside the VM normalize each agent's native output into ACP
`session/update` notifications ("every agent type produces the same event shape,"
`website docs agent-sessions.mdx:17,43`); the actor persists them append-only with a
per-session monotone `seq` (SQLite DDL at
`crates/agentos-actor-plugin/src/persistence.rs:27-70`; `MAX(seq)+1` allocation
`:982-1011`); `getSessionEvents`/`listPersistedSessions` replay them **with no VM
running** (`actions/session.rs:458-530`). Event vocabulary: `agent_message_chunk`,
`agent_thought_chunk`, `tool_call`, `tool_call_update`, `current_mode_update`, synthetic
`user_prompt` (`agent-os.ts:3869-3884`, `persistence.rs:1056-1088`).

**What**: one durable, agent-agnostic event log per agent run — the transcript is a
first-class store, not a rendering — so debugging, auditing, comparison, and resume all
read the same rows.

**Gap in jido_radclaw** (verified 2026-07-03): we already *have* the normalization half —
`runners/claude_code.ex:115-149` parses stream-json into `metadata.tool_events`
(tool_use/tool_result/assistant/system + turns), and `runners/codex.ex:215-309` maps
Codex JSONL into the same ClaudeCode-shape events — and then we **discard it**:
`harness.ex:689-697` reads `result.metadata` only for `%{state: …}`, and
`Persistence.record_execution_complete` persists only redacted stdout **truncated to the
last 10 KB** + exit code (`persistence.ex:207-232`). Two disjoint stores exist (Forge
`Event`/`ExecSession` vs `Conversations`), neither receives in-sandbox agent turns; a
Claude Code run inside Forge is invisible to every transcript surface we own.

**Why it matters**: the composer's judgment layer, the dashboard, the eval harness, and
any future "what did the sandboxed agent actually do?" question are all blind at exactly
the tier where autonomy is highest. We paid for the parsers already; the borrow is the
persistence discipline (seq-numbered, append-only, replayable, bounded).

**Adoption sketch**: extend the Forge persistence write path — on `iteration_complete`,
alongside `record_execution_complete`, write `metadata.tool_events` as Forge `Event` rows
(the table is already append-only with `exec_session_sequence`,
`persistence.ex:234-268`): `event_type: "agent.tool_use" | "agent.tool_result" |
"agent.message" | "agent.system"`, data = the parsed event passed through
`Patterns.redact` + a JSON-safe envelope (reuse `TranscriptEnvelope`'s normalization
posture). **Bounded by default** (AO2-2's doctrine applied on arrival): cap events per
iteration and bytes per event, count drops in a final `agent.events_truncated` row —
never silently. Keep the ClaudeCode-shape as the documented schema for now (OQ-1 holds
the ACP-naming question). Non-goal: do not write these into `Conversations.Message` —
that store is the Jido-agent conversation axis; this is the run log. *(Same-day sibling:
[openshell OSH1-3](../openshell/FEATURES-WORTH-BORROWING.md)'s audit-vs-trace rubric is
where the "which store gets what" rule gets written — these rows are the run-log plane,
complementary to its decision-event kinds; the rubric should classify both.)*

---

### AO1-2. Tiered resume: native session resume, else transcript-reconstruction preamble

**Recommendation**: BORROW-PATTERN — rides AO1-1 (the events are the source material).

**Where in agentos**: the ACP extension's resume state machine tries the agent's native
`session/load`/`session/resume` first and falls back to `session/new` + a one-shot
preamble pointing at a Markdown transcript reconstructed from the persisted event log
(`crates/agentos-sidecar/src/acp_extension.rs:836-1177`; renderer
`persistence.rs:1051-1121` — `## User` / `## Assistant` / `### Tool call: <title>
(<status>)`; doc contract `sessions-persistence.mdx:92-137`). The Markdown file is
explicitly disposable — the event log is canonical.

**What**: resume degrades gracefully: when the agent's own session store can't survive
(fresh filesystem, changed id), the conversation continues from *our* durable record
instead of restarting cold.

**Gap in jido_radclaw** (verified 2026-07-03): `Forge.wake/1` re-provisions a **fresh
sandbox** and restores runner state via `restore_state/2` (`forge.ex:48-72`,
`harness.ex:897-947`) — the native tier half-exists (ClaudeCode re-syncs host `~/.claude`
and passes `session_name`/`--name`, `claude_code.ex:80-83,151-217`; Codex runs
`--ephemeral`, `codex.ex:120-124`), but when native resume isn't available there is
nothing: the agent restarts with the original prompt and no memory of prior iterations,
because (AO1-1) we kept only 10 KB of stdout.

**Why it matters**: wake/recovery is exactly when an autonomous run has the most context
worth not losing, and CLI-session stores inside throwaway sandboxes are the least durable
place to keep it. This turns AO1-1's rows into capability, not just observability.

**Adoption sketch**: in the wake path, when `resume_checkpoint_id` is set and the runner
can't (or is configured not to) native-resume: render the persisted `agent.*` events for
that session to Markdown (their renderer is the reference — keep it dumb), `write_file`
it to `<forge_home>/session/transcript.md`, and prepend a one-shot preamble to the next
iteration's prompt ("You are resuming; the prior transcript is at …"). Cap the rendered
size (head+tail elision, same posture as OutputShaper). ClaudeCode first; Codex when it
grows a non-ephemeral mode worth using.

---

## Tier 2 — Cheap wins and design-gated patterns

### AO2-1. A spawn-site architecture guard (the needle-scan we already know how to write)

**Recommendation**: BORROW-PATTERN — half-day; extends a shipped house idiom.

**Where in secure-exec**: `crates/sidecar/tests/architecture_guards.rs:325-428` — a CI
needle-scan banning `std::process::Command`/`tokio::process`/`fork` across the crates,
with a **two-file allowlist** and the comment "Guest 'process' spawns go through the
kernel `CommandDriver` registry and never reach `Command::new`." It is why the verifier
could refute the "broken node" warning structurally, not just empirically.

**What**: the invariant "all subprocess creation goes through the blessed sites" is a
test, not a convention — drift fails CI with the offending file named.

**Gap in jido_radclaw** (verified 2026-07-03): our equivalent invariant — *every spawn
uses a default-deny scrubbed env* — is convention. `Port.open` lives in six files
(`os_cmd.ex`, `backend_host.ex`, `mcp_stdio_transport_patch.ex`, `host_shell.ex`,
`docker.ex`, `redaction/env.ex`), `System.cmd`/`System.shell` in a handful more; 41 call
sites reference `scrubbed_port_env`/`scrubbed_cmd_env`, and nothing stops the 42nd spawn
from skipping the scrub. We already own the pattern to fix this:
`test/jido_claw/v064_file_store_sweep_test.exs:22-44` is precisely this shape (regex
sweep over `lib/**/*.ex`, allowlist, offenders printed).

**Why it matters**: env scrubbing is the single control standing between host secrets and
every child process (the MCP trust-boundary paragraph in AGENTS.md leans on it), and the
nono program (N1-1) is about to make the spawn sites even more load-bearing — the wrap
must happen at those sites or not at all. A guard makes both invariants survivable.

**Adoption sketch**: `test/jido_claw/spawn_site_guard_test.exs`, v064-style: ban
`Port.open`, `System.cmd`, `System.shell`, `:os.cmd`, `System.find_executable`-adjacent
spawn idioms outside an explicit allowlist of the six files (each entry with a one-line
justification comment); a second assertion checks each allowlisted file mentions
`scrubbed_port_env|scrubbed_cmd_env`. When nono N1-1 lands, `Containment.wrap_spawn/3`'s
site joins the allowlist — and the guard is what proves nothing else spawns around it.
*(Cross-dig, same day: crabbox's `timing-safe-auth` needle-test is a second subject data
point for the pattern ([crabbox S-6](../crabbox/FEATURES-WORTH-BORROWING.md)); and the
needle list must grow with new spawn primitives — a
[ghostty_ex GX2-2](../ghostty_ex/FEATURES-WORTH-BORROWING.md) PTY adoption would spawn
via `forkpty` inside a NIF, invisible to a `Port.open`/`System.cmd` scan, so
`Ghostty.PTY` joins the needles the day that lands.)*

### AO2-2. Limits inventory + bounded-by-default audit (doctrine with an enforcement mechanism)

**Recommendation**: BORROW-PATTERN (mechanism) + BORROW-RUBRIC (the review lines).

**Where**: agentos root `CLAUDE.md` "Limits, Bounds & Observability" — every bound must
be bounded by default, warn on approach (default ≥80%), and fail with a **typed error
naming the limit and how to raise it**; enforced in secure-exec by a committed
`limits-inventory.json` + `limits_audit.rs`, compile-breaking default-deny/bounded
assertions (`default_deny_guards.rs:236-300` — every non-time cap `Some(_)` and nonzero;
time budgets' opt-in status *documented as a test*), and edge-triggered ~80% warnings in
the accountant (`resource_accounting.rs:171-228`). Real defaults confirmed:
128 MiB V8 heap (`isolate.rs:128,178-191`), 256 processes/fds, 64 MiB fs quota.

**What**: a single place that answers "what are all our caps, what are their defaults,
which warn before they bite" — audited, not aspirational.

**Gap in jido_radclaw** (verified 2026-07-03): our caps are real but scattered and
convention-documented — OutputLimit 32 KB inline / 512 KB capture (AGENTS.md prose),
Forge `max_sessions: 50` + per-runner caps (`manager.ex:24-25`), ExecSession 10 KB
truncation (`persistence.ex:219`), Consumer re-prep backoff caps (`consumer.ex`), shell
`ulimit` opt-ins (`host_shell.ex:166-204`). No inventory, no approach-warning convention,
no "the error names the knob" rule; several clip silently-with-metadata rather than
warning as they approach.

**Why it matters**: for an agent platform, unbounded-or-silently-clipped is how both
runaway costs and quiet data loss happen; the 80%-warn + named-knob doctrine is the
difference between an operator finding out *before* and *after*. It is also the doctrine
AO1-1's event caps should be born under.

**Adoption sketch**: staged. (1) Write the inventory as a doc table (limit, default,
config key, behavior at cap, warn?) — an hour, immediately useful. (2) A
`limits_inventory_test.exs` asserting each inventoried config default is present and
nonzero (v064-style, reads config not source). (3) Adopt the review-checklist lines
verbatim: "bounded by default — never `nil`/0 meaning infinity," "warn at ~80% where a
gauge exists," "the error names the limit and the config key that raises it." Skip the
JSON-file indirection; our config is the inventory's source of truth.

### AO2-3. Host tools as in-sandbox commands (generalize the consolidator's inverse-MCP)

**Recommendation**: BORROW-PATTERN, design-gated — TRACK with a concrete trigger: **the
second Forge workload that needs host reach mid-run** (the consolidator was the first).

**Where in agentos**: `toolKits` registration (`packages/core/src/host-tools.ts:10-40`) →
inert command stubs written into the guest (`agent-os.ts:1439-1456`) → kernel intercepts
the name → reverse `host_callback` frame → host Zod-validates argv (`--flag`, `--json`,
`--json-file`) and runs `execute` host-side, result rendered as guest stdout/exit code
(`agent-os.ts:1976-2418`); gated per-binding by `binding.invoke` (host-enforced,
`agent-os.ts:2559-2584`); async-with-timeout (30 s default), **no streaming**; discovery
via a generated tool reference in the system prompt (`buildHostToolReference`,
`agent-os.ts:1817-1867`). `examples/agent-to-agent` shows the payoff shape: two VMs never
touch — the host binding is the only bridge.

**What**: sandboxed agents get *curated host capabilities* as ordinary CLI commands,
without host credentials entering the sandbox and without generic network egress.

**Gap in jido_radclaw** (verified 2026-07-03): exactly one precedent, purpose-built — the
memory consolidator mints a per-run host HTTP MCP endpoint and injects its URL into the
in-sandbox CLI's MCP config (`memory/consolidator/run_server.ex:369-393`,
`mcp_endpoint.ex`) — and it *requires* sandbox→host network (it doesn't set `network:
:none`), the opposite posture from the sketch tier. There is no general mechanism, no
registry, no per-tool gating for in-sandbox callers (the host ToolApproval gate never
sees these calls).

**Why it matters**: this is the leakage-hygiene-positive way to give Forge agents
capability: the sandbox holds no keys and no broad egress; the host executes with its own
credentials behind its own gate. It converts "mount more secrets into the sandbox" asks
into "expose one audited verb" answers.

**Adoption sketch** (when triggered): generalize the consolidator's shape rather than
inventing kernel stubs (we don't own the sbx kernel): a per-run
`Forge.HostBridge` HTTP MCP endpoint with a minted bearer token, a declared allowlist of
tool modules (reusing `Tools.Action` so redaction/approval/shaping apply — the in-sandbox
caller becomes just another gated surface), reachable at
`host.docker.internal:<port>` **through** the sandbox's `allowedDomains` (this is
PS1-2's host-reach spike — same plumbing, second consumer). Their argv/`--json-file`
convention and prompt-injected tool reference (AO2-4) are the ergonomics to copy.

### AO2-4. Tell the agent where it is: environment self-description injection

**Recommendation**: BORROW-PATTERN — small, composes with nono N2-3.

**Where in agentos**: the sidecar injects an OS-instructions prompt into every agent it
launches — `--append-system-prompt` (pi/claude), `--append-developer-instructions`
(codex), `OPENCODE_CONTEXTPATHS` (opencode) (`acp_extension.rs:482-538`); content =
"You are running inside agentOS…" + known limitations (no arbitrary binaries, no file
watching) + how to discover host tools (`AGENTOS_SYSTEM_PROMPT.md:1-22`).

**What**: the agent learns the box's shape *before* it walks into a wall, and learns the
sanctioned alternatives at the same moment.

**Gap in jido_radclaw** (verified 2026-07-03): our runners inject the task
(`session/context.md`, `claude_code.ex:31-34`) and flags, but nothing tells the agent
it's sandboxed, that `network: :none` means fetches will fail, what's mounted where, or
that responses arrive via `session/response.json`. The runner argv has no
`--append-system-prompt` today (`claude_code.ex:61-88`).

**Why it matters**: same economics as nono N2-3 (denial legibility) from the other end —
N2-3 explains the wall after impact; this moves the map before it. Fewer thrashed
iterations is paid back in tokens and wall-clock on every sandboxed run.

**Adoption sketch**: a `Runners.EnvDescription.build(spec)` that renders a short block
from what the harness already knows (`sandbox_spec.network`, mounts, workdir, forge_home
layout, response-file contract); ClaudeCode appends `--append-system-prompt <text>`,
Codex the developer-instructions equivalent. Static text, no new state. When AO2-3
exists, its tool reference joins this block (their `buildHostToolReference` precedent).

### AO2-5. Default egress posture: deny + LLM-provider allowlist (and the replace-vs-merge footgun)

**Recommendation**: FOLD-IN — this is a *decision* for the already-planned sbx
`allowedDomains` work (pi-sbx PS1-1, nono N2-4), not new machinery.

**Where in agentos**: `DEFAULT_EGRESS_HOSTS = [api.anthropic.com, api.openai.com,
generativelanguage.googleapis.com, openrouter.ai]` with `default: Deny`
(`crates/client/src/agent_os.rs:1189-1216`) — a VM with no policy can reach its model
provider and nothing else. The footgun worth recording with it: a user-supplied network
policy **replaces** the allowlist rather than merging (`agent_os.rs:1245-1251`), silently
severing LLM connectivity. Also for the N2-4 spec file: their kernel classifier defeats
IPv4-mapped-IPv6 metadata bypasses (`::ffff:169.254.169.254`,
`secure-exec/crates/kernel/src/network_policy.rs:34-84`) — add that case to the
non-overridable floor's test list.

**Gap in jido_radclaw** (verified 2026-07-03): our spec surface is still binary —
`network: :none` → `--network none`, else the sbx login default (`docker.ex:311-312`);
the planned allowedDomains work has mechanics (PS1-1) and semantics (N2-4) specced but
**no default posture chosen** for agent-runner sandboxes.

**Adoption sketch**: when PS1-1 lands, the `claude_code`/`codex` runner default becomes
`deny + provider hosts for the configured runner` (+ `host.docker.internal` entries only
where AO2-3/PS1-2 needs them); shell/sketch tiers keep `:none`. Spec rule from their
footgun: operator lists **merge over** the runner floor, or at minimum warn when the
resolved list can't reach the runner's provider. *(Same-day convergence:
[openshell OSH1-1](../openshell/FEATURES-WORTH-BORROWING.md) rung 1 arrives at this exact
default independently, motivated from the credential side — the OAuth login file our
runners copy into open-egress sandboxes; recorded in both docs as the corpus's
design-validation signal.)*

---

## Tier 3 — Parked with triggers

### AO3-1. Signed preview URLs for in-sandbox web servers

**Recommendation**: TRACK — trigger: the first Forge/sketch workload that runs a dev
server someone wants to *see* (today's sketch tier is `network: :none` and headless).
**Where**: `agentos-actor-plugin/src/http.rs:1-124`, `actions/preview.rs:71` — mint a
short-TTL token, host proxies `/preview/{token}/…` to a guest loopback port; revocable;
TTL-capped. The shape to copy someday: operator-facing, tokened, host-mediated — never
"expose the sandbox port."

### AO3-2. Warm-standby capacity for Forge sandboxes

**Recommendation**: TRACK — trigger: cold-create latency becomes a *felt* cost (composer
exec-sketch waves queuing on provisioning, or an operator complaint with numbers).
**Where/what**: their mechanisms don't transfer (shared-tenant sidecar + pre-warmed V8
isolates that already deserialized the snapshot, `v8_host.rs:210-215`,
`snapshot.rs:146-148`) but the *shape* does — N pre-created sandboxes claimed by lease.
Our side is a verified blank: every Forge run is a cold `sbx create` (grep for
pool/warm/standby in `forge/` is empty; budgets sized accordingly — 30 s manager call,
60 s ReadyStart await, `manager.ex:34`, `ready_start.ex:40`). Carry their honest lesson
when the trigger fires: their own numbers say warm ≠ free (452 ms warm vs 772 ms cold) —
measure the actual sbx create p50 first; the fix might be `deferred_provision` placement,
not a pool. *(Same trigger family: [ysa Y3-3](../ysa/FEATURES-WORTH-BORROWING.md) parks
warm dep/toolchain caches on the same Forge-latency trigger — evaluate the pair together
when it fires.)*

### AO3-3. Perf-baseline lane for the eval harness

**Recommendation**: TRACK — trigger: the next eval-harness increment (the minimal slice
just shipped, `docs/plans/unadopted-next-five` item 5), or the first perf regression we
have to bisect by hand.
**Where**: secure-exec `packages/benchmarks` — committed `baseline-{ci,local}.json` with
hardware provenance, a CI gate failing when current p50 > 2× baseline (README:85), memory
provenance from `/proc` deltas, and the doctrine line "never delete or silently skip a
bench — skips carry a reason." **Gap**: `JidoClaw.Eval` is correctness-only
(`eval/run_case` kinds: prompt/schema/composer/coherence); no latency lane, no committed
baselines. The borrow is the *artifact discipline* (baseline files + threshold gate +
provenance), not their harness.

---

## Skip / Already Covered

- **S-1. Cron / queues / workflows / webhooks.** ALREADY-COVERED. Their cron is the only
  primitive agentos itself owns (`agent-os.ts:5575-5590`, croner-backed, in-memory);
  queues/workflows are RivetKit's, webhooks a Hono pattern. Ours are durable and
  cluster-aware: `Platform.Cron` Owner/Dispatcher (`platform/cron/owner.ex:1-86`,
  leader-gated, DB-source-of-truth), the Reactor workflow engine with the gap-free
  `WorkflowEvent` log + gated `replay_workflow` (`orchestration/workflow_event.ex`,
  `orchestration/replay.ex:1-67`). The one hole on our side (no generic inbound
  webhook→workflow trigger; GitHub-only, `web/router.ex:61-64`) is real but their Hono
  pattern teaches us nothing Phoenix doesn't.
- **S-2. Multiplayer / live observation.** ALREADY-COVERED: PubSub `{:output, chunk}`
  fan-out (`harness.ex:699-706`), the LiveView dashboard, `AgentTracker`. Their
  seq-numbered reconnect-replay rides AO1-1 if we ever want it.
- **S-3. Filesystem mounts (S3/Drive/host/overlay).** ALREADY-COVERED at the tool tier by
  `VFS.Resolver` (github/s3/git backends, `vfs/resolver.ex:329-358`) — and their
  mount-into-VM mechanism is kernel-specific, not liftable onto sbx. The honest residual
  on our side (VFS↔Forge are disjoint; files enter sandboxes by bind-mount/clone/
  base64-echo, `resource_provisioner.ex:150-165`) predates this dig and isn't made
  cheaper by their code. Their `google_drive` backend is the one scheme we lack — no
  demand, skip.
- **S-4. The permission-policy schema** (fs/network/process glob axes). SKIP — wrong
  layer for us: the sbx microVM and nono own our walls. Recorded instead as the
  cautionary tale (SDK defaults allow-all while the README says deny-by-default) and as
  AO2-2's positive lesson (the *kernel's* compile-breaking default-deny guards).
- **S-5. ACP as our agent protocol.** SKIP for the platform (our runners drive CLIs;
  jido's signal bus is our spine; adopting ACP wholesale is a pivot with no trigger).
  AO1-1 takes the transcript shape; OQ-1 keeps the naming question open.
- **S-6. Guest env sanitization** (AT_SECURE-style `LD_*`/`DYLD_*`/`NODE_OPTIONS` strip,
  `packages-and-command-resolution.mdx:243`). ALREADY-COVERED, stronger:
  `Env.scrubbed_port_env/1` is allowlist/default-deny (`security/redaction/env.ex:178-188`)
  — same verdict as nono S-1.
- **S-7. Software registry packaging** (versioned `/opt/agentos/<pkg>/<version>` cellar,
  per-binary wasm crates, header-based dispatch). SKIP — solves provisioning for a kernel
  we don't run; our sandboxes provision via images + `bootstrap_steps` + the resource
  provisioner. Elegant, inapplicable.
- **S-8. The "sandbox extension" escalation ladder.** SKIP, with the scan corrected: it
  is **manual composition** (explicitly wire an external `sandbox-agent` container; its
  fs projected in as a mount; commands delegated over host tools;
  `packages/agentos-sandbox/src/toolkit.ts:25-218`, `examples/sandbox/server.ts:1-18`) —
  not automatic escalation; E2B/Daytona are prose-only. Our Forge *is* the full-sandbox
  tier; there is nothing to escalate from. (The README/crash-course also reference a
  `createSandboxBindings` export that doesn't exist — another drift datum.)
- **S-9. Browser/WASM convergence + Chrome on-device inference.** SKIP — genuinely novel
  (the whole sidecar compiles to wasm32; pi against Gemini Nano with zero egress) and
  genuinely irrelevant to a BEAM tailnet platform. One passing validation: their
  `examples/browser-terminal` (xterm.js over an actor WebSocket, render-only, reconnect
  re-adopts by id) independently lands on the same product shape as our ghostty_ex GX1-1
  verdict.
- **S-10. Doctrine garnishes, recorded not actioned**: stdout purity ("control channels
  must be out-of-band" — our MCP stdio already lives this); "NO FAKES" / "a red gate with
  an honest reason beats a green gate over a stub" (`AGENTOS-WEB-REAL-TERMINAL.md:7-24`)
  — camus already gave us this doctrine; their versionless-lockstep protocol rule
  convergently validates our greenfield-no-compat stance. Nothing to build.

## Open questions

- **OQ-1. Event vocabulary for AO1-1**: keep the ClaudeCode-shape we already emit, or
  rename to ACP `session/update` variants (`tool_call`/`tool_call_update`/…)? ACP is an
  open protocol with a growing ecosystem; renaming later is a migration, renaming now is
  free. Decide at AO1-1 implementation time.
- **OQ-2. Storage target for AO1-1**: Forge `Event` rows (leans on existing append-only +
  `exec_session_sequence`) vs a dedicated resource vs JSONB on `ExecSession`. Volume ×
  the AO2-2 caps decide; leaning Event rows.
- **OQ-3. AO2-3 transport when triggered**: generalized per-run HTTP MCP endpoint (the
  consolidator/PS1-2 path, through `allowedDomains`) vs a mounted unix socket (no network
  needed, but sbx mount semantics for sockets unverified). PS1-2's spike answers half of
  this for free.
- **OQ-4. Does AO2-5's provider-allowlist default extend to `shell`-runner sandboxes**,
  or only the agent runners? (Sketch tier stays `:none` regardless.)

## Cross-references and dependencies

```
AO1-1 (persist events) ──> AO1-2 (transcript resume)
   │                          
   └── caps born under ── AO2-2 (limits inventory/audit)
AO2-1 (spawn guard) ── protects the sites nono N1-1 will wrap
AO2-4 (self-description) ── composes with nono N2-3 (denial legibility); carries AO2-3's tool reference
AO2-5 (egress default) ── FOLD-IN → pi-sbx PS1-1 mechanics + nono N2-4 semantics
AO2-3 (host bridge) ── trigger-gated; transport rides PS1-2's host-reach spike
AO3-1..3 ── independent, named triggers
```

Suggested first wave: **AO1-1 + AO1-2 as one "Forge transcript" slice** (the parsers,
store, and wake path all exist; this is plumbing plus discipline), with **AO2-1 as the
half-day filler** and AO2-2's step-1 inventory doc alongside. Queue collision note: the
`unadopted-next-ten` queue (selected 2026-07-02) is in flight and untouched by this —
these are sandbox-axis items alongside the nono program, operator's call on ordering.
AO2-5 has no work of its own; it's a rider on whenever the pi-sbx spike runs.

## Bottom line

agentos is the best-engineered subject in the sandbox corpus and still a clear SKIP as a
dependency: it solves isolation one tier below where we already live, at rc-maturity,
behind a deliberately versionless protocol — and its two headline marketing claims
(deny-by-default, ~6 ms) don't survive contact with its own code and committed
benchmarks. What does survive is worth real work: **persist the agent transcripts we
already parse and rebuild sessions from them** (AO1-1/AO1-2 — the one gap here that
touches every axis we care about: composer judgment, observability, eval, recovery),
**turn our two spawn/limits conventions into guard tests** (AO2-1/AO2-2 — their CI
discipline, our existing idiom), and **let the sandbox tell its agent the truth about
itself** (AO2-4/AO2-5 — cheap words, fewer thrashed iterations, and the default egress
posture the allowedDomains program was missing). The scan called agentos a concept donor
and it is — just not of the concept it advertised.
