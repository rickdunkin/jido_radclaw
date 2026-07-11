---
type: surface
description: Read-only /gql over Projects + WorkflowRun behind API-key auth and a tenant-activity gate, allowlisted fields, SDL golden drift-guarded in precommit.
sources:
  - lib/jido_claw/web/graphql/schema.ex
  - lib/jido_claw/web/graphql/sdl.ex
  - lib/jido_claw/web/plugs/graphql_tenant_gate.ex
  - lib/jido_claw/web/plugs/graphql_batch_guard.ex
  - lib/jido_claw/web/plugs/graphiql_guard.ex
  - lib/jido_claw/web/router.ex
  - lib/mix/tasks/jidoclaw.graphql.schema.ex
  - lib/mix/tasks/jidoclaw.graphql.schema.check.ex
  - ui/schema.graphql
  - lib/jido_claw/orchestration/visibility.ex
  - lib/jido_claw/projects.ex
  - lib/jido_claw/projects/project.ex
  - lib/jido_claw/orchestration.ex
  - lib/jido_claw/orchestration/workflow_run.ex
  - lib/jido_claw/orchestration/workflow_run/status.ex
  - lib/jido_claw/orchestration/workflow_run/calculations/disposition.ex
  - lib/jido_claw/orchestration/workflow_run/calculations/findings_deferred_count.ex
verified: 2026-07-11
---

# GraphQL Read Surface

## What & why

`/gql` is the argus UI bootstrap's query surface (P1 of
`docs/plans/argus-ui-bootstrap/README.md`): a deliberately minimal
**read-only** AshGraphql/Absinthe schema over `Projects.Project` and
`Orchestration.WorkflowRun`, mounted behind the existing API-key auth. Its
SDL is a committed golden (`ui/schema.graphql`) that the `ui/` client's
codegen (P2) reads and `mix precommit` drift-guards — the schema→codegen
loop's mechanical enforcement (SYNTHESIS §5.5: advertisement without
enforcement rots). Slice 1 grows the surface (steps/events/cases, the first
mutation); this page owns the bootstrap contract.

## Invariants & contracts

- **Read-only = no GraphQL mutations.** No Mutation or Subscription root
  exists (pinned by the SDL tests). The one write behind the surface:
  the tenant-activity gate may **provision a missing tenant row** —
  `Access.ensure_active/1` is a read-first upsert. Config/trust mutations
  stay off GraphQL entirely (OVERVIEW §4.4, the CC2-4 lesson).
- **Field exposure is a positive allowlist** (`show_fields` on both
  resources; no `hide_fields` fallback): a new attribute stays off the API
  until deliberately listed. The AshCloak-encrypted pair
  (`resume_checkpoint`/`replay_inputs` and their decrypting calculations),
  lease credentials (`claim_token`/`claimed_by`/`claim_expires_at`), and raw
  `result`/`error`/`config` payloads are absent by construction; the SDL
  tests hold an identifier-level deny-list against the whole schema.
- **The tenant plug is an activity GATE, not a setter.** `Project` is
  deliberately global (`actor_present()` is its entire policy), so a valid
  key of a **suspended** tenant would read projects if the plug merely set
  the tenant. Outcomes: active → set tenant + continue; inactive → 403
  `{"error": "tenant_inactive"}`; activity-check infra failure → 503
  `{"error": "tenant_unavailable"}`; missing/malformed actor → 403
  `{"error": "invalid_actor"}` (fail closed). The PostgreSQL tenant row is
  the activity authority (`gateway-runtime-security.md`).
- **WorkflowRun shares Visibility's terminal-disposition derivation** —
  the shared-derivation seam, NOT a WorkflowView-backed resolver: the
  `disposition` / `findings_deferred_count` calculations delegate to the
  same public `Visibility.result_disposition/1` /
  `result_findings_deferred_count/1` that `run_view/3` uses, so the camus
  C1-4 "never plain green" rule rides GraphQL from day one with unforked
  semantics.
- **Fixed-shape surface**: `derive_filter?(false)` + `derive_sort?(false)`
  on both resources — no generated filter/sort inputs. Ordering and bounds
  live in the dedicated read actions (`:alphabetical`, `:recent`), each
  with a validated `limit` (default 50, min 1 / max 200 — over-cap is an
  honest validation error, never a silent clamp) and an id tie-break for
  deterministic pages.
- **No transport batching.** Absinthe.Plug natively parses three batch
  ingress vectors — a JSON **array body** (`body_params["_json"]` under
  Plug.Parsers), an **`operations` param** (query string or multipart
  field), and a **binary `_json` query param** it JSON-decodes itself —
  and threads the complexity/token limits into each element's OWN
  pipeline, so N individually-cheap queries would ride one request with
  unbounded aggregate cost (bounded only by the 8 MB body cap).
  `GraphqlBatchGuard` rejects all three vectors **presence-based and
  value-type-blind** (a `_json`/`operations` key in `params` or
  `body_params` halts, whatever the value — the guard never replicates
  absinthe's decode, so it fails closed) with 400
  `{"error": "batching_not_supported"}`. Rejection over an aggregate cap:
  no legitimate consumer batches (GraphiQL and the argus client post
  single objects), so a cap would be knob surface for zero users.
- **Pipeline order is load-bearing**: `[:api, :api_auth, :graphql]` where
  `:graphql` = `GraphqlBatchGuard` **then** `GraphqlTenantGate` **then**
  `AshGraphql.Plug` — auth seeds the actor, the batch guard 400s before
  the gate spends its DB activity check, the gate 403s/503s before
  anything resolves and sets the Ash tenant, AshGraphql.Plug copies both
  into the Absinthe context. Route tests prove the complexity/token
  controls and the batch rejection are live so a router refactor cannot
  silently drop them.
- **The SDL golden has exactly one writer**: `mix jidoclaw.graphql.schema`
  renders `SDL.render/0` into `ui/schema.graphql`;
  `mix jidoclaw.graphql.schema.check` (precommit) fails on any byte
  difference. AshGraphql's own `generate_sdl_file` codegen is deliberately
  not used — one writer only.

## Mechanics

- **Schema**: `JidoClaw.Web.GraphQL.Schema` — `use Absinthe.Schema` +
  `use AshGraphql, domains: [JidoClaw.Projects, JidoClaw.Orchestration]`
  and an **empty** `query do end` (structurally required: AshGraphql
  injects domain queries into the existing root; no placeholder fields).
  Queries: `project(id)` / `projects(limit)` (action `:alphabetical`,
  sort `name asc, id asc`) and `workflowRun(id)` /
  `recentWorkflowRuns(limit)` (action `:recent`, sort
  `inserted_at desc, id desc`). The `limit` default (50) is action-side —
  the SDL renders a plain nullable `Int`.
- **WorkflowRunStatus enum**: ash_graphql 1.9.4 maps plain `:atom`
  attributes to GraphQL `String` (no auto-enum from `one_of`), so `status`
  became a real `Ash.Type.Enum` — `WorkflowRun.Status` with
  `graphql_type(_) :: :workflow_run_status`. Same text storage, same atom
  values in Elixir; the Lua `jido.runs` status validator reads
  `Status.values/0` (it previously read the attribute's `one_of`
  constraint, which enum types don't carry).
- **Timestamps are explicitly `public?: true`** on both resources —
  `create_timestamp`/`timestamps()` default private, and `show_fields`
  cannot publicize a private field. A deliberate shared Ash
  public-interface change. `belongs_to :project` is public for run→project
  traversal (the `WorkflowStep.workflow_run` precedent); the raw
  `project_id` FK stays off the allowlist.
- **Policies untouched**: WorkflowRun reads keep tenant match + the
  active-tenant EXISTS; `:recent` joins no bypass. Project keeps
  `actor_present()` — hence the gate.
- **GraphiQL** (`/graphiql`, playground, `default_url: "/gql"`) is a
  sibling path (a `/gql` forward would swallow `/gql/*`), compiled
  `if Mix.env() in [:dev, :test]` — test env exists solely so route tests
  prove the guard; prod never compiles it. **The guard is interface-only**:
  GraphiQL executes documents itself on BOTH non-HTML requests and HTML
  GETs carrying `?query=` (absinthe_plug: only document-less HTML requests
  render the interface — the URL-query execution hole). The guard passes
  only `GET` ∧ first Accept header containing `text/html` (mirroring
  GraphiQL's own `html?/1`) ∧ empty query string ∧ a **literally empty
  body** proven via bounded `read_body/2` — Content-Length absence proves
  nothing (chunked requests omit it), and `Plug.Parsers` never consumes GET
  bodies. Everything else halts 404 before the forward.
- **SDL normalization**: `SDL.render/0` trims to exactly one trailing
  newline so the byte-diff is editor-safe; `problems/1` takes an injectable
  `:golden_path` for red/green tests and carries the regeneration
  instruction in every problem string.
- **JIDO.md rider**: `JidoClaw.JidoMd.framework_names/1` is the shared
  detection both the generator and `mix jidoclaw.jido_md.check` use; the
  committed Frameworks line is canonical detector output (detection gained
  Bandit / Jido / ash_graphql-implies-GraphQL), and the generator lists a
  `lib/**/graphql/schema.ex` entry point only when the file exists.

## Config & telemetry

- **Complexity/token controls** pinned on the `/gql` forward:
  `analyze_complexity: true, max_complexity: 200, token_limit: 5_000`.
  Rationale: the bootstrap's legitimate queries are shallow (a list + a
  nested project ≈ complexity 10–20), so 200 leaves an order of magnitude
  of headroom while stopping alias-amplification; 5k tokens comfortably
  fits any hand-written or codegen document while bounding parse cost.
  Both limits are **per batch element**, which is why the pipeline
  rejects transport batching outright (invariant above) — together they
  bound the whole request. Route tests prove all three live (an
  over-complex aliased document, an over-token document, and both batch
  vectors are rejected).
- No dedicated telemetry: requests ride the standard Phoenix/Absinthe
  spans; the audit trail is ApiKeyAuth's existing auth events.
- No new config keys. The gate resolves its access module via the existing
  `:tenant_access_module` app-env seam (the `LiveUserAuth` precedent,
  default `JidoClaw.Tenants.Access`) — a test seam, not an operator knob.

## Residuals & accepted risks

- **Complexity does not multiply by `limit`**: Absinthe's default
  complexity counts field nodes — `recentWorkflowRuns(limit: 200)` costs
  the same as `limit: 1`. The row bound is the action's `max: 200`
  constraint, not the complexity analyzer; revisit if list fields ever
  return unbounded collections.
- **Selecting either calculation loads the full private `result` JSONB**
  for up to 200 runs (calculations `load [:result]`): not exposed, but a
  material memory/query cost if results are large. Acceptable at bootstrap
  scale; a dedicated projection column is the escape hatch.
- **No key-mint task yet** (pre-argus #18): `/gql` is hand-testable only
  via a dev-seeded key (`ApiKey.create(user.id, authorize?: false)` in
  IEx). Scopes/RBAC stay deferred — schema room arrives with the mint
  task's rider, enforcement with the first scoped surface (TC1-2).
- **Buffered non-streaming responses**: Absinthe.Plug sends complete JSON
  bodies; fine for the bootstrap's row counts (≤ 200-row pages).

## Source map

- `lib/jido_claw/web/graphql/schema.ex` — the Absinthe schema
- `lib/jido_claw/web/graphql/sdl.ex` — SDL render + drift problems
- `lib/jido_claw/web/plugs/graphql_tenant_gate.ex` — the activity gate
- `lib/jido_claw/web/plugs/graphql_batch_guard.ex` — the transport-batch rejection
- `lib/jido_claw/web/plugs/graphiql_guard.ex` — the interface-only guard
- `lib/jido_claw/web/router.ex` — `/gql` + `/graphiql` scopes, pinned controls
- `lib/mix/tasks/jidoclaw.graphql.schema.ex` — golden writer
- `lib/mix/tasks/jidoclaw.graphql.schema.check.ex` — precommit drift guard
- `ui/schema.graphql` — the committed golden
- `lib/jido_claw/projects/project.ex`, `lib/jido_claw/projects.ex` —
  Project graphql block + domain queries
- `lib/jido_claw/orchestration/workflow_run.ex`,
  `lib/jido_claw/orchestration.ex` — WorkflowRun graphql block + domain queries
- `lib/jido_claw/orchestration/workflow_run/status.ex` — the status enum type
- `lib/jido_claw/orchestration/workflow_run/calculations/` — the two
  Visibility-delegating calculations
- `lib/jido_claw/orchestration/visibility.ex:137` — the shared derivations
- `test/jido_claw/web/graphql_route_test.exs`,
  `test/jido_claw/web/graphql/sdl_test.exs`,
  `test/jido_claw/web/plugs/graphql_tenant_gate_test.exs`,
  `test/jido_claw/web/plugs/graphql_batch_guard_test.exs`,
  `test/jido_claw/web/plugs/graphiql_guard_test.exs` — the pins
