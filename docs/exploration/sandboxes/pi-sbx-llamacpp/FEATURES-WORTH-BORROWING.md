# Features Worth Borrowing from pi-sbx-llamacpp

Exploration notes — not a plan, not a commitment. Deep-dive **2026-07-03**, fulfilling the
"walk the pi-sbx kit against our existing sbx backend" next-step of the
[sandbox landscape scan](../README.md). Source:
`~/workspace/research/sandboxes/pi-sbx-llamacpp` (cuolm/pi-sbx-llamacpp, HEAD `3590a36`,
2026-06-16; jido_radclaw @ `0717a0f6`). Self-description: *"This guide runs the Pi coding
agent inside an isolated Docker Sandbox (sbx) microVM, with inference served by a local
llama-server running in router mode on the host machine"* (`README.md:3`). Shape: **the
smallest subject in the corpus — four files, 335 lines, zero code**: a 270-line setup
guide plus an sbx kit (`spec.yaml`, 18 lines; `models.json`, 21; `settings.json`, 4).
Maturity: 5 commits over one week (2026-06-09 → 2026-06-16), single author, MIT, quiet
since. Cites are firsthand reads of both trees, accurate to within a few lines; the
jido_radclaw side was mapped by a dedicated seams pass (2026-07-03). **Nothing was
installed or executed.** Because the subject is documentation *about* Docker's sbx, its
claims were additionally checked against Docker's published docs (get-started,
kit-reference, FAQ — fetched 2026-07-03): the kit's `allowedDomains`/kit mechanics are
vendor-corroborated where noted below; the `host.docker.internal`-through-the-proxy
routing behavior is **kit-only** (vendor docs are silent on host reach) and stays
spike-verified. One drift finding, minor and expected for a June guide against a moving
product: the kit's `spec.yaml` uses the pre-v0.32.0 schema (`kind: agent` + an `agent:`
block, both since renamed to `kind: sandbox` + `sandbox:`; deprecation-accepted per the
kit reference) — a synthesized kit of ours should use the current spelling.

Companion docs: the [sandbox landscape scan](../README.md) (this doc closes its pi-sbx
read item; the spike item remains, now fully specced);
[`nono/FEATURES-WORTH-BORROWING.md`](../nono/FEATURES-WORTH-BORROWING.md) — the critical
one: **N2-4 already owns the *semantics* spec for the sbx allowlist** (metadata deny
floor, subdomain-only wildcards, empty-means-deny posture); this doc supplies the
*mechanics* half (how sbx actually takes the policy), and PS2-1 below is the sbx-native
sibling of N2-2's phantom-token idea. And
[`coderunner/FEATURES-WORTH-BORROWING.md`](../coderunner/FEATURES-WORTH-BORROWING.md) —
its CR2-1 kernel-in-sbx successor would be a direct consumer of PS1-1/PS1-2 wiring. And
the [openshell deep-dive](../openshell/FEATURES-WORTH-BORROWING.md) (2026-07-03) grafts
onto this program from four sides: OSH1-1 re-motivates PS1-1 as *credential containment*
(the claude_code runner copies a full OAuth login file into sandboxes whose default
egress is open), OSH2-2 folds policy-lifecycle rules into PS1-1, OSH2-1 adds three
riders to PS1-2's endpoint injection, and PS2-1 is the reachable tier of OSH1-1's
credential-brokering ladder. And the
[agentos deep-dive](../agentos/FEATURES-WORTH-BORROWING.md) (same day) rides the program
twice: AO2-5 is PS1-1's missing **default-posture** decision (deny + LLM-provider
allowlist, with the replace-vs-merge footgun and an IPv4-mapped-IPv6 floor test case for
N2-4's semantics), and AO2-3's host-bridge — when its trigger fires — is PS1-2's second
host-reach consumer (agentos OQ-3 rides that spike).
Threat-model weighting applies throughout (personal, tailnet-only: LLM-misbehavior
containment + leakage hygiene): per-sandbox egress scoping and keep-inference-local are
both squarely inside it.

## Determination (TL;DR)

**Nothing to adopt — there is nothing that *can* be adopted. Borrow the kit as the worked
example it was included to be, and bank what the verification dig turned up beyond it.**
The scan already placed this subject correctly ("read this kit as the worked example for
our existing backend's next two features"); the deep-dive's job was to verify both sides
and extract the mechanics. Both scan claims held exactly: our network spec surface is
binary to the line (`docker.ex:311-312`), and no host-inference story exists anywhere in
`forge/`. What the dig adds: the concrete sbx mechanics (kit synthesis, dual host:port
allowlist entries, creation-time-only file injection), vendor corroboration of the
allowlist schema — which turned out to be **richer than the kit shows** (`deniedDomains`
with non-overridable precedence = a ready-made floor mechanism; proxy-managed credential
injection = the platform's phantom-token tier) — and one doc↔code divergence in our own
tree (generation ignores `providers.*.base_url`) worth fixing regardless.

| Part of pi-sbx-llamacpp | As a dependency | What to take |
| --- | --- | --- |
| `spec.yaml` network block + the dual `host:port` entries | No (18 lines of YAML) | **PS1-1**: the worked example for kit-synthesized per-sandbox egress allowlists |
| Host-inference wiring (`models.json` baseUrl + allowlist + pre-seeded settings) | No | **PS1-2**: the recipe for host-Ollama reach from inside a Forge sandbox |
| Kit `files/home/` injection pattern (config before first run; creation-time only) | No | Folded into PS1-1/PS1-2 sketches |
| llama-server router mode as the host stack | No | **S-1** ALREADY-COVERED by Ollama; flag set kept as garnish reference |
| Pi as the in-sandbox agent | No | **S-2** SKIP with a named trigger (local-model runner demand) |

Two further entries source from the **verification, not the kit** — a deliberate,
stated deviation from the standard anatomy (the corpus records what the dig found):
**PS2-1** (sbx `serviceDomains`/`serviceAuth`/`proxyManaged` — discovered in the vendor
kit reference while corroborating the kit's network claims) and **PS2-2** (our
`base_url` doc↔code divergence — surfaced by the seams pass; INDEPENDENT).

## Why there is nothing to adopt

The dependency axes are inapplicable by construction: the subject is a guide. No binary
(ADOPT-AS-TOOL), no library (ADOPT-AS-DEP), no code to lift. Its entire value is
epistemic — it demonstrates, against the exact product our only sandbox backend runs on,
the two capabilities that backend lacks, and it documents three sharp edges a naive
implementation would hit (the dual-entry proxy-routing gotcha at `README.md:193`; the
files-injected-at-creation-only rule at `README.md:263-270`; router-mode model-id
matching at `README.md:227`). A 335-line subject earns a short doc: Tier 1 is the two
features, Tier 2 is the two dig discoveries, Tier 3 is deliberately empty — the skips
are terminal, not parked.

## How to read this document

Recommendations: **BORROW-REFERENCE** (read their material as the spec/worked example
for something we build — the workhorse here), **TRACK** (parked on a named trigger),
**INDEPENDENT** (worth doing regardless of the subject; the doc is just where it
surfaced), **ALREADY-COVERED** (cite the local equal-or-better), **SKIP**. No new axis
is coined. Tiers scoped to this project: **Tier 1** = the two features the sbx-backend
work needs (the standing scan next-step — unqueued but live); **Tier 2** = adjacent
discoveries from the dig (one TRACK, one small INDEPENDENT fix). Per-entry fields as
usual: **Where in pi-sbx-llamacpp** (file:line, "start here"), **Vendor corroboration**
(this subject's extra field — what Docker's docs confirm vs what stays per-the-kit),
**What**, **Gap in jido_radclaw** (verified against source 2026-07-03 via the seams
pass), **Why it matters**, **Adoption sketch**. IDs are `PS<tier>-<seq>`; `S-n` skips,
`OQ-n` open questions.

---

## Tier 1 — The two backend features, now specced

### PS1-1. Per-sandbox egress allowlist: synthesize an sbx kit carrying `network.allowedDomains` / `deniedDomains`

**Recommendation**: BORROW-REFERENCE — the sbx-side *mechanics* for the already-planned
`sandbox_spec` allowlist (scan next-step; semantics authority remains nono N2-4).

**Where in pi-sbx-llamacpp**: `kit/pi-llamacpp/spec.yaml:10-14` (the whole feature in
five lines — a public registry plus two host-port entries):

```yaml
network:
  allowedDomains:
    - "registry.npmjs.org"
    - "host.docker.internal:8001"
    - "localhost:8001"
```

`README.md:36-38` (the enforcement claim: only listed destinations are forwarded by the
sbx host-side proxy, everything else blocked); `README.md:193` (**both** the
`host.docker.internal:<port>` and `localhost:<port>` forms are required "to authorize
and route proxy traffic to the host" — the gotcha nobody would guess);
`README.md:141-143, 263-270` (kits are `spec.yaml` + `files/`, applied via `--kit`;
file injection happens at sandbox **creation only** — config changes mean
`sbx rm` + recreate); `README.md:65` (login-time base policy, "Balanced" recommended).

**Vendor corroboration** (Docker kit reference + get-started, fetched 2026-07-03):
`allowedDomains` supports exact domains, `*.wildcard` subdomains (subdomain semantics
unverified against N2-4's bare-domain rule — spike item), and optional `:port` suffixes;
**`deniedDomains` takes precedence over allows and is non-overridable across composed
kits**; multiple kits compose additively; kits load via `--kit` on "sandbox commands";
login base policies are Open / Balanced / Locked Down, with a *global* `sbx policy allow
network <domain>` CLI beside the per-kit mechanism. **Not** vendor-documented: how a
kit's allowlist interacts with the login base policy (OQ-2) and the proxy's enforcement
layer (OQ-3). Current schema kinds are `mixin | sandbox`; a network-only kit of ours
would be a `kind: mixin`.

**Gap in jido_radclaw** (verified 2026-07-03): the entire network surface is two
clauses — `add_network_flag(args, %{network: :none})` emits `--network none`, anything
else emits nothing and the sandbox rides the operator's login-wide default
(`lib/jido_claw/forge/sandbox/docker.ex:311-312`; the scan's premise, confirmed
verbatim). `allowedDomains`/`allowed_domains` appear nowhere in `lib/` or `config/`
(greps clean — only in these exploration docs). The thread-through for a new key is
four touch-points: the spec producer (`lib/jido_claw/front_door.ex:419-424` — today's
only in-tree producer setting `network: :none`), the recovery whitelist
(`lib/jido_claw/forge/recovered_spec.ex:159-182` — an unlisted key is **silently
dropped** on jsonb recovery, so forgetting this step fails closed but invisibly), the
create-args builder (`docker.ex:282-299`, beside `add_network_flag`), and — only if the
value needs shaping — the harness spec boundary (`lib/jido_claw/forge/harness.ex:1350-1359`;
today it normalizes only `:extra_mounts`, `:1384-1415`). There is no schema module for
`sandbox_spec`; it is a plain map read positionally by the backend.

**Why it matters**: leakage hygiene at the strongest boundary we ship. Today a Forge
sandbox is all-or-nothing — no egress, or whatever the login default allows. The middle
("this build sandbox may reach npm plus the host inference port, nothing else") is the
threat model's exact ask, enforced at the microVM's only network path rather than by an
ignorable env hint. And it is **port-granular where the host tier cannot be** — nono's
Seatbelt tier can't port-scope (their doc, macOS section), while sbx entries carry
`:port` suffixes. N2-4's "one policy vocabulary across tiers" goal needs this sbx half.

**Adoption sketch**: (1) `sandbox_spec` gains `allowed_domains: [binary]` (+ optional
`denied_domains`); `network: :none` stays the stronger tier and wins if both appear.
(2) `Sandbox.Docker.create` synthesizes a transient kit when the key is present — write
`<workspace_base>/kits/forge-<id>/spec.yaml` containing `schemaVersion: "1"`,
`kind: mixin`, and only the `network:` block; append `--kit <dir>` to the create argv
(OQ-1: verify `sbx create` accepts `--kit`; the kit demos it on `sbx run`). (3) Emit the
N2-4 floor as `deniedDomains` (metadata hosts + link-local) — sbx's own
denials-are-non-overridable rule then enforces the floor even under kit composition.
(4) Thread the recovery whitelist + a `normalize_allowed_domains/1`
(`recovered_spec.ex:214-219` is the pattern to copy). (5) Apply N2-4 semantics at our
boundary rather than trusting the proxy's (subdomain-only wildcards, explicit
empty-means-deny posture, a stated RFC1918 position — we're on a tailnet; reaching
private ranges is a *decision*). (6) The spike proves both directions from inside a real
Forge sandbox: listed domain reachable, unlisted domain blocked. *(2026-07-03:
[agentos AO2-5](../agentos/FEATURES-WORTH-BORROWING.md) folds in here — agent-runner
sandboxes default to deny + the configured provider's hosts; operator lists **merge
over** that floor (their replace-not-merge footgun silently severs LLM connectivity);
and the deny floor's test list gains the IPv4-mapped-IPv6 metadata bypass
`::ffff:169.254.169.254`.)*

---

### PS1-2. Host-local inference reach: `host.docker.internal` + endpoint config injected before first run

**Recommendation**: BORROW-REFERENCE — the worked recipe for the scan next-step's second
half ("prove host-Ollama reach from inside a Forge sandbox").

**Where in pi-sbx-llamacpp**: `README.md:36-38` (inside the microVM, `localhost` is the
VM; the host is `host.docker.internal` via the sbx gateway, *through* the host-side
proxy, allowlist-subject); `kit/pi-llamacpp/files/home/.pi/agent/models.json:4-6`
(`"baseUrl": "http://host.docker.internal:8001/v1"`, `"api": "openai-completions"`, and
a dummy `"apiKey": "local-llama"` — the endpoint is OpenAI-compatible and effectively
unauthenticated); `spec.yaml:12-13` + `README.md:193` (the dual allowlist entries,
PS1-1's gotcha, exist *for this feature*); `settings.json:2-3` + `README.md:240-242`
(defaults seeded via kit `files/` so the agent never prompts on first run);
`README.md:105-115` (pre-download models so the first in-sandbox call doesn't hit a
download timeout); `README.md:227` (router-mode model `id` must match the served name).

**Vendor corroboration**: none — Docker's FAQ documents neither `host.docker.internal`
nor the enforcement path for host-bound traffic (fetched 2026-07-03). The routing claim
is **per-the-kit**: plausible (it matches the alias our OneCLI config already assumes)
but spike-verified, not doc-verified.

**Gap in jido_radclaw** (verified 2026-07-03): no in-sandbox→host-inference story
exists — greps for `host.docker.internal`/`OLLAMA`/`base_url` across `forge/` are clean
except OneCLI. Three adjacent facts sharpen the gap. (a) The alias is already our
assumed host reach: the opt-in OneCLI egress proxy defaults to
`http://host.docker.internal:10255` (`config/runtime.exs:21`) and injects it as env-var
proxy hints into `.forge_env` (`docker.ex:539-573`) — precedent, not policy. (b) A live
instance of exactly this missing translation already exists: the consolidator's MCP
endpoint hands runs a `http://127.0.0.1:<port>/run/<id>` URL
(`lib/jido_claw/memory/run_server.ex:391-392`, bound to loopback at
`lib/jido_claw/memory/mcp_endpoint.ex:16-28`) that cannot work from inside a microVM —
harmless today only because the consolidator defaults to `sandbox_mode: :local`
(`config/config.exs:493`). (c) Our runners authenticate by **synced file, never env
key** (`forge/runners/claude_code.ex:151-217` `credentials.json`;
`forge/runners/codex.ex:150-174` `auth.json`; zero `*_API_KEY` hits in `forge/`) — the
scan's "key never enters sbx env" claim confirmed — so an inference-*endpoint* env var
is a new, deliberate channel, not a loosening of credential posture.

**Why it matters**: this is the "agents on local models inside strong isolation" path —
prompts and code never leave the host (leakage hygiene), zero marginal token cost, host
GPU speed. Concretely it unblocks: a codex/custom runner pointed at host Ollama (our
`JidoClaw.Providers.Ollama` is OpenAI-compatible — host-side
`http://localhost:11434/v1`, `lib/jido_claw/providers/ollama.ex:27` — which becomes
`http://host.docker.internal:11434/v1` in-sandbox); the consolidator's `:docker` mode
(same translation seam); and any future local-model in-sandbox agent (S-2's trigger).

**Adoption sketch**: rides PS1-1 — the allowlist entry is
`host.docker.internal:11434` (Ollama) or the chosen router port; per the kit's gotcha,
also carry the `localhost:<port>` twin until OQ-3 says it's unnecessary. Delivery of the
endpoint into the sandbox: `spec.env` (`harness.ex:1434-1442` → `.forge_env` →
`--env-file`) carrying `OPENAI_BASE_URL`/`OLLAMA_HOST`-style vars for env-shaped
runners, or the runner file-sync pattern for config-file-shaped agents
(`claude_code.ex:151-217` is the in-tree shape; the kit's `models.json`/`settings.json`
is the seed-before-first-run variant — and mind the creation-time-only rule,
`README.md:263-270`: endpoint changes mean recreating the sandbox, cheap for us since
sandboxes are per-session). Add one small helper — translate `127.0.0.1`/`localhost`
host URLs to `host.docker.internal` when the backend is `:docker_sandbox` — and use it
for the consolidator URL too. Spike success:
`curl http://host.docker.internal:11434/v1/models` from inside a Forge sandbox returns
the host's model list with the allowlist entry present, and is blocked without it.

---

## Tier 2 — What the dig surfaced beyond the kit

### PS2-1. sbx proxy-managed credentials (`serviceDomains` / `serviceAuth` / `proxyManaged`) — the platform's phantom-token tier

**Recommendation**: TRACK — trigger: the first sandboxed runner/tool needing a
**header-keyed** API credential (today's runners are file-OAuth), or the next OneCLI
maintenance/hardening pass.

**Where**: *not in the kit* — found in Docker's kit reference (fetched 2026-07-03) while
corroborating PS1-1: `network.serviceDomains` maps domain → service-id; `serviceAuth`
declares `headerName` + `valueFormat` (e.g. `"Bearer %s"`); `credentials.sources` reads
the secret host-side from env or file (with a `json:<dot.path>` parser);
`environment.proxyManaged` names vars the proxy populates at request time. The FAQ,
verbatim: credentials are injected "through a host-side proxy without exposing them to
the agent."

**Gap in jido_radclaw** (verified 2026-07-03): our equivalent is OneCLI
(`docker.ex:100-117,535-602`, opt-in via `FORGE_ONECLI_ENABLED`) — an **env-hint** proxy
(`HTTP_PROXY`/`HTTPS_PROXY` + `PROXY_AUTHORIZATION` bearer + CA cert) at
`host.docker.internal:10255`. The enforcement position differs qualitatively: a process
can simply ignore proxy env vars; the sbx proxy sits on the microVM's only egress path.
No built-in runner puts an API key into sandbox env at all today (PS1-2 fact c), so
there is no urgent consumer — hence TRACK, not do-now.

**Why it matters**: it is nono N2-2's phantom-token goal shipped by the platform we
already run — keys live host-side, auth is stamped per-request at the proxy, revocation
is host-side, and PS1-1's synthesized kit carries the declaration for free (same
`spec.yaml`). When the trigger fires, the decision is "extend OneCLI vs declare
`serviceAuth` in the kit," and this entry is the reference for the comparison.

### PS2-2. Wire `providers.*.base_url` into actual generation

**Recommendation**: INDEPENDENT — a doc↔code divergence in our own tree, surfaced by
this dig's seams pass; worth fixing regardless of the kit, and the host-side half of
the local-inference story.

**Gap in jido_radclaw** (verified 2026-07-03): `.jido/config.yaml`
`providers.<name>.base_url` looks authoritative but feeds only the reachability probe
(`lib/jido_claw/core/config.ex:255-256` hits `<base_url>/api/tags`) and the setup wizard
(`lib/jido_claw/cli/setup.ex:253`). Generation resolves through ReqLLM's registered
provider default — `default_base_url: "http://localhost:11434/v1"`
(`lib/jido_claw/providers/ollama.ex:27`) — and boot threads only the **model string**
into jido_ai aliases (`lib/jido_claw/cli/repl.ex:67-70`, `cli/run_command.ex:221`).
Nothing pushes a custom base_url into ReqLLM (grep clean). The current dev
`.jido/config.yaml` even sets `providers.ollama.base_url: "https://ollama.com"`, which
the generation path silently ignores.

**Why it matters**: operator confusion first (the config lies), capability second —
pointing generation at *any* OpenAI-compatible local endpoint (llama-server in router
mode, vLLM — the `ollama.ex` moduledoc's own claim) requires exactly this wiring, and
PS1-2's in-sandbox endpoints should inherit whatever this standardizes.

**Adoption sketch**: where boot already puts model aliases, also thread
`Config.base_url/1` into the provider layer via ReqLLM's supported override (per-call
`base_url:` in llm_opts, or provider app-env config); one test pinning
probe-URL == generation-URL so the divergence can't silently reopen. *(2026-07-03: ship
with [crabbox CB1-1](../crabbox/FEATURES-WORTH-BORROWING.md) in view — CB1-1 names this
exact field as the latent case that "activates the day it stops being decorative": once
wired, the provider key (host env, higher trust) follows a `base_url` chosen in
agent-writable `.jido/config.yaml`. The provenance guard — or at least its
destination-trust check on this field — should land with or before the wiring.)*

---

## Skip / Already Covered

- **S-1. llama-server router mode as the host inference stack.** ALREADY-COVERED by
  Ollama for the role the kit uses it for — one stable endpoint, dynamic model
  load/unload, OpenAI-compatible `/v1`: our recommended local stack (AGENTS.md), a
  registered ReqLLM provider (`config/config.exs:149-150`,
  `lib/jido_claw/providers/ollama.ex`), aliases wired (`config.exs:161-166`). Garnish
  kept: the router-mode flag set (`README.md:120-135` — `--models-max 1`,
  `--sleep-idle-seconds 240`, per-request child instances) is the reference if Ollama's
  VRAM/model-swap behavior ever chafes; once PS2-2 lands it would serve through the same
  OpenAI-compatible provider by URL alone.
- **S-2. Pi as a fourth Forge runner.** SKIP, named trigger: real demand for a
  local-model-driven in-sandbox coding agent (`claude_code` and `codex` both assume
  their cloud harnesses; a local-first third is plausible but evidence-free today). If
  it fires, this kit is the provisioning recipe — `models.json`/`settings.json` seeded
  before first run, the same file-sync shape as `claude_code.ex:151-217` — plus one
  hygiene detail worth copying, `npm install -g --ignore-scripts` (`spec.yaml:18`).
- **S-3. Model/quant selection (Gemma QAT GGUFs).** SKIP — operator-side content with no
  decision surface for us. The one durable detail (router-mode model `id`s must match
  served names, `README.md:227`) belongs on the spike checklist, not in an entry.

## Open questions

- **OQ-1. Does `sbx create` accept `--kit`?** Our backend's lifecycle is
  create/exec/rm (`docker.ex:64,282-299`); the kit demos `--kit` on `sbx run`, and the
  vendor phrase is "sandbox commands" without an enumeration (the `sbx run` CLI
  reference page was JS-rendered/empty to our fetcher). If create lacks it, options are
  reshaping that path around `sbx run`, or (worse) global `sbx policy allow network`
  mutations bracketing create. Answer with the CLI itself at spike start.
  **Third-party code evidence it does (2026-07-03):** crabbox's shipped docker-sandbox
  adapter passes repeatable `--kit` *and* `--mcp` flags to `sbx create`
  (`internal/providers/dockersandbox/client.go:89-116`, validated against sbx client/
  server v0.31.3) — see [sandboxes/crabbox CB-note-1](../crabbox/FEATURES-WORTH-BORROWING.md).
  Still confirm against the local `sbx` version at spike start, but the "create lacks
  `--kit`" branch is now the unlikely one.
- **OQ-2. Kit allowlist vs login base policy.** Vendor docs define kit-with-kit
  composition (additive; denies non-overridable) but not kit-vs-base ("Balanced"). If a
  kit's `allowedDomains` merely *adds* to Balanced, our "exactly this list" posture
  needs the Locked-Down base or verified replace semantics — N2-4's
  empty-means-deny-under-block rule is the stance to enforce at our boundary either
  way. Test with a canary domain in the spike sandbox.
- **OQ-3. Proxy enforcement semantics.** Inherited from N2-4's "verify what sbx's proxy
  does before trusting it": DNS-rebinding handling, IP-literal handling, whether
  portless entries mean all-ports or 443-only, and whether `host.docker.internal`
  traffic is genuinely allowlist-subject (the kit says yes, `README.md:38,193`; vendor
  docs are silent; the dual-entry requirement hints the proxy matches both the requested
  name and the routed destination). All empirically answerable in the same spike
  sandbox.

## Cross-references and dependencies

```
nono N2-4 (semantics: metadata floor, wildcard rules, empty-posture)
        └─ feeds ─> PS1-1 (mechanics: synthesized kit, allowedDomains/deniedDomains)
                       ├─ carries ─> PS1-2 (host-inference reach: allowlist entry +
                       │                    injected endpoint + URL-translation helper)
                       │                └─ host-side half ─> PS2-2 (INDEPENDENT
                       │                                     base_url wiring)
                       ├─ same spec.yaml, when triggered ─> PS2-1 (serviceAuth vs OneCLI)
                       └─ future consumers: coderunner CR2-1 (kernel-in-sbx),
                          front-door proto sandboxes (front_door.ex:416-428),
                          consolidator :docker mode (run_server.ex:391-392),
                          agentos AO2-3 host-bridge (agentos OQ-3 rides this spike)

OQ-1 / OQ-2 / OQ-3 gate the PS1-1+PS1-2 spike — one sandbox, one afternoon, all three
empirical.
```

Suggested first wave: the standing scan next-step, now fully specced — a single spike
session answering OQ-1..3 against the sbx CLI directly, then the four-file thread
(`front_door.ex` → `recovered_spec.ex` → `docker.ex` → `harness.ex`) with N2-4
semantics applied at our boundary. The same session should also clear the riders the
sibling digs parked on it: openshell OQ-1 (live `allowedDomains` mutability), OQ-2
(where egress denials become observable), OQ-4 (OAuth refresh-host enumeration), and
agentos AO2-5's default-posture decision — the full checklist now spans five docs (see
the [scan README's convergence map](../README.md)). PS2-2 is independent and XS-sized; it can ride any
session. Queue collision: none — verified 2026-07-03: `unadopted-next-five` is complete,
`unadopted-next-ten` is composer/judgment + capability work, and `docs/plans/` has zero
sbx/allowedDomains items (grep clean).

## Bottom line

The kit did exactly the job the scan hired it for: both missing backend features are now
confirmed on our side to the line (`docker.ex:311-312`; no host-reach story) and specced
on the sbx side, with the three sharp edges a naive build would hit recorded (dual
host:port allowlist entries; files inject at creation only; deprecated kit schema — use
`kind: mixin`). The dig's own yield beyond the kit is the part not to lose:
**`deniedDomains` is a ready-made non-overridable floor mechanism** for N2-4's metadata
deny-list, **`serviceAuth`/`proxyManaged` is the phantom-token tier shipped by the
platform we already run** (PS2-1, parked with a named trigger), and **our
`providers.*.base_url` config is currently decorative** (PS2-2 — fix independent of all
of this). Nothing here displaces nono: N2-4 stays the semantics authority; this doc is
its sbx-mechanics half.
