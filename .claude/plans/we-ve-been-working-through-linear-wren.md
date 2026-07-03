# Review fixes: routed-worker context restore (P1) + strict REPL flag parsing (P2)

## Context

The headless one-shot + CLI session resume feature (plan
`please-review-docs-plans-unadopted-next-warm-moonbeam.md`) got a code review with two
findings. **Both are validated against source this session** — this plan fixes them.
Done means `mise exec -- mix precommit` passes. No commits; work stays unstaged.

### P1 (validated): handoff-owned resumed sessions restore context onto the wrong pid

`chat/4` restores the persisted transcript onto the **main** agent pid when it is fresh
(`lib/jido_claw.ex:123-130`), but `run_chat_turn/8` then routes the actual ask through
`HandoffRouter.resolve_session_owner/6` (`lib/jido_claw.ex:250`) to a worker pid the
router may have just started (`router.ex:400-436` `ensure_worker_pid/2`). The router
injects the worker's system prompt but never restores the transcript. Worse, the
cold-start synthesized owner is marked `preamble_consumed?: true` (`router.ex:315`), so
a rehydrated worker gets **neither** preamble nor restore: a cold `--resume`/`--continue`
of a session whose `metadata["current_agent_template"]` is set looks resumed in
persisted/worker history while the model answering is amnesic. Strict mode doesn't help —
the main-pid restore succeeded.

**The review named only the chat/4 surface; the REPL dispatcher has the same bug**: turns
go through `Repl.resolve_owner_and_attach/1` (`repl.ex:512`, `:690-712`) to the same
router, and the boot restore (`maybe_restore_boot_context`, `repl.ex:247,421-438`) only
targets the main pid. Both surfaces get the fix.

Key fact making the fix safe: for a **rehydrated** owner, `handoff_context_from_owner`
short-circuits to `%{}` (`router.ex:508-511`), so the router injects the **base** prompt
via `inject_system_prompt` — exactly the `Startup.resolve_prompt/2` bytes
`ContextRestore.restore/4` carries in its `:replace`. Restore-after-inject stays
byte-identical (CC2-2 preserved).

### P2 (validated): REPL/escript resume flag parse errors silently ignored

Both catch-all arms bind `_invalid` and continue
(`lib/mix/tasks/jidoclaw.ex:77`, `lib/jido_claw/cli/main.ex:59`):
`mix jidoclaw --resume` (missing value), `--bogus`, or `--resume <id> --continue`
(conflict — `resolve_boot_session`'s `cond` silently prefers resume) all boot a
fresh/default REPL while the user believes they requested history.
`RunCommand.main/2` already has the stricter pattern to mirror
(`validate_invalid/1` at `run_command.ex:145-150`, `validate_session_flags/1` at `:179-185`).

### Decisions (defaults endorsed by the review; documented, not asked)

- **P1 scope: rehydrated owners only** (`Handoff.rehydrated?/1`, `handoff.ex:106-108`).
  A rehydrated owner ⇔ durable ownership with runtime state lost — precisely the resume
  class. Fresh workers under a **live** (non-rehydrated) handoff keep today's designed
  behavior (bounded preamble + handoff-block prompt); restoring them would clobber the
  `inject_handoff_prompt` combined prompt with base-prompt bytes and change tested
  behavior. **Documented residual** (owned, consciously deferred): a handoff worker that
  crashes mid-live-handoff is lazily recreated amnesic (`router.ex:447-449`) — fixing
  that needs a prompt-choice-aware restore (carry the combined handoff prompt bytes) and
  is a separate follow-up, not this review item.
- **Main-pid restore stays.** It's harmless (main isn't asked this turn) and useful: if
  ownership later resets to main (`reset_handoff`), main has the transcript. A cold
  resume of a handoff-owned session therefore performs two restores (main + worker) —
  accepted.
- **P2 posture: hard-fail, exit 2** (stderr message + usage), matching the `run`
  subcommand's documented exit contract and RunCommand precedent. Positional-dir
  semantics (`resolve_project_dir_from_argv` falling back to cwd for a non-dir arg,
  `startup.ex:273-282`) are deliberately unchanged — the review scoped to flags.

---

## Unit 1 — P2: shared strict parser for the REPL arms

**New** `lib/jido_claw/cli/repl_args.ex` (`JidoClaw.CLI.ReplArgs`) — pure, no IO:

```elixir
@spec parse([String.t()]) ::
        {:ok, %{project_dir: String.t(), resume: String.t() | nil, continue: boolean()}}
        | {:usage, String.t()}
```

- `OptionParser.parse(args, strict: [resume: :string, continue: :boolean])`.
- `invalid != []` → `{:usage, "invalid option(s): <flags>"}` (mirror
  `RunCommand.validate_invalid/1`; note `--resume` with no value lands in `invalid` as
  `{"--resume", nil}`, so it's caught here).
- `resume` set AND `continue` true → `{:usage, "--resume and --continue are mutually exclusive"}`.
- Else `project_dir = JidoClaw.Startup.resolve_project_dir_from_argv(positional)`
  (positionals only — preserves the existing flag-value-skipping fix).

**Both entry files** (`lib/mix/tasks/jidoclaw.ex` catch-all `run/1`,
`lib/jido_claw/cli/main.ex` catch-all `main/1`): replace the inline parse with

```elixir
case ReplArgs.parse(args) do
  {:ok, %{project_dir: dir, resume: resume, continue: continue}} ->
    # existing put_env + app start + Repl.start(dir, resume: resume, continue: continue)
  {:usage, message} ->
    IO.puts(:stderr, "error: #{message}")
    IO.puts(:stderr, "usage: mix jidoclaw [dir] [--resume <uuid> | --continue]")  # jido … for escript
    System.halt(2)
end
```

Add one moduledoc line to each entry file: invalid flags exit 2.

**Tests** — new `test/jido_claw/cli/repl_args_test.exs` (pure, async): zero args → cwd +
nil/false; `[dir]`; `--resume <uuid>`; `--resume <uuid> <dir>` (dir from positional, uuid
NOT treated as dir); `--continue`; `--bogus` → usage; `--resume` (no value) → usage
naming `--resume`; `--resume x --continue` → mutually-exclusive usage.

## Unit 2 — P1: router exposes worker freshness

`lib/jido_claw/agent/handoff/router.ex`:

1. `ensure_worker_pid/2` → `{:ok, pid, fresh? :: boolean}`: `true` only when this call's
   `jido_start_agent` actually started it; `whereis` hit / `already_started` /
   `already_registered` ⇒ `false` (mirror `JidoClaw.resolve_agent_pid/1` semantics,
   `jido_claw.ex:190-203`).
2. Return tuple grows 5 → 6:
   `{routed_pid, routed_template, routed_agent_id, first_post_handoff?, worker_fresh?, owner}`.
   Default/fallback paths (`default_tuple/1`) return `worker_fresh?: false`. Update
   `@spec resolve_session_owner/6` + moduledoc return list.
3. New public predicate (the Router owns Handoff-struct knowledge):
   ```elixir
   @spec rehydrated_owner?(HandoffRegistry.owner() | nil) :: boolean()
   def rehydrated_owner?(%{handoff: %Handoff{} = h}), do: Handoff.rehydrated?(h)
   def rehydrated_owner?(_), do: false
   ```

**Complete 5→6-tuple call-site checklist** (verified by grep this session; line numbers
will drift a little while editing — the grep at the end is the ground truth):

| File | Sites |
|---|---|
| `lib/jido_claw.ex` | `:251` (`run_chat_turn` destructure) |
| `lib/jido_claw/cli/repl.ex` | `:513` (`handle_message` destructure), `:687` (`@spec`), `:690-711` (`resolve_owner_and_attach` internal destructure + return) |
| `test/jido_claw/agent/handoff/router_test.exs` | 19 calls: 124, 141, 161, 184, 195, 227, 241, 279, 308, 335, 367, 386, 419, 441, 469, 495, 539, 546, 557 |
| `test/jido_claw/cli/repl_test.exs` | 171, 221 |
| `test/jido_claw/reasoning/compactor/coherence_test.exs` | 272, 351, 422 (three, not one) |
| `test/jido_claw/conversations/handoff_routing_integration_test.exs` | ~104, 128, 148, 188, 200 |

`test/jido_claw/conversations/handoff_dispatcher_integration_test.exs` has **no**
destructures (it drives `chat/4`), so the tuple change doesn't touch it — and its live-
handoff tests double as regression canaries that a non-rehydrated fresh worker still
gets NO restore. Final check after editing:
`grep -rn "resolve_session_owner\|resolve_owner_and_attach" lib test`.

**New router tests** (router_test's existing `SeamRuntime` + cold-start describe):
first resolve after cold-start synthesis reports `worker_fresh?: true`; second resolve
(whereis hit) reports `false`; default path reports `false`.

## Unit 3 — P1: chat/4 path restores the routed worker

`lib/jido_claw.ex` `run_chat_turn/8`, immediately after the routing destructure
(`:250-260`) and **before** `SessionWorker.add_message(:user, …)` at `:290` (restore
loads `Message.for_session_primary`; appending the current user row first would
double-append it):

```elixir
restore_worker? = worker_fresh? and HandoffRouter.rehydrated_owner?(owner)

case maybe_restore_context(restore_worker?, routed_pid, session, project_dir, actor, opts) do
  :ok -> # rest of the existing turn body, unchanged
  {:error, _} = err -> err
end
```

- Reuses `maybe_restore_context/6` verbatim — the `:context_restore` strict/best-effort
  policy and the `:context_restore_impl` test seam come for free. Strict (the one-shot's
  `--session`/`--continue`) now fails loud when the **worker** restore fails —
  `RunCommand` already maps `{:error, {:context_restore_failed, _}}` to exit 1
  (`run_command.ex:391-398`); no runner change needed.
- Structure: extract the remainder of the body into a private continuation helper rather
  than nesting ~90 lines in a `case` (credo nesting/complexity). The trailing pragma'd
  `rescue`/`catch` (`jido_claw.ex:356-361`) must keep wrapping the whole body; the
  restore error flows as a normal return value.
- No condition on `routed_pid != agent_pid` needed: `worker_fresh?` is only ever true on
  the routed path.

**Tests** — extend `test/jido_claw/chat_resume_test.exs` (setup already has the
`:ask_runtime` `HandoffDispatchCapture` — which reports the asked **pid** — plus
`:context_restore_impl` in its saved-env list):

- New capturing restore stub in the file (records `{:restore_called, pid}` to the test
  process, returns `:ok`).
- **Headline P1 test**: seed transcript (turn 1 via `chat/1` helper), stop the agent,
  set `ConversationsSession.set_current_agent_template(session, "reviewer", …)`, clear
  the handoff registry (`on_exit` too), install the repl_test-style `FakeRuntime`
  (worker pid in app env — pattern at `repl_test.exs:176-187`); run a turn; assert the
  restore stub was called with the **worker** pid (equal to the pid
  `{:dispatch_capture, pid, _, _}` reports), not only main.
- **Strict worker-failure test**: restore stub returns `{:error, :forced}` only when the
  target pid is the app-env worker pid (`:ok` for main) → turn with
  `context_restore: :strict` returns `{:error, {:context_restore_failed, :forced}}`.
- **Live-handoff pin**: seed a NON-rehydrated registry owner (real `message:`, as
  `router_test.install_handoff/5` does) with a fresh worker → assert NO restore call
  with the worker pid (scope guard against clobbering the handoff prompt).

**Required real-worker e2e** (not optional — the bug is an integration bug, and it's
cheap: `handoff_dispatcher_integration_test.exs` already starts REAL Reviewer workers
through the real runtime with the ask stubbed). Add to that file: *"cold resume of a
handoff-owned session restores the routed worker's LLM context"* —

1. Turn 1: plain `chat/4` (no handoff) seeds durable user+assistant rows.
2. `ConversationsSession.set_current_agent_template(session, "reviewer", …)`; leave the
   registry EMPTY (no `HandoffTool.run`) — that IS the cold-resume state.
3. Turn 2: real router synthesizes the rehydrated owner, starts a real Reviewer worker,
   real `ContextRestore` (no stub) delivers `ai.react.context.modify`.
4. Assert `{:dispatch_capture, pid, …}` pid ==
   `Jido.whereis(JidoClaw.Jido, "handoff:#{session.id}:reviewer")`, then read that
   worker's strategy context (borrow `agent_context/1` from `chat_resume_test.exs:81-89`,
   pointed at the worker pid) and assert entries == turn 1's `{:user, …}`/`{:assistant,
   "captured"}` pair with a non-empty binary `system_prompt`. (Turn 2's own user message
   rides the stubbed ask, not the restored context — restore precedes
   `add_message(:user, …)`; main is alive from turn 1, so only the worker restore fires.)

This closes the loop the seam tests can't: a real routed worker accepting the restore
signal.

## Unit 4 — P1: REPL path restores the routed worker

`lib/jido_claw/cli/repl.ex` `resolve_owner_and_attach/1` (`:690-712`) — it already
fetches `session_record` and returns the router tuple:

- After `ensure_attached`, when `worker_fresh? and HandoffRouter.rehydrated_owner?(owner)`
  **and** `session_record != nil and is_binary(state.cwd)` (ContextRestore guards require
  a binary dir; repl_test drives this seam with `cwd: nil`), call the same
  `:context_restore_impl` facade (add a `defp context_restore_impl` mirroring
  `jido_claw.ex:183-184`): `restore(routed_pid, session_record, state.cwd, actor: actor)`.
- Interactive posture (matches boot + `resolve_boot_session`): on `{:error, reason}`
  print the boot warning verbatim-style —
  `⚠ history NOT restored — the model will not remember prior turns: …`
  (`repl.ex:433-437`) — and proceed; never abort the turn.
- **Intentional residual — no retry after a failed warn-and-proceed restore**: the
  worker pid is now live, so `worker_fresh?` is `false` on every subsequent turn and the
  restore never re-fires; the session stays amnesic until the worker dies or the REPL
  restarts. Same shape on chat/4's `:best_effort` surfaces (cron/web): logged once, no
  retry. This mirrors the existing boot-restore failure posture (also fire-once) and is
  accepted because the surfaces where it matters most self-heal: `:strict` (the
  one-shot's `--session`/`--continue`) fails the turn, the VM exits, and the next
  invocation is a fresh node with a fresh worker. Document this in the
  `resolve_owner_and_attach` `@doc` alongside the live-handoff-crash residual.
- Update the `@spec`/`@doc` (6-tuple) and the `handle_message` destructure at `:512`.

**Tests** — extend `test/jido_claw/cli/repl_resume_test.exs` (TenantCase, already
resume-scoped): seed session + `current_agent_template` metadata + a real workspace tmp
dir; build a `%Repl{}` state with `session_uuid: session.id`, `cwd: tmp`; FakeRuntime +
capturing restore impl → `resolve_owner_and_attach` triggers restore on the worker pid;
failing impl → `capture_io` shows the ⚠ warning and the tuple is still returned.

## Verification

```bash
# Targeted while iterating
mise exec -- mix test test/jido_claw/cli/repl_args_test.exs \
  test/jido_claw/agent/handoff/router_test.exs \
  test/jido_claw/chat_resume_test.exs \
  test/jido_claw/cli/repl_resume_test.exs \
  test/jido_claw/cli/repl_test.exs \
  test/jido_claw/reasoning/compactor/coherence_test.exs \
  test/jido_claw/conversations/handoff_routing_integration_test.exs \
  test/jido_claw/conversations/handoff_dispatcher_integration_test.exs \
  test/jido_claw/cli/run_command_test.exs

# Definition of done — run BARE (no pipes: they mask the exit code), in background,
# then read the output tail:
mise exec -- mix precommit
```

Manual smoke (optional; needs Postgres + configured `.jido/`):
`mix jidoclaw --bogus; echo $?` → 2 · `mix jidoclaw --resume; echo $?` → 2 ·
`mix jidoclaw --resume <uuid> --continue; echo $?` → 2 ·
`mix jidoclaw run "what did I ask?" --continue` against a handoff-owned session.

Flaky-suite reminder: async:false singleton tests (MCPServer/Prompt/PipelineStore/
MultiSandbox) move under load — verify unrelated failures in isolation before blaming
this change.

## Risks / build-time re-checks

1. `Jido.AgentServer` restore delivery to a template worker is identical to the main
   agent (same `use JidoClaw.Agent.Defaults` ⇒ ReAct strategy handles
   `ai.react.context.modify`) — pinned for real by the **required** real-worker e2e in
   Unit 3, not just the seam tests.
2. Restore-before-`add_message(:user, …)` ordering in BOTH surfaces (chat: before
   `jido_claw.ex:290`; REPL: `resolve_owner_and_attach` already precedes
   `repl.ex:542`) — re-verify after the Unit-3 helper extraction.
3. Precommit gotchas for new code: `@spec` + `@moduledoc` on `ReplArgs` and
   `rehydrated_owner?/1`; alias instead of nested refs; no comment line beginning with
   the word "step"; test/support-style lint applies to test helpers; keep the existing
   `reach:disable-next-line bare_rescue` pragmas in place when restructuring
   `run_chat_turn`.
4. `IO.puts(:stderr, …)` in the mix task before `Mix.Task.run("app.start")` is fine;
   keep `System.halt(2)` (not `Mix.raise`, which exits 1) for exit-contract consistency.

## Suggested commit slicing (user commits; nothing staged)

1. `fix: reject invalid/conflicting REPL resume flags with exit 2 (shared ReplArgs parser)` —
   `lib/jido_claw/cli/repl_args.ex`, `lib/mix/tasks/jidoclaw.ex`,
   `lib/jido_claw/cli/main.ex`, `test/jido_claw/cli/repl_args_test.exs`
2. `fix: restore resumed transcript onto the routed handoff worker, not just main` —
   `lib/jido_claw/agent/handoff/router.ex`, `lib/jido_claw.ex`,
   `lib/jido_claw/cli/repl.ex`, + updated/new tests (router, chat_resume, repl,
   repl_resume, coherence)
