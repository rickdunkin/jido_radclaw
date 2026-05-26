# Resolve code-review findings for `quiet-moonbeam`

## Context

Code review on the T1-3 structured-output branch surfaced three correctness
gaps plus a precommit-blocker. We need to address all four for `mix precommit`
to come up clean.

The four issues, in priority order:

1. **`parse_verdict/1` crash on unknown atom verdicts**
   (`lib/jido_claw/workflows/iterative_workflow.ex:147`). The newly-added
   `when is_atom(verdict)` clause returns the verdict atom unchanged, but the
   caller at `:259` only matches `:pass | :fail`. A typed map with
   `%{verdict: :unknown}` (which `Zoi.enum/1` rejects upstream, but malformed
   stubbed data or a future schema widening could produce) would crash with
   `CaseClauseError` instead of conservatively failing the iteration.

2. **`run_step_async` is untested.** Today the only StepAction tests use
   `EchoStub`, which doesn't export `ask/3` — so `function_exported?(module,
   :ask, 3)` at `step_action.ex:90` is false and every test exercises the
   sync fallback at `:110`. The `typed_output` capture path (`:140-158`)
   has zero coverage.

3. **`get_agent_result` only sees the initial spawn's `request_id`.**
   `send_to_agent` (`lib/jido_claw/tools/send_to_agent.ex:37`) generates a
   new `request_id` per follow-up turn but never tells the tracker.
   `AgentTracker` already carries a `:request_id` field on `AgentEntry` —
   set once at registration, never updated. The tool description on
   `get_agent_result` says "return the result" generically, which is
   misleading when follow-ups have happened.

4. **`mix credo --strict` fails on 10 unrelated duplicate-code findings.**
   The repo has a `JidoClaw.NoClone` mixin that annotates duplicates with
   `@no_clone true` to suppress ExDNA's clone detector. The annotation
   syntax is wrong for `ex_dna 1.5.2`: per
   `deps/ex_dna/lib/ex_dna/ast/annotator.ex:105-122`, ExDNA only reads
   comment-form pragmas (`# ex_dna:disable-for-next-line` etc.) — module
   attributes are ignored. All 10 sites have been silently failing
   precommit since the mixin was introduced.

## Approach

### 1. `parse_verdict/1` — let unknown atoms fall through to `:fail`

`lib/jido_claw/workflows/iterative_workflow.ex` — **delete line 147**:

```elixir
def parse_verdict(%{verdict: verdict}) when is_atom(verdict), do: verdict
```

The catch-all `def parse_verdict(_), do: :fail` at `:166` already covers the
"unknown verdict atom" case correctly, matching the docstring's
"conservative because a missing/garbled verdict should not be treated as
success" promise. The `:pass`/`:fail` clauses at `:145-146` continue to
handle the happy path. No new clause needed — the change is purely a
deletion.

Add a regression test in `test/jido_claw/workflows/iterative_workflow_test.exs`
alongside the existing `parse_verdict/1` cases:

```elixir
test "parse_verdict/1 returns :fail for unknown atom verdicts" do
  assert IterativeWorkflow.parse_verdict(%{verdict: :unknown}) == :fail
  assert IterativeWorkflow.parse_verdict(%{verdict: :error}) == :fail
end
```

### 2. StepAction async-path test

Two pieces:

**(a) Test seam for `Jido.AgentServer`** —
`lib/jido_claw/workflows/step_action.ex:141` calls
`AgentServer.await_completion` directly. Mirror the established pattern from
`lib/jido_claw/tools/get_agent_result.ex:179-181`:

```elixir
defp agent_server_module do
  Application.get_env(:jido_claw, :step_agent_server, Jido.AgentServer)
end
```

Update `await_step/4` to call `agent_server_module().await_completion(...)`.
No production-code behavior change. **Watch the alias**: the existing
`alias Jido.AgentServer` at `step_action.ex:51` is referenced only at
`:141` today. Either reuse `AgentServer` as the default value (`defp
agent_server_module, do: Application.get_env(..., AgentServer)`) to keep
the alias live, or drop the alias entirely and inline `Jido.AgentServer`
in the default. Without one of those, `mix compile --warnings-as-errors`
will fail on unused alias.

**(b) Test stub that exports `ask/3`** — Create
`test/support/echo_ask_stub.ex`. Mirror `test/support/echo_stub.ex`'s
`use Jido.Agent` + `name:` macro setup, but implement `ask/3` instead of
`ask_sync/3`:

```elixir
def ask(_pid, _task, opts) do
  rid = Keyword.fetch!(opts, :request_id)
  {:ok, %{id: rid}}
end
```

This makes `function_exported?(module, :ask, 3)` return true and routes
through `run_step_async`.

**(c) New test in `test/jido_claw/workflows/step_action_test.exs`** —
register `EchoAskStub` via the existing templates fake, set
`Application.put_env(:jido_claw, :step_agent_server, FakeStepAgentServer)`
where `FakeStepAgentServer.await_completion(_pid, _opts)` returns:

```elixir
{:ok,
 %{
   status: :completed,
   result: %{
     status: :completed,
     result: %{verdict: :pass, confidence: :high, reasoning: "ok"},
     meta: %{output: %{status: :validated, schema_kind: :map}}
   }
 }}
```

Assert the returned `%StepResult{}` carries:
- `typed_output: %{verdict: :pass, ...}` populated
- `result: <stringified text>` (from `Output.extract_result/1` over the
  typed map — likely the inspect-rendered form; assert it's a non-empty
  binary)

Add a second case that returns `meta.output.status: :error` — assert
`typed_output: nil`, confirming `Output.typed_request_output/1`'s filter at
`reasoning/output.ex:80`.

Use `setup` to read the prior value of `:step_agent_server` and `on_exit`
to restore it (or `Application.delete_env` if originally unset) so other
tests aren't affected. Keep the `FakeStepAgentServer.await_completion/2`
narrow — implement only the two return shapes the test exercises
(`:validated` + `:error`); anything else should raise so unexpected
callers fail loudly.

### 3. Wire `latest_request_id`

**(a) `lib/jido_claw/agent_tracker.ex`** — add a public mutator. Use
`GenServer.call`, not cast, so that `send_to_agent` returning guarantees a
following `get_agent_result` sees the new request_id (no race in tests or
production):

```elixir
@doc """
Update the tracked `:request_id` for an agent. Called by `send_to_agent`
after each follow-up turn so `get_agent_result` reads the latest request's
typed output, not the initial spawn's. No-op if the agent is not tracked.
"""
@spec update_request_id(String.t(), String.t()) :: :ok
def update_request_id(id, request_id) when is_binary(id) and is_binary(request_id) do
  GenServer.call(__MODULE__, {:update_request_id, id, request_id})
end
```

Add a matching `handle_call({:update_request_id, id, rid}, _from, state)`
that delegates to the existing private `update_agent/3` helper at `:279`
and replies `:ok` regardless of whether the agent exists (matches the
no-op-on-missing style of the existing `update_agent/3`):

```elixir
def handle_call({:update_request_id, id, rid}, _from, state) do
  {:reply, :ok, update_agent(state, id, fn entry -> %{entry | request_id: rid} end)}
end
```

No struct change — `:request_id` already lives on `AgentEntry`.

**(b) `lib/jido_claw/tools/send_to_agent.ex`** — after
`request_id = JidoClaw.register_child_correlation(child_tool_context)` at
`:37`, call:

```elixir
agent_tracker().update_request_id(params.agent_id, request_id)
```

Use the existing `agent_tracker/0` DI shim at `:106` so tests can verify the
call via the test tracker.

**(c) Tests** — extend `test/jido_claw/tools/spawn_agent_test.exs` (where
`AgentTracker` is currently tested per the earlier exploration) with:

```elixir
test "AgentTracker.update_request_id/2 overwrites the stored request_id" do
  {:ok, pid} = Agent.start_link(fn -> nil end)
  :ok = AgentTracker.register("upd-rid", pid, "coder", "task", request_id: "rid-1")
  :ok = AgentTracker.update_request_id("upd-rid", "rid-2")
  assert %{request_id: "rid-2"} = AgentTracker.get_agent("upd-rid")
end
```

Add to `test/jido_claw/tools/send_to_agent_test.exs` a test that swaps in a
fake agent tracker capturing `update_request_id/2` calls and asserts the
follow-up `request_id` is recorded with the same value passed to
`register_child_correlation`. **Required prereq**: the existing
`FakeTracker` in that file does not implement `update_request_id/2`, so
every existing test will crash on `UndefinedFunctionError` once
`send_to_agent` starts calling it. Add a no-op `update_request_id/2`
clause to the existing `FakeTracker` first, then layer the capture-and-
assert variant on top for the new test.

**(d) Tool description honesty** — update
`lib/jido_claw/tools/get_agent_result.ex:5-6` description to say "Wait for
a spawned child agent to finish its current task". Removing "task" entirely
would be misleading; "current task" accurately covers both initial-spawn
and post-`send_to_agent` results now that the wiring is in place.

### 4. Fix the Credo `NoClone` mechanism

Per `deps/ex_dna/lib/ex_dna/ast/annotator.ex:105-122`, ExDNA only reads
comment-form pragmas. No check-name suffix is required (the parser
ignores the rest of the line). **Critical placement detail**: the
annotator only strips `:def`, `:defp`, `:defmacro`, and `:defmacrop` nodes
when the pragma precedes them. It does **not** strip a `defmodule`. So
for the four Ash Change modules, the pragma must sit immediately above
the duplicated `def change(changeset, _opts, context)` — after the
preceding `@impl true` — not above the `defmodule Changes.*` line:

```elixir
@impl true
# ex_dna:disable-for-next-line
def change(changeset, _opts, context) do
```

For non-Ash sites (`sync_file`, `load_from_disk`, `resolve_scope`), the
pragma sits directly above the `def`/`defp` it suppresses.

**The 10 sites:**

- `lib/jido_claw/forge/runners/claude_code.ex:179` — `sync_file/2`
- `lib/jido_claw/forge/runners/codex.ex:308` — `sync_file/2`
- `lib/jido_claw/reasoning/pipeline_store.ex:134` — `load_from_disk/0`
- `lib/jido_claw/reasoning/strategy_store.ex:178` — `load_from_disk/0`
- `lib/jido_claw/audit/signal_listener.ex:129` — `resolve_scope/?`
- `lib/jido_claw/conversations/recorder.ex:763` — `resolve_scope/?`
- `lib/jido_claw/memory/resources/fact.ex:582` —
  `Changes.ResolveInitialEmbeddingStatus`
- `lib/jido_claw/memory/resources/fact.ex:633` —
  `Changes.ValidateCrossTenant`
- `lib/jido_claw/solutions/resources/solution.ex:557` —
  `Changes.ResolveInitialEmbeddingStatus`
- `lib/jido_claw/memory/resources/block.ex:341` —
  `Changes.ValidateCrossTenant`

**Remove the `use JidoClaw.NoClone` line from each of the 10 occurrences**
(`fact.ex` contains two nested defmodules at `:579` and `:627`, each with
their own `use`):

- `claude_code.ex:4`, `codex.ex:38`, `pipeline_store.ex:38`,
  `strategy_store.ex:55`, `signal_listener.ex:18`, `recorder.ex:92`,
  `fact.ex:579`, `fact.ex:627`, `solution.ex:552`, `block.ex:338`.

**Delete `lib/jido_claw/no_clone.ex`.** The mixin's body is a no-op
(`defmacro __using__(_), do: nil`) — removing it has no runtime impact.

### Verification

1. `mix compile --warnings-as-errors`
2. `mix format`
3. `mix credo --strict` — must show 0 issues. The 10 `[D]` findings from
   ExDNA should disappear; if any remain, the comment isn't on the
   immediately-preceding line of the clone candidate (Ash Change
   `defmodule` not the inner `change/2`, etc.) — adjust placement.
4. `mix dialyzer --format short` — no new warnings expected; the
   `update_request_id/2` spec is `String.t(), String.t() :: :ok`.
5. `mix test` — full suite green. New tests:
   - `iterative_workflow_test.exs` (parse_verdict unknown atom)
   - `step_action_test.exs` (async path × 2 cases)
   - `spawn_agent_test.exs` (update_request_id/2)
   - `send_to_agent_test.exs` (tracker update on follow-up)
6. **`mix precommit` — required to pass cleanly. Plan is not complete
   until it does.**
7. **Smoke**: `mix jidoclaw`, spawn a Verifier on "verify the project
   compiles", then `send_to_agent` with a follow-up message, then
   `get_agent_result`. Confirm the returned `result` reflects the
   follow-up response, not the initial-task response.

### Files to modify

- `lib/jido_claw/workflows/iterative_workflow.ex` — delete line `:147`.
- `lib/jido_claw/workflows/step_action.ex` — add `agent_server_module/0`
  shim, update `await_step/4` call.
- `lib/jido_claw/agent_tracker.ex` — add `update_request_id/2` +
  `handle_call`.
- `lib/jido_claw/tools/send_to_agent.ex` — call
  `AgentTracker.update_request_id/2` after new `request_id` is generated.
- `lib/jido_claw/tools/get_agent_result.ex` — soften description text
  ("current task").
- `lib/jido_claw/no_clone.ex` — **delete**.
- 10 lib sites listed under §4 — replace `@no_clone true` with
  `# ex_dna:disable-for-next-line` (above the `def`, not the
  `defmodule`); remove `use JidoClaw.NoClone` (10 occurrences across
  9 files; `fact.ex` has two).
- `test/support/echo_ask_stub.ex` — **new**; mirrors `echo_stub.ex` but
  exports `ask/3`.
- `test/jido_claw/workflows/iterative_workflow_test.exs` — add
  `parse_verdict` regression test.
- `test/jido_claw/workflows/step_action_test.exs` — add async-path test
  with fake agent server.
- `test/jido_claw/tools/spawn_agent_test.exs` — add
  `update_request_id/2` test.
- `test/jido_claw/tools/send_to_agent_test.exs` — add tracker-update
  assertion on follow-up.

### Open questions / risks

- **`function_exported?` + `Code.ensure_loaded`** — `step_action.ex:88`
  ensures the module is loaded before checking. Confirm the new
  `EchoAskStub` is compiled into the test support tree (it should be once
  it lives under `test/support/` — see `mix.exs` `elixirc_paths` for the
  test env).
