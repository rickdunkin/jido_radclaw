# Phase 2 — Conversations: implementation plan

Tracking ticket: `docs/plans/v0.6/phase-2-conversations.md`

## Context

Phase 2 retires the JSONL transcript writer (`Session.Worker.append_to_jsonl`)
and persists full-fidelity chat history into Postgres — user, assistant,
tool_call, tool_result, and reasoning rows — so the consolidator (Phase 3)
has a real query surface and the agent loop's tool calls become recoverable
across BEAM restarts. Phase 0 (Conversations.Session, Workspaces.Workspace,
resolvers, dispatch-with-`:kind`) and Phase 1 (Redaction.Transcript /
Patterns / Env) are already in place; this phase fills in the
`Conversations.Message` table, the signal-bridging plugin that captures tool
activity, the request-correlation persistence that survives restarts, the
JSONL→Postgres migrator, and the legacy export task.

## Decisions captured before planning

| Choice | Decision |
|---|---|
| Plugin wiring across 8 `use Jido.AI.Agent` sites | New `JidoClaw.Agent.Defaults` macro that wraps `use Jido.AI.Agent` and injects the Recorder plugin |
| `mix jidoclaw.export.conversations` scope | In scope — full exporter with three §2.7 fixtures (sanitized round-trip, dropped-roles sidecar, redaction-delta manifest) |
| `:reasoning` row capture scope | Full — Recorder writes reasoning rows when the LLMResponse result carries `thinking_content` (see correction below) |
| Cross-tenant FK error string | New resources use `"cross_tenant_fk_mismatch"` (matches Solutions); don't retrofit existing `Conversations.Session` |

## Source-plan corrections + review feedback

Five points where the implementation deviates from the literal source plan
or from earlier draft thinking, all confirmed by code inspection.

1. **`ai.react.*` is the wrong namespace for reasoning capture.**
   `ai.react.*` signals exist but are command/control
   (`ai.react.query`, `ai.react.cancel`, `ai.react.worker.{start,event,cancel}`).
   The reasoning content is on `Jido.AI.Signal.LLMResponse` (type
   `ai.llm.response`). Critically, `thinking_content` is **inside the result
   tuple**, not at the top level of `signal.data` —
   `deps/jido_ai/lib/jido_ai/reasoning/react/strategy.ex:1578-1592` builds
   `Signal.LLMResponse.new!(%{call_id, result: {:ok, %{type, text,
   thinking_content, reasoning_details, tool_calls, usage}, []}, metadata})`.
   The Recorder extracts `thinking_content` from
   `signal.data.result |> elem(1) |> Map.get(:thinking_content)` (matching
   the `{:ok, payload, _effects}` and `{:ok, payload}` shapes via pattern
   match) — **not** `signal.data.thinking_content`.

2. **`request_id` must be passed through `Agent.ask/ask_sync`, not
   `tool_context`.** `Jido.AI.Request.create_and_send/3` accepts
   `request_id:` (`deps/jido_ai/lib/jido_ai/request.ex:191`) and otherwise
   generates its own. The ReAct strategy explicitly merges its own
   `request_id` into the worker context at
   `deps/jido_ai/lib/jido_ai/reasoning/react/strategy.ex:632-648`,
   overwriting whatever the caller put in `tool_context.request_id`. The
   dispatcher must mint the `request_id` and pass it as a top-level option
   to `Agent.ask/ask_sync`, not via `tool_context`.

3. **Resolver names in §2.5 are stale.**
   `JidoClaw.Workspaces.Resolver.ensure_workspace/3` and
   `JidoClaw.Conversations.Resolver.ensure_session/5` are the actual
   modules (the plan says `WorkspaceResolver.ensure/1` and
   `SessionResolver.ensure_session/4`).

4. **Mix task naming convention is `jidoclaw.*`** (no underscore between
   `jido` and `claw`). Existing tasks: `mix jidoclaw.migrate.solutions`,
   `mix jidoclaw.export.solutions`. The new tasks are
   `mix jidoclaw.migrate.conversations` and
   `mix jidoclaw.export.conversations`.

5. **`:imported_legacy` is already in the `kind` enum**
   (`lib/jido_claw/conversations/resources/session.ex:149`) — no §0.4
   extension needed.

## Critical files

### New modules

| File | Purpose |
|---|---|
| `lib/jido_claw/conversations/resources/message.ex` | §2.1 resource — append/import/read actions, sequence allocation, partial identities |
| `lib/jido_claw/conversations/resources/request_correlation.ex` | §2.3 resource — durable `request_id → {session, tenant, workspace, user}` mapping |
| `lib/jido_claw/conversations/transcript_envelope.ex` | §2.4 stage 1 — JSON-safe envelope normalizer for tool result tuples |
| `lib/jido_claw/conversations/recorder.ex` | GenServer that subscribes to `ai.*` topics on `JidoClaw.SignalBus` and writes Message rows |
| `lib/jido_claw/conversations/request_correlation/cache.ex` | GenServer-owned ETS table (Tenant.Manager pattern) |
| `lib/jido_claw/conversations/request_correlation/sweeper.ex` | Periodic worker that calls `RequestCorrelation.sweep_expired` |
| `lib/jido_claw/conversations/session_id.ex` | Move target for the legacy `Session.new_session_id/0` helper (still used by REPL boot) |
| `lib/jido_claw/agent_server_plugin/recorder.ex` | `use Jido.Plugin` — bridges agent-mailbox `ai.*` signals to `JidoClaw.SignalBus` |
| `lib/jido_claw/agent/defaults.ex` | Macro wrapper around `use Jido.AI.Agent` that injects the Recorder plugin |
| `lib/mix/tasks/jidoclaw.migrate.conversations.ex` | §2.5 JSONL → Postgres migrator |
| `lib/mix/tasks/jidoclaw.export.conversations.ex` | §2.7 round-trip exporter with sidecar + redaction manifest |
| `priv/repo/migrations/<ts>_v060_create_messages_and_request_correlations.exs` | Generated by `mix ash_postgres.generate_migrations` |

### Modified

| File | What changes |
|---|---|
| `lib/jido_claw/conversations/resources/session.ex` | Add `update :set_next_sequence` action for the migrator's post-import bump (current actions only expose `:touch`/`:close`) |
| `lib/jido_claw/conversations/domain.ex` | Register Message + RequestCorrelation |
| `lib/jido_claw/platform/session/worker.ex` | Strip JSONL helpers; store `session_uuid` on state; `add_message/4` calls `Message.append!`; `handle_continue(:load)` reads from Postgres |
| `lib/jido_claw.ex` | `chat/4` resolves Workspace+Session BEFORE the user-message append; mints `request_id` and passes via `Agent.ask_sync(_, _, request_id: …)`; writes RequestCorrelation row + Cache entry |
| `lib/jido_claw/cli/repl.ex` | Same correlation write before `Agent.ask`; `repl.ex:155` switches from `JidoClaw.Session.new_session_id/0` to the new helper; flush Recorder before assistant write |
| `lib/jido_claw/tools/send_to_agent.ex` | Child correlation write before child dispatch; pass `request_id` |
| `lib/jido_claw/tools/spawn_agent.ex` | Same as above (ask_sync caller at `spawn_agent.ex:51`) |
| `lib/jido_claw/workflows/step_action.ex` | Same as above (ask_sync caller at `step_action.ex:58`) |
| `lib/jido_claw/tool_context.ex` | Add `:user_id` to `@canonical_keys` (`tool_context.ex:28-36`); without this, `tool_context[:user_id]` is silently dropped by `build/1` and child correlations always lose user scope |
| `lib/jido_claw/agent/agent.ex` + 7 worker files | All 8 sites change `use Jido.AI.Agent` → `use JidoClaw.Agent.Defaults` |
| `lib/jido_claw/application.ex` | Start Cache, Recorder, Sweeper under InfraSupervisor; Recorder monitors `JidoClaw.SignalBus` and resubscribes on `:DOWN` |

### Deleted

- `lib/jido_claw/platform/session.ex` — legacy module, only `new_session_id/0` is live and that moves to `Conversations.SessionId`

## Implementation phases

### A — Data layer (resources + migration)

1. **`Conversations.Message`** per §2.1.
   - `attribute :inserted_at, :utc_datetime_usec, default: &DateTime.utc_now/0, allow_nil?: false, writable?: true` — explicitly NOT the `create_timestamp` macro (which sets `writable? false`, blocking `:import`).
   - Three identities: `unique_import_hash` (partial), `unique_session_sequence` (total), `unique_live_tool_row` (partial). Register the two partials in `postgres do … identity_wheres_to_sql … end` (existing pattern: `lib/jido_claw/workspaces/resources/workspace.ex:30-33`).
   - Indexes per §2.1.
   - Actions: `:append`, `:import`, `:for_session`, `:since_watermark`, `:by_tool_call`, `:by_request`.
   - Three `before_action` hooks on `:append`, all using `Ash.Changeset.force_change_attribute/3` (idiomatic Ash for setting attrs after validations have run):
     1. **Tenant denormalization** — fetch parent session (`Conversations.Session.by_id`), copy `tenant_id` onto changeset; caller can't spoof.
     2. **Sequence allocation** — raw SQL `UPDATE conversation_sessions SET next_sequence = next_sequence + 1 WHERE id = $session_id RETURNING next_sequence - 1 AS sequence` (table name is `conversation_sessions` per `lib/jido_claw/conversations/resources/session.ex:25` and `priv/repo/migrations/20260430224530_v060_create_workspaces_and_sessions.exs:69`) via `Ecto.Adapters.SQL.query!` inside the action transaction; row-level lock serializes concurrent appends to the same session.
     3. **Redaction** — pipe `content` and `metadata` through `Redaction.Transcript.redact/1`.
   - One `before_action` hook on `:import`:
     - **Cross-tenant FK validation** — fetch session, `Ash.Changeset.add_error(field: :session_id, message: "cross_tenant_fk_mismatch")` if `session.tenant_id != changeset.tenant_id`. Pattern mirrors `lib/jido_claw/solutions/resources/solution.ex:486` (Solution `:import_legacy`).
   - `:import` does NOT run the sequence-allocation hook; caller passes `sequence` explicitly.

2. **`Conversations.RequestCorrelation`** per §2.3.
   - Attributes: `request_id` (text, PK), `session_id`, `tenant_id`, `workspace_id` (nullable), `user_id` (nullable), `inserted_at`, `expires_at`.
   - Default `expires_at = inserted_at + 600s` (10 min) when caller doesn't supply one.
   - Indexes: PK (auto), `(expires_at)`, `(tenant_id, expires_at)`.
   - Actions:
     - `:register` (create) — accepts the full attribute set from the dispatcher.
     - `:complete` (destroy) — used by the Recorder on terminal signals. Define an explicit code interface so the Recorder can delete by request_id without first reading the row: `define :complete, action: :complete, get_by: [:request_id]`. Then `RequestCorrelation.complete!(request_id)` is the call. The same destroy action also works with `Ash.bulk_destroy!(records, :complete, %{})` for the sweep path.
     - `:expired` (read) — `Ash.Query.filter(expires_at < now())`. Used by the sweeper, NOT a destroy action: Ash's destroy-action DSL doesn't carry a query limit, and we want a bounded 1_000-row tick. Also expose a code interface: `define :expired, action: :expired`.

     The sweeper module fn (`RequestCorrelation.sweep_expired/0`) is:
     ```
     def sweep_expired do
       expired =
         __MODULE__
         |> Ash.Query.for_read(:expired)
         |> Ash.Query.limit(1_000)
         |> Ash.read!()

       case expired do
         [] -> {:ok, 0}
         records ->
           Ash.bulk_destroy!(records, :complete, %{})
           {:ok, length(records)}
       end
     end
     ```
     `Ash.read!/2` takes a query, not `(resource, action, opts)`
     (`deps/ash/lib/ash.ex:2756`); the
     `Ash.Query.for_read |> limit |> read!` chain is the idiomatic
     bounded-read shape. `Ash.bulk_destroy!/3` matches the destroy
     action API at `deps/ash/lib/ash.ex:3485`.
   - `before_action` on `:register` — cross-tenant FK validation across `session_id` AND `workspace_id` (skip `user_id` per §0.5.2 untenanted-parent rule).

3. **`Conversations.TranscriptEnvelope.normalize/1`** per §2.4 stage 1.
   - Pure module, no GenServer. Recursive normalizer with the canonical
     output shape from §2.4 (status / value / error / effects /
     raw_inspect). Atoms (except primitives) → `":<atom>"`; tuples →
     `%{__tuple__: [...]}`; structs with `Jason.Encoder` → encode/decode;
     others → `inspect/2` into `raw_inspect`.

4. **Add `update :set_next_sequence` action to `Conversations.Session`,
   plus an explicit `read :by_id` action.**
   - Current Session actions only expose `:touch` / `:close`; the
     migrator needs a named action to bump `next_sequence` to
     `max(imported_sequence) + 1` after each session's batch import.
   - Define as `update :set_next_sequence do; argument :next_sequence,
     :integer, allow_nil?: false; change set_attribute(:next_sequence,
     arg(:next_sequence)); end`. With `args: [:next_sequence]` declared
     on the matching `code_interface`, the generated call is positional:
     `Conversations.Session.set_next_sequence!(session, next_sequence)`,
     not `set_next_sequence!(session, %{next_sequence: N})`.
   - `read :by_id, get_by: [:id]` — needed by `Message`'s `:append`
     `before_action` for tenant denormalization (looking up the parent
     session by primary key inside the action transaction). Today
     callers fall back to `Ash.get/2` which works but isn't idiomatic
     and bypasses domain authorization; the named action makes it
     explicit. Add a corresponding `code_interface :by_id, args: [:id], get?: true`
     — the `get?: true` flag matches the existing local style (e.g.
     `Workspace.by_path` in `lib/jido_claw/workspaces/resources/workspace.ex`)
     and makes the return-shape explicit (`{:ok, record} | {:error, _}`,
     not a list). Call sites are `Conversations.Session.by_id!(session_id)`.

5. **Generate migrations**.
   - `mix ash_postgres.generate_migrations` — produces the migration file plus snapshot files for the new resources.
   - Spot-check the partial identity `WHERE` clauses are present.
   - Run `mix ecto.migrate` against dev DB.

### B — Worker swap-out

**Naming convention used in the rest of this section.** `tool_context`
already carries both forms (`lib/jido_claw/tool_context.ex:14-20`):
`:session_id` / `:workspace_id` are the runtime/string IDs (CLI session
strings, project_dir paths); `:session_uuid` / `:workspace_uuid` are the
DB UUIDs (`Conversations.Session.id` / `Workspaces.Workspace.id`). The
new `Conversations.Message.session_id` and
`Conversations.RequestCorrelation.session_id` columns are FK targets and
therefore want **UUIDs**. To keep this unambiguous below, the plan uses
`session.id` / `workspace.id` (UUID, returned by the resolver) when the
target is the FK column, and the `tool_context` keys (`:session_uuid` /
`:workspace_uuid`) when threading through child contexts.

6. **Reorder `chat/4`** (`lib/jido_claw.ex:27-82`) so workspace + session
   are resolved BEFORE the user-message append. Today the user message is
   written at `jido_claw.ex:68` (via `Worker.add_message`) before any
   resolver runs. Worker.add_message can't write a `Conversations.Message`
   with the session UUID until the session row exists. New order:
   `ensure_workspace → ensure_session → mint request_id → register
   RequestCorrelation(session_id: session.id, workspace_id: workspace.id) →
   Worker.add_message(user, request_id)` → `Agent.ask_sync(...,
   request_id: request_id, tool_context: ctx)` → `Recorder.flush()` →
   `Worker.add_message(assistant, request_id)`.
7. **`Session.Worker` swap-out** (`lib/jido_claw/platform/session/worker.ex`).
   - State adds `session_uuid` (the `Conversations.Session.id` UUID); the
     existing `state.id` keeps the legacy external string for registry
     compatibility, but the persistence path uses `session_uuid`.
   - Caller must set `session_uuid` via a new `set_session_uuid/3` API
     after `Conversations.Resolver.ensure_session/5` returns. The handler
     for `set_session_uuid` ALSO hydrates `state.messages` from
     `Message.for_session(session.id)` synchronously — otherwise
     `handle_call(:get_messages)` and `get_info.message_count` would stay
     stale until the next Worker restart, since `handle_continue(:load)`
     no-ops when the UUID is still unset at boot.
   - The worker refuses `add_message/4` until `set_session_uuid` has
     run (returns `{:error, :session_uuid_unset}`).
   - `add_message/4` accepts `request_id` as a 5th arg (or via opts) and
     calls `Conversations.Message.append!(%{session_id: state.session_uuid,
     role:, content:, request_id: request_id, ...})`. Redaction happens
     inside the resource hook.
   - `handle_continue(:load, state)` no-ops if `session_uuid` is unset;
     otherwise reads via `Message.for_session(state.session_uuid)`. With
     the eager `set_session_uuid` hydration above this becomes a fallback
     for warm-restart paths that bypass the explicit setter.
   - Delete `append_to_jsonl/3`, `load_from_jsonl/2`, `jsonl_dir/1`,
     `jsonl_path/2`.
   - `handle_call(:get_messages)` drops `Enum.reverse` since Postgres
     returns chronologically forward.
8. **Update `JidoClaw.history/2`** (`lib/jido_claw.ex:179`) — preserve the
   legacy `[%{role: String, content:, timestamp: int_ms}]` return shape
   via a small adapter that converts `role` atom → string and
   `inserted_at` `DateTime` → `unix_ms`. **But** `Message.for_session/1`
   takes a `Conversations.Session.id` UUID, while `history/2`'s
   `session_id` argument is a runtime/external string. Resolution path:
   - If a `Session.Worker` is alive for `(tenant_id, session_id)`, read
     `state.messages` from the worker (cached by step 7's hydration).
     This is the live-session path — fast, no DB round-trip — and it's
     what 100% of in-flight `history/2` callers exercise today.
   - Add a new `JidoClaw.history/3` that takes
     `(tenant_id, session_id_external, opts)` with **required**
     `:kind` and optional `:workspace_id` (defaults to `File.cwd!()`)
     in `opts`. Required `:kind` is the deliberate choice — defaulting
     to `:api` produces silent false-not-founds for REPL / Discord /
     Telegram sessions whose `kind` is something else, and the cold
     lookup identity `(tenant, workspace, kind, external_id)` makes
     the value load-bearing. A missing `:kind` raises `KeyError` at
     compile/call time, which is the right failure mode.
     Internally: read-only resolution — call
     `Workspaces.Resolver.ensure_workspace(tenant_id, opts[:workspace_id]
     || File.cwd!())` (workspace creation is acceptable; ensure is
     idempotent), then `Conversations.Session.by_external!(tenant_id,
     workspace.id, opts[:kind], session_id_external)` — using the
     **existing read action**, NOT `ensure_session/5`. Returning a
     not-found error when the session doesn't exist is the correct
     behavior; `history/3` must not create a row as a side effect.
     Then `Message.for_session(session.id)`.
9. **Move `new_session_id/0`** to `JidoClaw.Conversations.SessionId` and update its single live caller (`lib/jido_claw/cli/repl.ex:155`). Then delete `lib/jido_claw/platform/session.ex` entirely.
10. Run `mix test` to confirm regression-free.

### C — Recorder + plugin + Defaults macro

11. **`JidoClaw.Conversations.RequestCorrelation.Cache`** — GenServer that
    owns its ETS table (mirrors `JidoClaw.Tenant.Manager` at
    `lib/jido_claw/platform/tenant/manager.ex:40`). API: `put/2`,
    `lookup/1`, `delete/1`, `clear/0`, all backed by `GenServer.call`s
    that the GenServer translates into `:ets.{insert,lookup,delete}`. The
    GenServer is the table owner; if it crashes, the supervisor restarts
    it and the table is re-created. Lookups on a cold cache hit the
    Postgres fallback in the Recorder, so a brief restart is invisible to
    callers.
12. **`JidoClaw.AgentServerPlugin.Recorder`** plugin — must compile
    against `Jido.Plugin`'s schema, which requires `state_key` and
    `actions` (`deps/jido/lib/jido/plugin.ex:80-92`). `name` must be a
    **string** (per the `Zoi.string()` declaration at plugin.ex:82-86),
    not an atom — example sites in the deps tree use `name: "chat"` /
    `name: "my_agent"`:
    ```
    use Jido.Plugin,
      name: "recorder",
      state_key: :recorder,
      actions: [],
      signal_patterns: [
        "ai.tool.started", "ai.tool.result",
        "ai.llm.response",
        "ai.request.completed", "ai.request.failed"
      ]
    ```
    `handle_signal/2` must NEVER return `{:error, _}` — agent_server.ex:1896
    halts signal processing on plugin errors, which would stall the agent.
    Wrap the publish in try/rescue and always return `{:ok, :continue}`:
    ```
    def handle_signal(signal, _ctx) do
      try do
        Jido.Signal.Bus.publish(JidoClaw.SignalBus, [signal])
      rescue
        e -> Logger.warning("[Recorder.Plugin] publish failed: #{inspect(e)}")
      catch
        kind, payload ->
          Logger.warning("[Recorder.Plugin] publish #{kind}: #{inspect(payload)}")
      end
      {:ok, :continue}
    end
    ```
13. **`JidoClaw.Agent.Defaults`** macro:
    ```
    defmacro __using__(opts) do
      base_plugins = [JidoClaw.AgentServerPlugin.Recorder]
      opts = Keyword.update(opts, :plugins, base_plugins, &(base_plugins ++ &1))
      quote do
        use Jido.AI.Agent, unquote(opts)
      end
    end
    ```
    Each of 8 sites changes line 2 from `use Jido.AI.Agent, …` to `use JidoClaw.Agent.Defaults, …`. Existing per-site options (model, max_iterations, tool_timeout_ms, llm_opts, streaming) pass through unchanged.
14. **`JidoClaw.Conversations.Recorder`** GenServer:
    - `init/1` returns `{:ok, state, {:continue, :setup}}`.
    - `handle_continue(:setup, state)` resolves the bus PID — but
      retry-safe, because `Jido.Signal.Bus.whereis(JidoClaw.SignalBus)`
      can return `{:error, :not_found}` during a bus restart and a
      pattern-match crash would put the Recorder into a restart loop:
      ```
      case Jido.Signal.Bus.whereis(JidoClaw.SignalBus) do
        {:ok, bus_pid} ->
          Enum.each(@topics, &JidoClaw.SignalBus.subscribe/1)
          Process.monitor(bus_pid)
          {:noreply, %{state | bus_pid: bus_pid}}
        {:error, :not_found} ->
          Process.send_after(self(), :retry_setup, 250)
          {:noreply, state}
      end
      ```
      (The delegate is at `deps/jido_signal/lib/jido_signal/bus.ex:306`
      → `Jido.Signal.Util.whereis/2`.) `handle_info(:retry_setup, ...)`
      runs the same logic; the Recorder will eventually find the bus
      after the supervisor brings it back.
    - `handle_info({:DOWN, _ref, :process, _pid, _reason}, state)` —
      schedule the same `:retry_setup` (NOT a `handle_continue` —
      `handle_continue` only fires once after init/handle_call/etc., not
      from arbitrary handle_info paths). InfraSupervisor is
      `:one_for_one`, so a bus crash leaves the Recorder running but
      stranded; the retry brings it back when the bus is up again.
    - `handle_info({:signal, %Jido.Signal{type: type} = signal}, state)`:
      - `"ai.tool.started"`: lookup correlation (Cache → RequestCorrelation Postgres fallback → rehydrate Cache); normalize+redact `signal.data.arguments` via `TranscriptEnvelope.normalize/1` then `Redaction.Transcript.redact/1`; write `:tool_call` row with `tool_call_id: signal.data.call_id`, `request_id: signal.data.metadata.request_id`, `content` = `"#{tool_name}(args…)"` summary, `metadata` = redacted envelope.
      - `"ai.tool.result"`: same lookup + normalize/redact; resolve parent via `Message.by_request(session_id, request_id, tool_call_id, role: :tool_call)`; write `:tool_result` row with `parent_message_id` and content = `"#{tool_name} → ok"` / `"… → error: …"`.
      - `"ai.llm.response"`: extract `thinking_content` from inside the result tuple — `case signal.data.result do {:ok, %{thinking_content: tc}, _} when is_binary(tc) and tc != "" -> write_reasoning(tc); _ -> :skip end`. Match both 2- and 3-tuple result shapes.
      - `"ai.request.completed"` / `"ai.request.failed"`: delete RequestCorrelation row + Cache entry.
    - All write paths use a try/rescue that classifies errors:
      - Duplicate-key violations (caught via `Ash.Error.Invalid` containing the partial-identity violation) → log at `:debug` and skip (idempotent).
      - Anything else → log at `:warning` and skip; the agent loop must keep going.
    - Specifically NOT `Message.append!/1` in the hot path — use `Message.append/1` (without the `!`) and pattern-match on the result.
15. **Recorder `:flush` API — request-keyed barrier, not naive FIFO.**
    A naive `GenServer.call(Recorder, :flush)` does NOT establish the
    ordering guarantee we want: BEAM only guarantees per-sender FIFO,
    not total ordering across senders. The caller's call message comes
    from the caller PID; the `{:signal, _}` messages come from the
    `Jido.Signal.Bus` PID. The Recorder may dequeue the flush call
    before the bus has delivered a still-in-flight `:signal` message
    that the agent emitted moments earlier — race window is real.

    **Correct shape: wait for the request's terminal signal.** The
    Recorder already processes `ai.request.completed` and
    `ai.request.failed` (step 14). When the agent's `ask_sync` returns,
    one of those terminal signals is in flight (or has already
    arrived). Wait for it:

    ```
    @spec flush(String.t(), timeout()) :: :ok | {:error, :timeout}
    def flush(request_id, timeout \\ 30_000) do
      try do
        GenServer.call(__MODULE__, {:flush, request_id}, timeout)
      catch
        :exit, {:timeout, _} ->
          Logger.warning("[Recorder.flush] timeout for request_id=#{request_id}")
          {:error, :timeout}
      end
    end
    ```
    The `try/catch` is important: a raw `GenServer.call` exits the
    caller process on timeout, which would crash the dispatcher and
    surface as `EXIT` to whatever supervises it (`chat/4` callers,
    REPL, channel adapters). Wrapping it lets the dispatcher decide
    what to do — and the right call here is to **log the timeout and
    still write the assistant row**, because dropping the agent's
    response after `ask_sync` already returned successfully is a
    worse outcome than a rare ordering miss. The acceptance test for
    "Assistant/tool_result ordering" should run under the happy path
    only; a separate regression test exercises the timeout branch.

    Recorder state gains:
    - `waiters :: %{request_id => [from]}` — pending flush calls
      keyed by `request_id`.
    - `recent_completed :: :queue.queue()` — bounded LRU (e.g. last
      512) of `request_ids` that already saw a terminal signal,
      so a late flush returns immediately.

    Handler logic:
    - `handle_call({:flush, request_id}, from, state)`:
      - If `request_id` is in `recent_completed`, reply `:ok` immediately.
      - Otherwise prepend `from` to `state.waiters[request_id]` and
        return `{:noreply, state}` (no immediate reply).
    - On `ai.request.completed` / `ai.request.failed` for `request_id`:
      - After processing the signal (writing any pending rows, deleting
        correlation), `Enum.each(state.waiters[request_id] || [],
        &GenServer.reply(&1, :ok))`; drop from `waiters`; push onto
        `recent_completed` (with eviction at the 512 mark).
    - The 30s timeout on the caller side guards against lost terminal
      signals — the call raises `:timeout` rather than hanging the
      dispatcher forever.

    The dispatcher (`chat/4`, REPL) calls `Recorder.flush(request_id)`
    after `Agent.ask_sync` returns and before the assistant
    `Worker.add_message`. By the time `flush/1` returns `:ok`, the
    Recorder has *finished processing* the request's terminal signal,
    which means it has also processed every prior `:signal` for that
    request (because the Recorder processes its mailbox in FIFO order
    from a single sender — the bus PID — and the bus delivered all
    signals for one agent invocation in emission order).

    **Caveat — partition_count must be 1.** The per-sender-FIFO
    argument above also requires `Jido.Signal.Bus` to be configured
    with `partition_count: 1`. With multiple partitions, signals are
    fanned out to multiple partition GenServers
    (`deps/jido_signal/lib/jido_signal/bus.ex:1037`), each with its
    own mailbox, so the Recorder may receive signals from multiple
    senders and per-sender FIFO is not enough. Mitigation: explicitly
    start `JidoClaw.SignalBus` with `partition_count: 1` (verify the
    existing `application.ex:74` child spec — if it doesn't already
    pin this, add it) and add a regression test that asserts the bus
    is single-partition. If multi-partition becomes desirable later,
    the request-keyed waiter design above is still correct — only the
    "all prior signals processed" claim weakens, and the Recorder
    would need an internal counter-based barrier per request_id
    (publish-side increment via the AgentServerPlugin bridge,
    consume-side decrement; flush waits for parity).

### D — Dispatcher integration + sweeper + ordering barrier

16. **`JidoClaw.chat/4`** (`lib/jido_claw.ex:27`):
    - Resolve workspace + session FIRST (today happens later at `jido_claw.ex:104,106`). `workspace = Workspaces.Resolver.ensure_workspace(...)` and `session = Conversations.Resolver.ensure_session(...)` give back the records — `workspace.id` / `session.id` are the UUIDs.
    - Mint `request_id = Ecto.UUID.generate()`.
    - `Conversations.RequestCorrelation.register/1` with `(request_id, session_id: session.id, tenant_id: tenant_id, workspace_id: workspace.id, user_id: opts[:user_id], expires_at: now + 600s)` — note the `session_id` and `workspace_id` columns on RequestCorrelation expect the UUIDs, not the runtime/external IDs.
    - `Cache.put(request_id, %{session_id: session.id, tenant_id: tenant_id, workspace_id: workspace.id, user_id: opts[:user_id]})`.
    - `Worker.set_session_uuid(tenant_id, session_id_external, session.id)` so the worker can persist (passes legacy external string as the registry key plus the new UUID as the FK target).
    - `Worker.add_message(:user, message, request_id)` — request_id is stored on the user row too, per §2.1's "nullable on user/system rows" — populating it lets Phase 3 group messages by request and lets §G ordering tests assert per-turn ordering invariants without fishing for `inserted_at` ranges.
    - `Agent.ask_sync(pid, message, request_id: request_id, timeout: 120_000, tool_context: tool_context)` — pass `request_id` as a top-level option (NOT inside `tool_context`, which gets overwritten by the ReAct strategy at `react/strategy.ex:632-648`).
    - `Recorder.flush(request_id)` — barrier so any `:tool_call` / `:tool_result` / `:reasoning` rows committed during the agent loop have a sequence less than the assistant row about to be written. The flush returns `:ok` once the Recorder has processed the request's terminal signal (per step 15's request-keyed waiter design).
    - `Worker.add_message(:assistant, response, request_id)`.
17. **REPL** (`lib/jido_claw/cli/repl.ex:272`) — same shape; the REPL goes through `Agent.ask/3` directly (not `chat/4`), so the dispatcher block lives next to that call. The `set_session_uuid` call already has a place at `repl.ex:159` (`ensure_session`). Both `add_message` calls (user and assistant) take the same `request_id`.
18. **Child agent dispatch sites — all four**:
    - `lib/jido_claw/tools/send_to_agent.ex:39, 48`
    - `lib/jido_claw/tools/spawn_agent.ex:51`
    - `lib/jido_claw/workflows/step_action.ex:58`
    Each one mints a child `request_id`, registers a child correlation that
    **inherits the UUIDs from `tool_context`**: `session_id:
    tool_context.session_uuid`, `workspace_id: tool_context.workspace_uuid`,
    `tenant_id: tool_context.tenant_id`, `user_id: tool_context[:user_id]`.
    Then passes `request_id:` through to the child `ask_sync` call. Without
    these, the Recorder will fail correlation lookup for tool signals
    coming from child agents — every tool_call/tool_result emitted by a
    child would land in the Postgres-fallback path and (if the
    correlation isn't there either) get dropped.
19. **`JidoClaw.Conversations.RequestCorrelation.Sweeper`** GenServer:
    - `init/1` schedules `:timer.send_interval(60_000, :sweep)`.
    - `handle_info(:sweep, state)` calls `Conversations.RequestCorrelation.sweep_expired/0` (the module fn defined in step 2). When the result is `{:ok, 1_000}`, immediately `send(self(), :sweep)` to drain the backlog rather than waiting for the next tick.
20. **Wire into `lib/jido_claw/application.ex`** under `InfraSupervisor`: `Cache` (GenServer), then `Recorder`, then `Sweeper`. All three start after the existing `Jido.Signal.Bus` child at `application.ex:74`. Recorder's `Process.monitor` of the bus PID handles bus restarts (the alternative — switching InfraSupervisor to `:rest_for_one` — is more invasive and out of scope).

### E — Migrator (`mix jidoclaw.migrate.conversations`)

Template: `lib/mix/tasks/jidoclaw.migrate.solutions.ex`.

21. Walk `.jido/sessions/<tenant>/*.jsonl` — `<tenant>` is the source of truth, NO defaulting to `"default"`.
22. Parse filename → `(kind, external_id)` per the §2.5 step 2 prefix table. Unknown shape → `(:imported_legacy, basename_without_ext)`.
23. Resolve workspace: `Workspaces.Resolver.ensure_workspace(tenant_id, File.cwd!())`. Surface this assumption in CLI output.
24. Resolve session: `Conversations.Resolver.ensure_session(tenant_id, workspace.id, kind, external_id)`.
25. Stream JSONL **in file order**; for each line:
    - Decode the legacy shape `%{role:, content:, timestamp:}`.
    - Convert `role` string → atom via explicit clauses, NOT `String.to_atom/1`:
      ```
      defp parse_role("user"), do: :user
      defp parse_role("assistant"), do: :assistant
      defp parse_role(other), do: raise "unknown legacy role: #{inspect(other)}"
      ```
    - Convert `timestamp` ms-int → `DateTime.from_unix!(ts, :millisecond)`.
    - Increment a per-session counter (1-based).
    - Compute `import_hash = SHA-256(session_id || sequence || role || inserted_at_ms || content)`.
    - Call `Conversations.Message.import/1`. On `{:error, %Ash.Error.Invalid{}}` matching the `unique_import_hash` partial identity, treat as idempotent skip.
26. After all rows for a session: single `Conversations.Session.set_next_sequence!(session, max(sequence) + 1)` (positional call from the `code_interface` defined in step 4).
27. JSONL files are NOT deleted (manual cleanup after operator verification).
28. Optional `--dry-run`. CLI argument parser via `OptionParser.parse(args, switches: [project: :string, dry_run: :boolean])`.
29. Call `JidoClaw.Tenant.Manager.get_tenant/1` against the directory tenants and warn (not skip) on unregistered tenant strings, so users can reconcile before Phase 4.

### F — Exporter (`mix jidoclaw.export.conversations`)

Template: `lib/mix/tasks/jidoclaw.export.solutions.ex`.

30. CLI surface: `mix jidoclaw.export.conversations --tenant TENANT [--workspace DIR] [--kind KIND] [--session EXTERNAL_ID | --session-uuid UUID] [--out PATH] [--with-redaction-manifest]`.
    - When `--session-uuid` is given, skip resolution and call `Message.for_session/1` directly.
    - Otherwise resolve **read-only** (no implicit session creation): `--workspace` (defaults to cwd) → `Workspaces.Resolver.ensure_workspace(tenant, workspace_dir)` (workspace ensure is idempotent); `--kind` (required when `--session` is given since `(tenant, workspace, kind, external_id)` is the unique identity) → `Conversations.Session.by_external!(tenant, workspace.id, kind, external_id)`. If the session doesn't exist, the export task exits with a clear error rather than silently inserting an empty row. Then read `Message.for_session(session.id)`.
31. Read messages ordered by `sequence` ASC.
32. For `--out PATH` (default `<project_dir>/.jido/sessions/<tenant>/<external_id>.jsonl.exported`), emit one JSON line per `:user` / `:assistant` row in the legacy shape `%{role:, content:, timestamp:}` (timestamp = `DateTime.to_unix(:millisecond)`).
33. Emit `<file>.export-manifest.json` sidecar listing dropped rows by `(sequence, role)` for `:tool_call`/`:tool_result`/`:reasoning` — closes the §2.7 dropped-roles fixture.
34. With `--with-redaction-manifest`, also emit a redaction-delta manifest: for each `:user`/`:assistant` row whose `content` contains the literal string `"[REDACTED"`, list `(sequence, position_in_content, pattern_category)`.

### G — Acceptance tests (§2.7)

Test files under `test/jido_claw/conversations/` and `test/mix/tasks/`.

| Gate | Test |
|---|---|
| New REPL session creates Message rows | `repl_test.exs` — drive a fake REPL turn, assert rows |
| Discord traffic populates Message rows incl. tool calls/results | Integration test that exercises a tool through the Recorder |
| `JidoClaw.history/2` API preserved | Read-shape regression test |
| Migrated transcripts retain content + ordering | Walk a fixture session through migrator, assert `for_session` returns same content in same order |
| Redaction confirmed via fixtures | Append a message containing each §1.4 pattern; assert redacted in DB |
| Recorder plugin coverage CI gate | AST traversal under `lib/`: every `use Jido.AI.Agent` OR `use JidoClaw.Agent.Defaults` site is enumerated; each must resolve to one that injects the Recorder plugin |
| Concurrent tool-result signals → exactly one row | Emit duplicate `Signal.ToolResult`; second insert rejected by `unique_live_tool_row` (and Recorder logs as idempotent skip, not crash) |
| Recorder correlation survives process restart | Dispatch → assert RequestCorrelation row → kill+restart Recorder → emit ToolResult → assert Message row carries correct `(session, tenant, workspace, user)` |
| TTL sweep eviction | Insert backdated row; sweep; assert gone. Then dispatch + emit `request_completed` → both Cache + Postgres deleted |
| Tool envelope shape | End-to-end tool call; assert `:tool_call` metadata has `arguments`, `:tool_result` metadata has `result` |
| Import-hash collision | Two identical user lines at the same ms → 2 rows (different `sequence`, different `import_hash`) |
| Cross-tenant FK validation regression for `:import` | Tenant-A migrator pointed at Tenant-B session → fails with `:cross_tenant_fk_mismatch`, no row written |
| Round-trip three fixtures | `migrate.conversations` + `export.conversations` against sanitized / dropped-roles / redaction-delta fixtures |
| Assistant/tool_result ordering | After an agent run that calls a tool, assert `:tool_result.sequence < :assistant.sequence` for that request — verifies the `Recorder.flush()` barrier works |
| Reasoning extraction shape | Mock an `ai.llm.response` with `thinking_content` inside `{:ok, %{thinking_content: "x"}, []}` — assert `:reasoning` row written with `content = "x"`. Mock with empty/absent thinking_content — assert no row |
| Plugin halts processing only on `{:ok, :continue}` | Force the Recorder plugin's publish to crash; assert the agent loop continues (plugin still returns `{:ok, :continue}` after rescue), no `{:error, _}` propagates to the agent |
| Bus restart resubscribe | Kill `JidoClaw.SignalBus`; supervisor restarts it; emit a tool signal; assert Recorder still receives it (its `:DOWN` handler resubscribed) |
| `Recorder.flush` timeout is non-fatal | Force the Recorder to never receive the terminal signal (e.g. mock a request without a `request_completed` emission); call `Recorder.flush(request_id, 100)`; assert the call returns `{:error, :timeout}` (NOT exits the caller) and the dispatcher proceeds to write the assistant row |
| `ToolContext` preserves `:user_id` | `ToolContext.build(%{user_id: "uuid-1", tenant_id: "x", project_dir: "/tmp"})[:user_id] == "uuid-1"`; child `ToolContext.child(parent_ctx, %{}) ` carries `:user_id` forward — guards against the canonical-keys regression where the value would silently drop on `build/1` |
| `RequestCorrelation.sweep_expired` shape | Insert >1_000 expired rows; one tick deletes exactly 1_000 and returns `{:ok, 1_000}`; the sweeper immediately reschedules and drains the rest |
| `mix ash.codegen --check` | Clean |
| `mix ash_postgres.generate_migrations` | Clean (no `identity_wheres_to_sql` errors) |

## Reused infrastructure

These already exist; the plan does not re-implement them:

- `JidoClaw.Workspaces.Resolver.ensure_workspace/3` — `lib/jido_claw/workspaces/resolver.ex:19`
- `JidoClaw.Conversations.Resolver.ensure_session/5` — `lib/jido_claw/conversations/resolver.ex:25`
- `JidoClaw.Security.Redaction.Transcript.redact/1` — `lib/jido_claw/security/redaction/transcript.ex`
- `JidoClaw.Security.Redaction.Patterns.redact/1` (incl. URL-userinfo) — `lib/jido_claw/security/redaction/patterns.ex:29`
- `JidoClaw.Security.Redaction.Env.sensitive_key?/1` — `lib/jido_claw/security/redaction/env.ex:83`
- `JidoClaw.Tenant.Manager.get_tenant/1` — `lib/jido_claw/platform/tenant/manager.ex:89` (also the GenServer-owned-ETS template for `RequestCorrelation.Cache`)
- `JidoClaw.SignalBus.{emit/2, subscribe/1}` — `lib/jido_claw/core/signal_bus.ex:48,74`
- `JidoClaw.ToolContext.{build/1, child/2}` — used by every dispatch site for correlation scope
- AgentTracker / Stats subscription pattern — `lib/jido_claw/agent_tracker.ex:87-106` (template for Recorder)
- Cross-tenant `before_action` reference impl — `lib/jido_claw/solutions/resources/solution.ex:486` (use this exact shape; error string `"cross_tenant_fk_mismatch"`)
- `Workspaces.Workspace`'s `identity_wheres_to_sql` block — `lib/jido_claw/workspaces/resources/workspace.ex:30-33` (template for Message's two partial identities)
- `mix jidoclaw.migrate.solutions` / `export.solutions` — `lib/mix/tasks/jidoclaw.{migrate,export}.solutions.ex` (CLI shape templates)

## Verification

End-to-end, after Phase G:

1. `mix ecto.reset && mix setup` — fresh DB.
2. `mix jidoclaw` — REPL boots, send `"list files in lib/"`. The agent should run a tool.
3. `psql jido_claw_dev -c "SELECT role, sequence, request_id IS NOT NULL FROM messages ORDER BY sequence"` — confirm `:user`, `:assistant`, `:tool_call`, `:tool_result` rows interleave correctly by sequence; `request_id` populated on tool/reasoning rows. Critically: `:assistant.sequence > :tool_result.sequence` for the same request.
4. `psql jido_claw_dev -c "SELECT role, length(content) FROM messages WHERE content LIKE '%[REDACTED%'"` — confirm redaction is firing where applicable.
5. From the REPL: trigger an exception in a tool (e.g. read a missing file). Assert the resulting `:tool_result` row's metadata envelope shows `status: :error` with the canonical error shape; agent loop did not stall.
6. Restart the BEAM mid-session (`Ctrl-C` twice + `mix jidoclaw` again). The `Session.Worker` for that session no longer exists, so `history/2` would return `[]`. Use the new cold-cache form: `JidoClaw.history(tenant_id, session_id_external, workspace_id: cwd, kind: :repl)` — assert it returns the prior turns. Send a new message; confirm the conversation resumes coherently (the worker boots, calls `set_session_uuid`, hydrates `state.messages` from Postgres). Then kill the Recorder GenServer mid-call: emit a `Signal.ToolResult` from a test harness with the same `request_id`; assert the resulting Message row carries the correct `(session, tenant, workspace, user)` (RequestCorrelation Postgres fallback worked + Cache rehydrated).
7. Move an existing `.jido/sessions/<tenant>/*.jsonl` set into a fresh DB and run `mix jidoclaw.migrate.conversations`. Confirm row count matches line count and `Conversations.Session.next_sequence` is `max(sequence) + 1`.
8. Run `mix jidoclaw.export.conversations --tenant default --session <external_id>` against the migrated session. Diff exported JSONL against original — sanitized rows should be byte-equivalent; manifest should list the dropped roles.
9. `mix test` — full suite green, including new acceptance gates.
10. `mix compile --warnings-as-errors`.
11. `mix ash.codegen --check` — clean (no resource drift).

## Out of scope / deferred

- Real Ash tenants — `tenant_id` stays a text column until Phase 4.
- FTS `search_vector` GIN index on `Message.content` — optional Phase 3/4 follow-up; not needed for §2.7 gates.
- Standardizing the existing `Conversations.Session` cross-tenant error string — leave at `"cross-tenant FK mismatch"` for now (separate change).
- Reasoning content sourced from anywhere other than `ai.llm.response.result.thinking_content` — extend Recorder if a future strategy emits reasoning differently.
- Solution-side message standardization (Solutions already uses `"cross_tenant_fk_mismatch"`).
- Routing assistant writes through the Recorder via `ai.request.completed` — appealing because it eliminates the flush barrier and unifies the persistence path, but depends on the signal carrying the final answer payload (currently undocumented). Defer; revisit after measuring the flush-barrier latency in practice.
- Switching `InfraSupervisor` to `:rest_for_one` — simpler than the Recorder's `Process.monitor` re-subscription dance, but invasive (affects every InfraSupervisor child). Defer.
- Sharding the Recorder by `session_id` — single GenServer should suffice for v0.6; revisit if mailbox depth becomes a problem under load.

## Open assumptions worth confirming during implementation

- The flush barrier (`Recorder.flush()` before assistant write) keeps assistant rows after their tool/reasoning rows ONLY because (a) `Jido.Signal.Bus` is configured `partition_count: 1` (see step 15 caveat) AND (b) tool signals are emitted from the same OS process that hosts the agent (the `Jido.AgentServer` cast path). If a future strategy emits tool signals from a separately-supervised Task without the cast-back, the barrier won't help — the AgentServerPlugin won't see those signals at all. Today's strategies (ReAct + the directive layer) all cast back; verify before extending to other strategies.
- `ai.request.completed` and `ai.request.failed` are emitted exactly once per request. If a strategy re-emits, the Recorder's correlation deletion would fire twice — second delete is a no-op, but worth a regression test.
