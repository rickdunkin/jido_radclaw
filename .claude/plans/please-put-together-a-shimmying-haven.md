# Phase 3c — Memory: Codex Sibling Runner

## Context

Phase 3b shipped `JidoClaw.Memory.Consolidator` with a `harness:` config knob that
accepts `:claude_code | :codex | :fake`, but `:codex` is a stub
(`run_server.ex:310` returns `{:error, "no_runner_configured"}`). 3c adds the
actual `JidoClaw.Forge.Runners.Codex` so operators can swap harnesses without
touching consolidator code, and the per-run `ConsolidationRun.harness` row
records which CLI produced the proposals.

The plan doc at `docs/plans/v0.6/phase-3c-memory-codex.md` was written against
assumptions that don't all hold against the actual Codex CLI surface (cloned at
`~/workspace/claws/codex`) and the actually-shipped 3b code. Notable corrections
are in **Plan-doc deltas** below; user has decided each open question (see
**Decisions made**); review feedback is folded into **Review pass corrections**.

## State of the world (post-research)

### Already shipped in 3b — reuse as-is

- `ConsolidationRun` Ash resource — `@harnesses [:claude_code, :codex, :fake]`
  (`lib/jido_claw/memory/resources/consolidation_run.ex:39`). `error` column is
  `:string` with no enum constraint, so new reasons need no migration.
- `RunServer.resolved_harness/0`
  (`lib/jido_claw/memory/consolidator/run_server.ex:306-313`) with the
  `:codex -> {:error, "no_runner_configured"}` gate. `spawn_harness_task/2`
  (315-356), `base_runner_config/2` (416-427), `MCPEndpoint.start_link/1`
  (318), `write_mcp_config/2` (435).
- Per-run Bandit endpoint (`MCPEndpoint`/`Plug`) and 11 proposal tools — harness-agnostic.
- `Forge.Runner` behaviour, `Forge.Harness.resolve_runner/1` dispatch table,
  `Forge.Sandbox.{Local,Docker}` with `inject_env/2`, `run/4`, `exec/3`,
  `write_file/3`.
- `:fake` runner (`lib/jido_claw/forge/runners/fake.ex`) — harness-agnostic
  by construction.
- `Cron.Scheduler.start_system_jobs/0` + `SystemJobsInitializer` — boot wiring complete.

### Plan-doc deltas (corrections vs. `phase-3c-memory-codex.md`)

1. **Auth file is `~/.codex/auth.json`**, not `credentials.json`.
2. **`run_now/2` `:harness` override "added in 3b" does not exist.** Only
   `:await_ms`, `:override_min_input_count`, `:fake_proposals` are accepted
   (`lib/jido_claw/memory/consolidator.ex:43-49`). 3c adds `:harness`.
3. **`:no_credentials` is documented for ClaudeCode in 3b but not implemented**
   — `sync_host_claude_config/1` silently no-ops on missing `~/.claude`. Per
   **Decisions made #2**, 3c retro-fits ClaudeCode for parity.
4. **`:runner_unavailable` is not a path** — Codex configured today returns
   `"no_runner_configured"`, not `"runner_unavailable"`. 3c adds this when
   the `codex` binary is absent from `$PATH`.
5. **Codex CLI flag surface differs sharply from Claude Code's** (next section).

### Codex CLI surface (verified against `~/workspace/claws/codex`)

| Claude Code | Codex |
| --- | --- |
| `claude -p PROMPT` | `codex exec [PROMPT]` (subcommand; PROMPT is positional) |
| `--model NAME` | `-m NAME` |
| `--mcp-config FILE` | **None.** `[mcp_servers.<name>]` in `$CODEX_HOME/config.toml`, or `-c 'mcp_servers.NAME.url="…"'` |
| `--output-format stream-json` | `--json` (alias `--experimental-json`) |
| `--max-turns N` | **No analogue** — verified by exhaustive grep. Rely on `timeout_ms`. |
| `--dangerously-skip-permissions` | `--dangerously-bypass-approvals-and-sandbox` (Forge already isolates). `codex exec` headless mode already defaults approval policy to `Never`, so `-a` is unnecessary. |
| Auth at `~/.claude/credentials.json` | Auth at `~/.codex/auth.json` (mode 600) |
| (no equivalent) | `CODEX_HOME=/path` relocates BOTH `config.toml` and `auth.json` (`utils/home-dir/src/lib.rs:13-63`). Path **must exist as a directory** or Codex errors. |
| (no equivalent) | `--ephemeral` (no session persistence), `--skip-git-repo-check`, `--ignore-rules`, `-C DIR` |

`--ignore-rules` disables `$CODEX_HOME/rules/` (and project `.rules`) — so
syncing `rules/` from host is inert if we pass that flag. The runner doesn't
sync `rules/`. AGENTS.md is read by Codex from the working directory (`-C
/var/local/forge`), not `$CODEX_HOME` — so syncing `~/.codex/AGENTS.md` is
inert too. The runner doesn't sync `AGENTS.md` either. Whitelist is
intentionally tiny.

### `[mcp_servers.<name>]` TOML schema (verified)

`config/src/mcp_types.rs:362-392` defines `McpServerTransportConfig` as
`#[serde(untagged)]` with stdio (`command` key) vs streamable_http (`url` key).
**No `transport = "..."` discriminator.** Streamable-HTTP minimum:

```toml
[mcp_servers.consolidator]
url = "http://127.0.0.1:<port>/run/<run_id>"
```

Mixing `command` and `url` is rejected (`mcp_types.rs:283-326`). Inline TOML
matches `codex mcp add` output (`mcp_edit_tests.rs:60-76`). `-c
'mcp_servers.consolidator.url="..."'` works as a per-invocation override
(`utils/cli/src/config_override.rs:18-37`).

### `codex exec --json` event schema (verified)

`exec/src/exec_events.rs:9-37` — top-level `ThreadEvent` JSONL types:
`thread.started`, `turn.started`, `turn.completed`, `turn.failed`,
`item.started`, `item.updated`, `item.completed`, `error`.

**Two `"type"` keys per line** — outer top-level + inner `item.type` via
`#[serde(flatten)]`. Item subtypes: `agent_message`, `reasoning`,
`command_execution`, `file_change`, `mcp_tool_call`, `collab_tool_call`,
`web_search`, `todo_list`, `error`.

**No `"result"` event with `subtype`.** `turn.completed` (with `usage`)
signals success; `turn.failed` carries `{ error: { message } }`. **Interruption
emits nothing** (`event_processor_with_jsonl_output.rs:544-548`). No
per-token streaming on `--json`; assistant text appears once in
`item.completed { item.type: "agent_message" }`.

`McpToolCallItem` (lines 279-288): `{ server, tool, arguments, result, error,
status }`. Tool invocation/result share an `item.id`: `item.started` (status
`in_progress`) → `item.completed` (status `completed|failed`).

## Decisions made (from AskUserQuestion exchange)

1. **MCP injection — Hybrid: sync host config.toml, append consolidator block.**
   See **Review pass corrections #4** for race-fix: per-session `CODEX_HOME` so
   concurrent runs don't trample each other.
2. **`:no_credentials` — retro-fit ClaudeCode for parity.** Both runners' `init/2`
   return `{:error, :no_credentials}` when host home or auth file is missing.
3. **Cross-harness §3.19 test — add `:harness` override to `run_now/2`.**
4. **Parser depth — mirror ClaudeCode shape.** Codex events get adapted into
   the same `metadata.tool_events` map shape.

## Review pass corrections (folded into the plan below)

These came out of two careful reads of the actual call-paths after earlier
drafts. Each is specifically addressed in the file-by-file changes:

1. **`:no_credentials` doesn't propagate via `Forge.Manager.start_session/2`.**
   `start_session` returns `{:ok, pid}` once the supervisor child boots; runner
   `init/2` runs later in `Harness.handle_info(:init_runner)` (`harness.ex:262`).
   On `{:error, :no_credentials}`, the harness `:stop`s with reason
   `{:runner_init_failed, :no_credentials}` (harness.ex:296). The runner-side
   await currently sees a generic `:DOWN` and produces
   `"harness_died_during_bootstrap: ..."` (`run_server.ex:397-398`). 3c
   teaches `await_ready/3` to pattern-match `{:runner_init_failed, reason}`
   and surface `reason` as a clean error string (`"no_credentials"`,
   `"runner_unavailable"`). Other DOWN reasons fall through to the existing
   string.

2. **Effective harness/model must be persisted at the EARLIEST point — in
   `handle_call({:await_and_start, opts}, ...)` — not at spawn time.**
   The success-path row write at `run_server.ex:594` and the
   failure-path `write_run_row/3` at `:969` currently call
   `Keyword.get(consolidator_config(), :harness, :claude_code)` and
   `model_from_config()` (defined at line 1047), ignoring any `run_now/2`
   `:harness` override. **And** skip rows (`:below_min_input_count`,
   `:scope_busy`, `PolicyResolver` skips) finalise BEFORE
   `spawn_harness_task/2` runs, so populating effective values there
   would leave skip rows with the old app-env behaviour. 3c sets both
   `effective_harness` and `effective_harness_model` in
   `handle_call({:await_and_start, opts}, ...)` (run_server.ex:90),
   immediately after `state.opts` is captured, then both row-write sites
   read from state.

3. **`harness_model` capture must not depend on `runner_config.model`.**
   `base_runner_config(:fake, _)` is `%{fake_proposals: []}` (no `:model` key),
   so deriving model from runner_config breaks the cross-harness regression
   test. 3c computes
   `effective_model = Map.get(runner_config, :model) || Keyword.get(harness_options, :model)`
   at gate time — works for every harness including `:fake`.

4. **Per-run `forge_home` AND per-run `codex_home` to avoid
   concurrent-run races.** Even with per-session `CODEX_HOME`, the
   shared `/var/local/forge/session/{context.md,response.json}` path
   is overwritten across concurrent runs. `Sandbox.Local` writes
   absolute paths to the host filesystem (`local.ex:36, 119-128`).
   3c roots **everything** under a per-run dir:
   `forge_home = Path.join(base_forge_home, forge_session_id)` and
   `codex_home = "#{forge_home}/.codex"`. Both runners take
   `runner_config.forge_home` and `runner_config.codex_home` from
   the consolidator. ClaudeCode gets the same per-run isolation as
   parity (it currently uses the shared `/var/local/forge/.claude/`).

5. **Per-run forge dirs need cleanup after the harness has fully
   stopped.** With `Sandbox.Local`, absolute paths persist on the host
   filesystem after `Forge.Manager.stop_session/2` runs (the Local
   backend's `destroy/2` only removes the sandbox tmpdir at
   `local.ex:163-168`, not arbitrary absolute write-targets). 3c
   handles cleanup inside `drive_harness/4` after
   `maybe_stop_forge_session/1` (NOT in `RunServer.cleanup/1`, which
   would race the still-exiting CLI). The cleanup is wrapped in an
   outer `try`/`after` so it runs even when
   `Forge.Manager.start_session/2` fails with `:at_capacity`,
   `:runner_at_capacity`, or `:already_exists` — see §3f for the
   actual code shape. For `:docker` mode, container destruction
   handles cleanup; the host-side `File.rm_rf` is harmless.

6. **`Forge.Manager.max_per_runner` needs a `:codex` entry.** Without it,
   the `Map.get(state.max_per_runner, :codex, state.max_sessions)`
   fallback at `manager.ex:83` makes Codex runs share the global
   `max_sessions: 50` cap instead of the intended per-runner throttle.
   3c adds `:codex => 10` in both the defstruct default
   (`manager.ex:15`) and the `init/1` default (`manager.ex:68-73`).

7. **Consolidator prompt-rendering is missing in 3b code.** Verified by
   grepping the entire `lib/jido_claw/memory/consolidator/` and
   `test/`: zero references to a consolidator prompt builder,
   zero `:prompt` keys in the runner_config built by
   `spawn_harness_task/2`, and `drive_harness/4` calls
   `Forge.Harness.run_iteration(forge_session_id, timeout: timeout_ms)`
   without `:prompt` in opts. So `runner.run_iteration` falls back to
   `state.prompt = ""`. The 3b suite passes because `:fake` ignores
   prompt and just executes hard-coded `fake_proposals`. **Real CLI
   harnesses would invoke the model with an empty prompt.** 3c closes
   this with a NEW module
   `JidoClaw.Memory.Consolidator.Prompt.build/1` that takes the
   gated/clustered RunServer state and emits the consolidator system
   prompt (scope summary, cluster listings, available tool names,
   committing rules). `spawn_harness_task/2` puts the rendered string
   into `runner_config.prompt`; both runners' `init/2` already read
   `Map.get(config, :prompt, "")` into `state.prompt`. This NEW
   module is small but new scope; flagged in **Open questions** so
   the operator can confirm 3c is the right phase to land it (vs. a
   3b follow-up).

8. **Tests must not exercise `parse_output/1` directly** (it's
   private). Test it through `run_iteration/3` with a stub sandbox
   that returns canned JSONL. Init-happy-path tests need `forge_home`
   and `codex_home` injectable so they don't write to
   `/var/local/forge/...` on the host. 3c makes both runners read
   `Application.get_env(:jido_claw, :forge_home, "/var/local/forge")`
   for the base, then derive per-run dirs from `forge_session_id`.

9. **Codex sync whitelist tightened.** `--ignore-rules` makes a synced
   `rules/` directory inert; Codex reads project AGENTS.md from `-C
   cwd`, not `$CODEX_HOME`. The whitelist becomes `~w(auth.json
   config.toml)` — nothing else carries weight under `$CODEX_HOME`
   for our use.

10. **`-a never` removed from the argv.** `codex exec` headless mode
    already defaults approval policy to `Never` per the upstream
    source (no need for `-a`). 3c uses
    `--dangerously-bypass-approvals-and-sandbox` (the literal
    Codex-side analogue of ClaudeCode's
    `--dangerously-skip-permissions`) — Forge already isolates, so
    Codex's own sandbox layer is redundant.

11. **Canonical error string is `"runner_unavailable"`** (not
    `"codex_runner_unavailable"`). Pattern-fixed throughout the runner
    sketch. Also fixed `_client` typo in `append_consolidator_mcp/2`.

12. **Parser fallback for exit-0 with no terminal event.** If the
    JSONL stream ends without a `turn.completed`, `turn.failed`, or
    top-level `error` line (e.g., interrupted before a turn finished),
    fall back to `Runner.done(output)` so the harness reports normal
    completion. This matches ClaudeCode's behaviour where a missing
    `result` event also defaults to `Runner.done(output)`.

## File-by-file changes

### 1. NEW: `lib/jido_claw/forge/runners/codex.ex` (~220 LOC)

Mirror `claude_code.ex`. Key shape:

```elixir
defmodule JidoClaw.Forge.Runners.Codex do
  @behaviour JidoClaw.Forge.Runner
  alias JidoClaw.Forge.{Runner, Sandbox}
  alias JidoClaw.Security.Redaction.PromptRedaction
  require Logger

  # Whitelist trimmed: rules/ is inert under --ignore-rules; AGENTS.md is
  # read from `-C cwd`, not $CODEX_HOME. Auth + config are the only files
  # that actually move the needle.
  @syncable_entries ~w(auth.json config.toml)
  @auth_file "auth.json"
  @consolidator_server_name "consolidator"

  @impl true
  def init(client, config) do
    # forge_home/codex_home are optional in runner_config so direct
    # Forge users (not the consolidator) still work. Defaults match
    # the pre-3c shared path so direct callers see no behaviour
    # change and have no new cleanup obligation. The consolidator
    # opts INTO per-run isolation by passing per-run paths via
    # runner_config (see RunServer §3b).
    forge_home = Map.get(config, :forge_home, default_forge_home())
    codex_home = Map.get(config, :codex_home, "#{forge_home}/.codex")
    mcp_url = Map.get(config, :mcp_server_url)
    prompt = Map.get(config, :prompt, "")

    # 1. mkdir per-run sandbox dirs.
    for dir <- ["#{forge_home}/session", "#{forge_home}/templates", codex_home] do
      Sandbox.exec(client, "mkdir -p #{dir}", [])
    end

    # 2. sync host ~/.codex/{auth.json,config.toml} → :ok | {:error, :no_credentials}
    case sync_host_codex_config(client, codex_home) do
      :ok ->
        # 3. append [mcp_servers.consolidator] block to per-run config.toml
        append_consolidator_mcp(client, codex_home, mcp_url)

        # 4. optional redacted prompt drop (parity with ClaudeCode)
        if prompt != "" do
          Sandbox.write_file(client,
            "#{forge_home}/session/context.md", PromptRedaction.redact(prompt))
        end

        # 5. inject CODEX_HOME so codex finds the per-run config.toml + auth.json
        Sandbox.inject_env(client, %{"CODEX_HOME" => codex_home})

        {:ok,
         %{
           model: Map.get(config, :model, "gpt-5-codex"),
           prompt: prompt,
           iteration: 0,
           max_turns: Map.get(config, :max_turns, 60),  # state symmetry only; no Codex flag
           timeout_ms: Map.get(config, :timeout_ms, 600_000),
           codex_home: codex_home,
           forge_home: forge_home,
           session_name: Map.get(config, :session_name)
         }}

      {:error, :no_credentials} = err ->
        err
    end
  end

  @impl true
  def run_iteration(client, state, opts) do
    redacted_prompt = PromptRedaction.redact(Keyword.get(opts, :prompt, state.prompt))

    args = [
      "exec",
      "-m", state.model,
      "--dangerously-bypass-approvals-and-sandbox",  # Forge already isolates
      "--json",
      "--ephemeral",
      "--skip-git-repo-check",
      "--ignore-rules",
      "-C", state.forge_home,
      redacted_prompt
    ]

    timeout_ms = Keyword.get(opts, :timeout, state.timeout_ms)
    run_opts = [timeout: timeout_ms]
    run_opts = if state.session_name, do: [{:name, state.session_name} | run_opts], else: run_opts

    case Sandbox.run(client, "codex", args, run_opts) do
      {output, 0}     -> parse_output(output)
      {_, :timeout}   -> {:ok, Runner.error("harness_timeout", "")}
      {output, 127}   -> {:ok, Runner.error("runner_unavailable", output)}
      {output, _code} -> {:ok, Runner.error("codex cli failed", output)}
    end
  end

  @impl true
  def apply_input(client, input, state) do
    Sandbox.write_file(client, "#{state.forge_home}/session/response.json",
                       Jason.encode!(%{response: input}))
    :ok
  end

  defp sync_host_codex_config(client, codex_home) do
    host_codex = host_codex_dir()
    auth_path = Path.join(host_codex, @auth_file)

    cond do
      not File.dir?(host_codex) -> {:error, :no_credentials}
      not File.regular?(auth_path) -> {:error, :no_credentials}
      true ->
        Enum.each(@syncable_entries, fn entry ->
          source = Path.join(host_codex, entry)
          dest = "#{codex_home}/#{entry}"
          if File.regular?(source), do: sync_file(client, source, dest)
        end)
        :ok
    end
  end

  defp append_consolidator_mcp(client, codex_home, url)
       when is_binary(url) and url != "" do
    block = """

    [mcp_servers.#{@consolidator_server_name}]
    url = "#{url}"
    """
    encoded = Base.encode64(block)
    Sandbox.exec(client,
      "echo '#{encoded}' | base64 -d >> #{codex_home}/config.toml", [])
  end
  defp append_consolidator_mcp(_client, _codex_home, _), do: :ok

  defp parse_output(output) do
    # Mirror claude_code.ex parse_output/1 shape: collect tool_events into
    # metadata, dispatch :done | :error based on the terminal turn event.
    #
    # Codex JSONL → ClaudeCode-shape mapping:
    #   {type: "thread.started"|"turn.started"} → drop (system noise)
    #   {type: "item.started",  item: {type: "mcp_tool_call", server, tool, arguments, ...}}
    #     → %{"type" => "tool_use", "name" => tool, "server" => server, "input" => arguments, "id" => item.id}
    #   {type: "item.completed", item: {type: "mcp_tool_call", result|error, status, ...}}
    #     → %{"type" => "tool_result", "tool_use_id" => item.id, "content" => result.content || error.message, "is_error" => status == "failed"}
    #   {type: "item.completed", item: {type: "agent_message", text}}
    #     → %{"type" => "assistant", "text" => text}
    #   {type: "item.completed", item: {type: "reasoning", text}}
    #     → %{"type" => "reasoning", "text" => text}
    #   {type: "turn.completed", usage}
    #     → terminal :done; usage stashed into metadata.usage
    #   {type: "turn.failed", error: {message}}
    #     → terminal :error with message
    #   {type: "error", message} (top-level fatal)
    #     → terminal :error with message
    #
    # Fallback: if no terminal turn.completed/turn.failed/error line is
    # observed (e.g., Codex was interrupted before a turn finished but
    # exit-0'd), default to Runner.done(output) — same posture as
    # ClaudeCode's missing-result branch (claude_code.ex:135-139).
    #
    # Result:
    #   {:ok, Runner.done(output) | %{base | metadata: tool_events ++ usage}}
    #   {:ok, Runner.error(error_message, output)}
    #
    # No :continue case (Codex has no max-turns).
  end

  defp sync_file(client, source, dest) do
    case File.read(source) do
      {:ok, content} ->
        encoded = Base.encode64(content)
        Sandbox.exec(client, "echo '#{encoded}' | base64 -d > #{dest}", [])
        # `echo > dest` uses the process umask (commonly 0644). Codex's
        # auth.json is mode 600 on host; preserve that posture in the
        # sandbox copy so it isn't world-readable.
        if Path.basename(dest) == @auth_file,
          do: Sandbox.exec(client, "chmod 600 #{dest}", [])

      {:error, reason} ->
        Logger.debug("[Codex] Skipping #{source}: #{reason}")
    end
  end

  # Default for direct (non-consolidator) Forge callers — preserves
  # the pre-3c shared path. No per-pid suffix, so direct callers
  # don't acquire a cleanup obligation they didn't have before.
  # Concurrent direct callers were always the caller's responsibility
  # (same as ClaudeCode); the consolidator opts INTO per-run isolation
  # via runner_config.forge_home.
  defp default_forge_home,
    do: Application.get_env(:jido_claw, :forge_home, "/var/local/forge")

  defp host_codex_dir,
    do: Application.get_env(:jido_claw, :codex_home_dir, "~/.codex") |> Path.expand()
end
```

### 2. EDIT: `lib/jido_claw/forge/runners/claude_code.ex`

Retro-fit `:no_credentials` and make paths injectable for parity (per
**Review pass corrections #6**).

- Update `sync_host_claude_config/1` to return `:ok | {:error,
  :no_credentials}`. `:no_credentials` when host dir is missing OR
  `credentials.json` is missing.
- Update `init/2` to early-return `{:error, :no_credentials}` BEFORE
  writing the pinned `settings.json` or `context.md`.
- Replace hard-coded `Path.expand("~/.claude")` (line 145) with
  `Application.get_env(:jido_claw, :claude_home_dir, "~/.claude") |>
  Path.expand()`.
- Replace `@forge_home "/var/local/forge"` (line 7) with the same
  optional-config-key pattern Codex uses:
  `forge_home = Map.get(config, :forge_home, default_forge_home())` in
  `init/2`, where `default_forge_home/0` derives a unique path under
  `Application.get_env(:jido_claw, :forge_home, "/var/local/forge")`.
  Store on state and reference from `apply_input/3`. Direct Forge
  callers without `:forge_home` in runner_config still work.
- In `sync_file/3`, after the base64 pipe, `chmod 600` the dest if it
  is `credentials.json` to preserve secret-file permissions
  (matches the new Codex `auth.json` posture).

### 3. EDIT: `lib/jido_claw/memory/consolidator/run_server.ex`

#### 3a. Un-stub `:codex` — resolver lifted into `resolve_effective_harness/1`

- The old `resolved_harness/0` (line 306) is replaced by the
  `resolve_effective_harness/1` helper introduced in §3b — called from
  both `handle_call({:await_and_start, ...})` AND
  `handle_continue(:invoke_harness, state)` (line 287). The
  `:codex -> {:error, "no_runner_configured"}` clause becomes a valid
  `:codex` accept; runner dispatch happens via
  `Forge.Harness.resolve_runner(:codex)` (file 5 below).
- `handle_continue(:invoke_harness, state)` reads
  `state.effective_harness` directly (set in §3b) instead of
  re-resolving.

#### 3b. Persist effective harness/model in state at the EARLIEST point

Add three state fields: `effective_harness :: atom()`,
`effective_harness_model :: String.t() | nil`, and `run_forge_home ::
String.t() | nil`. Populate `effective_harness` and
`effective_harness_model` in
`handle_call({:await_and_start, opts}, ...)` (run_server.ex:90) so they
are valid even for skip rows that finalise before
`spawn_harness_task/2` runs:

```elixir
def handle_call({:await_and_start, opts}, from, %{status: :idle} = state) do
  case resolve_effective_harness(opts) do
    {:ok, harness} ->
      send(self(), :gate)
      # harness_options is app-env only — there is no per-call override.
      # The cross-harness §3.19 test uses Application.put_env between
      # runs to vary the model.
      effective_harness_model =
        Keyword.get(consolidator_config(), :harness_options, [])
        |> Keyword.get(:model)

      {:noreply,
       %{state
         | status: :running,
           opts: opts,
           awaiters: [from],
           effective_harness: harness,
           effective_harness_model: effective_harness_model}}

    {:error, reason} ->
      # Fail fast — no ConsolidationRun row is written. The Ash resource
      # constraint at consolidation_run.ex:238 only accepts
      # [:claude_code, :codex, :fake], so writing a row with
      # :unresolved would fail validation. Surface the configuration
      # mistake directly to the caller instead.
      {:reply, {:error, reason}, state, {:continue, :stop}}
  end
end

# Same resolution logic resolved_harness/0 used to do, lifted to a function
# of opts so :await_and_start can call it before :gate.
defp resolve_effective_harness(opts) do
  override = Keyword.get(opts, :harness)
  global = Keyword.get(consolidator_config(), :harness, :claude_code)
  case override || global do
    h when h in [:claude_code, :codex, :fake] -> {:ok, h}
    other -> {:error, "unknown_harness:#{inspect(other)}"}
  end
end
```

`run_now/2` accepts ONE new public option: `:harness`. It does not
accept `:harness_options` per-call — anything model/timeout/sandbox
related stays app-env only. (Avoids hidden public surface.) The
cross-harness regression test uses `Application.put_env` between runs
to vary the model.

Then `spawn_harness_task/2` re-uses the already-set values from state and
populates per-run paths and prompt:

```elixir
defp spawn_harness_task(state, harness) do
  forge_session_id = Ecto.UUID.generate()
  {:ok, endpoint} = MCPEndpoint.start_link(state.run_id)
  temp_path = write_mcp_config(state.run_id, endpoint.url)

  base_forge = Application.get_env(:jido_claw, :forge_home, "/var/local/forge")
  run_forge_home = Path.join(base_forge, forge_session_id)
  codex_home = Path.join(run_forge_home, ".codex")

  # mkdir_p the per-run home here so the harness Task can rm_rf it
  # unconditionally on exit. With :fake or any runner that never calls
  # Sandbox.exec("mkdir -p ..."), the dir would otherwise not exist —
  # and the cleanup-existed-then-removed test would be vacuously true.
  # This also gives the runner a stable target if it skips its own
  # mkdir step.
  if sandbox_mode == :local do
    File.mkdir_p!(run_forge_home)
  end

  harness_options = Keyword.get(consolidator_config(), :harness_options, [])
  timeout_ms = Keyword.get(harness_options, :timeout_ms, 600_000)
  sandbox_mode = Keyword.get(harness_options, :sandbox_mode, :local)

  runner_config =
    base_runner_config(harness, harness_options)
    |> Map.put(:mcp_config_path, temp_path)         # ClaudeCode-only
    |> Map.put(:mcp_server_url, endpoint.url)       # Codex-only
    |> Map.put(:forge_home, run_forge_home)
    |> Map.put(:codex_home, codex_home)
    |> Map.put(:prompt, JidoClaw.Memory.Consolidator.Prompt.build(state))
    |> maybe_add_fake_proposals(harness, state.opts)

  # If runner_config landed a model the resolver didn't see (because
  # base_runner_config supplied one), refine effective_harness_model.
  effective_model =
    Map.get(runner_config, :model) || state.effective_harness_model

  spec = %{runner: harness, runner_config: runner_config, sandbox: sandbox_mode}
  parent = self()
  task = Task.Supervisor.async_nolink(
    JidoClaw.Memory.Consolidator.TaskSupervisor,
    fn -> drive_harness(parent, forge_session_id, spec, timeout_ms) end)

  {:noreply,
   %{state
     | mcp_endpoint: endpoint,
       temp_file_path: temp_path,
       forge_session_id: forge_session_id,
       harness_task_ref: task.ref,
       harness_task_pid: task.pid,
       run_forge_home: run_forge_home,
       effective_harness_model: effective_model}}
end
```

#### 3c. Add `:codex` clause to `base_runner_config/2`

```elixir
defp base_runner_config(:codex, opts) do
  %{
    model: Keyword.get(opts, :model, "gpt-5-codex"),
    max_turns: Keyword.get(opts, :max_turns, 60),
    timeout_ms: Keyword.get(opts, :timeout_ms, 600_000)
  }
end
```

(Default model TBD; placeholder pending operator confirmation — see
**Open questions**.)

#### 3d. Map runner-init failures to clean error strings in `await_ready/3`

Current shape (lines 389-404):

```elixir
{:DOWN, ^ref, :process, _, reason} ->
  {:error, "harness_died_during_bootstrap: #{inspect(reason)}"}
```

Replace with:

```elixir
{:DOWN, ^ref, :process, _, {:runner_init_failed, init_reason}} ->
  {:error, runner_init_error_string(init_reason)}

{:DOWN, ^ref, :process, _, reason} ->
  {:error, "harness_died_during_bootstrap: #{inspect(reason)}"}
```

with helper:

```elixir
defp runner_init_error_string(:no_credentials), do: "no_credentials"
defp runner_init_error_string(:runner_unavailable), do: "runner_unavailable"
defp runner_init_error_string(other),
  do: "runner_init_failed: #{inspect(other)}"
```

This is what closes the `:no_credentials` path: runner `init/2` returns
`{:error, :no_credentials}` → `Forge.Harness` `:stop`s with reason
`{:runner_init_failed, :no_credentials}` (harness.ex:296) → `await_ready`
returns `{:error, "no_credentials"}` → `drive_harness` propagates it →
RunServer's task-DOWN handler writes `error: "no_credentials"` on the
`ConsolidationRun` row.

#### 3e. Read harness/model from state in row writes

Both row-write sites read from state, eliminating the app-env fallback
entirely (state values are guaranteed populated by §3b's
`handle_call({:await_and_start, opts}, ...)` edit, which fires before
any `finalise/3` path):

- **Line 594** (`do_publish/1` success path):
  ```elixir
  harness: state.effective_harness,
  harness_model: state.effective_harness_model
  ```
- **Line 969** (`write_run_row/3` failure/skip path): same.
- The `model_from_config/0` helper at line 1047 can be deleted; both
  call sites now read from state.

#### 3f. Cleanup of per-run forge dir — outer try/after in `drive_harness/4`

The forge dir cannot be removed in `cleanup/1` — that runs from
`finalise/3`, which `commit_proposals` triggers as soon as the
proposals are staged. The CLI process may still be unwinding (codex
exec exiting, file handles closing, last writes flushing) when
`cleanup/1` fires; `File.rm_rf` racing the still-running process
risks corrupted writes or "directory not empty" failures.

Cleanup must also run when `Forge.Manager.start_session/2` itself
fails (`:at_capacity`, `:runner_at_capacity`, `:already_exists`) —
because §3b already created the dir before the Task started. So the
cleanup is wrapped in an outer `try`/`after` covering BOTH the
start-session-failed path AND the start-session-succeeded path:

```elixir
defp drive_harness(_parent, forge_session_id, spec, timeout_ms) do
  :ok = JidoClaw.Forge.PubSub.subscribe(forge_session_id)
  run_forge_home = spec.runner_config[:forge_home]

  try do
    case JidoClaw.Forge.Manager.start_session(forge_session_id, spec) do
      {:ok, %{pid: pid}} ->
        try do
          with :ok <- await_ready(forge_session_id, pid, bootstrap_timeout(timeout_ms)),
               result <- JidoClaw.Forge.Harness.run_iteration(forge_session_id, timeout: timeout_ms) do
            result
          else
            {:error, reason} -> {:error, reason}
          end
        rescue
          e -> {:error, Exception.message(e)}
        catch
          :exit, reason -> {:error, inspect(reason)}
        after
          maybe_stop_forge_session(forge_session_id)
          # AFTER stop_session — the harness is supervisor-terminated
          # so the CLI process has been signalled and the sandbox is
          # no longer being written to.
        end

      {:error, reason} ->
        {:error, reason}
    end
  after
    # Outer cleanup catches the start-session-failed path too, where
    # the dir was created by spawn_harness_task/2 but no harness ever
    # touched it. Best-effort: a missing dir is fine.
    if run_forge_home, do: File.rm_rf(run_forge_home)
  end
end
```

`cleanup/1` (run_server.ex:984-989) is left unchanged for the
`run_forge_home` concern. (It still releases the lock, stops the MCP
endpoint, and removes the host-side temp file as before.)

For `:docker` sandbox mode, `Sandbox.Docker.destroy/2` already handles
the container, so the host-side `run_forge_home` either doesn't exist
(writes went into the container) or is harmless to remove. The
`File.rm_rf` is best-effort for both modes.

### 4. EDIT: `lib/jido_claw/memory/consolidator.ex`

- Add `:harness` to the `run_now/2` `@doc` options block (lines 43-49).
- Threading: option already in `opts`, reaches GenServer via
  `{:await_and_start, opts}` (line 58); RunServer reads from `state.opts`
  per §3a/§3b above.

### 4a. NEW: `lib/jido_claw/memory/consolidator/prompt.ex`

The consolidator's existing harness invocation has no prompt rendering
(verified in **Review pass corrections #7**). 3c adds:

```elixir
defmodule JidoClaw.Memory.Consolidator.Prompt do
  @moduledoc """
  Renders the consolidator system prompt from a gated/clustered
  RunServer state. Output is a single string passed to the harness via
  runner_config.prompt; both ClaudeCode and Codex runners read it into
  state.prompt during init/2.
  """

  alias JidoClaw.Memory.Scope

  @spec build(state :: map()) :: String.t()
  def build(state) do
    """
    You are the JidoClaw memory consolidator. Your job is to review the
    clustered memory inputs below and propose mutations using the
    available MCP tools, then commit them.

    ## Scope
    #{render_scope(state.scope)}

    ## Available tools (MCP server "consolidator")
    - list_clusters / get_cluster — inspect clusters
    - get_active_blocks — see existing block-level summaries
    - find_similar_facts — dedup against existing facts
    - propose_add / propose_update / propose_delete — fact mutations
    - propose_block_update — block-level summary writes
    - propose_link — fact↔fact links (#{link_relations()})
    - defer_cluster — postpone a cluster to a later run
    - commit_proposals — call EXACTLY ONCE when done; this finalises the run

    ## Clusters in this run
    #{render_clusters(state.clusters || [])}

    Behaviour:
    - Inspect clusters with list_clusters / get_cluster before proposing.
    - Use find_similar_facts to avoid duplicates.
    - When done, call commit_proposals once. Do not keep iterating after.
    """
  end

  defp render_scope(%{scope_kind: kind} = s),
    do: "#{kind} (tenant=#{s.tenant_id}, fk=#{Scope.primary_fk(s)})"

  defp render_clusters(clusters), do: # iterate, render id/type/size

  defp link_relations,
    do: ~w(supports contradicts supersedes duplicates depends_on related)
        |> Enum.join(", ")
end
```

The exact body wording is operator-tunable later (it's just a system
prompt). The structural commitment is: a single `build/1` function
that consumes RunServer state and emits a string.

**Bounded body:** `Prompt.build/1` renders cluster id/type/size only —
**not** full message/fact bodies. The model has `list_clusters` /
`get_cluster` MCP tools to fetch detail on-demand. Inlining bodies
would balloon prompts unbounded with the input set, increase token
cost without proportional benefit, and pull more user content
(potentially containing redacted-but-still-sensitive substrings)
into the model's context than necessary. Detail goes through the
MCP tool path; the prompt is a roster + behaviour contract.

**This is genuinely new scope** — see **Open questions** for whether
to land here vs. as a 3b follow-up.

### 5. EDIT: `lib/jido_claw/forge/harness.ex`

- Add `defp resolve_runner(:codex), do: JidoClaw.Forge.Runners.Codex`
  adjacent to the existing `:claude_code` clause (~lines 1131-1136).

### 6. EDIT: `lib/jido_claw/forge/manager.ex`

Add `:codex` to the per-runner capacity defaults (per **Review pass
corrections #5**):

- **Line 15** (defstruct): `max_per_runner: %{claude_code: 10, codex: 10,
  shell: 20, workflow: 10, fake: 10}`.
- **Lines 68-73** (init opts default): same map.

### 7. EDIT: `lib/jido_claw/forge/sandbox/docker.ex`

- `sandbox_agent_type/1` (line 224-230): add `:codex -> "codex"` (assumes
  the `sbx` toolchain has a `codex` agent image; flagged in **Open
  questions**).
- Docker sandbox for Codex remains operator-validated only.

### 8. CONFIG: `config/config.exs:285`

- Update the `harness:` comment to reflect that `:codex` is now functional.

## Tests

### NEW: `test/jido_claw/forge/runners/codex_test.exs`

All tests use `Application.put_env(:jido_claw, :forge_home, tmp_dir)` and
`Application.put_env(:jido_claw, :codex_home_dir, tmp_host_dir)` to isolate
filesystem effects, plus a stub Sandbox (or real `Sandbox.Local` rooted at
the tmp dir).

- **`init/2` — no_credentials when host dir missing.** Set
  `:codex_home_dir` to a non-existent path; assert `{:error, :no_credentials}`
  and that `Sandbox.write_file` was never invoked for the appended config
  block.
- **`init/2` — no_credentials when host dir exists but `auth.json` missing.**
- **`init/2` — happy path.** Tmpdir with `auth.json` + minimal `config.toml`.
  Assert sync wrote both into `<forge_home>/.codex-<session_id>/`, the
  consolidator block was appended, and `CODEX_HOME` was injected.
- **`run_iteration/3` — argv shape.** Stub Sandbox captures the argv passed
  to `Sandbox.run/4`; assert flag list matches expectation including
  positional prompt last.
- **`run_iteration/3` — exit-127 → `runner_unavailable`.** Stub returns
  `{"codex: command not found", 127}`; assert
  `Runner.error("runner_unavailable", _)`.
- **Parser exercised through `run_iteration/3` with stub-sandbox JSONL
  fixtures** (per **Review pass corrections #8** — `parse_output/1` is
  private):
  - Sample stream with `thread.started`, `item.started` (mcp_tool_call),
    `item.completed` (mcp_tool_call w/ result), `item.completed`
    (agent_message), `turn.completed`. Assert `metadata.tool_events` has
    **3 entries** — `tool_use`, `tool_result`, `assistant` (the
    `thread.started` and `turn.started` events are dropped as system
    noise per the mapping table). Assert iteration_result is `:done`
    and `metadata.usage` is captured from `turn.completed`.
  - `turn.failed` stream → `:error` with `error.message`.
  - **Stream with no terminal event** (interrupted, exit-0) →
    `:done` (parser fallback per **Review pass corrections #12**).

### NEW: `test/jido_claw/forge/runners/claude_code_test.exs`

For parity (none currently exist for ClaudeCode runner).

- **`init/2` — no_credentials when `~/.claude` dir missing.**
- **`init/2` — no_credentials when `credentials.json` missing.**
- **`init/2` — happy path.** Same isolation pattern (`:claude_home_dir`,
  `:forge_home`).

### NEW: `test/jido_claw/memory/consolidator/prompt_test.exs`

Pure unit tests for `JidoClaw.Memory.Consolidator.Prompt.build/1`:

- A workspace-scope state with two clusters (one fact, one message)
  produces a string that mentions the scope, both cluster ids, and the
  full set of available tool names. Snapshot-style assertion on
  required substrings — not byte-for-byte equality (the prompt body
  is operator-tunable later without test churn).
- An empty-clusters state still produces a valid prompt (still lists
  tools, still mentions scope) — defends against an edge-case
  empty-input run.

### EXTEND: `test/jido_claw/memory/consolidator/run_server_test.exs`

- **`runner_config.prompt` reaches the runner.** `:fake` ignores
  `prompt`, defeating an end-to-end assertion. Mocking `Manager.start_session/2`
  is also clumsy (project does not currently use meck/Mox against
  concrete modules). Cleaner: introduce a tiny test-only runner
  `JidoClaw.Memory.Consolidator.TestSupport.PromptCapture` (lives
  under `test/support/`) that implements `JidoClaw.Forge.Runner` and
  records `runner_config.prompt` in an Agent the test reads:

  ```elixir
  defmodule JidoClaw.Memory.Consolidator.TestSupport.PromptCapture do
    @behaviour JidoClaw.Forge.Runner
    @impl true
    def init(_client, config) do
      Agent.update(__MODULE__.Store, fn _ -> Map.get(config, :prompt) end)
      {:ok, %{prompt: Map.get(config, :prompt, "")}}
    end
    @impl true
    def run_iteration(_client, _state, _opts),
      do: {:ok, JidoClaw.Forge.Runner.done("")}
    @impl true
    def apply_input(_client, _input, _state), do: :ok
  end
  ```

  Wire it via a private `:runner_module` opt to `run_now/2`
  (test-only; not in `@doc`). RunServer reads `state.opts[:runner_module]`
  in `spawn_harness_task/2` and, when present, sets
  `spec.runner = module` directly, bypassing
  `Forge.Harness.resolve_runner/1`. Test asserts the Agent observed
  the expected scope-summary substring. This pins the wiring without
  requiring meck or modifying `Manager`.

- **Cross-harness `harness`/`harness_model` capture.** Two consecutive
  `run_now(scope, harness: :fake, fake_proposals: [], …)` calls with
  different `harness_options[:model]` (set via `Application.put_env`
  between runs). Assert two `ConsolidationRun` rows, distinct
  `harness_model`. With the §3.b/3.e edits, `effective_harness_model`
  flows from `harness_options[:model]` because `:fake`'s
  `runner_config` has no `:model` key — the test pins the
  `Map.get(...) || Keyword.get(...)` fallback.
- **`:no_credentials` egress (Codex).** `Application.put_env(:jido_claw,
  :codex_home_dir, empty_tmpdir)`, `run_now(scope, harness: :codex,
  override_min_input_count: true)`. Assert resulting `ConsolidationRun`
  row has `status: :failed, error: "no_credentials"` and that the runner
  reached `init/2` (so `Forge.Manager.start_session/2` did succeed) but
  the harness died with `{:runner_init_failed, :no_credentials}` —
  verifiable by inspecting `forge_session_id` (non-nil) on the row.

- **Per-run forge_home cleanup.** Drive a successful `:fake` run in
  a tmpdir-rooted `:forge_home` with `sandbox_mode: :local`. Because
  `spawn_harness_task/2` `mkdir_p!`s the per-run dir up-front
  (regardless of which runner runs), `:fake` is a valid driver here:
  - Before `run_now/2` returns: assert
    `<forge_home>/<forge_session_id>/` exists (use a `Process.send`
    /`receive` between `mkdir_p!` and the Task spawn to hold the run
    open mid-flight, OR observe via PubSub `:session_started`).
  - After `run_now/2` returns: assert the dir has been removed.

  Pins **Review pass corrections #5** of the latest review pass.

### Operator-validated (out of CI, captured in release notes)

- Live `harness: :codex` round-trip with real `auth.json`, real `codex`
  binary on `$PATH`, real Bandit endpoint. Assert one `ConsolidationRun`
  row with `status: :succeeded`, `harness: :codex`, populated
  `harness_model`. Run the same scope a second time with `harness:
  :claude_code` for parity comparison.

## Verification

```bash
mix compile --warnings-as-errors
mix format --check-formatted
mix test
mix test test/jido_claw/forge/runners/codex_test.exs \
         test/jido_claw/forge/runners/claude_code_test.exs \
         test/jido_claw/memory/consolidator/run_server_test.exs
```

End-to-end (operator):

```elixir
# iex -S mix
Application.put_env(:jido_claw, JidoClaw.Memory.Consolidator,
  enabled: false, harness: :codex,
  harness_options: [model: "<chosen-codex-model>",
                    sandbox_mode: :local, timeout_ms: 600_000])

JidoClaw.Memory.Consolidator.run_now(scope_record, override_min_input_count: true)
```

## Open questions to resolve during implementation

1. **Should the consolidator prompt module land in 3c, or as a 3b
   follow-up?** It's a missing 3b deliverable surfaced by careful
   review (verified zero references). Landing it in 3c is necessary
   for any real CLI harness to function (operator-validated round-trip
   would fail with an empty prompt otherwise). **Plan assumes: yes,
   land in 3c** (file 4a).
2. **Default Codex model name.** The plan reserves
   `base_runner_config(:codex, opts).model` with placeholder
   `"gpt-5-codex"`. Confirm the production model identifier.
3. **Docker `sbx` agent-type for Codex.** The plan adds
   `:codex -> "codex"`. Confirm against the actual `sbx` image registry
   name.
4. **Whether to also sync small files like
   `installation_id`/`version.json`** beyond the trimmed `auth.json` +
   `config.toml` whitelist. Codex regenerates them; plan keeps them OUT.

## Out of scope

- Codex-specific tool surface customisation. Both runners see the same 11
  proposal tools.
- Auto-detection of which runner is available at boot.
- Per-token streaming of assistant text. Codex `--json` only emits one
  `item.completed { agent_message }` per assistant message.
- A `:codex_fake` test substrate. The existing `:fake` runner is already
  harness-agnostic.

## Critical files reference

| File | Change | Anchor |
| --- | --- | --- |
| `lib/jido_claw/forge/runners/codex.ex` | NEW | — |
| `lib/jido_claw/forge/runners/claude_code.ex` | EDIT (`:no_credentials` retro-fit, app-env home/forge dirs) | lines 7, 13-52, 144-165 |
| `lib/jido_claw/forge/harness.ex` | EDIT (`:codex` resolver) | `resolve_runner` clauses (~1131-1136) |
| `lib/jido_claw/forge/manager.ex` | EDIT (`:codex => 10` capacity) | lines 15, 68-73 |
| `lib/jido_claw/forge/sandbox/docker.ex` | EDIT (`:codex` agent type) | line 224-230 |
| `lib/jido_claw/memory/consolidator.ex` | EDIT (`:harness` doc) | lines 43-49 |
| `lib/jido_claw/memory/consolidator/prompt.ex` | NEW (consolidator prompt builder) | — |
| `lib/jido_claw/memory/consolidator/run_server.ex` | EDIT (resolver lift to await_and_start with fail-fast on bad harness, prompt+forge_home wire-in, mkdir_p of per-run dir, await_ready init-failure mapping, effective state in row writes, cleanup moved to drive_harness post-stop) | lines 90-93, 287, 306-313, 315-356 (esp. 358-387), 389-404, 416-427, 594, 969 |
| `test/jido_claw/memory/consolidator/prompt_test.exs` | NEW | — |
| `config/config.exs` | EDIT (comment) | line 285 area |
| `test/jido_claw/forge/runners/codex_test.exs` | NEW | — |
| `test/jido_claw/forge/runners/claude_code_test.exs` | NEW | — |
| `test/jido_claw/memory/consolidator/run_server_test.exs` | EXTEND | cross-harness + no_credentials cases |

## Slicing guidance (NOT a commit plan)

If split into smaller commits:

1. ClaudeCode `:no_credentials` retro-fit + app-env `:claude_home_dir`
   / `:forge_home` + per-run forge_home from runner_config + tests.
2. `Forge.Manager.max_per_runner` adds `:codex => 10`;
   `Forge.Harness.resolve_runner(:codex)`;
   `Forge.Sandbox.Docker.sandbox_agent_type(:codex)`.
3. `Forge.Runners.Codex` module + tests (uses configurable forge_home
   from step 1).
4. `JidoClaw.Memory.Consolidator.Prompt.build/1` module + a
   ClaudeCode-driven (currently :fake-only) test that asserts the
   built prompt reaches `state.prompt`.
5. `RunServer` wire-up: lift resolver into `await_and_start`
   (fail-fast on bad harness), un-stub `:codex` in dispatch,
   `base_runner_config(:codex, _)`, per-run `run_forge_home` /
   `codex_home` plumbing + `mkdir_p!`, prompt wire-in,
   `await_ready` runner-init-failure mapping, effective state in row
   writes, **outer try/after cleanup of per-run dir in
   `drive_harness/4`** (NOT in `cleanup/1`). Cross-harness +
   `:no_credentials` regression tests + cleanup test.
6. `run_now/2` `:harness` option doc + plumbing (smallest commit;
   can land before or alongside step 5).
