# P4 — Channels substrate (argus-ui-bootstrap)

## Context

P4 of `docs/plans/argus-ui-bootstrap/README.md` builds the live half of the
argus substrate: the WebSocket transport the SPA uses to hear about run
changes, with the §4.2 posture (minimal payloads — id + change type; client
refetches via GraphQL). P1–P3 shipped `/gql`, the `ui/` scaffold, and
node-served deployment. Slice 1 (gates topics, per-step deltas,
`workflowEvents(afterSeq:)` catch-up) starts from this.

Decisions settled with the operator during planning:

1. **Separate key-only `ArgusSocket`**, not a `UserSocket` extension: key auth
   on the shared socket would have unlocked `rpc:*`
   (`sessions.create`/`sendMessage`) for the baked SPA key. `UserSocket`/
   `RpcChannel` stay untouched; the boundary is test-pinned both ways. (This
   deviates from OVERVIEW §4.4's sketch — recorded by the docs rider.)
2. **`authToken` header transport, never connect params**: Phoenix 1.8's
   `websocket: [auth_token: true]` carries the key via `Sec-WebSocket-Protocol`
   (`deps/phoenix/lib/phoenix/transports/websocket.ex:99-124`, surfacing as
   `connect_info[:auth_token]`; JS `new Socket(url, {authToken})`,
   `socket.js:90-91,204,398-400` — string or thunk). The key never rides the
   URL, so no log-filtering change is needed (and none should be made:
   Phoenix's app-env default is already `["password", "token"]`,
   `deps/phoenix/mix.exs:72` — replacing it would regress `_csrf_token`
   filtering).
3. **Connect-time tenant-activity gate** on the key path (mirroring
   `GraphqlTenantGate`): inactive → refuse, infra failure → refuse, fail
   closed.
4. **Suspension force-disconnects** argus sockets via the existing tenant
   runtime-stop seam; the key-revocation/expiry window on a live socket is an
   explicit documented residual (revalidated on transport reconnect only).
5. **Runs page = list**; joins per-run topics only for non-terminal rows,
   refetches on events. No detail route, no runs-list topic (slice 1).

---

## Increment 1 — shared API-key validator

- `lib/jido_claw/web/plugs/api_key_auth.ex`: extract public
  `authenticate_api_key/1` (`{:ok, user} | {:error, String.t()}`): strategy
  lookup + `Actions.sign_in` + success/failure audit emission move inside; a
  non-binary guard clause returns invalid. `call/2` delegates; its `else` emits
  only the `missing_api_key` failure (invalid already emitted inside).
  **`test/jido_claw/web/plugs/api_key_auth_test.exs` must pass unchanged**
  (audit contract: exactly one `:auth_event` per call).

## Increment 2 — `ArgusSocket` (key-only, authToken)

**Files:**
- New `lib/jido_claw/web/channels/argus_socket.ex`:
  - `connect/3` reads `connect_info[:auth_token]` (never params): missing →
    `{:error, :missing_api_key}`; `authenticate_api_key` failure →
    `{:error, :invalid_api_key}`; then activity gate via the
    `:tenant_access_module` app-env seam (default `JidoClaw.Tenants.Access` —
    4th resolution site alongside `graphql_tenant_gate.ex:63`,
    `live_user_auth.ex:129`, `auth_controller.ex:189`): inactive →
    `{:error, :tenant_inactive}`, infra → `{:error, :tenant_unavailable}`
    (fail closed; `ensure_active` provisions on first connect, same as `/gql`).
    Success assigns `current_user`/`current_actor`/`auth_method: :api_key`.
  - `id/1` → `"argus_socket:#{current_actor.tenant_id}"` (the per-tenant
    disconnect topic; `id/1` runs during connect —
    `deps/phoenix/lib/phoenix/socket.ex:668`).
  - `channel("workflows:*", JidoClaw.Web.WorkflowsChannel)` — the ONLY
    channel: capability separation by construction, nothing mutable reachable
    with the SPA key.
  - `disconnect_tenant/1`: endpoint-independent
    `Phoenix.PubSub.broadcast(JidoClaw.PubSub, "argus_socket:<id>",
    %Phoenix.Socket.Broadcast{topic: ..., event: "disconnect", payload: %{}})`
    — the exact message `Endpoint.broadcast/3` constructs, minus the endpoint
    dependency, so a suspension initiated on a CLI/MCP node (no local
    Endpoint) still drops gateway sockets cluster-wide (PubSub is always in
    the Core group, `application.ex:203`). No process guard. Topic naming
    stays cohesive with `id/1` in this module.
- `lib/jido_claw/web/endpoint.ex`: mount
  `socket("/argus/ws", ArgusSocket, websocket: [auth_token: true])`
  (endpoint-level — no conflict with the `/argus` Plug.Static/catch-all;
  root-relative, unaffected by the SPA base).
- `UserSocket`/`RpcChannel`: **zero changes**.

**Tests — new `test/jido_claw/web/argus_socket_test.exs`** (`use
JidoClaw.TenantCase, async: false`, `import Phoenix.ChannelTest`,
`@endpoint JidoClaw.Web.Endpoint`, `start_supervised!(Endpoint)` — joins the
endpoint-starter cohort; refresh the stale "four files" note at
`rpc_channel_test.exs:14-17` while here). Fixtures: key mint per
`graphql_route_test.exs:67-68` (`ApiKey.create(user.id, authorize?: false)` +
`Ash.Resource.get_metadata(..., :plaintext_api_key)`); tenant suspend per
`graphql_tenant_gate_test.exs:60-71`; app-env snapshot/restore + local
`InfraDownAccess` stub per `graphql_tenant_gate_test.exs:14-32`; session via
`live_user_auth_test.exs:206-216` (`Helpers.store_in_session`, key
`"user_token"`). `connect/3` options use the keyword form
(`connect_info: %{auth_token: plaintext}`) — map form is deprecated;
connect_info passes verbatim in test (`channel_test.ex:335-346`).

1. Valid token connects: user/actor assigned,
   `socket.id == "argus_socket:<tenant>"`, tenant row provisioned.
2. Invalid token → `:invalid_api_key`. 3. Missing token → `:missing_api_key`.
4. Suspended tenant → `:tenant_inactive`. 5. Infra stub → `:tenant_unavailable`.
6. Key connect emits the `api_key_sign_in_success` audit event (shared-fn proof).
7. **Boundary, argus side**: `rpc:lobby` is unroutable over ArgusSocket
   (`subscribe_and_join/3` without a module raises "no channel" — resolved via
   `handler.__channel__/1`).
8. **Boundary, UserSocket side**: `connect(UserSocket, %{"api_key" =>
   plaintext})` with no session refuses (key params never authenticate the
   legacy socket); `connect(UserSocket, %{}, connect_info: %{session:
   session_for(user)})` still connects and joins `rpc:lobby` (first real
   session-path connect test — rpc_channel_test bypasses `connect/3`).
9. **Mount pinned**: `Endpoint.__sockets__/0` includes `/argus/ws` →
   `ArgusSocket` with `websocket[:auth_token] == true` — the `connect/3`
   tests inject `connect_info` themselves and would pass with the endpoint
   option omitted (exact `__sockets__/0` tuple shape checked at
   implementation).

## Increment 3 — `WorkflowsChannel`

**File — new `lib/jido_claw/web/channels/workflows_channel.ex`:**
- `join("workflows:run:" <> raw_id, _payload, socket)`:
  1. require `socket.assigns[:current_actor]` with binary `tenant_id` (else
     `"not_found"`);
  2. `Ecto.UUID.cast(raw_id)` — **canonicalize first** (`:error` →
     `"not_found"`; an uppercase UUID would otherwise authorize via Ash cast
     but subscribe to a differently-cased topic and receive nothing);
  3. `RunPubSub.subscribe(canonical_id)` — **subscribe before the authorizing
     read** (a terminal landing between read and subscribe would be lost; a
     refused join kills the channel process and its subscription);
     `{:error, _}` from subscribe → `"unavailable"`;
  4. `WorkflowRun.by_id(canonical_id, tenant: tenant_id, actor: actor)` — the
     read policy (`workflow_run.ex:41-56`) folds tenant match + active-tenant
     EXISTS. Error mapping mirrors `unschedule_task.ex:63-77`: NotFound (bare
     or `Ash.Error.Invalid`-wrapped) → `{:error, %{reason: "not_found"}}`
     (uniform for cross-tenant/suspended/nonexistent — no oracle); anything
     else → `{:error, %{reason: "unavailable"}}` (infra ≠ absence).
  5. Success: `assign(socket, :run_id, run.id)`; reply
     `%{id: run.id, status: to_string(run.status)}` — **wire contract:
     lowercase snake** (`"pending"|"running"|"awaiting_approval"|...`); gives
     the client the authoritative status at subscription start, so it can
     reconcile anything that happened between its list fetch and the join.
- `join("workflows:" <> _, _, _)` → `{:error, %{reason: "unauthorized topic"}}`
  (explicit reject, `rpc_channel.ex:14-16` precedent).
- `handle_info({kind, run_id, _info}, %{assigns: %{run_id: run_id}} = socket)
  when kind in @lifecycle_kinds` → `push(socket, "run_event",
  %{id: run_id, kind: kind})` — id bound to the **authorized** run; allowlist
  `[:run_started, :run_completed, :run_failed, :run_cancelled, :run_abandoned]`
  (exact inventory riding `orchestration:run:<id>`:
  `reactor_middleware.ex:159/:223/:260`, `reactor_runner.ex:910`,
  `cancellation.ex:282`, `cases.ex:310`, `gate_disposition.ex:305`); the
  `info` map is **never** forwarded. Catch-all `handle_info` drops everything
  else (unknown kinds AND mismatched tuple ids).

**Tests — new `test/jido_claw/web/workflows_channel_test.exs`** (same cohort
shape; direct `socket(ArgusSocket, "argus_socket:<tenant>",
%{current_actor: actor_for(tenant_id)})` + `subscribe_and_join`; runs via
`WorkflowRun.create` after `seed_tenant`):

1. Owned-run join replies `%{id, status: "pending"}`.
2. Broadcast with poisoned info (`%{secret: "must-not-leak"}`) →
   `assert_push "run_event", payload` with **exact equality**
   `payload == %{id: run.id, kind: :run_completed}` (atoms in test via
   NoopSerializer; strings on the real wire).
3. All five kinds proxy (loop, assert each).
4. Non-lifecycle run-topic message (`{:gate_requested, id, %{}}`) →
   `refute_push` (allowlist proof — one refute only, suite-speed).
5. **Uppercase-UUID join works end-to-end**: join
   `"workflows:run:" <> String.upcase(run.id)` → ok; broadcast on the
   canonical topic → push received (canonicalize-before-subscribe red/green).
6. **Poisoned tuple id dropped**: broadcast `{:run_completed, other_uuid, %{}}`
   onto the subscribed topic → `refute_push` (id binding).
7. Cross-tenant run → `"not_found"`. 8. Nonexistent UUID and non-UUID id →
   identical `"not_found"`. 9. Suspended-after-create tenant → `"not_found"`
   (policy EXISTS). 10. `workflows:gates` → `"unauthorized topic"`.
11. Error-mapping helper unit tests: wrapped/bare NotFound → not_found;
    arbitrary other error → unavailable (route-level infra injection is
    disproportionate).
12. E2E: real `connect(ArgusSocket, %{}, connect_info: %{auth_token:
    plaintext})` then `subscribe_and_join(socket, "workflows:run:<id>")`
    **without naming the channel module** — the only shape that catches a
    missing `channel("workflows:*", ...)` declaration.

## Increment 4 — suspension force-disconnect

- `lib/jido_claw/platform/tenant/manager.ex`: in the live-transition
  runtime-stop path (`sync_runtime_supervisor/3` for `:suspended`/
  `:terminating`, `manager.ex:252-254`) also call
  `ArgusSocket.disconnect_tenant(id)` — best-effort beside
  `InstanceSupervisor.stop_instance/1`, riding the existing
  `Tenant.suspend → Changes.SyncRuntime → Manager.sync_from_resource` chain
  (`tenant.ex:69-75,156-174`). Cluster-correct: the direct
  `Phoenix.PubSub.broadcast` on `JidoClaw.PubSub` reaches every node's
  transport processes regardless of whether THIS node runs the Endpoint.
  (Accepted layering wrinkle: platform → web module call; the direct PubSub
  path is pragmatic — a transport-control message doesn't belong on the Jido
  Signal bus.)
- Tests (in `argus_socket_test.exs`):
  - `Phoenix.PubSub.subscribe(JidoClaw.PubSub, "argus_socket:<tenant>")` →
    `Tenant.suspend(tenant)` → `assert_receive %Phoenix.Socket.Broadcast{event:
    "disconnect"}` (drives the real chain; transport-level disconnect handling
    is Phoenix's documented contract).
  - **Endpoint-absent broadcast still occurs** (the clustered CLI/MCP-initiator
    case): with the Endpoint deliberately NOT started, subscribe →
    `ArgusSocket.disconnect_tenant(tenant_id)` → `assert_receive` the same
    broadcast (PubSub-only path proven; needs a test not in the
    endpoint-starter setup block, or an explicit stop before the call).

**Gate after increments 1–4:** targeted new/touched test files, then full
`mix precommit` (zero-findings; flake policy per repo memory).

## Increment 5 — UI

**Deps:** `phoenix@1.8.9` pinned **exact** (hex/npm serializer lockstep;
comment that hex bumps must bump it; confirmed published) + `@types/phoenix`
dev-dep latest (npm package ships no `types` field —
`deps/phoenix/package.json`; current DefinitelyTyped includes `authToken` —
verify at install, else add a local module augmentation beside socket.ts).

**Files:**
- New `ui/src/lib/socket.ts`:
  - `createSocket()` mirroring `apollo.ts`: `new Socket("/argus/ws",
    { authToken: apiKey })` — header transport, key never in the URL.
  - Lazy `getSocket()` singleton (connect on first use; `/`+`/projects` never
    open a socket; reconnect state survives route changes). The test seam.
  - **Bounded reconnect on every failure run** (audit-flood guard: each
    refused attempt writes a durable audit row, and phoenix.js deliberately
    reconnects even after the server's 1001 `"disconnect"` close —
    `socket.js:546` — so a suspended tenant's opened socket would loop
    forever): explicit slower backoff via `reconnectAfterMs` (e.g.
    `[1_000, 2_000, 5_000, 10_000]` then `30_000` — Phoenix's first five
    defaults land in <1s, too brittle a window to cap on), and a counter of
    **consecutive `onError` since the most recent `onOpen`** (reset on every
    open — covers pre-first-open AND every later reconnect sequence,
    suspension included); at the cap (8 ≈ >1 min of refusals)
    `socket.disconnect()` and flip a tiny subscribable transport status
    (`"connecting" | "live" | "unavailable"`); `retryConnect()` resets the
    counter and reconnects. Ordinary blips recover within the cap; only a
    persistently refusing server parks the client.
- New `ui/src/graphql/runs.graphql` — `query RecentWorkflowRuns($limit: Int)`
  selecting `id name workflowType status insertedAt completedAt`; then
  `pnpm codegen`.
- New `ui/src/routes/runs.tsx`:
  - `useQuery(RecentWorkflowRunsDocument, {variables: {limit: 50}})`;
    NON_TERMINAL from generated `WorkflowRunStatus` consts (`Pending`,
    `Running`, `AwaitingApproval`).
  - A **`useEffectEvent` reader** for current status (confirmed exposed by
    the installed React 19.2.7 runtime + types): join callbacks compare
    against the CURRENT rendered status, never a stale effect-time snapshot
    (the effect persists across refetches while the id set is unchanged, and
    Phoenix re-fires join receive callbacks on rejoin). `useEffectEvent` is
    designed exactly for effect-installed callbacks reading current state,
    adds no effect dependencies, and avoids the concurrent-render concerns
    of a render-time ref write (the workable fallback if it misbehaves under
    happy-dom).
  - Join effect keyed on `[activeKey, subEpoch, refetch]` — `activeKey` = the
    **stable comma-joined id string** of non-terminal rows, `subEpoch` = a
    **subscription retry generation** (`useReducer` counter): bumping it
    rebuilds fresh channels for the same ids, which is the ONLY way back after
    a `leave()` (the id set alone wouldn't change, and `Socket.connect()`
    no-ops while connected — `socket.js:279`). The effect sets a per-pass
    `disposed` flag (cleanup flips it; every receive/on callback returns early
    when disposed — late callbacks from replaced channels must never mutate
    current state). Per id: fresh `socket.channel("workflows:run:"+id)` each
    effect pass (**mandatory** — `join()` throws on reuse,
    `channel.js:79-81`, and StrictMode double-invokes effects),
    `.on("run_event", refetchSafely)`, `.join()`
    - `.receive("ok", reply => { clearDegraded(id); if
      (normalize(reply.status) !== currentStatusOf(id))
      refetchSafely() })` — `currentStatusOf` = the `useEffectEvent` reader;
      refetch on **any** current-status↔reply mismatch
      (`PENDING` vs `"running"` is the stale case a terminal-only rule would
      miss; the terminal race is subsumed — we only join non-terminal rows);
      no refetch only when both agree. `normalize` = explicit lowercase-snake
      → enum-case mapper (`"awaiting_approval"` → `"AWAITING_APPROVAL"`); the
      **casing trap** is a defined wire contract + test, not an accident;
    - `.receive("error", resp => { channel.leave(); refetchSafely(); if
      (resp.reason === "unavailable") markDegraded(id) })` — a
      deleted/unreadable run must not rejoin forever nor linger rendered;
    - `.receive("timeout", () => markDegraded(id))`;
  - cleanup `leave()`s all; empty id set → socket untouched.
  - **Channel health is per-run, not one boolean**: `degradedIds:
    Set<string>` in state, mutated ONLY through `markDegraded(id)`/
    `clearDegraded(id)` helpers that clone via
    `setDegradedIds(prev => ...)` (functional updates) — add on
    unavailable/timeout, **remove only the id whose join succeeds** (B's
    success must not clear A's outstanding degradation), prune ids that leave
    the active set.
  - **Transport status and channel health stay separate**: the banner shows
    when socket.ts's transport status is `"unavailable"` OR `degradedIds` is
    nonempty; its Retry action does both `retryConnect()` (transport) and a
    `subEpoch` bump (channels); the transport status clears itself on open.
  - `refetchSafely` = `refetch().catch(() => {})` (rejection surfaces via the
    hook's `error` state; no unhandled-rejection noise).
  - List UI shaped like `projects.tsx` (name · workflowType · status).
- `ui/src/routes/index.tsx` — add `<Link to="/runs">View runs</Link>`.
- `ui/vite.config.ts` — proxy gains
  `"/argus/ws": { target: "http://localhost:4000", ws: true }` (no
  `rewriteWsOrigin` — Vite docs flag it as a CSRF hazard; distinct prefix from
  Vite's HMR ws at the `/argus/` base).
- `config/dev.exs` — endpoint `check_origin` override: the three
  port-4000 entries + `"//localhost:5173"` (dev browser origin now reaches the
  socket upgrade; stays port-pinned per the `config.exs:407-409` security
  comment; `GatewayExposure` appends PHX_HOST origins on top,
  `gateway_exposure.ex:99-117`).

**Tests:**
- New `ui/src/runs.test.tsx` (imports from `vite-plus/test`;
  `vi.mock("./lib/socket.ts")` — same resolved module id as the route's
  `../lib/socket.ts`; hoisted FakeChannel recording topics, handlers, and
  receive-callbacks so tests can fire join replies/errors and events):
  1. Mixed statuses render; joins **exactly** the non-terminal topics.
  2. **Query `PENDING` + reply `"running"` → refetch** (the mismatch rule —
     two identical-variable mocks, MockedProvider consumes one per request;
     the second's `RUNNING` renders).
  3. **Query `RUNNING` + reply `"running"` → no refetch** (agreement — single
     mock; a spurious refetch would surface as the hook's error state —
     assert it doesn't).
  4. **Reply terminal (`"completed"`) → refetch** (the original join-reply
     race, subsumed by mismatch but pinned explicitly).
  5. **Rejoin after a status update compares against CURRENT status**: render
     with `PENDING`, mismatch-refetch to `RUNNING`, then re-fire the SAME
     channel's join-ok with `"running"` (Phoenix rejoin behavior) → no
     second refetch (the effect-event reader sees `RUNNING`; an effect-time
     snapshot would still say `PENDING` and refetch spuriously).
  6. `run_event` push → refetch; run now terminal → channel left (activeKey
     emptied → cleanup).
  7. Join error `"not_found"` → channel left + refetch (second mock without
     the run → row disappears).
  8. All-terminal list → socket never touched.
  9. **Two-run degradation is per-id**: run A's join errors `"unavailable"`,
     run B's join succeeds afterward → banner **persists** (B's success must
     not clear A); Retry (epoch bump) → fresh channel for A appears and its
     join-ok clears the banner.
  10. **Disposed channels can't mutate health**: after an epoch bump replaces
      channels, fire `"unavailable"` on a PRE-epoch channel's receive-error
      callback → `degradedIds`/banner unchanged.
- New `ui/src/lib/socket.test.ts` (`vi.mock("phoenix")`): authToken passed to
  the Socket constructor; custom `reconnectAfterMs` supplied; consecutive
  pre-open errors reach the cap → `disconnect()` called + status
  `"unavailable"`; **open → server-disconnect (1001) → repeated refused
  reconnects → capped** (counter resets on open, then caps the post-open
  failure run — the suspension scenario); `retryConnect()` resets and
  reconnects.

**Gate:** the full UI gate — `pnpm --dir ui codegen && check && test && build`
(all four, always).

## Increment 6 — docs riders + final verify

Per `mix jidoclaw.system_docs.check` (bidirectional AGENTS.md ↔ page
enforcement, README index set-match, frontmatter + `## Source map` required):
- New `docs/system/channels-surface.md` (`type: surface`;
  `graphql-surface.md` is the template). Contracts: ArgusSocket key-only auth
  via authToken header (never params/URL — no log-filter dependence),
  connect-time activity gate, capability separation from
  `UserSocket`/`rpc:*`, join authorization (canonicalize → subscribe → policy
  read; `not_found` vs `unavailable`), payload contract (push `{id, kind}`
  allowlisted + id-bound, info never forwarded; join reply `{id, status}`
  lowercase-snake wire casing), suspension force-disconnect (PubSub-direct,
  endpoint-independent). **Residuals**: key revocation/expiry does NOT drop a
  live socket and is re-validated **on transport reconnect only** — the
  socket retains user/actor, not key identity, so later joins on an
  established socket re-check run/tenant policy but never key validity
  (TC1-2 tickets close this properly; a non-secret key-identity re-check per
  join is the interim option if it ever matters); no run-creation events
  (new runs appear only on the next refetch — slice 1's runs-list topic);
  park/resume not broadcast (`run_halted` never rides the run topic — live
  updates cover start/terminal only until slice 1's deltas); bounded client
  retry ↔ audit-write rationale; baked `VITE_API_KEY` carries over from P3;
  platform → web layering wrinkle in the disconnect hook.
- `docs/system/README.md` — index row (exact `- [Title](channels-surface.md) —
  hook` shape).
- `AGENTS.md` — new Key Patterns bullet citing the page (inline contract +
  pointer, after the GraphQL bullet); UI section dev line gains the
  `/argus/ws` proxy note.
- Argus docs rider: `OVERVIEW.md` §4.4 implemented-note recording BOTH
  deviations from its sketch (separate socket, not a UserSocket extension —
  capability separation from `rpc:*`; authToken header, not connect params) +
  §4.2 table row for `workflows:run:<id>` flips to implemented;
  `DECISIONS.md` gains the P4 `[argus-ui-bootstrap]` entries (first topic;
  authToken transport supersedes the "params-borne v1" language; minimal
  payload + join-reply-status shape; suspension disconnect; ticket path
  reserved; GraphQL subscriptions re-examined at P4 and the §2.4 channels
  call stands — Apollo-side Absinthe transport maturity, notifier-vs-
  middleware publish mismatch, plug-pipeline protections don't apply over a
  socket).
- `docs/plans/argus-ui-bootstrap/README.md` — `### P4` Deviations subsection
  (entries recorded as-they-happen; already known: separate ArgusSocket,
  authToken over params + the filter_parameters premise correction,
  suspension disconnect (PubSub-direct, endpoint-independent), join-reply
  status + current-status mismatch rule, canonicalization,
  not_found/unavailable split, bounded every-failure-run reconnect cap,
  subscription retry epoch + per-id degradation, dev-origin over
  rewriteWsOrigin, reconnect-only key revalidation residual — each marked
  surfaced-decision vs forced-correction).
- **Not** touched unless a documented contract moves: `graphql-surface.md`
  (`GraphqlTenantGate` unmodified), `gateway-runtime-security.md` (P1
  precedent: source overlap alone doesn't trigger a bump).

**Final verification:**
1. Full `mix precommit` green (system_docs/jido_md/system_prompt/SDL checks
   included — SDL untouched by P4).
2. Full UI gate green (all four commands).
3. Manual e2e (the plan's "Done when"): server up + dev key in `ui/.env.local`
   (Tidewave-minted, P2/P3 precedent — pre-argus #18 still open);
   `pnpm --dir ui dev`; two tabs at `localhost:5173/argus/runs`; via Tidewave
   create a `WorkflowRun` (non-terminal → joined), then cancel it through the
   real `Orchestration.Cancellation` path — both tabs live-update
   pending → cancelled without refresh.
4. Manual lifecycle/degradation pass (exercises the wrapper end-to-end — an
   invalid `VITE_API_KEY` alone never opens the socket, since GraphQL shares
   the key and returns no runs): with a non-terminal run rendered over a
   valid key, `Tenant.suspend` via Tidewave → both tabs force-disconnect,
   reconnects are refused, the bounded cap parks the client, banner shows;
   `Tenant.resume` → manual Retry recovers live updates.

## Out of scope (deferred to slice 1, per plan)

`gates:user:<id>`, per-step delta projection from `WorkflowEvent`,
`workflowEvents(afterSeq:)` catch-up, carry-events-vs-minimal decision,
runs-list topic (run-creation liveness), runtime key entry UX, WS tickets
(TC1-2), key-revocation socket teardown (residual above).
