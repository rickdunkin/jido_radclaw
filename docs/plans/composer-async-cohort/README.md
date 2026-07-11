# Plan: Composer-cohort async enablement (+ one standalone production fix)

*Scoped 2026-07-10 from the async test campaign (Waves 1+2, 238 async files).
Status: **not scheduled** — the operator intends to take this on eventually,
likely piecemeal. Each item below is independently landable and carries its own
value; nothing here blocks anything else in flight. Evidence gathered by a
five-way cohort audit plus a dedicated composer dependency map (this doc is the
durable record of both).*

**Decision context.** The suite's wall time is dominated by its serial sync
tail, and ~40% of that tail is ONE cohort: the route_composer/eval composer
tests (~82s of a 198.8s serial trace run; measured via
`mix test --slowest-modules 40`, 2026-07-10). Precommit already banked the
cheap win — its test phase now runs `scripts/test-partitioned.sh` (~71s vs
~170s serial). This project is the only remaining test-time refactor whose
payoff clears the bar, and it compounds: nearly every future orchestration
feature adds tests to this cohort, and once the seams exist those tests are
async by default. Direct production value is limited to **Item 0**; the
indirect value is a harness that can finally exercise single-node
multi-composer concurrency (production runs composers concurrently constantly;
the suite structurally cannot today — cluster `:peer` tests cover cross-node
only).

**The measured prize** (serial module times, trace mode):

| Module | Time |
| --- | --- |
| ComposerDurableTest | 26.4s |
| ComposerSelfHealLoopTest | 19.5s |
| VerifyStageTest | 12.2s |
| ComposerLoopTest | 7.6s |
| ComposerReviewStallTest | 4.7s |
| EvidenceFloorTest | 3.7s |
| ComposerSystemLoopTest | 2.4s |
| ComposerLeaseTest | 1.3s |
| Eval composer cases (4 files) | ~6.5s |
| **Cohort total** | **~82s (~40% of serial suite time)** |

**Payoff honesty (read before committing).** The 82s is ~174 hermetic tests at
~0.47s each of **real serialized DB work** (20–40 event appends per converging
run, projection reads, Reactor overhead) on one shared-mode sandbox
connection — NOT idle waiting. Poll helpers are ceilings (50ms/20ms intervals;
the 15–60s literals never approach on a passing run) and deliberate sleeps
total ~2–4s across the cohort. So asyncing wins by giving each test its own
sandbox connection (parallelizing DB-bound work across cores + Postgres
backends), not by overlapping waits. Expect a material but sub-linear cut —
not 82s→26s — and expect it to stress the two latent budgets in the Risks
section.

---

## Item 0 — `current_owner?/2` timeout-vs-dead eviction (STANDALONE, production)

**The only piece with direct production value. Do it first, independent of
everything else; an afternoon.**

`RouteComposer.current_owner?/2`
(`lib/jido_claw/route_composer/route_composer.ex:805-809`) calls
`GenServer.call(pid, :get_claim_token, @owner_call_timeout)` (5_000ms, `:205`)
and folds **every** exit into `false` via `catch :exit, _`. A call **timeout**
exits too — so a composer that is merely busy >5s (long wave fold on a
saturated node) looks like a stale owner to any concurrent `ensure_started`,
and `ensure_current_owner/3` (`:789-797`) **terminates the live composer**
(`DynamicSupervisor.terminate_child`) and restarts it. The most plausible
concurrent caller is the ReclaimPooler after a heartbeat lapse caused by the
same load — kill/restart churn amplifying the load spiral that triggered it.
The durable envelope makes this safe-but-wasteful (rebuild from the event log;
the in-flight wave finishes into the void), not corrupting.

**Fix shape:** distinguish "timed out but alive" from "dead / stale registry
entry" — e.g. on `{:timeout, _}` check `Process.alive?(pid)` and the lease
freshness before evicting, or use a tiered retry. Keep the exact-token-equality
semantics untouched (`:799-804` — the nil-permissive fence variant is the
swallowed-reclaim bug this code exists to prevent).

**Test:** a composer whose `:get_claim_token` is artificially delayed past the
timeout must NOT be evicted while its lease is fresh; a genuinely dead pid must
still evict. (An async cohort would have found this wart on its own — see the
concurrency-capability argument above.)

---

## The dependency map (evidence base)

### 1. One `$callers` break, one primary DB writer

Trace of a composer run (`run_sync/1` path; `ensure_started/2` is identical
downstream):

- Test → `RouteComposer.run_sync/1` (`route_composer.ex:1065`) →
  `create_parent_run/1` (`:419,450`) — **in the test process**; the ONLY
  composer write on the owner chain (WorkflowRun + genesis events).
- `start_composer/2` → **`GenServer.start`** (`:733-734`) or `ensure_started/2`
  → **`DynamicSupervisor.start_child`** (`:776,861`) — **`$callers` drops
  here. This is the single break.**
- Composer `init/1` + `handle_continue(:rebuild)` (`:1147,1539`) — DB reads +
  writes begin **on the composer's first scheduler turn**.
- Wave dispatch → `ReactorRunner.run(async?: false)` (`:1806,1889,3255`) →
  `RunExecution.run_killable/4` → **`Task.Supervisor.async_nolink`**
  (`reactor_runner.ex:597`, `run_execution.ex:107`) — **`$callers` is
  explicitly propagated** (`run_execution.ex:121` says so, verbatim: "so Ecto
  sandbox allowances work in tests"). Reactor-internal async steps ride a
  PartitionSupervisor the same way (`run_execution.ex:46-48`).
- Stage stubs (`:step_agent_server` → `StubWorker.ask/3`) read ETS only
  (`test/support/jido_claw/route_composer/composer_stubs.ex:159-171`).
- Folds/commits/terminals — written **from the composer process**
  (`route_composer.ex:1751,1781,1835,1905,1934`).

**Consequence:** the composer pid is per-run (registered by `parent.id` in
`RouteComposer.Registry`, `:777`), and one
`Sandbox.allow(Repo, test_pid, composer_pid)` covers the composer AND — via
preserved `$callers` — the entire wave/step subtree. **No injection point
exists today**: `run_sync` never exposes the pid and blocks on the terminal
(`:1070-1075`); `ensure_started` returns the pid but `init`+rebuild race any
external allow.

**Off-chain writers OUTSIDE the would-be allow tree** (need separate handling):

- `Audit.AsyncWriter.enqueue` uses `Task.Supervisor.start_child` — NOT
  `async_nolink` — dropping `$callers` (`audit/async_writer.ex:48`).
  Best-effort (`safe_record` never raises); only matters if a test asserts
  composer-run audit rows. `TenantCase` on_exit already flushes.
- Eval fake-executor path only: `ForgeExecutor` → `Forge.Manager` (global
  singleton) → `DynamicSupervisor.start_child` of a `Forge.Harness`
  (`forge_executor.ex:518,660`, `forge/manager.ex:221`) which writes via
  `Persistence.record_*` (`forge/harness.ex:711,809`). The eval tests already
  neutralize this with `Forge.Persistence enabled: false` (`persistence.ex:20`).

### 2. App-env seam inventory (every key the cohort mutates)

**Class (b) — plumbable stub-behavior keys.** All read by test-support stubs
(`composer_stubs.ex`, `verify_stub.ex`, `scripted_deposit_runner.ex`, the
evidence StubReader); NONE has a lib reader. They are a global side-channel
from `setup` to stubs running inside the composer subtree:

`:route_composer_stub_outputs` (`composer_stubs.ex:84,415`),
`:route_composer_review_flag_on`/`_infra_on`/`_error_on`/`_finding_on`
(`:382-431,449`), `:route_composer_fixer_signals` (`:405`),
`:route_composer_system_verify_fails` (`:344`), `:route_composer_verify_stub`
(`verify_stub.ex:85`), `:route_composer_gate_armed` (`:273` — read-modify-write:
the stub itself put_envs the disarm at `:274`), `:route_composer_gate_pid`
(`:260` — a single global pid), `:route_composer_capture_context`/`_capture_task`
(`:139-141` — single global pid), `:route_composer_block_ms` (`:191`),
`:executor_fake_outputs` (`forge_executor.ex:200`), `:scripted_deposit_runner`
(`scripted_deposit_runner.ex:83`), `:evidence_stub_rows_sequence`
(`evidence_floor_test.exs:38`).

**The per-run alternative already exists:** stubs receive `tool_context`
(`composer_stubs.ex:78-79`), fed from composer `state.context` →
`ReactorRunner.run(context:)` → `build_tool_context`
(`agent_runner.ex:310-318`). Thread `parent_run_id` into `state.context` and
every stub can key behavior — and the `StubStore` ETS counters, which are
globally keyed today (`bump(:system_verifier_calls)` `:343`,
`bump({:reviewer_calls, lens})` `:379`, `verify_stub.ex:32`) — by run id.

**Class (c) — genuinely global wiring** (module swaps; live in `config/test.exs`
as suite-wide defaults — do NOT try to make per-run; just stop mutating them
per-test): `:step_agent_server` (`agent_runner.ex:47`),
`:agent_templates_override` (`templates.ex:283` — precedence chain already
per-run-capable via the catalog in `WorkflowRun.config`), `:evidence` reader
(`verify/evidence.ex:13`), `:verify` runner/git modules, `:ac_extract_generate`
(`ac_extractor.ex:168`), `:jido_ai, :model_aliases`, `Forge.Persistence`
enabled-flag, `:executor_vendor_runners` (`forge_executor.ex:841` — could
migrate onto per-stage `executor_config` if ever needed).

**Already per-run (use, don't rebuild):** the verify **command** override —
`run_sync`/`ensure_started` opt → `state.verify_override` → merged into verify
inputs (`route_composer.ex:1787`; exercised at `verify_stage_test.exs:513,601`).

### 3. Global-quiet assumptions in the tests

1. **`await_composer_process/1`** (`composer_loop_test.exs:998-1025`) scans
   `Process.list()` for `$initial_call == {RouteComposer, :init, 1}`; the
   comment at `:996` says async:false makes it "the only composer alive."
   Test-only; fix by taking the pid from `ensure_started` or registry lookup
   by `parent.id`.
2. **`drain_run_registry`** waits for `Registry.count(RunRegistry) == 0`
   (`composer_loop_test.exs:1063-1080`, `composer_durable_test.exs:2252`).
   Under async it never reaches 0 and silently burns its ceiling — and it is
   the guard against the teardown race below. Fix: run-scoped drain (lookup by
   `parent.id`).
3. **`RunPubSub.subscribe_gates()` + bare `assert_receive`**
   (`composer_loop_test.exs:353,398,446,518`; `review_stall:352`): the gates
   topic is global (`run_pubsub.ex:13`), and a bare receive binds the first —
   possibly foreign — event. **Production already filters by run id**
   (`route_composer.ex:1470-1484,1532-1537`); only the tests don't. Fix:
   filter receives by tenant_id (carried in the info map, `run_pubsub.ex:59`).
4. `composer_parent_run` lookups are **already safe** — scoped by the unique
   per-test tenant, not by serial execution (`composer_loop_test.exs:1013-1018`).
   Telemetry: only `verify_stage_test.exs:235` attaches; needs unique
   handler-id + stage/run filtering (minor).

No unscoped aggregates, no fixed tenant literals — `seed_tenant`/`seed_full`
uniqueness is the isolation that already works.

---

## Phases (each independently landable)

**Phase 1 — owner-pid threading + self-allow (the root-cause fix).**
Thread an `owner:` opt through `build_start_opts` (`route_composer.ex:733,776`);
`init/1` (`:1147`) calls `Ecto.Adapters.SQL.Sandbox.allow` before its first DB
touch, test-env-gated. Production byte-identical (opt never passed in prod).
One allow covers the whole subtree (§1). Contained to `RouteComposer`.

**Phase 2 — run-keyed stub state.** Thread `parent_run_id` into
`state.context`; migrate the class-(b) keys and the `StubStore` counters to
run-id keying. Touches `route_composer.ex` (one context key),
`composer_stubs.ex`, `verify_stub.ex`, `scripted_deposit_runner.ex`, the
evidence StubReader. Test-support-heavy; zero prod behavior change. This is
the highest-leverage single change — it also unlocks writing genuine
multi-composer concurrency tests.

**Phase 3 — de-globalize the three test assumptions** (§3.1–3.3). Pure
test-file mechanics once Phases 1–2 exist.

**Phase 4 — split kill/orphan tests into a sync file; flip the rest one file
at a time.** Do NOT try to solve the orphan teardown race (below); extract the
kill/timeout tests (`composer_loop_test.exs:948` 400ms kill, the
BlockingAgentServer paths, composer_durable's kill tests) into e.g.
`composer_kill_test.exs` staying `async: false` with the reason annotated, and
flip the remainder. Watch the latent budgets on every flip.

## What NOT to do

- **Don't chase the orphan teardown race.** Killed composers deliberately let
  in-flight waves outlive them and finish "durably into the void"
  (`route_composer.ex:1043` moduledoc). Under owner mode those orphans are
  allowed only transitively via the dead composer; `TenantCase`'s
  `stop_owner` on exit races their final writes, and the only existing guard
  is the global `RunRegistry.count == 0` drain (§3.2) — i.e., the guard IS a
  global-quiet assumption. Run-scoped drain plus owner-lifetime-tied-to-orphans
  is real architecture work for exactly the tests that verify kill semantics.
  Keeping those few tests sync costs ~2–4s of serial time. Not worth it.
- **Don't make class-(c) wiring per-run.** Suite-wide `config/test.exs`
  defaults are fine; the async blocker was per-test mutation, not existence.

## Risks / latent budgets concurrency will stress

- **`@owner_call_timeout 5_000`** (`route_composer.ex:205,806`): under N-way
  concurrent composers a trip evicts a live owner (Item 0). Land Item 0 before
  or with Phase 4.
- **15s verify-recovery awaits** (`verify_stage_test.exs:316,351,535,560,573`):
  a normally-300ms run can crawl toward the ceiling if Postgres saturates.
- Bare-receive gate waits become sift-through-foreign-messages under load
  (fixed by Phase 3).
- `AsyncWriter` `$callers` drop (§1): only matters if a flipped test asserts
  audit rows — none does today.

## Verification bar (same as Waves 1+2)

Per flipped file: green in the flipped-batch run, then full suite at ≥2 varied
seeds, `scripts/test-partitioned.sh` twice, `mix precommit`. Watch for
owner-eviction log noise and verify-await crawl specifically.

## Deviations

*(Record deviations from this plan here as they happen, per AGENTS.md — what
the plan assumed, what the code revealed, what was chosen and why.)*
