# M7 — Trace retention sweeper

**Finding (docs/reports/code-review-2026-06-10.md, M7):** Durable `trace_runs`/`trace_events`
grow without bound. The in-memory ring is capped (100 traces x 300 events) but every event with
`persist?: true` (prod default) writes rows, and no prune/retention exists. Fix: a retention sweeper.

This plan mirrors the existing `RequestCorrelation.Sweeper` precedent, adapted for the two key
differences in the trace subsystem: (1) **two tables, no FK/cascade** — delete events first, then runs;
(2) **no Ash policies on trace resources** — no actor / authorize options needed (unlike RequestCorrelation).

Scope: one finding. No new abstractions.

---

## Verified facts (grounded in source — do not re-derive)

- **`updated_at` IS bumped on every live event append.** `TraceRun.upsert_run` has explicit
  `upsert_fields` that exclude `updated_at`, BUT AshPostgres (`deps/ash_postgres/lib/data_layer.ex:2547-2563`)
  always refreshes `update_default` columns (i.e. `update_timestamp(:updated_at)`) when an upsert modifies
  fields — `touch_update_defaults?` defaults `true`. So a trace that is still receiving events keeps a fresh
  `updated_at`. A `:skipped_upsert` (stale/out-of-order event, `incoming_last_seq <= last_seq`) does NOT bump
  it — correct, since that is not new activity. => **Retention key is `updated_at`.**
- **No FK between the two tables.** `priv/repo/migrations/20260519142518_add_trace_domain.exs` creates
  `trace_events` and `trace_runs` as plain tables; `trace_events` has no `references(:trace_runs)`. The
  `has_many :events` on `TraceRun` is a logical join on the `trace_id` **string** (source_attribute /
  destination_attribute `:trace_id`), not a DB FK. => **No DB cascade exists. Must delete events-by-trace_id
  first, then the run rows.** `trace_events` has index `[:tenant_id, :trace_id, :seq]`, so delete-by-trace_id
  is indexed.
- **No authorizers/policies on either trace resource.** `trace_run.ex` / `trace_event.ex` use
  `use Ash.Resource` with NO `authorizers:` key. `Trace.history/1` (`lib/jido_claw/trace.ex:167`) reads via
  `Ash.read` passing only `tenant:`/`page:` — no actor, no `authorize?`. => **Sweeper needs NO actor and NO
  authorize options.** (RequestCorrelation needs `authorize_if(always())` because it *has* the policy authorizer;
  trace does not, so do not copy that.)
- **`global?(true)` => a tenantless read returns all tenants.** `deps/ash/lib/ash/actions/read/read.ex:2837`
  gates the tenant requirement on `multitenancy_global?(resource) || query.tenant`. A no-`tenant:` `Ash.read`
  on `TraceRun`/`TraceEvent` spans every tenant — exactly what a cross-tenant sweep needs. Same pattern
  `Trace.history()` already uses with no `tenant_id`.
- **No index serves a bare `updated_at < ?` scan.** Existing trace_runs indexes are
  `[:request_id]`, `[:run_id]`, `[:agent_id]`, `[:tenant_id, :inserted_at]`, plus the unique `[:trace_id]`.
  None is keyed on `updated_at`. => **a migration adding `index([:updated_at])` on trace_runs is needed.**
- **Existing tests backdate timestamps with raw SQL.** `test/jido_claw/memory/retrieval_test.exs` uses
  `JidoClaw.Repo.query!("UPDATE memory_facts SET ... WHERE id = $1", [...])`; `persistence_test.exs:97` uses
  `Repo.query!("UPDATE trace_events SET schema_version = NULL WHERE trace_id = $1", ...)`. Same technique for
  backdating `updated_at`/`inserted_at` (create_timestamp/update_timestamp stamp `now()`, so raw UPDATE is the
  only way).
- **Config:** `config/config.exs:258-267` `config :jido_claw, trace: [enabled?, max_traces, max_events_per_trace,
  persist?, persist_sync?]`. Tests flip it via `Application.put_env(:jido_claw, :trace, ...)` with on_exit restore
  (`persistence_test.exs:13-22`).
- **Supervision:** `application.ex:160-168` infra_children order — `RequestCorrelation.Cache`, then
  `Trace.Persistence` (164), `Trace.Collector` (165), `Recorder` (166), `RequestCorrelation.Sweeper` (167),
  `Audit.SignalListener` (168). Persistence MUST precede Collector (comment at 161-163). The retention sweeper has
  no such ordering constraint (it only reads/destroys rows; needs Repo, which is already up far earlier in
  `core_children`).
- **reach (`.reach.exs`):** `JidoClaw.Trace.*` is in the `data` layer; the only forbidden dep is `{:data, :web}`.
  A sweeper in `trace/` aliasing trace resources is unconstrained. The `RequestCorrelation.Sweeper` precedent
  carries one annotation worth mirroring: `# reach:disable-next-line bare_rescue` above its rescue.
- **No RequestCorrelation.Sweeper test exists** (only `request_correlation_test.exs`, which tests the resource's
  accept list, not the sweeper). So there is no sweeper-test precedent to copy directly — model the test on
  `persistence_test.exs` (shared sandbox, `async: false`, trace-config put_env) and test the sweep function
  synchronously.
- **precommit:** `jidoclaw.compile_check`, `jidoclaw.system_prompt.check`, `deps.unlock --unused`,
  `format --check-formatted`, `reach.check --arch --smells --strict`, `credo --strict`, `dialyzer --format short`,
  `test`. `mix test` runs `ash.setup --quiet` first, so the new migration auto-applies.

---

## Design decisions

| Question | Decision |
|---|---|
| Retention key | `trace_runs.updated_at < cutoff` (last activity; protects long-lived active traces — verified `updated_at` is bumped per live event). |
| Delete order | Two-phase, no DB cascade: (1) read expired run `trace_id`s (batch), (2) `Repo.delete_all` events `WHERE trace_id IN (...)`, (3) `Ash.bulk_destroy` the run rows. Orphan events (run missing) are a non-issue in practice (Persistence writes run first) but are also handled — see "orphan note". |
| Multitenancy | Tenantless `Ash.read` / `Ash.bulk_destroy` (global? => spans all tenants). No actor, no authorize opts. |
| Config knob | `retention_days` in the `trace:` keyword. Default `30`. Disable semantics: `nil` or `0` or `:infinity` => never sweep (no-op tick). |
| Sweeper module | `JidoClaw.Trace.RetentionSweeper` (sibling of `Trace.Persistence`, in `lib/jido_claw/trace/`). |
| Sweep entrypoint | `TraceRun.sweep_expired/1` code-interface-adjacent function ON the `TraceRun` resource (mirrors `RequestCorrelation.sweep_expired/0`), taking the cutoff. |
| Supervision slot | `application.ex` infra_children, immediately AFTER `JidoClaw.Trace.Collector` (line 165) and before `Recorder` — or grouped with the other sweeper; either is fine. Place next to Persistence/Collector for locality. |
| Batch size | `@sweep_batch 1_000` (mirror RequestCorrelation), with full-batch immediate re-send drain. |
| Tick | `@tick_ms 3_600_000` (1 hour) — retention is coarse (day granularity), no need for the 60s correlation cadence. |

**Why a TraceRun resource function (not raw Ecto for everything):** the run-row destroy goes through Ash
(`bulk_destroy`) for consistency with the rest of the trace data layer and to keep the multitenancy/global
semantics handled by Ash. The **event** delete uses raw `Repo.delete_all` keyed on `trace_id IN (...)` because
TraceEvent has no single-key destroy action and bulk-destroying potentially thousands of event rows per run via
Ash would be far heavier than one indexed `DELETE ... WHERE trace_id = ANY($1)`. This is the minimal, fastest
correct shape. (Both tables are append-only logs with no policies, so a raw delete is safe.)

**Orphan note:** Step 2 deletes events by the `trace_id`s of the *expired runs* we found. Events whose run row is
missing entirely (should not happen — Persistence upserts the run before appending the event) would not be caught
by run-driven sweeping. This is acceptable for M7 (the dominant growth is runs+their events together). If we want
belt-and-suspenders, the same sweep can optionally also `DELETE FROM trace_events WHERE inserted_at < cutoff`
(trace_events has `create_timestamp(:inserted_at)`); but that needs its own `[:inserted_at]` index on trace_events
to be cheap. **Recommendation: keep M7 minimal — drive deletion off expired runs only**, and note the orphan path
as a documented non-goal. (Decision flagged for the user below.)

---

## Files to create / modify

### 1. `config/config.exs` (MODIFY) — add the retention knob

In the `trace:` keyword (lines 258-267), add one entry:

```elixir
  trace: [
    enabled?: true,
    max_traces: 100,
    max_events_per_trace: 300,
    persist?: true,
    persist_sync?: false,
    # Durable trace_runs/trace_events older than this (by last-activity
    # updated_at) are pruned by JidoClaw.Trace.RetentionSweeper. nil / 0 /
    # :infinity disables the sweep.
    retention_days: 30
  ],
```

No env-specific override needed. Tests put_env the whole `:trace` keyword, so this default is overridable per-test.

### 2. `lib/jido_claw/trace/resources/trace_run.ex` (MODIFY) — index + sweep function

**(a) Add the cutoff index** in `custom_indexes do ... end` (line 28-33):

```elixir
    custom_indexes do
      index([:request_id], where: "request_id IS NOT NULL")
      index([:run_id], where: "run_id IS NOT NULL")
      index([:agent_id], where: "agent_id IS NOT NULL")
      index([:tenant_id, :inserted_at])
      index([:updated_at])
    end
```

**(b) Add a read action `:expired`** in `actions do` (mirror RequestCorrelation `:expired`), taking a cutoff arg.
A read action with an argument keeps the filter expression in Ash and reuses the global? read semantics:

```elixir
    read :expired do
      description("List trace_runs whose last activity (updated_at) is older than the cutoff.")
      argument(:cutoff, :utc_datetime_usec, allow_nil?: false)
      filter(expr(updated_at < ^arg(:cutoff)))
      prepare(build(sort: [updated_at: :asc]))
    end
```

Add to `code_interface`: `define(:expired, action: :expired, args: [:cutoff])`.

**(c) Add the sweep function** at the bottom of the module (mirror `RequestCorrelation.sweep_expired/0`,
but two-phase). Needs `alias JidoClaw.Repo` (or `JidoClaw.Repo` fully-qualified) and
`require Ash.Query` / `alias Ash.Query`:

```elixir
  @sweep_batch 1_000

  @doc """
  Delete at most #{@sweep_batch} trace_runs (and all their trace_events)
  whose last activity (`updated_at`) is older than `cutoff`. Two-phase
  because there is no DB FK between trace_events and trace_runs — events
  are deleted by `trace_id` first, then the run rows.

  Returns `{:ok, runs_deleted}`. Called by `JidoClaw.Trace.RetentionSweeper`;
  when the result is `{:ok, #{@sweep_batch}}` the sweeper reschedules
  immediately to drain the backlog.
  """
  @spec sweep_expired(DateTime.t()) :: {:ok, non_neg_integer()}
  def sweep_expired(%DateTime{} = cutoff) do
    query =
      __MODULE__
      |> Ash.Query.for_read(:expired, %{cutoff: cutoff})
      |> Ash.Query.limit(@sweep_batch)

    case Ash.read(query) do
      {:ok, []} ->
        {:ok, 0}

      {:ok, runs} ->
        delete_events_for(Enum.map(runs, & &1.trace_id))
        do_bulk_destroy(runs)

      {:error, reason} ->
        require Logger
        Logger.warning("[TraceRun] retention read failed: #{inspect(reason)}")
        {:ok, 0}
    end
  end

  defp delete_events_for([]), do: :ok

  defp delete_events_for(trace_ids) do
    import Ecto.Query, only: [from: 2]

    JidoClaw.Repo.delete_all(
      from(e in "trace_events", where: e.trace_id in ^trace_ids)
    )

    :ok
  end

  defp do_bulk_destroy(runs) do
    case Ash.bulk_destroy(runs, :destroy, %{}, return_errors?: true) do
      %Ash.BulkResult{status: :success, records: records} ->
        {:ok, length(records || runs)}

      %Ash.BulkResult{status: status, error_count: errors}
      when status in [:partial_success, :error] ->
        require Logger
        Logger.warning("[TraceRun] retention destroy partial: status=#{status} errors=#{errors}")
        {:ok, max(length(runs) - errors, 0)}
    end
  end
```

Notes:
- `:destroy` is the Ash default destroy action — TraceRun currently only `defaults([:read])`, so **add
  `:destroy` to the defaults**: `defaults([:read, :destroy])`. (RequestCorrelation used a named `:complete`
  destroy; trace has no special teardown, so the generated `:destroy` suffices.)
- `Repo.delete_all(from e in "trace_events", ...)` uses the table name as a schemaless source so we do not need
  an Ecto schema. `trace_id in ^trace_ids` compiles to `WHERE trace_id = ANY($1)`, served by the
  `[:tenant_id, :trace_id, :seq]` index's `trace_id` prefix (Postgres can use it for the IN). Acceptable.
- The function is tenantless => global? read returns rows across all tenants; bulk_destroy of those records
  destroys them regardless of tenant. No actor needed (no policies).

**Reach/credo:** This adds an Ecto `from`/`delete_all` inside an Ash resource module. `JidoClaw.Trace.*` is in
the `data` layer and `JidoClaw.Repo` is also `data`, so no forbidden cross-layer dep. No `bare_rescue` here (no
rescue). Should pass reach/credo as-is; if credo flags the inline `import Ecto.Query`, hoist it to a module-level
`import Ecto.Query, only: [from: 2]` near the top.

### 3. `lib/jido_claw/trace/retention_sweeper.ex` (CREATE) — the GenServer

Mirror `lib/jido_claw/conversations/request_correlation/sweeper.ex` exactly, swapping the cadence, the config
read, and the disabled-no-op path:

```elixir
defmodule JidoClaw.Trace.RetentionSweeper do
  @moduledoc """
  Periodic worker that prunes durable `trace_runs` (and their
  `trace_events`) older than the configured retention window.

  Runs `TraceRun.sweep_expired/1` every hour with a cutoff of
  `now - retention_days`. The read is bounded to 1_000 runs per tick
  (see `TraceRun.sweep_expired/1`); a full batch reschedules immediately
  to drain the backlog rather than waiting for the next tick.

  Retention is configured via `config :jido_claw, :trace, retention_days: N`.
  `nil`, `0`, or `:infinity` disables the sweep (the tick is a no-op).

  ## Why a separate GenServer

  Same rationale as `RequestCorrelation.Sweeper`: bulk Postgres maintenance
  that may take seconds must not block the hot trace write path
  (`Trace.Persistence`) or the in-memory ring (`Trace.Collector`).
  """

  use GenServer
  require Logger

  alias JidoClaw.Trace.Resources.TraceRun

  @tick_ms 3_600_000
  @full_batch 1_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(_opts) do
    schedule_next()
    {:ok, %{}}
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    case sweep() do
      {:ok, count} when count >= @full_batch ->
        send(self(), :sweep)

      _ ->
        schedule_next()
    end

    {:noreply, state}
  end

  @impl GenServer
  def handle_info(_other, state), do: {:noreply, state}

  defp sweep do
    case retention_cutoff() do
      nil ->
        {:ok, 0}

      %DateTime{} = cutoff ->
        TraceRun.sweep_expired(cutoff)
    end
    # Background sweeper — any failure must reschedule cleanly so the next
    # tick can drain. Crashing here would stall trace retention entirely.
  rescue
    # reach:disable-next-line bare_rescue
    e ->
      Logger.warning("[Trace.RetentionSweeper] sweep raised: #{Exception.message(e)}")
      {:ok, 0}
  catch
    kind, payload ->
      Logger.warning("[Trace.RetentionSweeper] sweep #{kind}: #{inspect(payload)}")
      {:ok, 0}
  end

  # nil / 0 / :infinity disable; otherwise now - retention_days.
  defp retention_cutoff do
    case Keyword.get(Application.get_env(:jido_claw, :trace, []), :retention_days, 30) do
      days when is_integer(days) and days > 0 ->
        DateTime.add(DateTime.utc_now(), -days * 86_400, :second)

      _ ->
        nil
    end
  end

  defp schedule_next do
    Process.send_after(self(), :sweep, @tick_ms)
  end
end
```

This mirrors the precedent's rescue+catch guard (with the `reach:disable-next-line bare_rescue` annotation),
`Process.send_after` re-arm, and full-batch drain.

### 4. `lib/jido_claw/application.ex` (MODIFY) — supervise the sweeper

In `core_children/0`'s `infra_children` list (lines 136-169), add `JidoClaw.Trace.RetentionSweeper` after
`JidoClaw.Trace.Collector`:

```elixir
      JidoClaw.Trace.Persistence,
      JidoClaw.Trace.Collector,
      JidoClaw.Trace.RetentionSweeper,
      JidoClaw.Conversations.Recorder,
```

No ordering constraint beyond "after Repo" (which is in `core_children` far earlier). Placing it adjacent to
the other trace children is for locality only.

### 5. Migration (GENERATE — not hand-written)

After steps 2(a) (the `index([:updated_at])`) lands, run:

```
mix ash.codegen add_trace_run_updated_at_index
```

This regenerates `priv/resource_snapshots/repo/trace_runs/<ts>.json` and emits
`priv/repo/migrations/<ts>_add_trace_run_updated_at_index.exs` creating
`index(:trace_runs, [:updated_at])`. The `:expired` read action and `:destroy` default are NOT schema changes,
so they produce no migration. `mix test` runs `ash.setup --quiet`, auto-applying the migration. **This is the
only generated file; do not hand-edit the migration.**

> NOTE: `mix ash.codegen` is a generation command and is NOT run during this read-only planning phase — it is an
> implementation step.

### 6. `test/jido_claw/trace/retention_sweeper_test.exs` (CREATE) — tests

Model on `persistence_test.exs` (shared sandbox, `async: false`, trace-config put_env). Test the **sweep function
directly** (`TraceRun.sweep_expired/1`) for the data-layer behavior, plus one tick-path test through the GenServer.

Setup block (copy from persistence_test.exs:9-27): shared SQL sandbox owner with on_exit stop; put_env
`:jido_claw, :trace` with `persist_sync?: true` (so seed emits are synchronous) and an explicit `retention_days`,
with on_exit restore.

Helper to seed a persisted run+events at a chosen age — two options:
- **Preferred:** seed via the real path (telemetry emit + `H.sync_collector()` + `H.sync_persistence()`), then
  backdate with raw SQL:
  `Repo.query!("UPDATE trace_runs SET updated_at = $2, inserted_at = $2 WHERE trace_id = $1", [trace_id, old_dt])`.
- Or seed directly via `TraceRun.upsert_run/2` + `TraceEvent.append_event/2` (as persistence_test.exs:66-91
  does), then backdate `updated_at` via raw SQL. Direct seeding is simpler and avoids collector coupling — use
  this for the unit tests.

Backdating is required because `update_timestamp` stamps `now()` on create; the resource has no accept for
`updated_at`. Raw `Repo.query!` UPDATE is the established technique (memory/retrieval_test.exs, persistence_test.exs:97).

Test list:
1. **expired runs + their events deleted** — seed a run with N events, backdate `updated_at` to `now - 60d`,
   `assert {:ok, 1} = TraceRun.sweep_expired(now - 30d_cutoff)`; assert `TraceRun.by_trace_id(tid)` => not found
   AND `TraceEvent.for_trace(tid)` => `{:ok, []}`.
2. **fresh rows survive** — seed a run with a current `updated_at`; sweep with `now - 30d` cutoff;
   `assert {:ok, 0}`; row + events still present.
3. **active long-lived trace protected** — seed a run with `inserted_at = now - 60d` but `updated_at = now`
   (simulating a still-active long-lived trace); sweep with `now - 30d`; assert it SURVIVES (this is the whole
   point of keying on `updated_at` not `inserted_at`). Backdate only `inserted_at`, leave `updated_at` fresh.
4. **batch drain** — seed `@full_batch + a few` (or lower `@full_batch` is not configurable, so use a smaller
   targeted assertion: seed e.g. 3 expired runs, assert the count returned equals the number actually destroyed;
   full 1_000-row drain via the immediate re-send is exercised by the tick-path test below with a temporarily
   small dataset). Keep this practical — a `count >= @full_batch` unit assertion would need 1_000 rows; instead
   assert the function returns the exact deleted count for a small expired set and trust the re-send branch
   (covered by reading the handle_info). If a true drain test is wanted, add a tick-path test (below) that seeds
   a handful and asserts eventual zero rows.
5. **disabled retention is a no-op** — put_env `retention_days: nil` (and separately `0`); the *sweeper's*
   `retention_cutoff` returns nil so a tick deletes nothing. Test by seeding an ancient row, sending `:sweep` to
   the running `RetentionSweeper` (or calling a thin private-equivalent), and asserting the row survives. Since
   `retention_cutoff` is private, prefer testing this at the sweeper level: `Application.put_env(... retention_days: nil)`,
   seed an expired row, `send(Process.whereis(JidoClaw.Trace.RetentionSweeper), :sweep)`, then a
   `H.sync`-style barrier or short `assert_eventually` that the row still exists. Simpler: also assert
   `TraceRun.sweep_expired(cutoff)` with a real cutoff deletes it, proving the no-op is config-driven, not a code bug.
6. **(optional) tick-path** — with the shared sandbox, the running `RetentionSweeper` GenServer can be exercised:
   set a tiny `retention_days` so seeded rows are "expired", `send(pid, :sweep)`, and poll (`assert_eventually`)
   until `TraceRun.by_trace_id` returns not-found. The shared sandbox (`shared: true`) lets the sweeper process
   see the test's seeded rows. Keep this to one test; the synchronous `sweep_expired/1` tests carry the bulk of
   coverage.

For the tick-path / sweeper-process tests, the global `RetentionSweeper` started by the application is available
(infra_children). Because it ticks hourly, it will not interfere with a synchronous test in the window; the test
drives it explicitly via `send(pid, :sweep)`. (Mirror how persistence_test.exs reaches into the live
`Trace.Collector`/`Trace.Persistence` singletons.)

---

## Sequencing

1. config knob (config.exs).
2. TraceRun: add `index([:updated_at])`, `:expired` read action + code_interface, `:destroy` default,
   `sweep_expired/1` + private helpers.
3. `mix ash.codegen add_trace_run_updated_at_index` (generates snapshot + migration).
4. RetentionSweeper module.
5. application.ex wiring.
6. Tests.
7. `mix precommit` — compile_check, system_prompt.check, deps.unlock --unused, format, reach.check --arch
   --smells --strict, credo --strict, dialyzer --format short, full test suite (which runs ash.setup --quiet to
   apply the new migration).

## Risks / watch-items

- **dialyzer:** `Ash.bulk_destroy/4` return is `%Ash.BulkResult{}`; match the `:success | :partial_success | :error`
  statuses exactly as RequestCorrelation does to avoid a "pattern can never match" warning. The `Repo.delete_all`
  on a schemaless `"trace_events"` source returns `{count, nil}` — ignore the return (we recount via the run set).
- **reach `fixed_shape_map`:** the small attrs maps here (`%{cutoff: cutoff}`, `%{}`) are unlikely to trip the
  cross-file shape smell, but if reach flags the resource, scope it the same way the config already scopes Ash-attrs
  modules (it does NOT currently list TraceRun; only add if reach complains).
- **credo `--strict`:** keep `import Ecto.Query, only: [from: 2]` at module level (not inline) if credo's
  `Credo.Check.Consistency` or alias-ordering rules object. Add `require Logger` at the top of TraceRun (it has none
  today) rather than inline `require Logger` in each helper.
- **Decision to confirm with user (below):** orphan-event sweeping (drive deletion off expired *runs* only — minimal
  — vs. also `DELETE FROM trace_events WHERE inserted_at < cutoff` which would need a second `[:inserted_at]` index on
  trace_events). Recommended: minimal/runs-only for M7.

## Open question for the user

- **retention_days default:** 30 (chosen) vs 7. 30 is the safer default for a debugging/replay store that feeds
  AgentView, the certificate verifier, and inspection tools; 7 reclaims disk faster. Flagging since the finding said
  "something like 7 or 30."
- **Orphan events:** confirm runs-only sweeping is acceptable (it is, given Persistence writes the run first), or
  request the extra trace_events `inserted_at` index + sweep.

---

## Critical Files for Implementation

- /Users/rickdunkin/workspace/claws/jido_radclaw/lib/jido_claw/trace/resources/trace_run.ex
- /Users/rickdunkin/workspace/claws/jido_radclaw/lib/jido_claw/trace/retention_sweeper.ex  (new)
- /Users/rickdunkin/workspace/claws/jido_radclaw/lib/jido_claw/application.ex
- /Users/rickdunkin/workspace/claws/jido_radclaw/config/config.exs
- /Users/rickdunkin/workspace/claws/jido_radclaw/test/jido_claw/trace/retention_sweeper_test.exs  (new)
