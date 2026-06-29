# Plan: WS3 — Reclaim & Recovery

## Context

JidoClaw can run as a multi-node cluster, but multi-node *workflow execution* is
not yet safe. The load-bearing gotcha: the boot reconciler `WorkflowRecovery`
**self-disables** under clustering (`workflow_recovery.ex:468-472`), and the
lease-expiry path meant to replace it does not exist — so `cluster_enabled: true`
today silently strands every interrupted run. WS1 (lease core) and WS2 (composer
lease) shipped; WS1 left `WorkflowLease.claim_next/1` complete but with **zero
production callers** and no claim→dispatch loop. This plan builds that consumer
and closes the single-node "No owner-monitor" gap (`run_execution.ex:53-63`).

### The governing insight

**Boot recovery and live reclaim are different paths with different liveness
assumptions, and must not share child-disposition logic verbatim.**

- **Boot** runs once when the BEAM has just restarted, so *nothing from the prior
  runtime is live* — every non-terminal run is dead by construction, decidable
  from DB state alone, with no surviving executor to fence.
- **Live reclaim** runs continuously *alongside live launches and executors* — a
  lease expiry proves only *that one run's* owner died, not its neighbours', and a
  still-alive zombie (e.g. a network partition) may need actively fencing.

The unifying rule WS3 adopts: **the lease is the liveness oracle.** A run (parent
*or* child) is dead — and reclaimable — **iff its lease has expired (or it is an
aged, never-claimed `:pending` row — the one leaseless case)**; and the act of
claiming it **rotates its token**, which is what fences any surviving zombie.

### Decisions locked (design review)

- **Q1 — stranded `:running` plain run, no checkpoint → fail (boot-parity).** The
  idempotency key is *launch-dedupe, not step-idempotency*, so re-running a
  partially-executed reactor double-executes side effects regardless of any key.
  No safe re-run today → fail. **No reactor-reconstruction seam is needed.**
- **Q2 — the reclaim Pooler is always-on**, in every serve mode (gateway / both /
  **mcp**) and both single- and multi-node — safe everywhere precisely because it
  is claim-gated (CAS), where the boot sweep is unguarded.
- **Q3 — one plan, M-sized.** Everything is reuse + one new GenServer + a selector
  tightening + a small lease-aware/zombie-fencing composer delta.

---

## Design

### Component 1 — `JidoClaw.Orchestration.ReclaimPooler` (the new process)

A per-node `GenServer` that drains the reclaim selector and routes each claimed
run, then re-polls on a timer.

```
reclaim_once():
  loop:
    case WorkflowLease.claim_next([]) do      # SAFE selector (Component 2); rotates the token
      :none            -> halt
      {:ok, run}       -> emit [:..., :reclaimed]; WorkflowRecovery.reclaim(run); continue
      {:error, reason} -> log; halt (retry next poll)
```

- `reclaim_once/0` is a **stateless module function** (drains to `:none`) so tests
  drive it directly — like `WorkflowRecovery.reconcile_all/0`.
- `handle_info(:poll, …)` calls it then reschedules `poll_interval_ms`; `init/1`
  self-gates (`owns_reclaim?/0` → first poll after `initial_delay_ms`, else
  `:ignore`).
- **Gating — `owns_reclaim?/0` = `reclaim_enabled?()`** (default true, false in
  test). **No `serve_mode`/`cluster_enabled` conditions** (unlike `owns_recovery?`):
  the boot sweep excludes MCP/clustering because it is *unguarded* (concurrent
  owners would race); the Pooler needs no exclusion because every claim is a
  `FOR UPDATE SKIP LOCKED` + token-CAS. MCP launches workflows (`run_skill` →
  `ReactorRunner.run`, `run_skill.ex:63-72`), so it must be covered.

File: `lib/jido_claw/orchestration/reclaim_pooler.ex`.

### Component 2 — a SAFE reclaim selector (fixes the fresh-pending steal)

**Problem:** `:claimable` clause 1 (`workflow_run.ex:252`) selects *any* `:pending`
run with a `nil` token immediately. But `ReactorRunner` creates the `:pending` run
*before* the lease middleware stamps it, so an always-on poller would **steal and
fail a legitimate just-created run** in that gap. (Boot never races live launches;
the Pooler does.)

**Fix — eligibility = "provably dead" only, via an action argument.** A runtime
grace can't live in a static compile-time filter, and ANDing a global cutoff would
wrongly constrain the expired-lease clause. So add a `:pending_cutoff` **argument**
to the `:claimable` action, referenced only in clause 1:

```elixir
read :claimable do
  argument :pending_cutoff, :utc_datetime_usec, allow_nil?: false
  ...
  filter(
    expr(
      (status in [:pending, :running] and not is_nil(claim_expires_at) and
         claim_expires_at < now())                                 # expired lease = true death
      or
      (status == :pending and is_nil(claim_token) and
         inserted_at < ^arg(:pending_cutoff))                      # genesis orphan, aged out
    )
  )
end
```

`WorkflowLease.read_claimable/0` computes `cutoff = DateTime.add(utc_now(),
-pending_grace_seconds(), :second)` (default grace `lease_seconds()` = 60s,
configurable) and passes it as the arg. `:claimable` has no other production
callers (`claim_next` is its only reader, WS3 its only caller), so tightening the
shipped action is correct. The **code-interface must pass the new arg**
(`define(:claimable, args: [:pending_cutoff])`), so the generated query builder
becomes arg-bearing — update `read_claimable/0` and any `query_to_claimable`
callers/tests (consult the **ash-framework** skill). WS1 `claim_next` tests that
expect immediate pending-claim must backdate `inserted_at` (helper
`backdate_inserted!/2` exists).

### Component 3 — plain-run reclaim (pure reuse)

Under Q1, boot and reclaim **agree** for plain (`workflow_type:"reactor"`) runs.
`claim_next` already rotated the token (fencing any zombie: a reconnecting zombie's
stale-token renew returns 0 → its sidecar self-kills, and any terminal it attempts
trips fence B). The Pooler routes the run through the existing classification via a
public `reconcile_one/1` wrapper over the private `reconcile_run/1`
(`workflow_recovery.ex:164`):

| claimed | `classify/1` | Outcome |
|---|---|---|
| aged `:pending` + nil token | `:stranded` | fail-with-audit |
| `:running` expired, no checkpoint | `:stranded` | `fail_stranded → :failed` (Q1) |
| `:running` expired, checkpoint + recorded decision | `:decision_recorded` | `GateResume.resume(recovered: true)` (same id) |
| `:running` expired, checkpoint, no recorded decision | `:decision_recorded` | forbidden pair → fail |

### Component 4 — composer reclaim (lease-aware + zombie-fencing children)

A reclaimed composer parent **cannot** reuse boot's `resume_composer` verbatim,
for two reasons:

1. **Liveness.** Boot's `reconcile_children` fails *every* non-terminal child;
   under live reclaim a `:running` child may be alive (a co-located wave executor
   that survived an intra-node composer crash), and `observe_existing_child`
   (`route_composer.ex:2747-2811`) blind-polls status until terminal or
   `wave_timeout_ms` (**300s**, `:193`) — the H6b stall + the H8 mis-handling of a
   mid-poll `:failed`.
2. **Fencing.** A child handled by the parent inline is *not* claimed by
   `claim_next`, so without explicit rotation a reconnecting zombie child (partition)
   keeps renewing its old token and re-runs the wave → unbounded double-execution.

**Fix — a reclaim-specific child step** (replacing boot's `reconcile_children`,
reusing the shared `restartable?/3` + `start_recovered_composer/3` tail):

- For **each non-terminal child**, call `WorkflowLease.claim_run/1` — which **locks
  the row (`FOR UPDATE`), checks the full `:claimable` predicate (expired lease
  **or** aged never-claimed `:pending` row), and on a match rotates the token +
  reloads**. The under-lock check is load-bearing two ways: (a) `stamp/4` alone
  checks token + status but **not expiry**, so a bare wrapper would steal a child
  that *renewed* between the parent's child-load and the claim (TOCTOU → a now-live
  child); (b) driving *every* non-terminal child through the **full** predicate — not
  a pre-filter to expired-lease only — is what stops an aged `:pending`+nil-token
  wave child (one that crashed before `Middleware` stamped it) from being skipped
  and **permanently blocking `restartable?/3`** (which rejects any non-terminal
  non-gate child). If claimable → `reconcile_one` the rotated child (→ `:failed`);
  if not (live lease, fresh-pending within grace, or leaseless parked gate) → leave
  it. `claim_next` shares this locked-claim core; rotation fences any surviving
  zombie within a renew window.
- **Leave** non-claimable children (live lease, fresh-pending) and parked gates
  untouched. The existing `restartable?` gate then defers the restart while a
  non-claimable non-gate child remains; the durably-`async_nolink`-completing child
  is **folded** on the eventual restart (`route_composer.ex:1434`) — no lost work,
  no double-exec.
- **Release-on-defer (token-fenced cooldown):** when deferring (a non-claimable
  non-terminal child remains), set `claim_expires_at` to `now() + poll_interval` via a
  **fenced** update on the held token (a short-interval `renew`-style write) —
  **not** `now()`. Expiring to `now()` would make the parent immediately
  re-claimable *within the same `reclaim_once/0` drain* → a hot-loop
  (claim→defer→claim…). The cooldown makes it re-claimable on the *next* poll —
  convergence ~`poll_interval`, no spin. (Belt-and-suspenders: also skip ids already
  deferred this sweep.)

**Boot stays unchanged and is justified by its own premise** — it fails *all*
non-terminal children because nothing from the prior runtime is live (true even
for an unexpired lease after a fast restart), and needs no rotation (no surviving
zombies). The boot-vs-reclaim difference is the explicit child-step, not a shared
filter equated by expiry.

The Pooler's single entry is `WorkflowRecovery.reclaim(run)`: composer parent
(`workflow_type=="composer" and status==:running`) → the reclaim child-step above;
else → `reconcile_one(run)`.

### Two distinct safety mechanisms (so "no fence-token threading" still holds)

- **Reclaimer-vs-reclaimer double-terminal** is handled by `lock_run`'s `FOR UPDATE`
  (`allocate.ex:174-183`) + the `:illegal` terminal-on-terminal guard
  (`projection.ex:162`, `allocate.ex:214-219`). So the reclaimer's own `run_failed`
  append carries **no** `claim_fence_token` and needs no `append_recovery` /
  `terminate_cancelling_cases` signature ripple.
- **Zombie fencing** is handled by **token rotation at claim time** — `claim_next`
  for parents/plain runs, `claim_run` for inline children — which invalidates the
  zombie's renew and trips fence B on any terminal it attempts. (The earlier draft
  omitted rotation for children; that gap is closed.)

### Boot vs reclaim are complementary

`owns_recovery?/0` is unchanged (boot stays single-node, non-MCP). The Pooler is
expiry-gated, touches only provably-dead runs, and is safe in every mode; the
`FOR UPDATE` + `:illegal` guard makes the single-node boot overlap idempotent, and
`initial_delay_ms` lets the boot one-shot win. Telemetry: the Pooler emits
`[:jido_claw, :orchestration, :reclaimed]` per claim; disposition rides the
existing `[:jido_claw, :orchestration, :recovered]` branch event.

---

## Files to create / modify

**Create**
- `lib/jido_claw/orchestration/reclaim_pooler.ex` — GenServer + `reclaim_once/0` +
  `owns_reclaim?/0` + telemetry.
- `test/jido_claw/orchestration/reclaim_pooler_test.exs`.
- `test/support/.../lease_helpers.ex` — lease seeders (`seed_run/2`, `set_claim!/3`,
  `backdate_inserted!/2`, `with_cluster_enabled/2`, `launch_blocking/1`) **extracted
  from the `defp`s** in `workflow_lease_test.exs` for cross-suite reuse.

**Modify**
- `lib/jido_claw/orchestration/workflow_lease.ex` — add `claim_run/1` (lock +
  re-verify `:claimable` under `FOR UPDATE` + CAS-rotate + reload) and a
  token-fenced cooldown-release helper (a short-interval fenced `renew`); refactor
  `claim_next`'s internal claim to share the locked-claim core; add
  `read_claimable/0`'s `:pending_cutoff` computation + grace config accessor.
- `lib/jido_claw/orchestration/workflow_run.ex` — `:claimable` gains the
  `:pending_cutoff` argument + clause-1 age filter, **and its code-interface updates
  to pass the arg** (`define(:claimable, args: [:pending_cutoff])`;
  `query_to_claimable` callers/tests updated) (Component 2).
- `lib/jido_claw/orchestration/workflow_recovery.ex` — public `reclaim/1` (composer
  vs plain) + `reconcile_one/1`; the reclaim-specific composer child-step
  (claim-rotate + fail expired children, leave the rest, release-on-defer), reusing
  `restartable?/3` + `start_recovered_composer/3`. **Boot path untouched.**
- `lib/jido_claw/application.ex` — supervise `ReclaimPooler` (`:permanent`,
  self-gating) beside the lease registries (`:153-161`).
- `config/config.exs` / `config/test.exs` — `:reclaim_pooler` block (`enabled?`,
  `poll_interval_ms ~15_000`, `initial_delay_ms ~5_000`, `pending_grace_seconds`);
  `enabled?: false` in test.
- Extract composer reclaim fixtures (`recoverable_parent/2`, `commit_wave0/3`,
  `craft_child/4`) from `composer_durable_test.exs` into the existing
  `test/support/jido_claw/route_composer/fixtures.ex`.

**Documentation reconciliation** (consult the **ash-framework** skill for the
action-argument + code-interface edits):
- `WS3-reclaim-and-recovery.md` — D2 + Design: stranded no-checkpoint → **fail**
  (key is launch-dedupe; re-run seam deferred until step idempotency exists).
  Pooler **always-on incl. MCP**; drop "never both run on the same run." Add the
  **boot ≠ reclaim** liveness distinction, the **lease-as-oracle** rule, and
  **token-rotation fencing of reclaimed children**. Fix the bullet that says
  `:awaiting_approval` reclaim resumes via `GateResume` (D1 is right; that path is
  `:running` + checkpoint + recorded-decision).
- `README.md` — line 73 "Step-level idempotency keys" → **run-level launch-dedupe**
  (composer parent carries none); coverage-matrix rows point at the always-on Pooler.
- `WS1-lease-core.md` — D2 always-vs-cluster lean is **decided: always-on**; note
  `:claimable` clause 1 gained the age-grace argument its first production caller
  requires, and that `claim_next`/`claim_run` share the CAS-rotate.

---

## Test plan

`test/jido_claw/orchestration/reclaim_pooler_test.exs`, `async: false`, using the
**extracted** `test/support` helpers.

- **No fresh-pending steal (P1)** — a just-created `:pending`+nil-token run (recent
  `inserted_at`) is not claimable; backdated past the grace, it is.
- **Plain stranded → fail (Q1)** — expired `:running` no-checkpoint → `:failed`;
  future-expiry run untouched.
- **Child token rotation fences a zombie (P1)** — a reclaimed corpse child's token
  is **rotated** (a `renew/2` with the *old* token returns 0, and an old-token
  status-authority append trips fence B), proving a reconnecting zombie is fenced.
- **Renewed-after-load child is not stolen (P1 TOCTOU)** — renew a child's lease
  (to a future expiry, same token) after the parent loads children but before the
  claim; `claim_run/1`'s under-lock expiry re-check returns `:lost` and the now-live
  child is left untouched (not rotated, not failed).
- **Defer does not spin (P1)** — a deferred parent (live child present) is **not**
  re-claimed within the same `reclaim_once/0` drain (cooldown release pushes its
  expiry to `now()+poll_interval`); it becomes claimable only on a later poll.
- **Composer node-death reclaim** — parent + expired corpse children + folded wave
  0 → `reclaim_once/0` claim-rotates+fails the corpses, restarts, folds wave 0,
  dispatches wave 1.
- **Composer live-child defer (P1)** — a reclaimed parent with one *live-lease*
  `:running` child: the child is not failed, the composer is not restarted
  (`restartable?` defers), the parent lease is released; after the child completes,
  a later `reclaim_once/0` restarts and folds it.
- **Aged-pending child doesn't block restart (P2)** — a leaseless aged
  `:pending`+nil-token wave child (crashed pre-stamp) is claimed+failed by the
  composer child-step (driven through `claim_run/1`'s full predicate, not skipped),
  so `restartable?/3` is not permanently blocked and the composer restarts.
- **Intra-node task-death** — launch single-node, kill the executor, expire the
  lease, assert reclaim+fail without a node restart.
- **Always-on, both modes** — `cluster_enabled: true` → boot off, reclaim on;
  `false` → both may touch one stranded run with ≤1 terminal (second `:illegal`).
- **Bounded window (P3)** — reclaimable no sooner than `claim_expires_at`, no later
  than expiry + one `poll_interval_ms`, asserted with a **clock-skew grace band**
  (eligibility is app-clock `now()`/cutoff vs DB-stamped expiry).

Cross-node "kill a node, watch another reclaim" stays the WS6 integration test.

---

## Known limitations / out of scope

- **No re-run/resume of stranded ungated plain runs** (Q1) — failed, not resumed;
  needs step-level idempotency (no current workstream). Documented.
- **Reclaim latency / multi-sweep convergence (P3).** Parent and child leases
  expire at slightly different times, so a composer may converge across a bounded
  window (≤ one lease window worst case; release-on-defer pulls the common case to
  ~`poll_interval`). Faster convergence needs node-down detection (`:pg`/cluster
  membership) — that's WS4/WS6, out of scope here.
- **Dangling gates / degraded-unleased under clustering** — hold no lease (D1), so
  outside the reclaim set; boot reaps them single-node only. WS3 strictly improves
  on today (which recovers nothing clustered). Recommend accepting as a documented
  residual; a periodic dangling-gate sweep is a possible follow-up.
- Live-node work-stealing / graceful drain — WS4 non-goal.

---

## Scope note

WS3 stays one cohesive M plan (no reactor-reconstruction seam). The review added
three bounded pieces on shipped machinery: the safe selector (Component 2), the
`claim_run/1` rotate helper (shared with `claim_next`), and the lease-aware +
fencing composer child-step (Component 4). If you'd rather de-risk, the split seam
is WS3a (Pooler + selector + plain reclaim + intra-node + MCP) / WS3b (composer
reclaim) — but I recommend keeping it whole, since splitting would either ship
composers reclaimed via boot's fail-all-children (unsafe under live zombies) or
leave composer reclaim unimplemented.

---

## Precommit & verification

**Not complete until `mix precommit` passes** (full gauntlet: `compile_check`
zero-warnings, `format --check-formatted`, Credo/reach strict at zero, Dialyzer,
tests). Traps:
- `reconcile_one/1` / `reclaim/1` / `claim_run/1` are real wrappers (return values,
  not pure forwarders) → no reach trivial-forwarder smell; refactor `claim_next` to
  *call* `claim_run` so the CAS-rotate lives once (clone gate).
- Keep `owns_reclaim?/0` / `reclaim_enabled?/0` from being a verbatim contiguous
  clone of `WorkflowRecovery`'s gate helpers.
- The `:claimable` argument + filter stays within the existing read action (no new
  action → no AshCredo interface gauntlet); re-run the WS1 lease suite after.
- Clean `@spec`s on every new public function.

**End-to-end**
1. `mix test test/jido_claw/orchestration/reclaim_pooler_test.exs`.
2. `mix test test/jido_claw/orchestration/workflow_lease_test.exs
   test/jido_claw/route_composer/composer_durable_test.exs` — confirm the
   `:claimable`/`claim_next` changes + helper extraction didn't regress WS1/WS2.
3. Tidewave / `project_eval`: expired `:running` → `ReclaimPooler.reclaim_once()` →
   `:failed`; composer parent + expired corpse children → resume from wave 1 with
   the child tokens rotated; live-lease child → restart deferred + lease released.
4. `mix test` — full suite green.
5. `mix precommit` — green.
