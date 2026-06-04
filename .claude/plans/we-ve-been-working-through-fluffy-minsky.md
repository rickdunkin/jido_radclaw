# Resolve Cron-Hardening Code-Review Findings

## Context

The "Schedule Kind Switch + cron hardening" plan shipped, then a code review surfaced three
follow-up defects. All three are **validated** against the current tree. This plan resolves them.
Definition of done: **`mix precommit` succeeds**, run via `mise exec` (compile `--warnings-as-errors` →
`jidoclaw.system_prompt.check` → `deps.unlock --unused` → format → `credo --strict` → dialyzer →
test). One caveat carried forward: the `deps.unlock --unused` stage is dep-lock hygiene unrelated to
this work and can trip on a pre-existing stale entry (e.g. `memento`) — see Verification.

Scope decisions confirmed with the user:
- **Validation fix** applies to **both** the CLI and the `schedule_task` tool.
- **Test fixture fix** applies to **all four** affected test files (the two flagged + two more with
  the identical latent race).

The load-bearing reuse is `JidoClaw.Cron.NextRun.compute_next_cron_utc/3`
(`lib/jido_claw/cron/next_run.ex`) — the same hard crontab boundary the worker already uses
(`worker.ex:202`). It wraps `Crontab.CronExpression.Parser.parse/1` **and**
`Crontab.Scheduler.get_next_run_date/2` in `try/rescue/catch`, returning
`{:ok, DateTime.t()} | {:error, :invalid_expression | :unknown_timezone | :calc_error}` — never
raising. `@reboot` parses but the scheduler raises → it maps to `{:error, :calc_error}`.

---

## Finding 1 (P2) — CLI `@reboot` slips past validation

`validate_cron/1` (`lib/jido_claw/cli/commands.ex:1619`) validates with `Parser.parse/1` only.
`Parser.parse("@reboot")` returns `{:ok, %CronExpression{reboot: true}}`, so `/cron add … "@reboot" …`
passes, starts a worker that disables itself (but `persist_disabled/1` no-ops because no DB row exists
yet), then the CLI persists an **active bad row**. (Second hole: `Parser.parse/1` can itself *raise* on
some malformed input, and the CLI path doesn't rescue it.)

**Fix** — route CLI validation through the same boundary as the worker:

```elixir
defp validate_cron(schedule) do
  case NextRun.compute_next_cron_utc(schedule, "Etc/UTC") do
    {:ok, _next_run} -> {:ok, {:cron, schedule}}
    {:error, reason} -> {:error, reason}
  end
end
```

- The CLI `/cron add` has no timezone input (always defaults to `"Etc/UTC"`), so validating against
  `"Etc/UTC"` is correct. `@reboot` → `{:error, :calc_error}` → `print_cron_schedule_error/1`; no
  worker started, no row persisted.
- **Alias bookkeeping (compile gate):** `Parser` is used *only* at `commands.ex:1620`. Remove
  `alias Crontab.CronExpression.Parser` (line 6) — leaving it unused fails `--warnings-as-errors`. Add
  `alias JidoClaw.Cron.NextRun` (alphabetically between `Cron.Job` (line 12) and
  `Cron.Scheduler` (line 13)).
- The `parse_cron_schedule("every " <> …)` branch (commands.ex:1606) parses intervals itself and never
  reaches `validate_cron/1` — unchanged.

**Tool (same class, narrower).** `schedule_task.ex`'s `parse_schedule(expr)` (line 236) requires
exactly 5 fields, so it already rejects `@reboot` (1 field) — but its cron branch (line 241) isn't
wrapped against `Parser` raises and doesn't verify computability. Keep the 5-field guard, swap the
inner check:

```elixir
defp parse_schedule(expr) do
  fields = String.split(expr)

  if length(fields) == 5 do
    case NextRun.compute_next_cron_utc(expr, "Etc/UTC") do
      {:ok, _} -> {:ok, {:cron, expr}}
      {:error, _} -> {:error, "invalid cron expression"}
    end
  else
    {:error, "expected a cron expression (5 fields) or 'every <interval>'"}
  end
end
```

- Keeps the existing error strings, so any existing assertion on `"invalid cron expression"` / the
  5-field message still passes.
- `Parser` is used only at `schedule_task.ex:241`. Remove `alias Crontab.CronExpression.Parser`
  (line 70); add `alias JidoClaw.Cron.NextRun`.

---

## Finding 2 (P3) — stale `:stuck` in the system prompt

`:stuck` was removed from the cron worker/scheduler/CLI/resource, but both prompt files still describe
it. The text is byte-identical in both:

- `priv/defaults/system_prompt.md:255` and `.jido/system_prompt.md:255`:
  `- No parameters. Returns all active, disabled, and stuck jobs.`
  → `- No parameters. Returns all active and disabled jobs.`

`list_scheduled_tasks` interpolates `job.status` directly (`list_scheduled_tasks.ex:33`), and the
worker only ever sets `:active` or `:disabled` — "active and disabled" is accurate.

- Edit **both** files identically (keeps them in sync; avoids a boot-time `.jido/…default` sidecar from
  `Prompt.sync/1`).
- The drift check `jidoclaw.system_prompt.check` only validates the `## Tool Catalog (N tools)` count
  and the `**tool_name**` entries against registered tools — it does **not** inspect prose and reads
  only `priv/defaults/`. This prose edit touches neither, so the precommit gate stays green.
- Edit **only** line 255's "active, disabled, and stuck jobs" text. Confirmed: both files have exactly
  two `stuck` mentions — line 255 (cron, fix this) and **line 414** ("Use kill_agent for agents stuck
  beyond 2 minutes"), which is valid agent guidance and must **not** be touched.

---

## Finding 3 (P3) — daily-cron fixture races worker auto-ticks

Tests use `"0 4 * * *"` as a "far-future" fixture, but a daily cron fires within 24 h, so a run near
04:00 UTC can auto-tick and (a) race explicit `Cron.Worker.trigger/2` telemetry assertions, or
(b) dispatch a real agent/workflow job.

**Critical constraint — do NOT use a far-future `:at` or a yearly cron.** `Worker.schedule_next/1`
arms an **unclamped** `Process.send_after(self(), :tick, delay)` (`worker.ex:191`, `:196`, `:212`).
`Process.send_after/3` raises above ~49.7 days (`4_294_967_295` ms). So `{:at, ~U[2099-01-01]}` or
`"0 4 29 2 *"` (next leap-year Feb 29, years out) would **crash worker `init`** and break `mix test` —
not sit idle. The fixture must fire **far enough out never to tick during a millisecond-scale test, yet
within the ~49-day ceiling.**

**Preferred fixture — a 1-day `:every` interval.** Its first (and only, within the test) tick is
exactly 1 day after the worker starts — independent of wall-clock time, so the time-of-day race is
*eliminated*, not merely reduced — and 1 day (8.64e7 ms) is ~50× under the timer ceiling. tz-display
assertions still hold: the `tz:` segment is gated on `tz != "Etc/UTC"`, **not** on schedule kind
(`list_scheduled_tasks.ex:46`, `commands.ex:1694`), and `format_schedule/1` already renders `:every`
(`list_scheduled_tasks.ex:50-53`).

**Exception — keep cron shape only where a test asserts it.** `commands_cron_test.exs:80` asserts
`schedule_kind == :cron`, so it must stay cron-shaped. Build the cron **dynamically at runtime** (not a
static fixture) from a time ~2 days out, so its next fire is always ~2 days away regardless of when the
test runs:

```elixir
future = DateTime.add(DateTime.utc_now(), 2, :day)
cron = "#{future.minute} #{future.hour} #{future.day} #{future.month} *"
```

The next fire is exactly `future` (~2 days out — the race is *eliminated*, not merely rarer like a
monthly fixture), `schedule_kind` stays `:cron`, and ~2 days (1.7e8 ms) is far under the ~49-day timer
ceiling. `future` is always a real calendar date, so the pinned day/month is never an impossible cron.

Per-file changes:

| File / line | Current | New | Why |
|---|---|---|---|
| `cron/telemetry_test.exs:18` | `@far_future {:cron, "0 4 * * *"}` | `@far_future {:every, 86_400_000}` | telemetry asserts only `mode`/`target`/`dispatch_target`/`tenant_id` — shape irrelevant |
| `tools/schedule_task_test.exs:18` | `@far_future "0 4 * * *"` (string) | `@far_future "every 1d"` | tool accepts interval; success-path asserts only target/workflow/timezone persistence |
| `tools/list_scheduled_tasks_test.exs:13` | `@far_future {:cron, "0 4 * * *"}` | `@far_future {:every, 86_400_000}` | asserts the non-UTC `tz:` segment, gated on tz not kind |
| `cli/commands_cron_test.exs:102,111` | `{:cron, "0 4 * * *"}` | `{:every, 86_400_000}` | tz-display cases; direct `Scheduler.schedule/2` |
| `cli/commands_cron_test.exs:80` | `"0 4 * * *"` (via `/cron add`) | dynamic cron pinned ~2 days out (see below) | asserts `schedule_kind == :cron`; must stay cron-shaped |

Update each fixture's nearby comment to state the schedule never ticks during the test. The four
`schedule_task_test` error-path tests are unaffected (they fail on target/timezone/workflow validation
*before* the schedule is parsed).

---

## Tests

- **New CLI `@reboot` regression** — add a third case to the `/cron add validate-before-schedule`
  describe block in `commands_cron_test.exs`, mirroring the existing `"totally invalid"` test verbatim
  (same `capture_io`, `base_state/0`, `worker_registered?/1`): `/cron add … "@reboot" …` →
  asserts output `=~ "Failed to schedule"`, `refute worker_registered?(id)`,
  `{:error, _} = CronJob.by_job_id(id, tenant: "default")`. (Prior art for the boundary itself:
  `next_run_test.exs:100` already asserts `@reboot → {:error, :calc_error}`.)
- **Tool validation regression** — in `schedule_task_test.exs`, assert that a 5-field-but-invalid cron
  (e.g. `"99 99 99 99 99"`) returns `{:error, …}` and persists no row — exercising the rewired
  `NextRun` cron branch. (If an equivalent invalid-cron assertion already exists, just confirm it still
  passes with the unchanged error strings.)
- All four fixture edits: run the affected files and confirm assertions hold; adjust any assertion that
  pins a rendered schedule substring (e.g. `list_scheduled_tasks_test` if it checks `"cron: …"`).

---

## Files to modify

- `lib/jido_claw/cli/commands.ex` — `validate_cron/1`; drop `Parser` alias, add `NextRun` alias.
- `lib/jido_claw/tools/schedule_task.ex` — `parse_schedule/1` cron branch; drop `Parser` alias, add
  `NextRun` alias.
- `priv/defaults/system_prompt.md` + `.jido/system_prompt.md` — line 255 prose.
- `test/jido_claw/cron/telemetry_test.exs`, `test/jido_claw/tools/schedule_task_test.exs`,
  `test/jido_claw/tools/list_scheduled_tasks_test.exs`, `test/jido_claw/cli/commands_cron_test.exs` —
  fixtures + new regression tests.

No migration, snapshot, `mix.exs`, or `mix.lock` changes. (The `deps.unlock --unused` precommit stage
is dep-lock hygiene independent of this work — see the Verification caveat.)

---

## Verification (definition of done)

Run via **mise** (OTP 28.5 — shell-default OTP 29 forces a failing dep recompile):

1. `mise exec -- mix precommit` — the gate; all stages must pass. Watch:
   - **compile `--warnings-as-errors`**: confirm no leftover `Parser.` usage in either file (each had a
     single call site) and the `NextRun` aliases resolve.
   - **`jidoclaw.system_prompt.check`**: unaffected by the prose edit (tool count + names unchanged).
   - **`deps.unlock --unused`**: must run via `mise exec` (OTP 28.5) — under shell-default OTP 29 a
     `memento` recompile fails. This stage can also modify `mix.lock` if a stale/unused entry exists;
     since this plan changes no deps, any lock change or failure here is pre-existing. Don't silently
     commit a `mix.lock` change or treat the gate as quietly passed — investigate the actual cause and
     report it (with output) to the user.
   - **dialyzer**: `validate_cron/1` and the tool's `parse_schedule/1` still return
     `{:ok, _} | {:error, _}`; `NextRun.compute_next_cron_utc/2` is already spec'd.
2. Targeted, while iterating:
   `mise exec -- mix test test/jido_claw/cron/ test/jido_claw/tools/schedule_task_test.exs \
   test/jido_claw/tools/list_scheduled_tasks_test.exs test/jido_claw/cli/commands_cron_test.exs`
3. Manual smoke (`mise exec -- mix jidoclaw`): `/cron add bad "@reboot" do a thing` → prints
   "Failed to schedule", no row in `cron_jobs`, no worker registered; `/cron add ok "0 9 * * *" …` →
   schedules + persists as before.
