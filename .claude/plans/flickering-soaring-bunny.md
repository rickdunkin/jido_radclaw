# Mock data layer for the argus SPA (`ui/src/mocks/`)

## Context

The argus UI currently needs a running Phoenix backend (`/gql` + `/argus/ws` proxied to :4000) for any real development, and tests hand-roll Apollo `MockedProvider` fixtures + a bespoke fake socket per file. We want a mock data layer so the UI can be developed fully backendless (richer states than the dev DB has: all 7 statuses, amber `done_with_findings`, empty/error/degraded), reusable in vitest.

**Mechanism (user-approved)**: in-process fakes, NOT MSW. Apollo `SchemaLink` executes real query documents against the committed `ui/schema.graphql` golden (schema drift → loud failure), plus a structural fake of the phoenix socket surface. **Zero new dependencies** — `@apollo/client/link/schema` and `graphql` are already installed.

Verified load-bearing facts:
- vite-plus-core's define plugin statically replaces `import.meta.env.DEV` (false in prod builds) and `import.meta.env.*` per-key — an inline `import.meta.env.DEV && import.meta.env.VITE_MOCKS === "1"` check constant-folds to `false` in EVERY production build, even one run with `VITE_MOCKS=1` exported, and the mocks module graph tree-shakes out. Under vitest, `DEV` is `true` (MODE `"test"`), so flag-on tests still work via `vi.stubEnv`.
- `SchemaLink.Options = { schema, rootValue?, context?, validate? }`; graphql-js `defaultFieldResolver` calls `rootValue.<field>(args, context, info)` — NOT the 4-arg makeExecutableSchema shape. A throw from `context` rejects into Apollo's link/network error channel; a resolver throw becomes a GraphQL `errors` entry, which AC4 (default `errorPolicy: "none"`) surfaces as a rejection with `CombinedGraphQLErrors`. `validate: true` gives real validation errors.
- `InMemoryCache` adds `__typename` via document transform; graphql-js resolves it — fixtures stay plain objects.
- Wire contract (from `workflows_channel.ex` / `run_pubsub.ex`): join ok reply `{id, status}` lowercase-snake (`to_string(run.status)`, e.g. `"awaiting_approval"`); join errors `"not_found"` / `"unavailable"` / `"unauthorized topic"`; pushes `run_event` `{id, kind}`, kind ∈ {run_started, run_completed, run_failed, run_cancelled, run_abandoned}. **No lifecycle kind exists for entering/leaving AWAITING_APPROVAL — the mock must not invent one.**
- Run lifecycle legality (projection.ex:136-144, `next_status/2` verbatim): `run_started` only from PENDING; `run_completed` only from RUNNING; `run_failed` and `run_cancelled` from ANY non-terminal (PENDING|RUNNING|AWAITING_APPROVAL); `run_abandoned` only from AWAITING_APPROVAL; everything else `:illegal`. (`approval_requested/approval_resolved/run_resumed` exist server-side but are NOT lifecycle wire kinds — approval resolution emits no `run_event`, so the mock must not simulate it either.)
- Read actions to mirror: projects `name asc, id asc`; runs `insertedAt desc, id desc`; `limit` is `allow_nil?(false), default: 50, min 1 max 200` — the default applies only when the arg is ABSENT; explicit `null` and out-of-range are honest validation **errors**, never a silent clamp.
- phoenix parity: `Push.receive` replays immediately if the reply already landed; `Channel.join()` **throws on second call** (runs.tsx's fresh-channel-per-effect depends on this — the fake must throw too).
- App's structural subset (read from source): Socket `onOpen/onError/connect/disconnect/channel`; Channel `on`, `join().receive("ok"|"error"|"timeout", cb)` chained, `leave()` (return value discarded).
- The runs list currently renders a `done_with_findings` COMPLETED run as plain completed — violating the platform contract ("every surface marks amber, never plain green"). This plan closes that while it's here (the fields exist on the SDL already).

## New files

Module DAG (all mocks modules side-effect-free at top level — DCE requirement): `lib/apollo.ts ⇢ mocks/link.ts` and `lib/socket.ts ⇢ mocks/socket.ts` (dead branches) → `store.ts` → `scenarios.ts` → `fixtures.ts`; `link.ts` also imports `../../schema.graphql?raw` (typed by `vite/client`'s `*?raw` ambient module — already in tsconfig types); `lib/socket-contract.ts` is imported by `lib/socket.ts`, `mocks/socket.ts` (no cycles).

1. **`ui/src/lib/socket-contract.ts`** — the app-owned structural contract (replaces any casting). A single `(response?: unknown) => void` callback param would NOT type-check at runs.tsx's call sites (standalone arrow arguments are checked strictly — `unknown` isn't assignable to the annotated reply type; phoenix only compiles today because its callback param is `any`). So the contract uses **status-specific overloads** with app-owned reply types:
   ```ts
   export interface JoinOkReply { id: string; status: string }
   export interface JoinErrorReply { reason?: string }
   export interface PushLike {
     receive(status: "ok", cb: (response: JoinOkReply) => void): PushLike;
     receive(status: "error", cb: (response?: JoinErrorReply) => void): PushLike;
     receive(status: "timeout", cb: () => void): PushLike;
   }
   export interface ChannelLike {
     on(event: string, cb: (payload?: unknown) => void): void | number;
     join(): PushLike;
     leave(): unknown;
   }
   export interface SocketLike {
     connect(): void;
     disconnect(): void;
     onOpen(cb: () => void): unknown;
     onError(cb: () => void): unknown;
     channel(topic: string): ChannelLike;
   }
   ```
   Assignability, both directions: phoenix's real `Push.receive(status: string, callback: (response?: any) => any): Push` satisfies every overload (its `any` callback param absorbs the typed ones; wider `status: string` accepts the literals; `onOpen(): string`→`unknown` etc.), so `new Socket(...)` is a `SocketLike` with no cast. `MockPush` does NOT rely on method-bivariance subtleties: it declares the SAME three overloads followed by one implementation signature over the union of the three callback types; internally, hooks are stored behind one private widening boundary (a single documented cast to `(response?: unknown) => void` at the array, never in public API). `getSocket()/createSocket()` return `SocketLike`; the fake `implements SocketLike`. Compile-time tripwire restored: new phoenix-API usage in routes fails tsc until the contract + fake widen deliberately.

2. **`ui/src/mocks/fixtures.ts`** — deterministic builders + default dataset.
   - `export const MOCK_MARKER = "argus-mock-fixture-7f3c"`, embedded in one fixture name → the prod-bundle-exclusion grep target.
   - `ProjectFixture`/`RunFixture` plain-object types matching SDL fields (statuses typed via generated `WorkflowRunStatus` const — no TS enums, `erasableSyntaxOnly`). Optional non-schema `simTerminal?: "COMPLETED" | "FAILED" | "CANCELLED"` hint (harmless under default resolvers).
   - `makeProject/makeRun(overrides)` + `defaultProjects()/defaultRuns()` returning fresh arrays. Stable hand-written lowercase UUIDs, fixed 2026-07 ISO timestamps; NO `Date.now`/`Math.random`. Builders accept an index for deterministic bulk generation (ids/timestamps derived from it) — the link tests seed 60-row stores from it. Coverage: all 7 statuses; COMPLETED with `disposition: "done_with_findings"` + `findingsDeferredCount: 3` AND one with `disposition: null`; null `workflowType`; null `startedAt/completedAt` on PENDING; `project` embedded on some runs, null on others; one AWAITING_APPROVAL run the sim parks; deliberate tie-breaker rows (two runs sharing `insertedAt`, two projects sharing `name`, distinct ids).

3. **`ui/src/mocks/scenarios.ts`** — `MockScenario` type `{ projects, runs, graphql: "ok"|"graphql-error"|"network-error", joins: "ok"|"unavailable", simulate: boolean }`; named scenarios `default` (rich + sim), `empty`, `error-gql`, `error-network`, `degraded` (joins "unavailable", no sim); `resolveScenario()` — a function, never top-level: `?mock=<name>` URL param (typeof window guard) → `VITE_MOCK_SCENARIO` → `"default"`, unknown name warns + falls back to default.

4. **`ui/src/mocks/store.ts`** — `MockStore` class:
   - Constructor **deep-clones** scenario rows including nested projects (`structuredClone`) — no test/socket can mutate another store's fixture template. Logical clock: base `"2026-07-10T12:00:00Z"` + 60s per successful transition — deterministic, no wall clock.
   - **One immutable behavior surface**: `readonly behavior: Readonly<{ graphql: "ok"|"graphql-error"|"network-error"; joins: "ok"|"unavailable"; simulate: boolean }>`, `Object.freeze`d from the scenario at construction (property-level `readonly` alone would still allow `store.behavior.graphql = ...` statically while the freeze throws at runtime — `Readonly<>` aligns the compile-time contract with the freeze) — the single property BOTH fakes read (link: `behavior.graphql`; channel joins: `behavior.joins`; sim auto-start: `behavior.simulate`). Data arrays stay store-private behind the read/mutator methods.
   - Reads mirroring Ash: `listProjectsAlphabetical(limit)` (name asc, id asc), `listRecentRuns(limit)` (insertedAt desc, id desc), `getProject(id)`, `getRun(id)` — **all public reads return snapshots (`structuredClone`), never internal rows**: a live reference would let callers mutate `status` past the transition table (no stamps, no events). Mutators alone touch the private lookup.
   - **One legal-transition table** (single source for mutators AND the simulator), mirroring the projection (projection.ex permits fail/cancel from EVERY non-terminal state): `PENDING →(advance)→ RUNNING` [run_started]; `RUNNING →(advance)→ simTerminal ?? COMPLETED` [family kind]; `failRun/cancelRun` legal from any non-terminal — PENDING|RUNNING|AWAITING_APPROVAL [run_failed/run_cancelled]; `abandonRun` legal ONLY from AWAITING_APPROVAL [run_abandoned]; `advanceRun` on AWAITING_APPROVAL no-ops (no lifecycle kind exists for approval resolution); everything else is an illegal transition → **no-op: no event emitted, no clock tick, no stamp**. Successful transitions stamp `updatedAt` (+`startedAt` on start, `completedAt` on terminal) and emit exactly one honest `RunTransition {id, kind}`.
   - `onTransition(listener): unsubscribe`; `hasAdvanceableRuns()` = any PENDING|RUNNING (a parked AWAITING_APPROVAL run does NOT keep the simulator alive).
   - `getSharedStore()` lazy singleton (link + socket share one store in app mode → a mutation is visible as both push and refetch). Exposed for dev-console poking via a `declare global { var __argusMockStore: MockStore | undefined }` augmentation (strict-TS-clean), assigned in `getSharedStore()`.

5. **`ui/src/mocks/link.ts`** — `createMockLink(store = getSharedStore())`:
   ```ts
   let schema: GraphQLSchema | null = null;           // lazy+memoized: top-level
   const getSchema = () => (schema ??= buildSchema(sdl)); // buildSchema defeats DCE
   // Ash limit contract: default only when ABSENT; explicit null and out-of-range error.
   function checkLimit(limit: number | null | undefined): number {
     if (limit === undefined) return 50;
     if (limit === null || limit < 1 || limit > 200)
       throw new GraphQLError("limit: must be between 1 and 200");
     return limit;
   }
   return new SchemaLink({
     schema: getSchema(),
     validate: true,
     // SchemaLink types rootValue as `any` — the params get NO contextual type,
     // so they MUST be annotated explicitly or TS7006 (implicit any) fails strict.
     rootValue: {   // graphql-js shape: (args, context, info)
       projects: (a: { limit?: number | null }) => { failIfGqlError(); return store.listProjectsAlphabetical(checkLimit(a.limit)); },
       recentWorkflowRuns: (a: { limit?: number | null }) => { failIfGqlError(); return store.listRecentRuns(checkLimit(a.limit)); },
       project: (a: { id: string }) => { failIfGqlError(); return store.getProject(a.id); },       // null when missing
       workflowRun: (a: { id: string }) => { failIfGqlError(); return store.getRun(a.id); },
     },
     context: () => {  // throw here rejects through Apollo's link (network) error channel
       if (store.behavior.graphql === "network-error") throw new Error("mock: gateway unreachable");
       return {};
     },
   });
   ```
   `failIfGqlError()` throws `GraphQLError` on scenario `error-gql`. Nested `WorkflowRun.project`, scalars, enums, `__typename` resolve via default property access. SDL enums serialize name-as-value; DateTime passes ISO strings through.

6. **`ui/src/mocks/socket.ts`** — no runtime `phoenix` import (keeps `socket.test.ts`'s `vi.mock("phoenix")` untangled); implements the `socket-contract.ts` interfaces:
   - `MockPush implements PushLike`: `receive(status, cb)` returns `this`, replays immediately when the reply already landed, else buffers; internal `resolve(status, response)`.
   - `MockChannel implements ChannelLike`: extracts the raw id from the topic and **canonicalizes it (lowercase)** — mirroring the server's `Ecto.UUID.cast/1`-FIRST join (workflows_channel.ex:16: an uppercase-UUID topic must join fine and still hear events, not silently subscribe a dead topic). `on(event, cb)`; `join()` throws on second call (phoenix parity), else resolves via `queueMicrotask` — state read at REPLY time, **in the server's precedence order** (the topic pattern match rejects first, and `Ecto.UUID.cast/1` runs before any fallible subscribe/read, so "unavailable" models infra AFTER validation): (1) non-`workflows:run:` topic → `{reason: "unauthorized topic"}`; (2) malformed UUID (shape-checked on the canonical id) → `{reason: "not_found"}`; (3) `store.behavior.joins === "unavailable"` → `{reason: "unavailable"}`; (4) unknown canonical id → `{reason: "not_found"}`; else ok `{id: run.id, status: run.status.toLowerCase()}` (uppercase-snake enum → lowercase-snake wire; reply id is the canonical one). `leave()` unregisters + marks unjoined. `trigger(event, payload)` fires handlers only while joined.
   - `MockPhoenixSocket implements SocketLike`: `connect()` (idempotent, fires `onOpen` cbs via microtask → transport goes "live" through the REAL `getSocket()` wiring), `disconnect()`, `onOpen/onError` (onError never fired), `channel(topic)` registers a `MockChannel`. Constructor subscribes ONCE to `store.onTransition`, routing `{id, kind}` to joined channels whose **canonical run id** matches (never the raw topic string) — the RunPubSub→WorkflowsChannel push mirror.
   - `createMockPhoenixSocket(store = getSharedStore())` + sim auto-start gated `store.behavior.simulate && import.meta.env.MODE !== "test"`.
   - `startSimulation(store, {intervalMs = 2500})` → interval calling `advanceRun` on the oldest advanceable run; **clears itself when `hasAdvanceableRuns()` is false** (parked AWAITING_APPROVAL rows don't hold it open); returns stop fn. Tests never rely on the interval — they call mutators directly (sim shutdown itself is tested with fake timers).

## Edits

7. **`ui/src/graphql/runs.graphql`** — add `disposition` and `findingsDeferredCount` to the `RecentWorkflowRuns` selection, then `pnpm --dir ui codegen`.

8. **`ui/src/routes/runs.tsx`** — amber rendering per the platform contract: a COMPLETED run with `disposition === "done_with_findings"` renders a distinct amber treatment (never the plain completed style), mirroring the LiveView `core_components.ex` badge semantics. Label: pluralized count — "completed · 3 findings deferred", singular "completed · 1 finding deferred" (a count of 1 is real backend output); `findingsDeferredCount` is nullable in the SDL, so a null count keeps the amber treatment with the countless label "completed · findings deferred".

9. **`ui/src/runs.test.tsx`** — the `runRow` builder gains the two new fields AND an explicitly widened return type: annotate it as `RecentWorkflowRunsQuery["recentWorkflowRuns"][number]` — added to the existing `./gql/graphql.ts` import as an inline type specifier (`import { RecentWorkflowRunsDocument, type RecentWorkflowRunsQuery }`), required by `verbatimModuleSyntax` — with a typed `overrides` parameter — defaults of `disposition: null, findingsDeferredCount: null` would otherwise infer literal-`null` field types through `ReturnType<typeof runRow>` and reject the amber string/count overrides. Plus a new MockedProvider unit test asserting the amber treatment across THREE variants: count=3 (plural label), count=1 (singular "1 finding deferred"), and disposition-present + count=null (countless fallback, amber retained) — this file is the established home of runs-rendering tests.

10. **`ui/src/lib/apollo.ts`** — inside `createApolloClient()`, FIRST:
    ```ts
    if (import.meta.env.DEV && import.meta.env.VITE_MOCKS === "1") {
      return new ApolloClient({ link: createMockLink(), cache: new InMemoryCache() });
    }
    ```
    Static `import { createMockLink } from "../mocks/link.ts"` — referenced only in the dead branch. The check stays an INLINE literal in this file (a helper-module indirection would defeat define-replacement + dead-branch elimination). **`import.meta.env.DEV` makes mock mode structurally impossible in production builds** — even `VITE_MOCKS=1 pnpm --dir ui build` folds the branch away (DEV is statically false); mocks exist only under the dev server (`vp dev`) and vitest (DEV true there).

11. **`ui/src/lib/socket.ts`** — same inline `import.meta.env.DEV && import.meta.env.VITE_MOCKS === "1"` check at the TOP of `createSocket()`, returning `createMockPhoenixSocket()` — no cast; `createSocket()/getSocket()` now return `SocketLike` and module state becomes `let socket: SocketLike | null`. Branching in `createSocket` (not `getSocket`) keeps the real onOpen/onError/status wiring + `retryConnect()` driving the fake unchanged.

12. **`ui/package.json`** — add script `"dev:mock": "VITE_MOCKS=1 vp dev"`.

13. **`AGENTS.md`** — one line in the UI command block: `pnpm --dir ui dev:mock` — backendless dev via in-process fakes (SchemaLink over the SDL golden + fake channel socket; dev-server-only by construction); scenario via `VITE_MOCK_SCENARIO` or `?mock=`.

No vite.config.ts changes (src/mocks IS linted/formatted deliberately), no main.tsx changes, no new deps.

## Tests (new files colocated in `ui/src/mocks/`, `vite-plus/test` imports; router plugin only scans src/routes so colocation is safe)

- **`link.test.ts`** (real `ApolloClient` + `createMockLink(new MockStore(...))`, no MockedProvider): typed results for both documents incl. `disposition`/`findingsDeferredCount` flowing; ordering incl. **tie-breakers** (equal `insertedAt` → id desc; equal project `name` → id asc); `limit: 2` respected; **omitted limit returns exactly 50** against a store seeded with 60 builder-generated deterministic rows (an accidentally unbounded implementation must fail this); `limit: 0`, `500`, and **explicit `{limit: null}`** each → rejection where `CombinedGraphQLErrors.is(error)` is true and the message mentions "limit"; `workflowRun(id)` known id (incl. nested `project { name }`) + unknown → null; **`project(id)`** known/unknown; `cache.extract()` has `WorkflowRun:<id>` keys (normalization proof); scenario `error-gql` → rejection with `CombinedGraphQLErrors.is(error) === true` vs `error-network` → rejection with the original link `Error` (`.is` false) — asserted at the AC4 layer, not Apollo-3-style `networkError`; malformed document errors (validate: true).
- **`store.test.ts`**: **table-driven status × operation matrix** pinning the single transition table — every status in {PENDING, RUNNING, AWAITING_APPROVAL, COMPLETED, FAILED, CANCELLED, ABANDONED} × every mutator in {advanceRun, failRun, cancelRun, abandonRun}: legal cells assert the new status, the stamps, and exactly one emitted event with the right kind (fail/cancel from ALL THREE non-terminals — projection parity; advance PENDING→RUNNING [run_started] and RUNNING→terminal [family kind — **all three `simTerminal` hints pinned**: FAILED → `run_failed`, CANCELLED → `run_cancelled`, absent/COMPLETED → `run_completed`]; abandon only from AWAITING_APPROVAL [run_abandoned]); every illegal cell is a total no-op (status unchanged, no event, no `updatedAt` change). Plus isolation, three angles: mutating the ORIGINAL scenario object after construction doesn't leak into the store; transitioning one of two stores built from the same scenario leaves the other untouched; mutating a row returned by a public read changes nothing inside the store (snapshot reads). `hasAdvanceableRuns()` false when only parked/terminal rows remain.
- **`scenarios.test.ts`**: `resolveScenario()` precedence — `?mock=` beats `VITE_MOCK_SCENARIO` beats default; unknown name warns + falls back to default (stub `window.location.search` / `vi.stubEnv`).
- **`socket.test.ts` (in mocks/)**: connect fires onOpen async, idempotent; join ok reply lowercase-snake — assert `"pending"` AND `"awaiting_approval"` (casing bug magnet); **uppercase-UUID topic joins ok (reply carries the canonical lowercase id) and still receives `run_event` after a store transition** (the server's cast-first canonicalization); not_found / unavailable / unauthorized-topic errors, plus precedence pins: degraded store + unauthorized topic → `"unauthorized topic"` (never `"unavailable"`), degraded store + malformed-UUID topic → `"not_found"` (validation precedes infra); `advanceRun` after join → `run_event {id, kind: "run_started"}`, terminal → family kind; StrictMode shape: join→leave→fresh-channel rejoin works, transitions reach only the live channel, re-join of a used channel throws; late `receive` after reply replays; **simulator with `vi.useFakeTimers`**: ticks advance runs in age order; once no advanceable runs remain the interval self-clears — **proven by `vi.getTimerCount() === 0`** after the clearing tick (absence-of-transitions alone would pass on a leaked interval of no-op ticks), even with a parked AWAITING_APPROVAL row present; the returned `stop()` also drives the count to 0 mid-run.
- **`mock-mode.test.tsx`** — the only flag-on test, and it uses **NO `vi.resetModules()` and NO dynamic imports**: the generated route tree statically imports `routes/runs.tsx` → `lib/socket.ts`, so a reset-then-dynamic-import approach would split the module registry (the rendered component would keep the pre-reset socket/store while the test mutates post-reset instances). Instead: static imports throughout; vitest's per-file isolation gives this file a fresh registry, and the flag + shared store are only read lazily inside `createApolloClient()`/`createSocket()`/`getSharedStore()` — so `vi.stubEnv("VITE_MOCKS", "1")` AND `vi.stubEnv("VITE_MOCK_SCENARIO", "default")` in `beforeEach` (DEV is already true under vitest) land before any factory runs — the scenario pin keeps an inherited developer/CI `VITE_MOCK_SCENARIO` (e.g. `empty`) from silently breaking fixture-id assertions. Constraint to honor: the lib socket + shared store are file-lifetime singletons, so keep one comprehensive `/runs` test (render → assert fixtures + amber row + no degraded banner → `act(() => getSharedStore().advanceRun(PENDING_ID))` → assert the change **scoped to that run's row**, a RUNNING fixture exists elsewhere) under `<StrictMode>` + real `ApolloProvider(createApolloClient())` + `createAppRouter` memory history; a second test may render `/projects` (fresh Apollo client per test; it must not assume a pristine runs store).
- **Test-global cleanup (order-independence)**: every test file restores what it globally touches in `afterEach` — `scenarios.test.ts`: `vi.unstubAllEnvs()`, location restored (`history.replaceState` back to the original URL), `vi.restoreAllMocks()` for the `console.warn` spy; sim/socket tests: `vi.useRealTimers()` paired with every `vi.useFakeTimers()`; `mock-mode.test.tsx`: `vi.unstubAllEnvs()` + RTL `cleanup()`.
- Existing `projects.test.tsx` / `router.test.tsx`: untouched, must stay green. **`lib/socket.test.ts` gets ONE line**: `vi.stubEnv("VITE_MOCKS", "0")` in its `beforeEach` — vitest runs with `DEV = true`, so an inherited shell `VITE_MOCKS=1` would otherwise flip `createSocket()` into the mock branch and break its `phoenix.MockSocket` assertions (its existing `vi.unstubAllEnvs()` cleanup already restores). `runs.test.tsx` changes only as edit 9 describes.

## Implementation order

1. `lib/socket-contract.ts`; retype `lib/socket.ts` to `SocketLike` (no mock branch yet) — full suite proves the contract is assignable-from-phoenix.
2. `fixtures.ts` → `scenarios.ts` (+ `scenarios.test.ts`) → `store.ts` (+ `store.test.ts`).
3. `link.ts` + `link.test.ts`, then immediately `pnpm --dir ui test` && `pnpm --dir ui build` — front-loads the riskiest seams (`?raw` under `tsc -b`, SchemaLink construction). Fallback if `?raw` typing fails (unlikely — `vite/client.d.ts` declares it): `mocks/sdl.ts` template-literal copy of the golden (documented duplication, last resort).
4. Amber slice: `runs.graphql` + codegen + `runs.tsx` rendering + `runs.test.tsx` builder fields + amber unit test.
5. `mocks/socket.ts` + `mocks/socket.test.ts`.
6. Wire seams: `lib/apollo.ts`, `lib/socket.ts` mock branch, `package.json`. Full suite — existing tests prove real branches undisturbed.
7. `mock-mode.test.tsx`.
8. AGENTS.md line.
9. Verification below.

## Verification

From repo root:
1. `pnpm --dir ui codegen`
2. `pnpm --dir ui check`
3. `pnpm --dir ui test` — report exact counts
4. `pnpm --dir ui build` — `tsc -b` is the strict type arbiter
5. **Prod-bundle exclusion, adversarial**: `VITE_MOCKS=1 pnpm --dir ui build` (the hostile case — flag exported during a real build), then `grep -r "argus-mock-fixture" priv/static/argus/` → expect zero hits (exit 1): `import.meta.env.DEV` folds the branch regardless of the env var. The marker rides `fixtures.ts`, the leaf every mocks module reaches, so one literal covers the whole graph. Repeat the grep after a clean flag-unset build (the artifact that ships). If either hits: contingency = dynamic `import()` behind the same inline flag with async bootstrap in `main.tsx`.
6. **Manual smoke, no Phoenix running**: `pnpm --dir ui dev:mock` → `/argus/runs` renders fixtures incl. the amber `done_with_findings` row, statuses advance ~2.5s until only parked/terminal rows remain (sim stops), no degraded banner, zero `/gql`//`/argus/ws` network traffic; `?mock=degraded` → banner + honest re-degrade on Retry; `?mock=empty` → empty states; `?mock=error-gql` / `?mock=error-network` → error states; `/argus/projects` alphabetical.
7. Plain `pnpm --dir ui dev` with Phoenix up still proxies for real.
8. `mix precommit` (AGENTS.md was touched; gate must stay green — node-free, but the docs checks run here).

## Risks / accepted residuals

- Fake fidelity limits: no heartbeat/reconnect/transport-error simulation (`onError` never fires — the degraded scenario models channel-level unavailability, which is what the banner handles); join replies race past `leave()` like the real server (runs.tsx's `disposed` guard covers it).
- Mock mode cannot run under `vp preview` (DEV false there) — deliberate consequence of the P1 fix; backendless dev is dev-server-only.
- The `SocketLike` contract is the compile-time tripwire; if a route needs more phoenix API, widen contract + fake together (tsc forces it — that's the point).
- `MODE !== "test"` guards sim auto-start; a future non-vitest MODE (e.g. storybook-like) would auto-start the sim — acceptable, it's dev tooling.

## Out of scope

- Migrating existing tests off MockedProvider (fixtures are importable for that later, opportunistically).
- MSW / network-level interception; mutations/subscriptions (none exist on the surface); `workflowRun`/`project` detail routes themselves.
