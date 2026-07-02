# Features Worth Borrowing from Amber

Exploration notes — not a plan, not a commitment. Inventory **2026-07-02**.

Source: `~/workspace/research/amber` — **Amber**, a dinosaur-park management demo app
(companion to a YouTube video, per its README) demonstrating how to expose an Elixir
app's data and actions to AI agents. Phoenix 1.8 + Ash 3, ~4.4k lib LOC, almost all of
it igniter-generated boilerplate (auth LiveViews, park CRUD, DaisyUI overrides). The
**novel surface is ~40 lines across two files** plus router/OAuth config:

- `lib/amber/agents.ex` + `lib/amber/agents/mcp_actions.ex` — an **AshLua "code mode"**
  tool pair: instead of one MCP tool per action, expose `amber_lua_docs` +
  `amber_lua_eval` so an agent *scripts* against a declared set of Ash actions.
- `lib/amber_web/router.ex` + `lib/amber/oauth2_server.ex` — a **remote MCP server**
  (`AshAi.Mcp.Router` forwarded at `/mcp`) protected by a real **OAuth 2.1
  authorization server** (`AshAuthentication.Oauth2Server`) with Dynamic Client
  Registration, so claude.ai connectors / the ChatGPT Apps SDK can self-register,
  authenticate a user, and call the tools as that user.
- Role-based Ash policies (`park/dinosaur.ex:36-47`: rangers write, visitors read)
  making the *same* MCP tools do less for a read-only actor.

Amber is a demo, not a library — there is nothing to adopt *from amber's code*. What's
borrowable is the **stack recipe** it demonstrates, i.e. the hex packages it wires
together, evaluated for jido_radclaw fit: `ash_lua 0.1.6`, `ash_ai 0.7.2` (its
`Mcp.Router`), `ash_authentication_oauth2_server 0.2.2`.

Read alongside the three prior entries this interacts with, which split across two
lineages. The **payoff** lineage:
[`../hermes/FEATURES-WORTH-BORROWING.md`](../hermes/FEATURES-WORTH-BORROWING.md)
**T1-1 (Programmatic Tool Calling — NOT_ADOPTED)** and
[`../gust/FEATURES-WORTH-BORROWING.md`](../gust/FEATURES-WORTH-BORROWING.md)
**G2-2 (framed-port JSON-RPC for external runtimes — still open)** — batch the
model's calls server-side so intermediate results never enter context. And the
**medium** lineage:
[`../jidoka/FEATURES-WORTH-BORROWING-V2.md`](../jidoka/FEATURES-WORTH-BORROWING-V2.md)
**V2-7 (Lua-authored bounded workflow DAGs — WATCH)** — the corpus's one prior
sandboxed-LLM-Lua entry, deliberately unadopted on the plan-*authoring* axis (rolled
up in [`../jidoka/UNADOPTED-IDEAS.md`](../jidoka/UNADOPTED-IDEAS.md) §2, 2026-07-02:
LLM authorship is a posture change, not a feature gap — and a future `compose_skill`
would validate routes against the composer catalog, "certainly not embedded Lua").
AM-1 below takes V2-7's medium for T1-1's payoff, restricted to the *read* axis, and
is scoped so it does **not** reopen V2-7's verdict — the distinction is argued inside
the entry. This tree turns out to already carry most of the substrate for it.

## Determination (TL;DR)

**Amber's own code: nothing to adopt. The stack it demos: one high-value borrow, one
watch-with-trigger, everything else already covered.**

| Amber concept | As shown (dep) | What to take |
| --- | --- | --- |
| **AshLua "code mode" (docs + eval tool pair)** | `ash_lua 0.1.6` — ❌ blocked as-dep today (`lua ~> 0.3` vs our locked `1.0.0-rc.3`) | **The pattern (AM-1 — the gem): a scoped, policy-enforcing script surface over our Ash read-models. The Lua VM + a hardened eval action are ALREADY in this tree, unregistered.** |
| Remote MCP over HTTP + OAuth 2.1 + DCR | `ash_ai` router + `ash_authentication_oauth2_server` — ❌ not now | The *shape* (AM-2): WATCH with an explicit trigger (wanting cloud MCP clients). Substrate would be anubis `streamable_http`, not ash_ai. |
| Role-scoped MCP authorization (Ash policies per actor) | — | Folded into AM-2 (a remote surface's actor model), not separately actionable while MCP stays single-operator stdio. |
| Park domain, state machine, auth LiveViews, usage_rules skills | — | SKIP — igniter boilerplate or already present here (see Skip list). |

## How to read this document

Same axes as the sibling docs: **ADOPT-AS-DEP / BORROW-PATTERN / SKIP**, tiers scoped
to this codebase. Per entry: **Recommendation**, **Where**, **What**, **Gap**, **Why**,
**Adoption sketch**, dated **Status**. Amber cites verified firsthand; `ash_lua`
behavior from its hexdocs (v0.1.6) — re-verify at adoption time (the author marks it
"functional but a few pieces are still missing").

---

## Tier 1 — High Impact

### AM-1. "Code mode": a scoped `docs` + `eval` Lua pair over the app's data layer

**Recommendation**: BORROW-PATTERN (hand-roll on the in-tree Lua VM; ash_lua itself is
version-blocked today — see sketch). **Status (2026-07-02)**: NOT_ADOPTED — no
scriptable query surface exists on any tool surface (REPL agent or served MCP).

**Where (amber)**: `lib/amber/agents/mcp_actions.ex:6-10` — the whole feature:

```elixir
eval_actions do
  resource Amber.Park.Dinosaur, actions: [:read, :update]
  resource Amber.Park.Paddock, actions: [:read]
  resource Amber.Reporting.Incident, actions: [:read]
end
```

plus `lib/amber/agents.ex:4-7` exposing the two synthesized generic actions as AshAi
tools (`amber_lua_docs`, `amber_lua_eval`).

**What**: `AshLua.EvalActions` synthesizes two actions on a dedicated resource:
`:docs` (manifest-driven documentation of exactly the declared `(resource, action)`
pairs — designed to feed MCP `search_docs`/`get_docs`-style discovery) and `:eval`
(run a Lua script in which those actions are callable as `<domain>.<resource>.<action>()`,
returning Lua-conventional `(result, err)` pairs). The host supplies actor/tenant/context
at eval time; **scripts cannot read or change them**, and every call inside the script
flows through standard Ash authorization — amber's visitor role can script all it wants
and still can't write (`park/dinosaur.ex:42-46`). The client-facing payoff: an agent
answers "which paddocks hold more dinosaurs than their comfort threshold?" in **one
tool call** carrying a small script — filter/join/aggregate run server-side — instead
of N list-tool round-trips with every intermediate row inflating model context.

**Gap in jido_radclaw**: The corpus has circled this from three directions — two on
the payoff axis (where the standing plans are both heavy), one on the medium:

- **hermes T1-1** (programmatic tool calling): LLM-authored *Python* batching tool
  calls over a UDS/file RPC into the host — NOT_ADOPTED, needs Forge hosting + a stub
  generator + an RPC server.
- **gust G2-2** (framed-port JSON-RPC): the transport half of the same idea — still
  open, needs a warm process pool + a protocol.
- **jidoka V2-7** (Lua-authored bounded workflow DAGs — WATCH): the medium's prior
  sighting, and the reason this entry must be precise about scope. There the LLM
  writes sandboxed Lua that *authors* a bounded Runic DAG over an allowlisted action
  catalog under a hard `Lua.Policy` (defaults: 1.5s, 12 calls, 8 parallel, depth 64,
  6KB script, read-only actions required) with a `call_trace` audit
  (`lib/jidoka/workflow/lua.ex` + `workflow/lua/{policy,call_trace,plan}.ex`). The
  2026-07-02 rollup verdict stands: **No — watch.** AR-2's deterministic composer
  already delivers bounded-plans-over-a-catalog from the *platform* side; handing
  route authorship to the LLM is a posture change, not a feature gap; and the
  translation, if its trigger ever fires, is `compose_skill` validated against the
  composer catalog — "certainly not embedded Lua."

**AM-1 does not reopen that verdict.** The eval script here authors nothing and
drives nothing — no plan, no route, no workflow, no write. It computes a read and
returns a value, so the composer's deterministic-composition doctrine is untouched.
Nor can V2-7's translation absorb this slice: a composed plan's step results still
land in model context, and an ad-hoc filter/join/aggregate over read-models isn't a
plan — the point is that the intermediate rows never leave the sandbox. What V2-7
*does* hand this entry is its hardening design: the policy envelope and call-trace
are the reach-bounding complement to `LuaEval`'s resource caps (folded into the
sketch below). Conversely, should V2-7's trigger ever fire, AM-1's binding table +
policy envelope is the substrate a `jido.workflow(...)` binding would slot into —
behind that entry's posture decision, which stays its own explicit gate.

Meanwhile the *query-composition* slice of the gap sits right on top of assets this
tree already has:

- The **Lua VM is already a hard dependency**: `jido_shell` requires
  `{:lua, "~> 1.0.0-rc.1"}` (`deps/jido_shell/mix.exs:81`; locked `1.0.0-rc.3`).
- A **hardened eval action already compiles in this tree and is registered nowhere**:
  `Jido.Tools.LuaEval` (`deps/jido_action/lib/jido_tools/lua_eval.ex`, beam present in
  `_build`) — sandboxed-by-default Luerl (no `os`/`io`/`package`/`load`; Lua.ex 1.0 has
  no host shell/filesystem access at all), plus the execution hardening ash_lua does
  NOT document: `timeout_ms` with kill + watchdog, `max_heap_bytes` (default 64MB,
  `kill: true`), `max_call_depth`, deadline propagation from tool context.
  What it lacks is exactly amber's point: **bindings into the app's data with
  authorization** — bare `globals:` injection only.
- The natural binding targets are **already Ash resources with tenant-scoped read
  paths**: the orchestration read-models (`WorkflowRun`, `WorkflowEvent`,
  `AgentCase`), Solutions, Memory. Today an MCP client composing a question across
  runs pages `workflow_events` (byte-budgeted), calls `inspect_workflow` per run, and
  does the correlation in model context.

**Why it matters**: The token/latency argument from hermes T1-1 ("a 10-tool-call
investigation collapses to 1 inference turn; intermediate results never enter LLM
context") applies in full to the *data-query* slice — and that slice turns out to be
the cheap one: in-BEAM (µs startup, no Forge session, no container, no process pool),
capability-scoped (only declared actions exist in the sandbox — this is not
`python -c`), and policy-correct by construction (actor/tenant pinned by the host,
unreachable from the script). It composes with, rather than competes against, the
shipped MCP workflow surface: `workflow_events`/`inspect_workflow` stay the raw/derived
per-run reads; `lua_eval` becomes the cross-run *ad-hoc computation* surface. Honest
scope note: this does **not** close hermes T1-1 — no `run_command`, no web tools, no
file I/O in the sandbox (that's still Forge/G2-2 territory). It closes the
query/aggregate slice, which is the slice MCP clients actually hit today.

**Adoption sketch** (two paths — recommend Path A now, watch Path B):

- **Path A — BORROW-PATTERN, no new deps.** A `JidoClaw.Tools.LuaQuery` action
  (`use JidoClaw.Tools.Action`, so ToolApproval → redaction → shaping → cap wrap it
  automatically) that: builds a `Lua.new()` VM; lifts `Jido.Tools.LuaEval`'s hardening
  wholesale (timeout/heap/call-depth/watchdog — or delegates to it); injects a **small
  host-function table** (`Lua.set!` of Elixir callbacks) bound to explicit, read-only
  code-interface calls — e.g. `jido.runs(filter)`, `jido.events(run_id, opts)`,
  `jido.cases(filter)`, `jido.solutions(query)` — each closing over
  `tenant`/`session` from `tool_context` (present-nil coercion per the ToolContext
  trap). A sibling `lua_docs` renders the binding table's docs **from the same table**
  (single-source the capability and its docs — the `Stage.to_map/1` /
  `jido://workflows/{name}` precedent, G2-1b). Bound **reach** with V2-7's
  `Lua.Policy` envelope on top of `LuaEval`'s **resource** caps — they limit
  different things: a per-eval host-call budget (jidoka default 12) and script-size
  cap (6KB) alongside timeout/heap/call-depth, a read-only-bindings invariant
  asserted at registration, and a `call_trace`-style audit of which bindings ran
  (with args) emitted as Trace events. Publish both to the served MCP list
  and register for the in-REPL agent. Gate policy: read-only bindings ⇒ not
  require-listed (the sandbox is capability-scoped, categorically unlike the S-M1
  interpreter floor, which gates *host* interpreters); any future write binding ⇒
  require-list the tool the day it lands, same as `replay_workflow`.
- **Path B — ADOPT-AS-DEP (`ash_lua`), blocked today.** Blockers, in order:
  (1) `ash_lua 0.1.6` pins `{:lua, "~> 0.3"}`; this tree locks `lua 1.0.0-rc.3` and
  `jido_shell` hard-requires `~> 1.0.0-rc.1` — an override is a semver lie across a
  known API break (Lua.ex 1.0 changed sandbox semantics); needs upstream support for
  lua 1.x first. (2) Pre-1.0 (author: pieces missing; input/output renames pending).
  (3) It binds **Ash actions**, so the eval surface is only as good as the public
  read actions on our resources — some of today's read paths are code-interface/
  custom-query shaped and would need deliberate action-surface curation anyway
  (which Path A does explicitly per binding). Trigger to revisit: ash_lua releases
  lua-1.x support **and** we want broad Ash-wide exposure rather than a curated
  binding table.

**Security notes** (why this doesn't reopen settled review ground): Luerl executes on
the BEAM with no NIF/FFI/ambient I/O; the remaining abuse surfaces are CPU/memory
(bounded by LuaEval's kill-on-timeout + `max_heap_size` — keep both) and data volume
(bounded by the existing pipeline: `OutputRedaction` at the root, `OutputShaper`,
`OutputLimit`'s 32KB inline cap + ref-store — an eval result is just another tool
output). Bind reads only; never bind `run_command`-class actions into the VM.

---

## Tier 2 — Medium Impact

### AM-2. Remote MCP endpoint: OAuth 2.1 + Dynamic Client Registration in front of streamable HTTP

**Recommendation**: BORROW-PATTERN (the shape), explicitly **DEFERRED — WATCH with
trigger**. **Status (2026-07-02)**: NOT_ADOPTED, and correctly so for now.

**Where (amber)**: `lib/amber_web/router.ex:26-29,108-117` — a 3-line pipeline
(`AshAuthentication.Phoenix.Oauth2Server.BearerPlug`) in front of a forwarded MCP
router; `lib/amber/oauth2_server.ex` — the whole authorization server as one `use`
block (`scopes: ["mcp"]`, `dcr_enabled?: true`, consent + protocol routes, token/
client/consent Ash resources).

**What**: The full "cloud MCP client" recipe: an MCP client (claude.ai connectors,
ChatGPT Apps SDK) hits `/mcp`, gets redirected through a real OAuth 2.1 flow with
**Dynamic Client Registration** (RFC 7591 — the client self-registers, no operator
pre-provisioning), the user signs in and grants the `mcp` scope, and every subsequent
tool call carries a bearer token that resolves to a **user actor** — which Ash
policies then scope per role (amber's visitor gets read-only behavior from the *same*
tools). Tokens/consent/clients are durable Ash resources.

**Gap in jido_radclaw**: The MCP server is **stdio-only** by design (`serve_mode:
:mcp`; Gateway/Discord skipped in that mode), and the remote story is tailnet-shaped:
`GatewayExposure` (`web/gateway_exposure.ex`) opts the Phoenix gateway onto a
Tailscale hostname with loopback default and port-pinned origins. That covers the
operator's own devices. What it structurally cannot cover is **cloud-hosted MCP
clients** — claude.ai connectors can't join the tailnet and can't spawn a stdio
process. Notably, the transport half already exists in-dep: anubis 1.6.2 ships a
server-side `streamable_http` transport (`deps/anubis_mcp/lib/anubis/server/transport/
streamable_http.ex`), unused here.

**Why it matters (and why not yet)**: The day "drive jido_radclaw's workflow surface
from claude.ai" becomes a real want, this is the reference shape — and doing it
*without* the OAuth layer (a bare token in a header on a tailnet-exposed port) would
forfeit per-user actors, consent, and revocation. But adopting now fails three ways:

1. **Dep blocker**: `ash_authentication_oauth2_server 0.2.2` requires
   `ash_authentication ~> 5.0-rc`; this tree locks **4.14.1** — a major-version
   upgrade (RC, with ash_authentication_phoenix knock-ons) purely on spec.
2. **Actor-model gap is the real work**: under `:mcp` the boot scope is deliberately
   tenant-wide (the documented REPL-minted-ref drill-in flow; S-M2 keeps session
   scoping off MCP). A remote multi-client surface inverts that: per-token actors,
   per-actor session scoping, and Ash policies on resources that today rely on
   tenant-scoped code interfaces. That's a security-architecture change, not a
   router change.
3. **Substrate**: don't adopt `ash_ai`'s `Mcp.Router` for this — it serves AshAi
   tools (Ash actions) and would stand up a *second* MCP tool substrate beside the 24
   `Jido.Action` tools (the fourth-orchestration-surface smell, again). The right
   port is the existing jido_mcp/anubis stack on its `streamable_http` transport,
   with the OAuth extension supplying only the bearer/consent layer — amber shows
   they compose cleanly at the router.

**Adoption sketch** (recorded for the trigger, not for now): serve the existing MCP
server module over anubis `streamable_http` mounted in the gateway router behind a
bearer pipeline; adopt `ash_authentication_oauth2_server` once it (and our
ash_authentication) are past the 5.0 RC line; scope `mcp` (read-rollup tools) first
and keep the standing doctrine — destructive controls (cancel, replay overrides,
gate decisions) stay dashboard/REPL-only regardless of transport. Amber's
ranger/visitor policy split is the template for the actor model: same tool list,
policy-scoped reach. Pair with AM-1: a *read-only* `lua_docs`/`lua_eval` pair is the
single highest-leverage thing to put behind such an endpoint (one tool, whole
read-model), which is exactly amber's configuration.

**Trigger to revisit**: a concrete need for cloud MCP clients (claude.ai connector /
ChatGPT Apps) against this instance, or ash_authentication 5.x going GA — whichever
comes second.

---

## Skip / Already Covered

- **`ash_ai` as a dependency generally** (LLM tooling, prompt-backed actions,
  tool-per-action exposure) → **SKIP**. The LLM layer here is jido_ai; tools are
  `Jido.Action` modules behind the shared safety pipeline. Exposing one-tool-per-Ash-
  action is the *opposite* of this repo's curated 24-tool publish list (and of AM-1's
  thesis). Amusing lock-file fact: the trees already overlap anyway (`req_llm 1.16.0`,
  `ash_json_api` both present here).
- **OAuth for the web dashboard itself** → SKIP. The gateway has its own auth
  (`require_browser_auth` / `require_admin` pipelines, `admin_access.ex`); amber's
  OAuth server earns its keep only for third-party *clients* (AM-2), not first-party
  browser login.
- **`AshStateMachine` on Incident/Paddock** (`reporting/incident.ex:15-25`) → SKIP.
  Already a dep and a settled pattern here; the orchestration state machines are
  event-sourced beyond what the demo shows.
- **Incident + `IncidentEvent` append-log modeling** → SKIP. `WorkflowEvent` +
  projections already implement the grown-up version (fold + projection + terminal
  discipline).
- **Actor-scoped draft visibility policy** (`incident.ex:76-79` — author sees own
  drafts) → SKIP as a feature; noted inside AM-2 as the policy *template* for a
  remote actor model.
- **`usage_rules`-built agent skills in `mix.exs`** → ALREADY ADOPTED. This repo's
  `mix.exs` carries the same `usage_rules:` project config and builds the same
  `.agents/skills/{ash,phoenix}-framework` trees (amber's skill descriptions are
  byte-identical to ours — same generator, same convention).
- **Igniter-generated auth LiveViews, DaisyUI overrides, park CRUD, seeds** → SKIP.
  Demo scaffolding.

---

## Comparison: amber's demo stack vs jido_radclaw today

| Dimension | Amber (demo) | jido_radclaw (2026-07-02) | Verdict |
| --- | --- | --- | --- |
| MCP transport | HTTP (`AshAi.Mcp.Router`, streamable) | stdio (`jido_mcp`/anubis); anubis `streamable_http` present but unused | AM-2 (deferred) |
| MCP authn | OAuth 2.1 bearer + DCR + consent | none (local stdio; tailnet for gateway) | AM-2 (deferred) |
| MCP authz | per-user actor → Ash policies (role split) | tenant-wide boot scope, curated tool list, approval gates | AM-2 design note |
| Tool surface shape | **2 tools: `docs` + `eval` (code mode)** | 24 curated tools + 2 resources | **AM-1 — borrow** |
| Script sandbox | Luerl via ash_lua (no host I/O; no documented limits) | Luerl already in-tree (`jido_shell`→`lua 1.0.0-rc.3`) + `Jido.Tools.LuaEval` hardening (timeout/heap/depth), unregistered | **AM-1 — assemble ours** |
| Data layer for agents | Ash actions + policies | Ash resources behind tenant-scoped code interfaces | AM-1 Path A binds explicitly |
| Heavy code execution | — | Forge (containers, runners) — unchanged; hermes T1-1 / gust G2-2 still the plan of record for *general* scripted tool-calling | complementary |
| LLM-authored plans | — (amber's eval computes, never plans) | jidoka V2-7 WATCH: deterministic composer is doctrine; `compose_skill` (sans Lua) is the translation if triggered | AM-1 orthogonal — verdict untouched |

## Bottom line

Amber is a ~40-line demo wrapped in 4.4k lines of scaffolding — and one of those 40
lines is worth the visit. The **code-mode tool pair** (AM-1) is the cheapest credible
attack on the programmatic-tool-calling gap this repo has tracked since the hermes
review (T1-1), re-confirmed via gust (G2-2) — and whose medium jidoka V2-7 already
weighed for the plan-authoring axis and put on watch, a verdict AM-1 deliberately
leaves standing (its `Lua.Policy` envelope gets borrowed; its posture question does
not get reopened). Not by hosting Python in Forge, and not by handing the LLM route
authorship, but by
binding a curated, read-only, tenant-pinned slice of the Ash read-models into a Lua
sandbox whose VM (`lua 1.0.0-rc.3` via jido_shell) and execution hardening
(`Jido.Tools.LuaEval`, compiled and idle in `_build`) are **already in the tree** —
roughly a two-file borrow in the spirit of amber's own two files. Adopt the pattern,
not (yet) the `ash_lua` dep — its `lua ~> 0.3` pin conflicts with the locked 1.0-rc
line. The OAuth 2.1 + DCR remote-MCP recipe (AM-2) is genuinely good and genuinely
premature: blocked on ash_authentication 5.x and, more honestly, on an actor-model
redesign of the deliberately tenant-wide MCP scope — recorded with its trigger so the
day claude.ai connectors matter, the shape is on file.
