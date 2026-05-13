# Post-review cleanup for Credo Tier 3 (Phase 7 follow-ups)

## Context

The Credo Tier 3 plan (`.claude/plans/we-ve-just-recently-added-linked-snowflake.md`) has been implemented and code-reviewed. The review surfaced two **Low**-severity issues, both validated:

1. **Inaccurate callback typespec** in the new `JidoClaw.Memory.EmbeddingResolver` (Phase 7b extraction). The `compute_fn` callback's `model` argument is declared as `atom()`, but the value comes from `PolicyResolver.model_for_query/1`, which returns `request_model: String.t()` (`"voyage-4"`). Runtime is correct; the spec is wrong and will mislead future readers and Dialyzer.

2. **Promised but missing test coverage** for Phase 7a. The plan committed to "targeted tests covering … cancellation mid-flight … both functions must behave correctly after extraction." No test exercises the `:command_cancelled` receive clause in either `do_collect/5` (local/VFS) or `do_collect_ssh/6` (SSH). Both clauses dispatch to the shared `cancellation_error/0` helper introduced in Phase 7a, so the clause is the contract under test.

Outcome: spec is honest, both receive clauses have coverage, and the Phase 7a promise is fully delivered.

## Files modified

- `lib/jido_claw/memory/embedding_resolver.ex` — typespec correction.
- `test/jido_claw/shell/session_manager_ssh_test.exs` — add one SSH cancellation test (this file already owns the SSH path).
- `test/jido_claw/shell/session_manager_vfs_test.exs` *or* a new `test/jido_claw/shell/session_manager_cancel_test.exs` — one local-path cancellation test. Decide during implementation based on where the existing VFS/local fixture is most reusable.

No production code changes for Finding 2; the test is purely additive.

## Changes

### 1. Fix `EmbeddingResolver` callback spec

`lib/jido_claw/memory/embedding_resolver.ex:29-31` currently declares:

```elixir
@spec resolve(String.t() | nil, String.t() | nil, keyword(), (String.t(), atom(), keyword() ->
                                                                [float()] | nil)) ::
        [float()] | nil
```

`PolicyResolver.model_for_query/1` (see `lib/jido_claw/embeddings/policy_resolver.ex:25-29, 52-56`) defines `request_model: String.t()` in its `provider_spec` type, and `resolve_via_policy/4` (line 45) passes that value straight to `compute_fn`. Change the second positional argument of the callback type from `atom()` to `String.t()`. Also align the callback's first argument with the outer `resolve/4` spec — the outer accepts `String.t() | nil`, so the honest callback type is:

```elixir
@spec resolve(String.t() | nil, String.t() | nil, keyword(),
              (String.t() | nil, String.t(), keyword() -> [float()] | nil)) ::
        [float()] | nil
```

If, during implementation, the callsites and `resolve_via_policy/4` show that `nil` is never a real query, prefer tightening the **outer** `query` arg to `String.t()` (and updating the callback to match) over keeping the `| nil` slack. Pick one and make them consistent.

No callsite changes needed: both callers (`JidoClaw.Solutions.Matcher.compute_voyage/3` and `JidoClaw.Memory.Retrieval.compute_voyage/3`) already accept a string for the model arg.

### 2. Add cancellation tests for both receive clauses

The receive blocks in `lib/jido_claw/shell/session_manager.ex:1288-1289` (local) and `:1416-1417` (SSH) both match:

```elixir
{:jido_shell_session, ^session_id, :command_cancelled} ->
  cancellation_error()
```

and `cancellation_error/0` (`:1466`) returns `{:error, "Command was cancelled"}`. The cancel broadcast originates from `JidoClaw.Core.JidoShellSessionServerPatch.do_cancel/1`; the public trigger is **`Jido.Shell.ShellSessionServer.cancel/1`** (the module lives under `Jido.Shell.*`, not `JidoClaw.Shell.*`). Subscription uses `Jido.Shell.ShellSessionServer.subscribe/2` from the same module.

**Important nuance:** the SessionManager's own SSH timeout handler at `:1322-1326` already calls `cancel/1` after `do_collect_ssh/6` returns `{:timeout, _}` — but by then the receive loop has already exited via the `after` clause, so the cancellation broadcast is drained, not received. To hit the `:command_cancelled` clause, the cancel must arrive **externally and mid-flight**, before the receive's `after` deadline.

**Test plan** (one test per path; both follow the same shape — bootstrap a session first so subscription is safe, then run the long command in a Task and cancel from the test process):

1. **Bootstrap the session with a quick command** so the underlying `ShellSessionServer` exists before subscribing. The session id is deterministic from the workspace + backend:
   - **Host/local**: `SessionManager.run(ws, "true", 5_000, project_dir: tmp, backend: :host)`; then `session_id = ws <> ":host"`.
   - **SSH**: `SessionManager.run(ws, "true", 5_000, project_dir: tmp, backend: :ssh, server: "staging")` (drain any `{:fake_ssh, _}` messages afterwards); then `session_id = ws <> ":ssh:staging"`.

2. Subscribe: `Jido.Shell.ShellSessionServer.subscribe(session_id, self())`.

3. Start the long-running command in a `Task.async`:
   - **Host/local**: `"sleep 10"`.
   - **SSH**: a command string containing `__fake_hang__` — FakeSSH still notifies the test about `{:exec, _, _, _}` (see `test/support/fake_ssh.ex:74,124`), it just emits no backend events for that channel, so `do_collect_ssh/6` blocks in `receive` as required. No `:no_events` flip needed unless the FakeSSH command-matcher changes.
   - **Timeout argument**: generous (e.g. `5_000` ms) so the external cancel arrives well before `after` fires.

4. Wait deterministically for the command to be in flight: `assert_receive {:jido_shell_session, ^session_id, :command_started}` (the subscriber receives this lifecycle event because we subscribed before launching the Task).

5. Cancel: `Jido.Shell.ShellSessionServer.cancel(session_id)`.

6. Assert: `assert Task.await(task) == {:error, "Command was cancelled"}`.

### 3. (Optional) Drop a one-line comment cross-referencing the tests

Above `defp cancellation_error` at `session_manager.ex:1466`, no new comment is needed — the function is already documented. Skip unless the implementer feels it adds value.

## Verification

After both changes:

```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix test test/jido_claw/shell/         # focused — confirms new tests pass and nothing nearby breaks
mix test                               # full suite — confirms no spec ripple from EmbeddingResolver
mix credo --format json --mute-exit-status > /tmp/credo_fresh.json
```

Expect:
- Full suite passes with the two added tests, 0 failures.
- Credo deltas: none. The deferred buckets (`Nesting` 79, `CyclomaticComplexity` 17, `ExDNA.Credo` 53) stay where they are.
- The new SSH test should also assert no leaked FakeSSH messages via the existing `on_exit` teardown — follow the pattern at `session_manager_ssh_test.exs:54-64`.

No migrations, no config changes, no Ash resource touches.

## Commit-slicing guidance (not authorization)

Two natural commits — keep them separate so the spec fix can ship even if the test scaffolding needs iteration:

1. `fix: correct EmbeddingResolver callback spec — model is String.t(), not atom()`
2. `test: cover :command_cancelled receive clause in SessionManager (Phase 7a follow-up)`

Commit only when explicitly asked.
