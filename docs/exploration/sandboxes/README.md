# Sandbox Landscape Scan

**Status**: initial scan (2026-07-03). Quick pass over the repos cloned at
`~/workspace/research/sandboxes/` — READMEs, top-level structure, and last-commit
activity only. Nothing here has been built, run, or read in depth yet; treat every
claim as "per their docs" until a follow-up dig verifies it. **First deep-dive
landed** (same day): nono — see
[nono/FEATURES-WORTH-BORROWING.md](nono/FEATURES-WORTH-BORROWING.md).

**Goal**: figure out where each project could improve, replace, or supplement the
current Forge/sandboxing capabilities before the next phase of work.

## Where Forge stands today (the seams these would plug into)

- `JidoClaw.Forge.Sandbox.Behaviour` (`lib/jido_claw/forge/sandbox/behaviour.ex`) —
  `create / exec / exec_argv / spawn / write_file / read_file / inject_env / run /
  destroy`. Exactly **one** backend exists: `Sandbox.Docker`, and despite the name
  it is built entirely on **Docker Sandboxes (`sbx` CLI)** — `sbx create/exec/run/rm`
  against microVMs, not plain `docker run`. MicroVM-class isolation is already our
  baseline; what the backend does *not* yet do is network policy (`allowedDomains`)
  or host-inference reach (no hits for either in `forge/`). Any container/VM project
  below would land as a second implementation of this behaviour.
- Runners (`forge/runners/`): `claude_code`, `codex`, `shell`, `custom`, `workflow` —
  what runs *inside* a sandbox.
- `JidoClaw.MCP.Consumer` — we already consume external MCP servers with the full
  safety pipeline wrapped around every proxied tool. A sandbox that *exposes an MCP
  server* is a near-zero-code integration.
- `Security.ShellCommand` / `ToolApproval` — the host-side `run_command` gate, with
  documented residuals (`npx`, script-file indirection) and a `:docker` shell-floor
  skip that matches the shipped sbx microVM isolation ("inside a provisioned
  microVM, relax the gate"). OS-level process sandboxing is the missing third
  option between "gate" and "allow" for commands running on the *host*.
- Threat model (personal, tailnet-only): LLM misbehavior + secret/data leakage
  hygiene, not hostile multi-tenant isolation.

## Quick comparison

| Repo | What it is | Tech | Isolation | License | Activity | Fit |
|---|---|---|---|---|---|---|
| [nono](https://github.com/nolabs-ai/nono) | Zero-setup OS-level agent sandbox CLI | Rust | Landlock/seccomp (Linux), Seatbelt (macOS) | Apache-2.0 | very active (Jul 2026) | **New capability: host-process sandboxing** |
| [ysa](https://github.com/ysa-ai/ysa) | Container runtime for coding agents | TypeScript/Bun | Rootless Podman, hardened | Apache-2.0 | very active (Jul 2026) | **Sandbox backend (design donor or CLI wrap)** |
| [OpenShell](https://github.com/NVIDIA/OpenShell) | Policy-governed agent runtime platform | Rust | Docker/Podman/K8s/VM drivers + L7 proxy | Apache-2.0 | very active (Jul 2026), alpha | Sandbox backend and/or policy-design reference |
| [coderunner](https://github.com/instavm/coderunner) | Local sandbox exposing an MCP server | Python | Apple `container` VM (Apple-Silicon macOS) | Apache-2.0 | slower (May 2026) | **Zero-code trial via MCP consumption** |
| [agentos](https://github.com/rivet-dev/agentos) | In-process "OS for agents", ~6ms cold start | Rust + TypeScript | WASM VM + V8 isolates, in-process | Apache-2.0 | very active (Jul 2026) | Concept donor; awkward embed for BEAM |
| [crabbox](https://github.com/openclaw/crabbox) | Remote execution control plane (lease, sync, run, evidence) | Go | **explicitly not a sandbox** | MIT | very active (Jul 2026) | Scale-out axis, not isolation |
| [ghostty_ex](https://github.com/dannote/ghostty_ex) | Terminal emulator library for the BEAM | Elixir NIF (libghostty-vt) | n/a | MIT | active (May 2026) | Supporting infra: PTY + VT parsing |
| [pi-sbx-llamacpp](https://github.com/cuolm/pi-sbx-llamacpp) | Setup guide, no code | Markdown "kit" | Docker `sbx` microVM (what we already run) | MIT | Jun 2026 | **Direct reference for our existing sbx backend: allowedDomains + host inference** |

## Categories

### 1. Host-process sandboxing — a capability we don't have

**nono** (nolabs-ai, the Sigstore team). Wraps a command in a least-privilege
OS-native sandbox with *no* daemon/container/VM: Landlock + seccomp on Linux,
Seatbelt on macOS, WSL2 supported. Profile registry with per-agent policies
(filesystem scope, network allowlist, hooks), credential injection via a local
proxy, L7 filtering, audit. C FFI bindings exist (plus Rust/Python/TS/Go), so both
integration shapes are open: shell out to `nono run --profile … -- cmd`, or a
NIF/port later.

Why this matters for us: it targets exactly our threat model — the agent's own
process can't read SSH keys/cloud creds or write outside scope, *regardless* of what
command it runs. Today `ShellCommand.analyze/1` has conscious residuals (the
`npx`/`nix run` family, interpreter script-files) where we either gate or trust.
Running `run_command` children under a nono profile would convert that binary into
"gate, allow, or **contain**", and could eventually relax the approval gate the same
way the `:docker` shell-floor skip already does inside a microVM. Caveats to verify:
macOS Seatbelt gaps they document (no per-port filtering), and what a long-lived
shell session (vs one-shot command) looks like under it. *(Deep-dive 2026-07-03
answered both: Seatbelt genuinely can't port-filter — domain policy is enforced in a
userspace proxy with the kernel pinning egress to it; and our "sessions" are discrete
`sh -c` spawns with Elixir-side cwd/env state, so the long-lived-shell concern
dissolves. Full inventory:
[nono/FEATURES-WORTH-BORROWING.md](nono/FEATURES-WORTH-BORROWING.md).)*

### 2. Sandbox backend candidates (second `Forge.Sandbox.Behaviour` impl)

**ysa** (Your Secure Agent). Rootless Podman containers, defense-in-depth flags
(no-root, read-only fs, syscall whitelist, capability-stripped), a **git worktree
per task**, optional network policy via local proxy + firewall, session resume, and
a deliberately small SDK surface (`runTask()` as the composable primitive — they
explicitly expect an orchestration layer like ours on top). It's TypeScript, so we
wouldn't embed it; the realistic options are (a) wrap the CLI as a backend, or
(b) treat it as a **design donor**: lift the Podman hardening flag set, the
worktree-per-task pattern, and the network-policy approach into a native
`Sandbox.Podman` backend. Option (b) looks like the higher-value path — Podman is
the obvious second backend for Linux hosts and their hardening choices are the
research we'd otherwise do ourselves.

**OpenShell** (NVIDIA, alpha). The maximalist take: a Rust gateway with pluggable
drivers (Docker, Podman, Kubernetes, VM — 19 crates), declarative YAML policies
enforced by an L7 proxy at HTTP method + path granularity without restarts, OCSF
audit logging, TUI, Helm chart. Sandbox images ship with `claude`/`opencode`/
`codex`/`copilot` preinstalled. It overlaps heavily with what JidoClaw *is* (an
agent platform), so adopting it wholesale would be strange; the plausible uses are
(a) `openshell sandbox create` as a managed backend where we want VM-class isolation
plus network policy handled for us, or (b) a **reference** for the policy/proxy
design (method+path-level egress rules are notably finer than our destination-policy
browse gate). Alpha status and platform weight are the main cautions.

**coderunner** (instavm). macOS Apple-Silicon local sandbox built on Apple's
`container` tool, with persistent Jupyter kernels (pool of 2–5, health-checked) and
— the interesting bit — an **MCP server** at `coderunner.local:8222/mcp`
(`execute_python_code`, etc.). Because `JidoClaw.MCP.Consumer` already wraps
external MCP tools in the full approval/redaction/shaping pipeline, this is a
**config-only trial**: add it under `mcp_servers:` in `.jido/config.yaml` and the
agent gets sandboxed code execution with zero new code. That makes it the cheapest
experiment in the set, even though the project itself moves slower (last commit
May 2026) and is macOS-only — which happens to match the primary dev machine.

### 3. In-process micro-VMs — concept donor

**agentos** (rivet-dev). An "OS for AI agents" that runs *inside your process*:
WASM VM + V8 isolates, ~6ms cold starts, WASM builds of coreutils/git/curl, Node
runtime routing, deny-by-default fs/network/process permissions, built-in ACP
agents (Pi, Claude Code, OpenCode), and a sandbox extension that escalates to a
full sandbox on demand. Impressive, but it's an npm package designed to embed in a
JS backend — from the BEAM it would be a sidecar Node process, at which point much
of the "in-process, no network hop" value evaporates. Worth tracking for the
**pattern** (per-tool-call ephemeral micro-VMs with ms cold starts; graduated
escalation from cheap isolate → full sandbox) rather than as a dependency.

### 4. Remote execution / scale-out — orthogonal to isolation

**crabbox** (openclaw). Go CLI + optional coordinator (Cloudflare Durable Object or
Node+Postgres) that leases a remote runner (Hetzner/AWS/Azure/GCP or your own SSH
host), syncs the working tree, runs the command, streams output, and records an
auditable evidence trail. Their docs are explicit that it is **not** a security
boundary — it solves "run this somewhere bigger/elsewhere, with evidence", not
containment. For us it maps to the swarm/scale-out axis (Forge runs on beefier
remote capacity; evidence trail for agent-run suites), not to sandboxing. Park it
for a later phase; if revisited, the coordinator-owned-credentials model is the
part worth studying.

### 5. Supporting infrastructure

**ghostty_ex**. The only Elixir-native repo here: libghostty-vt as precompiled
NIFs — terminals as GenServers, SIMD VT parsing, scrollback with reflow, PTY
management, and `snapshot/2` to plain text **or HTML with inline colors**. Not a
sandbox, but directly relevant to the surfaces *around* Forge: real PTY-backed
shell sessions, rendering agent terminal output in the LiveView dashboard, and a
principled alternative to regex ANSI-stripping (parse the stream, snapshot clean
text) where our redaction/shaping pipeline currently strips escapes textually.
Cheap to adopt piecemeal and worth a focused spike on the dashboard/shell-session
side independent of the sandboxing decision.

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
  the VM; the host is reached as `host.docker.internal` *through* the sbx proxy,
  subject to `allowedDomains`. That is exactly the path a Forge-sandboxed agent
  needs to use host Ollama (our recommended local-dev inference) or a
  `llama-server` in router mode (dynamic model loading on the host GPU), and we
  currently have no story for it.

So rather than "candidate backend to evaluate", read this kit as the worked example
for our existing backend's next two features.

## Early read (to be challenged in the deep-dive)

1. **Cheapest experiment**: point `mcp_servers:` at coderunner — sandboxed Python
   execution through the existing MCP consumption pipeline, config-only.
2. **Highest strategic value**: nono — OS-level containment for `run_command` is the
   missing rung between the approval gate and full Forge sandboxes, and it matches
   the leakage-hygiene threat model precisely.
3. **Most likely code we write**: extend the existing sbx backend per the pi-sbx
   kit — `allowedDomains` in `sandbox_spec` + host-Ollama reach — and/or a
   `Sandbox.Podman` backend using ysa's hardening set as the spec.
4. **Track, don't adopt**: OpenShell (policy/proxy design reference), agentos
   (escalation-ladder pattern), crabbox (later scale-out phase).
5. **Independent quick win**: ghostty_ex for PTY/terminal rendering in shell
   sessions and the dashboard.

## Suggested next steps

- [ ] Spike: coderunner as an external MCP server on the dev Mac (config-only).
- [x] Deep-dive nono: profile semantics, macOS Seatbelt limits, long-lived session
      story, CLI-wrap vs C-FFI integration shape — **done 2026-07-03**:
      [nono/FEATURES-WORTH-BORROWING.md](nono/FEATURES-WORTH-BORROWING.md). Verdict:
      **ADOPT-AS-TOOL** (CLI wrap; the C FFI is immature and the wrong grain), phased —
      wrap the `run_command`/HostShell/MCP-stdio spawns, add a `:contained` approval
      tier beside the `:docker` skip, grow into supervised egress allowlists +
      phantom-token credentials.
- [ ] Read ysa's `container/` hardening + network-policy implementation as the spec
      for a native Podman backend.
- [ ] Walk the pi-sbx kit against our existing sbx backend: add `allowedDomains` to
      `sandbox_spec` (between today's binary default/`--network none`), and prove
      host-Ollama reach from inside a Forge sandbox via `host.docker.internal`.
- [ ] Spike ghostty_ex against a shell-session surface (PTY + HTML snapshot in
      LiveView).
