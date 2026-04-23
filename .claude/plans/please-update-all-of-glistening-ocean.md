# Plan: Refresh 7 git-branch deps (and retire the anubis_mcp patches)

## Context

Phase 2 of the dependency-update workflow left 7 git-branch-pinned deps
unrefreshed because `mix hex.outdated` doesn't see them. The user asked to
update them all, noting that `jido_mcp` was believed to have bumped `anubis_mcp`
— which, if true, would finally unblock removal of the two runtime monkey-patches
against `Anubis.Server.Transport.STDIO` and `Anubis.Server.Handlers.Tools`
(documented in `mix.exs:14-22` and each patch file header as "remove once
jido_mcp upgrades to anubis_mcp ~> 1.0").

**Confirmed**: `jido_mcp` main (`ece85aaf74`, 2026-04-22) pins
`{:anubis_mcp, "~> 1.1"}` ([source](https://github.com/agentjido/jido_mcp/blob/ece85aaf745390ee22d00cdbf68bb9d2fa61de3b/mix.exs#L31-L36));
hex has `anubis_mcp` 1.1.1. Our repo is pinned to `jido_mcp@8cdd6397cd`
(2026-02-27, still on `anubis_mcp ~> 0.17.0`).

Outcome we want: all 7 deps on their current tracked-branch HEAD, both anubis
patches retired if the upgrade closes the schema-validation gap (best case),
otherwise the stdio patch retired cleanly and the tools-handler patch replaced
with a slimmer port against anubis 1.1. Either way, `mix.exs`,
`docs/ROADMAP.md`, `AGENTS.md`, and the three surviving shell-patch headers
all get their stale anubis language cleaned up in the same commit as the
`jido_mcp` SHA bump. Which branch we land depends on the Step 3 smoke test —
see that section for the decision point.

## Current state vs. tracked branches

Actually behind their tracked branch (needs update):

| Dep | Pinned SHA | Latest | Delta |
|---|---|---|---|
| `jido_mcp` | `8cdd6397cd` | `ece85aaf74` | 4 commits; `anubis_mcp ~> 0.17.0` → `~> 1.1`; runtime endpoint registration; deletes `lib/jido_mcp/anubis_client.ex`; new `lib/jido_mcp/config.ex`. |
| `jido_memory` | `fcaea45c7f` | `2490899522` | 1 commit — docs + `mix.exs` + `plugin_test.exs`. No lib-side diffs for `Store.ETS` / `Record` / `Query` (our only integration points). |
| `jido_messaging` | `525a6c7ebd` | `49a4acb0ad` | 1 commit — "align with Jido package quality standards". `adapter_bridge.ex` +142/-73, new `bridge_server.ex`, `bridge_supervisor.ex`, `onboarding/supervisor.ex`, `topology_validator.ex`, plus `mix.exs` +11/-6. |

Already at tracked-branch HEAD (`mix deps.update` is a no-op — skip):
`libgraph@32280656f8`, `jido_skill@cc5ec5aaf5`, `jido_shell@5d7ecf096a`,
`jido_vfs@6c9cd2c521`. Verified upstream `jido_shell@5d7ecf096a` still has
no `ShellSession.update_env/2`, no `:update_env` handler in
`ShellSessionServer`, and no `:extra_commands` hook in `Command.Registry` — all
3 `jido_shell_*_patch.ex` files stay.

## Recommended approach — three independent steps, lowest-risk first

Each step ends with `mix compile --warnings-as-errors` and `mix test`. If a step
fails, fix or revert before starting the next so failures attribute to the
specific upgrade that caused them.

### Step 1 — `jido_memory` (low risk)

```bash
mix deps.update jido_memory
mix compile --warnings-as-errors
mix test
```

Integration seam: `lib/jido_claw/platform/memory.ex` (`@store
Jido.Memory.Store.ETS`; constructs `%Jido.Memory.Record{}` /
`%Jido.Memory.Query{}`). No lib-side diffs against those modules upstream;
expect this to be uneventful.

Canary tests already present: `test/jido_claw/memory_test.exs`,
`test/jido_claw/tools/remember_test.exs`,
`test/jido_claw/tools/recall_test.exs`.

### Step 2 — `jido_messaging` (medium risk)

```bash
mix deps.update jido_messaging
mix compile --warnings-as-errors
mix test
```

Integration seam: `lib/jido_claw/platform/messaging.ex`
(`use Jido.Messaging, persistence: Jido.Messaging.Persistence.ETS`). Upstream
refactored `adapter_bridge.ex` and added new supervisors/servers; our `use`
macro will pick up new children. If compile fails, read the new
`Jido.Messaging.__using__/1` and reconcile — the 1-line `use` call is the only
attach point in our codebase.

**Add a minimal canary test** at
`test/jido_claw/messaging_test.exs` that exercises the `JidoClaw.Messaging`
module's generated API (minimally: boot the supervisor, create a room via the
public API, save + fetch one message). Without it, Step 2 relies on compile
alone since the supervisor starts during `app.start` and wouldn't crash on
subtle API drift — we'd only notice at runtime. The exact call surface
depends on `Jido.Messaging` v2 semantics; read `deps/jido_messaging/lib/` after
the update to pick the thinnest end-to-end path.

### Step 3 — `jido_mcp` + retire (or slim) the anubis patches (**atomic**, highest value)

Anubis's public surface changed between 0.17 and 1.x (the patches call into
`Anubis.MCP.Message`, `Anubis.Transport.Behaviour`, `Anubis.Logging`,
`Anubis.Telemetry` — any rename breaks the patch at compile). So
`mix deps.update jido_mcp` must happen in the same commit as the patch-file
deletion. Stopping between them leaves the tree non-compiling.

Actions in this single commit:

1. `mix deps.update jido_mcp` (pulls new `jido_mcp`; transitively upgrades
   `anubis_mcp` 0.17.1 → 1.1.1).
2. **Delete** `lib/jido_claw/core/anubis_stdio_patch.ex`.
3. **Delete** `lib/jido_claw/core/anubis_tools_handler_patch.ex`.
4. **Edit `mix.exs:14-22`** — rewrite the `elixirc_options` comment. The flag
   stays (the 3 surviving shell patches still need it), but drop all
   "anubis_mcp 0.17.1" and "jido_mcp upgrade to anubis_mcp ~> 1.0" language;
   re-point the comment at the 3 `jido_shell_*_patch.ex` files.
5. **Edit `AGENTS.md:56-58`** — remove the "Known limitations (anubis_mcp
   0.17.1 …)" block. Leave the second bullet about stdout warnings only if
   smoke testing shows anubis 1.1 still emits them; otherwise drop that too.
6. **Edit `docs/ROADMAP.md:24`** — the bullet currently reads
   `MCP server mode validation with Claude Code (validated — patched
   anubis_mcp 0.17.1 stdio transport + tools handler)`. Drop the parenthetical,
   or replace with `(anubis_mcp 1.1.1)`.
7. **Edit `docs/ROADMAP.md:141`** — the "Strict compile green" paragraph
   describes the temporary flag and the patches. Rewrite to describe the
   surviving `jido_shell_*` patches, or drop the paragraph entirely since
   the ROADMAP entry it sits under (v0.2.5 auto-selection) is historical.
8. **Edit `lib/jido_claw/core/jido_shell_registry_patch.ex:15-17`** — header
   says "the flag is already in place for the anubis_mcp patches". Rewrite to
   own the flag ("the flag is declared in mix.exs to suppress the intentional
   redefinition warning — see the comment there for the patch inventory").
9. **Edit `lib/jido_claw/core/jido_shell_session_server_patch.ex:18-21`** —
   same fix ("flag already in place for the anubis_mcp + registry patches"
   → same rewrite as above).
10. **Edit `lib/jido_claw/core/jido_shell_session_patch.ex:10-12`** — header
    says the flag is "in place" without specifying why. Align with the other
    two shell patch headers.
11. `mix compile --warnings-as-errors`.
12. `mix test` — pay attention to `test/jido_claw/mcp_server_test.exs`.
13. **Manual MCP smoke test** (see below). **If this fails**, stay in Step 3
    and add the schema fix in the same commit — do not land Step 3 with a
    broken MCP path and bisect later.

### Step 3 smoke test

**Prerequisite**: `brew install coreutils` (installs `gtimeout`; neither
`timeout` nor `gtimeout` is on PATH on this machine by default).

`mix jidoclaw --mcp` calls `Process.sleep(:infinity)` after boot
([lib/mix/tasks/jidoclaw.ex:26](lib/mix/tasks/jidoclaw.ex)), so pipe-based
invocations never exit on their own. Wrap in `gtimeout` and judge by stdout,
not exit code.

Required MCP handshake: `initialize` → `notifications/initialized` → any
`tools/*` call. `tools/list` or `tools/call` before the notification returns
"Server not initialized". Use a required-argument tool so string-keyed JSON
arguments actually reach a Jido action (`project_info` has `schema: []` and
would pass even if atomization/validation were still broken); `read_file`
with `{"path": "mix.exs"}` is the right canary.

```bash
printf '%s\n%s\n%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"read_file","arguments":{"path":"mix.exs"}}}' \
  | gtimeout 10 mix jidoclaw --mcp
```

Expected output: two JSON objects on stdout — an `initialize` result and a
`tools/call` result. Per the MCP tool-call protocol, the `read_file` action's
return map lives under `result.structuredContent` (Anubis sends
`"content": []` at the top level and the action's map under
`"structuredContent"`). Confirm `structuredContent` has non-empty `content`
(or whatever `JidoClaw.Tools.ReadFile` returns) matching `mix.exs`.

If the second response is a JSON-RPC error (`-32602 Invalid params` or a
`FunctionClauseError` stack), the schema/validation path is live — see the
next section.

Also run `mix jidoclaw` (REPL) briefly to confirm the 3 surviving
`jido_shell_*` patches still load cleanly — any command (`pwd`, `ls`) will
exercise registry lookup and session state.

### Known risk in Step 3: Anubis input validation still runs before `handle_tool_call/3`

`anubis_tools_handler_patch.ex:82-84` rescues the `Peri.validate` crash in
`validate_params/3`. Anubis 1.1.1 still gates tool dispatch on
`validate_params/3`
([source](https://github.com/zoedsoupe/anubis-mcp/blob/v1.1.1/lib/anubis/server/handlers/tools.ex#L55-L66)).
Current `jido_mcp` main still appears to pass Jido JSON-Schema into Anubis's
`Frame.register_tool/3` — there is no evidence the upstream made its schema
emission Peri-compatible when it bumped the anubis dep. So a `read_file`
failure at validation is plausible, not just defensive.

Crucially, a shim in `JidoClaw.MCPServer.handle_tool_call/3` cannot rescue
this: Anubis validates *before* it ever calls `handle_tool_call/3`. And
`Jido.MCP.Server` doesn't expose a tool-registration override point — only
`authorize/2` is user-overridable upstream; `init/2` and registration are
owned by the macro. So "adapt the schema at registration from our side"
isn't actually on the menu without touching upstream.

Realistic options if the smoke test fails at validation:

- **Primary local fallback: slimmer tools-handler patch ported to anubis
  1.1.** Copy `anubis_mcp 1.1.1`'s `lib/anubis/server/handlers/tools.ex`
  verbatim into `lib/jido_claw/core/anubis_tools_handler_patch.ex`, then
  reapply just two changes from the retired 0.17 patch:
  1. `rescue` clause in `validate_params/3` that returns `{:ok, params}` on
     Peri error (Jido.Exec.run validates internally, so skipping is safe).
  2. `atomize_known_keys/1` before `server.handle_tool_call/3`. (Optional —
     if validation passes but the action then `KeyError`s on an atom key, add
     atomization; if not needed, drop it.)

  The stdio patch still retires cleanly either way — anubis 1.1 fixed both
  stdio bugs the old patch addressed (upstream `process_single_message`
  writes to stdout; `handle_call({:send, …})` replaces the broken
  `handle_cast`). Only the tools-handler patch survives.

- **Upstream fix (preferred long-term, not in scope for this commit)**: file
  an issue / PR against `jido_mcp` so its schema emission is Peri-compatible,
  or so it no longer routes JSON-Schema-shaped descriptors through Anubis's
  pre-dispatch Peri validation path.
  Reference: the Peri path is in anubis's
  [`tools.ex:55-66`](https://github.com/zoedsoupe/anubis-mcp/blob/v1.1.1/lib/anubis/server/handlers/tools.ex#L55-L66).

If the local fallback is needed, update in the same Step 3 commit:

- The plan's outcome and headline — this is not "retire both anubis patches";
  it's "retire `anubis_stdio_patch.ex`; replace `anubis_tools_handler_patch.ex`
  with a slimmer port against anubis 1.1."
- `mix.exs:14-22` comment — reference `Anubis.Server.Handlers.Tools` as the
  one surviving anubis redefinition.
- `AGENTS.md` — narrow the "Known limitations" block rather than removing
  it. Bullet becomes: `Runtime patch overrides Anubis.Server.Handlers.Tools
  to rescue a Peri validation crash caused by jido_mcp schema format; remove
  once jido_mcp either emits Peri-compatible schemas or no longer routes those
  descriptors through Anubis's pre-dispatch Peri validation path.`
- `docs/ROADMAP.md:141` — rewrite but don't remove the patch mention.

Whichever path the smoke test forces, land it in the **same Step 3 commit**
so the tree bisects cleanly.

## Files that will be touched

- `mix.lock` — SHA bumps for `jido_memory`, `jido_messaging`, `jido_mcp`;
  transitive `anubis_mcp` 0.17.1 → 1.1.1, likely `zoi` (upstream `mix.exs`
  pins `~> 0.17`, same as ours).
- `mix.exs` — rewrite the `elixirc_options` comment (lines 14-22). No code
  changes.
- `AGENTS.md` — drop "Known limitations (anubis_mcp 0.17.1)" block (lines
  56-58).
- `docs/ROADMAP.md` — edit lines 24 and 141.
- `lib/jido_claw/core/jido_shell_registry_patch.ex` — header rewrite (lines
  15-17).
- `lib/jido_claw/core/jido_shell_session_patch.ex` — header rewrite (lines
  10-12).
- `lib/jido_claw/core/jido_shell_session_server_patch.ex` — header rewrite
  (lines 18-21).
- **Delete** `lib/jido_claw/core/anubis_stdio_patch.ex` (always — anubis 1.1
  fixed both stdio bugs this patched).
- `lib/jido_claw/core/anubis_tools_handler_patch.ex` — **delete** if the
  smoke test passes without it; **replace** with a slimmer port against
  anubis 1.1 if validation still fails. See Step 3's "Known risk" section.
- **New** `test/jido_claw/messaging_test.exs` — canary for Step 2.

## Files that will NOT change

- `mix.exs` dep list — no version-constraint changes; all 7 git deps keep
  their current `github:` / `branch:` specs.
- `lib/jido_claw/core/mcp_server.ex` DSL usage — `Jido.MCP.Server`'s
  `__using__/1` still accepts `publish: %{tools: [...]}` upstream (verified
  against `main@ece85aaf74`'s `lib/jido_mcp/server.ex`).

## End-to-end verification

After Step 3, in order:

1. `mix compile --warnings-as-errors` — clean. "Redefining module" noise is
   silenced by `ignore_module_conflict: true`. Expected redefinitions: 3
   `Jido.Shell.*` (always) + 0 or 1 `Anubis.Server.Handlers.Tools` (depending
   on whether the smoke test forced the fallback).
2. `mix test` — 1268/1268 pass, 10 `:docker_sandbox` excluded, + 1 new canary
   test from Step 2.
3. `mix hex.outdated` — unchanged from baseline (all hex deps current).
4. MCP stdio smoke test (handshake-correct version above) — returns two valid
   JSON results, second includes `mix.exs` content.
5. `mix jidoclaw` REPL — launches, run a shell-backed command to exercise the
   surviving shell patches.
6. **Format check** — AGENTS.md claims `mix format --check-formatted` is CI-enforced,
   but this project has no `.formatter.exs`. The command fails with "expected
   one or more files/patterns to be given". Out of scope for this plan, but
   worth raising separately — the AGENTS.md assertion is currently false. If
   you want it addressed here, say so and I'll add a standard `.formatter.exs`
   as a separate step-zero commit before any dep work.

## Commit plan (slicing guidance — do not commit without explicit request)

Three commits align with the three steps:

1. `chore(deps): update jido_memory to <new-sha>`
2. `chore(deps): update jido_messaging to <new-sha>` — includes the new canary
   test.
3. Headline depends on the Step 3 outcome:
   - **Best case** (both patches gone): `refactor(mcp): retire anubis_mcp
     0.17.1 patches on jido_mcp upgrade`
   - **Fallback** (slimmer tools-handler patch stays): `refactor(mcp):
     upgrade jido_mcp; retire anubis stdio patch, port tools-handler patch
     to anubis 1.1`

   Either way the commit bundles: `jido_mcp` SHA bump + `anubis_mcp`
   transitive bump, stdio patch deletion, tools-handler patch deletion or
   replacement, `mix.exs` comment rewrite, `AGENTS.md` edit, both
   `docs/ROADMAP.md` edits, and the three shell-patch header rewrites.

Per the standing rule in memory, no commits run without an explicit request.
