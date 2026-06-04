# Finish & Verify T2-5 — Schedule Kind Switch (+ cron hardening)

## Context

`docs/exploration/jidoka/FEATURES-WORTH-BORROWING.md` lists **T2-5 Schedule kind switch** as PARTIAL
(status line **2026-05-26**). That status is **stale**: the execution-target axis
(`target :: :agent | :workflow | :mfa`) shipped in commit `77d852c` (2026-05-31, 1688 lines + tests).
The `Cron.Job` resource, `Cron.Dispatcher`, `run_count`/`last_run_at` counters, worker plumbing, the
`ScheduleTask` tool, and the cron test suite all exist and route correctly.

Verifying the shipped feature surfaced three real defects in the cron subsystem this plan also fixes:

1. **Cron schedules fire in UTC.** `worker.ex:194` hardcodes `DateTime.from_naive!(naive, "Etc/UTC")`,
   so `"0 9 * * *"` runs at 09:00 **UTC** (= 05:00 ET for this user). The load-bearing fix.
2. **Dead stuck-detection.** The `worker.ex` moduledoc claims "Stuck detection at 2 hours," but the
   `:check_stuck` handler can never fire (no timer schedules it, status is never set `:running`, and
   synchronous dispatch blocks the GenServer during a tick). Misleading dead code — removed.
3. **Cron telemetry can't identify the dispatch path.** `emit_cron_*` carry only `job_id`/`tenant_id`
   (and exception drops even `tenant_id`). Worse, `target` alone is misleading: `mode: :system_job`
   routes to MFA *before* `target` is read, so the memory consolidator (`mode: :system_job`,
   `target` defaulting to `:agent`) would report `target: :agent` while running MFA.

Greenfield — no data/path back-compat concerns.

---

## 1. Resolve the T2-5 ADOPTED-vs-deferral conflict (doc rule, line 22)

The doc's strict rule: any *deferral within the borrowed capability* keeps an entry PARTIAL. Resolution
= **narrow T2-5's borrowed capability** so the un-done items are explicitly *out of scope*, not deferred:

- **T2-5 borrowed capability (→ ADOPTED):** the execution-target dispatch axis
  (`:agent | :workflow | :mfa`), per-job durability counters (`run_count`/`last_run_at`) across
  dispatch targets, and —
  closing the UTC-only bug found during adoption — **timezone-aware cron firing**. (Durability =
  **per-job counters across dispatch targets**, not per-kind.) All shipped by this plan.
- **Explicitly NOT borrowed from Jidoka's `schedule/2` (out of scope, with rationale):**
  - `overlap: :skip | :allow` + `skip_count` — cannot occur under synchronous single-worker dispatch
    (a busy worker can't re-tick; the next `:tick` just queues). N/A by architecture.
  - schedule history retention — low value; workflow-target runs are already recorded as `WorkflowRun`.
- **Operational notes (not Jidoka features, so not "deferrals" of the borrow):**
  - stuck-detection — removed here (dead code); a real watchdog needs async dispatch (future work).
  - multi-tenant boot-reload — single-user/`"default"`-tenant deployment; not wired for other tenants.

This satisfies the rule: the *borrowed capability* has no in-scope deferrals.

---

## 2. Timezone-aware cron scheduling (core fix)

**2a. Wire the tz database.** `time_zone_info` 0.7 is already in the tree (transitive via `jido`),
ships `priv/data.etf` (v2026b, 370 KB), defaults to `update: :disabled` (no network/fs), boots via its
own OTP app. Wiring:
- `config/config.exs` — `config :elixir, :time_zone_database, TimeZoneInfo.TimeZoneDatabase` (near the
  `:phoenix, :json_library` line ~269; loaded in all envs via the trailing `import_config`, so `:test`
  gets it).
- `mix.exs` deps — add `{:time_zone_info, "~> 0.7"}` explicitly with a comment (decouples from jido's
  dep tree; already resolved, so `deps.unlock --unused` keeps it).

**2b. New pure module `lib/jido_claw/cron/next_run.ex`** with a **hard crontab boundary** (the lib
returns `{:ok, naive}` *and can raise* — e.g. `@reboot` parses but the scheduler raises):
```elixir
@spec compute_next_cron_utc(String.t(), String.t(), DateTime.t()) ::
        {:ok, DateTime.t()} | {:error, :invalid_expression | :unknown_timezone | :calc_error}
def compute_next_cron_utc(expression, tz, now_utc \\ DateTime.utc_now()) do
  with {:ok, local_now} <- to_local(now_utc, tz),     # DateTime.shift_zone -> :unknown_timezone
       {:ok, cron}      <- parse(expression),          # try/rescue Parser.parse -> :invalid_expression
       {:ok, next}      <- next_naive(cron, DateTime.to_naive(local_now)) do  # explicit to_naive
    resolve_local_to_utc(next, tz)
  end
end
```
- `parse/1` and `next_naive/2` each wrap the crontab call in `try/rescue` (and `catch`), unwrap
  `{:ok, _}`/`{:error, _}`, and map anything else to `:invalid_expression` / `:calc_error` — never
  propagate a raise.
- `resolve_local_to_utc/2` interprets the naive result as wall-clock in `tz` via `DateTime.from_naive/2`:
  `{:ok, dt}` use it; `{:ambiguous, first, _}` → `first` (fall-back); `{:gap, _, just_after}` →
  `just_after` (spring-forward); else `:calc_error`. Finish `DateTime.shift_zone!(dt, "Etc/UTC")`.
- `"Etc/UTC"` short-circuits without the db (Elixir's `UTCOnlyTimeZoneDatabase` exception), so
  default-tz jobs are byte-identical to today.

**2c. Worker (`lib/jido_claw/platform/cron/worker.ex`).** Add `:timezone` to the struct
(default `"Etc/UTC"`) + read it in `init/1`. Replace the `:cron` branch of `schedule_next/1`:
- `{:ok, dt}` → `delta = DateTime.diff(dt, DateTime.utc_now(), :millisecond)`; **log a warning when
  `delta < 0`** (don't silently mask a miscalc), then `Process.send_after(self(), :tick, max(delta, 1000))`.
- `{:error, _}` (any of `:invalid_expression | :unknown_timezone | :calc_error`) → these are
  deterministic, permanent config errors → `Logger.error` + **`persist_disabled(state)`** +
  `status: :disabled` (see §6).

**2d. Resource (`lib/jido_claw/cron/resources/job.ex`).** Add `timezone` attribute (`:string`,
`default("Etc/UTC")`, `allow_nil?(false)`, `public?(true)`) near the schedule attributes (~line 200).
Add `:timezone` to the `:upsert` `accept` (84-97) and `upsert_fields` (69-82).

**2e. Migration + snapshot.** `mix ash.codegen add_cron_timezone` (snapshots in
`priv/resource_snapshots/repo/cron_jobs/`) → `timezone text NOT NULL DEFAULT 'Etc/UTC'`. No backfill.

**2f. Scheduler hydration (`scheduler.ex`).** In `build_persistent_opts/1` (~66-82), add
`timezone: job.timezone` to the opts.

**2g. `ScheduleTask` tool (`tools/schedule_task.ex`).** Add an optional `timezone` field to the schema;
validate via `match?({:ok, _}, DateTime.now(tz))` (strict, in the style of `parse_target/1`); thread
into `Scheduler.schedule/2` opts + `Job.upsert` attrs; mention it in `success_message/1`. **The field
doc and success message must state that `timezone` only affects cron-expression schedules — it is inert
for `every <interval>` and absolute `:at` schedules** — so users don't expect it to shift interval or
absolute-time behavior.

**2h. `ListScheduledTasks` tool (`tools/list_scheduled_tasks.ex`).** Append a `| tz: <zone>` segment to
the formatted line (`:33`), **non-UTC only** (mirrors the CLI `/cron` display; `Scheduler.list_jobs/1`
worker state carries `:timezone` after §2c). Use the same non-UTC `format_tz/1` shape as the CLI.

---

## 3. Cron telemetry: real dispatch target + mode + tenant_id

**3a. Single source of truth in `Dispatcher` (`dispatcher.ex`).** Extract a pure `dispatch_target/1`
and route `dispatch/1` through it (preserves the exact matrix: `:system_job` precedence, no mfa-present
fallback — `dispatcher_test.exs` stays green):
```elixir
@spec dispatch_target(map()) :: :agent | :workflow | :mfa
def dispatch_target(%{mode: :system_job}), do: :mfa
def dispatch_target(%{target: :workflow}), do: :workflow
def dispatch_target(%{target: :mfa}), do: :mfa
def dispatch_target(_), do: :agent

def dispatch(state) do
  case dispatch_target(state) do
    :mfa -> run_mfa(state); :workflow -> run_workflow(state); :agent -> run_agent(state)
  end
end
```

**3b. Worker metadata (`worker.ex` `execute_job/1`).** Build one metadata map and reuse it for
start/stop/exception:
```elixir
meta = %{job_id: state.id, tenant_id: state.tenant_id, mode: state.mode,
         target: state.target, dispatch_target: Dispatcher.dispatch_target(state)}
```
This makes the consolidator correctly report `dispatch_target: :mfa`. Fix
`emit_cron_exception(%{job_id: state.id}, :error)` → `emit_cron_exception(meta, :error)` so exceptions
carry `tenant_id`. The `telemetry.ex` emit fns pass metadata through unchanged (optionally document the
expected keys in their `@doc`). `Trace.Collector` doesn't tap cron events — no collector work.

**3c. Metrics tags (`core/telemetry.ex:42-45`).** The four cron `Telemetry.Metrics` defs
(`counter`/`summary` for start/stop/duration/exception) currently have **no tags**, so raw
`:telemetry` handlers would see `dispatch_target` but metrics dashboards would not. Add
`tags: [:mode, :target, :dispatch_target]` to those four defs (precedent: the consolidator metrics at
`:48-62`). Tags resolve because §3b puts those keys on every cron event's metadata. (Decision: metric
tags **are** in scope — they're what make the §3 enrichment usable in dashboards, not just raw taps.)

---

## 4. Remove the dead stuck-detection

`worker.ex`: delete the `handle_info(:check_stuck, _)` clause (106-119), the `@stuck_threshold_ms`
attribute (16), and the unreachable `:stuck`/`:running` references; correct the moduledoc (drop the
stuck claim; keep "auto-disables after 3 consecutive failures"). Leave a one-line comment that a real
watchdog requires async dispatch (deferred).

---

## 5. CLI cron surface (`lib/jido_claw/cli/commands.ex`)

The `/cron add` + `/cron` path is separate from the `ScheduleTask` tool. Make it consistent:
- **Validate the cron expression before scheduling** (fixes a race with §6): `/cron add` schedules the
  worker *then* persists, and `parse_cron_schedule/1` never validates the expression — so an invalid
  cron starts a worker (whose `persist_disabled/1` no-ops because the row doesn't exist yet) and then
  persists an **active bad row** (which only converges after two more boots). Change
  `parse_cron_schedule/1` to validate via `Crontab.CronExpression.Parser.parse/1` and return
  `{:ok, tuple} | {:error, reason}`; `add_cron_job/4` schedules + persists only on `{:ok, _}`, else
  `print_cron_schedule_error/1`. Matches the agent tool's validate-before-persist discipline.
- **Remove the stale `cron_status_icon(:stuck)` clause** (1672) — the catch-all `cron_status_icon(_)`
  remains for anything unknown.
- **Display timezone** in `print_cron_job/1` (1654-1664): append `tz: #{job.timezone}` **only when
  non-UTC** (keeps default output clean; worker state carries `:timezone` after §2c).
- **Default handling**: `add_cron_job/3` + `persist_cron_job/4` omit `timezone`, so the resource
  default (`"Etc/UTC"`) and worker default apply — correct UTC behavior, no change needed.
- **Rich `/cron add` timezone input is explicitly deferred** (the positional `/cron add <id>
  "<sched>" <task>` syntax has no tz slot). The timezone-aware entry point is the `schedule_task`
  agent tool; document this in the plan and the `/cron` help text. (If you want a `/cron add … tz=…`
  token, say so and I'll add the parse.)

---

## 6. Persist `disabled_at` on permanent config errors (point 5)

Today an invalid-cron worker sets in-memory `status: :disabled` but never persists it, so the bad row
reloads (and re-disables) every restart. Fix at the worker: on any `NextRun` error (§2c) and on the
existing invalid-`{:cron, …}` path, call the existing best-effort `persist_disabled/1` (worker.ex:215;
looks up by `job_id`, calls `Job.disable`, rescues all errors). Since `for_tenant` filters
`is_nil(disabled_at)`, the row is excluded on the next boot — converges in one cycle. (Called from
`init/1`'s `schedule_next`, but `persist_disabled/1` rescues, so a DB hiccup at startup can't crash the
worker.) Hydration's existing skip-invalid-schedule behavior is unchanged — one fix site.

---

## 7. Update the exploration doc

`docs/exploration/jidoka/FEATURES-WORTH-BORROWING.md`:
- Rewrite **T2-5** → **ADOPTED** (today's date) using the narrowed scope from §1: describe the shipped
  target axis + durability counters + timezone-aware firing + target-aware telemetry + stuck-detection
  removal; add the explicit "NOT borrowed (out of scope)" and "operational notes" lists.
- Update the bottom **Tier 2 sequencing** bullet (currently "T2-5 … can ship anytime").

---

## 8. Tests

- **New `test/jido_claw/cron/next_run_test.exs`** (pure, pin `now_utc`): UTC byte-identical regression
  vs the legacy `from_naive!(_, "Etc/UTC")` path; `"0 9 * * *"` in `America/New_York` → `13:00Z` (EDT)
  and `14:00Z` (EST); spring-forward gap (`"0 2 * * *"`, 2025-03-09) → after-gap instant; fall-back
  ambiguous (`"0 1 * * *"`, 2025-11-02) → first occurrence; `Australia/Sydney` sanity; unknown tz →
  `:unknown_timezone`; invalid expr → `:invalid_expression`; `@reboot` (raises) → `:calc_error`.
- **`test/jido_claw/cron/dispatcher_test.exs`** — add `dispatch_target/1` unit cases for the full
  matrix incl. `mode: :system_job` + `target: :workflow` → `:mfa` (precedence).
- **`test/jido_claw/tools/schedule_task_test.exs`** — valid `timezone` persists; invalid errors;
  omitted → `"Etc/UTC"`.
- **`test/jido_claw/cron/job_test.exs`** — `timezone` round-trips via `:upsert`; default applies.
- **Telemetry test** — attach a `:telemetry` handler; assert start/stop/exception metadata carries
  `tenant_id`, `mode`, `target`, `dispatch_target`. **Include a `mode: :system_job` case asserting
  `dispatch_target: :mfa`** (locks the effective-target fix).
- **Config-error persistence** — a worker started with an unknown timezone (or invalid expr) calls
  `Job.disable` (assert `disabled_at` set); reuse `cron_test_support.ex` patterns.
- **Worker integration (shallow)** — boot a worker with `timezone: "America/New_York"`; assert
  `next_run` is the correct UTC instant.
- **Display (tool + CLI)** — a non-UTC job renders `tz: …` in `ListScheduledTasks`; a UTC job omits it.
- **CLI invalid-cron rejection** — `/cron add` with a malformed expression neither schedules a worker
  nor persists a row (no active bad row left behind).

---

## Reused building blocks

- `Crontab.CronExpression.Parser.parse/1` + `Crontab.Scheduler.get_next_run_date/2` (takes a reference
  `NaiveDateTime`; can raise — wrapped in `NextRun`).
- `TimeZoneInfo.TimeZoneDatabase` — `Calendar.TimeZoneDatabase` impl, data pre-shipped.
- `JidoClaw.Cron.Job.upsert/2` / `.disable/2` (job.ex:50,55) — persist + disable paths.
- `JidoClaw.Cron.Scheduler.schedule/2` + `build_persistent_opts/1` — hot-path + reload seams.
- `JidoClaw.Cron.Worker.persist_disabled/1` (worker.ex:215) — best-effort disable persistence (reused
  for config errors).
- `JidoClaw.Authorization.Actor.system/1` — actor for `Job` writes.

---

## Verification (definition of done)

Run via **mise** (OTP 28.5 — shell-default OTP 29 forces a failing dep recompile):

1. `mise exec -- mix ash.codegen add_cron_timezone` — generate migration + snapshot; eyeball the
   migration (single `timezone` column, NOT NULL, default `'Etc/UTC'`).
2. `mise exec -- mix ecto.migrate`.
3. `mise exec -- mix precommit` — the gate, in order: `compile --warnings-as-errors`,
   `jidoclaw.system_prompt.check`, `deps.unlock --unused`, `format`, `credo --strict`,
   `dialyzer --format short`, `test` (runs `ash.setup --quiet` first). **All must pass.**
   - If `system_prompt.check` fails from a `schedule_task`/`.jido` drift, sync per AGENTS.md
     (`priv/defaults/system_prompt.md` → `.jido/system_prompt.md`).
   - Watch dialyzer on `NextRun`'s tagged-tuple spec, `Dispatcher.dispatch_target/1`, and the worker's
     `:timezone` field.
4. Iterate: `mise exec -- mix test test/jido_claw/cron/ test/jido_claw/tools/schedule_task_test.exs`.
5. Manual smoke (`mise exec -- mix jidoclaw`): `/cron add … "0 9 * * *" …` (UTC default, shown clean);
   schedule via the agent `schedule_task` with `timezone: "America/New_York"`; confirm `/cron` shows
   the tz and the computed `next_run` is the correct UTC instant; `Cron.Worker.trigger/2` to fire.
