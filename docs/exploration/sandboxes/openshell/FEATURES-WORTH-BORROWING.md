# Features Worth Borrowing from OpenShell

Exploration notes — not a plan, not a commitment. Deep-dive **2026-07-03**, closing the
[sandbox landscape scan](../README.md)'s "track, don't adopt" early read on this subject.
Source: `~/workspace/research/sandboxes/OpenShell` (NVIDIA/OpenShell, HEAD `6461677c`,
2026-07-02 — active the day before this review). Self-description: *"the safe, private
runtime for autonomous AI agents … sandboxed execution environments … governed by
declarative YAML policies."* Shape: a Rust workspace of **19 crates, ~220k LOC** (+3k
Python SDK, +2.7k proto, +13.6k docs lines) — gateway control plane (`openshell-server`),
in-sandbox supervisor (`openshell-sandbox` + `supervisor-network`/`supervisor-process`),
compute drivers (docker/podman/kubernetes/vm), policy engine + Z3 prover, OCSF crate,
ratatui TUI. Maturity: 936 commits since 2026-01-29, 77 contributors (a real NVIDIA team,
not a side project), Apache-2.0, DCO, no CHANGELOG (tag-driven releases + a rolling `dev`
tag), **alpha by its own banner** ("proof-of-life: one developer, one environment, one
gateway"), with evidence of breaking migrations (`install.sh:220-327` forces a gateway
destroy/recreate across a model change). Code maturity outruns the label: 7 TODO markers
in 220k lines, zero `todo!()`, extensive e2e. **Nothing was installed or executed this
review** — jido_radclaw @ `0717a0f6`; cites are firsthand reads of both trees, accurate
to within a few lines; runtime claims (boot times, the quickstart transcript) are
per-docs/e2e-test-names. Two adoption-relevant provenance facts up front: telemetry is
**default-on to a real NVIDIA endpoint** (`openshell-core/src/telemetry.rs:27`;
compile-out via `--no-default-features`, runtime opt-out env), and sandbox images live in
a separate `NVIDIA/OpenShell-Community` repo not reviewed here.

Companion docs: the [sandbox landscape scan](../README.md) (this doc closes its OpenShell
row); [nono](../nono/FEATURES-WORTH-BORROWING.md) — N2-2 phantom tokens and N2-4
network-policy semantics are the comparison spine for OSH1-1 and OSH2-2;
[pi-sbx-llamacpp](../pi-sbx-llamacpp/FEATURES-WORTH-BORROWING.md) — PS1-1/PS1-2 (the sbx
`allowedDomains` + host-inference program) is where most of this doc's borrows land, and
PS2-1 (sbx `serviceAuth`) is the credential tier we can reach without new infrastructure;
and [agentos](../agentos/FEATURES-WORTH-BORROWING.md) (dug the same day) — its AO2-5
(deny + LLM-provider default egress posture) is the same PS1-1 rider OSH1-1 arrives at
independently below.
Threat model weighting as always: personal, tailnet-only — LLM-misbehavior containment
and secret/data leakage hygiene, not hostile multi-tenant isolation. OpenShell is built
for the multi-tenant end; the useful surprise is how much of its machinery is *still*
aimed at our exact threat (an agent process that must not exfiltrate what it can read).

## Determination (TL;DR)

**Track the platform; borrow three mechanisms hard.** The scan's "track, don't adopt —
policy/proxy design reference" holds and is now specced. OpenShell-as-backend duplicates
what we run (its container drivers sit *below* our sbx microVM tier; its libkrun VM
driver matches the tier but is experimental and CI-runtime-untested on macOS) and
OpenShell-as-platform duplicates what we *are* (gateway control plane, durable state,
approval flows, TUI — our Postgres/AgentCase/LiveView/REPL stack). Its genuinely novel
capabilities — L7 method+path+binary egress policy, placeholder-credential brokering —
are inseparable from the in-guest supervisor stack, so there is no small adoptable piece.
But the dig converted the vague "design reference" into concrete entries, and the
seams pass surfaced our sharpest credential finding of the whole sandbox corpus (OSH1-1's
gap half: we copy a full OAuth login file into agent-readable sandbox fs with unrestricted
egress).

| Part of OpenShell | As a dependency | What to take |
| --- | --- | --- |
| Whole platform as a second Forge backend | **TRACK** (named triggers below) | — |
| Credential placeholder/resolver split + rotation | No | The reference spec for Forge credential brokering; immediate motivation for scoping claude_code egress (OSH1-1) |
| `policy.local` deny-guidance → proposal → human gate | No | **The best pattern in the subject** — graft onto ToolApproval/AgentCase (OSH1-2) |
| OCSF crate + logging doctrine | No (Rust, and we'd use a subset) | The audit-vs-tracing rubric, event kinds, severity ladder, dual-emit rule onto our existing `audit_events` (OSH1-3) |
| `inference.local` + router | No | The virtual-endpoint pattern for PS1-2's host-inference work (OSH2-1) |
| Policy lifecycle (static-vs-hot, LKG, revisions, audit-vs-enforce) | No | Design rules folded into the sbx `allowedDomains` spec (OSH2-2) |
| Z3 prover | No | The *delta-review* concept + binary-capability registry shape, sized down (OSH2-3) |
| Drivers / K8s CR / vfio / TUI / Python SDK | No | Skips and tracks (S-x) |

**Why the platform stays TRACK, not adopt** (argued against the temptation, which was
real): (1) **Tier**: Docker/Podman drivers are shared-kernel containers hardened with
netns+seccomp+Landlock — the same "wrong tier" verdict ysa earned against our sbx
microVMs; the VM driver (libkrun, Apple Silicon via Hypervisor.framework) matches our
tier but is explicitly experimental, cross-compiled for macOS with **no CI runtime boot
test** (`driver-vm-macos.yml` builds and packages only). (2) **Weight**: a persistent
gateway daemon (`127.0.0.1:17670`, brew-services/systemd-user), a supervisor image, one
compute driver per gateway (`openshell-server/src/lib.rs:1257-1269`), default-on
telemetry. (3) **Overlap**: gateway state, policy storage, draft-approval RPCs, and the
TUI re-implement surfaces JidoClaw already owns; running both means two control planes
disagreeing about one sandbox fleet. (4) **Coupling**: the L7 proxy is not a component —
it only works fed by the supervisor (netns pinning, binary identity via
`/proc/<pid>/exe`, placeholder resolver), which only works fed by the gateway (policy,
credentials, JWTs). **Named re-visit triggers**: the sbx `allowedDomains` spike (PS1-1)
failing to deliver usable egress scoping; a real need for method/path/per-binary-grade
sandbox egress policy (e.g. "agent may GET but not POST to api.github.com" becomes a
requirement, not a nice-to-have); or a GPU-passthrough / K8s-fleet phase.

## How to read this document

Recommendations: **BORROW-PATTERN** (translate the contract into our idioms),
**BORROW-REFERENCE** (their implementation is the spec for something we build),
**BORROW-RUBRIC** (lift evaluative criteria/text), **FOLD-IN** (absorb into a planned
item), **ALREADY-COVERED** (cite the local equivalent), **TRACK** (parked on a named
trigger), **SKIP**. Tiers: **Tier 1** = closes a verified gap on the leakage-hygiene
axis, actionable without adopting anything; **Tier 2** = design input for committed
programs (the PS1-x sbx work, the OSH1-2 loop); **Tier 3** = parked patterns and
garnish. Per-entry fields as usual: **Where in OpenShell** (file:line — "start here,"
not gospel), **What**, **Gap in jido_radclaw** (verified against source 2026-07-03),
**Why it matters**, **Adoption sketch**. IDs are `OSH<tier>-<seq>`; `S-n` skips; `OQ-n`
open questions.

One recurring translation note: OpenShell enforces *in the sandbox* (a supervisor
process co-resident with the agent — netns + embedded Rego engine + MITM proxy), while
our committed direction enforces *from the host* (Docker's sbx proxy applying
`allowedDomains` outside the microVM). Host-side is the architecturally stronger
placement (out of guest reach) but coarser (domain:port, no binary identity, no L7
method/path). Every Tier-2 entry below is about porting OpenShell's *semantics* onto
that coarser, stronger enforcement point — not about replicating its supervisor.

---

## Tier 1 — Verified gaps, actionable now

### OSH1-1 — Credential brokering: the placeholder/resolver split, and what it says about our Forge runners

**Recommendation**: BORROW-REFERENCE (their mechanism = the spec shelf), with the
immediate mitigation FOLDed INto PS1-1. The gap half of this entry is the dig's most
important product.

**Where in OpenShell**: placeholder minting `openshell-core/src/secrets.rs:526-536`
(`openshell:resolve:env:v{rev}_{KEY}`); the split `provider_credentials.rs:34-64` —
`child_env` (agent-visible, placeholders only; test asserts the real key is absent,
`:270-278`) vs `SecretResolver` (held by the supervisor/proxy); egress-time swap in
headers/bodies/websocket text `secrets.rs:262,304` plus full AWS SigV4 re-signing
(`supervisor-network/src/l7/rest.rs:509-522`); revision-scoped rotation without agent
restart, 8 generations retained, fail-closed on expiry (`provider_credentials.rs:10,
201-239`); even the GCE metadata emulator serves the agent a placeholder token, resolved
only on egress (`openshell-sandbox/src/google_cloud_metadata.rs:176`). Trust-boundary
caveat, recorded honestly: the resolver is a *sibling process in the same pod/VM* as the
agent (separated by UID drop + seccomp + Landlock), not an external trust domain — one
rung below nono N2-2's out-of-sandbox parent and sbx `serviceAuth`'s host-side proxy.

**What**: the agent's `ANTHROPIC_API_KEY` is a worthless string; the real key exists
only in the proxy's memory and appears only inside outbound requests to policy-allowed
endpoints. The README *undersells* this ("credentials … injected as environment
variables") — the same understated-docs drift nono showed, the direction you want.

**Gap in jido_radclaw** (verified 2026-07-03, corrected a premise this dig started
with): our Forge runners don't inject an API key at all — they copy **the host's whole
interactive login** into the sandbox. `runners/claude_code.ex:10,151-196` syncs
`~/.claude/credentials.json` (OAuth session, *more* powerful than an API key) into the
sandbox filesystem chmod 600, then runs `claude --dangerously-skip-permissions`
(`:28-29,67`); `runners/codex.ex:45-46,67,150-174,96` mirrors with `~/.codex/auth.json`
+ `--dangerously-bypass-approvals-and-sandbox`. The sandbox's default network is
**unrestricted** (`docker.ex:311-312`: only `%{network: :none}` emits a flag). So the
default `claude_code` Forge run is: a full login file, readable by an
approval-bypassing agent, in a microVM that can POST anywhere. Every other tier in this
corpus beats it: ysa's raw-key-in-env (Y-superseded), OpenShell's placeholders, sbx
`serviceAuth` (PS2-1), nono phantom tokens (N2-2). **One constraint the fix must respect
(operator doctrine, recorded 2026-07-03): the file sync itself is deliberate and
load-bearing.** Both tools authenticate via OAuth tokens that must live in those exact
files and formats, and both perform their own token refresh against the provider; remove
or rewrite the files and OAuth breaks. The exposure is therefore the *combination*
(login file × open egress), and the fix axis is **egress, not auth replacement** — the
files stay byte-identical. Elsewhere our hygiene is genuinely
good — MCP stdio children get default-deny env scrub (`security/redaction/env.ex:
93-106`), the `sbx` CLI itself runs scrubbed (`docker.ex:64,389`), vault-resolved
resource secrets ride an atomic 0600 `.forge_env` (`docker.ex:239-249`) — which is what
makes this one path stand out.

**Why it matters**: this is the house threat model's bullseye — the copied credential is
exactly the "secret the agent can read" that leakage hygiene exists for, and the
unrestricted default network is the exfil channel. The fix does **not** require
OpenShell's machinery.

**Adoption sketch** (a ladder, cheapest first — with an OAuth fence between rungs 1 and
2): (1) **Scope egress for credentialed runners** — when PS1-1 lands `allowedDomains` in
`sandbox_spec`, the `claude_code` runner should *default* to the provider's endpoints
(`api.anthropic.com`, `statsig.anthropic.com`, `sentry.io` per Claude Code's documented
needs, **plus the OAuth token-refresh host(s) — enumerate empirically, OQ-4** — or the
sandbox breaks at first token expiry) the same way `front_door.ex:410-422` already pairs
sketch sessions with `network: :none` — the copied credential becomes
unexfiltratable-except-to-its-provider, which is its job. **For OAuth-from-file runners
(both of ours today) this rung is the whole fix**: the synced files stay byte-identical,
the tools' own refresh flows run unmodified, only the reachable destinations narrow.
This entry is the *motivation sharpener* for PS1-1, not new work — and the agentos dig
landed the same rider independently the same day (AO2-5's deny+LLM-provider default
posture): two subjects converging on one default is the corpus's standard
design-validation signal. (2) **Proxy-managed credentials** where supported: sbx
`serviceDomains`/`serviceAuth` (PS2-1) is OpenShell's pattern at the stronger host-side
placement — the key never enters the VM at all. **Strictly for API-key-shaped auth**
(a static per-request header the proxy can inject): in our current setup *both* runners
are OAuth-from-file, so this rung has no eligible runner today; it goes live only if a
runner is switched to key auth or a new key-authenticated runner appears. (3)
Placeholder semantics (rotation without restart, SigV4-style re-signing): OpenShell's
`secrets.rs`/`provider_credentials.rs` is the reference implementation — but note the
ceiling: **even OpenShell does not phantom-ize file-based OAuth.** Its proxy never
parses or rewrites *responses* (`relay.rs:1145-1147`), so a client-driven refresh
exchange — whose response carries the new tokens — cannot be intercepted; its own
Claude Code support is API-key env injection or browser OAuth performed *inside* the
sandbox (`supported-agents.mdx:13-16`, `github-sandbox.mdx:62`), i.e. the tokens live
in-sandbox there too. Treat that as proof the industry answer for OAuth-file tools is
"contain the file's blast radius," not "broker the file."
Hygiene riders borrowed from their driver contract while we're in this code:
security-critical env keys are **overwritten after merging user/image env**, not merged
(`driver-docker/src/lib.rs:2190-2244`), and bootstrap tokens arrive as **bind-mounted
files, never env values** (`lib.rs:2232-2244`) — both cheap rules for `inject_env`/
`ResourceProvisioner`.

### OSH1-2 — Deny with guidance, propose with provenance, gate with a human: the policy-advisor loop

**Recommendation**: BORROW-PATTERN — the strongest genuinely-new pattern in the subject,
and it lands on machinery we already own.

**Where in OpenShell**: the agent-facing `policy.local` API
(`supervisor-network/src/policy_local.rs:39-73`): `GET /v1/policy/current`,
`GET /v1/denials`, `POST /v1/proposals`, `GET /v1/proposals/{id}/wait` (long-poll to a
terminal state, 1–300s). L7 403 bodies carry `AGENT_GUIDANCE` + structured `next_steps`
(`policy_local.rs:30,225-256`) — the quickstart's `{"error":"policy_denied","detail":
"POST … not permitted by policy"}` is what the agent actually sees. Proposals are
provenance-tagged (`agent_authored`, `policy_local.rs:512`) and **never self-approving**
(RFC-0002's hard non-goal, `rfc/0002:58`); the gateway referee validates → runs the
prover → computes the finding **delta vs baseline** → auto-approves only when the delta
is empty **and** an opt-in setting says `auto` (default `manual`; both conditions in
`openshell-server/src/grpc/policy.rs:862-954`) → else the proposal parks `pending` for
human review. The whole agent surface is behind a default-false flag
(`agent_policy_proposals_enabled`). Audit on auto-approve says "no new prover findings",
never "safe" (`grpc/policy.rs:848-850`).

**What**: a denial is not a dead end — it's a machine-readable teaching moment plus a
durable, human-gated path to the *policy change* (not a per-call retry). The agent
learns what was denied and why, drafts the narrowest rule that unblocks it, and waits.

**Gap in jido_radclaw** (verified 2026-07-03): our conversation-axis gate is close and
our policy axis is absent. `ToolApproval.gate/4` returns `{:error, %{code:
:approval_pending | :approval_denied}}` envelopes the LLM relays, backed by durable
run-less `AgentCase`s decided via `/gates` and `/approvals` — that's OpenShell's
proposal loop for *tool calls*. But: (a) approvals are single-use (`:consume`) — a
recurring legitimate need re-gates every call, with no path that says "make this
standing"; (b) deny envelopes carry no structured "how to request access" next-step;
(c) there is no denial ledger an agent can query — `browse_web` DestinationPolicy
denials emit one sanitized `Logger.warning` and vanish (`security/destination_policy.
ex:91-95,533-536`); (d) when PS1-1's `allowedDomains` lands, its denials (curl failing
with a proxy 403 inside the sandbox) will be *invisible* to the agent-facing loop
entirely unless we build this.

**Why it matters**: for a personal platform the human *is* the rate limiter — the
difference between "the agent thrashes against a 403 or gives up" and "the agent files
a scoped request I approve once from `/gates`" is most of the UX value OpenShell's
enterprise pitch carries, and we can have it without the gateway.

**Adoption sketch**: (1) enrich deny envelopes: `ToolApproval` and DestinationPolicy
denials gain a `next_steps` field ("a standing grant can be requested via …") — pure
data, no new process. (2) New AgentCase kind `:policy_proposal` (the `:tool_call` kind's
sibling): fingerprint = `{tenant, scope, proposed_rule}`, provenance `agent_authored`,
rendered in `/gates` + `/approvals` beside tool approvals; approval writes the rule to
the relevant store (tool-approval overrides; `allowed_cidrs`; later `allowedDomains`
per-template defaults). (3) A `request_access` tool (or an arm of the deny envelope the
agent can act on) that mints the case and optionally long-polls — our
`ToolApprovals.request/3` already blocks the same way. (4) Skip auto-approval entirely
until OSH2-3's delta checker exists; when it does, keep OpenShell's framing: opt-in,
double-conditioned, audited as "no new findings", never "safe". Collision note: this
extends the tool-approval gate family documented in AGENTS.md — same surfaces, same
`Cases.decide/4`, so it inherits the FOR-UPDATE fencing that machinery already has.
*(Cross-dig, same day: [nono N2-3](../nono/FEATURES-WORTH-BORROWING.md) is step (1)'s
containment-tier sibling — its `sandbox_denial` block and this entry's `next_steps` field
should be one policy-denial envelope design, not two.)*

### OSH1-3 — Finish our audit plane with their doctrine (not their crate)

**Recommendation**: BORROW-RUBRIC + BORROW-PATTERN, onto the `audit_events` resource we
already ship.

**Where in OpenShell**: the decision doctrine is written as contributor law in
`AGENTS.md:76-153` — **OCSF for observable sandbox behavior** (network/L7 decisions,
process lifecycle, security findings, config changes) vs **plain tracing for plumbing**;
a 7-class table (NetworkActivity, HttpActivity, SshActivity, ProcessActivity,
DetectionFinding, ConfigStateChange, AppLifecycle — OCSF v1.7.0, hand-rolled builders in
`openshell-ocsf/src/`); a severity ladder (Informational=allowed … Medium=denied …
Critical=timeout kills); the **dual-emit rule** (a security finding emits both the
domain event and a DetectionFinding); "never log secrets … the OCSF JSONL may be shipped
to external systems." Sink is an opt-in JSONL file with daily rotation; a representative
event: `class_uid 4001, action "Denied", dst_endpoint {domain, port}, actor.process
{name, pid}, firewall_rule {name, type:"opa"}` (`docs/observability/ocsf-json-export.
mdx:44-89`). Notably absent on their side: File Activity (fs is enforced, not audited)
and any LLM-call class (inference is just HttpActivity), and **no session recording at
all** — their audit plane is decision metadata only.

**What**: a small, closed set of security-*decision* events with severities and a
paste-ready "does this deserve an audit row?" rubric — the thing that keeps an audit log
from decaying into a second debug log.

**Gap in jido_radclaw** (verified 2026-07-03): we have the substrate they lack and lack
the coverage they have. `JidoClaw.Audit.Event` is a real append-only Ash/Postgres
resource (`audit/resources/event.ex:26-35,149-197`) with kinds `tool_call`,
`policy_denied`, `auth_event`, `session_*`, `memory_*`, actor/target axes, tenant-scoped
indexes, and an async writer with honest sync-vs-cast semantics (`audit/async_writer.
ex:25-43,93-120`). But: `tool_call` fires on `ai.tool.started` only — **no outcome,
result, or exit code ever lands** (`audit/signal_listener.ex:112-130`); `policy_denied`
covers only Ash authorization forbids (`audit/ash_tracer.ex:187-196`); **egress
decisions are not audit events** (DestinationPolicy denials → `Logger.warning`,
`destination_policy.ex:91-95`); Forge sandbox exec has no kind; LLM calls have no kind
(model+tokens exist only as telemetry, `reasoning/telemetry.ex:329-336`); and we run
three parallel Postgres event stores (audit / trace / workflow_event) with no stated
rule for which gets what — exactly the decay their rubric exists to stop. Our transcript
plane (durable sessions, `SubagentTranscript`, `ToolOutput` refs, WorkflowEvent) is
*stronger* than theirs; the two planes are complementary, not redundant.

**Why it matters**: leakage hygiene is an observability problem as much as an
enforcement one — "what did the agent try that was denied, and what did it actually
run" is the question this threat model asks after any incident, and today half the
answer is in log noise or nowhere.

**Adoption sketch**: (1) add kinds `egress_decision` (emit from DestinationPolicy
deny/allow-on-hole, and from PS1-1's proxy denials once observable) and `forge_exec`
(one row per sandbox exec/run: runner, argv head, exit code, duration); consider
`llm_call` last (telemetry may suffice — decide via the rubric, not reflex). (2) give
`tool_call` an outcome: either a completion listener beside the started-listener or a
disposition patch — OpenShell's `action/disposition/severity` field triple is the
reference shape for the `payload` map; borrow OCSF *names* (`action`, `disposition`,
`severity_id`, `dst_endpoint`) without vendoring the schema, so a future JSONL export
is OCSF-mappable. (3) paste their adapted rubric into `Audit`'s moduledoc as the
audit-vs-trace-vs-workflow_event decision table, including the dual-emit rule for
security findings and the "never log secrets — this table may be exported" law (our
`OutputRedaction` root already runs upstream of the tool path; assert the same for new
emit sites). Cheap, high leverage, no dependency. *(2026-07-03: the same-day
[agentos dig](../agentos/FEATURES-WORTH-BORROWING.md) adds a fourth surface the rubric
must classify — AO1-1's Forge transcript rows, the run-log plane. Complementary, not
redundant: AO1-1 records what the sandboxed agent *did*, these kinds record what was
*decided*; write the decision table to cover both so they don't collapse into one
store.)*

---

## Tier 2 — Design input for committed programs

### OSH2-1 — `inference.local`: a stable virtual endpoint instead of a taught host path

**Recommendation**: BORROW-PATTERN, grafting onto pi-sbx **PS1-2** (host-Ollama reach)
and PS2-2 (our decorative `base_url`).

**Where in OpenShell**: agents talk to `https://inference.local`; the in-sandbox proxy
detects provider-shaped requests (`supervisor-network/src/l7/inference.rs:64-151`),
strips caller credentials, and the sandbox-local router forwards with the real key from
a gateway-fetched route bundle (`openshell-router/src/backend.rs:229-253`;
`openshell-server/src/inference.rs:891-979`). The router **forces the
operator-configured model into the request body** regardless of what the agent asked for
(`backend.rs:297-302`), translates provider dialects (Vertex rawPredict vs
OpenAI-compatible), and hot-reconfigures via `openshell inference set`. Deliberately
**outside** network policy — adding an inference host to `network_policies` is
documented as a mistake that bypasses credential isolation (`best-practices.mdx:
240-251`). Honest caveats: streaming is capped/buffered (32 MiB, and
`examples/local-inference/README.md:42-65` documents a buffering bug), and it's the
supervisor stack again — not liftable.

**What**: the sandbox learns *one stable name* whose backend, credentials, and even
model choice are host-controlled and swappable at runtime; the agent never learns
`host.docker.internal`, ports, or keys.

**Gap in jido_radclaw** (verified 2026-07-03): no story for in-sandbox inference reach —
PS1-2's finding stands (nothing in `forge/` reaches host Ollama). Credit where due:
PS1-2's sketch already does endpoint *injection* (`.forge_env` carrying
`OLLAMA_HOST`/`OPENAI_BASE_URL`-style vars), so the delta this entry adds is narrower
than "endpoint vs path": it is the **indirection and its composition** — the injected
value names the *host-controlled route*, not the backend. Meanwhile OpenCode's "partial
coverage" fix in OpenShell (`ANTHROPIC_BASE_URL=https://inference.local/v1`,
`supported-agents.mdx:13-16`) is exactly the seam PS2-2 flagged on our side: our
`providers.*.base_url` feeds only the reachability probe, never generation.

**Why it matters**: PS1-2 is committed work; this entry firms up its *shape*. Keeping
the injected endpoint pointed at one stable route whose backend the host owns (sbx
`serviceDomains`/`serviceAuth`, or the dormant OneCLI proxy, owning
translation+credentials host-side) means backend swaps (Ollama ↔ llama-server router
mode ↔ cloud) change host config, not sandbox specs — and it composes with OSH1-1's
ladder because any credential rides the proxy, not the env.

**Adoption sketch**: three riders on the PS1-2 spike, not a redesign: (a) the injected
env should carry one harness-minted `INFERENCE_BASE_URL`-style name with the allowlist
entry and any auth attached to that name (the 127.0.0.1→`host.docker.internal`
translation helper PS1-2 specs becomes an implementation detail behind it); (b) adopt
the router's "operator config wins" rule for model selection — the same philosophy as
our AR-9 stage tiering (the platform, not the in-sandbox agent, decides the model);
(c) park dialect translation until a non-OpenAI-compatible backend actually appears.

### OSH2-2 — Policy lifecycle rules for the `allowedDomains` program

**Recommendation**: BORROW-PATTERN / FOLD-IN — a page of design rules for PS1-1 (and a
second reference beside nono N2-4).

**Where in OpenShell**: the four-domain split — filesystem/process **locked at sandbox
creation**, network/inference **hot-reloadable** (`README.md:117-128`;
`policy-schema.mdx:33`); reload is gateway-polling on `config_revision`/`policy_hash`
with an **atomic engine swap** and **last-known-good on any validation failure**
(`openshell-sandbox/src/lib.rs:1601-1770`; `opa.rs:399-428`); live updates apply to new
connections, in-flight streams finish under the old policy (`sandbox.md:179-181`);
default posture is **deny-all at every layer** (`data/sandbox-policy.rego:6,196,207`)
with a restrictive built-in fallback policy when none is supplied (`openshell-policy/
src/lib.rs:1043-1068`); per-endpoint `enforcement: audit | enforce` where **audit
(log-don't-block) is the default** (`best-practices.mdx:104-113`) — their one
posture-softening trap; non-overridable floors live *outside* the policy engine in Rust
(loopback/link-local/metadata/unspecified + etcd/k8s-API/kubelet ports,
`openshell-core/src/net.rs:55-72`, `proxy.rs:2353-2357`) while RFC1918 is deniable-by-
default but policy-openable; DNS is resolve-once-connect-to-checked-IPs
(`proxy.rs:773-986`) — the same rebinding discipline nono N2-4 recorded.

**What**: the operational half of egress policy — not *what* to allow (N2-4 covers
that) but *how policy changes behave*: what's mutable on a live sandbox, what happens
on a bad update, who wins between floor and allow.

**Gap in jido_radclaw** (verified 2026-07-03): PS1-1's spec covers the schema mechanics
(kit synthesis, dual host entries) but not lifecycle. Our spec surface is create-only
today (`docker.ex:282-312`); whether sbx can mutate `allowedDomains` on a running
sandbox is unknown (→ OQ-1). Our only floor engine, DestinationPolicy, is
browse_web-only — Forge sandboxes have *no* SSRF floor unless the sbx-side
`deniedDomains` floors (pi-sbx dig) carry it.

**Why it matters**: these are exactly the decisions PS1-1 will otherwise improvise
mid-spike, and two of them are safety-relevant defaults (deny-all base posture;
enforce-not-audit as *our* default — inverting OpenShell's, correctly for a personal
machine where nobody reads audit logs in real time).

**Adoption sketch**: fold into the PS1-1 plan: (a) classify every `sandbox_spec` field
static-vs-hot, and if sbx offers no live update (OQ-1), say so in the spec and make
"recreate to widen egress" the documented cost; (b) policy content is versioned data —
stamp a revision/hash into the spec and into OSH1-3's `egress_decision` audit payloads;
(c) floors (`deniedDomains`: metadata, link-local, tailnet CGNAT range) compose
non-overridably above any per-sandbox allowlist, mirroring `is_always_blocked_ip`'s
placement outside the mutable policy; (d) if we implement an audit mode for rollout,
default it off.

### OSH2-3 — Review the delta, not the policy (and the binary-capability registry)

**Recommendation**: BORROW-REFERENCE, gated on OSH1-2 shipping — take the concept, not
the Z3.

**Where in OpenShell**: `openshell-prover` encodes policy + attached credentials +
per-binary capabilities as SMT constraints and answers **four v1 reachability
questions** (`prover/src/finding.rs:28-33`): link-local/metadata reach;
credentialed reach through an L7-bypassing binary; *new* credentialed reach vs
baseline; *new* HTTP methods on already-credentialed endpoints. The auto-approval gate
consumes the **finding delta vs the current policy**, not an absolute score
(`grpc/policy.rs:475-478,613`); unknown binaries default to the dangerous side
(`registry.rs:180-188`); the capability registry is plain YAML per binary —
`registry/binaries/git.yaml` marks git `bypasses_l7: true, can_exfiltrate: true`. The
README is explicit it does **not** judge semantic risk ("PUT vs GET are both
authenticated actions; the reviewer decides") — it narrows what a human must look at.

**What**: mechanical review that answers "does this change *expand* what a credential
can reach?" — the one question a tired human approver reliably gets wrong at 11pm.

**Gap in jido_radclaw** (verified 2026-07-03): nothing shaped like this. Our nearest
relatives: `ShellCommand`'s invocation facts (`pushes?`, `:opaque`/`:runner`/
`:interpreter` scopes — per-command capability *classification*, same spirit, different
axis) and `solutions/`' semi-formal verification (different target). When OSH1-2's
proposal cases exist, the approver sees a raw rule diff with no risk framing.

**Why it matters**: sized to us, this is not an SMT problem — with one tenant, a static
runner set, and domain:port-grained policy, "compute the reach delta" is set arithmetic
over (domains added) × (credentials present in that sandbox) × (metadata/private-range
membership). A ~100-line Elixir check gets ~all of the prover's v1 value at our grain.

**Adoption sketch**: when a `:policy_proposal` case is created (OSH1-2), annotate it:
new hosts vs current policy; whether any added host is metadata/link-local/private
(auto-flag, never auto-approve); whether the sandbox holds a copied credential or
`serviceAuth` grant (OSH1-1's inventory tells us this); wildcard widening. Render the
annotation in `/gates`. A per-runner capability sheet (claude_code: carries login file,
talks anthropic; shell: whatever the spec mounted) is 20 lines of data riding the
existing runner registry — the registry *shape* borrowed, the YAML skipped. Auto-approve
remains a separate, later, opt-in decision (OSH1-2's framing).

---

## Tier 3 — Parked patterns and garnish

### OSH3-1 — Supervisor-dials-out control plane

**Recommendation**: TRACK — trigger: a real remote/multi-node Forge phase (the
clustering program's WS6 tail, or a crabbox-style scale-out revisit).

**Where/What**: every sandbox supervisor connects *outbound* to the gateway,
authenticates as a workload, and holds a session over which config, policy, credential
refresh, exec, file sync, and log push are multiplexed (`architecture/README.md:
136-154`; exec/files ride SSH-over-relay, not driver RPCs) — dissolving
gateway→sandbox reachability (NAT, pod IPs, port maps) into "supervisor must reach
gateway." The compute-driver contract stays lifecycle-only (8 RPCs,
`proto/compute_driver.proto:18-43`) because the relay carries everything else.

**Gap/Why**: our Forge is strictly local-node (`docker.ex` shells out to a local `sbx`;
`:pg` only routes control to the owning node, `forge/manager.ex:59-77`) — fine today.
If sandboxes ever run on other tailnet machines, this inversion (plus its corollary:
keep the backend behaviour lifecycle-thin, put the rich surface in a channel the
workload initiates) is the design to reread, and it composes with tailscale naturally.
Until then, nothing to do.

### OSH3-2 — SSRF floor: already covered, two garnishes

**Recommendation**: ALREADY-COVERED — by `Security.DestinationPolicy`
(`destination_policy.ex:108-123,344-376`): loopback/RFC1918/link-local/CGNAT/
unspecified + IPv6 equivalents + IPv4-mapped forms, resolve-all/deny-any, fail-closed
on resolver error — semantically matching OpenShell's `is_always_blocked_ip` +
`is_internal_ip` split (`net.rs:55-72,168-222`), with our `allowed_cidrs` playing their
`allowed_ips`. Garnishes worth a line in some future pass: their floor also blocks
**control-plane ports** (2379/2380, 6443, 10250/10255) irrespective of IP — ours has no
port dimension (moot until we're near k8s); and their floor applies to *all* sandbox
egress while ours guards exactly one tool — the generalization belongs to PS1-1's
`deniedDomains` floors (OSH2-2c), not to widening this module.

### OSH3-3 — MCP as a governed wire protocol

**Recommendation**: TRACK — trigger: an *in-sandbox* agent consuming MCP servers.

**Where/What**: the policy proxy parses MCP Streamable HTTP as a first-class L7
protocol — per-method and per-tool (`tools/call` + `params.name`) allow/deny at the
network boundary, strict tool-name grammar, batch-deny semantics
(`policy-schema.mdx:174-327`; `l7/jsonrpc.rs:10-55`) — with honest limits (tool
*arguments* unmatched; responses/SSE unparsed).

**Gap/Why**: different plane than our MCP story. We gate MCP at the *application* layer
— `JidoClaw.MCP.Consumer` proxies wrap every call in approval/redaction/shaping, gated
default-on (AGENTS.md's External MCP Tool Consumption) — which governs what *our* agent
invokes, with human approval, argument visibility, and output hygiene the wire-level
gate can't see. OpenShell governs what escapes a sandbox it doesn't trust — relevant to
us only when a Forge-sandboxed agent (claude in a microVM) starts calling MCP servers
*from inside*; then per-tool egress policy at the sbx/allowlist layer becomes the only
gate we'd have, and this schema is the reference. Not before.

## Skip / Already Covered (one line each)

- **S-1 Container drivers (docker/podman) as a backend** — SKIP: shared-kernel tier
  below our sbx microVMs; same verdict as ysa Y3-1, stronger implementation.
- **S-2 VM driver (libkrun) as a backend** — SKIP for now: matches our tier but
  experimental, macOS build cross-compiled with no CI runtime boot test; our sbx already
  delivers the microVM.
- **S-3 `openshell-vfio` GPU passthrough** — SKIP: Linux-x86_64+IOMMU+root; no GPU
  workload on the roadmap; (noted: clean RAII/crash-recovery design if that changes).
- **S-4 Kubernetes driver + `agents.x-k8s.io` Sandbox CR** — SKIP; one ecosystem note
  worth remembering: an upstream K8s agent-sandbox controller exists and OpenShell
  targets it rather than raw pods.
- **S-5 Ratatui TUI** — ALREADY-COVERED: REPL + LiveView dashboard (+ ghostty GX1-1 for
  the terminal pane).
- **S-6 Python SDK / `exec_python` via cloudpickle** — SKIP: sidecar over their CLI's
  auth cache; wrong substrate for us.
- **S-7 Compile-time per-RPC authz annotations + coverage test** — SKIP as machinery
  (Rust proc-macro grain; our Ash policies own this), the *coverage-test* idea is noted.
- **S-8 Vouch system / agent-first contribution pipeline** — SKIP: multi-contributor
  process; we're one operator (their `generate-sandbox-policy` skill idea is subsumed by
  OSH1-2's proposal loop).
- **S-9 Default-on telemetry** — not a borrow, an adoption caution recorded in the
  header (and a reminder that our own posture is zero phone-home).
- **S-10 Session recording** — nothing to borrow *from* them (they have none); our
  transcript plane is ahead; OSH1-3 closes the decision-event half they are ahead on.

## Open questions

- **OQ-1**: Can sbx mutate `allowedDomains` on a *running* sandbox (live policy update),
  or is network policy create-only? Decides how much of OSH2-2's hot-reload/LKG guidance
  applies vs "recreate to widen." Empirical; belongs to the PS1-1 spike's first session
  (alongside pi-sbx OQ-1..3).
- **OQ-2**: When PS1-1 lands, where do sandbox-egress *denials* become observable to us
  (sbx proxy logs? exit codes only?) — OSH1-2(c)'s denial feed and OSH1-3's
  `egress_decision` events need a source; if sbx exposes nothing, the loop's guidance
  half still works (the 403-in-sandbox is agent-visible) but the audit half degrades to
  proposal-time-only.
- **OQ-3**: For `tool_call` outcome capture (OSH1-3): completion signal vs a
  `Tools.Action` pipeline stage — pick one emit point and keep the started-row
  correlation (`request_id`) intact. Small design decision, one session.
- **OQ-4**: OAuth endpoint enumeration for OSH1-1 rung 1 — before defaulting
  `claude_code`/`codex` sandboxes to provider allowlists, enumerate the *full* endpoint
  set file-based OAuth needs (API hosts plus the token-refresh host(s)) by running a
  sandbox through a **forced token refresh** under the PS1-1 spike's observability and
  capturing what gets denied. While there: confirm whether a sandbox-side refresh
  rotates/invalidates the refresh token the *host's* copy of the file still holds — a
  property of today's sync worth knowing either way, independent of any egress change.

## Cross-references and dependencies

```
OSH1-1 credential gap ──motivates──▶ PS1-1 allowedDomains ◀──rules── OSH2-2 lifecycle
        │                                   │        ▲                     │
        │ ladder step 2                     │        └─ spec spine: nono N2-4
        ▼                                   ▼
   PS2-1 serviceAuth                 OQ-1/OQ-2 (sbx empiricals)
        │
        ▼
OSH2-1 inference.local ──shapes──▶ PS1-2 host-inference (+ PS2-2 base_url seam)

OSH1-2 deny→propose→gate ──annotated by──▶ OSH2-3 delta checker (gated on OSH1-2)
        │                                        │
        └──── denial feed needs OQ-2             └── auto-approve: later, opt-in only
OSH1-3 audit kinds ◀──payload fields from── OSH2-2(b) revision stamps; OQ-3
```

**Suggested first wave** (one session each, no collisions with the running
next-five/next-ten queues, which hold no sandbox items): **OSH1-3** (audit kinds +
rubric — self-contained, all substrate exists) and **OSH1-2 steps 1–2** (deny-envelope
`next_steps` + `:policy_proposal` case kind). OSH1-1's step 1 and all of Tier 2 land
inside the already-queued PS1-x program rather than as new work. The pi-sbx doc's PS1-1/
PS1-2 entries should gain one-line pointers here (done this pass); nono N2-4 likewise.

## Bottom line

1. **The `claude_code` runner copies a full OAuth login into an agent-readable sandbox
   with unrestricted egress** (OSH1-1's gap) — the sharpest credential finding in the
   sandbox corpus; PS1-1's `allowedDomains` work is now motivated as a *credential
   containment* fix, not a nice-to-have, and OpenShell's placeholder/resolver split is
   the reference shelf above it.
2. **Deny with guidance, propose with provenance, gate with a human** (OSH1-2) — the
   best pattern here, ~free on our AgentCase/ToolApproval machinery, and the thing that
   makes egress policy *livable* once PS1-1 tightens it.
3. **Finish the audit plane** (OSH1-3): egress decisions and Forge execs become
   `audit_events`, tool calls get outcomes, and their OCSF-vs-tracing rubric becomes our
   three-store decision table.
4. The platform itself stays **TRACK** with named triggers — its unique enforcement
   grain is real but inseparable from a gateway+supervisor stack that duplicates both
   our isolation tier and our control plane.
