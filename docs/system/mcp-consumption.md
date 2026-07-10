---
type: subsystem
description: External MCP servers consumed as first-class tools — proxies ride the full safety pipeline, reach is allowlisted at registration, approval fails closed.
sources:
  - lib/jido_claw/mcp/consumer.ex
  - lib/jido_claw/mcp/proxy_generator.ex
  - lib/jido_claw/mcp/endpoint_config.ex
  - lib/jido_claw/mcp/server_spec.ex
  - lib/jido_claw/tools/action.ex
  - lib/jido_claw/core/mcp_stdio_transport_patch.ex
  - lib/jido_claw/core/canonical_hash.ex
  - lib/jido_claw/security/tool_approval.ex
verified: 2026-07-10
verified_sha: "b2cae5cd"
---

# External MCP Tool Consumption

## What & why

The platform both *serves* MCP (`JidoClaw.MCPServer` — see
[mcp-server-surface](mcp-server-surface.md)) and *consumes* it (`JidoClaw.MCP`).
Operators declare external servers in `.jido/config.yaml` under `mcp_servers:`
(stdio/sse/streamable_http); `JidoClaw.MCP.Consumer` (a boot GenServer with
off-process, crash-isolated prep) discovers each server's tools and binds a proxy
`Jido.Action` per tool via `JidoClaw.MCP.ProxyGenerator`.

## Invariants & contracts

- **The payoff: generated proxies `use JidoClaw.Tools.Action`** (not bare `Jido.Action`
  like the dep's `Jido.MCP.JidoAI.ProxyGenerator`, which returns remote data raw), so
  the full safety pipeline (`ToolApproval.gate → Error.normalize → OutputRedaction →
  OutputLimit` inside `MCPScope.wrap`) wraps every call automatically — inbound results
  are redacted + capped + generically shaped.
- **Reach is scoped at registration**: a server's `templates:` allowlist decides which
  templates register its tools — withheld tools the LLM never sees. `[]`/absent ⇒ all;
  a list ⇒ only those; the moment any server uses an allowlist the operator must
  include `"main"` to keep its tools on the interactive agent.
- **Default-on approval, fail-closed**: every `mcp_*` tool gates unless its server is
  trusted (`require_approval: false`) or the global `mcp_require_approval` is false —
  and an unknown `mcp_`-prefixed name (lost/unset policy) falls back to the global
  default (**fails CLOSED to gated, never to native**).
- **Trust boundary** — two things sit *outside* the per-call gate (`require_approval`
  gates tool *calls*, not server *startup*): the stdio subprocess env (scrubbed
  default-deny, below) and tool names/descriptions, which are **prompt-trusted before
  any call** — the gate can't stop description-borne injection, so configured servers
  are trusted for prompt metadata.

## Mechanics

- **Shaping**: an `mcp_`-rooted name takes `OutputShaper`'s `safe_shape_mcp/3`
  collapse-above-cap path (pretty-serialize → capture-capped ref-store → bounded
  `:output` wrapper with `isError` lifted); format-aware parsing stays
  `run_command`/`git_diff`-only.
- **Outbound**: the proxy scrubs args (now also strips ANSI, via the `OutputRedaction`
  root pass).
- **`:tool_error` re-surfacing**: a domain `isError: true` result is a *successful* MCP
  response per spec, but the dep promotes it to
  `{:error, %{type: :tool_error, details: <raw result map>}}`; the proxy re-surfaces it
  to `{:ok, data}` (matching `"isError" => true` in `details`, so
  transport/protocol/validation errors stay `{:error, _}`) — the headline failure case
  is shaped + `isError`-lifted + ref-stored rather than buried by `Error.normalize` and
  ref-lessly head-cut by `OutputLimit`.
- **Naming/schema**: names are `mcp_<server>_<tool>`, deduped + 64-char-capped +
  asserted `mcp_`-rooted. Per-server dedupe handles sanitized remote collisions;
  aggregate commit separately detects cross-server boundary ambiguity (for example,
  server `a` / tool `b_ping` versus server `a_b` / tool `ping`) and gives *every*
  colliding member a stable server/remote/local identity suffix before module
  allocation (bounded endpoint atoms remain backend identity only). The result is
  independent of config order and fresh endpoint-slot assignment, preserves every
  non-colliding historical name, and leaves approval/reach maps with a one-to-one
  provider name → backend/server-policy binding. The remote `inputSchema` is passed
  through directly as the action `schema:` — a JSON-Schema map is an LLM-only
  pass-through (`Zoi.map()`/`to_zoi` would advertise *no args*).
- **Bounded proxy identity**: a proxy module is stable for one
  `{server, endpoint, remote, local}` identity. Description/schema drift updates a
  runtime definition with a SHA-256 digest instead of minting a new atom/module;
  the Consumer detects that digest change and unregisters/re-registers the name so
  cached ReqLLM metadata refreshes. A failed refresh name remains pending per agent
  until a correlated reconcile task confirms success, so the following no-op tick
  retries a transient unregister/register failure. New remote-name identities have
  a cumulative 1,024-per-VM ceiling and strong digest-based module/name suffixes,
  so endpoint churn cannot exhaust the atom table or collide through `phash2`.
  Definition and endpoint-transport identities both route through
  `Core.CanonicalHash.sha256_term/1`; this is byte-identical to their former inline
  recipe, so the cleanup causes no runtime identity churn or migration.
- **Configuration/discovery convergence**: duplicate server names reject every
  conflicting declaration. Validated names bind for the VM lifetime to a
  lock-protected 64-atom fixed endpoint pool; config order/invalid insertion cannot
  reassign an endpoint, IDs are never reused, and binary server names never become
  atoms. Each binding pins a digest of URL/command/args/cwd/env/headers: transport
  drift under the same name fails loudly as restart-required, while templates and
  approval policy remain live. Killable off-process discovery creates inert staged
  descriptors only — no dynamic atom, proxy identity-capacity entry, or live definition.
  The Consumer resolves aggregate name collisions, allocates accepted modules, and
  publishes the complete definition aggregate in one registry write only after the
  correlated result wins. Thus a sibling failure, stale result, or hard kill preserves
  the complete last-known-good routing/schema/module/reach/approval set without
  capacity burn; it never turns a transient endpoint outage into an authoritative
  empty discovery that prunes healthy live tools.
- **Attach** is non-blocking: `attach_to_agent/2` (fire-and-forget, REPL boot +
  `:prepared`/restart rehydrate from `AgentTracker`) and `ensure_attached/3` (bounded,
  every agent-turn path — the Consumer defers its reply so the *caller* waits, never
  the Consumer). Every turn surface — chat (REPL + chat/4), handoff-routed turn, spawn,
  follow-up, skill-step — runs `ensure_attached(pid, template, 8_000)` keyed by
  `tool_context.agent_template`.
- **Allowlist enforcement** is `Consumer.modules_for_template/3` — reach, not gating
  (`tool_approval.ex` is untouched; a finer per-tool *approval* overlay for MCP stays
  an explicit non-goal).
- **Approval publication**: the Consumer publishes `%{tool_name => true|false|nil}` to
  `:persistent_term`; the private `ToolApproval.requirement/4` consults it per call.
- **The stdio patch**: `Port.open`'s `{:env}` overlays, not replaces, the host env, so
  a patched `Jido.MCP.Transport.STDIO` (`lib/jido_claw/core/mcp_stdio_transport_patch.ex`,
  registered in `DependencyPatches`) builds `:env` via `Env.scrubbed_port_env/1` —
  default-deny: host secrets unset; endpoint `env:` is the operator override map.
- **Prompt metadata hygiene**: `ProxyGenerator` strips control chars + caps description
  length (that is all it can do — see the trust boundary above).

## Config & telemetry

`.jido/config.yaml` `mcp_servers:` (per-server `templates:`, `require_approval:`,
`env:`); global `mcp_require_approval`. Results ride the `:output` shaping/trace
surfaces of the tool pipeline.

## Residuals & accepted risks

Deferred: a per-tool (vs per-server) approval overlay for `mcp_*`.

- **Policy choice (canonized, not an omission)**: an explicitly trusted
  (`require_approval: false`) server's tools keep their last-known-good trust
  through a prep-death outage window — the inverse of the documented
  gated-survives rule. Wiping the published policy to `%{}` on prep death would
  void explicit *gates* under a trusted global posture, the worse trade; both
  directions of LKG survival are pinned in `consumer_test.exs`.
- A collision-disambiguation flip permanently **retains** the now-inactive
  proxy identity plus a force-gated policy tombstone for whichever name is
  currently inactive. Allocation happens only on the first transition to a
  previously-unseen local name; repeated toggles between already-seen names
  **reuse** identities (restoring the collision re-activates the original
  disambiguated identities). Bounded and deliberate: identities are never
  reclaimed by design, and hitting the per-VM ceiling degrades gracefully.

## Source map

- `lib/jido_claw/mcp/consumer.ex` — discovery, attach paths,
  staged-result acceptance, retryable metadata reconciliation,
  `modules_for_template/3`, `:persistent_term` policy publication
- `lib/jido_claw/mcp/proxy_generator.ex` — bounded stable proxy identity/runtime
  definitions, inert staging + aggregate commit, naming, schema pass-through,
  `:tool_error` re-surfacing, description hygiene
- `lib/jido_claw/mcp/endpoint_config.ex` — `mcp_servers:` parsing, stable bounded
  endpoint identity + transport-drift fence
- `lib/jido_claw/mcp/server_spec.ex` — validated server declaration
- `lib/jido_claw/tools/action.ex` — runtime-name-aware shared safety wrapper
- `lib/jido_claw/core/mcp_stdio_transport_patch.ex` — the default-deny env scrub
- `lib/jido_claw/core/canonical_hash.ex` — the shared deterministic identity digest
- `lib/jido_claw/security/tool_approval.ex` — `requirement/4`, the fail-closed unknown
  arm
