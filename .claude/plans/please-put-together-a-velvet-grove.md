# Phase 3b — Memory Consolidator Runtime & Frozen-Snapshot Prompt

## Context

Phase 3a (commit `76f2de3`) shipped the seven memory resources and the
read/write/scope plumbing. Phase 3b makes those resources actually fill
themselves: a per-scope worker runs on a cadence, invokes a frontier-model
coding harness inside Forge, collects memory mutations through a scoped
MCP tool surface, and publishes them transactionally. The other half is
turning `JidoClaw.Agent.Prompt.build/1` into a frozen snapshot so
Anthropic's prompt cache (`anthropic_prompt_cache: true`, set on
`agent.ex:50`) can amortise across turns. Source plan:
`docs/plans/v0.6/phase-3b-memory-consolidator.md`.

After 3b: Block tier auto-fills every cadence tick, the prompt cache fires
both intra-turn and inter-turn, and `/memory consolidate` /
`/memory status` are wired.

## Confirmed design decisions

1. **Snapshot trigger** — built and persisted on session creation when
   `kind != :cron` and `metadata["prompt_snapshot"]` is missing.
2. **Stream-json parsing** — batch-mode in `parse_output/1`.
3. **Scoped MCP server** — single static
   `JidoClaw.Memory.Consolidator.MCPServer` with `use Jido.MCP.Server`
   (tools are `Jido.Action` modules). Bandit endpoint per run, server
   module shared. Tools read `run_id` from
   `ctx.assigns[:consolidator_run_id]`.
4. **Skip rows** — every cadence tick produces a `ConsolidationRun`
   row when a per-scope RunServer reaches the row-write step. Skip
   paths set `status: :skipped` with a string `error`. Behind
   `write_skip_rows: true`.
5. **`run_now/2` result shape** — `{:ok, run}` for `:succeeded`;
   `{:error, error_string}` for `:skipped` and `:failed`. The row is
   always persisted; the API split makes CLI/test code natural to read.

## Deferred to 3c

- `JidoClaw.Forge.Runners.Codex`. With `harness: :codex`, the
  per-scope RunServer immediately finalises as `:failed,
  "no_runner_configured"` (guard runs *inside* the run path so the
  every-tick row guarantee holds — see §5d).
- `anthropic_prompt_cache: true` sweep over
  `lib/jido_claw/agent/workers/`.
- `consolidation_policy: :local_only` runner branch — `PolicyResolver`
  returns `{:skip, "consolidation_local_runner_unavailable"}`.

## Top design item — lock ownership / RunServer responsiveness

A session-level `pg_try_advisory_lock` taken via
`Repo.checkout(fn -> ... end)` pins the connection to the executing
process. RunServer can't both hold the lock and serve `GenServer.call`s.

**Resolution:** dedicated lock-owner Task decoupled from RunServer.

```elixir
defmodule JidoClaw.Memory.Consolidator.LockOwner do
  @moduledoc false

  def acquire(scope_lock_key) do
    parent = self()
    {:ok, pid} = Task.start_link(fn -> hold(scope_lock_key, parent) end)

    receive do
      {:acquired, ^pid} -> {:ok, pid}
      {:busy, ^pid} -> :busy
    after
      5_000 ->
        Process.unlink(pid)
        Process.exit(pid, :kill)
        {:error, :lock_acquire_timeout}
    end
  end

  def release(lock_pid) do
    ref = Process.monitor(lock_pid)
    send(lock_pid, :release)

    receive do
      {:released, ^lock_pid} ->
        Process.demonitor(ref, [:flush])
        :ok

      {:DOWN, ^ref, :process, _, _} ->
        :ok  # already gone — nothing to do
    after
      5_000 ->
        Process.demonitor(ref, [:flush])
        :ok  # don't stall cleanup on a stuck or unresponsive lock-owner
    end
  end

  defp hold(key, parent) do
    JidoClaw.Repo.checkout(fn ->
      case JidoClaw.Repo.query!("SELECT pg_try_advisory_lock($1)", [key]) do
        %{rows: [[true]]} ->
          send(parent, {:acquired, self()})

          receive do
            :release ->
              JidoClaw.Repo.query!("SELECT pg_advisory_unlock($1)", [key])
              send(parent, {:released, self()})
          end

        %{rows: [[false]]} ->
          send(parent, {:busy, self()})
      end
    end)
  end
end
```

**Pool-sizing note.** The lock-owner holds one pinned pool connection
for the full harness window. With `max_concurrent_scopes: 4`, the
Repo pool size must accommodate four pinned lock connections plus
normal reads/writes from the rest of the system. Confirm
`config :jido_claw, JidoClaw.Repo, pool_size:` is at least
`base_size + max_concurrent_scopes` (current default + 4 with no
other changes; bump if base sizing is tight).

**Implementer validation step.** Before coding RunServer against this,
write a 20-line test that proves: while a separate process holds a
`Repo.checkout/1`, *another* process can still execute
`Repo.query!`/`Ash.read` against the pool (using a different
connection). The plan-scale assumption is one pinned connection, not
the whole pool. If that fails, fall back to a `consolidation_locks`
DB table with `(scope_lock_key, owner_pid, acquired_at)` and a
janitor for stale rows.

## Pre-3b prep

### Prep A — `Memory.Scope.lock_key/3` is not actually 63-bit

`scope.ex:200` uses `:erlang.phash2/1` (27-bit) and masks with
`@max_bigint`. Mask doesn't expand. Replace:
```elixir
def lock_key(tenant_id, scope_kind, fk_id) do
  bin =
    :crypto.hash(:sha256,
      :erlang.term_to_binary({tenant_id, scope_kind, fk_id || ""}))

  <<int::signed-64, _::binary>> = bin
  int
end
```

### Prep A.1 — `Memory.Scope.primary_fk/1` helper

The plan needs a single source of truth for "which FK identifies this
scope" (used for lock-key computation, telemetry metadata, CLI
history args, and candidate identity). Add to
`lib/jido_claw/memory/scope.ex`:
```elixir
@spec primary_fk(scope_record()) :: Ecto.UUID.t() | nil
def primary_fk(%{scope_kind: :session, session_id: id}), do: id
def primary_fk(%{scope_kind: :project, project_id: id}), do: id
def primary_fk(%{scope_kind: :workspace, workspace_id: id}), do: id
def primary_fk(%{scope_kind: :user, user_id: id}), do: id
```
Resolved scope records from `Memory.Scope.resolve/1` carry the
populated FK columns; `primary_fk/1` selects the right one based on
`scope_kind`. **Use this everywhere** (RunServer lock acquisition,
telemetry metadata, history queries) — never reach for `:fk_id`
which doesn't exist on resolved scopes.

### Prep B — `Fact.for_consolidator` doesn't filter `source`

Add a `:sources` argument defaulting to
`[:model_remember, :user_save, :imported_legacy]`. Update
`Preparations.ForConsolidator` to apply `source IN ?`.

### Prep C — `Forge.Sandbox.Local.run/4` honors timeout, drops `sh -c`

Two surgical fixes to **`Forge.Sandbox.Local.run/4` only** (`exec/3`
stays untouched — existing callers may rely on its shell semantics):

1. **Timeout enforcement.** Wrap `System.cmd/3` in
   `Task.async/Task.yield/Task.shutdown(:brutal_kill)` honoring
   `run_opts[:timeout]`. Return shape stays `{output, code}`. On
   timeout: `{"", :timeout}` (empty output, atom code). `System.cmd`
   doesn't expose partial output on kill — accept that for 3b. Future
   streaming-output need → `Port.open` upgrade.
2. **Argument-array execution.** Replace `System.cmd("sh", ["-c",
   joined], opts)` with `System.cmd(cmd, args, opts)`.

Audit `lib/jido_claw/forge/` for any other `Sandbox.run/4` callers
passing shell-style strings; migrate to argv before this lands. The
ClaudeCode runner already passes a clean argv.

## Existing infrastructure to reuse

- `Memory.Scope.resolve/1` — expects tool-context keys
  (`:workspace_uuid`, `:session_uuid`, etc.), not Session column
  names. Mapping helper at §1b.
- `Memory.Scope.chain/1` — most-specific FIRST.
- `Memory.Scope.lock_key/3` (Prep A), `primary_fk/1` (Prep A.1).
- `Memory.Retrieval.search/1` — keyword-list arity.
- `Security.CrossTenantFk.validate/2` — telemetry already wired.
- `Fact.for_consolidator` (Prep B).
- Step-7 publish actions: `Fact.record/1`, `Fact.promote/2`,
  `Fact.invalidate_by_id/2`, `Block.write/1`, `Block.revise/2`
  (already commits invalidate + new write + `BlockRevision` row in
  `block.ex:586-601` — **don't** double-call
  `BlockRevision.create_for_block/1`), `Link.create_link/1`,
  `FactEpisode.create_for_pair/1`, `Episode.record/1`,
  `ConsolidationRun.record_run/1`. Match each resource's actual
  code-interface arity.
- `Forge.Manager.start_session/2` — `(session_id, spec)` shape.
  Generate `session_id = Ecto.UUID.generate()` up front.
- `Forge.Harness.resolve_client/1` — add `:local` clause.
- `Forge.Resources.Session.spec :map` and `metadata :map` — jsonb.
- `Anubis.Server.Handlers.Tools` shim auto-applies.
- `Cron.Scheduler.schedule/2` — accepts arbitrary `:mode`, needs a
  tenant supervisor (§4).
- `ConsolidationRun.latest_for_scope` and `:history_for_scope`.

## Component plan

### 1. Frozen-snapshot system prompt (§3.14)

#### 1a. Re-order startup so persistence happens before prompt injection

**Modify** `lib/jido_claw/startup.ex`:
- `inject_system_prompt/3` taking `(pid, project_dir, session_or_nil)`.
  When `session.metadata["prompt_snapshot"]` is non-nil, inject
  verbatim. Otherwise call `Prompt.build(project_dir)`.
- 2-arity wrapper for callers without a session.

**Modify** `lib/jido_claw.ex:71-77` — reorder:
```elixir
with {:ok, _} <- JidoClaw.Startup.ensure_project_state(project_dir),
     {:ok, _pid} <- JidoClaw.Session.Supervisor.ensure_session(tenant_id, session_id),
     {:ok, agent_pid} <- resolve_agent_pid(session_id),
     {:ok, workspace, session} <-
       resolve_persistence(tenant_id, project_dir, session_id, kind, opts),
     :ok <- JidoClaw.Session.Worker.set_session_uuid(tenant_id, session_id, session.id),
     :ok <- JidoClaw.Startup.inject_system_prompt(agent_pid, project_dir, session) do
  run_chat_turn(...)
end
```

**Modify** `resolve_persistence/5` (`lib/jido_claw.ex:98-115`) — pass
`project_dir: project_dir` to `Conversations.Resolver.ensure_session/5`.

**Modify** `lib/jido_claw/cli/repl.ex:148-176` — run
`ensure_persisted_session` before `inject_system_prompt`.

#### 1b. Build and persist the snapshot at session-create time

**Modify** `lib/jido_claw/conversations/resolver.ex`:

```elixir
defp maybe_persist_snapshot(%Session{kind: :cron} = s, _opts), do: {:ok, s}
defp maybe_persist_snapshot(%Session{metadata: %{"prompt_snapshot" => _}} = s, _), do: {:ok, s}

defp maybe_persist_snapshot(s, opts) do
  project_dir = Keyword.get(opts, :project_dir, File.cwd!())

  with {:ok, scope} <- JidoClaw.Memory.Scope.resolve(scope_ctx(s)),
       snap = JidoClaw.Agent.Prompt.build_snapshot(project_dir, scope),
       {:ok, s} <- JidoClaw.Conversations.Session.set_prompt_snapshot(s, snap) do
    {:ok, s}
  else
    _ -> {:ok, s}  # snapshot is best-effort
  end
end

# Memory.Scope.resolve/1 expects tool-context keys, not column names.
defp scope_ctx(%Session{} = s) do
  %{
    tenant_id: s.tenant_id,
    user_id: s.user_id,
    workspace_uuid: s.workspace_id,
    session_uuid: s.id
  }
end
```

**Modify** `lib/jido_claw/conversations/resources/session.ex`:
```elixir
update :set_prompt_snapshot do
  accept []
  argument :snapshot, :string, allow_nil?: false

  change fn changeset, _ctx ->
    snap = Ash.Changeset.get_argument(changeset, :snapshot)
    md = Ash.Changeset.get_attribute(changeset, :metadata) || %{}
    Ash.Changeset.change_attribute(changeset, :metadata,
      Map.put(md, "prompt_snapshot", snap))
  end
end
```
With `define :set_prompt_snapshot, args: [:snapshot]`.

#### 1c. `Prompt.build_snapshot/2` and Block tier rendering

**Modify** `lib/jido_claw/agent/prompt.ex:276-292`:
- `build_snapshot(project_dir, scope)` — same prefix as `build/1` for
  base prompt, project_type, skills, JIDO.md. Drop
  `load_agent_count/0` and `git_branch/0`. Replace `load_memories/0`
  with `render_block_tier(scope)`.
- `def build(dir), do: build_snapshot(dir, nil)`. `nil` scope renders
  no Block tier.

**Add** `JidoClaw.Memory.list_blocks_for_scope_chain/1` to
`lib/jido_claw/memory.ex`. Note: `Block.for_scope_chain/2` returns
`{:ok, blocks} | {:error, _}` — unwrap before grouping. Also:
`Block.for_scope_chain/2` doesn't return rows in scope-chain order,
so dedup by label using an explicit rank map.

```elixir
def list_blocks_for_scope_chain(scope) do
  chain = Memory.Scope.chain(scope)  # most-specific FIRST
  rank =
    chain
    |> Enum.with_index()
    |> Map.new(fn {{kind, fk}, i} -> {{kind, fk}, i} end)

  chain_maps = Enum.map(chain, fn {kind, fk} -> %{scope_kind: kind, fk_id: fk} end)

  case JidoClaw.Memory.Block.for_scope_chain(scope.tenant_id, chain_maps) do
    {:ok, blocks} ->
      blocks
      |> Enum.group_by(& &1.label)
      |> Enum.map(fn {_label, group} ->
        Enum.min_by(group, fn b ->
          Map.get(rank, {b.scope_kind, scope_fk_for(b)}, 999)
        end)
      end)
      |> Enum.sort_by(fn b ->
        Map.get(rank, {b.scope_kind, scope_fk_for(b)})
      end, :desc)  # most-general first; most-specific last

    {:error, _} ->
      []
  end
end

defp scope_fk_for(%{scope_kind: :session, session_id: id}), do: id
defp scope_fk_for(%{scope_kind: :project, project_id: id}), do: id
defp scope_fk_for(%{scope_kind: :workspace, workspace_id: id}), do: id
defp scope_fk_for(%{scope_kind: :user, user_id: id}), do: id
```

#### 1d. Acceptance test

The frozen artifact is the **persisted string** in
`session.metadata["prompt_snapshot"]`. Two distinct properties:
1. **Persisted-snapshot immutability across reads.** Set a known
   string, write a Block, reload, assert byte-stable.
2. **New-session refresh.** Write a Block, resolve a fresh session
   (different `external_id`), assert the snapshot includes the new
   Block content.

Test in `test/jido_claw/agent/prompt_snapshot_test.exs`.

### 2. Forge runner extensions

#### 2a. `ClaudeCode` runner

**Modify** `lib/jido_claw/forge/runners/claude_code.ex`:
1. **`init/2`** — pull `max_turns`, `timeout_ms`, `mcp_config_path`,
   `thinking_effort` from config; stash in state.
2. **`run_iteration/3`**:
   - `--max-turns` from `state.max_turns || 200`.
   - When `state.mcp_config_path` is set, append
     `["--mcp-config", state.mcp_config_path]`.
   - When `state.thinking_effort` is set, append the corresponding
     CLI flag (verify spelling against the local install).
   - `run_opts` timeout: `timeout: state.timeout_ms || 300_000`.
   - **Classify timeout in the `Sandbox.run` case** (not in
     `parse_output/1`, which only sees output text):
     ```elixir
     case Sandbox.run(client, "claude", args, run_opts) do
       {output, 0} -> parse_output(output)
       {output, :timeout} -> {:ok, Runner.error("harness_timeout", output)}
       {output, _code} -> {:ok, Runner.error("claude cli failed", output)}
     end
     ```
3. **`parse_output/1`** — full pass: decode every JSON line,
   accumulate `tool_use`/`tool_result`/`assistant`/`system` (preserve
   order), capture the final `result` line. Return existing
   `Runner.done/continue` shape merged with
   `%{metadata: %{tool_events: events}}`.

#### 2b. `Forge.Harness` call timeout wiring

`harness.ex:62, 74` hardcode `300_000` ms. Add explicit timeout:
```elixir
defp call(session_id, msg, timeout \\ 300_000) do
  ...
  GenServer.call(pid, msg, timeout)
  ...
end
```
Update `apply_input/2`, `status/1`, `attach_sandbox/3`,
`detach_sandbox/2`. Consolidator passes
`timeout: harness_options.timeout_ms`.

#### 2c. `Fake` runner (speaks MCP JSON-RPC)

**Create** `lib/jido_claw/forge/runners/fake.ex`. Critically, it must
exercise the same MCP client path the real ClaudeCode CLI uses, so
the consolidator's MCP server, plug, registry lookup, and tool
dispatch are all covered by tests:

- `@behaviour JidoClaw.Forge.Runner`.
- `init/2` reads `runner_config[:fake_proposals]` (a list of
  `{tool_name, args}` tuples) and the `runner_config[:mcp_config_path]`
  (the temp JSON the consolidator wrote).
- `run_iteration/3`:
  - Read the JSON, extract the `consolidator` server URL.
  - Open an MCP HTTP/SSE client session against that URL: send a
    JSON-RPC `initialize` request with the standard MCP protocol
    handshake; await the response carrying the session id.
  - For each `{tool_name, args}` in `fake_proposals`, send
    `tools/call` with `{"name": tool_name, "arguments": args}` and
    the `mcp-session-id` header.
  - Send `tools/call` for `commit_proposals` last.
  - Tear down the session (DELETE on the URL or just close).
  - Return `{:ok, Runner.done("fake-completed")}`.

This way the Fake exercises Anubis's plug, the run_id assign
propagation, the registry lookup in tool handlers, and the staging
buffer end-to-end. The implementer can keep this small (~120 LOC) by
using `:httpc` or `Req` and hand-constructing JSON-RPC envelopes; no
need for a full MCP-client library.

#### 2d. Harness clauses + capacity

**Modify** `lib/jido_claw/forge/harness.ex:1129-1135`:
- `resolve_runner/1` — `:fake -> JidoClaw.Forge.Runners.Fake`.
- `resolve_client/1` — `:local -> JidoClaw.Forge.Sandbox.Local`.

**Modify** `lib/jido_claw/forge/manager.ex:15` — capacity entry
`fake: 10` (update **both** the defstruct default and any hardcoded
`Keyword.get(opts, :max_per_runner, ...)` default).

Document `:local` and `:fake` in
`lib/jido_claw/forge/resources/session.ex` moduledoc.

### 3. Per-session scoped MCP server (§3.15 step 4)

#### 3a. Anubis server supervisor at app boot

**Modify** `lib/jido_claw/application.ex` — add to `core_children/0`:

```elixir
{JidoClaw.Memory.Consolidator.MCPServer,
 [transport: {:streamable_http, [start: true]}]}
```

`start: true` lives **inside the transport tuple** —
`Anubis.Server.Supervisor.should_start?/1` reads
`transport_opts[:start]`; a top-level `[start: true]` is silently
ignored.

#### 3b. `MCPServer` module + tools

**Create** `lib/jido_claw/memory/consolidator/mcp_server.ex`:
```elixir
defmodule JidoClaw.Memory.Consolidator.MCPServer do
  use Jido.MCP.Server,
    name: "memory_consolidator",
    version: "0.6.0",
    publish: %{tools: [
      JidoClaw.Memory.Consolidator.Tools.ListClusters,
      JidoClaw.Memory.Consolidator.Tools.GetCluster,
      JidoClaw.Memory.Consolidator.Tools.GetActiveBlocks,
      JidoClaw.Memory.Consolidator.Tools.FindSimilarFacts,
      JidoClaw.Memory.Consolidator.Tools.ProposeAdd,
      JidoClaw.Memory.Consolidator.Tools.ProposeUpdate,
      JidoClaw.Memory.Consolidator.Tools.ProposeDelete,
      JidoClaw.Memory.Consolidator.Tools.ProposeBlockUpdate,
      JidoClaw.Memory.Consolidator.Tools.ProposeLink,
      JidoClaw.Memory.Consolidator.Tools.DeferCluster,
      JidoClaw.Memory.Consolidator.Tools.CommitProposals
    ]}
end
```

**Create** the eleven tool modules (`Jido.Action`):
```elixir
defmodule JidoClaw.Memory.Consolidator.Tools.ProposeAdd do
  use Jido.Action,
    name: "propose_add",
    description: "Stage a new Fact for this run.",
    schema: [
      content: [type: :string, required: true],
      tags: [type: {:list, :string}, default: []],
      label: [type: :string, default: nil]
    ]

  @impl true
  def run(args, ctx) do
    run_id = ctx.assigns[:consolidator_run_id]

    case Registry.lookup(JidoClaw.Memory.Consolidator.RunRegistry, run_id) do
      [{pid, _}] -> GenServer.call(pid, {:propose_add, args})
      [] -> {:error, "no active run for #{inspect(run_id)}"}
    end
  end
end
```

**Structured "soft" errors.** `Jido.MCP.Server.Runtime.handle_tool_call/5`
turns `{:error, reason}` into `Response.error(inspect(reason))` —
the model receives a stringified blob. For a tool that needs the
model to *parse* the error and retry intelligently (e.g.,
`propose_block_update` exceeding `char_limit`), return a structured
**successful** tool result with an `ok: false` discriminator instead:

```elixir
def run(%{label: label, new_content: content} = args, ctx) do
  ...
  case GenServer.call(pid, {:propose_block_update, args}) do
    :ok -> {:ok, %{ok: true}}
    {:char_limit_exceeded, current_value, char_limit} ->
      {:ok, %{
        ok: false,
        error: "char_limit_exceeded",
        char_limit: char_limit,
        current_value: current_value
      }}
  end
end
```

The model sees structured JSON it can parse for `ok: false` and the
overflow details; the underlying staging buffer is what enforces the
char limit and returns the structured info.

#### 3c. Per-run Bandit endpoint + run_id propagation

**Create** `lib/jido_claw/memory/consolidator/run_registry.ex`:
`{Registry, keys: :unique, name: JidoClaw.Memory.Consolidator.RunRegistry}`.

**Create** `lib/jido_claw/memory/consolidator/plug.ex`:
```elixir
defmodule JidoClaw.Memory.Consolidator.Plug do
  use Plug.Router
  plug :match
  plug :dispatch

  forward "/run/:run_id",
    to: __MODULE__.RunForward,
    init_opts: [server: JidoClaw.Memory.Consolidator.MCPServer]
end

defmodule JidoClaw.Memory.Consolidator.Plug.RunForward do
  @behaviour Plug
  alias Anubis.Server.Transport.StreamableHTTP.Plug, as: AnubisPlug

  def init(opts), do: AnubisPlug.init(opts)

  def call(conn, opts) do
    run_id = conn.path_params["run_id"]
    conn = Plug.Conn.assign(conn, :consolidator_run_id, run_id)
    AnubisPlug.call(conn, opts)
  end
end
```

**Create** `lib/jido_claw/memory/consolidator/mcp_endpoint.ex`:
- `start_link(run_id)` — `Bandit.start_link(plug: {Plug, []}, port: 0,
  ip: {127,0,0,1})`.
- `ThousandIsland.listener_info(pid)` for `{ip, port}`.
- `stop(state)` — `ThousandIsland.stop(state.pid)`.

### 4. Cron `:system_job` mode + `start_system_jobs/0`

#### 4a. `:system_job` worker mode

**Modify** `lib/jido_claw/platform/cron/worker.ex`:
- `defstruct` (line 12) — add `:mfa`.
- `init/1` (line 50) — `mfa: Keyword.get(opts, :mfa)`.
- `execute_job/1` (line 114) — third clause:
  ```elixir
  :system_job ->
    {m, f, a} = state.mfa
    apply(m, f, a)
  ```
- **Don't** add `parse_mode("system_job")` in `scheduler.ex:67-68`.

#### 4b. System-tenant bootstrap — prefer Option A

**Option A (preferred):** ensure a `"system"` tenant in
`Tenant.Manager` / `InstanceSupervisor` once at boot. The implementer
should look in `lib/jido_claw/platform/tenant/` for an existing
public ensure-tenant entry point and call it for `"system"`. If no
such entry point exists, add a small one — it's a tiny piece of
existing infrastructure to extend.

Reason for preferring Option A: acceptance gate 10 expects
`Cron.Scheduler.list_jobs("system")` to surface the consolidator job
naturally. With Option A, `list_jobs/1` works unchanged. With
Option B (separate `SystemJobsSupervisor`), `list_jobs/1` would need
to be extended to also walk system-job storage, and the gate would
need to be reworded. Skip the cascading API churn.

If Option A turns out to require unreasonable Tenant changes during
impl, fall back to Option B and update gate 10 to read
`SystemJobsSupervisor.list_jobs/0`.

#### 4c. `start_system_jobs/0` and the boot hook

**Modify** `lib/jido_claw/platform/cron/scheduler.ex`:
```elixir
def start_system_jobs do
  config = Application.fetch_env!(:jido_claw, JidoClaw.Memory.Consolidator)

  if config[:enabled] do
    schedule("system",
      id: "memory_consolidator",
      task: "consolidate",
      schedule: parse_schedule(config[:cadence]),
      mode: :system_job,
      mfa: {JidoClaw.Memory.Consolidator, :tick, []}
    )
  end
end
```

**Modify** `lib/jido_claw/application.ex`:
- Add `RunRegistry` early.
- Add `JidoClaw.Memory.Consolidator.TaskSupervisor` (a
  `Task.Supervisor`).
- Add MCPServer per §3a.
- Transient initializer: ensure `"system"` tenant; call
  `Cron.Scheduler.start_system_jobs/0`. Mirror
  `JidoClaw.MCPScope.Initializer` at `application.ex:257-262`.

### 5. `JidoClaw.Memory.Consolidator` — the core (§3.15)

**Architecture:**
- `Consolidator` (façade) — `tick/0`, `run_now/2`.
- `RunServer` (GenServer per run, idle until `:await_and_start` call).
- `LockOwner` (Task per run).
- A worker Task spawned by RunServer drives Forge.
- MCP tool handlers `GenServer.call(RunServer, {:propose_*, ...})`.

#### 5a. Façade and `run_now/2` semantics

```elixir
def run_now(scope_or_opts, opts \\ []) do
  with {:ok, scope} <- normalize_scope(scope_or_opts),
       {:ok, pid}   <- start_run_server(scope) do
    timeout = Keyword.get(opts, :await_ms, default_await_timeout())
    GenServer.call(pid, {:await_and_start, opts}, timeout)
    # → {:ok, run} | {:error, error_string}
  end
end

defp normalize_scope(%{scope_kind: _} = scope), do: {:ok, scope}
defp normalize_scope(opts) when is_map(opts) or is_list(opts),
  do: JidoClaw.Memory.Scope.resolve(Map.new(opts))
```

`run_now/2` accepts both:
- An already-resolved scope record (CLI path via `memory_scope/1`).
- Tool-context-shaped opts (test/programmatic callers).

Result:
- `{:ok, %ConsolidationRun{status: :succeeded}}` — published.
- `{:error, error_string}` — `:skipped` and `:failed` paths. The
  `ConsolidationRun` row is still written when
  `write_skip_rows: true` (operator visibility); the API just
  surfaces the failure.

#### 5b. RunServer — race-free await-start handshake

`handle_continue` runs *before* mailbox processing, so it does NOT
fix the await race — `run_now/2` can't enqueue `:await` before
`{:continue, :gate}` fires from `init/1`. Correct fix: start the
RunServer **idle**. `run_now/2` issues a single `:await_and_start`
call that both registers the awaiter and triggers the first work
message.

```elixir
defmodule JidoClaw.Memory.Consolidator.RunServer do
  use GenServer

  def start_link(scope) do
    run_id = Ecto.UUID.generate()
    name = {:via, Registry, {JidoClaw.Memory.Consolidator.RunRegistry, run_id}}
    GenServer.start_link(__MODULE__, {run_id, scope}, name: name)
  end

  @impl true
  def init({run_id, scope}) do
    # Trap exits so `terminate/2` runs on `GenServer.stop/3` (used in
    # acceptance gate 7) and so the linked LockOwner Task's exit is
    # delivered as `{:EXIT, pid, reason}` we can handle gracefully
    # rather than cascading-crash through the run.
    Process.flag(:trap_exit, true)

    {:ok, %{
       run_id: run_id,
       scope: scope,
       opts: [],
       lock_owner_pid: nil,
       mcp_endpoint: nil,
       temp_file_path: nil,
       forge_session_id: nil,
       harness_task_ref: nil,
       staging: Staging.new(),
       status: :idle,
       result: nil,
       awaiters: []
     }}
  end

  @impl true
  def handle_call({:await_and_start, opts}, from, %{status: :idle} = state) do
    send(self(), :gate)
    {:noreply, %{state |
                 status: :running,
                 opts: opts,
                 awaiters: [from]}}
  end

  def handle_call({:await_and_start, _opts}, from, %{status: :terminal} = state) do
    {:reply, state.result, state, {:continue, :stop}}
  end

  def handle_call({:await_and_start, _opts}, from, state) do
    # Already running (multiple await_and_start callers): queue the awaiter.
    {:noreply, %{state | awaiters: [from | state.awaiters]}}
  end

  def handle_call({:propose_add, args}, _from, state) do
    {staged, staging} = Staging.add(state.staging, :fact_add, args)
    {:reply, staged, %{state | staging: staging}}
  end

  # ... other propose_* clauses ...

  def handle_call(:commit_proposals, _from, state) do
    send(self(), :publish)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:gate, state) do
    case PolicyResolver.gate(state.scope) do
      :ok -> {:noreply, state, {:continue, :acquire_lock}}
      {:skip, reason} -> finalise(state, :skipped, reason)
    end
  end

  def handle_info({:harness_result, result}, state) do
    # process result, then publish
    send(self(), :publish)
    {:noreply, %{state | harness_task: nil, harness_result: result}}
  end

  def handle_info(:publish, state) do
    # step-7 transactional publish; finalise/3 with :succeeded or :failed.
    ...
  end

  def handle_continue(:acquire_lock, state), do: ...
  def handle_continue(:load_inputs, state),  do: ...
  def handle_continue(:cluster, state),       do: ...
  def handle_continue(:invoke_harness, state),do: ...
  def handle_continue(:stop, state),          do: {:stop, :normal, state}

  defp finalise(state, status, error_string) do
    run_or_nil = maybe_write_run_row(state, status, error_string)

    reply =
      case {status, run_or_nil} do
        {:succeeded, {:ok, run}} -> {:ok, run}
        _ -> {:error, error_string}
      end

    # Cleanup *before* replying so the lock, MCP endpoint, and temp
    # file are gone before the awaiter — and lifecycle tests — can
    # observe the result. This blocks the GenServer briefly at
    # terminal time, which is fine since no further work can happen.
    cleanup(state)

    Enum.each(state.awaiters, &GenServer.reply(&1, reply))

    {:stop, :normal,
     %{state | status: :terminal, result: reply, awaiters: []}}
  end

  defp maybe_write_run_row(state, :skipped, reason) do
    if write_skip_rows?(), do: write_run_row(state, :skipped, reason), else: nil
  end

  defp maybe_write_run_row(state, status, error_or_nil) do
    write_run_row(state, status, error_or_nil)
  end

  defp cleanup(state) do
    if state.lock_owner_pid, do: LockOwner.release(state.lock_owner_pid)
    if state.mcp_endpoint, do: MCPEndpoint.stop(state.mcp_endpoint)
    if state.temp_file_path, do: File.rm(state.temp_file_path)
    :ok
  end
end
```

Key invariants:
- `init/1` returns immediately with `status: :idle` and **no work
  triggered**. The pid is registered, `start_link` returns.
- `run_now/2` issues exactly one `{:await_and_start, opts}` call. The
  RunServer registers the awaiter and `send(self(), :gate)`s the
  first work message before replying.
- `:gate`, `:acquire_lock`, etc. flow through `handle_continue`/`handle_info`
  asynchronously; the RunServer remains responsive to MCP tool
  `GenServer.call`s throughout.
- Late awaiters (post-`:terminal`) get the cached `state.result`.
- All callbacks are non-blocking. Harness runs in a spawned Task.

#### 5c. RunServer flow detail (§3.15 steps -1 → 7)

- **`:gate`** → `PolicyResolver.gate(scope)`.
- **`:acquire_lock`** →
  ```elixir
  key = Memory.Scope.lock_key(state.scope.tenant_id,
                              state.scope.scope_kind,
                              Memory.Scope.primary_fk(state.scope))
  case LockOwner.acquire(key) do
    {:ok, pid} -> ...
    :busy -> finalise(state, :skipped, "scope_busy")
    {:error, reason} -> finalise(state, :failed, to_string(reason))
  end
  ```
- **`:load_inputs`** — read latest run via
  `ConsolidationRun.latest_for_scope(...)` (consult resource for
  arity), composite watermarks, message + fact load (Prep B's
  `:sources` argument), `min_input_count` pre-flight.
- **`:cluster`** — `Clusterer.cluster(...)`.
- **`:invoke_harness`** —
  - `MCPEndpoint.start_link(state.run_id) → %{pid:, port:}`.
  - Write temp config JSON.
  - `forge_session_id = Ecto.UUID.generate()`.
  - Spawn the Forge-driving work via
    `Task.Supervisor.async_nolink(JidoClaw.Memory.Consolidator.TaskSupervisor, ...)`
    and stash the returned `Task` ref in
    `state.harness_task_ref`. **Don't link.** A linked Task crash
    would cascade into the RunServer before it can write the
    `:failed` row.
  - The Task: calls
    `Forge.Manager.start_session(forge_session_id, spec)` then
    `Harness.run_iteration(forge_session_id, [..., timeout: timeout_ms])`
    and returns the result.
  - Handle the Task lifecycle in `RunServer`:
    - `handle_info({ref, result}, %{harness_task_ref: %Task{ref: ref}} = state)` —
      normal completion; `Process.demonitor(ref, [:flush])`; send
      self `:publish` carrying `result`.
    - `handle_info({:DOWN, ref, :process, _, reason}, %{harness_task_ref: %Task{ref: ref}} = state)` —
      Task crashed; `finalise(state, :failed, "harness_error")`
      (use the reason to enrich telemetry but keep the
      `error` column to one of the documented strings).
- **`:publish`** — validate, compute contiguous-prefix watermarks,
  `Repo.transaction/1` (Block revisions only via `Block.revise/2`),
  `ConsolidationRun.record_run/1`. Reply via `finalise/3`.
- **`:cleanup`** — `LockOwner.release/1`, stop MCPEndpoint, unlink
  temp file, normal stop.

Failure handling: any pre-publish error → `finalise(state, :failed,
"harness_timeout" | "harness_nonzero_exit" | "max_turns_reached" |
"harness_error" | "no_credentials" | "no_runner_configured")`.
`forge_session_id` populated even on failure.

#### 5d. Codex guard — placed inside the run path

`Harness.resolve_runner/1` treats unknown atoms as module names, so
`harness: :codex` would naively try to load a `Codex` module. The
guard **must run inside the per-scope RunServer's flow** — placing it
earlier (in `tick/0` or `run_now/2`) would prevent the per-scope
`ConsolidationRun` row from being written, breaking the "every tick
records a row" guarantee.

Placement: in `RunServer`'s `:invoke_harness` handler, before
spawning the Forge session:
```elixir
case resolved_harness() do
  {:ok, harness} -> spawn_harness_task(state, harness)
  {:error, reason} -> finalise(state, :failed, reason)
end

defp resolved_harness do
  case Application.get_env(:jido_claw, JidoClaw.Memory.Consolidator)[:harness] do
    :claude_code -> {:ok, :claude_code}
    :fake -> {:ok, :fake}
    :codex -> {:error, "no_runner_configured"}
    other -> {:error, "unknown_harness:#{other}"}
  end
end
```

#### 5e. Candidate scope discovery for `tick/0`

Watermark-anchored. Per tenant, candidates = union of:
1. Sessions with messages newer than their last successful run's
   message watermark.
2. Workspace/user/project scopes with new
   `:model_remember`/`:user_save`/`:imported_legacy` facts newer than
   their fact watermark.

Dedup by `(tenant_id, scope_kind, primary_fk(scope))`. Cap at
`max_candidates_per_tick: 100`. Fan out via
`Task.Supervisor.async_stream_nolink(JidoClaw.Memory.Consolidator.TaskSupervisor,
candidates, &run_now(&1, async: true), max_concurrency:
max_concurrent_scopes, on_timeout: :kill_task)`.

`PolicyResolver.gate/1` filters opted-out scopes inside each
RunServer.

**Project-scope policy:** A project may be referenced by multiple
workspaces in the same tenant. `PolicyResolver` returns the
**most-restrictive** policy across all workspaces in the tenant that
reference this project (same MIN-aggregate shape as user-scope, with
`project_id` as the filter column). No referencing workspaces →
`:disabled` (default-deny).

### 6. Workspaces helper for most-restrictive policy

**Modify** `lib/jido_claw/workspaces/policy_transitions.ex`:

```elixir
def resolve_consolidation_policy_for_user(tenant_id, user_id),
  do: aggregate_policy(:user_id, tenant_id, user_id)

def resolve_consolidation_policy_for_project(tenant_id, project_id),
  do: aggregate_policy(:project_id, tenant_id, project_id)

# Pattern-matched private clauses keep the SQL column name closed
# under a known set — the SQL string is built from a literal in the
# clause body, never from the call-site atom.
defp aggregate_policy(:user_id, tenant_id, fk_id),
  do: run_aggregate("user_id", tenant_id, fk_id)

defp aggregate_policy(:project_id, tenant_id, fk_id),
  do: run_aggregate("project_id", tenant_id, fk_id)

defp run_aggregate(column, tenant_id, fk_id)
     when column in ["user_id", "project_id"] do
  table = AshPostgres.DataLayer.Info.table(JidoClaw.Workspaces.Workspace)

  {:ok, %{rows: [[result]]}} =
    Ecto.Adapters.SQL.query(JidoClaw.Repo, """
    SELECT MIN(CASE consolidation_policy
                  WHEN 'disabled' THEN 0
                  WHEN 'local_only' THEN 1
                  WHEN 'default' THEN 2
                END)
    FROM #{table}
    WHERE tenant_id = $1 AND #{column} = $2
    """, [tenant_id, fk_id])

  decode_policy(result)
end

defp decode_policy(nil), do: :disabled
defp decode_policy(0), do: :disabled
defp decode_policy(1), do: :local_only
defp decode_policy(2), do: :default
```

(Ash-native version with a `manage_relationship` aggregate is also
fine.)

### 7. Configuration

**Modify** `config/config.exs`:
```elixir
config :jido_claw, JidoClaw.Memory.Consolidator,
  enabled: false,
  cadence: "0 */6 * * *",
  min_input_count: 10,
  max_concurrent_scopes: 4,
  max_candidates_per_tick: 100,
  max_messages_per_run: 500,
  max_facts_per_run: 500,
  max_clusters_per_run: 20,
  harness: :claude_code,
  harness_options: [
    model: "claude-opus-4-7",
    thinking_effort: "xhigh",
    sandbox_mode: :local,
    timeout_ms: 600_000,
    max_turns: 60
  ],
  write_skip_rows: true
```

### 8. CLI commands

**Modify** `lib/jido_claw/cli/commands.ex` — between line 312 and 314,
case-on-`memory_scope/1`:

```elixir
def handle("/memory consolidate" <> _, state) do
  case memory_scope(state) do
    {:ok, scope} ->
      case JidoClaw.Memory.Consolidator.run_now(scope, override_min_input_count: true) do
        {:ok, run} -> render_run_summary(run)
        {:error, "scope_busy"} -> render_warning("consolidation already running for this scope")
        {:error, reason} -> render_error("consolidation failed: #{reason}")
      end

    {:error, reason} ->
      render_error("scope unresolved: #{inspect(reason)}")
  end
end

def handle("/memory status" <> _, state) do
  case memory_scope(state) do
    {:ok, scope} ->
      history = JidoClaw.Memory.ConsolidationRun.history_for_scope(...)
      render_history(history)

    {:error, reason} ->
      render_error("scope unresolved: #{inspect(reason)}")
  end
end
```

`history_for_scope` args: use the resource's actual interface arity
with `tenant_id`, `scope_kind`, `Memory.Scope.primary_fk(scope)`.

**Modify** `lib/jido_claw/cli/branding.ex:165-169` — help banner.

### 9. Telemetry

`:memory` namespace currently empty. Standard split:

- `[:jido_claw, :memory, :consolidator, :run]`
  - measurements (numeric):
    `%{duration_ms, harness_turns, messages_loaded, messages_published,
       facts_loaded, facts_published, blocks_written, blocks_revised,
       links_added}` plus `cost_usd_micros` (integer) **only when
    known** — omit the key when the runner can't surface usage.
  - metadata:
    `%{tenant_id, scope_kind, scope_fk_id, status, harness, model,
       run_id, forge_session_id}` (use
    `Memory.Scope.primary_fk(scope)` for `scope_fk_id`).
- `[:jido_claw, :memory, :consolidator, :skipped]`
  - measurements: `%{count: 1}`.
  - metadata: `%{tenant_id, scope_kind, scope_fk_id, reason}`.

## Files to create or modify

### Modify

| Path | Change |
|------|--------|
| `lib/jido_claw/memory/scope.ex` | Prep A (real 64-bit `lock_key`); Prep A.1 (`primary_fk/1`) |
| `lib/jido_claw/memory/resources/fact.ex` | Prep B — `:sources` argument |
| `lib/jido_claw/forge/sandbox/local.ex` | Prep C — `run/4` honors timeout, drops `sh -c`; `exec/3` untouched |
| `lib/jido_claw.ex` | reorder `chat/4`; thread `project_dir` |
| `lib/jido_claw/cli/repl.ex` | reorder REPL bootstrap |
| `lib/jido_claw/startup.ex` | `inject_system_prompt/3` taking session arg |
| `lib/jido_claw/agent/prompt.ex` | `build_snapshot/2` rewrite |
| `lib/jido_claw/memory.ex` | `list_blocks_for_scope_chain/1` (unwraps Ash result, rank-map dedup) |
| `lib/jido_claw/conversations/resources/session.ex` | `:set_prompt_snapshot` action + interface |
| `lib/jido_claw/conversations/resolver.ex` | persist snapshot when missing & non-cron; correct `scope_ctx` keys |
| `lib/jido_claw/forge/runners/claude_code.ex` | wire config, batch parse_output, `:timeout` classification in `run_iteration/3` |
| `lib/jido_claw/forge/harness.ex` | thread call timeout; `:fake`; `:local` |
| `lib/jido_claw/forge/manager.ex` | `fake: 10` capacity (both defaults) |
| `lib/jido_claw/forge/resources/session.ex` | document `spec.sandbox` aliases |
| `lib/jido_claw/platform/cron/worker.ex` | `:system_job` + `:mfa` |
| `lib/jido_claw/platform/cron/scheduler.ex` | `start_system_jobs/0` |
| `lib/jido_claw/application.ex` | `RunRegistry`, `TaskSupervisor`, MCPServer (transport-internal `start: true`), `"system"` tenant ensure, `start_system_jobs/0` initializer |
| `lib/jido_claw/cli/commands.ex` | `/memory consolidate` and `/memory status` |
| `lib/jido_claw/cli/branding.ex` | help banner |
| `lib/jido_claw/core/telemetry.ex` | `:memory` namespace events |
| `lib/jido_claw/workspaces/policy_transitions.ex` | `resolve_consolidation_policy_for_user/2`, `_for_project/2` |
| `config/config.exs` | `JidoClaw.Memory.Consolidator` block; consider Repo `pool_size:` bump |

### Create

| Path | Purpose |
|------|---------|
| `lib/jido_claw/forge/runners/fake.ex` | MCP-JSON-RPC test substrate |
| `lib/jido_claw/memory/consolidator.ex` | `tick/0`, `run_now/2` |
| `lib/jido_claw/memory/consolidator/run_server.ex` | per-run GenServer (idle until `:await_and_start`) |
| `lib/jido_claw/memory/consolidator/lock_owner.ex` | per-run lock-holding Task with timeout + already-dead cleanup |
| `lib/jido_claw/memory/consolidator/policy_resolver.ex` | egress gate (project + user aggregates) |
| `lib/jido_claw/memory/consolidator/clusterer.ex` | deterministic clustering |
| `lib/jido_claw/memory/consolidator/staging.ex` | staging buffer |
| `lib/jido_claw/memory/consolidator/run_registry.ex` | `Registry` |
| `lib/jido_claw/memory/consolidator/task_supervisor.ex` | `Task.Supervisor` |
| `lib/jido_claw/memory/consolidator/mcp_server.ex` | `use Jido.MCP.Server` |
| `lib/jido_claw/memory/consolidator/mcp_endpoint.ex` | per-run Bandit/ThousandIsland |
| `lib/jido_claw/memory/consolidator/plug.ex` | run_id-aware Plug.Router with explicit `init_opts:` |
| `lib/jido_claw/memory/consolidator/tools/*.ex` | eleven `Jido.Action` modules |

Tests under `test/jido_claw/memory/consolidator/`,
`test/jido_claw/agent/prompt_snapshot_test.exs`,
`test/jido_claw/cron/system_jobs_test.exs`,
`test/jido_claw/forge/runners/fake_test.exs`.

## Acceptance gates (§3.19 subset)

1. **Scheduled run produces measurable Block content.** `:fake`
   emits one `propose_block_update`; assert `Block` row.
2. **Frozen-snapshot prompt cache fires on Anthropic.** `cache_hits >
   0` after two turns same session. Real-API, env-gated.
3. **Opt-out egress gate.** `WS_off (:disabled)` writes
   `:skipped, "consolidation_disabled"`, `:fake` never invoked;
   `WS_on (:default)` `:succeeded`.
4. **User-scope most-restrictive.** Flip `WS_b`; assert before/after.
5. **Project-scope most-restrictive.** Two workspaces referencing
   same `project_id`; flip; assert before/after.
6. **Concurrency.** Two `run_now/2` same scope. One `:succeeded`,
   one `{:error, "scope_busy"}`.
7. **Crash recovery (graceful).** Use `GenServer.stop(run_server_pid,
   :shutdown, 10_000)` to drive a graceful shutdown — this triggers
   the normal `terminate/2` callback path. (`Process.exit/2` from an
   external process does *not* run `terminate/2` unless the target
   traps exits, which RunServer does. `GenServer.stop/3` is the
   intended API.) After stop, start a new run for the same scope;
   assert it acquires the lock cleanly. Brutal `Process.exit(pid, :kill)`
   is acceptable to leak the temp file in `/tmp`; see §10.
8. **`/memory consolidate` and `/memory status` functional.**
9. **Scoped MCP server lifecycle.** Bandit, temp file, registry
   entry exist mid-run; gone after graceful shutdown.
10. **`Cron.Scheduler.list_jobs("system")` includes
    `memory_consolidator` at boot.** (Option A path. If the
    implementer falls back to Option B, restate as
    `SystemJobsSupervisor.list_jobs/0`.)
11. **Persisted-snapshot immutability.** Read-stable across Block
    writes; new sessions post-write produce a fresh snapshot.
12. **Codex guard writes a row.** With `harness: :codex`, the run
    finalises as `:failed, "no_runner_configured"` — confirms the
    guard runs *inside* the per-scope flow.

## Verification (end-to-end)

1. `mix compile --warnings-as-errors`, `mix format --check-formatted`.
2. `mix test test/jido_claw/memory/consolidator/`,
   `test/jido_claw/agent/prompt_snapshot_test.exs`,
   `test/jido_claw/cron/system_jobs_test.exs`,
   `test/jido_claw/forge/runners/fake_test.exs`.
3. **Integration drive (REPL).** `mix jidoclaw`,
   `Application.put_env(...)` to enable, seed workspace + session +
   15 messages, `/memory consolidate`, inspect via Tidewave's
   `execute_sql_query`. Then `/memory status`.
4. **MCP lifecycle visual.**
   `lsof -i -P -nP | grep -E "127.0.0.1:[0-9]+ \(LISTEN\)"` during a
   run; gone after. `ls /tmp/consolidator-*.json` empty post-run.
5. **Telemetry handler test.** Attach to `:run` and `:skipped`,
   trigger one path of each, verify measurements/metadata.
6. **No regression on existing prompt path.**

## §10 Implementation-time notes

1. **Anubis Frame.assigns confirmed.** Tools read
   `ctx.assigns[:consolidator_run_id]`.
2. **Bandit bound-port via ThousandIsland.**
   `ThousandIsland.listener_info(pid)`,
   `ThousandIsland.stop(pid)` / `Supervisor.stop(pid)`.
3. **Claude Code thinking-effort flag spelling.** Empirical check.
4. **Repo pool sizing.** `max_concurrent_scopes` pinned connections
   for lock-owners — pool must have enough headroom. Bump
   `pool_size:` in `config/config.exs` if base sizing is tight.
5. **`Repo.checkout` pool isolation.** Validate during the
   lock-owner spike that holding a checkout in one process doesn't
   starve another process's queries against the pool. Failure mode
   → fall back to `consolidation_locks` DB-table strategy.
6. **Temp-file durability.** `Process.exit(pid, :kill)` skips
   `terminate/2` — `/tmp/consolidator-<run_id>.json` leaks on brutal
   kill. OS handles `/tmp` cleanup; out of scope for 3b. Document in
   the consolidator's moduledoc.
7. **Local sandbox argv migration.** Audit
   `lib/jido_claw/forge/` for `Sandbox.run/4` callers passing
   shell-style strings before Prep C lands. ClaudeCode runner
   already passes a clean argv. `Sandbox.exec/3` is unchanged.
8. **Tenant.Manager `ensure/1` shape.** Read
   `lib/jido_claw/platform/tenant/` to confirm Option A is viable; if
   the cost is high, fall back to Option B + restate gate 10.
