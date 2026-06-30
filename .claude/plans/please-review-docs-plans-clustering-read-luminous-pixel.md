# WS5 — Cross-node cancellation

## Context

JidoClaw's live-run cancel switch (`Cancellation.cancel/2`, dashboard-only via
`WorkflowsLive`) is **durable-decision-first**: it appends the terminal
`run_cancelled` event (one transaction with pending-case cancellation) and only
*then* kills the live executor. The durable half is already cluster-correct — a
DB write works regardless of which node issued it. The **kill** is the node-local
half: `Cancellation.kill_if_live/1` → `RunExecution.lookup/1` →
`Process.exit(pid, :kill)`, and `lookup/1` reads the node-local `RunRegistry`
(`application.ex:154`, `keys: :unique`). So a cancel issued on node A cannot find
or kill an executor running on node B.

Today (WS1 lease shipped, but `cluster_enabled: false` by default) this is latent.
Under clustering it means: the cancel lands durably, but the remote executor
keeps burning until its **next status write** trips the terminal-reload guard
(`run_execution.ex:33-42` / `ReactorMiddleware`) and self-stops. (Note: a plain
cancel does *not* rotate the `claim_token`, so the WS1 lease *renew* does **not**
fence it — only a WS3 reclaim rotates the token. The terminal-reload guard is the
real fallback, not the lease fence — the WS5 doc's "Current state" is imprecise
on this.) Net: an in-flight, possibly expensive LLM/tool call can run for one more
step after the operator clicked cancel.

**Outcome:** route the kill to the node that owns the run (`run.claimed_by`, set
by WS1), closing the latency/waste gap. This is a **latency fix, not a correctness
fix** — the durable decision already wins; an unroutable/dead owner is covered by
WS3 reclaim. Single-node behavior stays byte-identical.

This implements **WS5** as scoped in
`docs/plans/clustering/WS5-cross-node-cancellation.md` (closes T2-4's
"cluster-correct cancellation" deferral). The substantive WS5 logic — the routing
*decision* and the terminator *receiver* — is fully tested single-node. The one
thing that cannot be exercised on a single BEAM is the actual cross-node `cast`
*delivery* to a genuinely remote node; that is **WS6's** documented item (the
`:peer` multi-node test harness) and is explicitly out of scope here.

## Design

Three small pieces; the durable-first ordering in `cancel_live/4` is untouched.

1. **Extract `RunExecution.kill_local/2`** — the existing `kill_if_live/1` body,
   parameterized on `(run_id, tenant_id)`: `lookup/1` → tenant-pin
   (`{:ok, pid, ^tenant_id}`) → `Process.exit(pid, :kill)`; a tenant mismatch logs
   a warning and does **not** kill; a registry miss is a no-op. This becomes the
   *single source of truth* for the tenant-pinned local kill, called by both the
   local cancel path and the remote terminator. It lives in `RunExecution` because
   that module already owns `lookup/1`, the registry, and the kill mechanics — and
   both callers' dependency arrows already point into it (putting it in
   `Cancellation` would drag the whole cancellation domain — PubSub, WorkflowLog,
   Cases — into a process whose only job is `Process.exit`).

2. **New per-node GenServer `JidoClaw.Orchestration.RunTerminator`** — a tiny,
   stateless, **reactive-only** receiver (`name: __MODULE__`, one per node,
   reached cross-node as `{RunTerminator, node}`). Its sole job:
   `handle_cast({:kill, run_id, tenant_id}, state)` → `RunExecution.kill_local/2`.
   No timer, no DB, no PubSub → **no `enabled?` gate and no `init/1` self-gate**
   needed (it's as inert as `RunRegistry` until a cast arrives; a cast can only
   come from a remote `Cancellation` routing decision). Always-on, every serve
   mode, every node — the local cancel path must work single-node too, so it is
   **not** `cluster_enabled`-gated.

3. **`Cancellation.kill_if_live/1` becomes a 3-way router** driven by a **pure,
   unit-testable resolver** `resolve_kill_target/3`:
   - `:local` → `RunExecution.kill_local(run.id, run.tenant_id)` — **synchronous**,
     byte-identical to today.
   - `{:remote, node}` → `GenServer.cast({RunTerminator, node}, {:kill, run.id, run.tenant_id})`
     — fire-and-forget (the durable decision is the guarantee; a bounded `call`
     would add a cross-node timeout failure surface to the dashboard for zero
     correctness gain — this matches `Cron.Owner.notify_changed/1`'s follower cast
     at `owner.ex:167`, *not* the `call`-based `trigger/2`).
   - `:unroutable` → `:ok` no-op (owner gone/disconnected; WS3 reclaim covers it —
     the WS5 doc's D2).

### Route on the *post-append* struct (the stale-`claimed_by` race)

`cancel_live/4` currently appends `run_cancelled`, then kills using the struct it
read *before* the append (`cancellation.ex:165-180`). A run can be read as
`:pending`/unclaimed and *then* get stamped + started on a remote node before the
cancel append wins — so routing on the pre-append struct sees `claimed_by = nil`,
falls to `:local`, and misses the remote executor. Fix: **reload after
`terminate_cancelling_cases/4` commits, route on the fresh struct, and reuse that
same reload for the broadcast** (`finish/4` already reloads — collapse to one
read). This is safe and authoritative: once the run is terminal, no new stamp can
win (`WorkflowLease.stamp/4` gates on `status IN ('pending','running')`), so the
post-append `claimed_by` is frozen. A freak reload failure degrades to the
entry-time struct (durable cancel already won) — unchanged from `finish`'s current
fallback.

### Single-source the node identity (no raw `Node.*`)

`claimed_by` is written as `WorkflowLease.node_identity/0`
(`= to_string(JidoClaw.Cluster.local_node())`, `workflow_lease.ex:107-109`). The
router compares against that exact wrapper and resolves remote nodes via
`JidoClaw.Cluster.nodes/0` (connected nodes excl. self, `cluster.ex:13-16`) — not
raw `Node.self()`/`Node.list()`. The resolver stays **pure** (identity string +
node list passed as args), matching node *strings* over the candidate atoms
(never `String.to_existing_atom/1` — avoids the unknown-atom crash class):

```elixir
@spec resolve_kill_target(String.t() | nil, String.t(), [node()]) ::
        :local | {:remote, node()} | :unroutable
def resolve_kill_target(nil, _self_identity, _other_nodes), do: :local
def resolve_kill_target(claimed_by, self_identity, other_nodes) do
  if claimed_by == self_identity do
    :local
  else
    case Enum.find(other_nodes, &(to_string(&1) == claimed_by)) do
      nil -> :unroutable
      node -> {:remote, node}
    end
  end
end

# router (kill_if_live/1):
case resolve_kill_target(run.claimed_by, WorkflowLease.node_identity(), Cluster.nodes()) do
  :local -> RunExecution.kill_local(run.id, run.tenant_id)
  {:remote, node} ->
    Logger.debug("[Cancellation] routing kill for #{run.id} to #{node}")
    GenServer.cast({RunTerminator, node}, {:kill, run.id, run.tenant_id})
  :unroutable -> :ok
end
```

`claimed_by == nil` and the local-identity case both resolve `:local` →
byte-identical to today's unconditional `kill_if_live`. Tests drive the resolver
with synthetic identity strings + atom lists, exactly like `Leader.elect/1`
(`leader_test.exs:67`).

## Implementation steps

### 1. `lib/jido_claw/orchestration/run_execution.ex`
- Add `require Logger` in `StrictModuleLayout` position: **after `@moduledoc`,
  before** the `@registry`/`@task_supervisor`/`@registration_conflict` attributes.
- Add public `kill_local/2`:
  - `@spec kill_local(String.t(), term()) :: :ok` — tenant param is `term()`
    (matches `lookup/1`'s `{:ok, pid(), term()}` registry-value type; narrowing to
    `String.t()` risks a dialyzer mismatch).
  - Body = current `kill_if_live/1` logic parameterized on `(run_id, tenant_id)`,
    including the wrapped (≤120-char) tenant-mismatch `Logger.warning` and the
    `:error → :ok` no-op. All three branches return `:ok`.

### 2. `lib/jido_claw/orchestration/run_terminator.ex` (NEW)
- Real `@moduledoc` (per-node remote-kill receiver; reactive-only/inert; best-effort,
  durable decision + WS3 reclaim are the guarantees; tenant pin lives in
  `RunExecution.kill_local/2`; real cross-BEAM delivery is WS6).
- `use GenServer`; `alias JidoClaw.Orchestration.RunExecution`.
- `@spec start_link(keyword()) :: GenServer.on_start()` +
  `def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)`
  (copy `ReclaimPooler`).
- `@impl GenServer def init(_opts), do: {:ok, %{}}` (no gate, no timer).
- `@impl GenServer def handle_cast({:kill, run_id, tenant_id}, state)` →
  `RunExecution.kill_local(run_id, tenant_id); {:noreply, state}`.
- Layout order (StrictModuleLayout): moduledoc → `use` → `alias` → public
  `start_link` → `@impl GenServer` callbacks. (No `require Logger` here.)

### 3. `lib/jido_claw/orchestration/cancellation.ex`
- Add aliases (alpha-ordered with the existing block at `:60-66`):
  `alias JidoClaw.Cluster` and `alias JidoClaw.Orchestration.WorkflowLease`
  (for the router) and `alias JidoClaw.Orchestration.RunTerminator`. Let
  `credo --strict`'s `AliasOrder` confirm final placement.
- Add the public pure `resolve_kill_target/3` (above), with `@spec`.
- **Reload-once refactor of `cancel_live/4`** (`:165-180`): on `{:ok, _event}`,
  reload the run, pass the **reloaded** struct to `kill_if_live/1`, then broadcast
  + return via a `finish/1` that takes the already-reloaded run (drop the second
  reload now living inside `finish/3`). The `{:error, _}` →
  `explain_append_failure/4` branch is unchanged.
- Rewrite `kill_if_live/1` (`:195-213`) as the 3-way router (above). Add the
  `Logger.debug` on the `{:remote, node}` branch. Keep it `defp`.
- **Doc-only:** update the moduledoc sentence at `:28` and the `kill_if_live`
  comment at `:192-194` to reference `RunExecution.kill_local/2` + the
  reload-then-route flow (they otherwise go stale).

### 4. `lib/jido_claw/application.ex`
- Insert `JidoClaw.Orchestration.RunTerminator,` into `infra_children`
  **immediately after** `{Task.Supervisor, name: JidoClaw.Orchestration.RunTaskSupervisor}`
  (`:155`) — as a **bare module atom** (like `ReclaimPooler` at `:171`), with a
  short comment. Adjacent to `RunRegistry` (which `kill_local/2` looks up through);
  inside `infra_children` so it tears down before Repo/PubSub on shutdown.
- **No** `cluster_enabled` gate. **No** change to the file-level
  `# reach:disable-for-this-file fixed_shape_map` pragma (bare atom, not a `%{id:}`
  map → already covered).

### 5. `.reach.exs` — NO CHANGE
The `behaviour_candidate` smell fires only when ≥3 modules share a byte-identical
public-callback signature; `RunTerminator`'s `[handle_cast/2, init/1, start_link/1]`
shape has no such cluster in the repo (verified against reach's source by the
design review). Adding an ignore entry would be a dead no-op. Confirm with
`mix reach.check --smells --strict` (expected green); add the entry **only** if it
actually flags — it won't.

## Test plan (single-node)

Covered single-node: the routing **decision** (resolver, all branches), the
terminator **receiver** (kill + tenant-refusal + miss), durable-first-when-unroutable,
and the local-path regression. **Not** covered single-node — and explicitly left
to WS6's `:peer` harness — the actual `GenServer.cast({RunTerminator, remote_node}, …)`
*delivery* to a genuinely remote node (the resolver returns `:local` for self, and
a disconnected node atom can't receive a cast on one BEAM). State this boundary in
the new test modules' `@moduledoc`.

- **`test/jido_claw/orchestration/cancellation_routing_test.exs` (NEW, `async: true`)**
  — pure `resolve_kill_target/3`, synthetic identity strings + atom node lists
  (`:a@h`, `:b@h`), all four outcomes: `nil → :local`; identity match → `:local`;
  string-match in `other_nodes` → `{:remote, node}`; in neither → `:unroutable`.
- **`test/jido_claw/orchestration/run_terminator_test.exs` (NEW, `async: false`,
  no DB — plain `ExUnit.Case`)** — cast to the **already-running** app singleton via
  `{RunTerminator, Node.self()}` (single-BEAM stand-in; do **not** `start_supervised!`
  a second — name collision). Critical: `Registry.register/3` registers the
  **calling** process, so the **dummy must register itself and signal ready**, and
  the test asserts a monitored `:DOWN` rather than polling `Process.alive?`:
  ```elixir
  dummy = spawn(fn ->
    {:ok, _} = Registry.register(JidoClaw.Orchestration.RunRegistry, run_id, tenant)
    send(test_pid, :ready); Process.sleep(:infinity)
  end)
  assert_receive :ready
  ref = Process.monitor(dummy)
  GenServer.cast({JidoClaw.Orchestration.RunTerminator, Node.self()}, {:kill, run_id, tenant})
  assert_receive {:DOWN, ^ref, :process, ^dummy, :killed}
  ```
  Plus two more cases:
  - **cross-tenant** cast (`{:kill, run_id, "other"}`): wrap **both** the cast
    **and** a `:sys.get_state(RunTerminator)` sync barrier inside
    `ExUnit.CaptureLog.capture_log/1` (cross-process logs need an explicit
    synchronization point before the captured string is read — the barrier
    guarantees the cast was handled), then assert the returned log `=~` the
    mismatch warning and `Process.alive?(dummy)`. The dummy survives **by
    design**, so register an `on_exit(fn -> Process.exit(dummy, :kill) end)`
    (or kill it right after the assertion) — don't leak a sleeping process into
    the shared singleton registry.
  - **registry-miss** cast (`{:kill, "no-such-run", tenant}`): terminator survives
    — same `:sys.get_state(RunTerminator)` barrier, then `Process.alive?`.

  Use unique `run_id`/`tenant` strings per test (shared global `RunRegistry`); the
  terminator touches no DB, so no sandbox needed.
- **`test/jido_claw/orchestration/cancellation_test.exs` (EDIT, `async: false`)** —
  add **durable-first-when-unroutable** (the WS5 doc's named acceptance item):
  extend `strand_running/1` (`:237`) to stamp `claimed_by: "jidoclaw@ghost"` (a
  bogus, unconnected node), assert `cancel/2` still returns
  `{:ok, %{status: :cancelled}}` and `run_cancelled` landed — proving the append
  precedes routing and an unroutable owner doesn't break the cancel.
- **Local-path regression** — the existing live-kill test (`cancellation_test.exs:58-75`,
  synchronous `refute Process.alive?(executor)`) **must stay green untouched**:
  the `:local` branch calls `kill_local/2` synchronously. This is the single most
  important regression guard. Re-run the registration-conflict test (`:173-197`) too.

## Precommit gates (the bar for "done")

Run via `mise exec -- mix precommit`. Full alias is 8 steps (`mix.exs:251-260`):
1. **`jidoclaw.compile_check`** — zero-warning clean compile (allowlist empty).
   Watch the type checker for any unreachable-clause warning on the resolver.
2. **`jidoclaw.system_prompt.check`** — no system-prompt drift (WS5 touches none;
   should pass untouched).
3. **`deps.unlock --unused`** — no unused deps (WS5 adds none).
4. **`format --check-formatted`**.
5. **`reach.check --arch --smells --strict`** — expected green, no `.reach.exs` edit
   (orchestration is unconstrained by the `web`/`data` arch layers).
6. **`credo --strict`** — `@impl GenServer` (never `@impl true`); `@spec` on every
   public fn (`start_link/1`, `kill_local/2`, `resolve_kill_target/3`); alpha-sorted
   aliases (new `Cluster`/`WorkflowLease`/`RunTerminator` aliases); **`StrictModuleLayout`**
   — `require Logger` must precede the module attributes in `RunExecution`.
7. **`dialyzer --format short`** — the 3-variant resolver union (all reachable),
   `kill_local/2 :: :ok`, `term()` tenant param.
8. **`test`** — full suite green (incl. the untouched local-path regression).

The plan is **not complete until `mix precommit` passes.**

## Verification (end-to-end)

1. `mise exec -- mix compile --warnings-as-errors` — clean.
2. Targeted: `mise exec -- mix test test/jido_claw/orchestration/cancellation_routing_test.exs test/jido_claw/orchestration/run_terminator_test.exs test/jido_claw/orchestration/cancellation_test.exs`.
3. Full gate: `mise exec -- mix precommit` (run bare in background, read the output
   tail — never pipe through `tail`, which masks the exit code).
4. Tidewave sanity (optional): `mcp__tidewave__project_eval` —
   `JidoClaw.Orchestration.Cancellation.resolve_kill_target("other@host", "me@host", [:"other@host"])`
   ⇒ `{:remote, :"other@host"}`; `resolve_kill_target(nil, "me@host", [])` ⇒ `:local`.

## Non-goals (this unit)

- **Real cross-BEAM `:peer` delivery test** — WS6's multi-node harness item.
- **Expanding the cancel surface** (CLI/MCP) — stays dashboard-only.
- **Token rotation / fencing on cancel** — WS5 routes a kill; it does not change the
  lease. Reclaim/fencing is WS3's domain.
- **Work-stealing / live-node rebalancing** — dead-node-only per the plan.

## Files

| File | Change |
|---|---|
| `lib/jido_claw/orchestration/run_execution.ex` | `require Logger` + new public `kill_local/2` |
| `lib/jido_claw/orchestration/run_terminator.ex` | **NEW** per-node GenServer |
| `lib/jido_claw/orchestration/cancellation.ex` | new aliases; `resolve_kill_target/3`; reload-once `cancel_live/4`; `kill_if_live/1` → router; 2 doc comments |
| `lib/jido_claw/application.ex` | register `RunTerminator` in `infra_children` after `:155` |
| `test/jido_claw/orchestration/cancellation_routing_test.exs` | **NEW** pure resolver tests |
| `test/jido_claw/orchestration/run_terminator_test.exs` | **NEW** terminator kill/tenant/miss tests |
| `test/jido_claw/orchestration/cancellation_test.exs` | + durable-first-when-unroutable test |
| `.reach.exs` | **no change** (verify green) |
