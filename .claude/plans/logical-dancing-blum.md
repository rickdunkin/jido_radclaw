# v0.6 Phase 2 — Code Review Fix-Up

## Context

A code review of v0.6 Phase 2 (Conversations: messages + tool/result/reasoning persistence + RequestCorrelation) surfaced 3 verified issues. All three are accurate — confirmed against `lib/jido_claw/conversations/`, `lib/jido_claw/platform/session/`, and the test files.

The reviewer ran the focused regression suite and got `1 failure` in `history_test.exs` reporting `Session worker still registered after stop`. (My local re-run with two different seeds happened to pass — the bug is racy by construction; see P1 below for why the reviewer's analysis is correct regardless.)

The user also asks whether anything pgvector-related was deferred from Phase 2 and is now addressable. **Answer: no.** The Phase 2 plan (`docs/plans/v0.6/phase-2-conversations.md`) calls out exactly one deferral — "Optional FTS: `search_vector` GIN on `content` for `conversation_search` in Phase 3 / Phase 4" — and that's a `tsvector` FTS column, not pgvector. The pgvector extension is wired (`lib/jido_claw/repo.ex:7` lists `"vector"` in `installed_extensions`) and consumed by Solutions (commit `2b53296`); none of Phase 2's resources have an embedding column on the roadmap.

---

## Verification of Findings

### P1 — `history_test.exs:55` cold-path test stops a `:permanent` worker (verified)

`JidoClaw.Session.Worker` (`lib/jido_claw/platform/session/worker.ex:1`) uses `use GenServer` with no override of `child_spec/1`. The default child spec from `use GenServer` is `restart: :permanent`. `JidoClaw.Session.Supervisor.start_session/2` (`lib/jido_claw/platform/session/supervisor.ex:8`) hands a tuple form `{JidoClaw.Session.Worker, opts}` to `DynamicSupervisor.start_child/2`, so `:permanent` is honored — `GenServer.stop(pid)` (which exits with `:normal`) **does** trigger a supervisor restart. The race between (a) the registry briefly clearing as the worker dies and (b) the supervisor re-registering the new worker is genuinely flaky.

**Crucially**, the test setup is overcomplicated for what it claims to verify. `JidoClaw.history/3` (`lib/jido_claw.ex:293-313`) reads Postgres directly via `Conversations.Message.for_session/1` and never consults `Session.Worker`. The cold-path test's `ensure_session` + `set_session_uuid` + `GenServer.stop` + `wait_until_unregistered` dance is therefore unnecessary scaffolding. Removing it eliminates the race entirely and makes the test honest about what it's testing.

### P2 — `recorder_test.exs:184` `register/3` helper bypasses the Postgres path (verified)

The helper at `recorder_test.exs:184-196` only calls `Cache.put/2` (the ETS mirror). The recorder's scope resolution (`lib/jido_claw/conversations/recorder.ex:390-411`) tries the cache first and falls back to `RequestCorrelation.lookup/1`. The four existing tests cover the cache hit but never the durable-row fallback. The reviewer is right that this is the same masking pattern that hid the missing `expires_at` default — none of these tests would catch a regression where the durable write fails or the lookup misses.

### P3 — `request_correlation.ex:138-143` `expires_at` default ignores supplied `inserted_at` (verified)

The attribute default is `fn -> DateTime.add(DateTime.utc_now(), 600, :second) end`. The `:register` action accepts `:inserted_at` (line 75), so a caller backdating it sees `expires_at = now() + 600s`, **not** `inserted_at + 600s` as the comment claims (lines 132-137).

In production this is currently latent — the only caller (`lib/jido_claw.ex:190-196`) doesn't pass `inserted_at`. But the comment promises a contract the code doesn't honor, and the accept-list mismatch is unintended: the Phase 2 plan §2.3 spec'd `:register` accepts `request_id, session_id, tenant_id, workspace_id, user_id, expires_at` — `inserted_at` was never part of the design.

---

## Decisions

### D1 — P1 fix: drop the worker setup from the cold-path test, don't change the supervisor

The reviewer offered three options:
1. Make `Session.Worker` `restart: :transient`/`:temporary`
2. Terminate via `DynamicSupervisor.terminate_child/2` instead of `GenServer.stop`
3. Skip stopping; `history/3` reads Postgres directly

**Decision: option 3.** The simplest, most honest fix.

Rejecting (1): changing the worker's restart strategy is a semantic change that affects production lifecycle for every consumer, just to make a test pass. Sessions are long-lived and should be `:permanent`; flipping to `:transient` means a normal-exit code path stops re-registering the worker, which the rest of the codebase doesn't expect.

Rejecting (2): adds plumbing to look up the `DynamicSupervisor` (global vs per-tenant — see `supervisor.ex:5-21`) just to terminate a worker the test doesn't actually need. Still racy in spirit — the test would pass for the wrong reason.

Option (3) leaves production alone, removes the race, and removes scaffolding that misrepresents what the test verifies. The seed function (`seed_session_with_history/0`) already writes rows directly via `Message.append!/1`, so Postgres has the rows the test needs. `history/3` reads Postgres. Done.

### D2 — P2 fix: add one durable-path test, leave the existing four alone

Add a single new test in the `"tool_result parent resolution"` describe block (or a new describe block, "scope resolution via Postgres fallback") that:

1. Seeds a session via the existing `seed_session/1` helper.
2. Calls `JidoClaw.register_correlation/5` (the dispatcher entry point — `lib/jido_claw.ex:182-208`) so both the ETS Cache and the durable `RequestCorrelation` row get written.
3. Deletes the ETS entry via `Cache.delete/1` to force the recorder onto the Postgres fallback.
4. Appends a `:tool_call` parent row, emits an `ai.tool.result` signal, finalizes via `ai.request.completed`.
5. Asserts the resulting `:tool_result` row lives under the right session.

The four existing tests stay as-is. They legitimately use `Cache.put` to keep their focus tight on parent-resolution behavior; adding one durable-path test closes the coverage gap without rewriting the others. This matches the spec for the §2.7 "Recorder correlation survives a process restart" acceptance gate, scaled to a unit test.

### D3 — P3 fix: remove `:inserted_at` from the `:register` accept list

Two options the reviewer offered:
- (A) Build-time change that derives `expires_at` from supplied `inserted_at`
- (B) Stop accepting `inserted_at` unless `expires_at` is supplied

**Decision: B, simplified — drop `:inserted_at` from the accept list entirely.**

Rejecting (A): Ash attribute defaults run at changeset-build time (before `allow_nil?` validation), but they're 0-arity and can't read other attributes off the changeset. A `change` callback runs in the action pipeline, but by then `allow_nil?: false` on `expires_at` has already failed if the attribute default didn't fire. The existing comment in the code (`request_correlation.ex:132-137`) documents exactly this pitfall — the previous author tried `before_action` for the same reason and it didn't work. Recreating that fragile machinery to support a code path no caller exercises is wrong.

(B) is correct and matches the Phase 2 plan §2.3 spec, which lists the `:register` accept list as `request_id, session_id, tenant_id, workspace_id, user_id, expires_at` — no `inserted_at`. The current code accepts it as an unintended artifact. Removing it:

- Aligns the implementation with the spec
- Restores honest TTL semantics: `inserted_at` defaults to `DateTime.utc_now()`, `expires_at` defaults to `DateTime.utc_now() + 600s`, both fire at build time microseconds apart, so `expires_at ≈ inserted_at + 600s` holds within a few μs — well within the 60s sweeper tick granularity
- The only caller (`lib/jido_claw.ex:190-196`) is unaffected because it doesn't pass `:inserted_at`

Update the now-misleading comment on `expires_at` to reflect the new reality.

---

## Implementation

### Files modified

| File | Change |
|---|---|
| `test/jido_claw/conversations/history_test.exs` | Strip worker setup from `history/3` cold-path test; remove `wait_until_unregistered/3` helper if it's no longer used |
| `test/jido_claw/conversations/recorder_test.exs` | Add one new test exercising `RequestCorrelation` durable-row fallback |
| `test/jido_claw/conversations/request_correlation_test.exs` | New file — pins the `:register` accept-list contract |
| `lib/jido_claw/conversations/resources/request_correlation.ex` | Remove `:inserted_at` from `:register` accept list; update both the inline `expires_at` comment AND the module-level `## TTL semantics` docstring |

### Step 1 — P1 fix in `history_test.exs`

In `describe "history/3 (cold path — Postgres only)"`, replace the test body. The test currently:

```elixir
{:ok, _pid} = JidoClaw.Session.Supervisor.ensure_session(tenant, external_id)
:ok = JidoClaw.Session.Worker.set_session_uuid(tenant, external_id, session.id)

[{worker_pid, _}] =
  Registry.lookup(JidoClaw.SessionRegistry, {tenant, external_id})

:ok = GenServer.stop(worker_pid)

# Wait briefly for the registry to clean up.
_ = wait_until_unregistered(tenant, external_id)

# `:workspace_id` here is the project directory, not a UUID —
# history/3 passes it through Workspaces.Resolver.ensure_workspace/3.
msgs =
  JidoClaw.history(tenant, external_id, kind: :api, workspace_id: project_dir)
```

Becomes:

```elixir
# `history/3` reads Postgres directly via Conversations.Message.for_session/1
# and never touches Session.Worker (verified at lib/jido_claw.ex:293-313),
# so we don't need to bring up — let alone tear down — the worker. The
# rows seeded by seed_session_with_history/0 are all this test needs.
msgs =
  JidoClaw.history(tenant, external_id, kind: :api, workspace_id: project_dir)
```

Then remove `wait_until_unregistered/3` (lines 141-153) since it has no remaining caller. Also remove the unused `:session` field handling — actually, `seed_session_with_history/0` returns a map containing `:session`, but the cold-path test no longer uses it. Verify the destructure still uses what's needed: `tenant_id`, `external_id`, `project_dir`. The `session: session` field can stay in the returned map (the hot-path test uses it, line 23) but the cold-path test's destructure can drop it.

Existing imports (`alias JidoClaw.Conversations.{Message, Session}`) stay — `Session` is still used by `seed_session_with_history/0`.

### Step 2 — P2 fix in `recorder_test.exs`

Add a new `describe` block (or a new test in the existing one) below the four existing parent-resolution tests:

```elixir
describe "scope resolution via Postgres fallback" do
  test "Recorder rehydrates scope from RequestCorrelation when ETS cache misses" do
    %{tenant_id: tenant, session: session} = seed_session("durable")

    request_id = "req-durable-#{System.unique_integer([:positive])}"

    # Go through the public dispatcher API — writes both the ETS Cache
    # and the durable RequestCorrelation row.
    :ok = JidoClaw.register_correlation(request_id, session.id, tenant, nil, nil)

    # Force the cache miss so the Recorder hits the Postgres fallback path.
    Cache.delete(request_id)

    tool_call_id = "call-durable-#{System.unique_integer([:positive])}"

    {:ok, parent} =
      Message.append(%{
        session_id: session.id,
        request_id: request_id,
        role: :tool_call,
        content: "tool()",
        tool_call_id: tool_call_id
      })

    emit_tool_result(request_id, tool_call_id, "tool", {:ok, "ok"})
    finalize_and_flush(request_id)

    [tr] = tool_results_for(session.id)

    assert tr.parent_message_id == parent.id,
           "expected the :tool_result to link to the durable-path parent (#{parent.id}), got #{inspect(tr.parent_message_id)}"
  end
end
```

The proof that the Postgres fallback worked is that we deleted the ETS entry before emitting the tool result and the row still landed under the right session — the recorder had to have hit `RequestCorrelation.lookup/1`. We do **not** assert the cache was rehydrated post-flush, because `Recorder.finalize_request/2` (`recorder.ex:337-355`) deletes both the ETS entry and the durable row when it processes the terminal `ai.request.completed`, so by the time the test runs assertions, both are gone.

`Message` is already aliased (line 4); `Cache` is already aliased (line 5). `JidoClaw.register_correlation/5` is reachable as a fully-qualified call without an alias. Reuses `seed_session/1`, `emit_tool_result/4`, `finalize_and_flush/1`, `tool_results_for/1`.

### Step 3 — P3 fix in `request_correlation.ex`

In the `:register` create action (lines 66-80), drop `:inserted_at` from the accept list:

```elixir
create :register do
  primary?(true)

  accept([
    :request_id,
    :session_id,
    :tenant_id,
    :workspace_id,
    :user_id,
    :expires_at
  ])

  change({__MODULE__.Changes.ValidateCrossTenantFk, []})
end
```

Update the comment block at lines 132-137 above the `expires_at` attribute. Replace it with something honest about the actual semantics:

```elixir
# `expires_at` and `inserted_at` both default to `DateTime.utc_now()`-based
# values that fire at changeset-build time (before `allow_nil?: false`
# validation), so the gap between them is microseconds in practice.
# `:inserted_at` is intentionally NOT in the `:register` accept list —
# allowing callers to backdate `inserted_at` without coupling it to
# `expires_at` would break the documented `inserted_at + ~600s` TTL.
attribute :expires_at, :utc_datetime_usec do
  allow_nil?(false)
  public?(true)
  writable?(true)
  default(fn -> DateTime.add(DateTime.utc_now(), 600, :second) end)
end
```

Also update the `## TTL semantics` block in the `@moduledoc` (lines 22-26). The current text claims `expires_at` defaults to `inserted_at + 600s`, which was never quite true and is now even less so since `:inserted_at` is no longer accepted on `:register`. Replace with:

```
## TTL semantics

`expires_at` defaults to `DateTime.utc_now() + 600s` when the
dispatcher doesn't supply a value. Both `inserted_at` and `expires_at`
have build-time attribute defaults that fire microseconds apart, so
in practice `expires_at ≈ inserted_at + 600s`. The `:register`
action does **not** accept `:inserted_at` — allowing callers to
backdate it without coupling it to `expires_at` would silently
violate the documented TTL. The `Sweeper` worker calls
`sweep_expired/0` on a 60s tick; rows with `expires_at < now()` are
bulk-destroyed in batches of 1_000.
```

`inserted_at` (lines 125-130) keeps `writable?(true)` because non-`:register` write paths might still want it; only its presence in the `:register` accept list is the bug.

### Step 4 — Add explicit P3 regression test

The accept-list change is a contract-level decision and shouldn't ride only on indirect coverage. Add a regression test in a new file `test/jido_claw/conversations/request_correlation_test.exs` (or in an existing test for the resource if one exists — quick scan of the test tree at exploration time showed none, so a new file is most likely). Two tests:

```elixir
defmodule JidoClaw.Conversations.RequestCorrelationTest do
  use ExUnit.Case, async: false

  alias JidoClaw.Conversations.{RequestCorrelation, Session}
  alias JidoClaw.Workspaces.Workspace

  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(JidoClaw.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end

  describe ":register accept list" do
    test "supplying :inserted_at is rejected (not in accept list)" do
      %{tenant_id: tenant, session: session} = seed()

      result =
        RequestCorrelation.register(%{
          request_id: "req-#{System.unique_integer([:positive])}",
          session_id: session.id,
          tenant_id: tenant,
          inserted_at: DateTime.add(DateTime.utc_now(), -3600, :second)
        })

      # Ash returns an Ash.Error.Invalid wrapping an
      # Ash.Error.Invalid.NoSuchInput (or similar) when an unaccepted
      # attribute is supplied. Match loosely on the shape — the
      # important contract is that the call fails, not the exact error
      # struct, which can vary across Ash versions.
      assert {:error, %Ash.Error.Invalid{}} = result
    end

    test "registering without :inserted_at and :expires_at uses build-time defaults" do
      %{tenant_id: tenant, session: session} = seed()

      request_id = "req-#{System.unique_integer([:positive])}"

      assert {:ok, row} =
               RequestCorrelation.register(%{
                 request_id: request_id,
                 session_id: session.id,
                 tenant_id: tenant
               })

      now = DateTime.utc_now()
      delta_seconds = DateTime.diff(row.expires_at, now, :second)

      # The default should land within a small window of `now + 600`.
      assert delta_seconds in 595..600,
             "expected expires_at ~600s ahead of now, got delta=#{delta_seconds}s"
    end
  end

  defp seed do
    tenant = "tenant-rc-#{System.unique_integer([:positive])}"

    {:ok, ws} =
      Workspace.register(%{
        tenant_id: tenant,
        path: "/tmp/rc-#{System.unique_integer([:positive])}",
        name: "rc"
      })

    {:ok, session} =
      Session.start(%{
        workspace_id: ws.id,
        tenant_id: tenant,
        kind: :api,
        external_id: "ext-rc-#{System.unique_integer([:positive])}",
        started_at: DateTime.utc_now()
      })

    %{tenant_id: tenant, workspace: ws, session: session}
  end
end
```

The first test pins the accept-list decision: a future maintainer who restores `:inserted_at` to the accept list breaks this test immediately. The second test verifies the happy path still works after the change — without it, an accidentally-too-aggressive removal (e.g., dropping the attribute default) would slip through.

### Step 5 — Verify

```bash
# P1 regression: the previously-flaky test should now be deterministic
mix test test/jido_claw/conversations/history_test.exs

# P2 regression: new durable-path test runs alongside existing four
mix test test/jido_claw/conversations/recorder_test.exs

# P3 regression: explicit accept-list contract test
mix test test/jido_claw/conversations/request_correlation_test.exs

# Whole conversations subtree — catches any indirect breakage
mix test test/jido_claw/conversations/

# Full suite — make sure nothing else regressed
mix test

# Strict compile gate
MIX_ENV=test mix compile --warnings-as-errors --force

# Format gate (CI shape)
mix format --check-formatted
```

Expected:
- `history_test.exs` → `2 tests, 0 failures`, deterministic across seeds (the racy supervisor restart no longer factors in).
- `recorder_test.exs` → `5 tests, 0 failures` (4 existing + 1 new).
- `request_correlation_test.exs` → `2 tests, 0 failures` (new file).
- Full suite stays green.

---

## Notes on pgvector

Reviewed Phase 2 plan and current resources for pgvector deferrals:

- `docs/plans/v0.6/phase-2-conversations.md` mentions `search_vector` once (FTS, deferred to Phase 3/4) — that's `tsvector` FTS, not pgvector
- `lib/jido_claw/conversations/resources/message.ex` and `request_correlation.ex` have no embedding columns and the plan doesn't add any
- Phase 1 (Solutions) and Phase 3 (Memory) are where pgvector lands — both are out of scope for this fix-up

No pgvector-related work is unlocked by the recent extension addition for Phase 2. If the user wants the optional `search_vector` FTS column added now (ahead of Phase 3/4), that's a separate plan.
