# Plan: T1-1 — Unified Runtime Trace Surface (`JidoClaw.Trace`)

## Context

`docs/exploration/jidoka/FEATURES-WORTH-BORROWING.md` Tier 1 item #1 calls for a unified per-request trace projection that all surfaces (LiveViews, CLI REPL, MCP server, certificate verifier) can consume. Today jido_radclaw emits the raw events but they live in four uncoordinated sinks:

1. `lib/jido_claw/conversations/recorder.ex` — Postgres `Message` rows from SignalBus `ai.*` topics.
2. `lib/jido_claw/agent_tracker.ex` — per-agent counters from `[:jido, :ai, :tool, :execute, *]` telemetry + `jido_claw.{tool,agent}.*` signals.
3. `lib/jido_claw/reasoning/telemetry.ex` — `Reasoning.Outcome` rows from `[:jido_claw, :reasoning, :strategy, :start|:stop]`.
4. `lib/jido_claw/conversations/request_correlation/cache.ex` — per-request ETS scope (`tenant_id, session_id, run_id, model, tokens, latency`).

None of these answers "give me the ordered event timeline for request `R`". This plan lifts Jidoka's `Trace` + `Trace.Event` + `Trace.Collector` shape into jido_radclaw, adapted for: (a) Ash multitenancy via `tenant_id`, (b) optional Postgres persistence for cross-restart replay, and (c) jido_radclaw's existing reasoning telemetry — converted to the canonical 3-segment `[:jido_claw, :reasoning, :event]` shape so there's a single source of truth.

T1-1 is the keystone for T2-1 (Handoff), T2-2 (AgentView), and T2-4 (Inspection). Per the doc: do **not** subsume `Reasoning.Outcome` or `Conversations.Message` — they remain durable record-of-truth; the Trace is the in-flight view that links them via `request_id`.

User scope decisions (confirmed):
- **In-memory ring + Ash persistence** for durable replay.
- **Tap + Reasoning.Telemetry as the demonstration emitter.**
- **Single canonical reasoning event path** (replaces the existing 4-segment `:telemetry.execute` with `Trace.emit/3`; no double-capture).

Reviewer corrections incorporated:
- Strict tenant filtering (cache → durable fallback; refuse leakage on nil-tenant).
- Default-off `[:jido, :ai, :llm, :delta]` capture (streaming would flood the ring/DB).
- Serialized persistence through a dedicated GenServer with `last_seq` ordering guard.
- Ash domain registration + `code_interface` + `mix ash.codegen` (no hand-written migrations).
- `Jido.Observe.emit_event/3` for trace-context merging (not raw `:telemetry.execute/3`).
- Strings (not open `:atom`) for persisted `source`/`category`/`event`/`phase`/`status` columns.
- Single canonical reasoning event path (no special-case `event_shape/2` clause).
- `params` added to sanitization large-keys set (Jido tool execution telemetry).

## File layout

New code:
```
lib/jido_claw/trace.ex                                  # public API
lib/jido_claw/trace/event.ex                            # %Event{} struct
lib/jido_claw/trace/collector.ex                        # supervised GenServer (ingest)
lib/jido_claw/trace/sanitize.ex                         # port of Jidoka.Sanitize + `params`
lib/jido_claw/trace/persistence.ex                      # serialized async Postgres writer
lib/jido_claw/trace/domain.ex                           # Ash.Domain
lib/jido_claw/trace/resources/trace_run.ex              # Ash resource
lib/jido_claw/trace/resources/trace_event.ex            # Ash resource
test/support/jido_claw/trace_test_helpers.ex            # emit + sync helpers
test/jido_claw/trace_test.exs                           # public API tests
test/jido_claw/trace/collector_test.exs                 # collector internals
test/jido_claw/trace/sanitize_test.exs                  # redaction/omission
test/jido_claw/trace/persistence_test.exs               # Ash round-trip + ordering
```

Migrations are generated via `mix ash.codegen <slug>` (writes to `priv/repo/migrations/` and `priv/resource_snapshots/`). No hand-written migrations.

Modifications:
```
lib/jido_claw/application.ex                            # supervisor wire-up (Collector + Persistence)
lib/jido_claw/reasoning/telemetry.ex                    # replace 4-segment :telemetry.execute with Trace.emit
lib/jido_claw/tools/reason.ex                           # thread request_id + agent_id into telemetry opts
lib/jido_claw/tools/run_pipeline.ex                     # same
lib/jido_claw/tools/verify_certificate.ex               # same
config/config.exs (and config/test.exs)                 # `:jido_claw, :trace, [...]` defaults
```

## Public API surface

### `JidoClaw.Trace`

```elixir
@agent_id_key :__jido_claw_agent_id__

@type t :: %__MODULE__{
        trace_id:        String.t() | nil,
        run_id:          String.t() | nil,
        request_id:      String.t() | nil,
        agent_id:        term(),
        tenant_id:       String.t() | nil,
        status:          atom() | nil,
        started_at_ms:   integer() | nil,
        completed_at_ms: integer() | nil,
        events:          [JidoClaw.Trace.Event.t()],
        summary:         map()
      }

defstruct [:trace_id, :run_id, :request_id, :agent_id, :tenant_id,
           :status, :started_at_ms, :completed_at_ms,
           events: [], summary: %{}]

@type target ::
        pid()
        | String.t()                       # agent_id
        | Jido.Agent.t()
        | {:request, String.t()}
        | {:tenant, String.t()}

@spec agent_id_key() :: atom()

# IMPORTANT: argument order matches Jidoka — metadata is the SECOND positional arg.
# Mixing this up with Jido.Observe.emit_event/3 (which is measurements-first) is a
# silent footgun: caller-supplied :event/:phase/:name/:request_id/:agent_id keys
# would land in measurements instead of metadata, and event_shape/2 would normalize
# every emit to %Event{event: :event}.
@spec emit(atom(), map()) :: :ok
@spec emit(atom(), map(), map()) :: :ok
def emit(category, metadata, measurements \\ %{}) do
  metadata =
    metadata
    |> Map.put_new(:category, category)
    |> Map.put_new(:source, :jido_claw)

  Jido.Observe.emit_event([:jido_claw, category, :event], measurements, metadata)
end

@spec latest(target(), keyword()) :: {:ok, t()} | {:error, term()}
@spec for_request(target(), String.t(), keyword()) :: {:ok, t()} | {:error, term()}
@spec list(target(), keyword()) :: {:ok, [t()]} | {:error, term()}
@spec events(t() | target(), keyword()) :: {:ok, [Event.t()]} | {:error, term()}
@spec spans(t() | target(), keyword()) :: {:ok, [map()]} | {:error, term()}
@spec history(keyword()) :: {:ok, [t()]} | {:error, term()}            # Postgres-only paginated read
```

**`tenant_id:` semantics** (strict, reviewer-corrected):

- When `tenant_id:` is supplied, the candidate set is filtered to that tenant **before** picking `latest` / `for_request`. `latest("main", tenant_id: "B")` returns the latest trace for `agent_id == "main"` AND `tenant_id == "B"` — never falls through to a tenant-A trace.
- A trace whose `tenant_id` is `nil` (Cache + durable both empty at ingest, see Tenant Scoping) is excluded from tenant-scoped queries. Untyped queries (`tenant_id:` omitted) include all traces.
- Tenant mismatch returns `{:error, :not_found}` (avoids leaking existence across tenants).

**`target_ref/1` clauses** — extend Jidoka's resolver to handle the new target types:

```elixir
defp target_ref({:request, request_id}) when is_binary(request_id),
  do: %{request_id: request_id}

defp target_ref({:tenant, tenant_id}) when is_binary(tenant_id),
  do: %{tenant_id: tenant_id}

defp target_ref(%Jido.Agent{id: agent_id, state: state}),
  do: %{agent_id: agent_id, request_id: Map.get(state || %{}, :last_request_id)}

defp target_ref(target) when is_pid(target) or is_binary(target) do
  # ... Jidoka's original pid/string handling
end
```

Jidoka's original `target_ref/1` only handles `pid`, `%Jido.Agent{}`, and binary; the `{:request, _}` and `{:tenant, _}` clauses are new in this port and must land before the generic clauses. Test 7 (`for_request/3` with nil `agent_id`) and test 12 (`list({:tenant, tid})`) exercise these paths.

`Trace.emit/3` wraps `Jido.Observe.emit_event/3` (`deps/jido/lib/jido/observe.ex:282`). Note the deliberate argument-order swap: Jidoka's emit is `emit(category, metadata, measurements)`; `Jido.Observe.emit_event/3` is `(event_prefix, measurements, metadata)`. The wrapper translates between the two and stamps `:category` + `:source` into metadata. `Jido.Observe.emit_event/3` itself merges `Jido.Tracing.Context` metadata (`jido_trace_id`, `jido_span_id`, `jido_parent_span_id`) so Trace-native events get the same correlation IDs as `[:jido, :ai, *]` events automatically.

### `JidoClaw.Trace.Event`

Verbatim shape lift from Jidoka (`/Users/rickdunkin/workspace/claws/jidoka/lib/jidoka/trace/event.ex`) with `:source` atom values changed from `:jidoka` to `:jido_claw`. Enforced keys `[:seq, :at_ms, :source, :category, :event, :measurements, :metadata]`; full field set: `seq, at_ms, source, category, event, phase, name, status, duration_ms, request_id, run_id, trace_id, span_id, parent_span_id, measurements, metadata`. In-memory representation keeps atoms for source/category/event/phase/status (cheap to match on); persistence converts to strings at the boundary.

**`trace_id` fallback** — Jidoka's `"trace_unattributed_#{seq}"` fallback is unsafe across restarts when `trace_id` is globally unique in Postgres (seq resets on Collector restart → collision). Replace with `Ash.UUID.generate/0` in `Collector.normalize_event/4`:

```elixir
trace_id =
  string_value(metadata, :jido_trace_id)
  || string_value(metadata, :trace_id)
  || run_id
  || request_id
  || Ash.UUID.generate()                # was: "trace_unattributed_#{seq}"
```

UUIDs are collision-free across restarts; correlation by `request_id`/`run_id` still works for the common case where one is present.

### `JidoClaw.Trace.Collector` (internal)

Singleton GenServer named `JidoClaw.Trace.Collector`. State:

```elixir
defstruct enabled?: true,
          max_traces: 100,
          max_events_per_trace: 300,
          seq: 0,
          traces: %{},
          order: [],                    # LRU
          by_agent: %{},
          by_request: %{},
          by_run: %{},
          by_trace: %{},
          by_tenant: %{}                # tenant_id -> [trace_key]
```

Config read once at init from `Application.get_env(:jido_claw, :trace, [])`:
- `enabled?` (default true)
- `max_traces` (default 100)
- `max_events_per_trace` (default 300)
- `persist?` (default true; persistence is delegated to `Trace.Persistence`)

LLM delta events (`[:jido, :ai, :llm, :delta]`) are deliberately **not** attached in v1 — see "Delta handling" below. No config knob until a coalescing implementation exists, so we don't ship a half-feature.

### `JidoClaw.Trace.Persistence` (internal)

Singleton GenServer that serializes Postgres writes. Collector posts via `GenServer.cast(JidoClaw.Trace.Persistence, {:append, event, trace_snapshot})`. FIFO mailbox ordering guarantees that earlier-seq writes for the same `trace_id` complete before later ones. `last_seq` column on `trace_runs` is a defensive cap against any future parallelization.

```elixir
@spec append(JidoClaw.Trace.Event.t(), JidoClaw.Trace.t()) :: :ok
def append(event, trace), do: GenServer.cast(__MODULE__, {:append, event, trace})

# In handle_cast — explicit case (no silent error swallowing):
defp do_persist(event, trace) do
  case TraceRun.upsert_run(run_attrs(trace), tenant: trace.tenant_id) do
    {:ok, _} ->
      case TraceEvent.append_event(event_attrs(event, trace), tenant: trace.tenant_id) do
        {:ok, _} -> :ok
        {:error, reason} -> Logger.warning("[Trace] event append failed: #{inspect(reason)}")
      end

    {:error, reason} ->
      Logger.warning("[Trace] run upsert failed: #{inspect(reason)}")
  end
rescue
  e -> Logger.warning("[Trace] persistence raised: #{Exception.message(e)}")
end
```

Synchronous persist path (for tests) via `Application.put_env(:jido_claw, :trace, persist_sync?: true)` — the GenServer call becomes `GenServer.call/2`, which blocks the caller until the write commits.

## Telemetry attach list

Single handler id `"jido-claw-trace-collector"` via `:telemetry.attach_many/4`.

```elixir
@base_jido_ai_events [
  [:jido, :ai, :request, :start],
  [:jido, :ai, :request, :complete],
  [:jido, :ai, :request, :failed],
  [:jido, :ai, :request, :rejected],
  [:jido, :ai, :request, :cancelled],
  [:jido, :ai, :llm, :start],
  [:jido, :ai, :llm, :complete],
  [:jido, :ai, :llm, :error],
  [:jido, :ai, :tool, :start],
  [:jido, :ai, :tool, :retry],
  [:jido, :ai, :tool, :complete],
  [:jido, :ai, :tool, :error],
  [:jido, :ai, :tool, :timeout],
  [:jido, :ai, :tool, :execute, :start],
  [:jido, :ai, :tool, :execute, :stop],
  [:jido, :ai, :tool, :execute, :exception]
]

@jido_claw_events [
  [:jido_claw, :hook, :event],
  [:jido_claw, :guardrail, :event],
  [:jido_claw, :memory, :event],
  [:jido_claw, :workflow, :event],
  [:jido_claw, :subagent, :event],
  [:jido_claw, :handoff, :event],
  [:jido_claw, :mcp, :event],
  [:jido_claw, :output, :event],
  [:jido_claw, :schedule, :event],
  [:jido_claw, :compaction, :event],
  [:jido_claw, :reasoning, :event]      # canonical reasoning shape (Trace.emit produces this)
]

# Final attach list: @base_jido_ai_events ++ @jido_claw_events
```

`event_shape/2` clauses (no reasoning special-case — `Reasoning.Telemetry` emits the canonical 3-segment shape directly):

```elixir
defp event_shape([:jido, :ai, :request, event], _m), do: {:ok, :jido_ai, :request, event}
defp event_shape([:jido, :ai, :llm, event], _m), do: {:ok, :jido_ai, :model, event}      # :llm → :model rename
defp event_shape([:jido, :ai, :tool, event], _m) when event != :execute,
  do: {:ok, :jido_ai, :tool, event}
defp event_shape([:jido, :ai, :tool, :execute, event], _m),
  do: {:ok, :jido_ai, :tool, event}                                                       # collapse executor
defp event_shape([:jido_claw, category, :event], m) when is_atom(category),
  do: {:ok, :jido_claw, category, atom_value(m, :event) || :event}
defp event_shape(_, _), do: :error
```

### Delta handling

`[:jido, :ai, :llm, :delta]` is emitted in a streaming loop by ReAct (`deps/jido_ai/lib/jido_ai/reasoning/react/strategy.ex:2357`). A single LLM call can fire 100s of deltas. **v1 does not attach delta events at all.** The bounded ring (300 events/trace) and Postgres event log would otherwise be flooded with low-value events, evicting `:request, :start` and `:tool, :complete` (FIFO eviction prefers the oldest, which during streaming would be the high-value lifecycle events that arrived first).

When delta visibility is needed in a future iteration, the right design is to coalesce — maintain `delta_count` and `last_delta_preview` on the parent `:model` span (keyed by `llm_call_id`), not append per-delta `%Event{}` rows to the trace. v1 does **not** ship a config flag that turns deltas on without coalescing; that would reintroduce the flood risk. The flag goes in when coalescing goes in.

Document this gap in `Trace.Collector` moduledoc.

Handler ids confirmed non-conflicting with existing attachers (`{JidoClaw.Conversations.Recorder, :latency}`, `"agent-tracker-tool-start"`, `"agent-tracker-tool-stop"`). Telemetry is multi-listener.

## Tenant scoping (strict)

At first-event ingest, resolve `tenant_id` using the cache-then-durable pattern that Recorder/Audit already use (`lib/jido_claw/conversations/recorder.ex:750` is the precedent — `resolve_scope/1`):

```elixir
defp resolve_tenant(request_id) when is_binary(request_id) do
  case JidoClaw.Conversations.RequestCorrelation.Cache.lookup(request_id) do
    {:ok, %{tenant_id: tid}} when is_binary(tid) ->
      tid

    _ ->
      case JidoClaw.Conversations.RequestCorrelation.lookup(request_id) do
        {:ok, %{tenant_id: tid}} when is_binary(tid) -> tid
        _ -> nil
      end
  end
end

defp resolve_tenant(_), do: nil
```

`tenant_id` is stamped on the trace (invariant per trace). Backfill on subsequent events if first resolution missed: `trace.tenant_id || resolve_tenant(event.request_id)`.

### Query-time tenant filter (strict)

```elixir
def latest(target, opts) do
  tenant_id = Keyword.get(opts, :tenant_id)

  candidates =
    case target_ref(target) do
      %{agent_id: aid} -> traces_for_agent(state, aid)
      _ -> all_traces(state)
    end
    |> filter_by_tenant(tenant_id)

  case List.last(candidates) do
    nil -> {:error, :not_found}
    trace -> {:ok, wrap(trace)}
  end
end

defp filter_by_tenant(traces, nil), do: traces
defp filter_by_tenant(traces, tenant_id),
  do: Enum.filter(traces, &(&1.tenant_id == tenant_id))
```

`{:error, :not_found}` is returned for both "no trace exists" and "tenant mismatch" — same shape avoids leaking trace existence across tenants.

`for_request/3` similarly filters: load the trace by `request_id`; if `tenant_id:` supplied and `trace.tenant_id != tenant_id`, return `{:error, :not_found}`.

## Sanitization

Lift `Jidoka.Sanitize.payload/1` as `JidoClaw.Trace.Sanitize`. Key sets — Jidoka's lists **plus `params`**:

- Large keys → `"[OMITTED]"`: `arguments`, `context`, `data`, `llm_opts`, `messages`, `params` (**new**), `prompt`, `query`, `raw`, `raw_request`, `raw_response`, `request`, `request_opts`, `response`, `result`, `stacktrace`, `state`.
- Sensitive keys → `"[REDACTED]"`: exact `api_key`, `apikey`, `password`, `secret`, `token`, `auth_token`, `private_key`, `access_key`, `bearer`, `api_secret`, `client_secret`; suffix `_secret`, `_key`, `_token`, `_password`; contains `secret_`.

Rationale for `params`: Jido tool execution telemetry includes `:params` at `deps/jido_ai/lib/jido_ai/turn.ex:621`. Without omission, tool-call payloads (potentially containing user input or PII) would land in `trace_events.metadata`.

Applied to both `measurements` and `metadata` at ingest. Recursive descent on maps/lists; PIDs/funs become `inspect/1`.

## Ash persistence

### `JidoClaw.Trace.Domain`

```elixir
defmodule JidoClaw.Trace.Domain do
  use Ash.Domain, otp_app: :jido_claw

  resources do
    resource JidoClaw.Trace.Resources.TraceRun
    resource JidoClaw.Trace.Resources.TraceEvent
  end
end
```

Add the domain to `config/config.exs` under `config :jido_claw, ash_domains: [...]`.

### `JidoClaw.Trace.Resources.TraceRun`

```elixir
defmodule JidoClaw.Trace.Resources.TraceRun do
  use Ash.Resource,
    otp_app: :jido_claw,
    domain: JidoClaw.Trace.Domain,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "trace_runs"
    repo JidoClaw.Repo
  end

  multitenancy do
    strategy :attribute
    attribute :tenant_id
    global? true
  end

  attributes do
    uuid_primary_key :id
    attribute :trace_id, :string, allow_nil?: false, public?: true
    attribute :tenant_id, :string, public?: true
    attribute :request_id, :string, public?: true
    attribute :run_id, :string, public?: true
    attribute :agent_id, :string, public?: true
    attribute :status, :string, public?: true            # string: "running"|"completed"|"failed"|...
    attribute :started_at_ms, :integer, public?: true
    attribute :completed_at_ms, :integer, public?: true
    attribute :summary, :map, default: %{}, public?: true
    attribute :last_seq, :integer, default: 0, allow_nil?: false, public?: true   # ordering guard (NOT NULL so upsert_condition comparison is safe)
    timestamps()
  end

  identities do
    # Trace IDs are globally unique by construction. all_tenants? avoids
    # ambiguity in by_trace_id / has_many lookups when relationship loading
    # crosses tenant scope.
    identity :unique_trace_id, [:trace_id], all_tenants?: true
  end

  custom_indexes do
    index :request_id, where: "request_id IS NOT NULL"
    index :run_id, where: "run_id IS NOT NULL"
    index :agent_id, where: "agent_id IS NOT NULL"
    index [:tenant_id, :inserted_at]
  end

  actions do
    defaults [:read]

    create :upsert_run do
      accept [:trace_id, :tenant_id, :request_id, :run_id, :agent_id, :status,
              :started_at_ms, :completed_at_ms, :summary]
      argument :incoming_last_seq, :integer, allow_nil?: false

      change set_attribute(:last_seq, arg(:incoming_last_seq))

      upsert? true
      upsert_identity :unique_trace_id
      # Only overwrite when the incoming snapshot is newer than the persisted
      # one. Older snapshots become a `:skipped_upsert` no-op (not an error).
      upsert_condition expr(^arg(:incoming_last_seq) > last_seq)
      upsert_fields [
        :status, :request_id, :run_id, :agent_id,
        :started_at_ms, :completed_at_ms, :summary, :last_seq
      ]
      # `:updated_at` is intentionally omitted — AshPostgres update_timestamp
      # machinery handles it. Mirror the pattern used by existing resources
      # (`Conversations.RequestCorrelation`, `Reasoning.Outcome`).
      return_skipped_upsert? true
    end

    read :by_trace_id do
      get? true
      argument :trace_id, :string, allow_nil?: false
      filter expr(trace_id == ^arg(:trace_id))
    end

    read :by_request do
      get? true
      argument :request_id, :string, allow_nil?: false
      filter expr(request_id == ^arg(:request_id))
    end

    read :recent do
      pagination keyset?: true, default_limit: 50, required?: false
      prepare build(sort: [inserted_at: :desc])
    end
  end

  relationships do
    has_many :events, JidoClaw.Trace.Resources.TraceEvent,
      destination_attribute: :trace_id, source_attribute: :trace_id
  end

  code_interface do
    # No-args defines on creates so callers pass a params map:
    #   TraceRun.upsert_run(%{trace_id: ..., incoming_last_seq: ...}, tenant: t)
    define :upsert_run
    define :by_trace_id, args: [:trace_id]
    define :by_request, args: [:request_id]
    define :recent
  end
end
```

`code_interface` generates:
- `TraceRun.upsert_run(params_map, opts)` — caller passes `%{trace_id: _, incoming_last_seq: _, ...}` and `tenant: tid`.
- `TraceRun.by_trace_id("trace_id", opts)`, `TraceRun.by_request("req_id", opts)` (positional).
- `TraceRun.recent(opts)` — pagination via `page: [limit: 25]` keyword.

### `JidoClaw.Trace.Resources.TraceEvent`

```elixir
defmodule JidoClaw.Trace.Resources.TraceEvent do
  use Ash.Resource,
    otp_app: :jido_claw,
    domain: JidoClaw.Trace.Domain,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "trace_events"
    repo JidoClaw.Repo
  end

  multitenancy do
    strategy :attribute
    attribute :tenant_id
    global? true
  end

  attributes do
    uuid_primary_key :id
    attribute :tenant_id, :string, public?: true
    attribute :trace_id, :string, allow_nil?: false, public?: true
    attribute :seq, :integer, allow_nil?: false, public?: true
    attribute :at_ms, :integer, allow_nil?: false, public?: true
    attribute :source, :string, allow_nil?: false, public?: true     # "jido_ai" | "jido_claw"
    attribute :category, :string, allow_nil?: false, public?: true   # "request" | "model" | "tool" | ...
    attribute :event, :string, allow_nil?: false, public?: true
    attribute :phase, :string, public?: true
    attribute :name, :string, public?: true
    attribute :status, :string, public?: true
    attribute :duration_ms, :integer, public?: true
    attribute :request_id, :string, public?: true
    attribute :run_id, :string, public?: true
    attribute :span_id, :string, public?: true
    attribute :parent_span_id, :string, public?: true
    attribute :measurements, :map, default: %{}, public?: true
    attribute :metadata, :map, default: %{}, public?: true
    create_timestamp :inserted_at
  end

  identities do
    # Same global-uniqueness reasoning as TraceRun's unique_trace_id.
    identity :unique_trace_seq, [:trace_id, :seq], all_tenants?: true
  end

  custom_indexes do
    index [:trace_id, :seq]
    index :request_id, where: "request_id IS NOT NULL"
    index :run_id, where: "run_id IS NOT NULL"
  end

  actions do
    defaults [:read]

    create :append_event do
      accept [:tenant_id, :trace_id, :seq, :at_ms, :source, :category, :event,
              :phase, :name, :status, :duration_ms, :request_id, :run_id,
              :span_id, :parent_span_id, :measurements, :metadata]
      upsert? true                                    # idempotent re-emit
      upsert_identity :unique_trace_seq
      upsert_fields []                                # events are immutable; no-op on duplicate
      return_skipped_upsert? true
    end

    read :for_trace do
      argument :trace_id, :string, allow_nil?: false
      filter expr(trace_id == ^arg(:trace_id))
      prepare build(sort: [seq: :asc])
    end
  end

  code_interface do
    # No-args define on append_event so caller passes a params map:
    #   TraceEvent.append_event(%{trace_id: _, seq: _, ...}, tenant: t)
    define :append_event
    define :for_trace, args: [:trace_id]
  end
end
```

Source/category/event/phase/status are **strings** (not constrained atoms or open `:atom`) so future trace categories don't require a migration. The in-memory `%JidoClaw.Trace.Event{}` keeps atoms; conversion happens at the persistence boundary via `Atom.to_string/1`.

### Migrations via `mix ash.codegen`

After the resources land:

```
mix ash.codegen add_trace_domain
```

This generates the migration in `priv/repo/migrations/` and the snapshot in `priv/resource_snapshots/` (matching the pattern used by `RequestCorrelation`, `Outcome`, etc.). Do **not** hand-write the migrations.

### Read path

- `Trace.latest/2`, `Trace.list/2` — in-memory only (fast, matches Jidoka).
- `Trace.for_request/3` — in-memory first; if `:not_found`, fall back to Postgres via `TraceRun.by_request/1` + `TraceEvent.for_trace/1` and rehydrate into a `%Trace{}`.
- `Trace.history/1` — Postgres-only via `TraceRun.recent/0` with `page: [limit: n]` keyword.

## Wire-up changes

### `lib/jido_claw/application.ex` (two new children)

Insert into `infra_children` (`application.ex:127-147`). **Persistence must start before Collector** — Collector attaches telemetry handlers in `init/1` and may immediately start producing events that cast to Persistence:

```elixir
infra_children = [
  # ... existing entries unchanged ...
  JidoClaw.Conversations.RequestCorrelation.Cache,
  JidoClaw.Trace.Persistence,                              # NEW — serialized DB writer (must start FIRST)
  JidoClaw.Trace.Collector,                                # NEW — telemetry ingest
  JidoClaw.Conversations.Recorder,
  JidoClaw.Conversations.RequestCorrelation.Sweeper,
  JidoClaw.Audit.SignalListener
]
```

Defensive guard: `Trace.Persistence.append/2` checks `Process.whereis(__MODULE__)` before casting; on `nil`, drops the event with a debug log. Covers the Persistence-crashed-and-restarting window.

`InfraSupervisor` is `one_for_one`: Collector or Persistence crashing doesn't restart Cache/Recorder. Persistence dying mid-cast loses the in-flight write only; the in-memory ring is unaffected.

### `lib/jido_claw/reasoning/telemetry.ex` (canonical reasoning emitter)

Replace the existing 4-segment `:telemetry.execute([:jido_claw, :reasoning, :strategy, :start|:stop], ...)` calls at lines 70 and 109 with `Trace.emit/3`. The 4-segment events are removed entirely — no other internal code attaches to them (verified by grep). This makes `Reasoning.Telemetry` the v1 demonstration emitter and gives the reasoning timeline a single canonical event path.

Use the canonical lifecycle verbs (`:start`, `:stop`, `:error`) that Jidoka's `event_status/3` already maps. The `phase: :strategy` + `name: strategy_name` carry the strategy-specific shape; the verb stays in the lifecycle vocabulary.

**Strict emission rule** — exactly one terminal event per outcome:

- `status == :ok` → emit `event: :stop` (maps to `:completed`).
- `status in [:error, :timeout]` → emit `event: :error` (maps to `:failed`).
- Never both. The current normalization at `lib/jido_claw/reasoning/telemetry.ex:79` folds the underlying call return into a single `status` atom; the emit branches on that one value.

```elixir
# At line 70 (before existing :telemetry.execute for start — remove the 4-segment call):
:ok = JidoClaw.Trace.emit(:reasoning, %{
  event: :start,
  phase: :strategy,
  name: strategy_name,
  execution_kind: execution_kind,
  task_type: task_type,
  request_id: Keyword.get(opts, :request_id),
  agent_id: Keyword.get(opts, :agent_id),
  prompt_length: byte_size(prompt)
})

# At line 109 — success path (replaces 4-segment :telemetry.execute for stop):
:ok = JidoClaw.Trace.emit(:reasoning, %{
  event: :stop,
  phase: :strategy,
  name: strategy_name,
  execution_kind: execution_kind,
  task_type: task_type,
  request_id: Keyword.get(opts, :request_id),
  agent_id: Keyword.get(opts, :agent_id)
}, %{duration_ms: duration_ms})

# Error path:
:ok = JidoClaw.Trace.emit(:reasoning, %{
  event: :error,
  phase: :strategy,
  name: strategy_name,
  execution_kind: execution_kind,
  task_type: task_type,
  status: :failed,
  request_id: Keyword.get(opts, :request_id),
  agent_id: Keyword.get(opts, :agent_id),
  reason: inspect(reason)
}, %{duration_ms: duration_ms})
```

Jidoka's `event_status/3` maps `:start → :running`, `:stop → :completed`, `:error → :failed`. The reasoning timeline picks up the right statuses without extending the status table.

Add `:request_id` and `:agent_id` to the `opts` type at `telemetry.ex:22-37`.

Document this as a behavior change in the commit message. External consumers attached to `[:jido_claw, :reasoning, :strategy, *]` (none found internally) would need to migrate to `[:jido_claw, :reasoning, :event]`.

### `lib/jido_claw/tools/{reason,run_pipeline,verify_certificate}.ex`

Update `base_telemetry_opts/2` (and equivalent in run_pipeline / verify_certificate) to extract `request_id` from `context` and `agent_id` from `tool_context`. `request_id` is **not** in the ToolContext canonical key set (`lib/jido_claw/tool_context.ex:32-42` — `[:project_dir, :tenant_id, :session_id, :session_uuid, :workspace_id, :workspace_uuid, :user_id, :agent_id, :actor]`); it lives at the top-level `context` map alongside `:tool_context`:

```elixir
defp base_telemetry_opts(context, extra) do
  tool_context = Map.get(context, :tool_context, %{}) || %{}

  [
    request_id: Map.get(context, :request_id),                # NEW: top-level
    agent_id: Map.get(tool_context, :agent_id),               # NEW: from tool_context
    workspace_uuid: Map.get(tool_context, :workspace_uuid),
    session_uuid: Map.get(tool_context, :session_uuid),
    project_dir: Map.get(tool_context, :project_dir),
    forge_session_key: Map.get(tool_context, :forge_session_key)
  ]
  |> Keyword.merge(extra)
end
```

## Test plan

`test/jido_claw/trace_test.exs` (mirrors Jidoka's `trace_test.exs`):

1. Normalizes `[:jido, :ai, :request|:llm|:tool, *]` telemetry into ordered events; asserts `:llm → :model` rename; categories `[:request, :model, :tool, :request]`.
2. Sanitizes sensitive (`api_key`) and large (`query`, `params`) metadata at ingest.
3. Derives spans grouped by `(category, llm_call_id | tool_call_id | name)`.
4. `latest/2` and `list/2` for an agent id.
5. LRU eviction at `max_traces` (105 → 100 retained, req-1 evicted).
6. FIFO eviction at `max_events_per_trace` (305 → 300, oldest dropped).
7. `for_request/3` returns trace when `agent_id` is nil.
8. `agent_id` populated lazily when a later event carries it.
9. `tenant_id` stamped from `RequestCorrelation.Cache` on first event.
10. **Strict tenant filter**: `latest(agent_id, tenant_id: "B")` returns `{:error, :not_found}` even when tenant-A traces are more recent. Verifies filter happens BEFORE `latest` selection.
11. **Durable fallback**: `tenant_id` resolves from `RequestCorrelation.lookup/1` when Cache is empty.
12. `list({:tenant, tid})` returns only that tenant's traces.
13. `enabled?: false` short-circuits ingest.
14. `Trace.emit(:hook, ...)` round-trips through `Jido.Observe.emit_event/3` with `jido_trace_id` populated.
14a. **Argument-order regression guard**: `Trace.emit(:reasoning, %{event: :start})` normalizes to `%Event{event: :start, category: :reasoning, source: :jido_claw}` — NOT `%Event{event: :event}`. Catches the metadata/measurements swap directly.
15. Status derived from terminal events (`:completed`, `:failed`, `:cancelled`, `:interrupted`).
16. Concurrent agent emits don't collide on indexes.
17. **Reasoning canonical path**: `Reasoning.Telemetry.with_outcome/4` emits `[:jido_claw, :reasoning, :event]` exactly once per start/stop (no legacy 4-segment double-fire).
18. **Deltas not attached**: emitting `[:jido, :ai, :llm, :delta]` 100 times produces zero new trace events (deltas not in the attach list in v1).

`test/jido_claw/trace/collector_test.exs`:

19. `by_tenant` index correct after LRU eviction.
20. `handle_telemetry/4` robust to nil/missing metadata fields.
21. Collector survives a crash; handler reattaches without duplicate id.

`test/jido_claw/trace/sanitize_test.exs`:

22. Redaction rules (table-driven over sensitive key set).
23. Omission rules (recursive descent, including `params`).
24. Benign payloads pass through.

`test/jido_claw/trace/persistence_test.exs`:

25. `Persistence.append/2` with `persist_sync?: true` writes `trace_runs` + `trace_events` rows.
26. **Ordering guarantee**: 100 events for one trace_id in random emit order produce `trace_events.seq` in increasing order; `trace_runs.status` reflects terminal seq (uses `upsert_condition` guard on `last_seq`).
27. **Out-of-order safety**: directly invoking `Persistence` with a `:running` snapshot bearing `last_seq: 5` AFTER a `:completed` snapshot bearing `last_seq: 7` leaves the row as `status == "completed", last_seq == 7` (no error raised — `return_skipped_upsert?: true`).
28. **Duplicate event append is idempotent**: calling `TraceEvent.append_event(%{trace_id: t, seq: s, ...})` twice returns `{:ok, _}` both times and does not mutate the first-persisted row (`upsert_fields: []`).
29. `Trace.for_request/3` Postgres fallback returns the trace after collector ring eviction.
30. `Trace.history/1` paginates `trace_runs` via `page: [limit: 25]` keyword.
31. Cross-tenant persistence isolation: tenant A's `Trace.history(tenant_id: "B")` returns empty.
32. **UUID fallback for unattributed traces**: emit an event with no `request_id`/`run_id`/`jido_trace_id`, restart the Collector, emit another with no IDs — both rows persist with distinct UUID `trace_id`s (no unique-constraint collision).

### Persistence test sandbox setup

Persistence tests must share the test process's DB connection with `JidoClaw.Trace.Persistence` (otherwise async writes happen on a different connection invisible to `Ecto.Adapters.SQL.Sandbox`). Pattern in setup:

```elixir
setup do
  :ok = Ecto.Adapters.SQL.Sandbox.checkout(JidoClaw.Repo)
  Ecto.Adapters.SQL.Sandbox.mode(JidoClaw.Repo, {:shared, self()})
  # OR explicitly allow only the Persistence GenServer:
  # persistence_pid = Process.whereis(JidoClaw.Trace.Persistence)
  # Ecto.Adapters.SQL.Sandbox.allow(JidoClaw.Repo, self(), persistence_pid)

  Application.put_env(:jido_claw, :trace, persist_sync?: true)
  on_exit(fn -> Application.delete_env(:jido_claw, :trace) end)
  :ok
end
```

`{:shared, self()}` is simplest but forces `async: false`. The `allow/3` variant scopes sandbox sharing to just the Persistence pid, but the test itself still runs `async: false` because the Collector is process-global. Follow whichever pattern the existing `recorder_test.exs` uses (per AGENTS.md, mirror established patterns).

Test harness: `test/support/jido_claw/trace_test_helpers.ex` exposes `emit_request_start/1`, `emit_tool_complete/1`, `sync_collector/0` (`GenServer.call(JidoClaw.Trace.Collector, :__sync__)`), and `sync_persistence/0` (`GenServer.call(JidoClaw.Trace.Persistence, :__sync__)`). All trace tests use `async: false`.

## Critical files to read before editing

| File | Purpose |
| --- | --- |
| `/Users/rickdunkin/workspace/claws/jidoka/lib/jidoka/trace.ex` | Reference: public API |
| `/Users/rickdunkin/workspace/claws/jidoka/lib/jidoka/trace/event.ex` | Reference: struct shape |
| `/Users/rickdunkin/workspace/claws/jidoka/lib/jidoka/trace/collector.ex` | Reference: ingest/query algorithms |
| `/Users/rickdunkin/workspace/claws/jidoka/lib/jidoka/sanitize.ex` | Reference: key sets + recursive descent |
| `/Users/rickdunkin/workspace/claws/jido_radclaw/lib/jido_claw/application.ex` | Supervisor wire-up (line 127-147) |
| `/Users/rickdunkin/workspace/claws/jido_radclaw/lib/jido_claw/conversations/domain.ex` | Ash.Domain template |
| `/Users/rickdunkin/workspace/claws/jido_radclaw/lib/jido_claw/conversations/request_correlation/cache.ex` | Tenant cache lookup at ingest |
| `/Users/rickdunkin/workspace/claws/jido_radclaw/lib/jido_claw/conversations/resources/request_correlation.ex` | Multitenancy + durable `lookup/1` pattern |
| `/Users/rickdunkin/workspace/claws/jido_radclaw/lib/jido_claw/conversations/recorder.ex` | `resolve_scope/1` (cache-then-durable, line 750) and telemetry handler pattern (line 238-256) |
| `/Users/rickdunkin/workspace/claws/jido_radclaw/lib/jido_claw/reasoning/telemetry.ex` | Reasoning emitter rewrite (line 56-220) |
| `/Users/rickdunkin/workspace/claws/jido_radclaw/lib/jido_claw/reasoning/resources/outcome.ex` | Ash resource pattern (code_interface, async task) |
| `/Users/rickdunkin/workspace/claws/jido_radclaw/lib/jido_claw/tool_context.ex` | Canonical key set; `request_id` is NOT here |
| `/Users/rickdunkin/workspace/claws/jido_radclaw/lib/jido_claw/tools/reason.ex` | `base_telemetry_opts/2` (line 180) — needs `request_id` + `agent_id` |
| `/Users/rickdunkin/workspace/claws/jido_radclaw/deps/jido/lib/jido/observe.ex` | `emit_event/3` signature (line 282) |
| `/Users/rickdunkin/workspace/claws/jido_radclaw/deps/jido_ai/lib/jido_ai/observe.ex` | Canonical telemetry event names (line 221-230) |
| `/Users/rickdunkin/workspace/claws/jido_radclaw/deps/jido_ai/lib/jido_ai/turn.ex` | `params` payload key (line 621) — sanitize target |

## Existing utilities to reuse

- `JidoClaw.Conversations.RequestCorrelation.Cache.lookup/1` (ETS) + `RequestCorrelation.lookup/1` (durable) for tenant resolution.
- `JidoClaw.TaskSupervisor` for any one-off async work outside the Persistence GenServer.
- `Ash.Resource` upsert + `code_interface` pattern from `Reasoning.Resources.Outcome` and `Conversations.RequestCorrelation`.
- `multitenancy strategy: :attribute, attribute: :tenant_id, global? true` pattern from `Conversations.RequestCorrelation`.
- `Jido.Observe.emit_event/3` from `deps/jido/lib/jido/observe.ex:282`.

## Commit sequencing

Seven commits, each compiling and `mix test` green on its own.

1. **Sanitize + Event + Trace struct skeleton** — `lib/jido_claw/trace/{sanitize,event}.ex` and a bare `lib/jido_claw/trace.ex` with `agent_id_key/0` + `emit/3` (calls `Jido.Observe.emit_event/3`). Includes `params` in the large-keys set. Tests 22-24. No supervisor changes.

2. **Collector GenServer + supervisor wire-up + in-memory query API** — `lib/jido_claw/trace/collector.ex`, modify `application.ex` to add Collector, wire public API on `JidoClaw.Trace` (`latest/2|for_request/3|list/2|events/2|spans/2`). Tests 1-8, 13-16, 18-21. Includes the default-off delta behavior.

3. **Tenant scoping (strict)** — add `tenant_id` field to `%Trace{}`, `by_tenant` index, `{:tenant, tid}` target, `tenant_id:` keyword filtering with strict pre-selection filter, durable fallback in `resolve_tenant/1`. Tests 9-12.

4. **Ash domain + resources + codegen migration** — add `JidoClaw.Trace.Domain`, both resources with `code_interface`, run `mix ash.codegen add_trace_domain` to generate the migration + snapshot, register domain in `config/config.exs`. No persistence wiring yet — resources just exist. Test that the migration applies cleanly via `mix ash.setup` (already run by `mix test`).

5. **Persistence GenServer + write path + Postgres fallback in `for_request/3`** — `lib/jido_claw/trace/persistence.ex`, add to `infra_children` (BEFORE Collector), wire Collector to cast on every event. Tests 25-32. Includes `last_seq` ordering guard via `upsert_condition`, explicit `case` branches in `do_persist/2` (no silent error swallowing), UUID fallback for unattributed traces, idempotent duplicate-event handling.

6. **Reasoning canonical path** — replace 4-segment `:telemetry.execute` calls in `lib/jido_claw/reasoning/telemetry.ex` with `Trace.emit(:reasoning, ...)`. Update `Tools.Reason.base_telemetry_opts/2` + `Tools.RunPipeline` + `Tools.VerifyCertificate` to thread `request_id` from `context[:request_id]` and `agent_id` from `tool_context[:agent_id]`. Test 17.

7. **Config knobs + moduledoc cross-refs + polish** — `Application.get_env(:jido_claw, :trace, [])` for `enabled?`, `max_traces`, `max_events_per_trace`, `persist?`, `persist_sync?`. Cross-references from `Conversations.Recorder` and `AgentTracker` moduledocs pointing to `Trace`. Final `mix precommit` run.

## Verification — `mix precommit`

`mix.exs:246-254` runs (in order): `compile --warnings-as-errors`, `jidoclaw.system_prompt.check`, `deps.unlock --unused`, `format`, `credo --strict`, `dialyzer --format short`, `test` (which runs `ash.setup --quiet` first).

Plan-specific gates:

1. **`compile --warnings-as-errors`** — clean. Watch unused aliases.
2. **`jidoclaw.system_prompt.check`** — unchanged (plan doesn't touch system prompt).
3. **`deps.unlock --unused`** — no new deps. No-op.
4. **`format`** — automatic.
5. **`credo --strict`** — decompose `Collector.normalize_event/4` into `event_shape/2`, `event_status/3`, `event_time_ms/2` exactly as Jidoka does. Moduledocs on every new public module.
6. **`dialyzer --format short`** — PLT rebuild adds ~2-3 min on first precommit after this lands. Precise `@spec` on every public function.
7. **`test`** — `ash.setup --quiet` picks up the new migration after commit 4. After commit 5, persistence tests verify the ordering guarantee end-to-end.

End-to-end manual verification once all commits land:

```bash
mix jidoclaw                                          # in one shell
iex -S mix                                            # in another:
> JidoClaw.Trace.list("main")                         # in-flight
> JidoClaw.Trace.history(page: [limit: 10])           # durable
```

Tidewave (per AGENTS.md, "Always use Tidewave's tools"):

```
mcp__tidewave__execute_sql_query "SELECT count(*) FROM trace_runs"
mcp__tidewave__execute_sql_query "SELECT category, count(*) FROM trace_events GROUP BY category"
mcp__tidewave__execute_sql_query "SELECT trace_id, status, last_seq FROM trace_runs ORDER BY inserted_at DESC LIMIT 5"
```

## Open risks

1. **Reasoning behavior change** — removing the 4-segment `:telemetry.execute` is a breaking change for any external consumer attached to `[:jido_claw, :reasoning, :strategy, *]`. No internal consumers found in the grep. Document in the commit message; mention in `Reasoning.Telemetry` moduledoc.

2. **Cache+durable race window** — first-event tenant resolution can miss both Cache and Postgres if `RequestCorrelation.register/1` hasn't returned by then. Backfill on subsequent events covers this. Tests 9 + 11 verify both paths.

3. **Memory ceiling** — tens of MB at the default ring sizes (100 traces × 300 events). Realistic upper bound depends on BEAM struct/map overhead, sanitized metadata size, and per-event measurement maps; a hot system with rich metadata can exceed naive byte estimates. Tunable via `max_traces` / `max_events_per_trace`. Documented in Collector moduledoc.

4. **Persistence GenServer backpressure** — under burst, all writes serialize through one mailbox. Volume estimate (~10k events/min worst case) is well within a single GenServer's throughput. If real workloads exceed this, follow-up commit can shard the Persistence GenServer by `:erlang.phash2(trace_id, N)` while preserving per-trace ordering.

5. **Telemetry handler mailbox under burst** — `send/2` from telemetry handler is unbounded. Same Jidoka risk profile. T2 follow-up if a real workload demands a circuit breaker.

6. **Dialyzer first-run cost** — PLT rebuild ~2-3 min on first precommit. Mention in PR.

7. **No delta visibility** — v1 doesn't expose any way to see streaming deltas. If a user needs them, the follow-up implements coalescing (`delta_count` + `last_delta_preview` on the parent `:model` span) before adding the opt-in attach.

8. **`Jido.Tracing.Context` correlation** — `Jido.AI.Observe.enrich_with_trace_metadata/1` injects `jido_trace_id`/`jido_span_id`/`jido_parent_span_id`. `Jido.Observe.emit_event/3` (used by `Trace.emit/3`) auto-merges them. Test 14 asserts they appear on Trace-native events.
