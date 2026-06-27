# WS1 — Lease core: implementation plan

## Context

`docs/plans/clustering/WS1-lease-core.md` is the keystone of the clustering work:
make a `WorkflowRun`'s owner **durable and fenced** so a run can't be silently
double-executed. The claim columns + two global scan indexes already shipped dead
(`workflow_run.ex:367-380`, `:73-74`), so this is implementation, not design.

**The constraint that fixed scope.** Every run launches **in-process holding its
reactor** and blocks synchronously (`run_execution.ex:121`). There is **no general
"reconstruct a reactor from a stored `WorkflowRun` and run it" seam** — `WorkflowRecovery`
*fails* stranded runs (`workflow_recovery.ex:193, 447-449`); reconstruction exists
only for gate-resume (module-fenced checkpoint) and composer (serialized catalog),
and inline `%Reactor{}` structs can't be reconstructed at all. So a Pooler that
*claims and dispatches* an orphaned run can't run it — that is **WS3**.

### Scope decisions (settled)

- **D1 → (b) self-claim on launch**; single-node stays byte-identical (nothing expires).
- **Pooler → WS3.** WS1 ships the lease *mechanism* only: the stamp/`renew`/`claim_next`
  primitives, the `Lease` middleware + sidecar, self-claim wiring, config, tests. No
  Pooler, no always-on poller, no `cluster_enabled`-gated child.
- **Honest seam (not "no-deferral").** `claim_next` and the fence branches ship
  **unit-tested but not production-triggered until WS3** — a bounded, named-consumer
  deferral.
- **Defaults:** `claimed_by = to_string(Node.self())`; `lease_seconds: 60` /
  `renew_seconds: 15`; oldest-first; plaintext `:uuid` token (out of all payloads — T1-1).

### Review findings addressed

**Round 2**

| Finding | Resolution |
|---|---|
| Gate-resume claim could fence the live winner | Token *generation* stays in the caller; the row *stamp* moves into `Lease.init`, reached only by the registration-winner (`run_execution.ex:108-114`). |
| `:claimable` missed expired *claimed `:pending`* | Filter covers pending-unclaimed **and any expired-claimed** pending/running. |
| `renew` failed open on DB raise | Tagged returns (no `!`) + sidecar **fails closed** via pure `fence_decision/3`. |
| App vs DB time | DB clock (`now() + interval`) throughout. |
| Self-claim failure ran unleased / token not dumped / `:claimable` not private | Fail-closed-on-cluster (below); `Ecto.UUID.dump!` id **and** token; `public?(false)`. |

**Round 3**

| Finding | Resolution |
|---|---|
| **P1** stamp was a blind takeover — `RunRegistry` is node-local, so two nodes both reach `Lease.init` and last-writer-wins | **`stamp` is a compare-and-swap**: `… WHERE id = $ AND claim_token IS NOT DISTINCT FROM $expected` (nil-safe), `expected` = the loaded run's token. Cross-node, the loser's CAS hits 0 rows and aborts. |
| **P1** sidecar start was fail-open (row stamped, sidecar dies → unleased executor) | `start_sidecar` is a **synchronous readiness handshake**; `Lease.init` treats start/registration failure like a claim failure (abort under clustering). |
| **P2** stamping *after* `run_started` left an unclaimed `:running` crack | **Order flipped to `[Lease.Middleware, ReactorMiddleware]`** — stamp at `:pending`, so a crash in the gap leaves `:pending` + claimed + expiry, which `:claimable` selects. No ambiguous `:running`-unclaimed state. |
| **P2** `stamp` needs row-count semantics | Returns `{:ok, :claimed}` (1) / `{:ok, :lost}` (0 — fenced/CAS-lost) / `{:error, term}`. |
| **P3** `ensure_middleware` sketch could raise (`{:ok, b} = …`) | Use a `with`, returning `{:error, reason}` → the runner's existing `{:error, reason, nil}` path. |

**Round 4**

| Finding | Resolution |
|---|---|
| **P1** CAS guarded only `id + claim_token` — a cancel/recovery terminal can land before `Lease.init` *without rotating the token*, so the late executor would re-stamp a terminal row | **Add `AND status IN ('pending','running')`** to the CAS. A terminal/parked row → `{:ok, :lost}` → abort, no stamp, no sidecar. New test for "cancel before `Lease.init`". |
| **P2** GateResume relied on the *deserialized* reactor already carrying `Lease.Middleware` | Factor a shared `normalize_middleware/1`; `GateResume` **applies it** to the decoded reactor before `run_killable/4`. |
| **P3** ready-recipient coupled to the executor pid | `start_sidecar` captures `caller = self()` separately from `executor_pid`; the sidecar sends ready to `caller`, monitors `executor_pid`. |
| **P3** sidecar register failure unspecified | Sidecar **cases on `Registry.register`**; on `{:error, _}` it `exit`s before ready, so `start_sidecar` reports `{:sidecar_down, reason}` (fail-closed). |
| *(confirmed)* fresh-context token wins on resume | Reactor deep-merges runtime context over `reactor.context`, RHS wins (`deps/reactor/lib/reactor/executor/init.ex:33`) — no fallback needed. |

### The claim-ownership model (the core fix)

> **Generation is decoupled from the stamp, and the stamp is a CAS.** The **caller**
> (`run/3` / `gate_resume`) generates a fresh `:uuid` token and threads it into the
> reactor `context` (sidecar + in-txn terminal fence) and `finalize_opts` (runner-side
> fence). The **row stamp runs in `Lease.init`**, inside `Reactor.run`, which
> `run_killable` reaches **only after the executor wins `RunRegistry` registration**
> (`run_execution.ex:108-114`) — so a same-node duplicate never stamps. The stamp is a
> **compare-and-swap on the prior token**, so a *cross-node* duplicate that does reach
> `Lease.init` loses the CAS and aborts. Only the process that wins execution rotates
> the token.

### Projection-ownership invariant (must not break)

`WorkflowRun.status` is written **only** by `:set_status`, called **only** by
`WorkflowEvent.Changes.Allocate` in the append transaction (`workflow_run.ex:127-135`).
The claim columns are **not** in `:set_status`'s accept list (`:141`). The stamp and
`renew` are raw `UPDATE`s touching only `claimed_by` / `claim_expires_at` /
`claim_token` — never `status`.

---

## File-by-file changes

### NEW `lib/jido_claw/orchestration/workflow_lease.ex` (`JidoClaw.Orchestration.WorkflowLease`)

- `node_identity/0` → `to_string(JidoClaw.Cluster.local_node())` (`core/cluster.ex:25`).
- `lease_seconds/0` / `renew_seconds/0` →
  `Application.get_env(:jido_claw, :workflow_lease, []) |> Keyword.get(:lease_seconds, 60)`.
- `stamp(run_id, new_token, expected_token, opts) :: {:ok, :claimed} | {:ok, :lost} | {:error, term()}`
  — **raw SQL, DB clock, CAS**:
  ```sql
  UPDATE workflow_runs
     SET claimed_by = $1, claim_token = $2,
         claim_expires_at = now() + ($3 || ' seconds')::interval
   WHERE id = $4 AND claim_token IS NOT DISTINCT FROM $5
     AND status IN ('pending', 'running')         -- never re-stamp a terminal/parked row
  ```
  params `[node_identity(), dump!(new_token), to_string(lease_seconds()), dump!(run_id),
  dump_or_nil(expected_token)]` (`dump_or_nil(nil) = nil` for the nil-safe genesis case)
  via `Repo.query/2`; `{:ok, %{num_rows: 1}} -> {:ok, :claimed}`,
  `{:ok, %{num_rows: 0}} -> {:ok, :lost}`, `{:error, e} -> {:error, e}`. The **status guard**
  means a cancel/recovery terminal (or a park) landing before `Lease.init` makes the late
  executor's stamp `{:ok, :lost}` → it aborts without stamping or starting a sidecar; fence A's
  `:cancelled` clause then returns the clean envelope. Used by `Lease.init` and `claim_next/1`
  (whose `:claimable` rows are already `:pending`/`:running`, so the guard is a no-op there).
- `renew(run_id, token) :: {:ok, non_neg_integer()} | {:error, term()}` — **raw SQL, DB
  clock, fenced**: `… SET claim_expires_at = now() + ($1||' seconds')::interval WHERE id = $2
  AND claim_token = $3`, params `[to_string(lease_seconds()), dump!(run_id), dump!(token)]`;
  `{:ok, %{num_rows: n}} -> {:ok, n}` / `{:error, e} -> {:error, e}`.
- `claim_next/1 :: {:ok, WorkflowRun.t()} | :none | {:error, term()}` — `Repo.transaction`
  around `Ash.read` of `:claimable` with `Ash.Query.limit(1) |> Ash.Query.lock("FOR UPDATE
  SKIP LOCKED")` (**literal string** — `trace_run.ex:218-229`); on `[run]`,
  `stamp(run.id, Ash.UUID.generate(), run.claim_token, …)` (CAS is redundant under the
  held `FOR UPDATE` but uniform), reload, return; `[]` → `nil`; `Repo.rollback/1` on errors.
- `fence_decision(renew_result, ms_since_ok, lease_ms) :: :renewed | :kill | {:retry, ms}`
  — **pure, unit-tested**: `{:ok, n} when n >= 1 -> :renewed`; `{:ok, 0} -> :kill`;
  `{:error, _} when ms_since_ok >= lease_ms -> :kill` (**fail-closed**); `{:error, _} -> {:retry, retry_ms}`.
- `start_sidecar(executor_pid, run_id, tenant_id, token) :: :ok | {:error, term()}` —
  **synchronous readiness handshake**. Captures `caller = self()` (who awaits ready)
  separately from `executor_pid` (what the sidecar monitors), so the helper isn't coupled
  to being called from the executor:
  ```elixir
  caller = self()
  case Task.Supervisor.start_child(LeaseTaskSupervisor,
         fn -> Sidecar.run(caller, executor_pid, run_id, tenant_id, token) end) do
    {:ok, pid} ->
      ref = Process.monitor(pid)
      receive do
        {:lease_ready, ^run_id} -> Process.demonitor(ref, [:flush]); :ok
        {:DOWN, ^ref, _, _, reason} -> {:error, {:sidecar_down, reason}}
      after 5_000 -> Process.demonitor(ref, [:flush]); {:error, :sidecar_timeout}
      end
    {:error, reason} -> {:error, {:sidecar_start, reason}}
  end
  ```

### NEW `lib/jido_claw/orchestration/workflow_lease/middleware.ex`

`use Reactor.Middleware`; **`init/1` only** (cleanup is monitor-driven). Runs **first**
(order below) so the stamp lands at `:pending`:

```elixir
def init(%{claim_token: t, workflow_run: %WorkflowRun{id: id, tenant_id: tid} = run} = ctx)
    when is_binary(t) do
  case WorkflowLease.stamp(id, t, run.claim_token, tenant: tid) do   # CAS on the prior token
    {:ok, :claimed} ->
      case WorkflowLease.start_sidecar(self(), id, tid, t) do        # readiness is part of the claim
        :ok -> {:ok, ctx}
        {:error, reason} -> fail_or_degrade({:lease_sidecar, reason}, ctx)
      end
    {:ok, :lost} ->
      {:error, {:lease_lost, id}}                                    # another owner OR a terminal/parked row landed first; fence A (incl. its :cancelled clause) → no terminal
    {:error, reason} ->
      fail_or_degrade({:lease_claim, reason}, ctx)
  end
end
def init(ctx), do: {:ok, ctx}                                        # no token (degraded) -> byte-identical

defp fail_or_degrade(reason, ctx) do
  if cluster_enabled?(), do: {:error, reason}, else: (Logger.warning(...); {:ok, ctx})
end
```

`cluster_enabled?/0` reads `Application.get_env(:jido_claw, :cluster_enabled, false)`.
`{:lost}` aborts regardless of mode — fence A maps it to no-terminal because the
reloaded row token (the winner's) ≠ the held token.

### NEW `lib/jido_claw/orchestration/workflow_lease/sidecar.ex`

A `Task` (not GenServer). `run(caller_pid, executor_pid, run_id, tenant_id, token)` —
**register, arm the monitor, *then* signal ready** (so "ready" = fully armed), wrapping the
loop so any unexpected death is fail-closed:

```elixir
case Registry.register(LeaseRegistry, run_id, %{executor: executor_pid, token: token}) do
  {:ok, _} ->
    ref = Process.monitor(executor_pid)              # arm BEFORE ready — no miss-the-:DOWN window
    send(caller_pid, {:lease_ready, run_id})         # handshake → start_sidecar returns :ok
    try do
      loop(executor_pid, run_id, token, ref, monotonic_now())
    rescue e -> Process.exit(executor_pid, :kill); reraise e, __STACKTRACE__
    catch kind, reason -> Process.exit(executor_pid, :kill); :erlang.raise(kind, reason, __STACKTRACE__)
    end
  {:error, reason} ->
    exit({:lease_register_failed, reason})           # no ready → start_sidecar gets {:sidecar_down, _}
end
```

Any **unexpected** loop death (a bug, an unhandled message) kills the executor before exiting,
so *arbitrary* sidecar death is fail-closed — not only renew failures. **Residual:** an
untrappable `Process.exit(sidecar, :kill)` can't run the rescue, so it would leave the executor
running unleased — accepted as out-of-scope for WS1, since nothing issues such a kill except
`LeaseTaskSupervisor` shutdown (where the executor is terminating too); a targeted external kill
of a sidecar is a WS3 reclaim concern. The renew loop:

- `{:DOWN, ^ref, :process, ^pid, _}` → stop.
- `{:lease_tick, from}` (**test seam**) → `renew/2`, reply `{:lease_ticked, r}`, act.
- `after renew_seconds*1000` → `renew/2`, act.

`act/_` = `fence_decision(result, monotonic_now() - last_ok, lease_ms)`: `:renewed` →
loop (`last_ok = now`); `:kill` → `Process.exit(executor_pid, :kill)` then stop;
`{:retry, ms}` → loop on a shorter timer **without** resetting `last_ok`.

### EDIT `lib/jido_claw/orchestration/workflow_run.ex`

- **Policy bypass** (`:24`) — add `:claimable`.
- **`:claimable` read action** — `public?(false)`, `multitenancy(:bypass)`,
  `prepare(build(sort: [<ts>: :asc]))`:
  ```elixir
  filter(expr(
    (status == :pending and is_nil(claim_token)) or
    (status in [:pending, :running] and not is_nil(claim_expires_at) and claim_expires_at < now())
  ))
  ```
  No `code_interface` define. No `:claim` Ash action (the raw `stamp` is the seam).
  **Verify:** timestamp attr name for the sort; that Ash `now()` works in the filter
  (fallback: pin `^DateTime.utc_now()` via `prepare`).

### EDIT `lib/jido_claw/orchestration/reactor_runner.ex`

- `ensure_middleware/1` (`:369-375`) — delegate to a **shared, no-raise**
  `normalize_middleware/1` (factored so `GateResume` reuses it — P2) that normalizes to
  `[Lease.Middleware, ReactorMiddleware | rest]`:
  ```elixir
  def normalize_middleware(base) do
    rest = Enum.reject(base.middleware, &(&1 in [ReactorMiddleware, WorkflowLease.Middleware]))
    with {:ok, b} <- Builder.add_middleware(%{base | middleware: rest}, ReactorMiddleware),
         {:ok, b} <- Builder.add_middleware(b, WorkflowLease.Middleware) do
      {:ok, b}   # prepend ⇒ [WorkflowLease.Middleware, ReactorMiddleware | rest]
    end
  end
  ```
  Init runs Lease (stamp at `:pending`) → ReactorMiddleware (`run_started`). The
  `{:error, reason}` flows to the existing `{:error, reason, nil}` path.
- `run/3` (at `:297`, after `create_run`) — **generate + thread, no stamp**:
  `claim_token = Ash.UUID.generate()` into the merged `context` and `finalize_opts`.
- `handle_exit/3` (`:590-600`) + `finalize({:error, …})` (`:633-642`) — fence A (below).
- `append_failed/2` (`:775-809`) — thread `claim_fence_token: Keyword.get(opts, :claim_token)`.

### EDIT `lib/jido_claw/orchestration/reactor_middleware.ex`

- `append/4` (`:411-416`) — add `claim_fence_token: context[:claim_token]`. `complete/2`/`error/2`
  bodies unchanged (a rejected fenced append already routes through their `with` else).

### EDIT `lib/jido_claw/orchestration/workflow_log.ex`

- `append/4` (`:25-34`) — forward the token to `WorkflowEvent.append` via the **`context:`
  opt** (not the payload — T1-1): `… ++ (if is_binary(t), do: [context: %{claim_fence_token: t}], else: [])`.
  Other helpers pass no token → operator-cancel/recovery terminals never fenced.

### EDIT `lib/jido_claw/orchestration/workflow_event/changes/allocate.ex`

- Fence B (below): a guard in `allocate/2` after `{:ok, run} <- lock_run(...)` (`:106`),
  reusing the per-run `FOR UPDATE` lock. **No change to status logic.**

### EDIT `lib/jido_claw/orchestration/gate_resume.ex`

- `run_reactor/7` (`:151-160`) — generate `claim_token = Ash.UUID.generate()`; add to the
  `context` and `finalize_opts`. **Apply `ReactorRunner.normalize_middleware/1` to the decoded
  reactor before `run_killable/4`** (P2) so `Lease.Middleware` is guaranteed present even on a
  checkpoint written before WS1 — don't rely on it being baked in. **Handle its `{:error, reason}`
  explicitly** (a `with`/`case`, not `{:ok, r} = …`): route it through the existing resume
  fail-with-audit path (the same one `decode_checkpoint`/decrypt failures use, `gate_resume.ex:135-147`),
  never a crash. The stamp then runs in `Lease.init` with a CAS on the run's current token, so
  only one resumer wins (fixing the approve-vs-recovery race). The fresh context token wins over
  any baked-in one — Reactor deep-merges runtime context over `reactor.context`, RHS wins
  (`deps/reactor/lib/reactor/executor/init.ex:33`).

### `lib/jido_claw/orchestration/replay.ex` — NO CHANGE

`replay.ex:251` launches a fresh run via `run/3` → standard self-claim path.

### EDIT `lib/jido_claw/application.ex`

After `RunRegistry`/`RunTaskSupervisor` (`:153-154`), in `infra_children`:

```elixir
{Registry, keys: :unique, name: JidoClaw.Orchestration.LeaseRegistry},
{Task.Supervisor, name: JidoClaw.Orchestration.LeaseTaskSupervisor},
```

All modes; inert until a run launches. No `cluster_enabled` gate (Pooler is WS3).

### EDIT `config/config.exs` / `config/test.exs`

```elixir
# config.exs (near :workflow_recovery, :251-255)
config :jido_claw, :workflow_lease, lease_seconds: 60, renew_seconds: 15
# test.exs — large interval so the prod auto-timer never races; tests drive {:lease_tick}
config :jido_claw, :workflow_lease, lease_seconds: 60, renew_seconds: 86_400
```

### NO MIGRATION

Columns + indexes already shipped; actions/policies/bypass aren't schema. Confirm
`mix ash.codegen --check` is clean.

---

## The fence-stop design

A fenced ("zombie") executor must **stop and write no terminal**. Three terminal-writing
paths; the caller token (fence A) and the in-txn token (fence B) neutralize all three.

### A. Runner-side fence — reload-first token compare

The held token is in `finalize_opts`. On any death/propagated-error:

```elixir
defp fenced?(reloaded, opts) do
  case Keyword.get(opts, :claim_token) do
    held when is_binary(held) -> is_binary(reloaded.claim_token) and reloaded.claim_token != held
    _ -> false
  end
end
```

- `handle_exit/3` (the `{:exit, _}` kill path): `cond` — `:cancelled` (existing) → clean;
  `fenced?` → `{:error, :fenced, reloaded}` **no `ensure_failed`**; else existing fail.
  Covers the **sidecar kill** (the reloaded token is the reclaimer's).
- `finalize({:error, reason})` (the propagated-`{:error}` path): same `fenced?` short-circuit
  — covers a **fenced `complete/2` rejected by Allocate** and **step-error-while-fenced** (the
  reloaded token rotated).
- **Dedicated `finalize({:error, {:lease_lost, _}}, …)` clause** (the CAS-lost `Lease.init`
  abort — "I don't own it"): `cond` — `:cancelled` → `:cancelled`; **any other terminal →
  `:already_terminal`** (the clean vocab for "a `:failed`/`:completed` landed first"); else
  (lost to a *live* owner) → `:fenced`. Scoped to the `{:lease_lost, _}` reason so a **real
  step error still surfaces its own reason** — the terminal short-circuit must not swallow a
  normal failure into `:already_terminal`. The *other* abort reasons —
  `{:lease_sidecar, _}` / `{:lease_claim, _}`, where the executor **does** own the lease but
  can't run safely — flow through the normal `finalize`, which fails the run it owns
  (best-effort if appended from `:pending`).

When the token matches (every non-fenced case, all of single-node), this is a **no-op** →
byte-identical.

### B. Append-side fence — in-transaction guard in `Allocate`

Stops a stale owner completing *between renew ticks*, at the single chokepoint, reusing
the `FOR UPDATE` lock `lock_run` already holds (race-free, 0 extra round-trips). After
`{:ok, run} <- lock_run(...)`:

```elixir
if claim_fenced?(changeset, run) do
  Changeset.add_error(changeset, field: :workflow_run_id, message: "claim token mismatch")
else
  # ... existing set_context + force_change(seq/payload/metadata) ...
end

defp claim_fenced?(changeset, run) do
  with kind when kind in [:run_completed, :run_failed] <- Changeset.get_attribute(changeset, :kind),
       token when is_binary(token) <- changeset.context[:claim_fence_token],
       current when is_binary(current) <- run.claim_token do
    current != token
  else
    _ -> false
  end
end
```

Rolls back like the existing `:illegal`-transition path (`:177-183`). A **no-op** unless
(terminal kind + present + mismatched token). The rejection propagates as `{:error,_}` and
fence A turns it into a clean fenced stop. **Verify:** the `context:` opt on
`WorkflowEvent.append` lands in `changeset.context` (fallback: a private
`argument :claim_fence_token` read via `Changeset.get_argument`); all Allocate/Projection/
`project_status == column` tests pass. *(Fallback if Allocate must stay untouched: fence in
`ReactorMiddleware.complete/2`/`error/2` via a fresh read — TOCTOU unreachable in WS1.)*

---

## Tests

New `test/jido_claw/orchestration/workflow_lease_test.exs`, `use JidoClaw.TenantCase,
async: false` (shared sandbox so the executor task + sidecar share the connection). Seed
expired leases / rotated tokens via raw `Repo.query!` (the `retention_sweeper_test.exs`
backdating precedent).

1. **`:claim_next` lock + selection** — true N-claimer race impossible under the sandbox
   (`retention_sweeper_test.exs:77-81`): **(a)** SQL-pin (`query.lock == "FOR UPDATE SKIP
   LOCKED"`, `Repo.to_sql(...) =~ "SKIP LOCKED"`, mirror `:83-91`); **(b)** selection —
   3 claimable runs → oldest-first, stamped once, 4th `:none`; claimed/future-expiry skipped.
2. **Fence (`renew/2`)** — stamp T; `renew(id, T)` → `{:ok, 1}`; rotate to T' (raw SQL);
   `renew(id, T)` → `{:ok, 0}`; `renew(id, T')` → `{:ok, 1}`.
3. **Lease middleware halt (fence A)** — a test `Reactor.Step` blocking in `receive` holds
   `:running`; launch via `run/3` in a `Task`; rotate the token; `Registry.lookup(LeaseRegistry,
   id)` → sidecar; `send(sidecar, {:lease_tick, self()})`; `assert_receive {:lease_ticked,
   {:ok, 0}}`; the kill → `{:error, :fenced, run}`; assert no terminal + status `:running`.
4. **Reclaim selection** — past expiry selected + re-stamped; future expiry skipped.
5. **Status untouched** — `stamp`/`claim_next`/`renew` leave `status`; then
   `WorkflowLog.append(run, :run_started, …)` flips it `:running`.
6. **Single-node identity** — `cluster_enabled: false`: a module reactor runs to `:completed`
   with the usual events **and** is self-claimed (`claim_token` non-nil, `claimed_by ==
   to_string(Node.self())`).
7. **Terminal-append fence (fence B)** — stamp + rotate; `WorkflowLog.append(run, :run_completed,
   %{}, …, claim_fence_token: <stale>)` → `{:error, _}`, no terminal; current token → succeeds.
8. **Same-node duplicate (P1 round 2)** — start a long reactor (registers), call
   `run_killable/4` again for the same id → `{:duplicate, pid}`; the row's `claim_token`
   is **unchanged** (loser never reached `Lease.init`).
9. **CAS / cross-node duplicate (P1 round 3)** — `stamp(id, T_new, expected)`: with `expected`
   = the row's token → `{:ok, :claimed}`; with a *stale* `expected` → `{:ok, :lost}` (0 rows,
   no mutation); nil-safe — `expected: nil` on a nil row → claimed, on a non-nil row → lost.
10. **Middleware ordering (P1)** — a reactor that **already declares** `ReactorMiddleware`;
    assert `ensure_middleware` yields `[WorkflowLease.Middleware, ReactorMiddleware | _]`
    (stamp before `run_started`).
11. **Expired *claimed* `:pending` (P1)** — `:pending` + non-nil expired `claim_expires_at`
    **is** selected by `:claimable` (the crash-after-stamp shape).
12. **Sidecar readiness fail-closed (P1 round 3)** — with `cluster_enabled: true`, a
    `start_sidecar` that returns `{:error, _}` (inject via a seam / killed supervisor) makes
    `Lease.init` return `{:error, _}` and the run not proceed past init; with
    `cluster_enabled: false` it degrades (run proceeds, logged).
13. **Fail-closed renew (P1 round 2)** — `fence_decision/3` pure: `{:ok,1}→:renewed`,
    `{:ok,0}→:kill`, `{:error,_}` with `ms_since_ok >= lease_ms → :kill`, else `{:retry,_}`.
14. **Raw-SQL UUID binding (P2)** — `stamp`/`renew` with `Ecto.UUID.dump!`-ed token + id
    round-trip (renew matches the dumped token).
15. **Cancel before `Lease.init` (P1 round 4)** — driven at the seam, **not via `run/3`** (which
    creates a fresh run): create a run, cancel it (→ `:cancelled`), build a context with that
    *existing* run + a fresh `claim_token`, call `Lease.Middleware.init(context)` →
    `{:error, {:lease_lost, _}}` (the status-guarded `stamp` returned `{:ok, :lost}`); assert
    `claim_token` **unchanged**, **no** `LeaseRegistry` entry, status still `:cancelled`; then
    `ReactorRunner.finalize({:error, {:lease_lost, id}}, run, opts)` → `{:error, :cancelled, run}`.
16. **Resume normalization (P2)** — a decoded reactor whose middleware list lacks
    `Lease.Middleware`; assert `ReactorRunner.normalize_middleware/1` yields
    `[WorkflowLease.Middleware, ReactorMiddleware | _]`, so a resume re-establishes the lease.
17. **Status-guarded CAS on a non-cancel terminal (P3 round 5)** — a raw `stamp/4` unit case:
    on a `:failed` (and a `:completed`) row with a *matching* `expected` token → `{:ok, :lost}`
    and `claim_token`/`claimed_by` **unchanged** — proving the `status IN ('pending','running')`
    guard is not merely cancellation-shaped.

**Seams kept out of prod:** `{:lease_tick, from}` is a normal sidecar feature; raw-SQL
rotation/backdating is test setup; `renew_seconds: 86_400` stops the auto-timer.

---

## Precommit hazards (completion bar = clean `mix precommit`)

- **Dialyzer** — `claim_next` via `Repo.transaction` + `Repo.rollback/1`; specs:
  `stamp :: {:ok, :claimed} | {:ok, :lost} | {:error, term()}`, `renew :: {:ok, non_neg_integer()}
  | {:error, term()}`, `{:error, :fenced, run}` already in `@type run_result`.
- **Caller-less `:claim_next`** — reach runs `--arch --smells` (no `--dead-code`);
  `BackfillWorker.tick/0` precedent. No `code_interface` define.
- **reach `fixed_shape_map` / clone** — single-source the stamp/renew SQL; `get_env |>
  Keyword.get` for config.
- **reach `behaviour_candidate`** — Sidecar is a `Task`; Middleware has one callback;
  `.reach.exs` ignore if flagged (Sweepers precedent).
- **compile_check (zero warnings)** — raw SQL ⇒ no `import Ecto.Query`; no unused aliases.
- **Allocate touch** — guarded no-op; re-run Allocate + Projection suites.
- **No migration** — confirm `mix ash.codegen --check`. **`mix format`.**

---

## Documentation reconciliation

- **WS1-lease-core.md** — move **Component 4 (Pooler)** + **D2** to WS3; reframe `:claim_next`
  as the reconstruction-independent primitive (tested, caller-less); note the fence branches
  as unit-tested / WS3-triggered; reword test #1 to the SQL-pin reality. Fix stale refs: claim
  attrs `:367-380`; composer sites `route_composer.ex:1186`/`:1385`; `gate_resume.ex:162` calls
  `run_killable/4`; BackfillWorker WHERE `backfill_worker.ex:187-191`.
- **WS3-*.md** — broaden mandate to **continuous reclaim covering clustering dead-node AND
  single-node intra-node task-death**; take the Pooler + reclaim-dispatch + the fence trigger.
- **README.md** coverage matrix — add the single-node task-death gap (`run_execution.ex:53-63`
  "No owner-monitor"), owned by WS3.

---

## Verification

1. `mix compile --warnings-as-errors` / `mix jidoclaw.compile_check`.
2. `mix ash.codegen --check` → no pending migration.
3. `mix test test/jido_claw/orchestration/workflow_lease_test.exs`.
4. Regression: `mix test test/jido_claw/orchestration/` (Allocate/Projection/recovery/
   cancellation/reactor_runner/gate_resume byte-identical).
5. Tidewave `project_eval`: launch a module reactor via `run/3`; assert `claim_token` non-nil
   + `claimed_by == to_string(Node.self())` + `:completed`; `renew(id, token)` → `{:ok, 1}`,
   bogus → `{:ok, 0}`; `stamp(id, new, stale_expected)` → `{:ok, :lost}`.
6. **Completion bar:** full `mix precommit` passes. Nothing committed — left unstaged.

## Critical files to read first

- `lib/jido_claw/orchestration/run_execution.ex` (`:96-131`) — registration-gates-`Reactor.run`
  (the ownership fix) + the shared-sandbox `$callers` model.
- `lib/jido_claw/orchestration/reactor_runner.ex` — token threading (`:297-324`),
  `ensure_middleware` normalize (`:369-375`), fence A (`:590-600`, `:633-642`), `append_failed`
  (`:775-809`).
- `lib/jido_claw/orchestration/workflow_event/changes/allocate.ex` (`:101-132`) — fence B.
- `lib/jido_claw/orchestration/workflow_run.ex` — `:claimable` (`public?(false)` + bypass `:24`),
  claim columns (`:367-380`).
- `lib/jido_claw/orchestration/gate_resume.ex` (`:151-180`) — fresh-context token.
- `lib/jido_claw/trace/resources/trace_run.ex` (`:218-286`) + `test/.../retention_sweeper_test.exs`
  (`:77-91`) — lock + sandbox-test pattern.
