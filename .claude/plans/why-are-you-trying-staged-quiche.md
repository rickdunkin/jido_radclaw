# REPL Dispatch: Bounded MCP Attach After Routing (code-review P2 fix)

## Context

The just-finished plan (`please-review-docs-exploration-jidoka-fe-twinkly-goblet.md`) shipped
worker/sub-agent MCP sync + a per-template reach-allowlist: every agent-turn surface now runs a
bounded `ensure_attached(pid, template, 8_000)` after routing, so a turn carries its external MCP
tools scoped to the resolved worker's template.

A code review found one validated gap (**P2**): the **interactive REPL dispatch path was missed**.

### Verification (confirmed by reading code, read-only)

- **Chat path** — `lib/jido_claw.ex:219` (`run_chat_turn/8`) calls
  `_ = mcp().ensure_attached(routed_pid, routed_template, 8_000)` immediately after
  `HandoffRouter.resolve_session_owner`.
- **REPL path** — `lib/jido_claw/cli/repl.ex:360` (`handle_message/2`) resolves the **identical**
  `{routed_pid, routed_template, …}` tuple via the same `resolve_session_owner`, then goes straight
  to `Agent.ask(routed_pid, …)` at `:423` with **no `ensure_attached`**. The REPL's only attach is
  the boot-time fire-and-forget `JidoClaw.MCP.attach_to_agent(pid, "main")` at `:72`.

Two real consequences:
1. A **handoff-routed REPL turn** runs on a fresh worker pid (not the boot main pid, not
   `AgentTracker`-registered) → zero external MCP tools.
2. A **first REPL turn** can race ahead of the async boot attach → tool-less.

Coverage sweep (`grep resolve_session_owner` + `ensure_attached` across `lib/`) confirms the REPL
`handle_message/2` is the **only** dispatch surface still missing the bounded attach
(spawn/follow-up/skill-step/chat all have it). So this single finding is the complete gap.

Two facts that shape the fix:
- The router's no-handoff path is **DB-free** when `session_uuid` is nil:
  `fetch_metadata_template(nil, …) → :none → default_tuple` (`router.ex:273/261/269-271`), returning
  `{default_pid, "main", default_agent_id, false, nil}` without touching Postgres. This makes a
  fast, deterministic REPL unit test possible.
- The already-shipped `test/support/mcp_facade_capture.ex` carries an `attach_to_agent/2` passthrough
  whose own comment ("keeps a test that swaps the whole facade from breaking the REPL-boot path")
  signals the boot attach was *intended* to route through the `mcp()` seam.

### Intended outcome

The REPL chat turn reaches parity with the programmatic chat path: it eagerly registers the
**routed** worker's template-allowlisted external MCP tools (bounded) before dispatch, so handoff
workers and first turns are tool-equipped. The "every turn surface" docs become honest.

## Changes

### 1. `lib/jido_claw/cli/repl.ex`

- **`@type t :: %__MODULE__{}`** after the `defstruct` block (backs the new `@spec`).
- **`defp mcp, do: Application.get_env(:jido_claw, :mcp_facade, JidoClaw.MCP)`** — a single, isolated
  seam (matches the `jido_claw.ex:159` form). Clone-gate safe: `repl.ex` has **no** contiguous
  `Application.get_env` seam cluster (cf. `project_exslop_duplicate_clone_seams` — the gate trips on
  ≥3 *contiguous* identical seams, not a lone small fragment).
- **Boot attach through the seam** (`:72`): `JidoClaw.MCP.attach_to_agent(pid, "main")` →
  `mcp().attach_to_agent(pid, "main")`. Zero production change (`mcp()` defaults to `JidoClaw.MCP`);
  makes all MCP facade access seamed and gives the test double's `attach_to_agent/2` a real purpose.
- **New public test seam `resolve_owner_and_attach/1`** (follows the existing
  `resolve_strategy/1` / `prepare_user_message/2` public-seam convention in this module). It resolves
  the handoff-aware owner and eagerly attaches the routed worker's tools, returning the full 5-tuple:

  ```elixir
  @spec resolve_owner_and_attach(t()) ::
          {pid(), String.t(), String.t(), boolean(),
           JidoClaw.Agent.Handoff.Registry.owner() | nil}
  def resolve_owner_and_attach(%__MODULE__{} = state) do
    actor = Actor.system(state.tenant_id)
    session_record = fetch_session_record(state, actor)

    routed =
      HandoffRouter.resolve_session_owner(
        state.tenant_id, state.session_id, state.session_uuid, state.agent_pid, actor,
        project_dir: state.cwd, session_record: session_record, default_agent_id: state.agent_id
      )

    {routed_pid, routed_template, _, _, _} = routed
    # Bounded: register the routed worker's template-allowlisted MCP proxies
    # before the turn; blocks only this turn, never the Consumer (best-effort).
    _ = mcp().ensure_attached(routed_pid, routed_template, 8_000)
    routed
  end
  ```

  (Spec uses the fully-qualified `JidoClaw.Agent.Handoff.Registry.owner()` to avoid adding an alias.)

- **`handle_message/2`** replaces its inline `actor`/`session_record`/`resolve_session_owner` block
  (`:357-370`) with `{routed_pid, routed_template, routed_agent_id, first_post_handoff?, owner} =
  resolve_owner_and_attach(state)`. The `actor`/`session_record` locals are used **only** for routing
  (verified: not referenced after `:370`), so they move inside the seam cleanly. Net new behavior:
  the bounded attach now runs (after `Display.start_thinking/0`, so the thinking indicator covers it).

### 2. `test/jido_claw/cli/repl_test.exs` (extend; module is already `async: false`)

New `describe "resolve_owner_and_attach/1 …"` driving the seam through `JidoClaw.Test.MCPFacadeCapture`
(set `:mcp_facade` + `:mcp_facade_capture_target` in `setup`, restore in `on_exit`). **Two tests**,
both DB-free (no `TenantCase`/sandbox needed):

**(a) No-handoff turn — the first-turn race fix.** `%Repl{}` with a parked dummy `agent_pid`,
`session_uuid: nil`, fresh `session_id`, `tenant_id: "default"`, `agent_id: "main"`. Asserts the
return is `{^agent_pid, "main", "main", false, nil}` **and** that `{:mcp_ensure_attached, ^agent_pid,
"main", 8_000}` is received — the routed (main) pid/template is threaded into the bounded attach.
(DB-free: `session_uuid: nil` → router takes `fetch_metadata_template(nil) → :none → default_tuple`.)

**(b) Routed-handoff turn — the headline P2 (worker gets its MCP tools).** Proves a handoff-routed
REPL turn attaches the *worker* pid under `"reviewer"`, not the main pid. Kept lightweight + DB-free:
  - Stub `:jido_runtime` (save/restore via `on_exit`) with a small fake — `whereis/1 → nil`,
    `start_subagent/2 → {:ok, worker_pid}` (a parked dummy pid) — mirroring `send_to_agent_test`'s
    `FakeJido`. This is the `ensure_worker_pid/2` seam (`router.ex:424/436`), so no real agent starts.
  - Seed the registry: `HandoffRegistry.put_owner(tenant, session, handoff, preamble_consumed?: true)`
    where `handoff = Handoff.new(%{tenant_id, runtime_session_id: session, session_uuid:
    Ecto.UUID.generate(), to_template: "reviewer", to_module: <reviewer module from
    Templates.get("reviewer")>, message: Handoff.rehydrated_marker()})`. The non-nil
    `handoff.session_uuid` is what `effective_uuid` falls back to (so routing stays on the owner path,
    DB-free); `preamble_consumed?: true` makes `first_post_handoff?` false. `clear/2` on_exit.
  - `%Repl{}` with `agent_pid:` a distinct main dummy, `session_uuid: nil`, **`cwd: nil`** (→
    `project_dir: nil` → `maybe_inject_prompt` short-circuits to `:ok`, `router.ex:445`), tenant
    `"default"`, fresh `session_id`.
  - Asserts the return is `{^worker_pid, "reviewer", _, false, _}` (and `worker_pid != main_pid`)
    **and** that `{:mcp_ensure_attached, ^worker_pid, "reviewer", 8_000}` is received.

Together these cover both halves of the P2 (first-turn race **and** handoff worker). The owner-present
path reads no session metadata from Postgres, so seeding the in-memory `HandoffRegistry` + stubbing
the runtime keeps test (b) DB-free. (The heavier real-session/real-worker variant of the routed case
is already covered by `handoff_dispatcher_integration_test.exs:138-174` for the chat path, which the
REPL now shares.)

### 3. Docs — reconcile the now-honest "every turn surface" claims

- **`AGENTS.md`** (MCP consumption bullet, ~`:87`): `every turn surface — chat, …` →
  `every turn surface — chat (REPL + chat/4), …` so the enumeration covers both chat entry points.
- **`docs/exploration/jidoka/FEATURES-WORTH-BORROWING-V2.md`** (V2-2 status, ~`:51`): the
  "every agent-turn surface" sentence omits the REPL entirely; add it —
  `… and the handoff-routed chat turn — across both the interactive REPL and the programmatic chat/4
  path (previously only the boot-time main chat pid, …)`.

`lib/jido_claw/mcp/server_spec.ex` and other docs are unaffected (this fix is about turn surfaces,
not the allowlist mechanism).

## Verification

1. **Targeted tests** (fast feedback):
   `mix test test/jido_claw/cli/repl_test.exs test/jido_claw/conversations/handoff_dispatcher_integration_test.exs`
2. **Full `mix precommit` must pass** (the done bar). Watch the gates this change touches:
   - `jidoclaw.compile_check` — zero non-allowlisted warnings (`@type t`, `@spec`, `@doc`, and the new
     `def`/`defp mcp` are all used).
   - `format --check-formatted`.
   - `reach.check --arch --smells --strict` — no new `fixed_shape_map`/`bare_rescue`
     (`repl.ex` already `# reach:disable-for-this-file bare_rescue`); lone `mcp/0` seam stays under the
     clone gate.
   - `credo --strict`, `dialyzer` (the new `@spec` matches `resolve_session_owner`'s return exactly).
   - `test`.
   Run the **full** `mix precommit`; do **not** pipe through `tail` (hides credo/reach
   string-building findings). Leave everything unstaged.
