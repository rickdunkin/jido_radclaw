# Plan: Fix stale compaction doc + borrow `schema_version` and inspection-summary fields from jidoka

## Context

A 2026-05-30 audit of `docs/exploration/jidoka/FEATURES-WORTH-BORROWING.md` against both codebases surfaced three follow-ups:

1. **`AGENTS.md` actively misdescribes shipped code.** Its "Context Compaction" bullet still says *"all 7 workers explicitly carry `compaction: [mode: :off]` on v1 … per-agent keying is deferred to v2."* Both halves are now false — the "Full Worker Compaction" commit moved every worker to `:auto` and shipped per-agent keying (this is what made the T1-2 feature ADOPTED). `CLAUDE.md` is just `@AGENTS.md`, so this is the one place project guidance contradicts reality.
2. **jidoka added a `schema_version` stamp to `%Trace.Event{}`.** jido_radclaw persists trace events to Postgres for durable replay (jidoka is in-memory only), so a version stamp on persisted rows is genuinely useful migration insurance for *us specifically*.
3. **jidoka's `Debug.summary` grew fields our `Inspection.Summary` lacks.** Per the audit, `model`, `status`, and `user_message` are genuinely sourceable in jido_radclaw; `mcp_errors`/`prompt_preview`/`prompt_sections`/`input_message`/`operation_names` are **not** (would be placeholders) and are explicitly out of scope. User chose to add **`model` + `status` + `user_message`**.

Outcome: project guidance matches reality, durable trace rows carry a version stamp, and the inspection surface tracks jidoka parity for the three fields we can source honestly. The exploration doc gets re-synced so the fix doesn't re-stale the file we just corrected.

---

## Change 1 — Rewrite the stale `AGENTS.md` compaction sentence

**File:** `AGENTS.md` (single bullet, currently line 83, last item under `### Key Patterns`). `CLAUDE.md` needs no edit.

**What to preserve (still accurate):** the `on_before_cmd/2` hook description, the main-agent `compaction: [mode: :auto, max_messages: 60, ...]` opener, the best-effort failure language, and the `RequestTransformer` description.

**What to replace** — only this clause:
> "The main `JidoClaw.Agent` uses `compaction: [mode: :auto, max_messages: 60, ...]`; all 7 workers explicitly carry `compaction: [mode: :off]` on v1 (workers share `session_uuid` and per-agent keying is deferred to v2)."

**Proposed replacement:**
> "The main `JidoClaw.Agent` and all 7 workers carry `compaction: [mode: :auto]`. Per-agent keying shipped: each agent compacts its own slice keyed by `JidoClaw.Reasoning.Compactor.Identity` (`"main"` for both main surfaces, `"handoff:<uuid>:<tpl>"` for a routed worker, the spawn tag for a sub-agent), with per-key snapshots persisted under `Session.metadata["compactions"][key]` (`key = "<identity>::<context_ref|default>"`) via atomic `jsonb_set`; spawned/handoff sub-agents get coherent durable transcripts via `JidoClaw.Conversations.SubagentTranscript`. (Real `context_ref` lanes remain a no-op follow-up — no producer currently sets `context_ref`, so keys normally trail `::default`, though the code accepts one if it appears in tool context.)"

**Verified facts behind it:** all 7 workers `:auto` (`lib/jido_claw/agent/workers/*.ex`); `Compactor.Identity.resolve/3` (`lib/jido_claw/reasoning/compactor/identity.ex`); `subagent` flag on `Conversations.Message` (`message.ex:353`); atomic `jsonb_set` in `Session` `:set_compaction_snapshot` (`session.ex:138`); `SubagentTranscript` (`lib/jido_claw/conversations/subagent_transcript.ex`); `context_ref` no-op (`compactor.ex:221-225`).

**Optional (not doing unless asked):** `lib/jido_claw/agent/defaults.ex:28-31` moduledoc frames `mode: :off` as the "no-op fallback" — still *technically accurate* (the fallback path exists), so leaving it. `compactor.ex:41-44` moduledoc is already correct.

---

## Change 2 — Add `schema_version` to `%JidoClaw.Trace.Event{}` (mirrors jidoka)

Reference shape: `jidoka/lib/jidoka/trace/event.ex` — `@schema_version 1`, `schema_version: pos_integer()` in the type, a `schema_version/0` function, and `schema_version: @schema_version` as a **defstruct default that is NOT in `@enforce_keys`**. Mirror this exactly.

| File | Change |
|---|---|
| `lib/jido_claw/trace/event.ex` | Add `@schema_version 1`; add `schema_version: pos_integer()` to `@type t`; add public `schema_version/0`; add `schema_version: @schema_version` to `defstruct`. **Do not** add to `@enforce_keys`. |
| `lib/jido_claw/trace/persistence.ex` | In `event_attrs/2` (~136-156) add `schema_version: event.schema_version || Event.schema_version()` — the struct default covers normal events; the `|| Event.schema_version()` guard prevents an explicit `nil` from ever being persisted. |
| `lib/jido_claw/trace/resources/trace_event.ex` | Add `attribute :schema_version, :integer do allow_nil?(true); default(1); public?(true) end`; add `:schema_version` to the `:append_event` action's `accept([...])` list (Ash drops un-accepted fields silently). |
| `lib/jido_claw/trace.ex` | In `durable_event_to_struct/1` (~343-362) map `schema_version: row.schema_version || 1` (NULL-coercion for pre-migration rows). |
| `priv/repo/migrations/<ts>_add_trace_event_schema_version.exs` + `priv/resource_snapshots/repo/trace_events/<ts>.json` | Auto-generated by the migration command (below). |

**No change needed** to `lib/jido_claw/trace/collector.ex` (`normalize_event/4`'s `%Event{...}` literal picks up the defstruct default automatically) or to `TraceRun`/`%JidoClaw.Trace{}` (per-event versioning is sufficient and is what jidoka does).

**Migration command** (this repo uses Ash-generated migrations exclusively — no `ash.codegen` precedent):
```
mise exec -- mix ash_postgres.generate_migrations add_trace_event_schema_version
mise exec -- mix ecto.migrate
```
Adds a nullable `:bigint default 1` column — an O(1) metadata-only op on Postgres ≥11, safe on a populated `trace_events` table.

**Gotchas:** (a) keep it out of `@enforce_keys` or every existing `%Event{...}` literal breaks; (b) the `row.schema_version || 1` coercion is required — without it, rehydrated old rows get `schema_version: nil`, contradicting the `pos_integer()` type and tripping dialyzer; (c) JSONB `measurements`/`metadata` come back string-keyed on rehydration — a pre-existing condition, not introduced here, but the reason the version stamp is worth having.

**Tests** (mirror jidoka's `trace_test.exs:74-75` shape):
- `test/jido_claw/trace_test.exs` — assert `Trace.Event.schema_version() == 1` and every ingested event carries `schema_version == 1`.
- `test/jido_claw/trace/persistence_test.exs` — extend the `round-trip` block to assert persisted rows carry `schema_version == 1`; extend the `Postgres fallback on for_request/3` block to assert rehydrated events carry it; add a "pre-migration row" test that **explicitly forces `schema_version` to `NULL`** (via raw SQL `UPDATE` or an Ash update bypassing the default — *not* by omitting the field on `append_event/2`, since `default(1)` would coerce an omitted input to `1` and the test would prove nothing) and asserts `Trace.for_request/3` rehydrates it as `1`, exercising the `row.schema_version || 1` coercion in `trace.ex`.

---

## Change 3 — Add `model`, `status`, `user_message` to `%JidoClaw.Inspection.Summary{}`

**Sourceability (audit-confirmed, no placeholders):**
- **`model`** — agent-state on live/definition paths (`strategy_opts[:model]` or `state.agent.state[:model]`), trace metadata on the request path. On the request path read it **string-key-safe**: `MapKeys.coalesce_field(event.metadata || %{}, :model)` (durable-rehydrated rows come back string-keyed, exactly as `inspection_test.exs:342` documents for measurements), with a fallback to `event.name` for `:model`-category events (the collector already stores the model label there). Note: definition/agent paths report the configured alias (e.g. `:fast`); the request path reports the resolved label that actually ran (e.g. `"claude-sonnet-4-5"`). Type as `String.t() | atom() | nil`.
- **`status`** — `trace.status` on trace-bearing paths; `nil` on module/`session_map` (no trace), exactly like `usage`/`duration_ms` already behave. Type as `atom() | String.t() | nil` — `Trace`'s `maybe_atom/1` falls back to the original string for unknown persisted statuses, so a rehydrated status can be a string.
- **`user_message`** — request path only: a sibling of `context_preview_for_request/4` filtering for `role: :user` instead of assistant; `nil` elsewhere.

| File | Change |
|---|---|
| `lib/jido_claw/inspection/summary.ex` | Add to `@type` and `defstruct` (all default `nil`): `model :: String.t() | atom() | nil`, `status :: atom() | String.t() | nil`, `user_message :: String.t() | nil`. |
| `lib/jido_claw/inspection.ex` | Populate across builders. **model:** add `model_from_module/1` (reads `strategy_opts[:model]`) for `module_summary`/`agent_id_summary`/`handoff_session_summary`/`plain_session_summary`/`session_map_summary`; read `state.agent.state[:model]` in `pid_summary` (reuse existing `safe_agent_state/1`), falling back to `model_from_module(module)` when live state is absent or malformed; add `model_from_trace/1` for `build_request_summary` — selects the **latest** `:model`-category event (`trace.events |> Enum.reverse() |> Enum.find(...)`, since a request may make multiple LLM calls / future per-turn model routing), reading `MapKeys.coalesce_field(event.metadata || %{}, :model)` with a fallback to `event.name`, mirroring how `usage_from_trace/1` already uses `coalesce_field` for string-keyed rehydrated rows; `nil` in `workflow_summary`. **status:** read `trace.status` wherever a trace is already fetched; `nil` otherwise. **user_message:** new helper paralleling `context_preview_for_request/4` (reuse `ConversationsMessage.by_request` + `@context_preview_limit` clamp), wired only into `build_request_summary`. |
| `lib/jido_claw/tools/inspect_agent.ex` | Add `model`/`status`/`user_message` to `output_schema` (`required: false`); in `project/1` project `model` and `status` through one shared **nil-preserving** helper `stringify_nilable/1` (`nil -> nil; v -> to_string(v)`) — bare `to_string/1` would emit `"nil"` at the MCP boundary, since `nil` is an atom. For `user_message`, reuse the existing `@context_preview_limit` clamp (don't duplicate length logic — centralize it so it can't drift from `context_preview`). All three are tenant-safe (the request path already does a tenant cross-check; `user_message` is the caller's own data, same hygiene profile as the already-exposed `context_preview`). |

**Reuse, don't reinvent:** `context_preview_for_request/4` and `@context_preview_limit` (user_message clamp); `usage_from_trace/1` (model_from_trace pattern); `safe_agent_state/1` (pid model); `module_from_tracker/1` (agent_id path); `JsonSafe.encode/1` and the `slim_*` pattern (MCP projection).

**Tests:**
- `test/jido_claw/inspection_test.exs` — extend module/agent_id/session dispatches to assert `model` from `strategy_opts`; extend the `inspect_request` happy-path to emit `model:` in metadata and assert `model`/`status`/`user_message`; confirm `model`/`status` stay `nil` on the workflow path. **Main regression guard (must-add):** a durable `inspect_request` test that directly seeds a `TraceRun` + a `:model` `TraceEvent` row with **string-keyed** `metadata: %{"model" => "claude-..."}`, then asserts `model_from_trace/1` resolves `model` after Postgres rehydration. Direct row seeding is preferred over forcing collector ring eviction — it avoids timing/ring-size noise; the essential assertion is just that string-keyed rehydrated metadata still resolves.
- `test/jido_claw/tools/inspect_agent_test.exs` — extend the JSON-safe-output test to assert the three new keys are present and string-or-nil.

---

## Change 4 — Re-sync the exploration doc

**File:** `docs/exploration/jidoka/FEATURES-WORTH-BORROWING.md` (so the file just corrected in the prior pass stays accurate):
- **T1-1 Event shape** — the note currently ends "…current Jidoka has since added a `schema_version` field … (jido_radclaw's has not)." Update: jido_radclaw now carries `schema_version` too (and *persists* it, which jidoka's in-memory design doesn't need).
- **T2-4 Summary shape** — bump the field list from 18 → 21 (`model`, `status`, `user_message`).
- **T2-4 "Where in jidoka" divergence note** — update: `model`/`status`/`user_message` are now shared; the remaining jidoka-only fields are `input_message`, `prompt_preview`, `prompt_sections`, `operation_names` (an alias of `tool_names`), and `mcp_errors` — the last left out deliberately because jido_radclaw has no MCP-error source to populate it without a placeholder.

---

## Verification

Run everything under `mise exec` (project pins OTP 28.5; shell-default OTP 29 forces a failing dep recompile):

1. **Migration first** (Change 2): `mise exec -- mix ash_postgres.generate_migrations add_trace_event_schema_version` then `mise exec -- mix ecto.migrate`. Inspect the generated migration adds a nullable `:bigint default 1`.
2. **Compile strict:** `mise exec -- mix compile --warnings-as-errors`.
3. **Format:** `mise exec -- mix format` (enforced).
4. **Targeted tests:** `mise exec -- mix test test/jido_claw/trace_test.exs test/jido_claw/trace/persistence_test.exs test/jido_claw/inspection_test.exs test/jido_claw/tools/inspect_agent_test.exs` (the suite auto-migrates the test DB via `ash.setup --quiet`).
5. **Full suite:** `mise exec -- mix test`.
6. **Optional live check via Tidewave:** eval `JidoClaw.Trace.Event.schema_version()` → `1`; emit a trace then `JidoClaw.inspect_request/2` to see `model`/`status`/`user_message`; `SELECT schema_version FROM trace_events LIMIT 5` to confirm the column populates.
7. **Docs (Changes 1 & 4):** no automated test — visual diff of `AGENTS.md` and the exploration doc.

**No git commit** unless explicitly requested — branch off `main` first if/when asked.
