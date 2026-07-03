# Features Worth Borrowing from nono

Exploration notes — not a plan, not a commitment. Deep-dive **2026-07-03**, fulfilling the
first next-step of the [sandbox landscape scan](../README.md). Source:
`~/workspace/research/sandboxes/nono` (nolabs-ai/nono, HEAD `f943fb5a`, v0.66.0). Built by
the Sigstore team. Self-description: *"Run AI agents in a zero latency sandbox in seconds
and with zero setup … no daemon, no container, no VM, and no disk space usage."* Shape: a
Rust workspace (~166k LOC, 191 files) of three crates — `nono` (policy-free sandbox
primitive: capability model, Landlock/Seatbelt application, path canonicalization,
keystore, rollback object store), `nono-cli` (profiles, policy, supervisor, tool-sandbox,
audit), `nono-proxy` (out-of-sandbox network proxy: CONNECT host filtering, credential
injection, TLS interception for L7) — plus a thin C FFI (`bindings/c`, v0.1.0). Maturity:
1,459 commits, 83 tagged releases, active the day of this review, real contributor tail,
OpenSSF Best Practices badge, Apache-2.0, pre-1.0 with "APIs stabilizing." Everything
below is from reading docs + source; **nono was not installed or executed during this
review** — runtime claims (latency above all) are per-docs until the install spike.

Companion docs: the [sandbox landscape scan](../README.md) (this doc answers its nono
deep-dive item; its pi-sbx/ysa items are siblings on the microVM/container tiers),
`docs/exploration/camus/FEATURES-WORTH-BORROWING.md` (C2-7 frozen judge assets and C2-8
trust-boundary laws are adjacent to nono's trust layer and review doctrine), and the
house threat model (personal, tailnet-only: LLM misbehavior + secret/data leakage
hygiene, not hostile multi-tenant isolation — exactly nono's design center).

## Determination (TL;DR)

**Adopt it as a tool — the first subject in this directory where that's the verdict.**
Every prior exploration ended "translate the contracts, skip the code." nono inverts:
there is almost nothing to translate (it's a Rust kernel-policy engine; we'd be
reimplementing Seatbelt/Landlock drivers for no reason) and a lot to *use*: a single
unprivileged ~2 MB binary that wraps exactly the process shape we already spawn. Our host
`run_command` funnels every command through one `Port.open({:spawn, "sh -c …"})` call
site with env already default-deny scrubbed; `nono wrap` is a transparent
sandbox-then-`exec()` prefix for precisely that shape, at ~zero claimed overhead, with a
JSON capability manifest as the programmatic policy interface. It supplies the missing
third rung the scan predicted — **gate / contain / allow** — and its supervised mode
holds the deepest leakage-hygiene upgrade on our books: phantom-token credential
injection, where the real `ANTHROPIC_API_KEY`/`GITHUB_TOKEN` never enters any
agent-reachable process.

| Part of nono | As a dependency | What to take |
| --- | --- | --- |
| `nono wrap` (Direct mode) + capability manifest | **ADOPT-AS-TOOL** | Contain the host `run_command`/`HostShell`/MCP-stdio spawns (N1-1, N1-3) |
| `nono run` (Supervised) + `nono-proxy` | ADOPT-AS-TOOL, phase 2 | Egress allowlists + phantom-token credentials for long-lived children (N2-1, N2-2) |
| Approval-floor interplay | — (ours to build) | A `:contained` tier beside the `:docker` skip (N1-2) |
| Network-policy semantics (deny floor, wildcards, DNS discipline) | No | **The spec** for the planned sbx `allowedDomains` work (N2-4) |
| Rollback / audit / tool-sandbox / trust / FFI | No (for now) | Track; revisit on named triggers (N3-x, S-x) |
| Registry profiles/packs | No | We compile our own manifests; third-party profiles carry privileged `session_hooks` |

## Why adopt-as-tool is on the table (the inverse of every prior doc)

1. **It's a binary, not a framework.** Integration is argv prefixing at one (later three)
   spawn sites, behind a config gate. No SDK, no daemon, no runtime coupling; removal is
   deleting the prefix. The C FFI exists but is immature (v0.1.0, `publish = false`, no
   README) and the wrong grain anyway — a NIF would sandbox the whole BEAM. CLI wrap is
   the intended shape and the docs' own client pattern (wrap the entire agent CLI in one
   `nono run` — `docs/cli/clients/claude-code.mdx`, `codex.mdx`).
2. **The seam is already cut.** Every host `run_command` is a *discrete* `sh -c` spawn at
   `lib/jido_claw/shell/backend_host.ex:135` — sessions persist cwd/env in Elixir state,
   not in a live shell PID, so there is no long-lived-shell complication. The same
   `Env.scrubbed_port_env` default-deny scrub already applied there keeps working
   unchanged underneath nono's own env filtering.
3. **Threat-model match is exact.** Filesystem default-deny with workspace grants;
   keychain/credential paths deny-by-default *including the Mach-IPC route to the
   keychain daemons* (`crates/nono/src/sandbox/macos.rs:531-549` — richer than their own
   docs); "allow discovery, deny content" so `stat` works but `cat ~/.ssh/id_ed25519`
   fails; a non-overridable cloud-metadata/link-local network deny floor. This is
   leakage-hygiene engineering, not multi-tenant isolation theater.
4. **Security-serious upstream.** Fail-closed doctrine written down and enforced in
   review (`NOGENT.md`: "TLS interception … must not fall back to an opaque tunnel";
   "missing credential material … must not allow the child to provide its own"), DNS
   rebinding closed correctly (resolve once, connect to the checked IPs —
   `crates/nono-proxy/src/filter.rs:55-92`), credentials in `Zeroizing` types, honest
   platform-gap documentation. Their docs *understate* shipped capability in at least one
   place (`seatbelt.mdx:166-174` claims binary network control; ProxyOnly domain
   filtering ships) — the rare direction of drift you want.
5. **Alternatives considered.** Anthropic's `sandbox-runtime` (what Claude Code's own
   sandbox mode uses) occupies the same Seatbelt/Linux+proxy niche but is a TS/npm
   package, experimental, and has no phantom-token credential story; it was not cloned or
   verified this session. The container-tier candidates (ysa, OpenShell) and the sbx
   microVM we already run are complements on a different rung, not substitutes — nono
   itself recommends composing with them (`docs/cli/internals/containers.mdx`).

**What keeps this honest** (macOS first, since that's the dev machine): Seatbelt
enforcement is static — no runtime capability expansion (SIP breaks the DYLD mechanism;
`security-model.mdx:168-176`), so profiles must be right up-front; Seatbelt **cannot
filter TCP by port** (a port-list request returns `NetworkFilterUnsupported`,
`macos.rs:760-769`), so with network left on, localhost services (Postgres, Ollama, the
Phoenix endpoint) stay reachable from contained commands; TCC can still deny paths the
profile allows; approval backends are terminal-only today (webhook/policy "planned",
`supervisor.mdx:99-104`), so dynamic in-run approvals cannot route to our gate surfaces
yet — fine for v1, since our approvals are pre-exec by design. On Linux (secondary),
Landlock's network rules filter by *port only, not address* (`capability.rs:892`), a
nuance their "localhost proxy port" phrasing glosses; kernel ≥5.13 for fs, ≥6.7 for port
rules.

## How to read this document

Recommendations: **ADOPT-AS-TOOL** (shell out to the binary; new axis, earned here),
**BUILD-ON** (ours to design, enabled by adoption), **BORROW-REFERENCE** (read their
implementation as the spec for something we build), **ALREADY-COVERED**, **SKIP**, and
**TRACK** (parked on a named trigger). Tiers: **Tier 1** = the adoption spine, achievable
as one config-gated program; **Tier 2** = follows the spine, needs a design decision;
**Tier 3** = polish/parked. Per-entry fields as usual: **Where in nono** (file:line —
"start here," not gospel), **What**, **Gap in jido_radclaw** (verified against source
2026-07-03), **Why it matters**, **Adoption sketch**. IDs are `N<tier>-<seq>`.

One recurring translation note: nono has two execution modes with different powers.
**Direct** (`nono wrap`) applies the sandbox and `exec()`s — transparent stdio/signals/
exit codes, no extra process, but no proxy, no rollback, no audit, no diagnostics
(`exec_strategy.rs:368-423`; `WrapSandboxArgs` drops the proxy flags, `cli.rs:1440-1668`).
**Supervised** (`nono run`) forks first and keeps an unsandboxed parent for the network
proxy, credential injection, rollback, audit, and (Linux-only) capability expansion
(`exec_strategy.rs:425-458`). Tier 1 rides Direct; Tier 2 is what Supervised buys.

---

## Tier 1 — The adoption spine

### N1-1. Contain the host command spawn under `nono wrap` (the third rung)

**Recommendation**: ADOPT-AS-TOOL — the load-bearing entry; everything else conditions on
it.

**Where in nono**: `crates/nono-cli/src/exec_strategy.rs:368-423` (Direct mode: apply
sandbox to current process via `Sandbox::apply_auto`, then `execvp` — nono disappears
from the process tree; stdio, controlling TTY, signal disposition, and exit codes are the
target program's own); `cli.rs:1393-1413` + `docs/cli/internals/capability-manifest.mdx`
(`--config <manifest.json>`: a fully-resolved, schema-first JSON policy — filesystem
grants/denies, network mode, process modes — mutually exclusive with ad-hoc flags;
`nono profile show <p> --format manifest` exports one); `cli.rs:1426,1665` (`--dry-run`
on both `run` and `wrap`: "show what would be sandboxed without executing" — policies are
testable); `docs/cli/internals/containers.mdx:14,183-203` (~0ms/~0MB claim and the
mechanism behind it: no VM, no namespace — build capability set, apply kernel LSM policy,
exec; per-invocation independence, no daemon, no locks); `crates/nono/src/sandbox/macos.rs:486-772`
(the Seatbelt profile it generates: `(deny default)`, keychain-daemon Mach-lookup denies,
allow-discovery-deny-content for sensitive paths, `file-map-executable` restricted to the
granted read set); `security-model.mdx:117` (fully unprivileged — no root, no setuid).

**What**: Prefix a spawned command with `nono wrap --config <manifest> -- …` and the
kernel confines that process and all its descendants to the manifest's filesystem scope —
regardless of what the command is: `npx anything`, `python foo.py`, a script file, an
alias-riddled login shell. `--block-net` is available in wrap mode for no-egress runs.
Per-invocation cost is claimed ~0ms because nothing is provisioned.

**Gap in jido_radclaw**: The host tier has *no containment at all* — only the gate and
env hygiene. `backend_host.ex:135` spawns bare
`Port.open({:spawn, "sh -c '…'"}, [{:cd, cwd}, {:env, scrubbed}])` for every REPL/agent
`run_command`; the *default* Forge backend is `Runner.HostShell` with an explicit "not
sandboxed" warning (`lib/jido_claw/forge/runner/host_shell.ex:30,84`) — the sbx microVM
backend exists but is opt-in via `FORGE_SANDBOX=docker` (`config/runtime.exs:6-13`).
`Security.ShellCommand`'s documented residuals (`shell_command.ex:95-110`: the `npx`/
`nix run` family, interpreter script-files, login-file aliases) are exactly the cases
where analysis is *statically impossible* — today they resolve to gate-or-trust; the scan
README (§1) predicted containment as the missing middle.

**Why it matters**: This converts the residual class from "interrupt the operator or
trust the model" into "let it run; the kernel bounds the blast radius to the workspace."
An `npx` package or a prompt-injected script can no longer read `~/.ssh`, `~/.aws`, the
keychain (file *or* Mach route), or write outside the project — which is the actual
threat model here. And it upgrades the Forge *floor*: HostShell-wrapped becomes
"OS-contained by default" with zero container infrastructure, sitting under the sbx
microVM as a graduated ladder (none → contained → microVM), the same escalation shape the
scan admired in agentos.

**Adoption sketch**: A `JidoClaw.Security.Containment` module owning three things.
(a) *Availability*: binary discovery + version floor + a boot-time `nono wrap --dry-run`
canary; result cached in `:persistent_term`, emitted as a Trace event. (b) *Manifest
compilation*: per-workspace capability manifest (JSON via their published schema —
`crates/nono/schema/capability-manifest.schema.json`) granting `project_dir` (rw),
session tmp (rw), and a curated toolchain read set (OQ-3); content-hash-keyed cache file
under the session scratchspace. (c) *Spawn wrapping*: `wrap_spawn(line, workspace, opts)`
→ `{exe, args}` so `backend_host.ex:135` becomes
`Port.open({:spawn_executable, nono_path}, args: ["wrap", "--config", manifest, "--", "sh", "-c", line], …)`
preserving `{:cd, cwd}` and the existing scrubbed env (nono's own dangerous-var stripping
layers harmlessly on top). Apply the same helper at the HostShell runner's `OsCmd.run(sh,
["-c", …])` (`host_shell.ex:84`). Config `config :jido_claw, :containment` —
`enabled?: false` initially (flip after the install spike), `false` in test. **Fallback
semantics are the status quo, not fail-open**: containment absent/failed ⇒ spawn exactly
as today with the full approval floor intact (N1-2's relaxation keys on per-call verified
containment, never on config intent). Process-tree mechanics are unchanged: wrap `exec`s,
so the Port's OS pid *is* the sandboxed process and `OsCmd.kill_tree/1` behaves as today.
Streaming is untouched (no PTY in Direct mode; stdout pipes pass through). Verify-on-
install checklist: measure wrap latency against the ~0ms claim; run the suite's
`run_command` fixtures under a workspace manifest; confirm `git`/`mix`/`mise` work with
the curated read set (`--dry-run` + `nono why` are the debug loop).

---

### N1-2. A `:contained` tier in the approval floor — gate / contain / allow, for real

**Recommendation**: BUILD-ON (ours to design; N1-1 makes it sound).

**Where in nono**: The *guarantee* this rides on: `overview.mdx:15-56` (protects against
path traversal, symlink escape, credential theft, child-process escape — children
inherit) and the Seatbelt/Landlock inheritance semantics (`landlock.mdx:221-230`,
irreversible, inherited by all descendants). The *doctrine*: one kernel boundary, then
stop re-litigating inside it (`developer-workflows.mdx:15-58` — "let nono be the only
sandbox layer").

**What**: When a command will verifiably run contained, the parts of the approval floor
that exist because *we cannot know a command's reach* stop applying — the kernel now
bounds reach. The parts that gate *durable, workspace-visible decisions* stay.

**Gap in jido_radclaw**: The precedent is already shipped for the microVM tier: a
`run_command` under `sandbox: :docker` skips the whole shell pattern-matcher set because
"their *reasons* … are inapplicable in-container" (`tool_approval.ex:270-287`), with
trust anchored by `AgentRunner.validate_sandbox_scope` refusing the tier without a real
Docker-backed session (`agent_runner.ex:144-146`). The host tier has no analogue: every
`:opaque`-floor hit (runner/interpreter/parse scopes, `shell_command.ex:51-55`) gates or
blocks, even when containment would make the answer "let the kernel decide."

**Why it matters**: This is where adoption pays rent in *fewer interruptions*, not just
more safety. The `npx`-family and script-file residuals are common in real agent work;
today each is an approval round-trip. Contained, they can run — and the gate budget
concentrates on the decisions that deserve a human: commits, pushes, cron.

**Adoption sketch**: Extend `sandbox_from(context)` with a `:contained` tier, stamped
into `tool_context` by the run path *only when* `Containment.available?` held at
gate-time and the spawn site is committed to wrapping this call (the same
trust-by-structure discipline as the `:docker` tier: once the gate skipped because
containment was promised, the spawn must wrap-or-refuse — never silently run bare).
Relaxation is **partial**, unlike the docker skip: drop the `{:effect, :opaque}` and
`:structure` matchers (leakage/reach rationale — now kernel-bounded); **keep**
`:git_commit`, `:git_push`, `:crontab`, and the git-config-injection floors (workspace-
effect decisions on the real repo; crontab would fail at the kernel anyway, but the gate
keeps it a visible decision rather than a confusing EPERM). Config knob under
`:tool_approval` (`contained_relaxes_shell_floor: true`), defaults-win merge as today so
config can't widen it silently. Tests drive `gate/4` with explicit opts as now.

---

### N1-3. Contain external MCP stdio servers (the `npx` residual, at its worst site)

**Recommendation**: ADOPT-AS-TOOL (same helper as N1-1, different spawn site).

**Where in nono**: Same Direct-mode wrap; plus `docs/cli/features/environment.mdx`
(`allow_vars: []` = zero inherited env, per-profile `set_vars`) and the client pattern of
wrapping one long-lived process per sandbox (`clients/*.mdx`). For the later network
phase: `nono run` per server with `--allow-domain`/`--credential` (N2-1/N2-2).

**What**: Each configured MCP stdio server process runs kernel-confined to its own state
directory, instead of full user-filesystem reach.

**Gap in jido_radclaw**: External MCP servers are *third-party code we run on the host,
long-lived, network-active* — the highest-exposure processes we spawn. Today's control is
env-only: the patched STDIO transport builds a default-deny environment
(`core/mcp_stdio_transport_patch.ex:258`, `Env.scrubbed_port_env/1`), and AGENTS.md
documents the residual trust boundary explicitly (server startup sits outside the
per-call gate). The *filesystem* reach of `npx -y some-mcp-server` — the canonical launch
shape — is unbounded, and it's literally the `npx` residual `ShellCommand` documents,
running unsupervised for the whole session.

**Why it matters**: A malicious or compromised MCP package today can read every secret
file the user owns. Contained, it reads its own state dir and nothing else — and this
lands *before* the per-call approval gate even matters, at the layer the AGENTS.md trust
note says we currently just accept. Per-server profiles also give the operator a legible
statement of what each server can touch.

**Adoption sketch**: Extend the MCP endpoint schema (`.jido/config.yaml `mcp_servers:`)
with an optional `sandbox:` block per stdio server — `fs: [paths…]` (default: a minted
per-server state dir), `network: :inherit | :block` (v1; `:allowlist` arrives with
N2-1). The transport patch's `Port.open` call composes `Containment.wrap_spawn/3` when
the block is present and containment is available; absent/unavailable ⇒ today's behavior.
Ship default-off; turn on per-server after smoking each server against its profile
(`--dry-run` first). Document in the AGENTS.md MCP trust-boundary paragraph: item (1) of
the boundary (stdio subprocess env) gains a filesystem clause.

---

## Tier 2 — What supervised mode buys

### N2-1. Kernel-forced egress allowlists for long-lived host children

**Recommendation**: ADOPT-AS-TOOL, phase 2 (needs the supervised mode + a policy surface
decision).

**Where in nono**: `crates/nono/src/sandbox/macos.rs:726-751` (ProxyOnly: `(deny
network*)` + allow outbound only to `localhost:<proxy-port>` — raw-TCP bypass is
kernel-denied on macOS); `crates/nono/src/net_filter.rs:98-102,188-231` (host allowlist:
exact + `*.suffix` wildcards, suffix does **not** match the bare domain; the deny floor —
`169.254.169.254`, `metadata.google.internal`, `metadata.azure.internal`, link-local
ranges — checked before the allowlist *and* before the empty-allowlist allow-all
short-circuit, non-overridable); `filter.rs:55-92` + `connect.rs:69-101` (resolve DNS
once, connect to the checked IPs — rebinding closed); `proxy_runtime.rs:2165-2314` (one
proxy per invocation in the supervisor, OS-assigned ephemeral port, 256-bit session
token — concurrency-safe by default). Plain domain allowlisting rides the transparent
CONNECT path — **no TLS interception, no CA trust needed**; only L7 endpoint rules and
credential routes require the MITM machinery (`route.rs:102-139`).

**What**: `nono run --config <manifest>` with `network.mode: proxy` +
`allow_domains: […]` gives a host process domain-scoped egress, enforced by the kernel
(the child can only reach the local proxy) with policy decided in the supervisor's proxy.

**Gap in jido_radclaw**: Egress control exists only as the browse_web destination-policy
gate (one tool, application-layer) and the sbx `--network none` binary
(`docker.ex:311-318`). Host-spawned processes — MCP servers, Forge runner CLIs — have
all-or-nothing network. The scan README's middle ground (`allowedDomains`) is planned for
the sbx tier but has no host-tier story at all.

**Why it matters**: For the leakage half of the threat model, egress scoping is the other
shoe: fs containment stops *reading* secrets; an allowlist stops *shipping* anything else
out. Long-lived third-party processes (MCP servers) are the right first target — "this
server talks to `api.github.com` and nothing else" is exactly the operator-legible
promise per-server profiles should make.

**Adoption sketch**: Extend `Containment` with a supervised variant
(`run_spawn/3` → `nono run --config manifest -- cmd`) used where a policy declares
`network: {:allowlist, domains}`. Start with N1-3's MCP servers (per-server
`allow_domains` in the endpoint `sandbox:` block), then Forge runner CLIs (N2-2 rides
this). Per-run_command allowlists stay out of scope until a real need appears (per-
invocation proxies are cheap per their docs, but the policy-authoring UX isn't). macOS
notes to carry: `NO_PROXY` is forced empty (`server.rs:576`); processes that ignore proxy
env vars still can't bypass (kernel), they just fail — which is the right failure. Linux
note: Landlock port-only nuance (above) means the guarantee is "can't reach standard
ports," not "can only reach localhost" — document it, don't oversell it.

---

### N2-2. Phantom-token credential injection for runner CLIs and MCP servers

**Recommendation**: ADOPT-AS-TOOL, phase 2 — the deepest leakage-hygiene item on our
books.

**Where in nono**: `docs/cli/features/credential-injection.mdx:13-31,321-330` (the flow:
real secret loaded host-side into `Zeroizing` memory before the sandbox exists; the child
gets a per-session 256-bit *phantom token* in the SDK's env var plus
`*_BASE_URL=http://127.0.0.1:<port>/<service>`; the proxy validates the phantom, strips
it, injects the real credential at egress); `crates/nono-proxy/src/reverse.rs` (the swap);
`server.rs:305-344` (phantom env vars injected only for routes whose real credential
actually loaded); `crates/nono-cli/data/network-policy.json:172-209` (built-in routes:
**anthropic** — `env://ANTHROPIC_API_KEY`, `x-api-key` header; github —
`env://GITHUB_TOKEN`; openai, gemini, gitlab); `keystore.rs:270` (sources: macOS
Keychain, `env://`, `file://`, `op://`, `cmd://` lazy capture). The reverse path is plain
HTTP to localhost — **no TLS interception, no CA trust** for header-inject routes.
NOGENT.md's doctrine line: "Phantom tokens must not be accepted as real credentials
upstream."

**What**: A wrapped agent CLI (or MCP server) authenticates normally as far as it can
tell, but the process — and anything it was prompt-injected into running — never holds a
real credential. Exfiltrating its entire environment yields a session-scoped token usable
only through the local filtered proxy.

**Gap in jido_radclaw**: Real keys enter child env today wherever a child needs them:
Forge `claude_code`/`codex` runner CLIs and the consolidator's headless runs (fail-closed
*presence* checks exist, but the key itself rides the env), and MCP stdio servers via the
operator's endpoint `env:` overrides (the documented scrubbed-env escape hatch). Our
redaction pipeline protects *model-facing output*; nothing protects the *child process's
own memory/env* from the code it runs — which is precisely the layer prompt-injection
attacks.

**Why it matters**: For a personal platform whose agents run third-party code with
API-key-bearing environments, this eliminates the single worst leak: the key itself. It
also composes with N2-1 for free — a credentialed route is inherently egress-scoped to
its upstream, and per-route `endpoint_rules` can later narrow *which* API calls the
phantom authorizes (e.g. a GitHub token that can only touch specific paths/methods).

**Adoption sketch**: Supervised wrap for the Forge runner CLIs first (the `claude` CLI
honors `ANTHROPIC_BASE_URL`; the built-in anthropic route reads `env://ANTHROPIC_API_KEY`
from the *supervisor's* env, which our runtime already holds): `nono run --credential
anthropic -- claude -p …`. Precondition: N2-1's supervised plumbing. Then HTTP-API MCP
servers (github MCP et al.) via per-server `credentials:` in the `sandbox:` block. Keep
`ssh`/database secrets out of scope — nono has no non-HTTP swap story (env-injection
only, visible in the child; `credential-injection.mdx:1102-1104`), so don't pretend
otherwise. Note the honest residual their docs state plainly: injection can't stop a
process *misusing* a credential it's entitled to use — that's what N2-1's endpoint rules
and our approval gate remain for.

---

### N2-3. Denial legibility: sandbox denials as structured tool errors

**Recommendation**: BORROW-PATTERN (their client hooks) + small BUILD-ON (our error
envelope).

**Where in nono**: `docs/cli/clients/claude-code.mdx:341-471` — the pack's whole hook
apparatus exists to solve one problem: a kernel denial looks like a generic tool failure,
so the model thrashes; the hooks inject `additionalContext` telling the model "this was a
nono sandbox boundary; run `nono why`." `nono why --json` (`cli.rs:238,1943`) answers
"would this path/host/command be allowed, and which rule decides"; `NONO_CAP_FILE` +
`nono why --self` lets a *sandboxed* process introspect its own live capabilities;
supervised runs emit a diagnostics footer / `--diagnostics-json` (`RunArgs`).

**What**: When containment denies something, the model (and the operator) should see
*"denied by workspace containment policy: write outside `/path/to/project`"* — not
`sh: Operation not permitted`.

**Gap in jido_radclaw**: Our `Error.normalize` → redact → shape pipeline has no concept
of a policy denial; a Seatbelt EPERM surfaces as a bare nonzero exit with whatever the
program printed. The LLM's documented failure mode (per nono's own client docs) is
retrying variations of the denied action.

**Why it matters**: Containment survives only if it doesn't degrade agent competence.
One structured hint ("this is policy, not a bug — stay in the workspace or ask") converts
a thrash loop into a single sensible turn. It's also the observability hook: denial
Trace events tell us which manifests are too tight *before* operators feel it.

**Adoption sketch**: v1 heuristic, zero new process cost: when a wrapped command exits
nonzero and containment was active, pattern-match the captured output for the denial
signatures (`Operation not permitted`, Seatbelt's `deny` traces) and append a
`sandbox_denial` block to the error envelope — policy name, workspace root, and a
one-line "kernel containment, not a command bug" note for the model (mirroring the
`isError`-lifting care taken in the MCP shaper). v2, if/when supervised mode is the norm:
parse `--diagnostics-json` instead of heuristics, and optionally run
`nono why --config <manifest> --json <denied-path>` host-side to name the exact rule.
Emit `[:jido_claw, :tool, :containment_denial]` telemetry either way.

---

### N2-4. Their network-policy semantics as the spec for sbx `allowedDomains`

**Recommendation**: BORROW-REFERENCE (documentation-level; feeds already-planned work).

**Where in nono**: `net_filter.rs:98-102` (three metadata hostnames + link-local ranges
as a *non-overridable* floor, checked before the allowlist and before the allow-all
short-circuit); `net_filter.rs:137-139,221-225` (`*.example.com` matches subdomains only,
never the bare domain, never `evil-example.com` — with tests); `filter.rs:55-92`
(resolve-once-connect-to-checked-IPs); `config.rs:41-47` + `server.rs:546-552`
(`strict_filter`: an *explicit block posture* makes an empty allowlist mean deny-all,
instead of the footgun default); `config.rs:676-699` (endpoint-rule path normalization:
percent-decode, collapse double-slash, strip trailing slash — the bypass checklist);
NOGENT.md's review floor ("cloud metadata hosts and link-local IPs are a non-overridable
deny floor"; "empty allowlists are dangerous").

**What**: The five semantic decisions any egress allowlist must get right, already made,
reviewed, and regression-tested by a security team.

**Gap in jido_radclaw**: The scan README's next-step #4 — `allowedDomains` in the sbx
`sandbox_spec`, between today's binary default/`--network none` — has no semantics spec
yet. These are exactly the decisions we'd otherwise re-derive (and plausibly get wrong:
the bare-domain wildcard trap and the empty-list ambiguity are classic).

**Why it matters**: One vocabulary across tiers. When both the host-contained tier
(N2-1) and the sbx microVM tier speak "exact + `*.suffix`, metadata floor,
empty-means-deny-under-block," operators reason about one policy language, and the
composer can someday carry a single egress declaration down whichever tier runs the
stage.

**Adoption sketch**: When writing the sbx `allowedDomains` spec: lift the floor
(metadata + link-local, non-overridable, checked first), the wildcard semantics
(subdomain-only suffixes), and the strict-filter rule (an explicit block posture turns
empty into deny-all) verbatim; verify what sbx's host-side proxy already does about DNS
rebinding before trusting it; state the RFC1918 position explicitly (nono deliberately
allows private ranges for enterprise reach — on a tailnet that's a *decision*, not a
default to inherit silently).

---

## Tier 3 — Parked with triggers

### N3-1. Pre-run filesystem snapshot/rollback for host-mutating autonomous runs

**Recommendation**: TRACK — trigger: autonomous composer waves mutating the host tree
without a git seal (or the first "agent trashed uncommitted work" incident).

**Where in nono**: `crates/nono/src/undo/` — content-addressed SHA-256 object store,
APFS `clonefile()` copy-on-write with `fs::copy` fallback (`object_store.rs:330-353`),
Merkle-committed snapshots (`snapshot.rs:145`), `.gitignore`-aware exclusions
(`exclusion.rs`), atomic per-file restore; `--rollback` auto-selects supervised mode.

**Gap / why parked**: Recovery for agent-damaged *uncommitted* work is git-shaped today
(and camus C1-6/C2-6 push toward sealing before mutating anyway). The REPL's supervised
normal mode makes catastrophic host edits rare. If the trigger fires, `nono run
--rollback` around composer code-path runs is nearly free to try — the machinery (CoW on
APFS, gitignore exclusions) is the part we'd never build ourselves.

### N3-2. Per-command brokered sub-sandboxes (`command_policies` / tool-sandbox)

**Recommendation**: TRACK — trigger: nono ships the webhook approval backend.

**Where in nono**: `docs/cli/features/tool-sandbox.mdx`; `command_policy.rs`;
`tool-sandbox/platform/macos.rs:2016-2154`. PATH-shim interception of *argv at exec
time*, command identity pinned by dev+inode (`FileId`) so path aliases can't dodge, a
kernel outer-exec-gate closing direct-path bypass, per-command child sandboxes with
their own grants, and caller-chaining (`git` may use `ssh` while direct `ssh` stays
denied). Approval decisions route to backends — but only the terminal backend exists
(`supervisor.mdx:99-104`).

**Gap / why parked**: This is the kernel-enforced sibling of `ShellCommand.analyze` —
identity-based interception where ours is syntactic classification. But its *decision*
layer duplicates ToolApproval, and until approvals can route to a webhook (→ our
`AgentCase` gates, REPL `/gates`, web `/approvals`), a second interactive approval
surface on `/dev/tty` is a UX regression for us. When the webhook backend ships, revisit:
brokered per-command approvals landing in our gate machinery would be strictly stronger
than string-level gating. (Their legacy `--block-command` path is startup-only argv[0]
matching, explicitly bypassable — `command_blocking_deprecation.rs:11-16`; ignore it.)

### N3-3. Session audit ledger

**Recommendation**: SKIP for now, one garnish. We own a durable event log
(`WorkflowEvent`, Trace); nono's per-session audit (`audit-events.ndjson`, hash-chain +
Merkle integrity, optional DSSE signing) is a parallel store we don't need. The garnish:
if N2-3's denial telemetry proves noisy, supervised runs' `--diagnostics-json` / audit
events are the ground truth to reconcile against. Their own docs are honest that the
ledger is local host state a host attacker can rewrite wholesale
(`security-model.mdx:262-284`) — the same epistemic humility camus C1-6 taught us to
demand.

---

## Skip / Already Covered

- **S-1. Dangerous-env-var stripping** (`env_sanitization.rs:14-53` — `LD_*`, `DYLD_*`,
  `BASH_ENV`, `PYTHONSTARTUP`, `NODE_OPTIONS`, …). ALREADY-COVERED, stronger:
  `Env.scrubbed_port_env/1` (`redaction/env.ex:184`) is allowlist/default-deny — none of
  those vars ever pass. nono's blocklist runs redundantly on top post-wrap; harmless
  belt-and-suspenders, nothing to change on our side.
- **S-2. Registry profiles / packs.** SKIP. We compile manifests from our own policy;
  consuming third-party profiles imports their `session_hooks` — scripts that run
  **outside the sandbox with full host privileges** (`profiles-groups.mdx:145-182`).
  Sigstore signing + signer-pinning make the supply chain respectable, but "someone
  else's privileged pre-run script" is a trust grant our integration never needs to make.
  (Embedded *groups* — `deny_credentials`, `system_read_macos`, `git_config`, the
  toolchain read sets — are compiled into the binary and are fair game for OQ-3.)
- **S-3. Trust/attestation of instruction files** (Sigstore-signed file allowlists,
  seccomp-notify runtime verification on Linux). SKIP for now — startup-only on macOS
  anyway (`trust.mdx:530-551`), and the house-adjacent thread (camus C2-7 frozen judge
  assets) wants run-start *hash pinning*, which we can do without a signing ceremony.
  Revisit if `.jido/` assets ever ship to other machines.
- **S-4. C FFI / NIF embedding.** SKIP. v0.1.0, `publish = false`, apply-to-current-
  process only — a NIF would sandbox the BEAM itself (wrong grain), and a self-
  sandboxing port program is `nono wrap` with extra steps. The CLI *is* the API.
- **S-5. Resource limits.** SKIP/track. Memory-only, Linux cgroup-v2-only, refused
  elsewhere (`resource_cgroup.rs`; `supervised_runtime.rs:149,427`). macOS still has no
  enforcement (our `ulimit -v` note in `host_shell.ex:166-179` stays true). Nothing to
  adopt on the dev platform; revisit for Linux deploy hardening.
- **S-6. Sessions / attach / PTY multiplexing.** SKIP. Our shell "sessions" are
  Elixir-side cwd/env state over discrete spawns (`session_manager.ex`) — there is no
  long-lived shell PID to attach to, and `nono attach` solves a tmux-shaped problem we
  don't have. If a persistent interactive shell surface ever ships (the ghostty_ex spike
  in the scan README), revisit `nono shell` for it.
- **S-7. NOGENT.md as review doctrine.** Garnish alongside camus C2-8's five laws: the
  fail-closed rules ("compatibility cannot silently downgrade enforcement"; "prefer a
  clear deny over a surprising allow"; "user prompts are policy decisions — denial
  remains the default on no response") are quotable additions to the orchestration/gate
  review checklist when that lands. No new machinery.

## Open questions

- **OQ-1. Binary provisioning & version pinning.** Brew formula exists (`brew install
  nono`); pre-1.0 with "APIs stabilizing" means the manifest schema is semver'd but the
  CLI surface can still move. Decide: minimum version floor in `Containment.available?`,
  a `setup`-wizard prerequisite entry (present/absent, like ollama), and whether CI needs
  it (test.exs keeps containment off, so: no).
- **OQ-2. Default posture per surface.** Which spawns wrap by default once the spike
  passes — all host `run_command` (REPL included), or only agent-template-driven ones
  (mirroring how `sandbox: :docker` is template-stamped, `templates.ex:165`)? Leaning:
  template-stamped `:contained` default for workers, REPL `"main"` opt-in — the REPL is
  the supervised surface, workers are where autonomy lives. Also: does `:contained`
  become the Forge HostShell default (upgrading the "not sandboxed" floor) in the same
  change or a later one?
- **OQ-3. Toolchain read-scope curation.** A `(deny default)` profile needs the read set
  for real work: system paths, `mise` shims + installs, Homebrew cellar, `~/.gitconfig`,
  hex/mix caches. Options: (a) hand-curate a manifest fragment (transparent, ours to
  maintain); (b) generate a *profile* that `extends` nono's embedded groups
  (`system_read_macos`, `git_config`, language runtimes) and resolve it to a manifest at
  boot via `nono profile show --format manifest` (their maintenance, our trust in group
  contents — they're compiled into the binary, reviewable at `crates/nono-cli/data/policy.json`).
  Leaning (b) with the resolved manifest diffed + logged at boot. The `--dry-run`/`nono
  why` loop is the discovery tool either way.
- **OQ-4. Localhost policy on macOS.** With network default-allow (v1), contained
  commands can still reach local Postgres/Phoenix/Ollama — Seatbelt can't port-scope, so
  the *only* localhost lever in wrap mode is all-or-`--block-net`. Is that acceptable for
  v1 (it matches today exactly), and which workloads deserve `--block-net` outright
  (formatters, test runs — the AR-8b-2 no-egress instinct applied to host commands)?
- **OQ-5. Composer/stage integration.** Should a composer stage (or skill step) be able
  to declare its containment tier the way `%Stage{}` declares `model`/`effort` (AR-9
  seam) — `containment: :none | :contained | :block_net`? Cheap once N1-1 lands
  (`tool_context` already carries `sandbox:`); decide whether the catalog is the right
  owner or whether template-level (OQ-2) suffices.

## Cross-references and dependencies

```
N1-1 (wrap the spawn) ──┬──> N1-2 (:contained approval tier)
        │               └──> N2-3 (denial legibility)
        ├──> N1-3 (MCP stdio servers) ──> N2-1 (egress allowlists) ──> N2-2 (phantom creds)
        │                                        │
        │                                        └──(shared vocabulary)── N2-4 (sbx allowedDomains spec)
        └── OQ-2/OQ-3 gate the default-on flip

N3-1 (rollback)      — trigger: unsealed autonomous host mutation
N3-2 (tool-sandbox)  — trigger: nono webhook approval backend ships
```

Suggested first wave: **install spike + N1-1 + N1-3**, config-gated off-by-default — one
`Containment` module, two spawn sites, the latency/toolchain checklist from N1-1 — then
**N1-2** once wrapped runs have soaked in real sessions. N2-x are a second program, after
supervised mode earns its way in via the MCP-server case. Queue note: the current
`unadopted-next-five` queue has one item left (eval harness); this program is new-
capability work alongside it, not a displacement — operator's call on ordering. The scan
README's other next-steps (coderunner MCP trial, ysa hardening read, pi-sbx sbx work)
are unaffected except that N2-4 now feeds the pi-sbx item its semantics.

## Bottom line

nono is the missing rung, and it's buildable-around rather than adoptable-around: a
mature, unprivileged, security-pedigreed binary that wraps the exact `sh -c` spawn shape
we already funnel everything through, at claimed-zero cost, on the platform we actually
develop on. The three ideas that should not slip: **contain the host spawn** (N1-1 — one
call site turns `npx`/script-file residuals from gate-or-trust into kernel-bounded),
**make containment buy back interruptions** (N1-2 — the `:contained` tier beside the
shipped `:docker` skip, partial by design: reach floors relax, decision floors stay), and
**phantom-token credentials** (N2-2 — the only item on our books that removes the real
API key from agent-reachable memory entirely, and the reason to grow into supervised
mode). Everything else — rollback, tool-sandbox brokering, audit — is parked with named
triggers, because the goal is the threat model, not the feature list.
