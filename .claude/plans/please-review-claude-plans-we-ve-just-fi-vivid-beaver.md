# RunServer end-to-end regression tests — author the deferred test file

## Context

Phase 3b's code-review fix plan
(`.claude/plans/we-ve-just-finished-working-eventual-phoenix.md`) lists six
test scenarios for a new `test/jido_claw/memory/consolidator/run_server_test.exs`
file (lines 708–733). The implementation PR shipped the production fixes but
skipped this test file with the note: *"That test scaffolding is non-trivial
and was not authored — adding it is the obvious next step before this PR
ships."*

Today's suite has zero coverage for the full run-now → fake-runner →
MCP-roundtrip → publish path. The bootstrap-race fix (the headline P1) is
unproven by tests; a future regression that re-introduces the race would
ship green. Three other behaviours from the same review (link forwarding,
update + supersedes link, defer_cluster watermark) also have no end-to-end
guard.

This plan authors the missing file. The substrate (`:fake` runner,
`run_now/2`, fact/link/block resources, `:fake` accepted by the
`ConsolidationRun.harness` enum) is already wired in `main` — no
production code changes are needed.

## What the file covers

Six test cases in a single `describe "end-to-end fake-harness run"` block.
Most map directly to the bullets at lines 711–733 of the source plan;
two diverge with reasons captured in the case notes:

1. **Bootstrap regression — happy path with Block + Fact**
   The headline test. Drives `Consolidator.run_now/2` with a non-trivial
   `:fake_proposals` script. Asserts `{:ok, %ConsolidationRun{status:
   :succeeded, harness: :fake, blocks_written: >= 1, facts_added: >= 1}}`
   and that the corresponding `Block` and `Fact` rows landed with the
   expected label/content. Without the bootstrap fix this fails with
   `{:error, "{:invalid_state, :bootstrapping}"}` (or the equivalent
   `:failed` audit row); with the fix it passes. This is the exact
   regression the source plan calls out at lines 717–720.

2. **`propose_link` forwards `relation` / `reason` / `confidence`**
   Seed two facts in the same scope, stage one `propose_link` proposal,
   assert a `Link` row exists with the right relation atom (`:supports`),
   `reason` string, and `confidence` float. Verifies issue 3a's plan-fix
   end-to-end (the schema extension + `apply_link_creates/1` + relation
   allowlist). `Staging.total/1` (`staging.ex:75`) counts every queue
   including `link_creates`, so a single link proposal is enough to
   bypass the `max_turns_reached` guard — no companion no-op block
   write is needed. Same simplification applies to tests 3 and 4.

3. **`propose_update` invalidates original + writes replacement + supersedes link**
   Seed one labeled fact (`label: "vacation_plans"`). Stage a
   `propose_update` for that fact's id. Assert: original is invalidated
   (`invalid_at != nil`), a new active row exists at the same
   `(tenant, scope, label)` carrying the proposal's `new_content` /
   `tags` and `source: :consolidator_promoted`, and a `:supersedes`
   `Link` points new → old. Verifies issue 3b end-to-end. Note: the
   labeled original is invalidated by `Fact.record/1`'s
   `InvalidatePriorActiveLabel` hook (`fact.ex:636-669`) when the
   replacement row is written, **not** by `maybe_invalidate_unlabeled/1`;
   the latter only fires for nil-labeled facts.

4. **`defer_cluster` (facts variant) — watermark stops at deferred row**
   Seed three facts with controlled `inserted_at` times via
   `Fact.import_legacy/1` (the only action that accepts `:inserted_at`
   as a writable argument — `Fact.record/1`'s accept list at
   `fact.ex:140` does not include it). Use distinct labels A/B/C in
   time order. Resolve B's cluster id via the public path:

   ```elixir
   [%{id: cluster_id_for_b}] = Clusterer.cluster([fact_b], 1)
   ```

   That avoids both private-formula duplication and any need to widen
   `Clusterer`'s API. Stage `defer_cluster` for that id; that single
   proposal also satisfies the `Staging.total > 0` gate (no-op block
   write not needed). Assert the audited
   `facts_processed_until_at`/`facts_processed_until_id` equals fact A's
   `(inserted_at, id)` — the last fact strictly before B's first
   loaded row.

5. **`defer_cluster` (messages variant) — single-cluster defer pins watermark to nil**
   Renamed from "watermark stops at row before deferred cluster" because
   that semantic doesn't hold for messages in 3b: with
   `Message.for_consolidator` constrained to `:session` scope per source
   plan §4a, one session produces exactly one message cluster covering
   all loaded messages, so deferring it defers everything and
   `contiguous_prefix/2` returns `{nil, nil}`. The valuable assertion
   here is the *constraint* — that `messages_processed_until_*` is
   `nil` after deferring the sole cluster, and that the run still
   succeeds (i.e. the messages stream doesn't break the publish path).
   Use `Message.import/1` (the action that accepts `:tenant_id,
   :sequence, :inserted_at`) for explicit-timestamp seeding;
   `Message.append/1`'s accept list omits those. Test comment should
   call out that the row-before-deferred-cluster semantic for messages
   needs the deferred 3c cross-session extension.

6. **`fake_proposals: []` → succeeded zero-count run** *(diverges from
   source plan)*
   The source plan at line 723 asserts `:failed` with
   `max_turns_reached` here, but that doesn't match the current
   `Runners.Fake` contract: `Fake.run_iteration/3` always calls
   `commit_proposals` after the proposal loop (`fake.ex:39-40`), and
   `:commit_proposals` in `run_server.ex:141` sends `:publish`
   unconditionally. So `fake_proposals: []` produces a `:succeeded`
   run with all zero counters, not `max_turns_reached`. The genuine
   max-turns scenario — harness exits without committing — can't be
   simulated with the current `Fake` runner; covering it requires
   either a `commit?: false` flag on `Runners.Fake` or a
   `Runners.NonCommittingFake` test stub. **This test asserts the
   actual current behaviour**: `{:ok, %ConsolidationRun{status:
   :succeeded, facts_added: 0, blocks_written: 0, links_added: 0,
   facts_invalidated: 0}}`. The deferred max-turns coverage is called
   out in "Out of scope" below so a future runner-stub PR can add it.

7. **Forge session cleanup — eventually clears `list_sessions/0`**
   After every successful run, `JidoClaw.Forge.Manager.list_sessions/0`
   should eventually drop the run's `forge_session_id`. **The check
   needs to be eventual**, not immediate: `commit_proposals` triggers
   `:publish` and `run_now/2` can return before the harness Task has
   finished unwinding through `maybe_stop_forge_session/1` at
   `run_server.ex:377-381`. Use a small in-test polling helper:

   ```elixir
   defp eventually(fun, timeout_ms \\ 1_000) do
     deadline = System.monotonic_time(:millisecond) + timeout_ms
     do_eventually(fun, deadline)
   end

   defp do_eventually(fun, deadline) do
     case fun.() do
       true -> :ok
       _ ->
         if System.monotonic_time(:millisecond) > deadline do
           ExUnit.Assertions.flunk("eventually condition not met within timeout")
         else
           Process.sleep(20)
           do_eventually(fun, deadline)
         end
     end
   end
   ```

   Then assert
   `eventually(fn -> run.forge_session_id not in Forge.Manager.list_sessions() end)`.
   Run the same eventual-check after case 6 (succeeded zero-count run) so
   the cleanup path is covered for both proposal-bearing and
   empty-proposal runs.

   The source plan asks for three additional cleanup-path tests
   (`await_ready` timeout, harness DOWN during bootstrap,
   `run_iteration` crash). All three require a test-only stub runner
   that hangs/crashes inside `init/2` or `run_iteration/3`.
   **Deferred** — see "Out of scope" below.

## File structure

```
test/jido_claw/memory/consolidator/run_server_test.exs
├── module + ExUnit.Case async: false
├── alias block: Consolidator, ConsolidationRun, Fact, Link, Block,
│                Resolver, Workspace, Session, Message, Scope, Clusterer
├── setup do  ─ shared sandbox owner + consolidator config override + on_exit cleanup
├── helper: workspace_scope/0     ─ {ws, scope}, consolidation_policy: :default
├── helper: session_scope/0       ─ {ws, session, scope} for :session-scoped tests
├── helper: seed_fact_simple!/2   ─ Fact.record with source: :model_remember (default)
├── helper: seed_fact_at!/3       ─ Fact.import_legacy with :inserted_at, :valid_at, unique :import_hash
├── helper: seed_message_at!/3    ─ Message.import with :tenant_id, :sequence, :inserted_at
├── helper: cluster_id_for_fact/1 ─ Clusterer.cluster([fact], 1) |> hd() |> Map.get(:id)
├── helper: eventually/1,2        ─ small polling helper for race-prone assertions
└── describe "end-to-end fake-harness run"
    ├── test "bootstrap regression — succeeded run + block + fact"
    ├── test "propose_link forwards relation, reason, confidence"
    ├── test "propose_update invalidates original + writes replacement + supersedes link"
    ├── test "defer_cluster (facts) — watermark stops at row before deferred cluster"
    ├── test "defer_cluster (messages) — single-cluster defer pins watermark to nil"
    ├── test "fake_proposals: [] → succeeded run with zero counters"
    └── test "Forge session is eventually stopped after every covered exit path"
```

## Test setup

**Sandbox**: `Sandbox.start_owner!(JidoClaw.Repo, shared: true)` plus
matching `on_exit(fn -> Sandbox.stop_owner(pid) end)` to release the
shared connection between tests. The RunServer, the LockOwner Task,
and the harness Task all run in separate PIDs and need to see seeded
rows. This is the same pattern as
`test/jido_claw/conversations/message_test.exs:7-11`. Plain `checkout`
(per `policy_resolver_test.exs:8-13`) won't work because the
LockOwner spawns a separate process that holds a pinned Repo connection;
`shared: true` is required for the cross-process visibility this test
needs.

**Config override**:

```elixir
prev = Application.get_env(:jido_claw, JidoClaw.Memory.Consolidator, [])

Application.put_env(:jido_claw, JidoClaw.Memory.Consolidator,
  enabled: true,
  min_input_count: 0,
  write_skip_rows: true,
  harness: :fake,
  harness_options: [sandbox_mode: :local, timeout_ms: 30_000, max_turns: 60]
)

on_exit(fn ->
  Application.put_env(:jido_claw, JidoClaw.Memory.Consolidator, prev)
end)
```

`harness: :fake` selects `Runners.Fake`. `min_input_count: 0` lets the
test seed exactly one fact and still pass the gate. `timeout_ms: 30_000`
keeps `bootstrap_timeout/1` (`min(timeout_ms, 60_000)`) snappy. The
`prev` snapshot + restore avoids leaking config to subsequent test
files (the keyword-list overwrite semantics of `put_env` make the
plain-`delete_env` form lossy if other config existed).

**Workspace + scope**: `Resolver.ensure_workspace("default",
"/tmp/run_server_test_<unique>")` then
`Workspace.set_consolidation_policy(ws, :default)` to clear the
`PolicyResolver.gate/1` skip. Scope record:

```elixir
%{
  tenant_id: "default",
  scope_kind: :workspace,
  user_id: nil,
  workspace_id: ws.id,
  project_id: nil,
  session_id: nil
}
```

Tests for the messages variant (`:session` scope) need a Session via
`Session.start(%{workspace_id: ws.id, tenant_id: "default", kind: :repl,
external_id: "sess-<unique>", started_at: DateTime.utc_now()})` and
swap in `scope_kind: :session, session_id: session.id`.

## Test-by-test detail

### Test 1 — bootstrap regression

```elixir
test "succeeded run writes a block + fact when proposals stage cleanly", %{scope: scope} do
  {:ok, run} =
    Consolidator.run_now(scope,
      fake_proposals: [
        {"propose_block_update",
          %{label: "core_facts", new_content: "shipping enabled"}},
        {"propose_add",
          %{content: "We ship to Canada", tags: ["geography"], label: "geo"}}
      ],
      override_min_input_count: true,
      await_ms: 30_000)

  assert run.status == :succeeded
  assert run.harness == :fake
  assert run.blocks_written >= 1
  assert run.facts_added >= 1

  blocks = Ash.read!(Block, domain: JidoClaw.Memory.Domain)
  assert Enum.any?(blocks, &(&1.label == "core_facts" and &1.value =~ "shipping"))

  facts = Ash.read!(Fact, domain: JidoClaw.Memory.Domain)
  assert Enum.any?(facts, &(&1.label == "geo" and &1.content =~ "Canada"))
end
```

Without the bootstrap-race fix this asserts on `run.status == :failed`
and `run.error` containing `:invalid_state`. We author it for the
fixed code path; the `git log -p` for the fix commit can be run in CI
to verify the test catches a revert.

### Test 2 — propose_link

Seed two facts via `seed_fact_simple!` with **distinct labels** (e.g.
`"link_source"` and `"link_target"`) — `Fact.record/1`'s
`InvalidatePriorActiveLabel` hook (`fact.ex:636-669`) invalidates any
existing active row at the same `(tenant, scope, label)`, so reusing
a label would make one of the two seeds historical and break the
link assertion. Capture their ids, run with a single proposal:

```elixir
fake_proposals: [
  {"propose_link",
    %{from_fact_id: fact_a.id, to_fact_id: fact_b.id,
      relation: "supports", reason: "consolidator_evidence",
      confidence: 0.85}}
]
```

Assert one `Link` row with:
- `relation == :supports` (atom — verifies `map_relation/1`'s string→atom
  conversion)
- `reason == "consolidator_evidence"`
- `confidence == 0.85`
- `from_fact_id == fact_a.id`, `to_fact_id == fact_b.id`
- `written_by == "consolidator"`

A single link proposal is enough — `Staging.total/1` (`staging.ex:75`)
counts every queue including `link_creates`, so a no-op
`propose_block_update` is unnecessary noise.

### Test 3 — propose_update

Seed one labeled fact `original` via `seed_fact_simple!` (label
`"vacation_plans"`). Run with one proposal:

```elixir
fake_proposals: [
  {"propose_update",
    %{fact_id: original.id, new_content: "updated content",
      tags: ["v2"]}}
]
```

Reload the original via `Ash.get!(Fact, original.id, domain: ...)` —
expect `invalid_at != nil`. The invalidation comes from
`Fact.record/1`'s `InvalidatePriorActiveLabel` change hook
(`fact.ex:636-669`) when the replacement row is written, not from
`maybe_invalidate_unlabeled/1` (which short-circuits for labeled
facts).

Read all facts, find the new active row at `label == "vacation_plans"`
where `id != original.id` — expect `content == "updated content"`,
`tags == ["v2"]`, `source == :consolidator_promoted`. Read all links —
expect a `:supersedes` row from `new.id → original.id` with
`written_by == "consolidator"`.

### Test 4 — defer_cluster (facts)

Seed three facts with controlled `inserted_at` via the import action
(the only path that accepts the timestamp as a writable attribute).
Truncate the base timestamp to microseconds first — the Ash
attributes are `:utc_datetime_usec`, and an unrounded
`DateTime.utc_now()` can produce equality surprises after round-trip
through Postgres:

```elixir
t0 = DateTime.utc_now() |> DateTime.truncate(:microsecond)
{:ok, a} = seed_fact_at!(scope, "label_a", t0)
{:ok, b} = seed_fact_at!(scope, "label_b", DateTime.add(t0, 1, :second))
{:ok, c} = seed_fact_at!(scope, "label_c", DateTime.add(t0, 2, :second))
```

`seed_fact_at!` is a private helper that calls `Fact.import_legacy/1`
with a unique `import_hash` (e.g. `"test-#{System.unique_integer([:positive])}"`),
the requested `inserted_at`, and `valid_at: inserted_at`. Per
`fact.ex`'s code-interface declaration, `import_legacy` accepts both
arguments while `record` does not.

Compute B's cluster id via the public clustering function:

```elixir
[%{id: b_cluster_id}] = Clusterer.cluster([b], 1)
```

Run with one proposal — `defer_cluster` alone satisfies
`Staging.total > 0`:

```elixir
fake_proposals: [
  {"defer_cluster", %{cluster_id: b_cluster_id, reason: "needs review"}}
]
```

Re-read the `ConsolidationRun` row. Sorted-by-`(inserted_at, id)` the
loaded inputs are `[a, b, c]`; `defer_cluster` flags `b`'s id as
deferred; `contiguous_prefix/2` walks `[a, b, c]`, `take_while not in
deferred`, returns `a`. Assert:

```elixir
assert run.facts_processed_until_at == a.inserted_at
assert run.facts_processed_until_id == a.id
```

### Test 5 — defer_cluster (messages)

`:session`-scoped run. Seed several messages on the session via
`seed_message_at!` (which calls `Message.import/1` with explicit
`tenant_id`, `sequence`, and `inserted_at` — `Message.append/1`'s
accept list omits these so `import/1` is the only way to write
messages with controlled timestamps). Use the same
`DateTime.truncate(:microsecond)` discipline as test 4 for the base
timestamp. Compute the cluster id — deterministic and public:

```elixir
message_cluster_id = "messages:#{session.id}"
```

Run with one proposal:

```elixir
fake_proposals: [
  {"defer_cluster",
    %{cluster_id: message_cluster_id, reason: "needs review"}}
]
```

A single session under `:session` scope produces exactly one message
cluster covering all loaded messages, so deferring it defers everything
and `contiguous_prefix/2` returns `{nil, nil}`. Assert:

```elixir
assert run.status == :succeeded
assert run.messages_processed_until_at == nil
assert run.messages_processed_until_id == nil
```

Add a `# CONSTRAINT:` comment in the test explaining that this is the
3b shape — `Message.for_consolidator` is constrained to `:session`
scope per source plan §4a, so a single session's only cluster covers
all messages by definition. The "watermark stops at row before
deferred cluster's first member" semantic for messages requires
cross-session input loading (deferred 3c work). When that lands, this
test's assertion shape will need to widen — the constraint comment
makes the dependency obvious.

### Test 6 — `fake_proposals: []` → succeeded zero-count run

```elixir
{:ok, run} =
  Consolidator.run_now(scope,
    fake_proposals: [],
    override_min_input_count: true,
    await_ms: 30_000)

assert run.status == :succeeded
assert run.harness == :fake
assert run.facts_added == 0
assert run.facts_invalidated == 0
assert run.blocks_written == 0
assert run.links_added == 0
```

Why `:succeeded` and not `:failed`: `Runners.Fake.run_iteration/3`
unconditionally calls `commit_proposals` after the proposal loop
(`fake.ex:39-40`), and the `:commit_proposals` handler in
`run_server.ex:141` sends `:publish` regardless of `Staging.total`.
So the publish path runs with all-zero counters and the run lands
`:succeeded`. The `max_turns_reached` branch (`run_server.ex:220-221`)
fires only when the harness returns *without* having committed —
which the current `Fake` runner can't simulate.

### Test 7 — Forge session cleanup (eventual assertion)

Run case 1 (succeeded with proposals) and case 6 (succeeded with no
proposals) inside this test, capture each run's `forge_session_id`
from the audit row, and assert the eventual property:

> **Implementation note:** Test 7 deliberately re-runs cases 1 and 6
> for clarity — the cleanup assertion is the test's whole point and
> belongs in its own `test` block. The trade-off is two extra
> fake-harness runs per file. If runtime becomes annoying, fold the
> `eventually(fn -> run.forge_session_id not in
> Forge.Manager.list_sessions() end)` assertion into tests 1 and 6
> directly and delete this test. Keep the separate test as the
> default — the documentation value of an explicit cleanup test
> outweighs ~1s of additional runtime.

```elixir
:ok = eventually(fn ->
  run.forge_session_id not in Forge.Manager.list_sessions()
end)
```

The check needs to be eventual, not immediate: the
`:commit_proposals` → `:publish` pipeline can finalise the
`RunServer` and return from `run_now/2` while the harness Task is
still unwinding through `maybe_stop_forge_session/1` at
`run_server.ex:381`. A 1-second polling deadline (with 20ms sleeps)
is generous enough that flakes won't show up in CI but tight enough
that a real cleanup-path bug fails fast.

Add a `# DEFERRED:` comment in this test pointing to the "Out of
scope" section: the source plan asked for `await_ready` timeout,
harness DOWN during bootstrap, and `run_iteration` crash coverage.
All three need a test-only stub runner (e.g.
`JidoClaw.Forge.Runners.HangingFake` and `…RaisingFake`) and aren't
authorable against the current `Runners.Fake` API.

## Critical files to read or call

- `lib/jido_claw/memory/consolidator.ex:54` — `run_now/2` entry point
  and option semantics.
- `lib/jido_claw/memory/consolidator/run_server.ex:200-234,358-414` —
  finalise paths, drive_harness shape, await_ready, maybe_stop_forge_session.
- `lib/jido_claw/forge/runners/fake.ex:36-46,98-105` — fake runner's
  proposal-forwarding shape and error semantics.
- `lib/jido_claw/memory/consolidator/clusterer.ex:34` — public
  `Clusterer.cluster/2`. Use it to derive a fact's cluster id (call
  with a 1-element list) instead of mirroring the private hash
  formula in the test.
- `lib/jido_claw/memory/resources/{fact,link,block,consolidation_run}.ex` —
  Ash code-interface entries used by the test (`Fact.record`,
  `Link.create_link`, `Block.write`, `ConsolidationRun.record_run`,
  `latest_for_scope`).
- `lib/jido_claw/conversations/resources/message.ex:91-104` —
  `Message.append/1`, `Message.for_consolidator/1`.
- `lib/jido_claw/workspaces/resolver.ex:17` —
  `Resolver.ensure_workspace/3`.
- `test/jido_claw/conversations/message_test.exs:7-11` — `shared: true`
  sandbox pattern (the right one for cross-process visibility).
- `test/jido_claw/memory/consolidator/policy_resolver_test.exs:18-26` —
  workspace + policy seed pattern.
- `test/jido_claw/memory/retrieval_test.exs:30-46` — Session creation
  pattern.

## Reused, do not duplicate

- `JidoClaw.Workspaces.Resolver.ensure_workspace/3` — workspace seeding.
- `JidoClaw.Workspaces.Workspace.set_consolidation_policy/1` — policy
  flip after creation.
- `JidoClaw.Memory.Fact.record/1` — fact seed for tests where
  timestamps don't matter (cases 1, 2, 3). The helper should default
  to `source: :model_remember` (or `:user_save`) so seeded facts are
  eligible for `Fact.for_consolidator/1`'s default
  `sources: [:model_remember, :user_save, :imported_legacy]` filter
  (`fact.ex` action declaration). `:consolidator_promoted` rows are
  excluded by default and would silently fail to load even when
  tests don't think they care — keeping the seed eligible avoids
  confusing future test additions.
- `JidoClaw.Memory.Fact.import_legacy/1` — fact seed *with*
  `:inserted_at` and `:valid_at` arguments and a unique `:import_hash`
  (case 4 watermark math). The `record` action's accept list does not
  include `:inserted_at`, so import is the only available path.
- `JidoClaw.Conversations.Message.append/1` — message seed for tests
  where `sequence` and timestamps don't matter.
- `JidoClaw.Conversations.Message.import/1` — message seed *with*
  `:tenant_id`, `:sequence`, and `:inserted_at` (case 5 controlled
  timestamps). Like Fact, `append` does not accept these.
- `JidoClaw.Conversations.Session.start/1` — session creation.
- `JidoClaw.Memory.Consolidator.Clusterer.cluster/2` — public function
  for resolving a fact's cluster id without duplicating the private
  hash formula (case 4).
- `Ash.read!/2` and `Ash.get!/3` against `JidoClaw.Memory.Domain` for
  assertions — no new query helpers required.

## Out of scope (deferred, intentional)

- **`max_turns_reached` failure path.** Source plan line 723 expects
  `fake_proposals: []` to land `:failed` with `max_turns_reached`,
  but the current `Runners.Fake` always commits, so empty proposals
  produce a `:succeeded` zero-count run instead. Covering the genuine
  max-turns scenario needs either a `commit?: false` flag on
  `Runners.Fake` or a `Runners.NonCommittingFake` test stub. Test 6
  asserts current behaviour; the max-turns case follows in a separate
  PR alongside that runner-stub change.
- **Bootstrap timeout, harness-DOWN-during-bootstrap, and
  run_iteration crash exit paths.** The current `:fake` runner can't
  be configured to hang in `init/2` or crash mid-iteration; covering
  these requires test-only stub runners (e.g.
  `JidoClaw.Forge.Runners.HangingFake` and `…RaisingFake` in
  `test/support/`). Out of scope for this PR — Test 7's eventual
  `list_sessions/0` check covers the two cleanup paths reachable via
  `Runners.Fake` (succeeded with and without proposals).
- **Apply-step partial-publish coverage.** The source plan keeps the
  count-and-skip pattern; testing it specifically requires a
  concurrent invalidation race or a malformed proposal that survives
  staging but fails at apply-time. Out of scope for the regression
  test file.
- **Multi-scope candidate enumeration** is covered by the separate
  `consolidator_test.exs` the source plan calls out at lines 735–740.
  This file stays focused on the run-server happy + key failure paths.

## Verification

```sh
mix format
mix compile --warnings-as-errors
mix test test/jido_claw/memory/consolidator/run_server_test.exs
mix test test/jido_claw/memory/consolidator/
mix test  # full suite, expect 1296+ tests at 0 failures
```

Per-test sanity:
- Test 1 alone reproduces the source-plan headline regression. Reverting
  `drive_harness/4`'s `await_ready` change in a scratch branch should
  cause this test to fail with an `:invalid_state` error string and the
  fix should make it pass.
- Test 7's assertions about `Forge.Manager.list_sessions/0` should hold
  consistently across the suite — re-running this file 10× via
  `for _ <- 1..10; do mix test test/jido_claw/memory/consolidator/run_server_test.exs; done`
  exercises the cleanup path under repeated load.
