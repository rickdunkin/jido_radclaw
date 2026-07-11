# P1 — GraphQL read surface + SDL golden (argus-ui-bootstrap) — rev 4

Rev 3 closed rev-2 review (GraphiQL HTML-GET execution hole, calculation tightening, introspection-based semantic tests, pinned+tested complexity controls, non-blind JIDO.md checker). Rev 4 folds in the rev-3 review: identifier-level deny-list (raw SDL scan false-fails on descriptions), the settled canonical JIDO.md framework set (extend detection to Bandit + Jido rather than discard knowledge), async-false + restore-previous app-env hygiene, a literal bodyless-GET check for the GraphiQL guard, and the verification-path/AGENTS.md-commands fixes.

## Context

P1 of `docs/plans/argus-ui-bootstrap/README.md`: a deliberately minimal **read-only** GraphQL surface (`/gql`) over `Projects.Project` and `Orchestration.WorkflowRun` behind the existing API-key auth, pinned by a **committed SDL golden** (`ui/schema.graphql`) drift-guarded in `mix precommit` (SYNTHESIS §5.5), plus a docs rider. "Read-only" means **no GraphQL mutations** — the tenant-activity gate may still provision a missing tenant row (`Access.ensure_active`'s read-first upsert), documented explicitly. Nothing deferred.

**Done when**: `mix precommit` fully green including the new check; curl with a seeded key returns projects over `/gql`; golden red/green-proven. Everything stays **unstaged/uncommitted**.

## Decisions (operator-confirmed)

1. **`recentWorkflowRuns`** (2026-07-10; renamed 2026-07-11): NEW read action `:recent` — `prepare build(limit: arg(:limit), sort: [inserted_at: :desc, id: :desc])`, `limit` default 50, constraints min 1 / max 200 (over-cap = honest validation error). Primary `:read` untouched; get query stays `workflowRun(id:)` on `:read`. Slice 1's richer `workflowRuns` arrives additively later.
2. **GraphiQL**: dev playground at `/graphiql` (sibling path — a `/gql` forward swallows `/gql/*`), `default_url: "/gql"`, compiled `if Mix.env() in [:dev, :test]` (test env exists solely so wiring tests prove the guard; prod never compiles it). **Interface-only guard** (required correction): GraphiQL executes documents itself on BOTH non-HTML requests AND HTML GETs carrying `?query=` (absinthe_plug source: HTML requests with a document are processed; only document-less requests render the interface). The guard passes only `GET` + Accept containing `text/html` + **empty `query_string`** + **literally empty body** (verified via bounded `read_body/2`, not Content-Length — chunked requests omit it); everything else halts before the forward.
3. **Field exposure = allowlist** (`show_fields`, positive enumeration; no hide_fields fallback).
4. **Tenant plug is an activity GATE** (2026-07-11): validates actor shape, calls the tenant-access module's `ensure_active/1`, sets the Ash tenant only on `:ok`. Inactive → **403**, infra failure → **503**, missing/malformed actor → fail-closed 403. Resolves the module via the **existing `:tenant_access_module` app-env seam** (`live_user_auth.ex:124-130` precedent; default `JidoClaw.Tenants.Access`) — infra-failure behavior is tested through public plug behavior with an injected stub, no test-only mapping function. Rationale: a valid key of a suspended tenant must not read global Projects (`gateway-runtime-security.md` lifecycle contract).
5. **WorkflowRun shares Visibility's terminal-disposition derivation** (2026-07-11 — precise phrasing: this is the shared-derivation seam, NOT a WorkflowView-backed resolver): `disposition` + `findings_deferred_count` derive per-row from `run.result` (`visibility.ex:137-153`); the two derivations become shared public functions; two public Ash calculations delegate to them; both join `show_fields`. The never-plain-green rule (camus C1-4) rides the SDL from day one.
6. **Fixed-shape surface**: `derive_filter?(false)` + `derive_sort?(false)` on both resources. Absinthe complexity/token controls pinned on the `/gql` plug — starting values `analyze_complexity: true, max_complexity: 200, token_limit: 5_000` (adjustable at implementation with rationale recorded in the system doc) — **with route tests proving both are live** (a future router refactor must not silently drop them).
7. **Task names aligned**: `mix jidoclaw.graphql.schema` + `mix jidoclaw.graphql.schema.check` (deviation from the program README's asymmetric pair — logged).

## Key facts (verified)

- `ash_graphql ~> 1.9` (1.9.4): needs `ash >= 3.5.13` (repo 3.29.2 ✓); brings `absinthe ~> 1.7` + `absinthe_plug ~> 1.4` transitively.
- `:atom` + `one_of` auto-generates the `WorkflowRunStatus` enum — no domain type change.
- **Timestamps are private today** (`create_timestamp`/`timestamps()` default `public?: false`; `show_fields` cannot publicize) → explicit `public?: true` on both resources' timestamp declarations (`project.ex:100-101`, `workflow_run.ex:475`) — a deliberate shared Ash public-interface change.
- `belongs_to :project` needs `public?: true`; precedent `workflow_step.ex:245-248`.
- Policies: Project = `actor_present()` only (global — hence the plug gate); WorkflowRun = tenant match + active-tenant EXISTS (`workflow_run.ex:46-56`); `:recent` not in any bypass.
- `Access.ensure_active/1` → `:ok | {:error, {:tenant_inactive, status}} | {:error, term}` (`access.ex:13`) — the 403/503 split falls out of the return shape.
- Actor+tenant enter the Absinthe context via `Ash.PlugHelpers.set_actor/set_tenant` BEFORE `plug AshGraphql.Plug`.
- `Absinthe.Schema.to_sdl/2` renders in-memory; Ash 3 calculations have **no `select/3`** (removed — upgrade guide) → use `load [:result]` / `load/3`; calculation `filterable?`/`sortable?` **default true** → set both false.
- Router tests: TenantCase + `start_supervised!(JidoClaw.Web.Endpoint)` + ConnTest (`admin_route_test.exs`). Key fixture: `api_key_auth_test.exs:105-120`.
- `JidoClaw.JidoMd.Check.problems/2` validates version/tools/templates/skills + Entry-points paths (`check_entry_points`) but **no Frameworks value** — extend it (below).
- `usage_rules` builds the ash-framework skill from `[:ash, ~r/^ash_/]` → `mix usage_rules.sync` required after the dep add.
- Precommit's test phase runs `cmd scripts/test-partitioned.sh`; the new check inserts earlier in the alias.

## Implementation steps

### 1. Dependency, formatter, sync
- `mix.exs`: `{:ash_graphql, "~> 1.9"}` in the ash block; `mix deps.get`.
- `.formatter.exs`: `:ash_graphql` into `import_deps` (`:absinthe` only if format still complains).
- `mix usage_rules.sync` (regenerates the ash-framework skill with ash_graphql's rules); consult those rules before writing the DSL.
- `mix.exs` `cli/0`: add `"jidoclaw.graphql.schema": :test`, `"jidoclaw.graphql.schema.check": :test`.

### 2. Shared derivation seam (Visibility) + calculations
- `visibility.ex`: promote `result_disposition/1` + `result_findings_deferred_count/1` (:137-153) to public `def` **with `@doc` and `@spec`** (`run_view/3` keeps calling them; no caller changes).
- Two calculation modules, **each in its own file**:
  - `lib/jido_claw/orchestration/workflow_run/calculations/disposition.ex`
  - `lib/jido_claw/orchestration/workflow_run/calculations/findings_deferred_count.ex`
  - Each: `use Ash.Resource.Calculation`, `load/3` returning `[:result]` (NOT select/3 — removed in Ash 3), `calculate/3` mapping records through the Visibility functions. Non-sensitive by construction (keys + counts, never finding bodies).
- **Residual to record** (system doc): selecting either calculation loads the full private `result` JSONB for up to 200 runs — not exposed, but a material memory/query cost if results are large.

### 3. Domain/resource GraphQL declarations
- `project.ex`: `extensions: [AshGraphql.Resource]`; new `read :alphabetical` (`argument :limit` default 50, min 1/max 200 + `prepare build(limit: arg(:limit), sort: [name: :asc, id: :asc])`); timestamps → `public?: true`; `graphql do type(:project); derive_filter?(false); derive_sort?(false); show_fields([:id, :name, :github_full_name, :default_branch, :inserted_at, :updated_at]) end`.
- `projects.ex` (domain): add `AshGraphql.Domain`; `graphql do queries do get(Project, :project, :read); list(Project, :projects, :alphabetical) end end`.
- `workflow_run.ex`: `extensions: [AshCloak, AshGraphql.Resource]`; new `read :recent` (per decision 1); calculations block wiring the two modules — `public?: true, filterable?: false, sortable?: false` on both; `belongs_to(:project, ..., public?: true)`; `timestamps(public?: true)`; `graphql do type(:workflow_run); derive_filter?(false); derive_sort?(false); show_fields([:id, :name, :workflow_type, :status, :disposition, :findings_deferred_count, :started_at, :completed_at, :inserted_at, :updated_at, :project]) end`.
- `orchestration.ex` (domain): add `AshGraphql.Domain`; `graphql do queries do get(WorkflowRun, :workflow_run, :read); list(WorkflowRun, :recent_workflow_runs, :recent) end end`.
- **Do NOT touch** primary `:read`, policies, multitenancy, cloak.

### 4. Schema, gate, guard, router
- New `lib/jido_claw/web/graphql/schema.ex` — `JidoClaw.Web.GraphQL.Schema`: `use Absinthe.Schema` + `use AshGraphql, domains: [JidoClaw.Projects, JidoClaw.Orchestration]`. No placeholder query block. Custom SDL tasks are the chosen golden mechanism (AshGraphql's `generate_sdl_file`/`ash.codegen --check` is a valid alternative deliberately not taken — one writer only).
- New `lib/jido_claw/web/plugs/graphql_tenant_gate.ex` — `JidoClaw.Web.Plugs.GraphqlTenantGate`:
  - Resolves the access module via `Application.get_env(:jido_claw, :tenant_access_module, JidoClaw.Tenants.Access)` (the LiveUserAuth seam).
  - Actor with binary non-empty `tenant_id` → `ensure_active/1`: `:ok` → `set_tenant`; `{:error, {:tenant_inactive, _}}` → halt 403 `{"error": "tenant_inactive"}`; `{:error, _}` → halt 503 `{"error": "tenant_unavailable"}`. Missing/malformed actor → halt 403 (fail closed, defense-in-depth behind ApiKeyAuth). Flat JSON error shape mirrors ApiKeyAuth's 401.
- New `lib/jido_claw/web/plugs/graphiql_guard.ex` — passes ONLY: `GET` ∧ Accept header contains `text/html` ∧ `conn.query_string == ""` ∧ **literally empty body** — Content-Length absence proves nothing (chunked requests omit it), so call `Plug.Conn.read_body/2` with a tiny bound and pass the RETURNED conn onward only on `{:ok, "", conn}` (also rejects `{:more, ...}`). Everything else halts (404) before GraphiQL can parse a document.
- `router.ex`:
  - `pipeline :graphql do plug(JidoClaw.Web.Plugs.GraphqlTenantGate); plug(AshGraphql.Plug) end` (gate BEFORE AshGraphql.Plug).
  - `pipeline :graphiql_guard do plug(JidoClaw.Web.Plugs.GraphiqlGuard) end`.
  - `scope "/gql" do pipe_through([:api, :api_auth, :graphql]); forward("/", Absinthe.Plug, schema: Module.concat(["JidoClaw.Web.GraphQL.Schema"]), analyze_complexity: true, max_complexity: 200, token_limit: 5_000) end` — `Module.concat` avoids the Router→Schema compile dep (AshGraphql-recommended).
  - `if Mix.env() in [:dev, :test] do scope "/graphiql" do pipe_through([:graphiql_guard]); forward("/", Absinthe.Plug.GraphiQL, schema: Module.concat(...), interface: :playground, default_url: "/gql") end end`.
  - No endpoint changes (`Plug.Parsers` already JSON-parses; `endpoint.ex:32-37`).

### 5. SDL golden + task pair
- New `lib/jido_claw/web/graphql/sdl.ex` — `JidoClaw.Web.GraphQL.SDL` (pure): `render/0` (to_sdl, normalized single trailing newline), `golden_path/0` (`"ui/schema.graphql"`), `problems/1` (injectable `:golden_path`; regeneration instruction in every problem string).
- New `lib/mix/tasks/jidoclaw.graphql.schema.ex` (`@requirements ["app.config"]`): mkdir_p `ui/`, write, print path.
- New `lib/mix/tasks/jidoclaw.graphql.schema.check.ex` (`Mix.Tasks.Jidoclaw.Graphql.Schema.Check`, `@requirements ["app.config"]`): errors + `Mix.raise("GraphQL SDL drift detected — run mix jidoclaw.graphql.schema and commit ui/schema.graphql")`.
- `mix.exs` `precommit`: insert `"jidoclaw.graphql.schema.check"` after `"jidoclaw.system_docs.check"`.
- Run the dump once → the golden (no `.gitignore` rule swallows `ui/` — verified).

### 6. JidoMd: detection + a non-blind checker (canonical framework set settled)
- **Canonical set decision** (rev 4): the committed Frameworks line (`Phoenix 1.7+ (with LiveView), Bandit HTTP adapter, Jido AI Agent Framework`) carries knowledge the detector can't derive (Bandit, Jido) while missing what it can (Ecto). Extend detection rather than discard knowledge: `jido_md.ex` `detect_framework_details/2` gains `has_bandit` → `"Bandit HTTP adapter"`, `has_jido` → `"Jido AI Agent Framework"` (a `":jido"` substring match also covers `jido_*` deps — acceptable, any of them implies the framework), and `has_ash_graphql` folded into the existing `"Absinthe/GraphQL"` label (`has_absinthe or has_ash_graphql`). The committed line is rewritten to canonical detector output — gains Ecto + Absinthe/GraphQL + Bandit + Jido labels, drops the underivable `1.7+` annotation.
- Extract framework detection into a shared function; `jido_md/check.ex` gains a `:framework_names` opt + `check_name_set` of the committed Frameworks line against the detection-derived set — the drift that motivated this change cannot recur while the check stays green. The check task derives the expected set from the real mix.exs via the shared function.
- Generator's Entry points gain the GraphQL schema module **only when the file actually exists** (`File.exists?`), never solely because `:ash_graphql` is installed; committed `.jido/JIDO.md` gains the entry-point line (path validated by the existing `check_entry_points`).
- Extend `test/jido_claw/platform/jido_md_test.exs` + `test/jido_claw/platform/jido_md/check_test.exs` for the new detection + validation (generate→check round-trip stays pinned).

### 7. Tests
- `test/jido_claw/web/graphql_route_test.exs` (TenantCase, **`async: false`** — mutates `:tenant_access_module` app env and boots the Endpoint; `start_supervised!(Endpoint)`):
  - POST `/gql` without key → 401 `{"error": "missing_api_key"}`.
  - Authed `projects` returns seeded rows; **nested** `workflowRun { project { id name } }` resolves.
  - **Project `:alphabetical` contract**: alphabetical order, id tie-break on equal names, `limit: 1`, invalid `0`/`201` → validation errors.
  - Two-tenant `recentWorkflowRuns` scoping (positive case asserts ≥1 — no false-pass); cross-tenant `workflowRun(id:)` → null/not-found.
  - **Inactive tenant → 403** on a Project query (the finding-1 regression: global resource, gate must stop it); **infra failure → 503** via a `:tenant_access_module` stub returning `{:error, :db_down}` — app-env override whose `on_exit` **restores the previous value** (never merely deletes).
  - Runs limit contract: default 50 semantics, `limit: 1` newest, `0`/`201` → validation errors; **deterministic ordering** (equal `inserted_at` → id-desc tie-break).
  - Disposition surfacing: a run whose `result` carries `disposition`/`findings_deferred_count` (atom AND string keys — JSONB round-trip) → both non-null in GraphQL; plain run → null.
  - **Complexity controls are live**: a query exceeding `max_complexity` → rejected without resolving; a document exceeding `token_limit` → rejected.
  - **GraphiQL guard wiring** (route exists in test env): unauthenticated JSON POST `/graphiql` → halted, no data; **HTML GET `/graphiql?query={__schema{queryType{name}}}` → halted** (introspection chosen so an actor-less empty-list result can't false-pass); plain HTML GET → 200 UI.
- `test/jido_claw/web/graphql/sdl_test.exs` — three-layer division:
  - **Golden (drift)**: `SDL.render() == File.read!("ui/schema.graphql")`; check red/green via `problems/1` with tmp goldens (clean → `[]`; mutated → drift problem; missing → problem).
  - **Semantic contract via the compiled schema** (NOT SDL text-parsing): `Absinthe.Schema.lookup_type/2` / `Absinthe.run/3` introspection — exact field sets on `Project` + `WorkflowRun` (set-compare, names not counts), exact Query root fields + arguments, **no Mutation or Subscription root**, `WorkflowRunStatus` enum with the 7 values.
  - **Deny-list (leakage defense) applied to IDENTIFIERS, not raw SDL text** — a raw golden scan false-fails on words like `result`/`error`/`config` in AshGraphql-emitted descriptions (WorkflowRun's moduledoc already contains them). Collect every schema field, input-field, and argument name via introspection, then assert the deny-list (snake + camel) against that identifier set: `resume_checkpoint`, `replay_inputs`, `encrypted_*` variants, `claim_token`, `claimed_by`, `claim_expires_at`, `settings`, `tenant_id`, `user_id`, `project_id`, `metadata`, `definition_hash`, `retry_of_id`, `config`, `result`, `error`, `idempotency_key` — iterated so a leak names itself; also the AshCloak decrypting-calculation fence. A raw-text scan of the golden is retained ONLY for the names prohibited even in documentation (the cloak/lease set: `resume_checkpoint`, `replay_inputs`, `encrypted_*`, `claim_token`, `claimed_by`, `claim_expires_at`). The exact field-set assertion above remains the primary protection.
- `test/jido_claw/web/plugs/graphql_tenant_gate_test.exs` (**`async: false`**, app-env override restored to the previous value in `on_exit`): active → tenant set + continue; inactive → 403 halt; **missing actor → 403 halt (fail closed)**; malformed actor → 403; infra stub → 503 (public behavior via the app-env seam).
- `test/jido_claw/web/plugs/graphiql_guard_test.exs`: GET+HTML+empty-query passes; GET+HTML **with `?query=`** halts; GET+JSON-accept halts; POST halts; GET with a body halts (including a body without Content-Length).

### 8. Docs rider (same change)
- **`docs/system/graphql-surface.md`** (new): frontmatter `type: surface`, `description`, `sources` — schema.ex, sdl.ex, graphql_tenant_gate.ex, graphiql_guard.ex, router.ex, both tasks, `ui/schema.graphql`, visibility.ex, **projects.ex, project.ex, orchestration.ex, workflow_run.ex, both calculation modules** (the schema-definition authorities) — `verified: <implementation date>`; house skeleton. Content: read-only = **no GraphQL mutations** (gate may provision a missing tenant row — stated); allowlist posture; tenant gate 403/503 semantics + global-Project rationale; **"shares Visibility's terminal-disposition derivation"** (precise phrasing — not WorkflowView-backed); pipeline order; disabled derive_filter/sort; complexity/token values + rationale + the field-count-complexity-doesn't-multiply-by-limit residual; the result-JSONB-load residual; SDL golden loop; GraphiQL guard (URL-query execution hole) + dev/test compile rationale; residuals (no key-mint task — pre-argus #18; scopes/RBAC deferred).
- **`docs/system/README.md`**: index row (literal ` — `): `- [GraphQL Read Surface](graphql-surface.md) — read-only /gql, tenant-gated, allowlisted fields, SDL golden drift-guarded`.
- **`AGENTS.md`**: Key Patterns bullet (before `<!-- usage-rules-start -->`) with the load-bearing contract + literal `docs/system/graphql-surface.md` pointer; **both** SDL commands in Build & Development Commands — `mix jidoclaw.graphql.schema` (writer) and `mix jidoclaw.graphql.schema.check` (drift guard).
- **`docs/exploration/argus/OVERVIEW.md`**: §2.6 — codegen tooling settled (basic `typescript` + `typescript-operations`; `typescript-react-apollo`/`client-preset` rejected, 2026-07-10) + per-node SPA host; §4.4 — `/gql` behind ApiKeyAuth + tenant-activity gate; read-only bootstrap; config/trust-mutation exclusion now golden-pinned; §6 item 3 — codegen settled + golden-SDL guard implemented.
- **`docs/exploration/argus/DECISIONS.md`**: bump snapshot; Architecture bullets (same-repo `ui/`, per-node serving, pnpm single package, node-free precommit + UI gate, SDL golden precommit-enforced, zero-mutations bootstrap, runs surface shares the Visibility disposition derivation); drop "Apollo codegen choice" from the Slice-1 `Open:` line; annotate the goldens invariant as realized for GraphQL.
- **Program README `## Deviations`**: task-name alignment; `recentWorkflowRuns` rename; timestamps needed explicit `public?: true`; bridge → activity gate; disposition/count via the Visibility seam; GraphiQL guarded (incl. the URL-query hole) + compiled in test; derived filter/sort disabled; JIDO.md checker extended + Frameworks line canonicalized (detection gains Bandit/Jido/ash_graphql).

## Implementation-time verifications (flagged, not blockers)
- Exact DSL spelling/placement of `derive_filter?`/`derive_sort?` and `show_fields` covering calculations + relationships; calculation option spelling (`public?/filterable?/sortable?` in the calculate call vs block).
- `prepare build(limit: arg(:limit), ...)` SDL rendering of the default — assert the real shape in the exact-args introspection test.
- Absinthe.Plug complexity/token option behavior at the pinned values (both verified supported in `Absinthe.Plug` opts); adjust values with recorded rationale if the introspection UI or legitimate queries trip them.
- `Absinthe.Schema.to_sdl` arity + stable output ordering for the pinned version.
- Whether `format --check-formatted` also wants `:absinthe` in import_deps.

## Gate-risk checklist (precommit is the completion bar; zero findings)
`jidoclaw.compile_check` · `system_prompt.check` (untouched) · `jido_md.check` (detector + checker + committed file move together) · `system_docs.check` (page/index/pointer rules) · **new** `graphql.schema.check` (golden fresh) · `deps.unlock --unused` (absinthe transitive — fine) · `format --check-formatted` · `credo --strict` · `reach.check --arch --smells --strict` (no trivial forwarders; calc modules implement a behaviour) · `dialyzer` (PLT rebuild — slow first run) · partitioned suite.

## Verification sequence
1. `mix jidoclaw.graphql.schema` → eyeball golden: both roots, `WorkflowRunStatus`, `disposition`/`findingsDeferredCount`, deny-list absent, no Mutation.
2. **Red/green**: append a byte → `mix jidoclaw.graphql.schema.check` raises with regen message → dump restores green.
3. Targeted: `mix test test/jido_claw/web/graphql_route_test.exs test/jido_claw/web/graphql/ test/jido_claw/web/plugs/graphql_tenant_gate_test.exs test/jido_claw/web/plugs/graphiql_guard_test.exs test/jido_claw/platform/jido_md/ test/jido_claw/platform/jido_md_test.exs`.
4. **Full gate**: `mix precommit` — bare (never piped), exit code + counts verbatim (rotating single-flake rule applies).
5. **Manual curl** (no key-mint task — pre-argus #18): register user + `ApiKey.create(user.id, authorize?: false)` in `iex -S mix phx.server` (tenant provisions on first gated request):
   ```bash
   curl -s localhost:4000/gql -H "content-type: application/json" -H "x-api-key: <key>" \
     -d '{"query":"{ projects { id name githubFullName } recentWorkflowRuns(limit: 5) { id status disposition } }"}'
   ```
   Plus: no header → 401; suspended tenant → 403; `GET /graphiql?query={__schema{queryType{name}}}` (browser/curl with HTML accept) → rejected; plain `/graphiql` renders (dev).
6. Tidewave `project_eval` for in-process `Absinthe.run/3` smokes during development.

## Explicitly out of scope (per program README non-goals)
Any mutation; steps/events/composer lineage; `ui/` toolchain (P2); node-served SPA (P3); channels (P4); PWA (P5); pagination/filters beyond the limit arg; scoped-key enforcement; key-mint task (pre-argus #18).
