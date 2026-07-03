# Sandbox Landscape Scan

**Status**: initial scan (2026-07-03). Quick pass over the repos cloned at
`~/workspace/research/sandboxes/` — READMEs, top-level structure, and last-commit
activity only. Nothing here has been built, run, or read in depth yet; treat every
claim as "per their docs" until a follow-up dig verifies it. **Deep-dives landed**
(same day): nono — see
[nono/FEATURES-WORTH-BORROWING.md](nono/FEATURES-WORTH-BORROWING.md) (verdict:
ADOPT-AS-TOOL); ysa — see
[ysa/FEATURES-WORTH-BORROWING.md](ysa/FEATURES-WORTH-BORROWING.md) (verdict: mostly
SKIP / ALREADY-COVERED; two narrow borrows); coderunner — see
[coderunner/FEATURES-WORTH-BORROWING.md](coderunner/FEATURES-WORTH-BORROWING.md)
(verdict: trial-scoped ADOPT-AS-TOOL via config-only MCP consumption; two
native-successor patterns; egress-open — a capability boundary, not a data one);
ghostty*ex — see
[ghostty_ex/FEATURES-WORTH-BORROWING.md](ghostty_ex/FEATURES-WORTH-BORROWING.md)
(verdict: scoped **ADOPT-AS-DEP** — the corpus's first — gated on its first consumer,
the render-only dashboard terminal; explicitly \_not* a redaction-root replacement); and
pi-sbx-llamacpp — see
[pi-sbx-llamacpp/FEATURES-WORTH-BORROWING.md](pi-sbx-llamacpp/FEATURES-WORTH-BORROWING.md)
(verdict: **BORROW-REFERENCE** — a guide, nothing adoptable by construction; both
backend-feature gaps verified to the line, kit mechanics + spike OQs specced; the dig
also surfaced sbx capabilities beyond the kit — `deniedDomains` floors + proxy-managed
credentials); agentos — see
[agentos/FEATURES-WORTH-BORROWING.md](agentos/FEATURES-WORTH-BORROWING.md) (verdict:
**SKIP as a dependency, richest concept donor in the corpus** — the dig also cloned and
pinned its `secure-exec` engine sibling; the scan's reasons were rewritten in both
directions, and the live borrows are the Forge transcript pair AO1-1/AO1-2 plus the
CI-guard discipline AO2-1/AO2-2); and OpenShell — see
[openshell/FEATURES-WORTH-BORROWING.md](openshell/FEATURES-WORTH-BORROWING.md)
(verdict: **TRACK the platform, borrow three mechanisms** — the placeholder/resolver
credential split as the brokering reference, the deny→propose→human-gate policy loop
onto our AgentCase machinery, the OCSF audit rubric onto our existing `audit_events`;
the seams pass also surfaced the corpus's sharpest credential gap — our claude_code
runner copies a full OAuth login file into open-egress sandboxes); and crabbox — see
[crabbox/FEATURES-WORTH-BORROWING.md](crabbox/FEATURES-WORTH-BORROWING.md) (verdict:
**SKIP-as-dependency, borrow the security discipline** — a team-scale remote-exec control
plane on the scale-out axis, not isolation; but the dig found two present-day defects on
our side its patterns fix — CB1-1 a credential-destination provenance guard, CB1-2
ownership proof before the `forge-*` sandbox reaper destroys anything — plus CB2-1's
capsule-replay outcome taxonomy folding into camus C1-3).

**Goal**: figure out where each project could improve, replace, or supplement the
current Forge/sandboxing capabilities before the next phase of work.

## Where Forge stands today (the seams these would plug into)

- `JidoClaw.Forge.Sandbox.Behaviour` (`lib/jido_claw/forge/sandbox/behaviour.ex`) —
  `create / exec / exec_argv / spawn / write_file / read_file / inject_env / run /
destroy`. Exactly **one** backend exists: `Sandbox.Docker`, and despite the name
  it is built entirely on **Docker Sandboxes (`sbx` CLI)** — `sbx create/exec/run/rm`
  against microVMs, not plain `docker run`. MicroVM-class isolation is already our
  baseline; what the backend does _not_ yet do is network policy (`allowedDomains`)
  or host-inference reach (no hits for either in `forge/`). Any container/VM project
  below would land as a second implementation of this behaviour.
- Runners (`forge/runners/`): `claude_code`, `codex`, `shell`, `custom`, `workflow` —
  what runs _inside_ a sandbox.
- `JidoClaw.MCP.Consumer` — we already consume external MCP servers with the full
  safety pipeline wrapped around every proxied tool. A sandbox that _exposes an MCP
  server_ is a near-zero-code integration.
- `Security.ShellCommand` / `ToolApproval` — the host-side `run_command` gate, with
  documented residuals (`npx`, script-file indirection) and a `:docker` shell-floor
  skip that matches the shipped sbx microVM isolation ("inside a provisioned
  microVM, relax the gate"). OS-level process sandboxing is the missing third
  option between "gate" and "allow" for commands running on the _host_.
- Threat model (personal, tailnet-only): LLM misbehavior + secret/data leakage
  hygiene, not hostile multi-tenant isolation.

## Quick comparison

| Repo                                                        | What it is                                                  | Tech                       | Isolation                                  | License    | Activity                         | Fit                                                                                                                                                                                                                                         |
| ----------------------------------------------------------- | ----------------------------------------------------------- | -------------------------- | ------------------------------------------ | ---------- | -------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [nono](https://github.com/nolabs-ai/nono)                   | Zero-setup OS-level agent sandbox CLI                       | Rust                       | Landlock/seccomp (Linux), Seatbelt (macOS) | Apache-2.0 | very active (Jul 2026)           | **New capability: host-process sandboxing**                                                                                                                                                                                                 |
| [ysa](https://github.com/ysa-ai/ysa)                        | Container runtime for coding agents                         | TypeScript/Bun             | Rootless Podman, hardened                  | Apache-2.0 | single-author, v0.5.5 (Jul 2026) | **Deep-dived: mostly SKIP — wrong tier (Podman < our microVM), superseded by nono where it overlaps; 2 narrow borrows (Y1-1, Y2-1)**                                                                                                        |
| [OpenShell](https://github.com/NVIDIA/OpenShell)            | Policy-governed agent runtime platform                      | Rust                       | Docker/Podman/K8s/VM drivers + in-sandbox L7 proxy | Apache-2.0 | very active (Jul 2026), alpha    | **Deep-dived: TRACK as platform (named triggers); three Tier-1 borrows — credential-brokering reference incl. our claude_code login-file exposure (OSH1-1), deny→propose→human-gate loop (OSH1-2), audit rubric onto `audit_events` (OSH1-3)** |
| [coderunner](https://github.com/instavm/coderunner)         | Local sandbox exposing an MCP server                        | Python                     | Apple `container` VM (Apple-Silicon macOS) | Apache-2.0 | slower (May 2026)                | **Deep-dived: trial ADOPT-AS-TOOL — config-only consumption confirmed; the durable ideas are the stateful-executor and agent-skills patterns (CR2-x); zero egress control**                                                                 |
| [agentos](https://github.com/rivet-dev/agentos)             | "OS for agents" — ACP wrapper over secure-exec              | Rust + TypeScript          | WASM VM + V8 isolates, in-process          | Apache-2.0 | very active (Jul 2026)           | **Deep-dived: SKIP-as-dep, richest concept donor — "~6ms" is VM-object allocation (772ms to first exec per their own committed baselines); BEAM embed feasible (native sidecar + Rust client) but a versionless-protocol treadmill; live borrows: Forge transcript pair (AO1-1/-2) + CI-guard discipline (AO2-1/-2)** |
| [crabbox](https://github.com/openclaw/crabbox)              | Remote execution control plane (lease, sync, run, evidence) | Go + TS coordinator        | **explicitly not a sandbox**               | MIT        | very active (Jul 2026), pre-1.0  | **Deep-dived: SKIP-as-dep, borrow the security discipline — scale-out not isolation; two present-day defects its patterns fix (CB1-1 credential-destination provenance, CB1-2 ownership-proof reaper); CB2-1 capsule taxonomy folds into camus C1-3** |
| [ghostty_ex](https://github.com/dannote/ghostty_ex)         | Terminal emulator library for the BEAM                      | Elixir NIF (libghostty-vt) | n/a                                        | MIT        | active (May 2026)                | **Deep-dived: scoped ADOPT-AS-DEP (corpus first) — dashboard terminal (GX1-1) is the gating consumer; screen-collapse/PTY/expect ride behind triggers; kept out of the redaction root (GX S-1)**                                            |
| [pi-sbx-llamacpp](https://github.com/cuolm/pi-sbx-llamacpp) | Setup guide, no code                                        | Markdown "kit"             | Docker `sbx` microVM (what we already run) | MIT        | Jun 2026                         | **Deep-dived: BORROW-REFERENCE — mechanics + spike OQs specced for the sbx backend's allowedDomains + host-inference work (PS1-1/PS1-2); dig also surfaced deniedDomains floors, serviceAuth (PS2-1), and our decorative base_url (PS2-2)** |

## Categories

### 1. Host-process sandboxing — a capability we don't have

**nono** (nolabs-ai, the Sigstore team). Wraps a command in a least-privilege
OS-native sandbox with _no_ daemon/container/VM: Landlock + seccomp on Linux,
Seatbelt on macOS, WSL2 supported. Profile registry with per-agent policies
(filesystem scope, network allowlist, hooks), credential injection via a local
proxy, L7 filtering, audit. C FFI bindings exist (plus Rust/Python/TS/Go), so both
integration shapes are open: shell out to `nono run --profile … -- cmd`, or a
NIF/port later.

Why this matters for us: it targets exactly our threat model — the agent's own
process can't read SSH keys/cloud creds or write outside scope, _regardless_ of what
command it runs. Today `ShellCommand.analyze/1` has conscious residuals (the
`npx`/`nix run` family, interpreter script-files) where we either gate or trust.
Running `run_command` children under a nono profile would convert that binary into
"gate, allow, or **contain**", and could eventually relax the approval gate the same
way the `:docker` shell-floor skip already does inside a microVM. Caveats to verify:
macOS Seatbelt gaps they document (no per-port filtering), and what a long-lived
shell session (vs one-shot command) looks like under it. _(Deep-dive 2026-07-03
answered both: Seatbelt genuinely can't port-filter — domain policy is enforced in a
userspace proxy with the kernel pinning egress to it; and our "sessions" are discrete
`sh -c` spawns with Elixir-side cwd/env state, so the long-lived-shell concern
dissolves. Full inventory:
[nono/FEATURES-WORTH-BORROWING.md](nono/FEATURES-WORTH-BORROWING.md).)_

### 2. Sandbox backend candidates (second `Forge.Sandbox.Behaviour` impl)

**ysa** (Your Secure Agent). Rootless Podman containers, defense-in-depth flags
(no-root, read-only fs, syscall whitelist, capability-stripped), a **git worktree
per task**, optional network policy via local proxy + firewall, session resume, and
a deliberately small SDK surface (`runTask()` as the composable primitive — they
explicitly expect an orchestration layer like ours on top). **Deep-dive landed
2026-07-03: [ysa/FEATURES-WORTH-BORROWING.md](ysa/FEATURES-WORTH-BORROWING.md).
Verdict: mostly SKIP / ALREADY-COVERED — a short list.** The framing below (CLI-wrap
vs design-donor) is _overturned_ by the dig on two counts. (1) **Wrong tier**: ysa
is rootless Podman on the _shared host kernel_; our `Sandbox.Docker` already runs on
`sbx` **microVMs** (a separate kernel), so the entire hardening flag set defends a
boundary we don't use — it's a spec for a `Sandbox.Podman` backend we'd only want on
a Linux host without sbx (Y3-1, TRACK), not a thing to adopt now. (2) **Superseded
where it overlaps**: ysa's network policy is a per-request L7 method/rate filter over
_all_ hosts (not an egress allowlist, no cloud-metadata deny floor) — beaten by nono
N2-4; and its credential path puts the **raw API key in container env**, which we
already beat (key never enters sbx env) and nono N2-2 beats further (phantom tokens).
CLI-wrap is off the table (full task-runner overlap with Harness/AgentRunner, weaker
tier, single-author pre-1.0 with security-doc drift in the _unsafe_ direction — a
`none` policy documented as zero-egress that gives full internet). **What survives**:
one genuinely-novel borrow — harden git execution against a **poisoned on-disk
`.git/config`** (Y1-1; our command-string gate ignores literal inline code-exec keys
like `-c core.sshCommand=…` and never reads the repo's config — ysa's key-strip list
is the ready spec), and the worktree-per-task pattern as the reviewable middle between
our throwaway scaffold and our in-sandbox clone (Y2-1).

**OpenShell** (NVIDIA, alpha). The maximalist take: a Rust gateway with pluggable
drivers (Docker, Podman, Kubernetes, VM — 19 crates), declarative YAML policies
enforced by an L7 proxy at HTTP method + path granularity without restarts, OCSF
audit logging, TUI, Helm chart. Sandbox images ship with `claude`/`opencode`/
`codex`/`copilot` preinstalled. It overlaps heavily with what JidoClaw _is_ (an
agent platform), so adopting it wholesale would be strange; the plausible uses are
(a) `openshell sandbox create` as a managed backend where we want VM-class isolation
plus network policy handled for us, or (b) a **reference** for the policy/proxy
design (method+path-level egress rules are notably finer than our destination-policy
browse gate). Alpha status and platform weight are the main cautions. **Deep-dive
landed 2026-07-03:
[openshell/FEATURES-WORTH-BORROWING.md](openshell/FEATURES-WORTH-BORROWING.md).
Verdict: TRACK the platform, borrow three mechanisms.** Option (b) won and is now
specced; option (a) is demoted to TRACK with named triggers — the container drivers are
a *lower* tier than our sbx microVMs (ysa's lesson again), and the tier-matching libkrun
VM driver is experimental with no CI runtime boot test on macOS. Three scan claims
sharpened by the dig: enforcement is not gateway-side — the L7 proxy and embedded Rego
engine run *inside* each sandbox (a supervisor process; the gateway is control-plane
only); policy is finer than advertised (per-**binary** matching via `/proc/<pid>/exe`
identity, MCP per-tool rules) with hot-reload limited to the network/inference domains
(fs/process lock at creation); and the sleeper feature is the **credential
placeholder/resolver split** — the agent's env carries `openshell:resolve:…`
placeholders, real keys swapped in only at proxy egress, rotation without restart. The
dig's sharpest product is on our side: `runners/claude_code.ex` copies the host's full
`~/.claude/credentials.json` OAuth login into agent-readable sandbox fs with
default-unrestricted egress (OSH1-1) — now the motivating case for PS1-1's
`allowedDomains` work.

**coderunner** (instavm). macOS Apple-Silicon local sandbox built on Apple's
`container` tool, with persistent Jupyter kernels (pool of 2–5, health-checked) and
— the interesting bit — an **MCP server** at `coderunner.local:8222/mcp`
(`execute_python_code`, etc.). Because `JidoClaw.MCP.Consumer` already wraps
external MCP tools in the full approval/redaction/shaping pipeline, this is a
**config-only trial**: add it under `mcp_servers:` in `.jido/config.yaml` and the
agent gets sandboxed code execution with zero new code. That makes it the cheapest
experiment in the set, even though the project itself moves slower (last commit
May 2026) and is macOS-only — which happens to match the primary dev machine.
**Deep-dive landed 2026-07-03:
[coderunner/FEATURES-WORTH-BORROWING.md](coderunner/FEATURES-WORTH-BORROWING.md).
Verdict: trial-scoped ADOPT-AS-TOOL** — the config-only claim verified on both
sides (`transport: streamable_http` + `url:`; exact entry in CR1-1), with two
pre-flight caveats (BEAM/mDNS `.local` resolution, approval posture — OQ-1/OQ-2).
The dig sharpened three scan claims: the sleeper feature is the **Anthropic-skills
compatibility layer** (run `anthropics/skills` unmodified via `/mnt/user-data` path
translation + 3 progressive-disclosure tools), not the kernels per se; the
"persistent kernel" headline is undermined by its own pool (no session affinity —
persistence by dict-order accident, breaks under concurrency); and the README's
"no fear of exfiltration" claim is host-true/data-false — **zero egress control**,
every in-VM service deliberately unauthenticated (a Docker fallback path publishes
the same tokenless stack on a shared kernel). Durable value if the trial proves
demand: build the session-affine stateful executor natively (CR2-1, their three
flaws as the fix-first spec) and the agent-skills surface (CR2-2 — three thin
tools + a read-only mount buys the public Anthropic skills corpus). Apple
`container` as a Forge backend: ALREADY-COVERED by our sbx microVMs.

### 3. In-process micro-VMs — concept donor

**agentos** (rivet-dev). An "OS for AI agents" that runs _inside your process_:
WASM VM + V8 isolates, ~6ms cold starts, WASM builds of coreutils/git/curl, Node
runtime routing, deny-by-default fs/network/process permissions, built-in ACP
agents (Pi, Claude Code, OpenCode), and a sandbox extension that escalates to a
full sandbox on demand. Impressive, but it's an npm package designed to embed in a
JS backend — from the BEAM it would be a sidecar Node process, at which point much
of the "in-process, no network hop" value evaporates. Worth tracking for the
**pattern** (per-tool-call ephemeral micro-VMs with ms cold starts; graduated
escalation from cheap isolate → full sandbox) rather than as a dependency.
**Deep-dive landed 2026-07-03:
[agentos/FEATURES-WORTH-BORROWING.md](agentos/FEATURES-WORTH-BORROWING.md) — which
also cloned its engine sibling `secure-exec` at the exact pinned sha (the kernel,
V8/WASM runtimes, wire protocol, and registry all live there, not in agentos).
Verdict: SKIP as a dependency, richest concept donor in the corpus.** The dig
overturned this paragraph's framing in both directions: (1) the embed reasoning was
wrong — agentos is NOT JS-only; a native `agentos-sidecar` binary speaks
length-prefixed BARE over stdio and a 1:1 Rust client proves non-JS drivability —
but the conclusion survives on better grounds (deliberately versionless lockstep
protocol, positional BARE tags, rc-stage single-author = a codec treadmill); (2) the
admired headline features shrink on contact — "~6ms" is VM-object allocation while
their own committed baselines show 772ms p50 to first exec and 15–856× WASM command
tax, "deny-by-default" is false at the SDK layer for fs/process (allow-all defaults;
only network denies, with a 4-host LLM allowlist), and the "sandbox extension" is
manual container wiring, not automatic escalation. What actually survives: the
transcript architecture (normalize → seq → append-only → replay → rebuild-on-resume)
that names our verified parse-then-discard gap in the Forge runners (AO1-1/AO1-2),
the CI-enforced engineering discipline (architecture needle-scans, compile-breaking
default-deny tests, bounded-by-default limits audits — AO2-1/AO2-2, extending our own
v064-sweep idiom), in-sandbox agent self-description prompts (AO2-4, composing with
nono N2-3), and the deny+LLM-provider default egress posture as a rider on the
planned sbx `allowedDomains` work (AO2-5).

### 4. Remote execution / scale-out — orthogonal to isolation

**crabbox** (openclaw). Go CLI + optional coordinator (Cloudflare Durable Object or
Node+Postgres) that leases a remote runner (Hetzner/AWS/Azure/GCP or your own SSH
host), syncs the working tree, runs the command, streams output, and records an
auditable evidence trail. Their docs are explicit that it is **not** a security
boundary — it solves "run this somewhere bigger/elsewhere, with evidence", not
containment. For us it maps to the swarm/scale-out axis (Forge runs on beefier
remote capacity; evidence trail for agent-run suites), not to sandboxing. **Deep-dive
landed 2026-07-03:
[crabbox/FEATURES-WORTH-BORROWING.md](crabbox/FEATURES-WORTH-BORROWING.md). Verdict:
SKIP-as-dependency, borrow the security discipline** — a 381k-LOC team-scale control
plane whose credential-custody reason-to-exist doesn't apply to one operator (and whose
overlap with us, SSH remote exec, we already ship thinner via `run_command backend:ssh`).
But it's rigorous on our exact threat axis, and the dig found **two present-day defects on
our side** its patterns fix: **CB1-1** — a credential-destination provenance guard
(`credential_provenance.go` refuses an inherited secret bound to a repo-config-chosen
destination; our `ServerRegistry` hands a host-env SSH `password_env` straight to a
`host:` loaded from the agent-writable `.jido/config.yaml`, so an LLM editing that file can
redirect the password to a host it chose — the sharpest borrow), and **CB1-2** — ownership
proof before destroying an external resource (crabbox's "labels/names/IDs are not ownership
proof"; our `Forge.SandboxInit` reaps `sbx` sandboxes on a bare `forge-*` name prefix,
which nukes a second instance's in-flight sandboxes). Plus **CB2-1**, whose capsule-replay
4-outcome taxonomy (`reproduced`/`passed`/`new_failure`/`inconclusive`, signature-gated)
converges with camus C1-3's verdict normalizer and folds in there. The scan's two framings
are corrected by the dig: (a) "coordinator-owned-credentials worth studying" is mostly
irrelevant to a single operator and already covered where it isn't (nono N2-2 phantom
tokens, openshell OSH1-1 brokering) — the distinct credential idea is the *provenance*
guard, not the custody; (b) "park for a later phase" undersells it — CB1-1/CB1-2 are
present-day hardening, not deferred. Bonus cross-corpus finding: crabbox's shipped `sbx`
adapter passes `--kit`/`--mcp` to `sbx create` (validated vs sbx v0.31.3), independent code
evidence for pi-sbx **OQ-1**.

### 5. Supporting infrastructure

**ghostty_ex**. The only Elixir-native repo here: libghostty-vt as precompiled
NIFs — terminals as GenServers, SIMD VT parsing, scrollback with reflow, PTY
management, and `snapshot/2` to plain text **or HTML with inline colors**. Not a
sandbox, but directly relevant to the surfaces _around_ Forge: real PTY-backed
shell sessions, rendering agent terminal output in the LiveView dashboard, and a
principled alternative to regex ANSI-stripping (parse the stream, snapshot clean
text) where our redaction/shaping pipeline currently strips escapes textually.
Cheap to adopt piecemeal and worth a focused spike on the dashboard/shell-session
side independent of the sandboxing decision. **Deep-dive landed 2026-07-03:
[ghostty_ex/FEATURES-WORTH-BORROWING.md](ghostty_ex/FEATURES-WORTH-BORROWING.md).
Verdict: scoped ADOPT-AS-DEP** — the corpus's first use of that axis, gated on its
first consumer: the render-only dashboard terminal our own README already (falsely)
advertises as xterm.js at `/forge` (GX1-1). The dig _refines_ the scan's headline
claim: terminal emulation is **not** an alternative to the regex strip in the
_redaction root_ — that layer exists to reassemble escape-split secrets on the
logical byte stream, and emulation would erase overwritten bytes and wrap lines
before redaction could scan them (GX S-1). Snapshot-as-normalizer is hygiene-safe
only _after_ redaction, as a trigger-gated OutputShaper stage for `\r`-frame noise
(GX2-1; snapshots verified full-scrollback against upstream source). PTY is a
capability decision with verified caveats (children inherit BEAM env, signal deaths
report exit 0, SIGHUP-only close) deferred behind a TTY-requiring need and the
web-shell question (GX2-2/OQ-3).

### 6. Reference for the backend we already run

**pi-sbx-llamacpp**. Not software — a setup guide for running the Pi agent inside
Docker's `sbx` microVM with inference served by a host `llama-server` in router
mode. This one was included deliberately: **`Sandbox.Docker` is already sbx** —
every Forge sandbox is one of these microVMs. The kit documents precisely the two
capabilities our backend hasn't wired up yet (neither appears anywhere in `forge/`):

- **Granular network policy**: sbx's host-side proxy enforces `allowedDomains` —
  everything else is blocked. Our spec surface today is binary: `%{network: :none}`
  emits `--network none` (AR-8b-2 no-egress), otherwise the sandbox rides whatever
  default policy the sbx login chose. The `allowedDomains` allowlist is the missing
  middle ground — per-sandbox egress scoping from the isolation layer we already
  ship, analogous to the browse_web destination-policy gate but kernel/proxy-enforced.
- **Host-local inference from inside the microVM**: inside the VM, `localhost` is
  the VM; the host is reached as `host.docker.internal` _through_ the sbx proxy,
  subject to `allowedDomains`. That is exactly the path a Forge-sandboxed agent
  needs to use host Ollama (our recommended local-dev inference) or a
  `llama-server` in router mode (dynamic model loading on the host GPU), and we
  currently have no story for it.

So rather than "candidate backend to evaluate", read this kit as the worked example
for our existing backend's next two features.

**Deep-dive landed 2026-07-03:
[pi-sbx-llamacpp/FEATURES-WORTH-BORROWING.md](pi-sbx-llamacpp/FEATURES-WORTH-BORROWING.md)
(read-only; nothing executed; sbx claims cross-checked against Docker's
kit-reference/get-started/FAQ pages). Verdict: BORROW-REFERENCE** — nothing to adopt by
construction (335 lines of markdown+YAML, zero code); both scan claims above held
exactly (the binary spec surface is `docker.ex:311-312` verbatim; no host-reach story
anywhere in `forge/`). The dig sharpened three things. The **allowlist schema is richer
than the kit shows**: `deniedDomains` beats allows and is non-overridable across
composed kits (a ready-made mechanism for nono N2-4's metadata floor), and
`serviceDomains`/`serviceAuth`/`proxyManaged` give proxy-injected credentials that
never enter the VM (the phantom-token tier, parked as PS2-1 against our OneCLI). The
**host-reach routing claim is kit-only**: vendor docs are silent on
`host.docker.internal`-through-the-proxy, so it — plus the odd
both-`host.docker.internal:port`-and-`localhost:port` allowlist requirement — stays
spike-verified, not doc-verified. And the kit's own `spec.yaml` uses the
**pre-v0.32.0 deprecated schema** (`kind: agent`); a synthesized kit of ours would be a
`kind: mixin`. Bonus finding from the seams pass, unrelated to sbx: our
`.jido/config.yaml` `providers.*.base_url` is decorative for generation (it feeds only
the reachability probe and setup wizard) — PS2-2, INDEPENDENT.

## Cross-dig convergence map (2026-07-03)

The eight deep-dives ran effectively in parallel on one day; each backfilled the sibling
docs it knew about, but several convergences only became visible with all eight on the
table. This section is the reconciliation pass — each per-doc entry named below carries a
matching dated note.

- **One spike, five feeders.** The sbx `allowedDomains` spike (next-step below) now has
  its checklist spread across five docs: mechanics + host reach
  (pi-sbx PS1-1/PS1-2 + OQ-1..3), semantics (nono N2-4), lifecycle rules + its own OQ
  riders (openshell OSH2-2, OQ-1/OQ-2/OQ-4), default posture (agentos AO2-5 — deny +
  provider hosts, merge-over-floor, the `::ffff:169.254.169.254` floor test case),
  motivation (openshell OSH1-1 — the claude_code OAuth file × open egress), and OQ-1
  evidence (crabbox CB-note-1). Whoever runs the spike should assemble the checklist from
  all five, not from the pi-sbx doc alone.
- **The credential story, resolved corpus-wide.** Tiers, weakest to strongest: raw key in
  child env (ysa, agentos — cautionary only) → copied OAuth file + scoped egress (ours;
  the fix axis per operator doctrine — OSH1-1 rung 1) → proxy-managed/phantom credentials
  (sbx `serviceAuth` PS2-1 ≈ openshell placeholders ≈ nono N2-2). Two corpus-level
  findings ride it: **nobody brokers file-based OAuth** (OSH1-1's ceiling — contain the
  file's blast radius instead), which re-scopes nono N2-2's first target to MCP stdio
  servers (a dated correction there: the "runner keys ride env" premise did not survive
  verification — runners are file-OAuth, zero `*_API_KEY` in `forge/`); and the
  orthogonal axis no custody tier covers — **destination provenance** (crabbox CB1-1),
  which also fences pi-sbx PS2-2 the day `base_url` goes live.
- **The Forge run-record pair.** agentos AO1-1/AO1-2 (transcript plane: what the
  sandboxed agent did) and openshell OSH1-3 (decision plane: what was
  allowed/denied/executed) are complementary halves of one observability gap; OSH1-3's
  store rubric is where the "which of the event stores (audit / trace / workflow_event /
  Forge events) gets what" rule must cover both.
- **Guard-test discipline, three sources.** agentos AO2-1/AO2-2 (spawn-site needle-scan,
  limits inventory) + crabbox S-6 (timing-safe needle test — second data point), with one
  forward caveat: needle lists must grow with new spawn primitives (a ghostty_ex GX2-2
  PTY adoption spawns via `forkpty` inside a NIF, invisible to a `Port.open` scan).
- **Denial legibility, one envelope.** nono N2-3 (`sandbox_denial` after the wall),
  agentos AO2-4 (self-description before the wall), openshell OSH1-2 (`next_steps` + the
  standing-grant loop) — three entries, one policy-denial envelope design; build it once.
- **Shared triggers worth filing together.** Forge latency: ysa Y3-3 (warm
  deps/toolchains) + agentos AO3-2 (warm-standby sandboxes, and its "measure `sbx create`
  p50 first" lesson). Remote/multi-node phase: openshell OSH3-1 (supervisor-dials-out),
  crabbox CB2-2/CB3-1, the argus overview. Render-only web terminal: ghostty GX1-1, with
  agentos S-9's independent convergence on the same shape.

## Early read (to be challenged in the deep-dive)

1. **Cheapest experiment**: point `mcp_servers:` at coderunner — sandboxed Python
   execution through the existing MCP consumption pipeline, config-only. _(Confirmed
   by the deep-dive 2026-07-03 — exact config + trial caveats in
   [coderunner CR1-1](coderunner/FEATURES-WORTH-BORROWING.md); egress-open, so the
   trial rule is "never feed it secrets," and the durable ideas are the CR2-x
   patterns, not the dependency.)_
2. **Highest strategic value**: nono — OS-level containment for `run_command` is the
   missing rung between the approval gate and full Forge sandboxes, and it matches
   the leakage-hygiene threat model precisely.
3. **Most likely code we write**: extend the existing sbx backend per the pi-sbx
   kit — `allowedDomains` in `sandbox_spec` + host-Ollama reach. _(Update post-dig:
   the `Sandbox.Podman`-from-ysa-hardening idea is demoted to TRACK — Y3-1 — because
   Podman is a weaker tier than our sbx microVM; ysa's live borrow turned out to be
   the git-config-poisoning defense Y1-1, unrelated to a backend.)_
4. **Track, don't adopt**: OpenShell (policy/proxy design reference), agentos
   (escalation-ladder pattern), crabbox (later scale-out phase). _(Update post-dig
   2026-07-03: agentos verdict confirmed as SKIP-as-dep but the tracked pattern was
   the wrong one — the escalation ladder is manual wiring and the ms-cold-start is
   allocation-only; the live borrows are the transcript pair and CI-guard discipline —
   [agentos/FEATURES-WORTH-BORROWING.md](agentos/FEATURES-WORTH-BORROWING.md).)_
   _(OpenShell likewise confirmed 2026-07-03, upgraded from bare reference to three
   specced Tier-1 borrows — OSH1-1/OSH1-2/OSH1-3 — with the platform itself TRACK on
   named triggers;
   [openshell/FEATURES-WORTH-BORROWING.md](openshell/FEATURES-WORTH-BORROWING.md).)_
   _(crabbox confirmed 2026-07-03: SKIP-as-dep, but "later scale-out phase" undersold
   it — the tracked value is present-day *security discipline*, not deferred scale-out.
   Two live defects its patterns fix (CB1-1 credential-destination provenance, CB1-2
   ownership-proof reaper) plus CB2-1 folding into camus C1-3;
   [crabbox/FEATURES-WORTH-BORROWING.md](crabbox/FEATURES-WORTH-BORROWING.md).)_
5. **Independent quick win**: ghostty*ex for PTY/terminal rendering in shell
   sessions and the dashboard. *(Confirmed and scoped by the deep-dive 2026-07-03 —
   the quick win is the render-only dashboard terminal
   [GX1-1](ghostty_ex/FEATURES-WORTH-BORROWING.md); the "principled ANSI-strip
   alternative" half is refined to a post-redaction shaper stage only, never the
   redaction root — GX S-1.)\_

## Suggested next steps

- [ ] Spike: coderunner as an external MCP server on the dev Mac (config-only).
      _Deep-dive done 2026-07-03 —
      [coderunner/FEATURES-WORTH-BORROWING.md](coderunner/FEATURES-WORTH-BORROWING.md)
      (read-only; nothing executed). The spike itself remains: CR1-1 has the exact
      `mcp_servers:` entry, pre-flight steps, and success criteria; OQ-2 (`.local`
      resolution from the BEAM) is the known friction to resolve first._
- [x] Deep-dive agentos (was: "track for the escalation-ladder pattern") — **done
      2026-07-03**: [agentos/FEATURES-WORTH-BORROWING.md](agentos/FEATURES-WORTH-BORROWING.md)
      (read-only; nothing executed; its `secure-exec` engine sibling cloned to
      `~/workspace/research/sandboxes/secure-exec` at the exact `.github/refs/secure-exec`
      pin `94f540b3` so kernel claims are code-verified). Verdict: **SKIP as a
      dependency, richest concept donor in the corpus** — suggested first wave is the
      Forge transcript slice (AO1-1 persist the runner events we already parse +
      AO1-2 transcript-reconstruction resume), with the spawn-site guard test (AO2-1)
      as filler and AO2-5's deny+LLM-provider egress default riding the future pi-sbx
      spike.
- [x] Deep-dive nono: profile semantics, macOS Seatbelt limits, long-lived session
      story, CLI-wrap vs C-FFI integration shape — **done 2026-07-03**:
      [nono/FEATURES-WORTH-BORROWING.md](nono/FEATURES-WORTH-BORROWING.md). Verdict:
      **ADOPT-AS-TOOL** (CLI wrap; the C FFI is immature and the wrong grain), phased —
      wrap the `run_command`/HostShell/MCP-stdio spawns, add a `:contained` approval
      tier beside the `:docker` skip, grow into supervised egress allowlists +
      phantom-token credentials.
- [x] Read ysa's `container/` hardening + network-policy implementation as the spec
      for a native Podman backend — **done 2026-07-03**:
      [ysa/FEATURES-WORTH-BORROWING.md](ysa/FEATURES-WORTH-BORROWING.md). Verdict:
      **mostly SKIP / ALREADY-COVERED**. The hardening set is a _shared-kernel_
      Podman posture, moot against our sbx microVM — it's the spec for a
      `Sandbox.Podman` backend only wanted on a Linux host without sbx (Y3-1, TRACK).
      Network policy is superseded by nono N2-4 (ysa's isn't even an egress allowlist;
      no metadata floor; `none` = full internet despite docs); credentials by nono N2-2
      (ysa puts the raw key in container env). Two narrow borrows survive: **Y1-1**
      (harden git-exec against a poisoned on-disk `.git/config` — our gate ignores
      literal inline code-exec keys and never reads repo config; ysa's key-strip list is
      the spec) and **Y2-1** (worktree-per-task as the reviewable workspace-isolation
      middle). CLI-wrap-as-tool rejected: full task-runner overlap, weaker tier,
      single-author pre-1.0 with security-doc drift.
- [x] Deep-dive OpenShell (added post-scan): policy/proxy design, backend candidacy,
      credential handling — **done 2026-07-03**:
      [openshell/FEATURES-WORTH-BORROWING.md](openshell/FEATURES-WORTH-BORROWING.md)
      (read-only; nothing executed). Verdict: **TRACK as platform** (container tier
      below our sbx; libkrun VM driver experimental; one-driver-per-gateway daemon;
      default-on telemetry), **three Tier-1 borrows**: OSH1-2 deny→propose→human-gate
      loop onto ToolApproval/AgentCase, OSH1-3 audit kinds + OCSF-vs-tracing rubric
      onto `audit_events`, OSH1-1 credential-brokering reference — whose gap half
      (claude_code copies `~/.claude/credentials.json` into open-egress sandboxes)
      now motivates PS1-1. Tier 2 (OSH2-1/2-2/2-3) folds into the PS1-x program
      rather than standing alone.
- [] Walk the pi-sbx kit against our existing sbx backend: add `allowedDomains` to
  `sandbox_spec` (between today's binary default/`--network none`), and prove
  host-Ollama reach from inside a Forge sandbox via `host.docker.internal`.
  _Deep-dive done 2026-07-03 —
  [pi-sbx-llamacpp/FEATURES-WORTH-BORROWING.md](pi-sbx-llamacpp/FEATURES-WORTH-BORROWING.md)
  (read-only; nothing executed). The spike itself remains, now specced: PS1-1
  (kit-synthesis mechanics + the four-file thread incl. the silently-dropping
  recovery whitelist) and PS1-2 (dual host:port allowlist entries, endpoint
  injection, the 127.0.0.1→host.docker.internal translation helper); pre-flight is
  OQ-1 (`sbx create --kit`? — **the crabbox dig gives third-party code evidence it
  does**: crabbox's shipped docker-sandbox adapter passes repeatable `--kit`/`--mcp`
  to `sbx create`, validated vs sbx v0.31.3 — crabbox CB-note-1), OQ-2
  (kit-vs-base-policy interaction), OQ-3 (proxy enforcement semantics) — all empirical,
  one sandbox, one afternoon. The spike's full checklist now spans five docs — see the
  convergence map above._
- [x] Spike ghostty_ex against a shell-session surface (PTY + HTML snapshot in
      LiveView) — deep-dive done **2026-07-03** (read-only; nothing executed):
      [ghostty_ex/FEATURES-WORTH-BORROWING.md](ghostty_ex/FEATURES-WORTH-BORROWING.md).
      Verdict: **scoped ADOPT-AS-DEP**, first consumer = render-only `/forge`
      terminal (GX1-1, one PR incl. the chunk fan-out and README claim fix); the
      PTY half is deliberately re-scoped out of the first slice (GX2-2/OQ-3 — a
      browser-reachable PTY is a web-shell decision, not a rendering one). The
      runtime smoke that remains is OQ-1: precompiled-NIF load under mise
      OTP 29 + the escript caveat.
- [x] Deep-dive crabbox (was: "park for a later scale-out phase"): the
      coordinator-owned-credentials model, remote-exec/evidence surfaces, provider
      abstraction — **done 2026-07-03**:
      [crabbox/FEATURES-WORTH-BORROWING.md](crabbox/FEATURES-WORTH-BORROWING.md)
      (read-only; nothing built or executed; coordinator read, not deployed). Verdict:
      **SKIP-as-dependency, borrow the security discipline** — a 381k-LOC team-scale
      control plane on the scale-out (not isolation) axis, whose SSH-remote-exec overlap
      we already ship thinner (`run_command backend:ssh`). Two present-day defects its
      patterns fix are the first wave: **CB1-1** credential-destination provenance (our
      `ServerRegistry` hands a host-env SSH `password_env` to a `host:` from the
      agent-writable `.jido/config.yaml` — an LLM can redirect the secret; the sharpest
      borrow) and **CB1-2** ownership proof before the `forge-*` name-prefix sandbox
      reaper destroys anything. **CB2-1** (capsule-replay 4-outcome taxonomy) folds into
      camus C1-3; **CB2-2** (tree-sync remote exec on tailnet capacity) and **CB3-1**
      (external-provider JSON-stdio protocol) are TRACK. The scan's "coordinator-owned
      credentials worth studying" resolved to already-covered custody (nono N2-2,
      openshell OSH1-1) — the distinct idea is the *provenance* guard, not the custody.
