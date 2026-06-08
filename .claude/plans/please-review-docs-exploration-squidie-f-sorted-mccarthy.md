# Workflow Event Log — Phase 0 (durable foundation + crash-recovery bug fix)

## Context

`docs/exploration/squidie/FEATURES-WORTH-BORROWING.md` and its two companion docs
(`T1-1-WORKFLOW-EVENT-LOG-PLAN.md`, `REACTOR-ADOPTION.md`) reach one conclusion:
**don't adopt Squidie as a dependency; borrow its single most valuable idea** — derive
workflow-run status from an **append-only event log** instead of mutating a `status`
column in place.

The bug that motivates it is real and verified in our tree. `WorkflowRun` mutates its
`status` column directly via Ash actions (`workflow_run.ex:47-96`), and `WorkflowRunner`
— the only producer — drives `pending → running → completed|failed` synchronously
(`workflow_runner.ex:111-112,172,199`). If the BEAM dies between `:start` and
`:complete`/`:fail`, **the row is stranded in `:running` forever**; nothing reconciles it
on reboot. Two secondary gaps share the root cause: `WorkflowStep`/`ApprovalGate` rows are
never written (dead scaffolding — confirmed: no callers anywhere), and there is no audit
trail of what a run did, in what order.

This plan implements **Reactor-doc Phase 0** ("envelope foundations") plus the **no-gate
slice of the boot recovery reconciler** — i.e. the durable substrate *and* the bug fix.
It deliberately stops short of adopting the Reactor engine itself (Phase 1+). The substrate
built here (event log, append helper, status-as-projection, recovery) is exactly what the
later Reactor adoption builds on — none of it is throwaway; only `WorkflowRunner`'s three
append calls get replaced by a `Reactor.Middleware` later.

**Greenfield**: no compat/migration concern. We replace the direct-mutation actions
outright rather than dual-writing.

**Done means `mix precommit` passes** — a heavy gate: `jidoclaw.compile_check`,
`jidoclaw.system_prompt.check`, `deps.unlock --unused`, `format`,
`reach.check --arch --smells --strict`, `credo --strict`, `dialyzer`, `test`
(`mix.exs:245-254`).

## Scope

**In:**
1. New append-only `WorkflowEvent` Ash resource (tenant-scoped, audit trail).
2. Append helper — sole `seq` allocator (per-run lock), recursive redaction, and
   status-authority kinds update `WorkflowRun.status` **in the same transaction**.
3. `WorkflowRun.status` becomes **projection-owned** — the direct-mutation actions are
   removed; status is written only by the append path.
4. Rewire `WorkflowRunner` to **produce events** instead of mutating status.
5. Boot-time recovery reconciler (no-gate case) — strands → `:failed` with audit. **The
   bug fix.**
6. **Global** redaction fix in `Env.sensitive_key?/1` (closes a real leakage hole for
   bare keys `password`/`secret`/`token`/`authorization`/`credential`).

**Explicitly deferred (named so they read as decisions, not omissions):**
- **Async step-timeline `Writer`** — the Reactor doc lists it in Phase 0, but in Phase 0
  the only events are run-lifecycle events, which are status-authority and *must* be
  written synchronously anyway. The async path has no producer until per-step events exist
  (with the Reactor middleware). Build it in Phase 1 where it's actually exercised.
- Reactor engine, skills→Reactor compiler, human gates + gate-aware recovery, replay/
  fingerprint, cron idempotency, deadline/actor-visibility read-models, `WorkflowStep`/
  `ApprovalGate` rework, multi-node lease/fencing. (Reactor doc §4.5–§4.11, Phases 1–5.)
- **Surface/column redaction** of `WorkflowRun.result`/`error` (T2-2). Phase 0 redacts the
  new durable **event** payloads; the run's `result`/`error` columns keep current raw
  values. Boundary is intentional.

## Current baseline (verified)

- `JidoClaw.Resource` (`resource.ex:30-58`) injects `use Ash.Resource` + AshPostgres +
  the tenant policy (bypass `:by_id_global`; `ActorTenantMatches` for writes;
  `tenant_id == ^actor(:tenant_id)` for reads). It does **not** inject `tenant_id`/
  `multitenancy`/`belongs_to :tenant` — the consumer declares those. `WorkflowRun`
  (`workflow_run.ex:3,15-19,120-123,196-200`) is the copy template.
- `Tenant` is `JidoClaw.Tenants.Tenant` at `lib/jido_claw/tenants/resources/tenant.ex`
  (string PK).
- Redaction: `Patterns.redact/1` only scans **binaries**, no-ops on maps
  (`patterns.ex:45-51`). `Transcript.redact/2` walks maps/lists recursively and
  key-redacts via `Env.sensitive_key?/1` (`transcript.ex:64-82,111-113`). `Env`'s rule is
  **suffix-only** (`env.ex:35,83-87`) → misses bare keys. (`Redaction.Memory` already
  carries a fuller exact-match list — reference it, optional convergence later.)
- Supervision: add a transient boot `Task` mirroring
  `Memory.Consolidator.SystemJobsInitializer` (`application.ex:213-218`, module file is the
  template); `Repo` starts at `application.ex:138`.
- Tests use `JidoClaw.TenantCase` (not `DataCase`): `seed_tenant/1`, `actor_for/1`
  (`%{user_id: t, tenant_id: t}`), shared sandbox, `AsyncWriter.flush()` in `on_exit`.
  `workflow_runner_test.exs` is the producer-test template (stubs the executor via
  `:cron_workflow_executor`).
- reach arch layers cover only `web`/`data`; **`Orchestration.*` is unconstrained**, so
  module placement is free. The live gate is `smells --strict` at zero (`.reach.exs:65`).

## Implementation

### 1. `WorkflowEvent` resource — `lib/jido_claw/orchestration/workflow_event.ex` (new)

Per `T1-1-...PLAN.md` Phase 1. **Does NOT use the `JidoClaw.Resource` macro** — that macro
always injects `bypass action(:by_id_global)` (`resource.ex:44-47`), which fails to compile
for a resource that doesn't define a `:by_id_global` action, and events are only ever read
run-scoped (`for_run`), never by global id. Instead, mirror `ReputationImport`
(`reputation_import.ex:15-31`): plain `use Ash.Resource, otp_app: :jido_claw, domain:
JidoClaw.Orchestration, data_layer: AshPostgres.DataLayer, authorizers:
[Ash.Policy.Authorizer]` + a hand-written `policies do` block (the two non-bypass policies:
`ActorTenantMatches` for `[:create,:update,:destroy]`; `tenant_id == ^actor(:tenant_id)`
for `:read`). *(Finding 1.)*
- `postgres`: table `workflow_events`, repo `JidoClaw.Repo`, `custom_indexes` →
  `index([:workflow_run_id, :seq], unique: true)` (the uniqueness fence + range/sort index).
- `multitenancy`: `strategy(:attribute)`, `attribute(:tenant_id)`, `global?(false)`.
- Attributes: `uuid_primary_key(:id)`; `tenant_id :string` non-null; `seq :integer`
  non-null; `kind :atom` non-null with `one_of:` the full Reactor-shaped vocabulary
  (`run_started run_resumed step_started step_completed step_failed step_retried
  step_compensated step_undone approval_requested approval_resolved run_halted
  run_completed run_failed run_cancelled run_recovered`); `payload :map`
  **`allow_nil?(false), default: %{}`**; `metadata :map` **`allow_nil?(false), default: %{}`**
  (the helper coerces `nil → %{}`); `occurred_at :utc_datetime_usec` non-null **with an
  attribute-level `default(&DateTime.utc_now/0)`** — *not* a `before_action` default, which
  runs *after* validation and so would trip `allow_nil?(false)` on an omitted value; matches
  `audit/resources/event.ex:192` (*4th-pass fix*); `timestamps()`.
- Relationships: `belongs_to :workflow_run, WorkflowRun` (`allow_nil?: false`);
  `belongs_to :tenant, JidoClaw.Tenants.Tenant` (`define_attribute?: false`,
  `attribute_writable?: true`, `allow_nil?: false`) — copy `workflow_run.ex:196-200`.
- Actions: `defaults([:read])`; `read :for_run` (arg `workflow_run_id`,
  `prepare build(sort: [seq: :asc])`, `filter expr(workflow_run_id == ^arg(...))`);
  `create :append` with `transaction?(true)`, `accept([:workflow_run_id, :kind, :payload,
  :metadata, :occurred_at])` — **`:seq` and `:tenant_id` are NOT accepted** (`seq` is forced
  by the change; `tenant_id` is set from the `tenant:` opt by Ash), `change(Changes.Allocate)`.
- `code_interface`: `define(:append)`, `define(:for_run, args: [:workflow_run_id])`,
  `define(:list, action: :read)`.

### 2. `WorkflowEvent.Changes.Allocate` — `.../workflow_event/changes/allocate.ex` (new)

An `Ash.Resource.Change` that runs entirely inside the `:append` action's transaction.
**Every internal Ash read/update threads `tenant: changeset.tenant`** (the tenant the
append was called with == the event's `tenant_id`) — `authorize?: false` drops the *policy*
but NOT the multitenancy *filter*, so without `tenant:` an attribute-multitenant
read/update would fail or silently cross the tenant boundary. *(Finding 2.)*

- `before_action`:
  1. Lock + read the run: `WorkflowRun |> Ash.Query.filter(id == ^run_id) |>
     Ash.Query.lock("FOR UPDATE") |> Ash.read_one(tenant: changeset.tenant,
     authorize?: false)`. **Handle `{:ok, nil}` and `{:error, _}`** (missing run, or tenant
     mismatch where `tenant: changeset.tenant` filters it out) by returning
     `Ash.Changeset.add_error(changeset, …)` — a clean changeset error so the append rolls
     back predictably instead of crashing on a `nil`. *(2nd-pass finding 4.)* On `{:ok, run}`,
     stash `run.status` via **`Ash.Changeset.set_context/2`** (deep-merges a map — *not*
     `put_context/3`, which is `(changeset, key, value)`; two namespaced `put_context` calls
     would overwrite — *3rd-pass finding 1*):
     `Ash.Changeset.set_context(changeset, %{workflow_event: %{current_status: run.status}})`.
  2. `seq = (max existing seq for run) + 1` (Ash aggregate/read, `tenant: changeset.tenant`,
     after the lock so concurrent appends for one run serialize); `force_change_attribute(:seq, seq)`.
  3. **Stash the RAW `payload`** with another `set_context/2` (deep-merge preserves
     `current_status` from step 1) —
     `Ash.Changeset.set_context(changeset, %{workflow_event: %{raw_payload: payload}})`
     *before* redacting — then `force_change_attribute(:payload, Transcript.redact(payload))`
     and same for `:metadata`. The raw copy is what the run-column projection uses (Finding 3);
     the event attribute stores only the redacted copy. (No `:occurred_at` handling here — the
     attribute default covers omission; 4th-pass fix.)
  The unique `(workflow_run_id, seq)` index is the backstop.
- `after_action` (only for `Projection.status_authority?(kind)`) — read stashes back from
  `changeset.context[:workflow_event]` (there is **no** `Ash.Changeset.get_context` in this
  Ash version; read the `changeset.context` field directly — *2nd-pass finding 3*):
  1. **Transition guard** — `Projection.next_status(context.current_status, kind)` returns
     `{:ok, new_status} | :illegal`. On `:illegal` (e.g. `run_completed` on a non-`:running`
     run, a terminal→terminal append), return `{:error, …}` so the whole append transaction
     rolls back — the event is NOT persisted and status is unchanged. This preserves the
     pending/running/terminal invariants the removed `start`/`complete`/`fail`/`cancel`
     actions enforced, even though `:append` is a code interface. *(Finding 4.)*
  2. Update the run via `WorkflowRun`'s internal `:set_status` action with
     `Projection.status_attrs(kind, context.raw_payload, result.occurred_at)` — source
     `occurred_at` from the **created event** (`result`), so `started_at`/`completed_at`
     always equal the persisted event time. Result/error come from the **raw** stashed
     payload, so run columns stay raw (Finding 3). `tenant: changeset.tenant,
     authorize?: false`. Same transaction → status never lags the event.

> Verify in execution: Ash 3 `Ash.Query.lock/2`; reading `changeset.tenant`;
> `Ash.Changeset.set_context/2` (deep-merge) writes and `changeset.context` reads (no
> `get_context`); that `after_action` runs *inside* the txn
> (`mix usage_rules.search_docs "lock" -p ash`, or Tidewave `get_docs`).

### 3. `WorkflowEvent.Projection` — `.../workflow_event/projection.ex` (new)

Pure functions shared by the change, recovery, and tests. **All payload access tolerates
both atom and string keys** (`payload[:result] || payload["result"]`) — the change projects
from the raw in-memory (atom-key) payload, while `project_status/1` folds persisted
(string-key, JSONB-round-tripped) events. *(Smaller improvement.)*
- `status_authority?(kind)` → true for `run_started`/`run_resumed`/`run_completed`/
  `run_failed`/`run_cancelled` (Phase 0 set). `run_recovered`/`run_halted`/`step_*`/gate
  kinds → false (gate kinds gain mappings when human gates land).
- `next_status(current_status, kind)` → `{:ok, new_status} | :illegal` — the transition
  guard (Finding 4). Legal: `run_started` only from `:pending`; `run_completed` only from
  `:running`; `run_failed` from `:pending|:running|:awaiting_approval`; `run_cancelled` from
  any non-terminal; `run_resumed` only from `:awaiting_approval`. Any terminal→terminal or
  out-of-order kind → `:illegal`.
- `status_attrs(kind, payload, occurred_at)` → `run_started → %{status: :running,
  started_at: occurred_at}`; `run_completed → %{status: :completed, completed_at:
  occurred_at, result: payload[result]}`; `run_failed → %{status: :failed, completed_at:
  occurred_at, error: payload[error]}`; `run_cancelled → %{status: :cancelled, completed_at:
  occurred_at}`; `run_resumed → %{status: :running}`.
- `project_status(events)` → fold a `seq`-sorted event list to a status (applies
  `next_status` per status-authority event). Authority at runtime is the materialized
  column; this exists to **prove** column == fold in tests.

### 4. `WorkflowLog` append helper — `lib/jido_claw/orchestration/workflow_log.ex` (new)

The ergonomic seam both producers (and recovery) share:
- `append(run, kind, payload, opts \\ [])` → coerces `nil` payload/metadata to `%{}`, builds
  attrs, calls `WorkflowEvent.append` threading `tenant:`/`actor:`. Returns
  `{:ok, event} | {:error, term}`.
- `append_all(run, events, opts)` — the **atomic multi-append seam** (`events` is a list of
  `{kind, payload}`). **Guard the empty list** (`append_all(_, [], _) → {:error, :no_events}`)
  so it can't silently return `{:ok, nil}` (*4th-pass polish*). Otherwise wrap in
  **`Ash.transact/3`** (the local idiom — `block.ex:601`,
  `run_server.ex:731`), which **auto-rolls back when the fn returns `{:error, reason}`** —
  cleaner than a manual wrapper that just returns the error and commits anyway
  (*2nd-pass finding 2*; *3rd-pass finding 2*). Shape the fn to short-circuit on the first
  failure and return the **terminal event** (bare) on success:
  ```
  Ash.transact(WorkflowEvent, fn ->
    Enum.reduce_while(events, nil, fn {kind, payload}, _ ->
      case append(run, kind, payload, opts) do
        {:ok, ev} -> {:cont, ev}
        {:error, reason} -> {:halt, {:error, reason}}   # fn returns {:error,_} → auto-rollback
      end
    end)
  end)
  ```
  (Explicit `Ash.DataLayer.rollback(WorkflowEvent, reason)` — `forge/persistence.ex:140`,
  `block.ex:609` — is the alternative abort; `Repo.transaction/1`+`Repo.rollback/1` with
  `FOR UPDATE` at `reputation.ex:201-217` is the raw-Ecto fallback.) *(Verify `Ash.transact`
  arity/`{:error,_}`-rollback contract in execution; `config :ash, warn_on_transaction_hooks?`
  is already `false` in test — `config/test.exs:52`.)*
- `append_recovery(run, prior_status)` → `append_all(run, [{:run_recovered, %{reason: …,
  prior_status: prior_status}}, {:run_failed, %{error: …}}], tenant: run.tenant_id, actor:
  Actor.system(run.tenant_id))`. One transaction → neither persists without the other
  (Finding 5). Used only by the reconciler.

### 5. `WorkflowRun` edits — `lib/jido_claw/orchestration/workflow_run.ex`

- **Remove** the six direct-mutation actions `start`/`await_approval`/`resume`/`complete`/
  `fail`/`cancel` (`:47-96`) and their `code_interface` `define`s (`:23-28`). Keep
  `create` (genesis `:pending`), `read`, `destroy`, `list_active`, `by_id_global`,
  `by_project`.
- **Add** internal `update :set_status` — **`public?(false)`** (matches the "internal
  action" intent and avoids exposure through Ash API extensions like AshAdmin — leaving it
  out of `code_interface` alone doesn't; *3rd-pass improvement*; `public?(false)` is the
  local idiom, e.g. `api_key.ex:58`, `session.ex:205`), `accept([:status, :started_at,
  :completed_at, :result, :error])`. It carries **no** status precondition itself because the
  legality check moved up into the append path (`Projection.next_status/2` in the `Allocate`
  after_action, Finding 4) — that's where the removed actions' pending/running/terminal
  invariants are now enforced, *before* `:set_status` is ever called. The change calls it via
  `Ash.Changeset.for_update/3` + `Ash.update` (internal calls work on a private action).
- **Add** `read :list_non_terminal_global` — `multitenancy(:bypass)`,
  `filter(expr(status in [:pending, :running, :awaiting_approval]))` — for the cross-tenant
  recovery scan (called `authorize?: false`). Mirrors `by_id_global` (`:103-108`). **Add the
  matching `code_interface` `define(:list_non_terminal_global)`** — recovery calls
  `WorkflowRun.list_non_terminal_global(authorize?: false)`, which won't compile without it.
  *(2nd-pass finding 1.)*
- **Add** `has_many :events, JidoClaw.Orchestration.WorkflowEvent`.
- Grep `WorkflowRun.{start,complete,fail,cancel,await_approval,resume}` to confirm
  `WorkflowRunner` is the only caller before removing (exploration says yes; verify).

### 6. `WorkflowRunner` rewire — `lib/jido_claw/orchestration/workflow_runner.ex`

Keep structure, broadcasts, the never-raises contract, and the
`# reach:disable-for-this-file bare_rescue` pragma (`:48`). Swap the three status writes:
- `create_and_start` (`:111-112`): keep `WorkflowRun.create`; replace `WorkflowRun.start`
  with `WorkflowLog.append(created, :run_started, %{cron_job_id: state.id, skill: name},
  tenant:, actor:)`. Thread `created` as `started` downstream (`id`/`tenant_id` are stable;
  the `:run_started` broadcast keeps `status: :running`).
- `finalize_complete` (`:172`): `WorkflowLog.append(started, :run_completed, %{result:
  result}, ...)`; broadcast `completed_at` from the returned event's `occurred_at`. On
  `{:error, reason}` keep `{:error, {:terminal_persist_failed, reason}}`.
- `finalize_fail` (`:199`): `WorkflowLog.append(started, :run_failed, %{error: formatted},
  ...)`; keep the warning-log on append error.
- Update the moduledoc, which still names `WorkflowRun.fail/2` (`:38`) and "Terminal Ash
  transitions … validated against `status == :running`" — replace with the event-append
  model (`WorkflowLog.append(.., :run_failed, ..)`; legality via `Projection.next_status`).
  *(Smaller improvement.)*

### 7. Recovery reconciler — `lib/jido_claw/orchestration/workflow_recovery.ex` (new)

`use Task`; `start_link/1` → `Task.start_link(__MODULE__, :run, [opts])`. Child spec
(map, `restart: :transient`) added to `core_children/0` in `application.ex` after infra is
up — mirror `SystemJobsInitializer` (`application.ex:213-218`).
- **`run/1` runs recovery only when it is the sole owner of workflow execution** — it
  no-ops unless **all** of: `Application.get_env(:jido_claw, :workflow_recovery)[:enabled?]`
  (default true; **false in `config/test.exs`**), `serve_mode != :mcp`
  (`application.ex:31` shows the key), and `cluster_enabled != true`. *(Finding 6.)*
  Rationale: `core_children/0` boots in **every** surface (MCP, gateway, future cluster
  nodes), so an ungated reconciler in an MCP process or a second node could mark a run
  `:failed` while another live BEAM is still executing it. Boot recovery is explicitly the
  **single-node restart** mechanism (Reactor doc §4.8); multi-node safety is the deferred
  lease/fencing work (§4.11), under which lease expiry — not a boot scan — reclaims a dead
  node's runs. Gating it off when clustered/MCP makes Phase 0 safe without that machinery.
  When it does run: `reconcile_all/0`.
- `reconcile_all/0`: `WorkflowRun.list_non_terminal_global(authorize?: false)` → per run,
  `reconcile_run/1`.
- `reconcile_run/1` (no-gate only): nothing is live at boot, so a non-terminal run is
  stranded → `WorkflowLog.append_recovery(run, run.status)` (per-run
  `tenant: run.tenant_id, actor: Actor.system(run.tenant_id)`). Projection folds
  `run_failed → :failed`. Emit `:telemetry.execute([:jido_claw, :orchestration, :recovered],
  ...)`. A code comment notes gate-aware parking (leave `:awaiting_approval` runs with a
  checkpoint untouched) lands with human gates — `:awaiting_approval` is currently
  unreachable (its producer was removed).

### 8. Global redaction fix — `lib/jido_claw/security/redaction/env.ex`

- Add an exact-match (case-insensitive) bare-key set to `sensitive_key?/1` alongside the
  existing suffix/specific regexes: `password secret token authorization credential`.
  Use **exact** match (downcased), not substring, so `tokenizer`/`session_id` stay safe.
- Update the moduledoc bare-key list. The event helper then needs **no** special opts —
  plain `Transcript.redact/1` inherits the wider set.
- Grep `Env.sensitive_key?` call sites first (Transcript + any env-var redaction) to scope
  blast radius; extend `env_test`/`transcript_test` and confirm no existing redaction
  assertion regresses (these five are near-universally secrets; over-redaction risk is low).

### 9. Domain registration, config, supervision, migration

- `lib/jido_claw/orchestration.ex:19-23`: add `resource(JidoClaw.Orchestration.WorkflowEvent)`.
- Config: `config/config.exs` → `config :jido_claw, :workflow_recovery, enabled?: true`;
  `config/test.exs` → `enabled?: false` (boot recovery off in test; tests drive
  `WorkflowRecovery.reconcile_all/0` directly inside the sandbox).
- Supervision: add the `WorkflowRecovery` transient `Task` child to `core_children/0`
  (after infra/Repo), per §7.
- `mix ash.codegen add_workflow_event_log` → review the generated `priv/repo/migrations/*`
  + `priv/resource_snapshots/repo/workflow_events/*.json` → `mix ecto.migrate`. (Only the
  new table needs a migration; removing actions / adding `:set_status` touch no columns.)

## Testing

All under `test/jido_claw/orchestration/`, `use JidoClaw.TenantCase`, `seed_tenant/1` +
`actor_for/1`. New: `workflow_event_test.exs`, `workflow_recovery_test.exs`. Update
`workflow_runner_test.exs`. Extend redaction tests.

- **`workflow_event_test`**: appends allocate ascending `seq` (1,2,3); N concurrent appends
  to one run yield N events with unique `1..N` `seq` (proves the per-run lock + unique
  index); `for_run` is tenant-isolated (tenant B can't read tenant A's events); event
  payload `%{"password" => "x", "api_key" => "sk-..."}` is stored `[REDACTED]`; `run_started`
  flips `status → :running` + `started_at` **in the same txn**, `run_completed → :completed`,
  `run_failed → :failed`, and `Projection.project_status(events) == run.status`; a non-authority
  kind (`step_started`/`run_recovered`) leaves status unchanged.
- **transition guard (Finding 4)**: `append(run, :run_completed, …)` on a `:pending` run
  returns `{:error, …}`, and **neither** the event nor a status change persists
  (`for_run` count unchanged, status still `:pending`); a terminal→terminal append (e.g.
  `run_completed` then `run_failed`) is rejected.
- **raw/redacted boundary (Finding 3)**: `append(run, :run_completed, %{result: %{"token"
  => "sk-secret", "data" => "ok"}})` → the **event** payload's `result.token` is
  `[REDACTED]`, but `run.result` (the column) keeps the **raw** `"sk-secret"`.
- **`workflow_recovery_test`**: strand a `:running` run (`create` + `run_started`, no
  terminal) → `reconcile_all/0` → status projects `:failed`; both `run_recovered` +
  `run_failed` events exist (with consecutive `seq`); a `:completed` run is untouched;
  tenant-blind (strands in two tenants both fail in one pass).
- **recovery atomicity (2nd/3rd-pass finding 5)**: consecutive `seq` alone does **not** prove
  single-transaction rollback, and stubbing `WorkflowLog.append` isn't feasible (no
  monkey-patching in Elixir). Instead drive the real `append_all/3` seam with a batch whose
  **second** append fails *naturally* via the transition guard — e.g.
  `append_all(run, [{:run_recovered, %{}}, {:run_started, %{}}], …)` on a `:running` run
  (`run_started` is `:illegal` from `:running` → `{:error, …}`). Assert the call returns
  `{:error, …}`, the run has **no** persisted `run_recovered` event, and its status is
  unchanged — proving `Ash.transact` rolled the whole batch back with a genuine failure and
  no test-only seam.
- **`workflow_runner_test` (update)**: existing `:completed`/`:failed` assertions still
  hold (status now via the helper). Add: success path logs `run_started` then
  `run_completed`; each failure path (`{:error,_}`, raise, unexpected return) logs
  `run_started` then `run_failed` — assert via `WorkflowEvent.for_run`.
- **redaction**: `env_test` — `sensitive_key?/1` true for the five bare keys (+ case),
  false for `description`/`session_id`; `transcript_test` —
  `redact(%{"password" => "hunter2"}) == %{"password" => "[REDACTED]"}`.

## Verification (end-to-end)

1. `mix ash.codegen add_workflow_event_log && mix ecto.migrate` (or `mix ash.setup`).
2. `mix test test/jido_claw/orchestration/ test/jido_claw/security/redaction/`.
3. Tidewave: `get_ash_resources` shows `WorkflowEvent`; after a stubbed run via
   `project_eval` (`WorkflowRunner.run/1`), `execute_sql_query` →
   `select workflow_run_id, seq, kind from workflow_events order by seq` shows
   `run_started → run_completed`, and the run's `status` matches.
4. Strand test via `project_eval`: insert a `:running` run + `run_started` (no terminal),
   call `WorkflowRecovery.reconcile_all/0`, confirm `status` → `:failed` + the two events.
5. **`mix precommit` passes** — the bar for done.

## Precommit gate & risks

- **`reach.check --smells --strict` (zero today)**: new modules may trip `fixed_shape_map`
  (event/status attr maps) or `behaviour_candidate`. Resolve per the documented policy —
  vary shapes, else inline `# reach:disable-for-this-file <smell>` or add the module to the
  `.reach.exs` ignore list (nested change modules may need a `WorkflowEvent.*` glob, as
  `Memory.Block.*` does at `.reach.exs:107`). Run `mix reach.check --smells --strict` and
  clear before committing.
- **`dialyzer`**: full `@spec`s on every new public fn (`append/4`, `append_recovery/2`,
  projection fns, recovery fns).
- **`credo --strict`**: moduledocs (`@moduledoc false` on internals), function length, no
  `TODO` comments (phrase forward-notes as plain comments).
- **`jidoclaw.system_prompt.check`**: no tools/skills added → unaffected; still run it.
- **Ash specifics to confirm in execution**: `Ash.Query.lock("FOR UPDATE")` + reading
  actor/tenant inside a change; that `after_action` runs inside the action's transaction
  (it does — `after_transaction` is the post-commit one); create-action transactionality.
- **Global `Env` change blast radius**: confirmed app-wide by choice; mitigated by
  exact-match (not substring) and a test sweep of existing redaction assertions.
- **Sandbox**: the helper's `FOR UPDATE` + transaction run fine under the shared
  `Ecto.Sandbox`; recovery is disabled at boot in test and driven directly from tests.
