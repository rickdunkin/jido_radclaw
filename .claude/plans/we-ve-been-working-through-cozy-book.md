# WS4a code-review fixes — Cron.Owner leadership guards + UnscheduleTask error handling

## Context

A static code review of the unstaged WS4a diff (clustered user-cron ownership,
`docs/plans/clustering/WS4a-clustered-cron-ownership.md`) surfaced three correctness
bugs. All three are **validated against source** below. WS4a's whole point is an
exactly-once-under-clustering invariant for persisted user cron jobs, and two of the
three findings poke holes in exactly that invariant (a demoted node can still
schedule/fire) or crash a user-facing tool. Fixing them is in scope; the bar for "done"
is **`mix precommit` green**.

All three fixes are localized to the two files they live in and **mirror patterns that
already exist in those same files / the codebase** — no public API signature changes, so
no ripple to callers.

---

## Finding 1 [P1] — leader-recheck on the synchronous call handlers

**File:** `lib/jido_claw/platform/cron/owner.ex`

**Validated.** `handle_cast({:reconcile_tenant, …})` (`:240`) guards its work with
`if Cluster.leader?()`. The two synchronous `handle_call` clauses do **not**:

- `handle_call({:reconcile_tenant, …})` (`:253`) calls `reconcile_tenant/2`
  unconditionally → a node demoted between `notify_changed/1`'s `leader?/0` check
  (`:144`) and this call being handled will `converge/2` and **schedule** user workers
  it no longer owns (the new leader schedules them too → double-fire).
- `handle_call({:trigger, …})` (`:262`) likewise reconciles then **fires** a user cron
  job (`Scheduler.trigger/2`) — a demoted node firing a job is the worst case.

Every other reconcile entry (`do_reconcile/1` via boot/tick/telemetry/`:reconcile` call)
already re-checks `leader?/0` internally; only these two per-tenant call paths are
unguarded.

**Fix** — add the same fail-closed guard the cast clause uses:

```elixir
def handle_call({:reconcile_tenant, tenant_id}, _from, state) do
  # Re-check: leadership may have moved between notify_changed's leader?/0 check
  # and this call landing. A demoted node must not schedule workers (the new
  # leader owns them; this node's own workers are pruned by the leader_changed-
  # driven do_reconcile). The new leader's periodic reconcile backstops the
  # dropped notify.
  if Cluster.leader?(), do: reconcile_tenant(tenant_id, state)
  {:reply, :ok, state}
end

def handle_call({:trigger, tenant_id, job_id}, _from, state) do
  if Cluster.leader?() do
    case reconcile_tenant(tenant_id, state) do
      :ok -> {:reply, Scheduler.trigger(tenant_id, job_id), state}
      {:error, :desired_unknown} = err -> {:reply, err, state}
    end
  else
    {:reply, {:error, :not_leader}, state}
  end
end
```

- The `{:reconcile_tenant}` clause still always replies `:ok` (its current contract;
  `notify_changed/1`'s `@spec` is `:ok`). When not leader it simply skips the work —
  consistent with the cast clause, which also just drops (no re-forward); the real
  leader's periodic reconcile is the backstop.
- The `{:trigger}` clause gains `{:error, :not_leader}` when demoted — a fail-closed
  refusal to fire. `trigger/2`'s `@spec` is already `:ok | {:error, term()}`, and
  `/cron trigger`'s renderer (`commands.ex:582`) has a catch-all `{:error, reason}`
  branch, so the new atom needs no caller changes. `trigger/2` itself is unchanged:
  the handler reply is a normal `{:error, :not_leader}` (not an exit), so it passes
  through the existing `try/catch` at `:175` untouched.
- **Also update `trigger/2`'s `@doc`** (`owner.ex:161`) to enumerate the new
  `{:error, :not_leader}` (leadership moved between routing and handling) alongside the
  errors it already lists. Spec + callers already cover it; only the prose is stale.

---

## Finding 2 [P2] — `notify_changed/1` must not crash its caller

**File:** `lib/jido_claw/platform/cron/owner.ex`

**Validated.** The leader-local branch (`:151`) is a raw bounded `GenServer.call(…, 5_000)`.
If the Owner is mid-`reconcile_all_tenants` on the periodic tick (slow with many tenants),
restarting, or otherwise busy, the call exits on timeout/`:noproc` and that exit
propagates to `schedule_task`, `unschedule_task`, and `/cron add|remove|disable` —
**after the DB row was already written**. Given the durable-row + periodic-reconcile
design, the row is safe and the tick backstops; crashing the user-facing tool is wrong.
Note `trigger/2` (`:175`) already wraps its call in exactly this `try/catch`.

**Fix** — mirror `trigger/2`'s guard on the `_pid ->` branch:

```elixir
_pid ->
  try do
    GenServer.call(__MODULE__, {:reconcile_tenant, tenant_id}, @reconcile_tenant_timeout)
  catch
    :exit, _ ->
      # Row is durable; the periodic reconcile backstops a busy/slow/dead Owner.
      # Never crash the user-facing tool/command after the DB write.
      Logger.debug("[Cron.Owner] reconcile_tenant call exited; reconcile deferred to tick")
      :ok
  end
```

Returns `:ok` in every branch, preserving `@spec notify_changed(String.t()) :: :ok`.
(`require Logger` is already present at `:90`.) The follower `GenServer.cast` branch
(`:156`) is already fire-and-forget and cannot raise on an unreachable node, so it is
untouched.

---

## Finding 3 [P2] — `UnscheduleTask` distinguishes not-found from real failure

**File:** `lib/jido_claw/tools/unschedule_task.ex`

**Validated.** `run/2` (`:35`) matches only `:ok` and `{:error, :not_found}` from
`remove_persistent/3`. But `remove_persistent/3` (`:45`) returns the raw `err` from a
failed `Job.remove/2` (its `err -> err` fall-through) — any real Ash/DB destroy error
lands in `run/2` with **no matching clause → `CaseClauseError`** (crashes the tool). And
its `{:error, _} -> {:error, :not_found}` collapses **every** `Job.by_job_id/2` failure
(including a genuine DB read error) into "not found," hiding real failures.

**Convention to mirror** (confirmed in-repo):
- Not-found from a `get?` code interface surfaces in **two** shapes here: bare
  `{:error, %Ash.Error.Query.NotFound{}}` (`verify_certificate.ex:229`, `Solution.by_id`)
  **and** wrapped `{:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{}]}}`
  (`project_policy_test.exs:37`, a `get_by`). The shape varies by call path, so classify
  for both up front — don't bet on the bare form. (No shared classifier exists yet:
  `JidoClaw.Core.AshErrors` has `unique_violation?/2` + `db_errors/0` but no not-found
  predicate; `Error.not_found/3` is a *builder*, not a classifier. Add a private one.)
- Tool-level real-failure return is `{:error, "human string"}` — `list_scheduled_tasks.ex:38`
  (`{:error, "Failed to list scheduled tasks: #{inspect(reason)}"}`).

**Fix** — a private recursive `not_found_error?/1` (bare + wrapped, recursion style of
`AshErrors.unique_violation?/2`), routed through a normal `case` branch; extract
`do_remove/3` to keep nesting shallow; add a real-error branch to `run/2`:

```elixir
case remove_persistent(tenant_id, id, actor) do
  :ok ->
    CronOwner.notify_changed(tenant_id)
    {:ok, %{result: "Removed task '#{id}' from the persistent store."}}

  {:error, :not_found} ->
    {:ok, %{result: "Task '#{id}' not found in the persistent store."}}

  {:error, {_stage, reason}} ->
    {:error, "Failed to remove task '#{id}': #{inspect(reason)}"}
end

# ...

defp remove_persistent(tenant_id, id, actor) do
  case Job.by_job_id(id, tenant: tenant_id, actor: actor) do
    {:ok, job} -> do_remove(job, tenant_id, actor)
    {:error, reason} -> read_error(reason)
  end
end

defp do_remove(job, tenant_id, actor) do
  case Job.remove(job, tenant: tenant_id, actor: actor) do
    :ok -> :ok
    {:ok, _} -> :ok
    {:error, reason} -> {:error, {:remove_failed, reason}}
  end
end

# A get? read surfaces not-found either bare or wrapped in Ash.Error.Invalid;
# both mean "gone", anything else is a real read failure worth surfacing.
defp read_error(reason) do
  if not_found_error?(reason),
    do: {:error, :not_found},
    else: {:error, {:read_failed, reason}}
end

defp not_found_error?(%Ash.Error.Query.NotFound{}), do: true

defp not_found_error?(%Ash.Error.Invalid{errors: errors}) when is_list(errors),
  do: Enum.any?(errors, &not_found_error?/1)

defp not_found_error?(_), do: false
```

- Genuine not-found (either shape) keeps the existing friendly `{:ok, …}` message.
- A `by_job_id` read failure or a `Job.remove` failure now returns a normal tool error
  instead of mis-reporting "not found" / crashing with `CaseClauseError`.
- `Ash.Error.Query.NotFound` / `Ash.Error.Invalid` are referenced once each → no
  `Credo.Design.AliasUsage`; no `@spec` needed on the new private helpers; the
  `not_found_error?/1` name ends in `?` per the predicate-naming rule.

**Out of scope:** `commands.ex` `/cron remove`/`disable` (`:556`,`:595`) swallow the same
errors (`_ -> :ok`, `_ = CronJob.remove(...)`), but the reviewer scoped Finding 3 to the
tool, and the CLI is deliberately fire-and-forget ("Removed" prints regardless). Left as-is.

---

## Tests

### `test/jido_claw/cron/owner_test.exs` (extend — Findings 1 & 2)

Reuse the file's existing harness (`set_leader/1`, `start_owner/1`, `seed_job/3`,
`worker_alive?/2`, the `trigger` describe's `CapturingRunner` + `cron_owner_test_pid`).

- **Trigger fails closed when this node is no longer leader (F1).** Faithful via the
  public API: `set_leader(false)` (the stub's `leader/0` still returns `Node.self()`, so
  `Owner.trigger/2` routes to the local Owner), seed a workflow job, `start_owner()`
  (boots follower → no worker). `assert {:error, :not_leader} = Owner.trigger(tenant, id)`
  and `refute_receive {:ran, _}, 200`.
- **`{:reconcile_tenant}` call on a non-leader schedules nothing (F1).** This handler is
  unreachable via `notify_changed/1` when `leader?/0` is false (it takes the cast branch),
  so exercise the handler directly to simulate the demotion race: `set_leader(false)`,
  `start_owner()`, `seed_job/3`, then `assert :ok = GenServer.call(Owner, {:reconcile_tenant, tenant})`
  and `refute worker_alive?(tenant, id)`.
- **`notify_changed` catches a dead/slow Owner call and returns `:ok` (F2).** Add a tiny
  throwaway GenServer (alongside `CapturingRunner`) registered as `JidoClaw.Cron.Owner`
  whose `handle_call({:reconcile_tenant, _}, …)` stops without replying — use
  `use GenServer, restart: :temporary` and a `{:stop, {:shutdown, :test}, state}` reason so
  the ExUnit supervisor neither restarts it nor logs a crash. `set_leader(true)`,
  `start_supervised!(ThatModule)`, then `assert :ok = Owner.notify_changed(tenant)` (the
  call exits → caught → `:ok`). Do **not** also `start_owner()` in this test (name clash).

### `test/jido_claw/tools/unschedule_task_test.exs` (new — Finding 3)

Mirror `schedule_task_test.exs`'s harness: `use JidoClaw.TenantCase, async: false`,
`seed_tenant` + `Manager.ensure_tenant`, `ctx = %{tool_context: %{tenant_id: …, actor: actor_for(…)}}`.
Recall a `{:error, "string"}` from `run/2` surfaces as `{:error, wire}` with `wire.message`.

- **Removes a persisted job.** `Job.upsert` a row, `UnscheduleTask.run(%{id: id}, ctx)` →
  `{:ok, %{result: result}}`, `result =~ "Removed"`, and `Job.by_job_id(id, …)` now
  `{:error, _}` (row gone). (Owner is disabled in test, so `notify_changed` no-ops to `:ok`
  — no worker assertions.)
- **Genuine not-found returns the friendly message.** `run(%{id: "ghost"}, ctx)` →
  `{:ok, %{result: result}}`, `result =~ "not found"`. (Also pins that `not_found_error?/1`
  correctly classifies whichever not-found shape `by_job_id` actually returns here.)

The two real-error branches (`{:read_failed, _}` / `{:remove_failed, _}`) are **not
deterministically forceable** in a unit test: the Job policy ties read and destroy to the
same actor-tenant match (a mismatch fails the *read* first, as NotFound), and the tool
re-reads a fresh row so a stale-record destroy error is unreachable mid-call. Forcing them
would need a DI seam the reviewer didn't ask for and the tool doesn't otherwise want. They
are correct-by-construction (identical shape to `verify_certificate.ex` / `list_scheduled_tasks.ex`)
and covered by the type contract; documented here rather than silently skipped.

### Existing tests

No existing test changes are required. All `owner_test.exs` `trigger`/`notify_changed`
cases run under `set_leader(true)`, so the new `leader?/0`-false guards are inert for them;
the follower case already exercises the (already-guarded) cast path. `commands_cron_test.exs`
has no `/cron trigger` assertion to break.

---

## Critical files

- `lib/jido_claw/platform/cron/owner.ex` — Findings 1 (two `handle_call` clauses) + 2
  (`notify_changed/1` `_pid` branch).
- `lib/jido_claw/tools/unschedule_task.ex` — Finding 3 (`run/2` + `remove_persistent/3`,
  new `do_remove/3`).
- `test/jido_claw/cron/owner_test.exs` — three added cases + one throwaway GenServer module.
- `test/jido_claw/tools/unschedule_task_test.exs` — new file, two cases.

**Reuse:** the cast-clause guard idiom (`owner.ex:240`); `trigger/2`'s `try/catch :exit`
(`owner.ex:175`); `verify_certificate.ex:229`'s `%Ash.Error.Query.NotFound{}` match;
`list_scheduled_tasks.ex:38`'s `{:error, "…#{inspect(reason)}"}` tool-error return;
`schedule_task_test.exs`'s tool-test + `owner_test.exs`'s leader-stub harnesses.

---

## Verification (not done until `mix precommit` passes)

Run mix via `mise exec -- mix`. The `precommit` alias (mix.exs:251) runs, in order:
`jidoclaw.compile_check` (clean compile, **allowlist empty** — zero warnings) →
`system_prompt.check` → `deps.unlock --unused` → `format --check-formatted` →
`reach.check --arch --smells --strict` (smells must stay 0) → `credo --strict` →
`dialyzer --format short` → `test`.

1. **Format:** `mise exec -- mix format`.
2. **Targeted, in isolation** (both files are `async: false` and on the suite-flaky list —
   verify standalone, **not** under `--seed 0`):
   - `mise exec -- mix test test/jido_claw/cron/owner_test.exs`
   - `mise exec -- mix test test/jido_claw/tools/unschedule_task_test.exs`
3. **Full gate, bare in the background, read the tail** (never pipe through `tail` — it
   masks the exit code): `mise exec -- mix precommit`.

**Watch-fors:** no comment line may begin with the word "step" (ExSlop EXS3004); the new
`try/catch` and `if leader?` guards must not introduce a `compile_check` warning (they
mirror shipped code that already compiles clean); `Ash.Error.Query.NotFound` used once so
no AliasUsage finding; dialyzer is satisfied because `trigger/2` already ships the
identical `try/catch` and `verify_certificate.ex` already ships the identical NotFound
match.

**Optional manual smoke** (single node, Tidewave `project_eval` or `mix jidoclaw`):
`schedule_task` an `every 1m` agent job, confirm it fires and `list_scheduled_tasks` shows
it; `unschedule_task` a non-existent id → friendly "not found" (no crash).

---

## Out of scope (recorded, not silently dropped)

- `commands.ex` `/cron remove|disable` error swallowing — not flagged; CLI is intentionally
  fire-and-forget.
- A DI seam on `UnscheduleTask` to unit-test its two real-error branches — disproportionate
  to a 3-line fix; branches are correct-by-construction.
- The cross-BEAM `:peer` failover proof (incl. mid-flight demotion) stays WS6, per WS4a.
