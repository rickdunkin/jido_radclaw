---
type: surface
description: Key-only ArgusSocket + read-only workflows:run channels — authToken header auth, connect-time activity gate, minimal id+kind payloads, suspension force-disconnect.
sources:
  - lib/jido_claw/web/channels/argus_socket.ex
  - lib/jido_claw/web/channels/workflows_channel.ex
  - lib/jido_claw/web/plugs/api_key_auth.ex
  - lib/jido_claw/web/endpoint.ex
  - lib/jido_claw/orchestration/run_pubsub.ex
  - lib/jido_claw/route_composer/route_composer.ex
  - lib/jido_claw/platform/tenant/manager.ex
  - ui/src/lib/socket.ts
  - ui/src/routes/runs.tsx
  - ui/vite.config.ts
  - config/dev.exs
verified: 2026-07-11
---

# Channels Surface (argus live updates)

## What & why

The live half of the argus substrate (P4 of
`docs/plans/argus-ui-bootstrap/README.md`): a WebSocket surface the SPA
uses to hear that a run changed, with the OVERVIEW §4.2 posture —
**minimal payloads** (run id + change kind only) and the client refetches
via GraphQL, so the socket never becomes a second read API with its own
authorization surface. One socket (`/argus/ws`, key-only), one channel
family (`workflows:run:<uuid>`), and a client wrapper + runs page in
`ui/`. Slice 1 grows this (gates topics, per-step deltas,
`workflowEvents(afterSeq:)` catch-up); this page owns the bootstrap
contract.

## Invariants & contracts

- **Capability separation by construction.** `ArgusSocket` is a separate
  socket, NOT a `UserSocket` extension (a deliberate deviation from
  OVERVIEW §4.4's sketch): key auth on the shared socket would have
  unlocked the mutable `rpc:*` surface (`sessions.create` /
  `sessions.sendMessage`) for the SPA's baked key. `ArgusSocket` declares
  exactly one channel (`workflows:*`); `UserSocket`/`RpcChannel` are
  untouched. The boundary is test-pinned both ways: `rpc:*` is unroutable
  over `ArgusSocket`, and API-key params never authenticate `UserSocket`
  (sessions still do).
- **The key rides the `authToken` header transport, never params or the
  URL.** The endpoint mounts `socket("/argus/ws", ArgusSocket,
  auth_token: true)`; Phoenix 1.8 carries the token via
  `Sec-WebSocket-Protocol` (`base64url.bearer.phx.` subprotocol) and
  surfaces it as `connect_info[:auth_token]`. Because the key never
  appears in a URL, no `filter_parameters` change is needed — and none
  should be made (Phoenix's app-env default `["password", "token"]` also
  covers `_csrf_token`; replacing it would regress that). **The
  `auth_token: true` option must stay at the socket level**: the endpoint
  macro overwrites a nested `websocket: [auth_token: ...]` entry with the
  socket-level value (nil when absent), silently disabling the transport
  — the mount shape is pinned by an `__sockets__/0` test.
- **Connect mirrors the `/gql` pipeline** (`graphql-surface.md`):
  `ApiKeyAuth.authenticate_api_key/1` (the extracted shared validator —
  exactly one `:auth_event` audit row per attempt, HTTP or WebSocket; a
  token-less connect never reaches it, so the socket emits its row via
  `ApiKeyAuth.missing_api_key_failure/0`, the same helper the HTTP
  plug's no-header branch consumes) then the tenant activity gate via
  the `:tenant_access_module` app-env seam. Outcomes: missing token →
  `:missing_api_key`; bad key → `:invalid_api_key`; inactive tenant →
  `:tenant_inactive`; activity infra failure → `:tenant_unavailable`
  (fail closed). `ensure_active/1` may provision the tenant row on first
  connect — the same one-write-behind-a-read-surface as `/gql`.
- **Join is canonicalize → subscribe → authorize.** `Ecto.UUID.cast/1`
  FIRST (an uppercase UUID would otherwise authorize via Ash cast but
  subscribe to a differently-cased PubSub topic and hear nothing);
  `RunPubSub.subscribe/1` BEFORE the authorizing read (a terminal landing
  between read and subscribe would be lost; a refused join kills the
  channel process and its subscription); then `WorkflowRun.by_id/2` under
  the caller's tenant + actor — the read policy folds tenant match + the
  active-tenant EXISTS. Cross-tenant, suspended-tenant, and nonexistent
  ids are ONE uniform `"not_found"` (no existence oracle); subscribe or
  read infra failures are `"unavailable"` (infra ≠ absence).
- **Payload contract is minimal and id-bound.** Push frames:
  `run_event` with `%{id, kind}` where the id is the **authorized** run's
  (bound in `handle_info` by matching the tuple id against
  `assigns.run_id`) and kind is allowlisted to the exact lifecycle
  inventory riding `orchestration:run:<id>` — `run_started`,
  `run_completed`, `run_failed`, `run_cancelled`, `run_abandoned`,
  centralized in `RunPubSub.lifecycle_kinds/0` (the channel sources its
  allowlist from the producers' module, name-set-pinned in tests, so the
  two can never drift). The broadcast `info` map is NEVER forwarded (it
  carries names/errors the socket surface has no need to re-authorize).
  Join reply: `%{id, status}` with **lowercase-snake status**
  (`"pending"`, `"awaiting_approval"`, …) — the authoritative state at
  subscription start so the client can reconcile the fetch→join gap; the
  SPA normalizes to the GraphQL enum casing before comparing (a defined,
  tested wire contract).
- **Composer runs publish the full lifecycle onto the same five kinds.**
  Composer parents never ride `ReactorMiddleware` (the reactor-run start
  announcer), so `RouteComposer` broadcasts for itself, durable-then-notify
  at both seams: `run_started` right after the mint `Ash.transact` commits
  (`reload_running_parent/3`), and every parent terminal from the single
  append choke point (`append_loaded_parent_terminal/6`, post-commit) as
  its status-FAMILY wire kind — completed-family `route_*` kinds →
  `:run_completed`, failed family + the abnormal-path `:run_failed` →
  `:run_failed`, cancelled family → `:run_cancelled` (`route_abandoned`
  included: it *projects* to `:cancelled`, and the wire kind must agree
  with the durable status the payload carries). The kind→status map is
  `Projection.route_terminal_status/1` — the same lists that drive the
  status fold, never a hand re-derivation. Broadcasts are best-effort and
  total: both seams run under the `notify_best_effort/3` shield, which
  logs returned errors AND catches raises/exits/throws
  (`Phoenix.PubSub.broadcast/3` raises while its registry is briefly
  down), so an unmappable kind, a reload failure, or a PubSub outage can
  never fail the committed mint or the persisted terminal; the
  already-terminal short-circuit broadcasts nothing (the
  finish-vs-timeout double-fire guard). Zero new wire shapes: `route_*`
  kinds never ride the topics — the amber `disposition` detail lives on
  the run row, read via GraphQL refetch (camus C1-4).
- **Suspension force-disconnects argus sockets cluster-wide.**
  `id/1` keys every socket on the tenant (`"argus_socket:<tenant_id>"`),
  and the tenant manager's live runtime-stop path (`:suspended` /
  `:terminating`) calls `ArgusSocket.disconnect_tenant/1` — a direct
  `Phoenix.PubSub.broadcast` of the exact
  `%Phoenix.Socket.Broadcast{event: "disconnect"}` message
  `Endpoint.broadcast/3` would construct, minus the Endpoint dependency,
  so a suspension initiated on a CLI/MCP node (no local Endpoint) still
  drops gateway sockets on every node (PubSub is always in the Core
  supervision group). Reconnects are then refused at connect by the
  activity gate.
- **The client parks itself instead of hammering a refusing server.**
  Every refused connect writes a durable audit row, and phoenix.js
  deliberately reconnects even after the server's 1001 close — so
  `ui/src/lib/socket.ts` slows the schedule (1s/2s/5s/10s then 30s) and
  counts consecutive `onError` since the most recent `onOpen` (reset on
  every open — bounds the pre-first-open run AND every later reconnect
  run, suspension included). At 8 (≈ >1 min of refusals) it disconnects
  and flips a subscribable transport status to `"unavailable"`; a manual
  Retry resets and reconnects. Ordinary blips recover within the cap.

## Mechanics

- **Server**: `ArgusSocket.connect/3` assigns
  `current_user`/`current_actor`/`auth_method: :api_key`;
  `WorkflowsChannel` maps read errors via `read_error_reason/1`
  (not-found classification through `Core.AshErrors.not_found_error?/1`,
  shared with `Tools.UnscheduleTask`). Non-`run` subtopics
  (`workflows:gates`, …) get an explicit `"unauthorized topic"` reject —
  the `RpcChannel` precedent, not a crash.
- **Client wrapper** (`ui/src/lib/socket.ts`): lazy `getSocket()`
  singleton — `/` and `/projects` never open a socket; reconnect state
  survives route changes; `vi.mock`-able seam for the runs-page tests.
  The npm `phoenix` package is pinned **exact** to the hex phoenix
  version (serializer wire compat) — a hex phoenix bump must bump
  `ui/package.json` in the same change. `@types/phoenix` provides
  `authToken` typings.
- **Runs page** (`ui/src/routes/runs.tsx`): the list query runs under
  `fetchPolicy: "cache-and-network"` — cached rows paint immediately and
  every route entry fires the network leg, so a singleton-client cache
  (main.tsx) can never pin a stale/empty list across navigation
  (`refetch()` stays a network fetch under this policy). The list joins
  per-run topics for **non-terminal rows only** and refetches
  `recentWorkflowRuns` on any `run_event`. The join effect is keyed on
  `[activeKey, subEpoch, refetch]` — `activeKey` the sorted comma-joined
  non-terminal id string, `subEpoch` a retry generation whose bump is the
  only way back after a `leave()`. Fresh channels every effect pass
  (`join()` throws on reuse; StrictMode double-invokes effects); a
  per-pass `disposed` flag keeps late callbacks from replaced channels
  out of current state. Join-ok replies compare the (normalized) reply
  status against the CURRENT rendered status via a `useEffectEvent`
  reader — Phoenix re-fires join receive callbacks on rejoin, and an
  effect-time snapshot would refetch spuriously; any mismatch refetches.
  Join-error leaves the channel and refetches (`not_found` resolves
  itself; `unavailable` marks the run degraded); timeouts mark degraded.
  Channel health is per-run (`degradedIds` set, functional updates, only
  the succeeding id clears, pruned to the active set); the banner shows
  on transport-`unavailable` OR any degraded id, and its Retry does both
  `retryConnect()` and an epoch bump.
- **Dev plumbing**: Vite proxies `"/argus/ws"` to the gateway with
  `ws: true` and deliberately NO `rewriteWsOrigin` (a CSRF hazard per
  Vite's docs) — instead dev's endpoint `check_origin` allows
  `//localhost:5173` (port-pinned, per the config.exs any-port-wildcard
  warning; `GatewayExposure` appends PHX_HOST origins on top). The proxy
  prefix is distinct from Vite's own HMR websocket at the `/argus/` base.

## Config & telemetry

- No new config keys. The activity gate reuses `:tenant_access_module`
  (test seam, default `JidoClaw.Tenants.Access`); the client key reuses
  `VITE_API_KEY` (P3).
- No dedicated telemetry: every connect attempt — valid, invalid, AND
  token-less — rides ApiKeyAuth's existing `:auth_event` audit rows
  (`api_key_sign_in_success`/`_failure`, exactly one per attempt);
  channel traffic rides standard Phoenix spans. Composer lifecycle
  broadcasts are plain PubSub events, not telemetry.

## Residuals & accepted risks

- **Key revocation/expiry does NOT drop a live socket.** The socket
  retains user/actor identity from connect; later joins on an established
  socket re-check run/tenant policy but never key validity — the key is
  re-validated **on transport reconnect only**. TC1-2 (ticket-based WS
  auth) closes this properly; a non-secret key-identity re-check per join
  is the interim option if it ever matters. (Suspension is NOT subject to
  this residual — the force-disconnect covers it.)
- **No runs-LIST topic**: navigation genuinely refetches
  (cache-and-network), so a run created between visits appears on the
  next route entry — but a run created while the operator sits parked on
  `/runs` surfaces only when an already-joined run fires an event or the
  route is re-entered. Slice 1's runs-list topic is the fix.
- **Park/resume is not broadcast** (retained deliberately): parks are
  status-less by design — the composer parent stays `:running` and the
  durable case row IS the park representation, so there is no
  status-authority event to publish; `run_halted` never rides the run
  topic. Composer start/terminals DO broadcast now; per-step and park
  deltas stay slice 1, and an awaiting-approval flip (child runs)
  surfaces on the next refetch.
- **Bounded-retry ↔ audit-write tradeoff**: the cap (8) trades ~8 audit
  rows per parked client per outage against reconnect liveness; the
  schedule keeps that under one row per ~10s steady-state.
- **Baked `VITE_API_KEY`** carries over from P3 (build-time key in the
  bundle; runtime key entry UX deferred).
- **Layering wrinkle**: the tenant manager (platform) calls
  `JidoClaw.Web.ArgusSocket.disconnect_tenant/1` directly — accepted; a
  transport-control message doesn't belong on the Jido Signal bus, and
  the direct PubSub path is what makes it endpoint-independent.

## Source map

- `lib/jido_claw/web/channels/argus_socket.ex` — key-only socket,
  activity gate, `disconnect_tenant/1`
- `lib/jido_claw/web/channels/workflows_channel.ex` — join authorization,
  lifecycle allowlist, error mapping
- `lib/jido_claw/web/plugs/api_key_auth.ex` — shared
  `authenticate_api_key/1` (audit contract)
- `lib/jido_claw/web/endpoint.ex` — the `/argus/ws` mount
  (`auth_token: true`, socket-level)
- `lib/jido_claw/orchestration/run_pubsub.ex` — the run topic, the
  canonical `lifecycle_kinds/0` inventory, lifecycle broadcast
  construction sites
- `lib/jido_claw/route_composer/route_composer.ex` — composer
  `run_started` + terminal-family broadcast seams (durable-then-notify)
- `lib/jido_claw/platform/tenant/manager.ex` — suspension runtime-stop
  hook
- `lib/jido_claw/core/ash_errors.ex` — shared not-found classification
- `ui/src/lib/socket.ts` — wrapper: authToken, bounded reconnect,
  transport status
- `ui/src/routes/runs.tsx` — runs list + join lifecycle
- `ui/vite.config.ts`, `config/dev.exs` — dev ws proxy + check_origin
- `test/jido_claw/web/argus_socket_test.exs`,
  `test/jido_claw/web/workflows_channel_test.exs`,
  `ui/src/runs.test.tsx`, `ui/src/lib/socket.test.ts` — the pins
