# Phase 2 — Conversations: chat transcripts in Postgres

**Goal:** retire the JSONL writer, capture full-fidelity transcripts
(user, assistant, tool calls, tool results, reasoning) in Postgres,
and give the consolidator a real query surface to work from.

## 2.1 `Conversations.Message` resource

```
lib/jido_claw/conversations/resources/message.ex
```

| Attribute | Type | Notes |
|---|---|---|
| `id` | uuid | primary key |
| `session_id` | uuid (FK Conversations.Session) | required |
| `tenant_id` | text | required; denormalized from the session row by a `before_action` so reads can filter without a join (per §0.5.2). |
| `sequence` | bigint | monotonic per-session ordinal; assigned at write time. See "Per-session ordering" below. |
| `role` | atom (one_of: `:user`, `:assistant`, `:tool_call`, `:tool_result`, `:reasoning`, `:system`) | richer than today's user/assistant binary |
| `content` | text | redacted at write |
| `tool_call_id` | text, nullable | matches a tool_call's id; FK-by-string for now. Combined with `request_id` and `role` for the partial unique identity that prevents duplicate tool rows from re-published signals (see Identities below). |
| `request_id` | text, nullable | The strategy-level request identifier (e.g. ReAct's `request_id` from `runtime_signal_metadata`). First-class column rather than buried in `metadata` because the Recorder (§2.3) keys on it for parent-row lookup and uniqueness, and Phase 3 retrieval/audit queries filter by it. Required on `:tool_call`/`:tool_result`/`:reasoning` rows; nullable on user/system rows. |
| `run_id` | text, nullable | The per-iteration run identifier from the same metadata source. Same rationale as `request_id`; recorded for fault-tracing across iterations of the same request. |
| `parent_message_id` | uuid (FK self), nullable | for chain-of-thought / tool result threading |
| `model` | text, nullable | model identifier for assistant turns |
| `input_tokens`, `output_tokens` | integer, nullable | cost telemetry |
| `latency_ms` | integer, nullable | end-to-end latency |
| `metadata` | map | tool name, error context, residual signal data not promoted above |
| `import_hash` | text, nullable | content-derived dedup key for legacy JSONL imports; null on live traffic |
| `inserted_at` | utc_datetime_usec | append-only, no `updated_at`. Declared as a plain `attribute :inserted_at, :utc_datetime_usec, default: &DateTime.utc_now/0, allow_nil?: false, writable?: true` rather than the standard `create_timestamp` macro — `create_timestamp` ships with `writable? false` (`deps/ash/lib/ash/resource/dsl.ex:54-77`), which would block the `:import` action below from setting historical timestamps from the JSONL. The `:append` action explicitly omits `inserted_at` from its accept list, so live traffic still gets the default; only `:import` is allowed to set it. |

Identities:
- `unique_import_hash` on `[import_hash]`, partial
  (`WHERE import_hash IS NOT NULL`) — used by the JSONL migrator
  for idempotent re-runs (see 2.5). Needs a
  `postgres.identity_wheres_to_sql` entry — see the cross-cutting
  "partial identities" note.
- `unique_session_sequence` on `[session_id, sequence]` — enforces
  the per-session monotonic ordering invariant. Total identity
  (no `where`), so no `identity_wheres_to_sql` entry needed.
- `unique_live_tool_row` on `[session_id, request_id, tool_call_id, role]`,
  partial (`WHERE request_id IS NOT NULL AND tool_call_id IS NOT
  NULL AND role IN ('tool_call', 'tool_result')`). Prevents
  duplicate `:tool_call` / `:tool_result` rows when the Recorder
  receives the same signal twice (e.g. strategy + directive layer
  both publish, or after a Recorder restart that races a re-emitted
  result). Without this, looking up the parent `:tool_call` by
  `tool_call_id` alone is fragile across sessions and reruns. Needs
  a `postgres.identity_wheres_to_sql` entry — see the cross-cutting
  "partial identities" note.

Indexes:
- `(tenant_id, session_id, sequence)` — primary read pattern;
  tenant-scoped per §0.5.2. `sequence` is monotonic by
  construction so it doubles as a chronological key.
- `(session_id, inserted_at)` — kept as a secondary index for
  time-window queries that don't care about strict per-session
  order (e.g. "messages since 1h ago across all sessions").
- `(request_id, role)` — Recorder's parent-lookup path:
  finding the `:tool_call` parent for an arriving `:tool_result`,
  or the most recent `:reasoning` row for a request.
- `tool_call_id` — chase tool result back to call (kept for the
  legacy lookup; the partial identity above is the authoritative
  uniqueness guarantee).
- `parent_message_id` — chain traversal.
- Optional FTS: `search_vector` GIN on `content` for `conversation_search`
  in Phase 3 / Phase 4.

Actions:

- `create :append` — live-traffic write. Accepts `session_id`,
  `role`, `content`, `tool_call_id`, `request_id`, `run_id`,
  `parent_message_id`, `model`, `input_tokens`, `output_tokens`,
  `latency_ms`, `metadata`. Does **not** accept `inserted_at`,
  `sequence`, `tenant_id`, or `import_hash` — `inserted_at` falls
  through to the attribute default; `sequence` is assigned by the
  per-session-ordering `before_action` (live-only, see below);
  `tenant_id` is denormalized from the session row by another
  `before_action` (caller can't spoof it); `import_hash` is null
  on live traffic.
- `create :import` — JSONL migrator only. Accepts everything
  `:append` does plus `inserted_at`, `sequence`, `tenant_id`, and
  `import_hash`. The migrator passes a deterministic per-session
  `sequence` derived from JSONL file order (see 2.5), so the same
  ordering invariant applies to imported and live rows alike.
  The auto-sequence `before_action` **does not run** on `:import`
  — the action validates the caller-supplied `sequence` against
  `[session_id, sequence]` uniqueness (the `unique_session_sequence`
  identity catches collisions) and a non-negative-integer guard;
  `Session.next_sequence` is bumped exactly once per session at
  the end of the import batch, not per row, so concurrent live
  `:append`s during/after the migration pick up where the import
  left off (§2.5 step 4). Reasoning: a per-row hook would
  silently overwrite the migrator's deterministic JSONL ordering
  with a counter-derived value, breaking historical chronology
  and breaking idempotency on rerun (every replay would
  re-allocate fresh sequences). Marked `accept` rather than
  `default_accept` so it's clear at the resource that this is
  the privileged-import surface; the CLI tools / web surfaces
  don't expose it.

  A `before_action` hook validates the §0.5.2 cross-tenant FK
  invariant: it fetches the `Conversations.Session` row matching
  `session_id` inside the action transaction and rejects the
  create with `:cross_tenant_fk_mismatch` when
  `session.tenant_id != changeset.tenant_id`. The `:append`
  action denormalizes `tenant_id` *from* the session row, so the
  invariant trivially holds; `:import` accepts both
  caller-supplied — the migrator pieces `tenant_id` together
  from the host tenant resolution while pulling `session_id`
  from the JSONL filename (which itself reflects the legacy
  per-`project_dir` directory layout). A misaligned migrator
  command (`mix jido_claw.migrate.conversations --tenant=foo`
  pointed at sessions that resolve to tenant `bar`) would
  otherwise land a whole tenant's transcript history under the
  wrong tenant boundary; the validate-equality hook stops the
  batch on the first mismatched row.
- `read :for_session` — orders by `sequence` ASC.
- `read :since_watermark` — used by the consolidator's load query
  in 3.15 step 2.
- `read :by_tool_call`.
- `read :by_request` — args `request_id` (and optionally `role`).
  Used by the Recorder for the parent-row lookup that backs
  `parent_message_id` on `:tool_result` rows; replaces the previous
  `tool_call_id`-only lookup that was fragile across reruns.

**Per-session ordering.** `inserted_at` alone — even at
`utc_datetime_usec` resolution — is not sufficient to order a
session's transcript. The Phase 2.3 Recorder publishes
`:tool_call`/`:tool_result` rows from a separate process than the
Session Worker that publishes user/assistant rows; concurrent
inserts from different processes routinely collide on the
database clock, and sorting by `id` (UUIDv4) on ties yields stable
but not chronological order. `parent_message_id` partly mitigates
this for the tool-call ↔ tool-result subset, but does nothing for
the interleaving of user/assistant/reasoning rows.

The `sequence` column is assigned via a `before_action` hook on
`:append` only — `:import` is the **caller-supplied-sequence
path**, see the action note above. The hook uses an **atomic
counter on the session row**, not an aggregate over `messages`.
`Conversations.Session` gains a `next_sequence` bigint column
(default `1`) — see §0.4 — and the per-message live-write hook
runs the following inside the action's transaction:

```sql
UPDATE conversations_sessions
SET next_sequence = next_sequence + 1
WHERE id = $session_id
RETURNING next_sequence - 1 AS sequence;
```

The `UPDATE … RETURNING` is a single atomic step: Postgres takes a
row-level write lock on that session row for the duration of the
enclosing transaction, increments the counter, and returns the
pre-increment value. Two concurrent appends to the same session
serialize on the row lock; each gets a distinct `sequence` and the
loser of the race waits at most one transaction's worth of writes
(typically microseconds). Appends to different sessions don't
contend.

Why not `SELECT COALESCE(MAX(sequence), 0) + 1 FROM messages WHERE
session_id = $1 FOR UPDATE`? Earlier drafts used that shape, but
PostgreSQL **rejects locking clauses on aggregate queries**:
`SELECT MAX(...) ... FOR UPDATE` raises *"FOR UPDATE is not
allowed with aggregate functions"*
([Postgres SELECT docs, "Locking Clauses"](https://www.postgresql.org/docs/current/sql-select.html#SQL-FOR-UPDATE-SHARE)).
Even if it executed, it would lock the qualifying *messages* rows
(not a session row), giving no protection on the first append to a
session — the first writer's `WHERE session_id = $1` matches zero
rows so there's nothing to lock, and a concurrent second writer
would compute the same `MAX + 1`. The atomic counter on the session
row sidesteps both issues.

`Session.next_sequence` is initialised to `1` on `create :start`. The
import migrator (§2.5) does **not** mutate `next_sequence` per row —
the auto-sequence `before_action` is `:append`-only, so per-row
import writes leave the counter untouched. After all rows for one
session have been imported, the migrator does a single `Ash.update`
setting `next_sequence = max(sequence) + 1` (§2.5 step 6), so live
writes that arrive afterwards never collide with imported rows.

Read paths use `sequence` where chronology matters within a
single session: `for_session` orders by `sequence` ASC, the JSONL
importer assigns sequences in file order, and the consolidator's
clustering pass (3.15 step 3) groups by `session_id` and orders by
`sequence` so the LLM sees `:tool_call` rows before their
matching `:tool_result` rows even when both committed within the
same microsecond.

The consolidator's *watermark* in 3.9 stays
`(inserted_at, id)`, because the watermark needs a single global
key over messages from many sessions in the same scope; tracking
a per-session sequence map on `ConsolidationRun` would multiply
the watermark schema by the session count without buying anything
the contiguous-prefix invariant doesn't already provide.
`inserted_at` also remains for cross-session telemetry queries
(e.g. "messages per hour across all sessions").

## 2.2 Replace `Session.Worker.add_message/4`

`JidoClaw.Session.Worker` becomes a thin wrapper that calls
`Conversations.Message.append!/1`. The in-memory `messages` list is
kept for the GenServer's lifetime (cheap context for active session)
but the source of truth moves to Postgres.

`handle_continue(:load, state)` re-hydrates from Postgres via
`Message.for_session/1` instead of streaming the JSONL.

## 2.3 Capture tool calls and reasoning at write time

The agent loop currently increments `Stats.track_tool_call/2` and
renders pending tool calls but never persists. Persistence has to
live at a layer every surface shares — `display_new_tool_calls/2`
(`lib/jido_claw/cli/repl.ex:310`) is REPL-only and polls the agent
status snapshot, so hooking it would silently miss every
`JidoClaw.chat/4` caller (`web/controllers/chat_controller.ex`,
`web/channels/rpc_channel.ex`, `platform/channel/discord.ex`,
`platform/channel/telegram.ex`, `platform/cron/worker.ex`) and could
double-write rows when the poll catches a call that's already been
flushed.

Capture instead at the layer that already carries `tool_call_id`
end-to-end *and* the result payload. The available observation
points and what each provides:

1. `[:jido, :action, :start|:stop]` from `Jido.Action.Exec.do_run/4`
   (deps/jido_action/lib/jido_action/exec.ex:430). Carries `action`,
   `params`, `context` — but `tool_call_id` is not in the context.
   `Jido.AI.Turn.run_single_tool/4`
   (deps/jido_ai/lib/jido_ai/turn.ex:707) extracts `call_id`
   locally and never injects it before `execute/4`. **Unreliable
   without a dependency patch.**
2. `[:jido, :ai, :tool, :execute, :start|:stop|:exception]` from
   `Jido.AI.Turn.start_execute_telemetry/3`
   (deps/jido_ai/lib/jido_ai/turn.ex:621). Reads
   `context[:call_id]` — same `nil` problem as (1).
3. `[:jido, :ai, :tool, :start|:complete|:error|:timeout]` from
   `Jido.AI.Reasoning.React.Strategy.emit_runtime_telemetry/8`
   (deps/jido_ai/lib/jido_ai/reasoning/react/strategy.ex:2310).
   Metadata reliably carries `tool_call_id`, `tool_name`,
   `agent_id`, `request_id`, `run_id`, `iteration`, `model`. **But
   the result payload is not in the metadata** —
   `emit_tool_completed_telemetry/4` (strategy.ex:2375) only uses
   the result to *route* between `tool(:complete)` /
   `tool(:error)` / `tool(:timeout)` and discards it. So this
   tells us *that* a tool finished and *what id* it had, but not
   *what content* the result was. Insufficient on its own for
   full-fidelity transcript persistence.
4. `Jido.AI.Signal.ToolStarted` (`ai.tool.started`) and
   `Jido.AI.Signal.ToolResult` (`ai.tool.result`), emitted by the
   ReAct strategy at strategy.ex:1620 and 1647 (and by the
   directive layer at directive/tool_exec.ex:416 and 431, plus
   directive/emit_tool_error.ex:63). Both signals carry
   `call_id`, `tool_name`, and `metadata` populated by
   `runtime_signal_metadata(request_id, run_id, iteration,
   :tool_execute)`, but **the payload field differs**:
   `ToolStarted` carries `arguments` (the tool input — see
   `deps/jido_ai/lib/jido_ai/signals/tool_started.ex`),
   while `ToolResult` carries `result` (the full payload
   including the raw tuple — see
   `deps/jido_ai/lib/jido_ai/signals/tool_result.ex`).
   **This is the hook for content on both sides of the call** —
   but only after we add an explicit bridge (see below).

**Bus bridging.** These signals are not on `JidoClaw.SignalBus`
today. Each emission point — strategy.ex:1468, directive/tool_exec.ex:423,
directive/tool_exec.ex:438, directive/emit_tool_error.ex:72 — calls
`Jido.AgentServer.cast(self(), signal)` (or the equivalent agent
pid cast), which lands the signal in the AgentServer mailbox and
routes through the agent's internal router. Nothing publishes to
`JidoClaw.SignalBus`. `JidoClaw.Agent` also does not set
`default_dispatch`, so the `Jido.Signal.Dispatch` fallback path is
never engaged either (see `deps/jido/lib/jido/agent_server/directive_executors.ex:22-24`).

The Recorder needs an explicit bridge. The chosen approach:

- Add a `JidoClaw.AgentServerPlugin.Recorder` plugin (using the
  `Jido.Plugin` `handle_signal/2` callback at
  `deps/jido/lib/jido/agent_server.ex:1957-2000`) that intercepts
  `ai.tool.started`, `ai.tool.result`, and the ReAct progress
  signals on the agent's own routing path. The plugin forwards each
  matched signal to `JidoClaw.SignalBus.emit/2` (the existing API
  at `lib/jido_claw/core/signal_bus.ex:48`), then returns
  `{:ok, :continue}` so the agent's existing routing is untouched.
  Plugins are invoked from `do_process_signal/4`
  (`deps/jido/lib/jido/agent_server.ex:1731-1732`), which runs on
  every inbound `cast` — including the inbound paths used by
  strategy.ex:1468 and the directive layer — so every tool signal
  is captured.
- **The plugin must be added to every `use Jido.AI.Agent`
  block individually.** Earlier drafts of this plan claimed
  workers (`workers/coder.ex`, etc.) "inherit the plugin via its
  `use Jido.AI.Agent` macro options" from `JidoClaw.Agent` — that
  is incorrect. Inspection of the codebase
  (`lib/jido_claw/agent/agent.ex:2`,
  `lib/jido_claw/agent/workers/coder.ex:2`) confirms each module
  has its own `use Jido.AI.Agent, ...` block with its own options;
  there is no inheritance from `JidoClaw.Agent`. As-is,
  `anthropic_prompt_cache` is wired only on the main agent and
  every worker template's tool calls would silently bypass the
  Recorder. The Phase 2 implementation must (a) add the plugin
  configuration to every existing `use Jido.AI.Agent`
  declaration: `JidoClaw.Agent` plus
  `workers/{coder, docs_writer, refactorer, researcher, reviewer,
  test_runner, verifier}.ex`; and (b) provide a thin
  `JidoClaw.Agent.Defaults` macro or shared options module that
  callers can splice in to avoid drift. The acceptance gate in
  §2.7 grep-enforces "every `use Jido.AI.Agent` site lists the
  Recorder plugin," which mirrors the §0.7 tool-context coverage
  check.

The Recorder GenServer then subscribes to `ai.tool.*` and
`ai.react.*` topics on `JidoClaw.SignalBus` at supervisor start.
On `ai.tool.started` it writes a `:tool_call` `Message`, populating
`request_id`, `run_id`, and `tool_call_id` from the signal
metadata, plus storing the signal's `arguments` field through the
JSON-safe envelope normalizer (§2.4) into the row's `metadata`
column (redacted per §2.4). The `content` column gets a one-line
summary (`"#{tool_name}(args…)"`) so existing FTS / display paths
still read meaningfully without unwrapping the envelope. On
`ai.tool.result` it writes a `:tool_result` row carrying the
signal's `result` payload — also normalized + redacted —
with `parent_message_id` resolved via the
`Message.read :by_request` action filtering on
`(session_id, request_id, tool_call_id, role: :tool_call)` — not
`tool_call_id` alone. Three reasons the call_id-only lookup the
earlier draft proposed was fragile: (1) call_ids are unique per
request but not globally unique across reruns, so a cold-start
restore that re-emits a stored call_id could collide with an
older row; (2) the strategy and directive layers both emit
`Signal.ToolResult` for the same call in some paths, so a
duplicate started signal could write a sibling `:tool_call` row
with the same call_id; (3) without `request_id` in the WHERE
clause, a session that runs the same tool twice across separate
requests with overlapping lifetimes can match the wrong parent.
The `(session_id, request_id, tool_call_id, role)` partial unique
identity from §2.1 prevents the duplicate row insert in (2) and
the indexed `(request_id, role)` lookup makes the parent fetch
O(log n).

The result payload flows through the JSON-safe envelope
normalizer (§2.4) and is redacted before persistence.

Why a plugin rather than configuring `default_dispatch`: the
`%Directive.Emit{}` codepath that consumes `default_dispatch`
(directive_executors.ex:8-37) is the *outbound* path used when an
action explicitly emits a signal as a directive. The inbound `cast`
path used by the strategy at strategy.ex:1468 never visits that
code, so setting `default_dispatch` would not catch tool signals.
A plugin's `handle_signal/2` runs on every signal the AgentServer
processes, regardless of how it arrived.

**Session correlation.** Neither the runtime telemetry nor the
runtime signals carry `tool_context` — they only have
`request_id` / `run_id`. So the Recorder needs a side mapping from
`request_id → {session_uuid, tenant_id, workspace_uuid, user_id}`,
maintained durably so a BEAM restart mid-request doesn't strand
in-flight tool signals. Implementation: a two-tier cache backed
by Postgres, **not ETS-only**.

A new Ash resource `JidoClaw.Conversations.RequestCorrelation`:

| Attribute | Type | Notes |
|---|---|---|
| `request_id` | text, primary key | Application-generated by the dispatcher; matches the value the runtime signals carry as `metadata.request_id`. |
| `session_id` | uuid (FK Conversations.Session) | required |
| `tenant_id` | text | required (per §0.5.2) |
| `workspace_id` | uuid (FK Workspaces.Workspace), nullable | populated when `tool_context` carried it |
| `user_id` | uuid (FK Accounts.User), nullable | populated for authenticated surfaces |
| `inserted_at` | utc_datetime_usec | |
| `expires_at` | utc_datetime_usec | `inserted_at + idle_timeout_seconds + slack` (default ~10 min); see TTL eviction below. |

Indexes: `request_id` is the PK (covers the Recorder lookup);
`(expires_at)` btree powers the TTL sweep;
`(tenant_id, expires_at)` btree for tenant-scoped operator
queries (the §0.5.2 leading-`tenant_id` shape applies here
too).

Actions: `create :register` accepts `request_id`, `session_id`,
`tenant_id`, `workspace_id`, `user_id`, `expires_at`. A
`before_action` enforces the §0.5.2 cross-tenant FK invariant
across `session_id` and `workspace_id` — both have tenanted
parents, both must match `changeset.tenant_id`. `user_id` is
skipped per the §0.5.2 untenanted-parent rule (Accounts.User
spans tenants by design). The dispatcher writes one
RequestCorrelation per agent invocation; without the validation
hook, a buggy `tool_context` resolver could create a
RequestCorrelation under tenant A whose Session is in tenant B,
and every signal that arrives later would be Recorded against
the wrong tenant — the `Conversations.Message` rows the Recorder
writes denormalize tenant_id from the correlation, so a
mistenanted correlation propagates straight into the transcript.

`destroy :complete` and `destroy :sweep_expired` are the only
delete paths — both bypass the cross-tenant validation (no FK
change), but the destroy itself filters
`tenant_id = caller.tenant_id` via Ash policy so a request from
tenant A cannot delete tenant B's correlation row even when both
are alive concurrently.

ETS in front, Postgres behind, with the same shape:

- **At dispatch time** (`JidoClaw.chat/4` and every other
  `Agent.ask`/`ask_sync` site updated in §0.5.1), the caller
  generates the `request_id` it will pass to the agent and
  **writes both** an ETS entry (`:public, :named_table` —
  `JidoClaw.Conversations.RequestCorrelation.Cache`) and a
  `RequestCorrelation` row in a single helper call. The Postgres
  insert happens before the agent receives the request, so any
  signal the agent emits is guaranteed to find the row.
- **The Recorder reads ETS first** (microsecond lookup, no DB
  round-trip on the hot path) and **falls back to a
  `RequestCorrelation` Postgres lookup** when the ETS row is
  missing — full BEAM restart, hot code reload, or a Recorder
  process crash all clear ETS but leave the durable row intact.
  After a successful Postgres lookup the Recorder rehydrates the
  ETS entry so subsequent signals on the same request hit the
  cache.
- **TTL eviction.** When the corresponding
  `request_completed` / `request_failed` / `request_cancelled`
  signal arrives, the Recorder deletes both the ETS entry and the
  `RequestCorrelation` row. Crashed runs that never emit a
  terminal signal are swept by a periodic worker that deletes
  rows where `expires_at < now()` (default sweep interval 60
  seconds; bounded `LIMIT` per tick so a backlog drains
  gracefully).

This is preferable to "patch jido_ai to thread `tool_context`
through `Runtime.Event` and `runtime_signal_metadata`" because
the patch surface would need to touch every strategy module
(ReAct, Tree-of-Thoughts, Chain-of-Thought), and a small Ash
resource is local to JidoClaw. Earlier drafts described falling
back to `Conversations.Session.metadata`, but nothing in the
dispatch path actually wrote to it — the
`RequestCorrelation` resource closes that gap with an explicit,
testable persistence contract.

For reasoning steps (model thinking turns), subscribe to the
existing ReAct progress signals on the `SignalBus` and write
`:reasoning` rows threaded by `parent_message_id`. The same
correlation table resolves `session_uuid`.

If the signal path proves insufficient (e.g., a future strategy
doesn't emit `Signal.ToolResult`), the **fallback** is a minimal
`deps/jido_ai` patch to inject `tool_context` into
`runtime_signal_metadata`. A patch we'd then have to carry across
upgrades — but acceptable if forced.

This is the "transcript enrichment" decision from the New tensions
section; doing it here means the consolidator in Phase 3 can learn
from "we tried X, Y didn't work, Z worked."

## 2.4 Tool-payload normalization and redaction at write

Tool result payloads on `ai.tool.result` arrive as the raw 3-tuple
`{:ok, value, effects}` or `{:error, reason, effects}` (see
`deps/jido_ai/lib/jido_ai/directive/tool_exec.ex:387-408`). `value`
and `reason` can be any Elixir term — atoms, tuples, structs, nested
combinations of all three. Postgres `jsonb` (which is what
`Message.metadata` is in Ash) cannot encode tuples, will refuse
structs that don't implement `Jason.Encoder`, and silently
stringifies atoms in ways that lose round-trip fidelity. So
persistence runs in two stages: **normalize first, then redact**.

**Stage 1: `JidoClaw.Conversations.TranscriptEnvelope.normalize/1`.**
Converts an arbitrary tool result tuple into a JSON-safe map with
this canonical shape:

```elixir
%{
  status: :ok | :error,                # always present
  value: term | nil,                   # JSON-safe value on :ok; nil on :error
  error: %{type: atom, message: text, # populated on :error; nil on :ok
           details: term | nil},
  effects: [term],                     # JSON-safe; defaults to []
  raw_inspect: text | nil              # set ONLY when normalization had to
                                       # fall back; an Elixir-formatted dump
                                       # of whatever couldn't be encoded
}
```

Normalization rules, applied recursively to `value`, `error.details`,
and each entry in `effects`:

- **Atoms:** convert to string with a `:` prefix preserved (e.g.
  `:ok` → `":ok"`) so re-reads can distinguish atoms from strings
  if needed; safe atoms (`true`, `false`, `nil`) become their JSON
  primitives.
- **Tuples:** convert to a tagged map
  `%{__tuple__: [normalized_elements]}`. Round-trippable; explicit
  about being a non-JSON shape.
- **Structs with `Jason.Encoder`:** encode and decode through
  `Jason` to get a pure map, then recurse.
- **Structs without `Jason.Encoder`:** stringify with `inspect/2`
  (limit `:infinity`, `pretty: false`) into `raw_inspect` and set
  the corresponding slot to `nil`. The envelope's `raw_inspect`
  field is never set otherwise, so its presence is the signal that
  data was lossy.
- **Maps, lists:** recurse into values/elements.
- **Strings, numbers, booleans, nil:** pass through.
- **Anything else** (PIDs, references, functions, ports): same
  fallback as structs without encoder.

**Stage 2: `JidoClaw.Security.Redaction.Transcript.redact/1`** runs
on the normalized envelope. The full module specification — the
recursive rules over strings/maps/lists, sensitive-key detection
via `Redaction.Env.sensitive_key?/1`, and provider-specific JSON
unwrapping — lives in §1.4 alongside the URL-userinfo pattern
extension to `Redaction.Patterns`, because Phase 1's Solution
write path already consumes both. Phase 2 contributes the
**call-site**: applied at the `Message.append`/`:import` boundary
to `content`, `metadata`, and any tool-result payloads before
persistence.
`Message.role: :tool_result` rows store the redacted envelope as
`metadata` (jsonb), with `content` set to a one-line summary
(`"#{tool_name} → ok"` or `"#{tool_name} → error: #{type}"`) so
existing FTS / display paths that read `content` still work
without unwrapping the envelope.

Original (unredacted) content is **not** preserved anywhere — once
redacted, it's gone. This is intentional: the cost of leaking a key
into Postgres outweighs the cost of losing an unredactable string.

## 2.5 Migration: JSONL → Postgres

```
mix jido_claw.migrate.conversations
```

1. Walk `.jido/sessions/<tenant>/*.jsonl`. The `<tenant>` path
   segment is the source of truth for `tenant_id` — preserve it
   verbatim (no defaulting to `"default"`). `Conversations.Session.tenant_id`
   is still a text column in v0.6.0–v0.6.3 (real Ash tenant
   resources don't land until Phase 4), so the migrator does
   **not** require an Ash tenant row to exist; the string is
   stored as-is. As a sanity check the migrator can call
   `JidoClaw.Tenant.Manager.get_tenant/1` against the existing
   ETS table and warn (not skip) when the tenant string isn't
   registered there, so users can reconcile before Phase 4
   converts the column to an FK.
2. Parse each filename to derive `(kind, external_id)`:
   - `session_<timestamp>.jsonl` → `(:repl, "session_<timestamp>")`
   - `discord_<channel_id>.jsonl` → `(:discord, "discord_<channel_id>")`
   - `telegram_<chat_id>.jsonl` → `(:telegram, "telegram_<chat_id>")`
   - `cron_<job_id>_<ts>.jsonl` → `(:cron, "cron_<job_id>_<ts>")`
   - `api_<int>.jsonl` / `api_stream_<int>.jsonl` → `(:api, <as-is>)`
   - any other shape → `(:imported_legacy, <basename without .jsonl>)`,
     with `:imported_legacy` added to §0.4's `kind` enum for this
     purpose. Falling back to `:api` (as earlier drafts did) would
     conflate genuine API sessions with anything that doesn't
     match a known prefix; tagging unknowns explicitly preserves
     the post-Phase-0 invariant that `kind` reflects an actual
     surface and lets the v0.6.4 sweep find imported rows that
     need reclassification.

   The `<tenant>` segment from step 1 supplies `tenant_id`. The
   parser table here is the **only** prefix-inference path in the
   plan; live writes through `chat/4` always carry an explicit
   `:kind` per §0.5.1, so the migrator is the one place where
   prefix parsing is unavoidable (legacy JSONL filenames have no
   sidecar metadata).
3. Resolve the workspace before the session: legacy JSONL doesn't
   carry a `project_dir`, so use `WorkspaceResolver.ensure/1` with
   `File.cwd!()` as the fallback (matches today's `JidoClaw.chat/3`
   behavior at `lib/jido_claw.ex:29`). Then call
   `SessionResolver.ensure_session/4` with
   `(tenant_id, workspace.id, kind, external_id)` — the Phase 0.4
   identity is `[tenant_id, workspace_id, kind, external_id]`, so
   all four are required to look up or insert idempotently. The
   migrator surfaces the `cwd` assumption in its CLI output so
   users with multi-workspace JSONL archives can override.
4. Stream lines from the JSONL **in file order**; for each, call
   `Message.import/1` (the writable-timestamp action defined in
   2.1) with `role`, `content`, derived `inserted_at` from the JSONL
   timestamp, and `sequence` set to the running counter for that
   session (1-based; the importer maintains a `%{session_id =>
   next_seq}` map across the stream). The JSONL on disk is already
   in append order, so the file order is the chronological order;
   using a monotonic counter rather than rederiving from
   `inserted_at` avoids ambiguity on ties. Compute an
   `import_hash = SHA-256(session_id || sequence || role ||
   inserted_at_ms || content)` and store it in a top-level
   `import_hash` attribute on `Message` (text, nullable —
   live-traffic rows leave it null). Including `sequence` in the
   hash is what prevents idempotency from collapsing into
   accidental dedup: two legitimate identical replies in the same
   session at the same millisecond (e.g., a user sending "ok"
   twice in quick succession, or two `:tool_call` rows for the
   same tool in a single turn) would collide on a hash that
   omitted `sequence` and one would be silently dropped on
   import. With `sequence` in the hash the importer remains
   idempotent (re-runs find the same `(session, sequence)` and
   skip on the partial unique identity) without lossy
   deduplication.
5. Idempotency key: a partial unique identity
   `unique_import_hash` on `[import_hash]` gated on
   `WHERE import_hash IS NOT NULL`. Ash identities take attribute
   names, not JSONB paths — burying the hash inside `metadata`
   would force a `custom_indexes` raw-SQL unique index that Ash's
   upsert/conflict resolution wouldn't see, so the migrator
   couldn't use `Ash.Changeset.upsert/2` to skip on collision.
   Plain `inserted_at` is millisecond-resolution
   (`platform/session/worker.ex:93`) and bursty traffic can produce
   ties within a session; legacy JSONL has no row id to preserve, so
   a content-derived hash is the only stable dedup key.
6. **After all rows for a session are imported**, update the
   session row exactly once: `Session.next_sequence = (max
   imported sequence) + 1`. Done as a single `Ash.update` outside
   the per-row loop, not as a per-row hook (the per-row auto-
   increment hook is `:append`-only per §2.1). This is what makes
   live writes that arrive after migration pick up at the right
   ordinal — without it, the first live `:append` post-migration
   would clash with imported `sequence` values on the
   `unique_session_sequence` identity. On a re-run that imports
   zero new rows (every row's `import_hash` already exists), the
   bump is a no-op because `max(sequence)` doesn't move.

JSONL files are **not deleted** during migration. They become a backup
that can be removed by hand after verification.

## 2.6 Decommissioning

- `JidoClaw.Session` legacy module (`platform/session.ex` —
  `save_turn`/`load_recent`) removed; it's already dead code.
- `Worker.append_to_jsonl/3` removed.
- `Worker.load_from_jsonl/2` removed.
- `Worker.jsonl_dir/1` and `jsonl_path/2` removed.

## 2.7 Acceptance gates

- New REPL session creates `Conversations.Session` + `Message` rows.
- Discord traffic populates `Message` rows including tool calls and
  results.
- Existing `JidoClaw.history/2` API preserved (now reads Postgres).
- Migrated transcripts retain full content and ordering.
- Redaction confirmed on the obvious patterns via test fixtures.
- **Recorder plugin coverage**: a CI check (or AST traversal under
  `lib/`) lists every `use Jido.AI.Agent` declaration and asserts
  each one configures the Recorder plugin (matching the §0.7
  tool-context coverage shape). Known sites: `JidoClaw.Agent`,
  `Workers.Coder`, `Workers.DocsWriter`, `Workers.Refactorer`,
  `Workers.Researcher`, `Workers.Reviewer`, `Workers.TestRunner`,
  `Workers.Verifier`. New worker templates added later must satisfy
  the same check. Without this gate, swarm children's tool calls
  silently bypass persistence and transcripts lose fidelity exactly
  where it matters most.
- Concurrent tool-result signals from a single call_id (e.g. both
  the strategy and directive layers publishing) result in exactly
  one `:tool_result` row per `(session_id, request_id,
  tool_call_id, role)` — verified by an integration test that
  emits the same `Signal.ToolResult` twice and asserts the second
  insert is rejected by the partial unique identity.
- **Recorder correlation survives a process restart.** Dispatch a
  request through `JidoClaw.chat/4`; assert the
  `RequestCorrelation` row is in Postgres before the agent emits
  its first tool signal. Stop and restart the Recorder GenServer
  (clearing its ETS cache); emit a `Signal.ToolResult` with the
  same `request_id`; assert the resulting `Message` row carries
  the correct `session_id`, `tenant_id`, `workspace_id`, and
  `user_id` — the fallback found the durable row and rehydrated
  ETS. Without the §2.3 `Conversations.RequestCorrelation`
  resource (rather than the earlier broken
  `Session.metadata` fallback), this test fails by emitting an
  uncorrelated `Message`.
- **TTL sweep eviction.** Insert a `RequestCorrelation` row with
  `expires_at = now() - 1` (manually backdated); run the sweep;
  assert the row is gone. Then dispatch a fresh request; emit its
  terminal `request_completed` signal; assert both the ETS entry
  and the Postgres row are deleted in the same operation.
- A `:tool_call` row's `metadata` envelope contains the tool's
  `arguments` (sourced from `Signal.ToolStarted.arguments`); the
  paired `:tool_result` row's `metadata` envelope contains the
  `result`. A regression test runs a tool end-to-end and asserts
  both shapes — without it the Recorder could silently lose call
  inputs (the original draft confused which signal carries which
  payload).
- An import-hash collision test: two identical `:user` JSONL
  entries written within the same millisecond import as two
  separate Message rows (different `sequence`, different
  `import_hash`), not one. Verifies the §2.5 sequence-in-hash fix.
- **Cross-tenant FK validation regression test for `:import`.**
  Create two Sessions under distinct tenants (`Sess_a` in tenant
  A, `Sess_b` in tenant B). Invoke `Conversations.Message.import`
  with `tenant_id: A` but `session_id: Sess_b.id`. Assert the
  action fails with `:cross_tenant_fk_mismatch` and no row is
  written. The `:append` action's denormalized-from-session
  shape makes its own test trivially pass; the migrator path is
  the one that needs the gate.
- `mix jido_claw.export.conversations` round-trip, three
  fixtures (per the Phase summary "Rollback caveat" two-fixture
  contract, plus the existing dropped-roles case):
  - **Sanitized fixture** with only `:user`/`:assistant` rows
    and no strings matching §1.4 redaction patterns: byte-
    equivalent round-trip.
  - **Dropped-roles fixture** with `:tool_call` /
    `:tool_result` / `:reasoning` rows present: the
    user/assistant subset is byte-equivalent and the dropped
    roles appear in the
    `<file>.export-manifest.json` sidecar with the correct
    sequence numbers and roles.
  - **Redaction-delta fixture** that does contain matched
    secrets in `:user` / `:assistant` content: the export
    contains `[REDACTED]` exactly where the import-time
    `Redaction.Transcript.redact/1` observed a match,
    cross-checked against the export's redaction manifest.
- `mix ash.codegen --check` clean.
- `mix ash_postgres.generate_migrations` runs without
  `identity_wheres_to_sql` errors; Conversations.Message's
  partial identities carry the entries listed in §Cross-cutting
  concerns.
- Generated columns sanity (per §Cross-cutting "Generated columns"):
  the optional `Conversations.Message.search_vector` migration, if
  enabled, declares `GENERATED ALWAYS AS (to_tsvector(content))
  STORED`. (Memory.Fact's `search_vector` and `content_hash`
  generated-column gates land in §3.19.)

