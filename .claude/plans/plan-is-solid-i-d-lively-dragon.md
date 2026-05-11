# v0.6 Audit/Tracer Code-Review Fixes

## Context

Code review of the just-landed v0.6 audit work surfaced four defects in
`JidoClaw.Audit.AshTracer`, `JidoClaw.Memory.Block.revise/3`, and the
test sandbox plumbing. Three are correctness bugs in security audit
rows (silent drops, wrong `actor_kind`, wrong `actor_id`); the fourth
is suite noise from `Postgrex.Protocol ... owner exited` errors that
the new global tracer aggravates. All four findings were verified
against the current code. This plan resolves them in one pass and
backs each fix with a regression test.

## Approach

### Fix 1 — Restrict tracer to `:action` spans [P1]

**File:** `lib/jido_claw/audit/ash_tracer.ex:65-66`

Replace the catch-all `trace_type?(_type), do: true` with:

```elixir
def trace_type?(:action), do: true
def trace_type?(_), do: false
```

Ash's `span/4` macro filters tracers via `trace_type?` **before**
dispatching `start_span` / `stop_span` (`deps/ash/lib/ash/tracer/tracer.ex:66,72,81`),
so nested `:changeset` / `:query` / `:validation` spans will no longer
trigger our `stop_span/0` and clear the action metadata. `set_handled_error`
is **not** gated by `trace_type?` — it's dispatched directly from the
action modules (`deps/ash/lib/ash/actions/{action,create,update,destroy}.ex`),
so policy denials still emit.

The moduledoc already states this intent ("Only `:action` span metadata
is captured — sub-spans … are ignored"); the fix brings the code in
line with the doc.

### Fix 2 — Correct actor classification [P1]

Extract a shared classifier so the tracer and `Block.revise` cannot
drift. The user-supplied refinement requires honoring both atom and
string `kind` values and requiring a **non-nil** id before classifying.

**New file:** `lib/jido_claw/audit/actor_classifier.ex`

```elixir
defmodule JidoClaw.Audit.ActorClassifier do
  @moduledoc """
  Maps an Ash actor (canonical map from `JidoClaw.Authorization.Actor`,
  a `%JidoClaw.Accounts.User{}`, or `nil`) to the `actor_kind` /
  `actor_id` pair stored on `JidoClaw.Audit.Event`.

  Rules, in priority order:
    1. `kind: :system` (or `"system"`) → `{:system, nil}`
    2. non-nil `agent_id` → `{:agent, agent_id}`
    3. non-nil `user_id`  → `{:user,  user_id}`
    4. `kind: :user`  (or `"user"`)  + non-nil `id` → `{:user,  id}`
       `kind: :agent` (or `"agent"`) + non-nil `id` → `{:agent, id}`
    5. otherwise → `{:system, nil}` (unidentifiable actor, e.g. nil
       or a bare `%{id: …}` map with no `kind`/`*_id` field)

  Rule 4 is **deliberately narrow**: it requires an explicit `kind`
  alongside the `id` field. A bare `%{id: "abc"}` falls through to
  rule 5 — we do not infer `:user` from `:id` alone, because some
  boundaries pass `%Some.Other.Struct{}` shapes where `id` is not a
  user/agent identifier.

  The "non-nil id required" rule prevents canonical system actors —
  `%{kind: :system, user_id: nil, tenant_id: …}` — from being
  misclassified as `:user` purely because the key is present.
  """

  @spec classify(map() | struct() | nil) :: {:user | :agent | :system, String.t() | nil}
  # … pattern-match clauses implementing rules 1-5, with atom + string keys
end
```

**File:** `lib/jido_claw/audit/ash_tracer.ex:156-179`

Replace `actor_kind/1` + `actor_id/1` with a single
`ActorClassifier.classify(metadata[:actor])`, then split into
`actor_kind` / `actor_id` at the call site. Remove the dead helpers.

**File:** `lib/jido_claw/memory/resources/block.ex:716-744`

`emit_revise_audit/4` currently derives `actor_kind` from
`prior.source` (so a `Actor.system/1` revise of a `:user`-sourced
block is logged as `actor_kind: :user`) and looks for `actor[:id]`
(canonical actors carry `:user_id`, so user revises log
`actor_id: nil`). Replace both with `ActorClassifier.classify(actor)`.
Delete the now-orphaned `actor_kind_for/1` helper at L743-744.

The three other in-`lib` audit producers (`producers.ex`,
`signal_listener.ex`, `web/plugs/api_key_auth.ex`,
`web/controllers/auth_controller.ex`) classify off different inputs
(resource `:source` field, hardcoded `:agent`, presence of an opaque
`actor_id` string) and don't need the classifier. Out of scope.

### Fix 3 — (Merged into Fix 2)

Covered by replacing `Block.revise`'s ad-hoc logic with
`ActorClassifier.classify/1`.

### Fix 4 — Drain async audit writes at sandbox teardown [P2]

**File:** `lib/jido_claw/audit/async_writer.ex`

Add a bounded drain helper that loops until the supervisor reports
no live children or the deadline expires. The loop (rather than a
single snapshot) matches the intent: a task scheduled by a
straggler `cast/1` during the drain window is also waited on. The
helper is guarded so it stays harmless if the supervisor isn't
running (partial app shutdown, isolated unit tests):

```elixir
@spec flush(non_neg_integer()) :: :ok
def flush(timeout_ms \\ 5_000) do
  deadline = System.monotonic_time(:millisecond) + timeout_ms
  drain_loop(deadline)
rescue
  ArgumentError -> :ok
catch
  :exit, _ -> :ok
end

defp drain_loop(deadline) do
  case Task.Supervisor.children(@sup) do
    [] ->
      :ok

    pids ->
      Enum.each(pids, fn pid ->
        if Process.alive?(pid) do
          ref = Process.monitor(pid)
          remaining = max(deadline - System.monotonic_time(:millisecond), 0)

          receive do
            {:DOWN, ^ref, :process, ^pid, _} -> :ok
          after
            remaining -> Process.demonitor(ref, [:flush]); :ok
          end
        end
      end)

      if System.monotonic_time(:millisecond) < deadline do
        drain_loop(deadline)
      else
        :ok
      end
  end
end
```

Bounded timeout (default 5s) so a stuck audit task can't hang the
suite — if anything is still running at the deadline, we exit the
loop and let the existing `safe_record/2` rescue/catch handle
whatever Postgrex throws. `ArgumentError` (supervisor not
registered) and any `:exit` are swallowed so calling `flush/1` on
a dead/partially-started app stays a no-op.

Also broaden `sandbox_shutdown?/1` (`async_writer.ex:64-67`) so
stragglers from other shapes stay quiet:

```elixir
defp sandbox_shutdown?({:shutdown, reason}) when is_binary(reason),
  do: sandbox_text?(reason)
defp sandbox_shutdown?({{:shutdown, reason}, _}) when is_binary(reason),
  do: sandbox_text?(reason)
defp sandbox_shutdown?(%DBConnection.ConnectionError{message: msg})
  when is_binary(msg),
  do: sandbox_text?(msg)
defp sandbox_shutdown?(_), do: false

defp sandbox_text?(text),
  do: String.contains?(text, "owner") and String.contains?(text, "exited")
```

**Files:** `test/support/jido_claw/tenant_case.ex:39-43` and
`test/support/jido_claw/solutions_case.ex:41-45`

Wire the drain into both case templates' `on_exit` **before**
`Sandbox.stop_owner/1`:

```elixir
setup tags do
  pid = Ecto.Adapters.SQL.Sandbox.start_owner!(JidoClaw.Repo, shared: not tags[:async])
  on_exit(fn ->
    JidoClaw.Audit.AsyncWriter.flush()
    Ecto.Adapters.SQL.Sandbox.stop_owner(pid)
  end)
  :ok
end
```

Confirmed scope: only `TenantCase` and `SolutionsCase` start sandbox
owners in this repo (no `DataCase` / `ConnCase`); the two setup
blocks are byte-identical today. Production `cast/1` call sites
(`ash_tracer.ex:117`, `signal_listener.ex:107`,
`api_key_auth.ex:59`, `auth_controller.ex:43`) are unaffected — the
drain is test-only.

## Critical files

Modified:
- `lib/jido_claw/audit/ash_tracer.ex` (Fix 1 + Fix 2)
- `lib/jido_claw/memory/resources/block.ex` (Fix 2)
- `lib/jido_claw/audit/async_writer.ex` (Fix 4)
- `test/support/jido_claw/tenant_case.ex` (Fix 4)
- `test/support/jido_claw/solutions_case.ex` (Fix 4)

Added:
- `lib/jido_claw/audit/actor_classifier.ex` (Fix 2)
- `test/jido_claw/audit/actor_classifier_test.exs` (Fix 2 unit coverage)

## Tests to add

**`test/jido_claw/audit/ash_tracer_test.exs`** — extend the existing file:

1. **Direct `trace_type?/1` assertions** — locks in Fix 1 cheaply:
   ```elixir
   assert AshTracer.trace_type?(:action)
   refute AshTracer.trace_type?(:changeset)
   refute AshTracer.trace_type?(:query)
   refute AshTracer.trace_type?(:validation)
   refute AshTracer.trace_type?(:change)
   ```

2. **Integration via `Ash.Tracer.span/4`** — proves the filter actually
   keeps metadata across a nested span. `Ash.Tracer.span/4` is a
   **macro**, so the test module needs `require Ash.Tracer` (or
   `import Ash.Tracer, only: [span: 4]`):
   ```elixir
   require Ash.Tracer

   Ash.Tracer.span :action, "outer", [AshTracer] do
     AshTracer.set_metadata(:action, %{
       resource: SomeResource,
       action: :write,
       actor: actor_for(tenant_id),
       tenant: tenant_id,
       authorize?: true
     })

     Ash.Tracer.span :changeset, "nested", [AshTracer] do
       :ok                # filtered: start_span/stop_span never reach AshTracer
     end

     # set_handled_error MUST fire while still inside the outer
     # :action span — once the macro's `after` runs stop_span/0, the
     # metadata is gone by design.
     AshTracer.set_handled_error(%Ash.Error.Forbidden{errors: []}, [])
   end
   ```
   - Assert the `:policy_denied` row landed under the actor's tenant.
   - Before Fix 1, Ash's dispatcher would call our `stop_span/0` for
     the nested span and the row would be missing.

3. **System actor cross-tenant denial** — locks in Fix 2:
   - `Actor.system(tenant_a)` attempts `Block.write` against
     `tenant_b`'s workspace; assert the resulting row has
     `actor_kind: :system` (currently emits `:user` because
     `user_id: nil` key is present).

**`test/jido_claw/audit/producers_test.exs`** — extend "real action
surfaces" section:

4. **Block.revise audit actor metadata** — locks in Fix 2 at the
   `Block.revise` surface:
   - User revise via `actor_for(tenant_id)` → `actor_kind: :user`,
     `actor_id == tenant_id` (currently `actor_id: nil`).
   - System revise via `Actor.system(tenant_id)` of a user-sourced
     prior → `actor_kind: :system`, `actor_id: nil` (currently
     `actor_kind: :user` because `actor_kind_for(prior.source)`
     reads the prior block's source, not the actor).

**`test/jido_claw/audit/actor_classifier_test.exs`** (new) — pure unit
tests for the classifier, covering:
- `nil` → `{:system, nil}`
- `Actor.system(tid)` → `{:system, nil}`
- `Actor.build(user)` → `{:user, user.id}`
- `%{agent_id: "a", tenant_id: "t"}` → `{:agent, "a"}`
- `%{kind: :user, id: "u"}` and `%{"kind" => "user", "id" => "u"}`
  → `{:user, "u"}` (rule 4, both key flavors)
- `%{id: "abc"}` (bare) → `{:system, nil}` (rule 4 not satisfied)
- `%{kind: :system, user_id: "u", tenant_id: "t"}` → `{:system, nil}`
  (explicit kind beats non-nil `user_id`)

## Existing utilities to reuse

- `JidoClaw.Audit.AsyncWriter.@sup` (`JidoClaw.Audit.TaskSupervisor`)
  is already wired in `lib/jido_claw/application.ex:78` — `flush/0`
  just walks its children.
- `JidoClaw.Authorization.Actor` (`lib/jido_claw/authorization/actor.ex`)
  is the source of truth for the canonical actor shape; the
  classifier's clauses follow its `build/1` (`%{user_id, tenant_id}`)
  and `system/1` (`%{kind: :system, user_id: nil, tenant_id}`)
  contracts.
- Test helper `actor_for/1` (`test/support/jido_claw/tenant_case.ex:79`)
  already produces a canonical user actor — reuse for the new
  classifier coverage.

## Verification

Run, in order:

1. `mix format`
2. `mix compile --warnings-as-errors`
3. `mix test test/jido_claw/audit/actor_classifier_test.exs` (new unit
   tests)
4. `mix test test/jido_claw/audit/ash_tracer_test.exs test/jido_claw/audit/producers_test.exs`
   (regression coverage)
5. `mix test 2>&1 | tee /tmp/jc-full.log` (full suite)
6. `grep -iE 'postgrex.*owner exited|client #PID.* exited' /tmp/jc-full.log`
   — should be empty after the drain is wired in.
7. `mix ash_postgres.generate_migrations --check` — should pass
   (no schema changes expected).

## Out of scope

- Refactoring the three non-canonical actor-classification call sites
  (`producers.ex` MemoryWrite, `signal_listener.ex`,
  `web/plugs/api_key_auth.ex` / `web/controllers/auth_controller.ex`).
  They classify off different inputs and the review didn't flag them.
- Production-side graceful-shutdown drain for `AsyncWriter`. `flush/0`
  is added with public visibility so it could be hooked into
  `Application.stop/1` later, but that's not required by the review.
- Committing the work. Per memory, no commits without an explicit
  request — the plan ends at "all tests pass cleanly".
