# Code review follow-up: M7 + M8 + L9 (bounded durable storage) + report bookkeeping

## Context

All 16 HIGH findings and M1–M5 from `docs/reports/code-review-2026-06-10.md` are fixed. The report's own priority list (§ "Suggested priority order", item 6) names what's left: **M11/M12** "before the next data migration" and **M7/M8** "before long-running production use."

Exploration recalibrated that ordering:

- **M11 (cron `:at` re-fire)** is *worse than reported but latent*: after a one-shot fires, `schedule_next` re-arms the same past `dt` at delay 0 and the tick equality-matches again (`worker.ex:153-155, 244-248`) — a *successful* `:at` job would re-fire in a **tight infinite loop**, not just once per restart. However, **nothing produces `:at` jobs today**: `schedule_task` and `/cron add` emit only `:cron`/`:every`; only the DB-reload path can hydrate `{:at, dt}`. Footgun, not a live bug.
- **M12** (legacy v0.5.x migrator idempotency) is near-zero value for a greenfield deployment.
- **M7/M8/L9** are live in the prod-default configuration: every traced LLM request writes unbounded `trace_runs`/`trace_events` rows (`persist?: true` default), every workflow step persists full LLM text into `workflow_events.payload`, and replay re-persists arbitrarily large input blobs.
- **M6** turned out to be already fixed incidentally by `76328d3` (Live-Run Workflow Cancellation): `workflow_view.ex:15` now includes `:abandoned`, all four terminal sets agree, and the status enum (7 values) is fully covered. Docs-only.

**This plan fixes M7 + M8 + L9 and updates the report** (annotate M6 as fixed, M7/M8/L9 fix notes, M11 severity recalibration note). Theme: bounded durable storage before long-running use. Done = `mix precommit` passes.

---

## 1. M7 — Trace retention sweeper

Every event with `persist?: true` writes `trace_runs` + `trace_events` rows forever; no prune exists. Model the fix on the existing turnkey precedent: `lib/jido_claw/conversations/request_correlation/sweeper.ex` + the `:expired` read / `Ash.bulk_destroy` batch pattern in `lib/jido_claw/conversations/resources/request_correlation.ex` (`@sweep_batch 1_000`, full-batch → immediate re-`:sweep` drain, rescue/catch-guarded so a failure reschedules instead of crashing).

**Verified facts the design rests on:**
- Retention key is **`updated_at`** (last activity), not `inserted_at`: `TraceRun.upsert_run` is called by `Trace.Persistence.do_persist/2` on **every** event, and AshPostgres refreshes `update_timestamp` columns on any modifying upsert (each event carries a higher `incoming_last_seq`, so the `upsert_condition` passes). A long-lived active trace keeps a fresh `updated_at` and survives; a stale `:skipped_upsert` doesn't bump it.
- **No FK** between `trace_events` and `trace_runs` (plain tables in `20260519142518_add_trace_domain.exs`; `has_many :events` is a logical join on the `trace_id` string) → two-phase delete: events by `trace_id` (indexed) first, then run rows.
- Trace resources have **no authorizers** — a tenantless read spans all tenants (`global?(true)`), same as `Trace.history()` already does. Do **not** copy RequestCorrelation's policy block.
- No index serves `updated_at < ?` → add one.

**Changes:**

1. `config/config.exs` — add `retention_days: 30` to the existing `config :jido_claw, trace: [...]` keyword (~line 257-267), with a comment. Non-positive / non-integer / `nil` disables sweeping.
2. `lib/jido_claw/trace/resources/trace_run.ex`:
   - `custom_indexes`: add `index([:updated_at], all_tenants?: true)` — attribute-multitenant AshPostgres resources prepend the tenant attribute to custom indexes by default, which can't serve the sweeper's tenantless `updated_at < ?` scan; follow the `RequestCorrelation` precedent (`request_correlation.ex:90`).
   - Add a **named private destroy** — `destroy :sweep_delete do public?(false) end` — not a generic `:destroy` in `defaults`: keeps the maintenance path explicit and avoids widening the action surface on resources that intentionally have no authorizers.
   - Add `read :expired` action: `argument(:cutoff, :utc_datetime_usec)`, `filter(expr(updated_at < ^arg(:cutoff)))`, sorted `updated_at: :asc`. Query it via `Ash.Query.for_read(TraceRun, :expired, %{cutoff: cutoff}) |> Ash.Query.limit(@sweep_batch) |> Ash.read()` — stated explicitly; no `code_interface` define (the limit is applied at the query layer, so the `query_to_expired`-style helper from the precedent doesn't transplant 1:1).
   - Add `sweep_expired(cutoff)` module function returning **`{:ok, deleted_runs, more?}`** with **failure-safe ordering and progress-aware drain**:
     1. Read one batch (limit `@sweep_batch 1_000`) of expired runs; empty → `{:ok, 0, false}`.
     2. `Ash.bulk_destroy` their events (`TraceEvent` query filtered `trace_id in ^ids`, action `:sweep_delete`, `return_errors?: true`). **Anything but clean `:success` → log + `{:ok, 0, false}`** and do NOT delete the runs this round: deleting runs after a failed/partial event-delete would strand permanent orphan events (orphans are deliberately never swept) — retry on the next tick instead.
     3. Only then `Ash.bulk_destroy` the run records (same action/options). **Count `deleted_runs` from the batch, not from `BulkResult.records`**: with the default `return_records?: false`, `records` is `nil` (`deps/ash/lib/ash/bulk_result.ex`). Clean `:success` → `{:ok, length(batch), length(batch) == @sweep_batch}`; partial success → `{:ok, max(length(batch) - error_count, 0), false}` (progress recorded, but `more?` forced false).
     `more?` is true ONLY when a full batch was **cleanly deleted** — a repeatedly-failing full batch waits for the next hourly tick, never immediate-loops. (Pinned explicitly: the copied precedent returns `{:ok, count}` and compares `count >= @full_batch`, which is not progress-aware and would hot-loop on persistent delete failures — don't copy that shape.) Orphan events (run row missing) are deliberately not swept — Persistence writes the run before its events, and a re-upserted run re-covers its trace_id; note this in the moduledoc.
3. `lib/jido_claw/trace/resources/trace_event.ex` — add the same named private `destroy :sweep_delete do public?(false) end` (today it has `defaults([:read])` plus the `append_event` create only; `Ash.bulk_destroy` requires a destroy action to call).
4. **New** `lib/jido_claw/trace/retention_sweeper.ex` — GenServer copied from `RequestCorrelation.Sweeper`: hourly tick (`Process.send_after`), `more?` → immediate re-send `:sweep` drain, rescue+catch guard (carry the `# reach:disable-...bare_rescue` annotation style it uses), computes `cutoff = now - retention_days` from trace config at tick time; disabled config → no-op reschedule.
5. `lib/jido_claw/application.ex` — add `JidoClaw.Trace.RetentionSweeper` to `infra_children` (after `Trace.Collector`, near `RequestCorrelation.Sweeper`, ~line 164-168; only needs Repo, no ordering constraint — keep the inline comment style).
6. Migration: `mix ash.codegen add_trace_run_updated_at_index` → commit the generated migration + `priv/resource_snapshots/repo/trace_runs/` snapshot (`mix test` auto-applies via `ash.setup --quiet`).
7. **New** `test/jido_claw/trace/retention_sweeper_test.exs` — model on `test/jido_claw/trace/persistence_test.exs` (explicit `Ecto.Adapters.SQL.Sandbox.start_owner!(JidoClaw.Repo, shared: true)`, `async: false`, trace-config flip with `on_exit` restore — pin nested keyword config via merge per `Keyword.update`, not wholesale replacement). Backdate `updated_at`/`inserted_at` via raw `Repo.query!` UPDATE. Cover: expired run+events deleted; fresh rows survive; active-trace protection (old `inserted_at`, fresh `updated_at` survives); batch/drain behavior; disabled retention no-op; one tick-path test through the live GenServer.

## 2. M8 — Cap workflow event payload at append time

Full LLM-text step results land unbounded in `workflow_events.payload` (jsonb) and, via the raw-payload projection, in `WorkflowRun.result` / `WorkflowStep.output`.

**Single insertion point bounds all three sinks** — `lib/jido_claw/orchestration/workflow_event/changes/allocate.ex:101-110`: the after-action projection reads the **stashed raw payload** from changeset context. Use **two capped values with different ordering** — redaction must always see the full original, because truncating first can cut a long secret below the regex matcher threshold and persist an unredacted partial secret (see `security/redaction/patterns.ex`):

```elixir
raw_payload = Changeset.get_attribute(changeset, :payload) || %{}
raw_metadata = Changeset.get_attribute(changeset, :metadata) || %{}

# capped raw → context stash (bounds WorkflowRun.result / WorkflowStep.output,
# which store raw by design); redact-the-ORIGINAL-then-cap → persisted columns.
changeset
|> Changeset.set_context(%{
  workflow_event: %{current_status: run.status, raw_payload: capped(raw_payload)}
})
|> Changeset.force_change_attribute(:seq, next_seq(run_id, tenant, actor))
|> Changeset.force_change_attribute(:payload, raw_payload |> Transcript.redact() |> capped())
|> Changeset.force_change_attribute(:metadata, raw_metadata |> Transcript.redact() |> capped())
```

with `defp capped(map), do: OutputLimit.truncate(map, payload_leaf_cap())`. **`payload_leaf_cap/0` must normalize the env value**: return `Application.get_env(:jido_claw, :workflow_event_payload_max_bytes, 65_536)` only when it is a positive integer, else the default — a `nil` cap silently fails open (`byte_size(v) > nil` is `false` under Erlang term ordering, disabling truncation entirely) and a negative cap truncates everything to marker-only. (The projection stash needs no redaction — `result`/`output` intentionally store raw values; capping raw there is size-only and breaks nothing.)

- Reuse `JidoClaw.Tools.OutputLimit.truncate/2` (`lib/jido_claw/tools/output_limit.ex`): recursive per-leaf binary cap, UTF-8-safe (`valid_utf8_prefix/1` — satisfies the L3 concern), appends a marker. **Arch-rule verified:** `.reach.exs` only constrains `web`/`data` layers; orchestration is unconstrained, and `agent/handoff/router.ex:38` already aliases `OutputLimit` — no helper extraction, no module move. Accept the "[tool output truncated: …]" marker wording as-is (step results are tool/LLM output; an optional label param is out-of-scope churn).
- Per-leaf cap only (the stated threat is single large LLM-text leaves); small flag keys (`"irreversible"`, `:deadline`, statuses) pass through untouched — `Replay.check_irreversible` and recovery/retract are unaffected (recovery rebuilds nothing from payload text; resume state lives in the separate `resume_checkpoint` column — verified). **Accepted residual — document, don't fix:** this is a per-leaf bound, not a whole-payload budget; a payload of many under-cap leaves can still grow. State this in the cap-site comment and in the report's M8 fixed-note. Current payload shapes are single-large-leaf, so a whole-payload stub-replacement budget is deferred.
- **Do not change the secrets posture**: `WorkflowRun.result`/`WorkflowStep.output` intentionally store raw values gated by `public?(false)` + read-side `Visibility` redaction. This change only bounds size.
- `config/config.exs`: add `workflow_event_payload_max_bytes: 65_536` (64 KB — deliberately above the 32 KB tool cap, since a step legitimately aggregates multiple tool outputs) with a one-line comment.
- Tests in `test/jido_claw/orchestration/reactor_middleware_test.exs` (existing inline `Reactor.Step` machinery): flip the cap low via `Application.put_env` + `on_exit`; (a) huge step result → persisted `step_completed` payload leaf capped + marker; (b) `irreversible`/`deadline` keys untouched; (c) reloaded `WorkflowRun.result` capped too (proves the raw projection sink is bounded); (d) under-cap payload byte-identical, no marker; (e) **a secret straddling the cap boundary is fully redacted in the persisted event payload** (padding + secret positioned across the cut: cap-first would leave a partial-secret prefix that no longer matches the redaction regex — pins the redact-before-cap ordering); (f) cap-config normalization: with the env value set to `nil` or `-1`, an over-default-size leaf is still truncated at the 64 KB default (pins the fail-open footgun).

## 3. L9 — Guard the serialized replay-inputs blob

`lib/jido_claw/orchestration/reactor_runner.ex:249` encodes `{@replay_version, inputs, extra_context}` via `term_to_binary` straight into the encrypted `replay_inputs` column on **every** launch (cron, skills, replay — all funnel through `ReactorRunner.run/3`; grep-verified single writer). Replaying re-decodes and re-persists it — loopable amplification.

- **Over cap → omit the `:replay_inputs` key from the create attrs entirely; do NOT pass `replay_inputs: nil`.** AshCloak's `Encrypt` change encrypts any *present* argument — including `nil` — so passing nil would persist a small ciphertext-of-nil instead of SQL `NULL` (`deps/ash_cloak/lib/ash_cloak/changes/encrypt.ex:16`; cloak block at `workflow_run.ex:52-55`). Shape: `replay_inputs_attrs(name, inputs, extra_context)` returns `%{replay_inputs: blob}` or `%{}`, merged into the attrs map in the same position (below the dedupe read, inside the body-level rescue, preserving the never-raises envelope and the existing comment's intent).
- The helper: encode via `term_to_binary`; if `byte_size(blob) > cap` → `Logger.warning` and return `%{}`; else `%{replay_inputs: blob}`. The run id doesn't exist yet at this point, so the helper takes the already-bound `name` (run/3 line ~225) for the log line alongside blob size + cap. Cap from `Application.get_env(:jido_claw, :workflow_replay_inputs_max_bytes, 1_048_576)` (1 MB), **normalized the same way as the M8 cap** (positive integer or fall back to the default — a `nil` cap would make `byte_size(blob) > nil` false and never trip the guard; a negative one would strip replayability from every run).
- **The guard must never refuse the launch** — over-cap just means not replayable. An absent blob already surfaces through the existing refusal vocabulary with zero new code: `Replay.decrypt_inputs/3` (`replay.ex:261-262`) → `{:error, {:not_replayable, :no_inputs}}` → MCP `format_refusal` and the dashboard flash catch-all both render it. No new refusal detail (a distinct `:inputs_too_large` would require persisting a marker — deferred; the launch-time warning records why).
- `config/config.exs`: add `workflow_replay_inputs_max_bytes: 1_048_576` next to the M8 key.
- Tests in `test/jido_claw/orchestration/replay_test.exs`: cap flipped low; oversized inputs → run **completes**; the re-read row has **`encrypted_replay_inputs == nil`** (assert the raw column — proves SQL `NULL`, not ciphertext-of-nil; also assert the loaded `:replay_inputs` calculation is nil); `Replay.replay` refuses `{:error, {:not_replayable, :no_inputs}}` (`@tag :capture_log`). Plus a normalization regression: with the cap env set to `-1`, a normal launch still persists `replay_inputs` and replays fine (pins the fallback — a raw negative cap would strip replayability from every run). Existing happy-path replay tests double as the under-cap regression guard.

## 4. Report bookkeeping — `docs/reports/code-review-2026-06-10.md`

Follow the established per-finding annotation style:

- **M6**: mark "✅ fixed 2026-06-10 (incidentally, by `76328d3` Live-Run Workflow Cancellation)" — `:abandoned` is in `@terminal_statuses`; all four terminal sets (`workflow_view`, `workflows_live`, `reactor_middleware`, `replay`) agree and cover the full 7-value enum. Also note the original claim that `inspect_agent` was affected was inaccurate (it reads trace status, not WorkflowView).
- **M7, M8, L9**: add "✅ fixed 2026-06-11" notes describing the sweeper / append-time cap / blob guard, per the per-finding note convention. The M8 note must state the accepted residual (per-leaf bound, not a whole-payload budget) and the redact-before-cap ordering rationale; the L9 note must state the omit-key-vs-nil AshCloak subtlety.
- **M11**: add a recalibration note (no fix yet): the bug is worse than written — a fired `:at` job re-arms the same past window at delay 0 and the tick equality-matches again, so a *successful* one-shot re-fires in a tight loop within one process lifetime — but it is currently **latent**: no producer creates `:at` jobs (`schedule_task` and `/cron add` emit only `:cron`/`:every`; only DB reload hydrates `{:at, dt}`).
- Update "Suggested priority order" item 6 to tick off M7/M8 (+ L9, M6) and reflect the M11 note.

## Verification

1. Targeted: `mix test test/jido_claw/trace/retention_sweeper_test.exs test/jido_claw/orchestration/reactor_middleware_test.exs test/jido_claw/orchestration/replay_test.exs`
2. `mix ash.codegen --check` clean (snapshot + migration committed together).
3. **`mix precommit` must pass** (compile_check, system_prompt.check, deps.unlock --unused, format, reach.check --arch --smells --strict, credo --strict, dialyzer, full test suite) — the completion gate. Watch-items: match `Ash.BulkResult` statuses exactly (dialyzer); carry the sweeper precedent's reach `bare_rescue` annotation; no new tools, so `system_prompt.check` is unaffected.
4. Optional final step (only if asked): commit in the established style — `Code review M7 + M8 + L9 fixes` — staging only the files this plan touches.
5. Housekeeping once out of plan mode: save the review-feedback lessons to auto-memory — (a) redact before truncating in any redaction pipeline (truncation can cut a secret below the regex match threshold); (b) AshCloak encrypts *present* nil arguments — omit the key to get SQL NULL; (c) batch-drain loops must gate immediate re-run on actual clean progress, never on batch fullness alone.

## Recommended next batch (not in this plan)

M11 footgun defusal (one-shot `:at` lifecycle: disable-on-fire + skip-and-disable elapsed one-shots at reload, per the report's suggested fix — cheap committed tests included), then M17+L15 (sub-agent spawn supervision), then M14 (trace collector hot-path indexing).
