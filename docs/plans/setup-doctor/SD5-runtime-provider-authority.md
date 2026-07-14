# SD5 — Runtime provider-settings authority

*Builds: the runtime control plane that makes the validated provider
endpoint + credential what generation actually uses. Depends on: SD1
(derivation + `EndpointTrust`). Contracts owned: OD-1, INV-1 (conditional),
INV-2, INV-3, INV-4, INV-5, INV-10, INV-13, INV-23 (authority half), INV-7
(enforcement). **An architecture/security item in its own right — queue
#17b, no longer part of "make `/setup` a doctor."** Interview the D-series
below before building.*

> **What this owns.** Today, `providers.<p>.base_url` and `api_key_env`
> configure only the health probe; ReqLLM resolves generation through
> per-request opts → `:req_llm` app env → provider defaults / FIXED env
> vars, and nothing installs the config into that chain. SD5 closes the gap
> with **one atomic endpoint-and-credential snapshot** and a **consumption
> seam** at the Jido/ReqLLM request boundary — plus the typed refusal
> behavior, concurrency fencing, and operator authorization
> (`EndpointTrust` enforcement) that make redirecting generation traffic
> safe. OD-1 binds the outcome; the mechanism below supersedes the draft's
> rejected `Application.put_env(:req_llm, …)` bridge.

## Why the app-env bridge was rejected

The superseded draft implemented OD-1 as guarded `Application.put_env`
writes under `:req_llm`. Architecture review rejected mutable application
environment as the runtime control plane:

- **Global and unfenced** — two writers (boot, a repair loop) race readers
  mid-request; nothing makes the endpoint + credential legs change together
  (a torn pair sends the new endpoint the old credential, or vice versa).
- **Load-order-sensitive** — a put on an unloaded app is clobbered when
  `ensure_all_started` loads it later (the `run_command.ex:265-292` hazard);
  the draft spent a whole invariant (INV-1) defending against it.
- **Ownership needs a bolt-on registry** (draft INV-10) to avoid clobbering
  operator-supplied `:req_llm` config, and test isolation needs
  save/restore choreography everywhere the env is touched.

## Design direction (to interview, then pin)

**One atomic snapshot, consumed per-request.** A single typed term —
`%{generation: n, provider: p, endpoint: url | :default, credential:
{:value, v} | :blocked | :default_ok}` — swapped atomically (D1 picks the
store), built ONLY from the SD1 derivation + `EndpointTrust`-confirmed
settings. Consumption happens at the point where JidoClaw builds ReqLLM
requests (D2 finds the choke point): inject `base_url:` and the credential
as **per-request options** — the opts leg outranks app config in BOTH
ReqLLM orders (`Keys.get/2`: per-request opt first; `effective_base_url`:
model → opts → app config → metadata → default). Properties this buys:

- **Fencing for free** — readers take one snapshot per request; endpoint +
  credential always travel as a consistent pair; a repair republishes a new
  generation atomically (INV-13's reconcile-after-every-change becomes "one
  publish call after each desired-state change").
- **No global writes at all** — check-lane purity (INV-13), test isolation
  (INV-3 becomes "the seam serves nothing under `:sanitize_external_env`"),
  and inactive-provider non-interference (INV-10 — operator `:req_llm` env
  is simply never touched) hold by construction; INV-1's load-safety
  dissolves (record in Deviations).
- **The blocking rule survives, re-expressed** (INV-2): an absent
  resolution publishes `credential: :blocked`, and the seam turns that into
  an explicit failing credential at request build — generation must NEVER
  fall through to a provider's FIXED env var the doctor never probed.
  Keyless local ollama publishes the `"ollama"` placeholder (INV-23).
- **Refusal behavior** (INV-4): a canonicalizer-refused endpoint (shared
  guards with SD2 — INV-17's two layers; a refused value is never
  published) degrades that leg to `:default` while the credential rule
  stays in force; boot logs loudly with `/setup --check` guidance and does
  NOT fail — the doctor is the repair path.
- **Trust enforcement** (INV-7): snapshot admission is the enforcement
  point — an unconfirmed non-default `base_url`/`api_key_env` never enters
  a published snapshot. Session-only interactive confirms (SD6) publish for
  the running VM only.

Publish points — mutating lanes only (INV-13): `Application.start/2` (after
dotenv load + ambient-snapshot capture), and one reconciliation call in
`Setup.run/2` (SD6) after every successful config write, credential
installation, and session-trust confirmation. The check lane never
publishes.

**The doctor's endpoint verdict stays pure** (INV-6): SD2's opts-injection
comparison already models exactly what this seam does — the verdict is
"would the seam's injection win," no installed state consulted. After SD5,
the SD4 D1 disposition flips: a confirmed, guard-passing override reads
`endpoint: :equal` because generation now truly uses it.

## Named residuals (documented, not built)

- Per-request `base_url:` opts from call sites we don't own would outrank
  the seam — structurally absent today (no `lib/` call site passes it);
  re-verify at build, keep the residual note.
- Agent-writable `.jido/config.yaml` still *proposes* settings; only the
  trust boundary decides whether they're honored (tool-approval cross-ref).
- The general provenance guard (SSH `ServerRegistry`, MCP `endpoint_config`)
  remains queue #15 — this WS closes only the provider endpoint/credential
  slice of CB1-1 and #15 should generalize from the `EndpointTrust`
  precedent.

## Decisions (interview before build)

- **D1 — snapshot store.** `:persistent_term` (read-optimized, atomic
  swap, no process) vs a GenServer-owned ETS table (observable, supervised,
  easier test seams). Recommend `:persistent_term` for a
  read-mostly-write-rarely term this small, with the publish function as
  the single writer seam; take ETS if the interview wants runtime
  introspection surfaces.
- **D2 — the consumption seam.** Find the single choke point where
  JidoClaw's agent stack builds ReqLLM calls (`JidoClaw.Agent.Defaults` /
  `Jido.AI` request assembly — a code dig is the first task of this WS). If
  there are multiple call sites, one shared helper becomes the seam; the WS
  fails its review if injection is scattered.
- **D3 — does the snapshot cover more than the active provider?** The
  derivation is active-provider-shaped today. Recommend active-provider-only
  (matching the doctor), with the snapshot carrying the generation counter
  so a provider switch is one atomic flip.
- **D4 — docs placement.** Own `docs/system/` page (recommended — this is a
  runtime subsystem with its own trust boundary, not a CLI feature) vs
  extending `setup-doctor.md`. Either way OD-2's machine-guarded pairing
  applies.
- **D5 — fresh-VM verification shape.** The in-suite VM has already booted,
  so boot-owner pins are vacuous in-suite; keep the draft's fresh-VM spot
  drives (a `mix run -e` one-liner printing the effective URL +
  `Keys.get/2` source in a scratch dir; the cwd-vs-project conflicting
  `.env` agreement drive) as the whole-boot proof.

## Test plan

Seam-level (async: true, injected store): publish/refuse/degrade rows per
INV-2/INV-4/INV-23; trust-gated admission incl. malformed-fails-closed;
atomicity — a reader mid-swap sees old or new pair, never a torn mix;
sanitize-inert (INV-3). Live-pins (async: false, snapshot/restore, the ONLY
module touching real ReqLLM state): pinned through ReqLLM's REAL
`Keys.get/2` + `effective_base_url` — custom `api_key_env` resolves via the
seam; keyless ollama resolves the placeholder; **the blocking regression**
(custom name unset while the provider's FIXED env var is exported →
generation still refuses, never the unprobed fixed var); valid→invalid
transition (endpoint degrades, credential block survives); operator
`:req_llm` env untouched byte-identical across publish cycles (INV-10);
post-publish endpoint verdict `:equal` for a plain override, `:divergent`
for a model-level `base_url` fixture. Fresh-VM drives per D5.

## Docs & reconciliation (lands with this WS)

- The D4 system page + AGENTS.md bullet (or `setup-doctor.md` extension +
  `verified:` bump), covering: the snapshot contract, the seam, refusal +
  degraded-boot posture, the blocking rule, the `EndpointTrust` boundary
  (pre-dotenv ambient authority, fail-closed parse, session-only confirm,
  the `run_command`-forgeability rationale), and the residuals above.
- crabbox **CB1-1**
  (`docs/exploration/sandboxes/crabbox/FEATURES-WORTH-BORROWING.md:129`) +
  pre-argus README §15(a): dated **PARTIAL** cross-ref — the
  endpoint/credential slice closes here; #15 generalizes.
- Queue **#17b**: dated Status.
- OD-1's accepted behavior change (auto-cloud flip; overrides go live)
  lands in the page's residuals/behavior notes AND the WS Deviations log.
- `## Deviations` maintained in this doc as built — including INV-1's
  dissolution rationale if D1 confirms the no-app-env design.

## Cross-references

- [CONTRACTS.md](CONTRACTS.md) — OD-1, INV-1..5, INV-7, INV-10, INV-13,
  INV-17, INV-23.
- [SD1](SD1-configuration-foundation.md) — derivation + trust read-side.
  [SD2](SD2-provider-diagnostics.md) — shared canonicalizer;
  probe-what-you-use. [SD4](SD4-read-only-doctor.md) — D1 disposition flips
  when this ships. [SD6](SD6-repair-and-reconfigure.md) — repairs
  republish through this authority (INV-13).
- `docs/TRUST-BOUNDARIES.md` — the review rubric class this boundary
  belongs to; queue #15 (the general provenance guard).
