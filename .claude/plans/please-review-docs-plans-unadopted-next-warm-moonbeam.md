# Headless one-shot + CLI session resume (next-ten item #1)

## Context

Item #1 of `docs/plans/unadopted-next-ten/README.md` (osa **OS1-5**, with the **OQ-4**
exit-contract pin and the osa-claude-code **CC2-2** cache rider). Today every non-flag
arg to `mix jidoclaw` drops into the interactive REPL and every boot mints a fresh
`SessionId` — there is no scriptable entry point (CI, cron-from-shell, the future canary
rider all want one) and no way to resume a durable session. The substrate exists:
`JidoClaw.chat/4` is Display-free, sessions are durable, and the Session.Worker already
hydrates its chat view from Postgres. What's missing is the CLI plumbing, a most-recent
session query, and — the one genuinely net-new mechanism — **restoring the agent's LLM
context from persisted messages** (nothing seeds `Jido.AI.Context` from Postgres today,
so a "resumed" session would look resumed in the REPL while the model remembers nothing).

**Operator decisions (asked & answered):**
- Scope: item #1 only.
- Resume depth: **chat transcript only** — restore `:user`/`:assistant` rows with
  `refs.request_id` preserved; skip tool/reasoning/system rows.
- Composer diverts in one-shot mode: **await completion** (poll to terminal state with a
  timeout); gate-blocked → print case ids + exit 3.

**Exit contract (OQ-4, pinned):** `0` success · `1` error/failed-run/timeout ·
`2` usage/config error · `3` approval-gate pending.

Done means `mise exec -- mix precommit` passes. No commits — work stays unstaged;
"units" below are slicing guidance only.

---

## Verified seams (all re-checked against source this session)

| Seam | Where |
|---|---|
| Mix task arms (`--mcp`/`--setup`/catch-all→REPL) | `lib/mix/tasks/jidoclaw.ex` (new arms go before the catch-all) |
| Escript mirror | `lib/jido_claw/cli/main.ex` (`main/1` arms; boots via `Application.ensure_all_started`) |
| `JidoClaw.chat/4` — Display-free turn; returns `{:ok, binary} \| {:error, term}` | `lib/jido_claw.ex:82-133`; composer divert returns `{:ok, resp.message}` at `:281-297`; `resolve_agent_pid/1` at `:165-178`; inline `ask_sync` hardcoded `timeout: 120_000` at `:322` |
| Composer ack struct carries `parent_run_id` | `lib/jido_claw/front_door.ex:109` (`@type ack`), `:258` |
| `WorkflowRun` statuses `[:pending :running :awaiting_approval :completed :failed :cancelled :abandoned]`; `by_id` code interface | `lib/jido_claw/orchestration/workflow_run.ex:289-305`, `:97`; runs have `parent_run_id` |
| `RunPubSub.subscribe(run_id)` / `subscribe_gates/0` | `lib/jido_claw/orchestration/run_pubsub.ex:16,38` |
| `Visibility.run_view/3` (redact-safe status/error) | `lib/jido_claw/orchestration/visibility.ex:54` |
| `AgentCase.pending_for_session(session_id)`; `belongs_to :workflow_run` | `lib/jido_claw/orchestration/agent_case.ex:257-263`, `:372` |
| REPL boot: fresh mint at `session_id = SessionId.new()` | `lib/jido_claw/cli/repl.ex:201` inside `boot_repl_session/5` (`:200-264`); `ensure_persisted_session/3` (`:778`) keys `ensure_session(:repl, session_id)` |
| Model-alias setup the runner must replicate | `repl.ex:56-59` (`Application.put_env(:jido_ai, :model_aliases, %{fast: model, capable: model})`) |
| Prompt snapshot reuse (system-prefix byte-identity for free) | `lib/jido_claw/conversations/resolver.ex:90-93`; `Startup.resolve_prompt/2` (**currently private**, `startup.ex:242-247`) |
| LLM-context restore signal: `ai.react.context.modify`, op `%{type: :replace, reason: :restore, result_context: %Jido.AI.Context{}}`; applied immediately when no active run; `op_id` auto-generates | `deps/jido_ai/.../react/strategy.ex:891-908` (handler), `:1040-1110` (normalize); deliver like `Jido.AI.set_system_prompt` (`deps/jido_ai/lib/jido_ai.ex:399-409`): `Jido.AgentServer.call(pid, signal, timeout)` |
| **Restored context MUST carry the system prompt**: at ask time the strategy uses `context.system_prompt` with no config fallback; a `:replace` with `system_prompt: nil` silently drops the prompt | `strategy.ex` (`maybe_sync_config_prompt`, `runtime_state_from_context`) |
| Context builders accept `refs:` (compaction filter needs `refs.request_id`) | `deps/jido_ai/lib/jido_ai/context.ex:95-130` (`append_user/3`, `append_assistant/4`) |
| Prompt caching = tools array + system block only (messages not cached); tool wire order = `Map.values` (deterministic per key-set); native tool set static via `JidoClaw.Agent.tool_modules()` | `lib/jido_claw/agent/agent.ex:7-55`; `deps/req_llm/.../anthropic.ex:978-1062`; `deps/jido_ai/.../react/config.ex:202-206` |
| `redirect_logger_to_stderr/0` (public) | `lib/jido_claw/application.ex:608` |
| BootGuard raise (needs `VOYAGE_API_KEY`) | `JidoClaw.Embeddings.BootGuard.assert_voyage_key_or_raise!` at `application.ex:54` |
| `/gates`-style command pattern + test pattern | `lib/jido_claw/cli/commands.ex:610-622` + `commands/approvals.ex`; `test/jido_claw/cli/commands/approvals_test.exs` (TenantCase, capture_io) |
| chat/4 test seams | `:ask_runtime`, `:triage_impl` (TriageStub `canned(:talk)/(:code)`), `:front_door_composer` stub, `:recorder_flush_timeout` — see `test/jido_claw/front_door_test.exs:24-52` |

Key facts that shape the design:
- **Inline approval-pending is invisible in chat/4's return** — the gate error becomes a
  tool result the LLM relays as text (`{:ok, text}`). Detection must probe
  `AgentCase.pending_for_session/1`.
- **A composer parent stays `:running` while parked on a human gate** — the child wave
  run goes `:awaiting_approval` with the `AgentCase`. Await must probe the run *tree*.
- **Do not rely on broadcast for composer *parent* terminals** — the parent's terminal is
  written via `WorkflowLog.append` → projection, which does not broadcast (ordinary
  Reactor runs do broadcast completion). Polling `WorkflowRun.by_id` is the authoritative
  terminal detector; pubsub is an early-wake optimization only.
- Nothing ever calls `Session.close` on CLI sessions, so open-only listings show everything.
- `:api` is also the generic web/API surface kind (`chat_controller` uses `kind: :api`),
  so one-shot sessions need their own kind — `--continue` must never resume some web API
  caller's thread.

---

## Unit 1 — Foundations: `:cli_run` kind, two Ash reads, one index, shared prompt resolver

Consult the `ash-framework` skill. One generated migration (the index); the read actions
and the enum value need none.

1. `lib/jido_claw/conversations/resources/session.ex` — add **`:cli_run`** to the `kind`
   `one_of` constraint (one-shot sessions get their own kind; `:api` is the web surface).
   Update every public kind list: `chat/4`'s moduledoc, **`history/3`'s own kind list
   (`lib/jido_claw.ex:572`)**, and the **Conversations domain moduledoc
   (`lib/jido_claw/conversations/domain.ex:5`)**. Grep for kind-sensitive branching
   (`grep -rn "kind ==\|kind in\|:cron" lib/`) — known switch: `Conversations.Resolver`
   skips prompt snapshots only for `:cron`, so `:cli_run` gets snapshots (required for
   CC2-2).
2. Same file — new read action + code interface:
   ```elixir
   read :most_recent_for_workspace do
     get?(true)
     argument(:workspace_id, :uuid, allow_nil?: false)
     filter(expr(workspace_id == ^arg(:workspace_id) and kind in [:repl, :cli_run] and is_nil(closed_at)))
     prepare(build(sort: [last_active_at: :desc], limit: 1))
   end
   ```
   `--continue` = most recent *open* CLI session (REPL or one-shot — never a web `:api`
   thread); `--resume <uuid>` (existing `by_id`) resumes anything, closed included.
3. Same file — add custom index `[:workspace_id, :last_active_at]` (the sort runs under a
   `workspace_id` filter; existing indexes are `[:workspace_id, :started_at]` and
   `[:tenant_id, :last_active_at]`, neither matches). Generate the migration with
   `mise exec -- mix ash.codegen add_session_workspace_last_active_index` + `mix ash.setup`.
4. `lib/jido_claw/orchestration/agent_case.ex` — new read `pending_for_run_tree`:
   filter `(workflow_run_id == ^arg(:run_id) or workflow_run.parent_run_id == ^arg(:run_id)) and status == :pending`.
   If the relationship filter fights Ash policies/multitenancy, fall back to two-step
   (list child runs by `parent_run_id`, then pending per run) inside the runner.
5. `lib/jido_claw/startup.ex` — promote `resolve_prompt/2` to public (`@doc` + `@spec`)
   so `ContextRestore` and `inject_system_prompt` share one byte-source (CC2-2).

**Tests**: `test/jido_claw/conversations/session_most_recent_test.exs` (newest-open wins;
closed skipped; other workspace/tenant excluded; empty → not found),
`test/jido_claw/orchestration/agent_case_pending_for_run_tree_test.exs` (case on child
found from parent id; unrelated/decided cases excluded).

## Unit 2 — `ContextRestore` + generalized resume inside `chat/4`

**New** `lib/jido_claw/conversations/context_restore.ex`:
- Pure `build_context(rows, system_prompt) :: Jido.AI.Context.t()` — filter rows to
  `role in [:user, :assistant]`, fold via `Context.append_user/3` /
  `append_assistant/4` with `refs: %{request_id: row.request_id}` (keeps the
  Compactor's `RequestTransformer` filter working post-resume — snapshots in
  `Session.metadata["compactions"]` are re-read every ask, so compaction survives resume
  for free once refs are restored). `Context.new(system_prompt: system_prompt)` seed —
  **must carry the resolved snapshot bytes** (see seam table: nil would drop the prompt).
- `restore(pid, session, project_dir, opts) :: :ok | {:error, term}` — load
  `Message.for_session_primary(session.id, ...)`; no user/assistant rows → `:ok` no-op;
  else build context with `Startup.resolve_prompt(session, project_dir)` and deliver:
  `Jido.AgentServer.call(pid, Jido.Signal.new!("ai.react.context.modify", %{operation: %{type: :replace, reason: :restore, result_context: ctx}}, source: "/jido_claw/conversations/context_restore"), 15_000)`.

Wire into `lib/jido_claw.ex`:
- `resolve_agent_pid/1` → also report freshness (`{:ok, pid, fresh? :: boolean}`;
  `whereis`/`already_started`/`already_registered` ⇒ false).
- In `chat/4`'s `with`, **after** `inject_system_prompt`:
  `:ok <- maybe_restore_context(fresh?, agent_pid, session, project_dir, actor, opts)` —
  restore only for a fresh agent process (live pid ⇒ skip; no double-append), rows-empty
  no-op is defense in depth. Ordering: inject → restore → `run_chat_turn` (the current
  user message is appended at ask time, after restore).
- **Failure posture is opt-controlled**: new chat/4 opt `context_restore: :best_effort
  (default) | :strict`. Best-effort (background surfaces — cron, web): `Logger.warning`
  + proceed; logged, never silent. **Strict (explicit resume — the one-shot's
  `--session`/`--continue`)**: restore failure fails the turn with
  `{:error, {:context_restore_failed, reason}}` — a user who explicitly asked for
  history must never get a silent amnesic turn.
- Side effect worth noting in the moduledoc: cron `:main`-mode sessions become
  resume-safe across node restarts for free.

**Tests**: `test/jido_claw/conversations/context_restore_test.exs` (pure build: only
user/assistant survive in order, refs carried, system prompt carried; delivery captured
via the shared CapturingAgent — Unit 6; empty session sends no signal);
`test/jido_claw/chat_resume_test.exs` (TenantCase + `:ask_runtime` capture stub: turn 1
seeds rows, kill agent, turn 2 restores prior context; live-agent turn does not
re-restore; **strict mode**: a forced restore failure returns
`{:error, {:context_restore_failed, _}}` while best-effort proceeds).

## Unit 3 — `chat/4` composer-ack contract (structural run id)

`lib/jido_claw.ex`: new opt `composer_ack: :detailed` (default off ⇒ **byte-identical
current behavior** for cron/web/discord). When `:detailed`:
- inline → `{:ok, %{route: :inline, message: msg}}`
- composer launched → `{:ok, %{route: :composer, status: :launched, run_id: resp.parent_run_id, message: msg}}`
- composer failed-to-start → `{:ok, %{route: :composer, status: :failed_to_start, run_id: nil, message: msg}}`

Note `run_chat_turn`'s trailing `rescue`/`catch` (`lib/jido_claw.ex:302-307`) and its
`reach:disable-next-line bare_rescue` pragma — keep the wrap inside that boundary.

**Tests**: `test/jido_claw/chat_composer_ack_test.exs` — default opt returns plain
`{:ok, binary}` (regression pin for cron/web); `:detailed` + TriageStub `canned(:code)`
returns the run id of the created parent; `canned(:talk)` returns the inline shape.

## Unit 4 — One-shot runner: `mix jidoclaw run` + escript + await + exit codes

**New** `lib/jido_claw/cli/run_command.ex` (`JidoClaw.CLI.RunCommand`):
- **Pure core** `main(argv, opts \\ []) :: {exit_code :: 0..3, output :: String.t()}` —
  no `System.halt`, no direct printing; `opts[:boot]` injects the boot fn so mix task
  (`Mix.Task.run("app.start")`) and escript (`Application.ensure_all_started`) share it
  and tests stub it.
- Args (`OptionParser`, strict): `--format text|json` (default text), `--session <uuid>`,
  `--continue`, `--timeout <seconds>` (default **600**, composer await only — inline is
  bounded by chat/4's 120s). Positionals: first = prompt (required), optional second =
  existing project dir (default cwd); `--session`+`--continue` together, empty prompt,
  extra positionals → exit 2.
- Boot sequence: parse → `Setup.needed?(dir)` ⇒ exit 2 with "run `mix jidoclaw --setup`"
  (never the interactive wizard) → `Config.load(dir)` + **model-alias put_env**
  (mirror `repl.ex:56-59`) → put_env `:mode :cli`, `:skip_discord true`, `:project_dir`
  (leave `:serve_mode` nil so the external MCP Consumer + `ensure_attached` keep working)
  → `redirect_logger_to_stderr()` (stdout carries only the result) → boot fn in
  `try/rescue`; a BootGuard/boot raise ⇒ exit 2 with the message →
  `ensure_project_state` best-effort.
- Session resolution (runner-owned so it holds `session_uuid` for the gate probe):
  tenant `"default"`, `Actor.system/1`; `ensure_workspace(tenant, dir)`;
  `--session` ⇒ `Session.by_id` (not found ⇒ 2); `--continue` ⇒
  `Session.most_recent_for_workspace` (none ⇒ 2 — already scoped to the dir's
  workspace); fresh ⇒ `SessionId.new()` + kind **`:cli_run`** resolved up-front via
  `Conversations.Resolver.ensure_session`. **Carry the resolved session's own `kind` +
  `external_id` into chat/4** — `unique_external` includes kind, so hardcoding a kind
  for a resumed `:repl` session would mint a different row.
- **Workspace guard on `--session`**: chat/4 resolves persistence from the *directory's*
  workspace (`jido_claw.ex:139`), so a UUID from another workspace would mint/touch a
  different `(workspace, kind, external_id)` row and run tools in the wrong cwd. After
  `Session.by_id`, assert `session.workspace_id == ensure_workspace(tenant, dir).id`;
  on mismatch load `Workspace.by_id(session.workspace_id)` and exit **2** with
  "session belongs to workspace <workspace.path> — run from there (or pass that dir)".
  (Adopting the session's path as the effective dir isn't viable: `:project_dir` is read
  by supervision children at boot, before the DB is queryable.)
- Dispatch: `turn_started_at = DateTime.utc_now()`, then
  `JidoClaw.chat(tenant, external_id, prompt, kind:, external_id:, workspace_id: dir, actor:, composer_ack: :detailed, context_restore: restore_mode)`
  where `restore_mode` is `:strict` for `--session`/`--continue` (explicit resume must
  fail loud — `{:error, {:context_restore_failed, _}}` maps to exit 1 with a clear
  message) and `:best_effort` for fresh runs.
- Outcome → exit code:
  - inline `{:ok, %{route: :inline, message}}` → probe
    `AgentCase.pending_for_session(session_uuid)`; **any pending case ⇒ 3** (print case
    ids + `/gates approve <id>` guidance); none ⇒ **0**. Do NOT filter by
    `inserted_at >= turn_started_at` for the exit decision: `ToolApprovals` deliberately
    **reuses** an existing pending case for the same fingerprint without inserting or
    touching it (`tool_approvals.ex:173,196`), so a re-triggered gate would look stale
    and produce a false 0. Instead the envelope/output distinguishes them: each pending
    id carries `fresh: inserted_at >= turn_started_at`, and text output labels
    pre-existing ones ("pending since before this run"). A conservative 3 on a leftover
    pending is honest — the session has an undecided approval the operator must resolve.
  - composer `:launched` → **await** (below): `:completed` ⇒ 0; `:failed/:cancelled/:abandoned`
    ⇒ 1; gate pending ⇒ 3 (case ids); timeout ⇒ 1 ("run still in progress: <run_id>").
  - composer `:failed_to_start` ⇒ 1; `{:error, reason}` ⇒ 1.

**New** `lib/jido_claw/cli/run_await.ex` (`JidoClaw.CLI.RunAwait`):
`await(run_id, tenant, actor, timeout_ms)` → `{:done, status, run} | {:gate_pending, [case_id]} | :timeout`.
Poll loop (~500ms tick): `WorkflowRun.by_id(run_id)` terminal? → done;
`AgentCase.pending_for_run_tree(run_id)` non-empty? → gate_pending; deadline? → timeout;
else `receive after tick` — with `RunPubSub.subscribe(run_id)` for early wake only.
Polling is authoritative: composer *parent* terminals are written via the
`WorkflowLog.append` → projection path, which does not broadcast (ordinary Reactor runs
do broadcast completion — don't rely on that here). Terminal message/error for output
via `Visibility.run_view(run, :operator, now)`.

**`--format json`** (single `Jason.encode!` line; arbitrary error terms through
`JidoClaw.Core.JsonSafe.encode/1`):
```json
{"ok": true, "exit_code": 0, "route": "inline|composer",
 "outcome": "answered|launched_completed|failed|cancelled|abandoned|gate_pending|timeout|error|usage",
 "session_id": "<uuid>", "run_id": "<uuid|null>", "message": "...",
 "pending_cases": [{"id": "<agent_case_id>", "fresh": true}], "error": null}
```

**Entry points** (thin wrappers, both files): `lib/mix/tasks/jidoclaw.ex` — new
`def run(["run" | rest])` **before** the catch-all → `{code, out} = RunCommand.main(rest, boot: ...)`;
`IO.puts(out)`; `System.halt(code)`. Mirror `def main(["run" | rest])` in
`lib/jido_claw/cli/main.ex`. Update both moduledocs/usage strings.

**Tests**: `test/jido_claw/cli/run_command_test.exs` (TenantCase async:false, no-op
`:boot`, front-door seams): inline success with no pendings → 0 + JSON shape; seeded
fresh pending tool-call case → 3 with ids (`fresh: true`); **pre-existing pending
(inserted before turn start, the fingerprint-reuse class) → still 3**, labeled
`fresh: false`; composer completed/failed → 0/1; child-run gate → 3; `{:error,_}` → 1
(including `{:context_restore_failed,_}` on `--continue` → 1 with a
history-not-restored message); usage/bad-uuid → 2; **`--session` uuid from another
workspace → 2, naming the session's workspace path**; text vs json output.
`test/jido_claw/cli/run_await_test.exs`: drive `await/4` against seeded runs —
terminal, gate via run tree, tiny-timeout → `:timeout`.

## Unit 5 — REPL resume: `--resume <uuid>` / `--continue`

- Both entry files' catch-all arms: **parse options FIRST** with `OptionParser`
  (`strict: [resume: :string, continue: :boolean]`), then derive `project_dir` from the
  **remaining positionals only** — never feed raw argv to
  `Startup.resolve_project_dir_from_argv/1` (it takes the first non-flag arg and does not
  skip flag *values*, so `mix jidoclaw --resume <uuid> /path` would inspect the uuid as a
  dir candidate and ignore `/path`). Then `Repl.start(project_dir, resume: ..., continue: ...)`.
  Plain `mix jidoclaw [dir]` behavior unchanged. Keep `Repl.start/1` delegating to
  `start/2` (existing callers).
- `lib/jido_claw/cli/repl.ex` `boot_repl_session`: extract a testable
  `resolve_boot_session(tenant_id, project_dir, opts)` replacing the bare mint at `:201`:
  - `resume: uuid` → `Session.by_id`; found **and belonging to this dir's workspace**
    (`session.workspace_id == ensure_workspace(tenant, project_dir).id`) ⇒
    `{session.external_id, record}`; missing ⇒ warn + fresh mint; **workspace mismatch**
    ⇒ prominent warning ("session <uuid> belongs to <workspace.path> — starting a FRESH
    session here; cd there to resume it") + fresh mint (interactive surface: stay usable,
    but never silently run a session against the wrong cwd).
  - `continue: true` → resolve workspace + `most_recent_for_workspace` (inherently
    workspace-scoped); none ⇒ warn + fresh.
  - else today's `SessionId.new()`.
  - **Resumed record bypasses `ensure_persisted_session`'s create** (its kind may be
    `:api`; re-ensuring with `:repl` would mint a new row): use the resolved record +
    `Session.touch`, resolve workspace for the uuid; fresh path keeps today's flow.
- After `inject_system_prompt_with_warning` (`:223`): call `ContextRestore.restore(pid,
  session_record, project_dir, ...)`; print "Resumed session <uuid> — N prior messages".
  On restore error print a **prominent** boot warning ("⚠ history NOT restored — the
  model will not remember prior turns: <reason>") — interactive users see it and can
  decide; don't abort the REPL. `maybe_set_worker_session_uuid` (`:218`) already hydrates
  the worker's chat view.

**Tests**: `test/jido_claw/cli/repl_resume_test.exs` — the extracted resolver only
(REPL loop is IO-bound): resume-by-uuid returns the row's external_id; unknown uuid,
**cross-workspace uuid** (falls back with the workspace-path warning), and empty
workspace all fall back to fresh; continue picks most recent.

## Unit 6 — `/sessions` command + shared CapturingAgent

- **New** `lib/jido_claw/cli/commands/sessions.ex` (mirror `commands/approvals.ex`):
  `list(state)` needs the tenant/workspace scope — `session_scope/1` is currently `defp`
  inside `JidoClaw.CLI.Commands` (`commands.ex:899`), so **promote it to a public
  `@doc false` + `@spec` function** and call `Commands.session_scope(state)` from the new
  module (mutual module references are fine; if anything objects, duplicate the tiny
  check locally instead). Then `Session.active_for_workspace` sorted `last_active_at`
  desc in-memory, **split into two groups so the display matches `--continue`'s actual
  selection set**: "CLI resumable" (`kind in [:repl, :cli_run]`, newest first — the top
  row IS what `--continue` picks) and "Other sessions — resume by UUID only" (all other
  kinds). Print `<uuid>  <kind>  <last_active>` rows + footer
  `Resume: mix jidoclaw --resume <uuid> · --continue for most recent`; degraded scope →
  notice. Returns `{:ok, state}`.
- `lib/jido_claw/cli/commands.ex`: alias + `handle("/sessions", state)` clause **before**
  the `handle("/" <> unknown, ...)` catch-all (`:889`); add to `/help`.
- Promote the `CapturingAgent` from `test/jido_claw/startup_test.exs:11-31` into
  `test/support/jido_claw/capturing_agent.ex`, adding a `"ai.react.context.modify"`
  capture clause (used by Units 2 and 7). Watch the precommit gotchas for test/support
  (specs, AliasUsage).

**Tests**: `test/jido_claw/cli/commands/sessions_test.exs` (approvals_test pattern):
seeded `:repl` + `:cli_run` + `:api` sessions — CLI-resumable group prints newest-first
with the resume hint, the `:api` row lands in the "resume by UUID only" group; degraded
state doesn't crash.

## Unit 7 — CC2-2 prefix-identity tests

Cached prefix = tools array + system block (messages not cached). Two halves:

- **System half** — `test/jido_claw/conversations/context_restore_prefix_test.exs`:
  (a) pure: `Startup.resolve_prompt/2` returns byte-identical strings for the saved vs
  reloaded session row (snapshot reuse), and `build_context/2` carries those exact bytes;
  (b) e2e: CapturingAgent captures the injected prompt on fresh boot (P1) and on resume
  (P2) plus the restore payload's `result_context.system_prompt` (C2); assert
  `P1 == P2 == C2` byte-for-byte.
- **Tools half** — `test/jido_claw/agent/tool_prefix_identity_test.exs`. **Scope the
  claim honestly**: this pins the *native/no-MCP* tool prefix plus resume-neutrality; MCP
  attach can still extend the tool map mid-session by design (pre-existing behavior,
  independent of resume — note it, don't overclaim). Assertions:
  (a) wire-order determinism **on the real wire artifact**: build a ReAct `Config` from
  `JidoClaw.Agent.tool_modules()` twice (the same normalize path the strategy uses) and
  assert `Jido.AI.Reasoning.ReAct.Config.reqllm_tools/1` yields the identical ordered
  tool list both times (note the wire path is unsorted `Map.values`, config.ex:202 — the
  sorted `fingerprint/1` at config.ex:177 is NOT the wire order, don't test that instead);
  (b) resume is tool-neutral: drive inject + restore against CapturingAgent and assert
  **no** `ai.react.register_tool`/`unregister_tool` signals — resume can't shift the
  last-tool cache breakpoint (the exact `deferred_tools_delta` regression class).

## Unit 8 — Doc reconciliation (prose only)

- `docs/exploration/osa/FEATURES-WORTH-BORROWING.md` **OS1-5** (~line 97): dated
  `> Done 2026-07-02` blockquote — landed as `mix jidoclaw run` + `--resume/--continue` +
  `/sessions`; correct falsified claims (entry says `chat/3` — shipped on `chat/4` with
  `composer_ack: :detailed`; resume also had to carry the session's `kind` through
  `unique_external`; the "Worker already hydrates" claim was view-only — LLM-context
  restore was net-new). Answer **OQ-4** inline (~line 232): exit contract 0/1/2/3, inline
  gates probed via `pending_for_session` (invisible in the return), composer gates via
  `pending_for_run_tree` (parent stays `:running`).
- `docs/exploration/osa-claude-code/FEATURES-WORTH-BORROWING.md` **CC2-2** (~line 125):
  `> Status: landed 2026-07-02 with OS1-5` — our prefix = system + tools; identity via
  snapshot reuse carried into the restored context + deterministic wire order; both
  halves tested. **Scope the claim honestly**: byte-identity is proven for the
  native/no-MCP tool set plus resume-neutrality; mid-session MCP attach can still move
  the tools breakpoint (pre-existing, independent of resume).
- `docs/plans/unadopted-next-ten/README.md`: mark row #1 done in the table + `> Done`
  blockquote with the same corrections (mirror `unadopted-next-five/README.md:41-50`
  habit); note resume was generalized into `chat/4` for all surfaces, and that one-shot
  sessions got their own `:cli_run` kind so `--continue` can't resume a web `:api` thread.

---

## Verification

```bash
# Per-unit suites while iterating
mise exec -- mix test test/jido_claw/conversations/session_most_recent_test.exs \
  test/jido_claw/orchestration/agent_case_pending_for_run_tree_test.exs
mise exec -- mix test test/jido_claw/conversations/context_restore_test.exs \
  test/jido_claw/chat_resume_test.exs test/jido_claw/chat_composer_ack_test.exs
mise exec -- mix test test/jido_claw/cli/run_command_test.exs \
  test/jido_claw/cli/run_await_test.exs test/jido_claw/cli/repl_resume_test.exs \
  test/jido_claw/cli/commands/sessions_test.exs
mise exec -- mix test test/jido_claw/conversations/context_restore_prefix_test.exs \
  test/jido_claw/agent/tool_prefix_identity_test.exs

# Definition of done — run bare (no pipes; pipes mask the exit code), in background,
# read the output tail:
mise exec -- mix precommit
```

Manual smoke (needs Postgres + `mise exec -- mix ash.setup`, a configured `.jido/`
project with a reachable provider, `VOYAGE_API_KEY` set):

```bash
mise exec -- mix jidoclaw run "say hi" --format json   # clean JSON on stdout, logs on stderr
mise exec -- mix jidoclaw run "what did I just ask?" --continue
mise exec -- mix jidoclaw run "hi" --session <uuid>
mise exec -- mix jidoclaw run ""; echo "exit=$?"        # 2
mise exec -- mix jidoclaw --continue                    # REPL resume; then /sessions inside
```

Flaky-suite reminder: async:false singleton tests (MCPServer/Prompt/PipelineStore/
MultiSandbox) move under load — verify unrelated failures in isolation before blaming
this change.

## Risks / build-time re-checks

1. `pending_for_run_tree`'s relationship filter under multitenancy/policies — fallback
   documented (two-step probe in the runner).
2. `Jido.AgentServer.call` return shape for `context.modify` — mirror `set_system_prompt`'s
   `{:ok, agent}` match, adjust if bare.
3. BootGuard raise mapping to exit 2 — verify the exception type when wiring the rescue.
4. `chat/4` default return must stay byte-identical (cron auto-disable after 3 failures
   depends on it) — pinned by the Unit-3 regression test.
5. Precommit gotchas for new code: `@spec`s on public functions, alias instead of nested
   module refs, `@impl true`, no comment lines beginning with the word "step",
   test/support files are also linted.
6. New `:cli_run` kind: build-time grep for kind-sensitive branching
   (`grep -rn "kind ==\|kind in" lib/`) — the only known switch is the Resolver's `:cron`
   snapshot skip, but confirm before shipping.

## Suggested commit slicing (user commits; nothing staged by the implementer)

1. `feat: :cli_run session kind, most-recent + run-tree reads, workspace/last_active index; expose Startup.resolve_prompt/2`
2. `feat: restore LLM context from persisted transcript on fresh agent (resume core, strict/best-effort modes)`
3. `feat: structural composer ack via chat/4 composer_ack: :detailed`
4. `feat: mix jidoclaw run — headless one-shot with await + exit contract (osa OS1-5/OQ-4)`
5. `feat: REPL --resume/--continue + /sessions`
6. `test: CC2-2 prompt-prefix identity across resume (system + tools halves)`
7. `docs: reconcile osa OS1-5/OQ-4, osa-claude-code CC2-2, next-ten #1 status`
