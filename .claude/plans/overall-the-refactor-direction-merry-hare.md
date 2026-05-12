# Decompose `JidoClaw.CLI.Repl.start/1`

## Context

The Tier 2 single complexity outlier from `docs/reports/credo-baseline-2026-05-12.md`
is `lib/jido_claw/cli/repl.ex:36` — `start/1` scores cyclomatic complexity **23**
against the Credo default limit of **9** (`.credo.exs` enables
`Credo.Check.Refactor.CyclomaticComplexity` with no override). It is a 195-line
procedure that walks the entire REPL boot sequence inline, interleaving ~13
conditional/case constructs across eight clear phases.

All other Tier 1 and Tier 2 issues from the baseline are already addressed.
This is the last outlier; the goal is to bring `start/1` under the limit by
splitting it into small private helpers, **with zero behavioral change** — same
IO, same ordering, same failure semantics.

## Design constraints (from user feedback)

These were called out explicitly during plan review and must be preserved:

1. **Side-effect order is byte-for-byte equivalent.** The invalid-strategy
   warning currently prints *after* `Branding.boot_sequence/2`
   (`repl.ex:59`, `repl.ex:67`). The refactor must keep that order.
2. **Do not combine `set_session_uuid` and `set_agent`.** They are
   intentionally separated by `Startup.inject_system_prompt/3`
   (`repl.ex:169`, `repl.ex:176`, `repl.ex:185`). Combining them would force
   one of those calls to move.
3. **Preserve the hard-match on session worker startup.** `repl.ex:152` does
   `{:ok, _session_pid} = JidoClaw.Session.Supervisor.ensure_session(...)`;
   if extraction loses that match, a failing supervisor becomes a silent boot
   regression instead of a crash.
4. **Don't tighten `Heartbeat.start_link/1`'s return value.** It registers a
   named GenServer (`name: __MODULE__`), so a second boot in the same VM
   returns `{:error, {:already_started, pid}}`. The current code ignores the
   result. Any helper around it must keep ignoring it (or explicitly match
   `{:ok, _} | {:error, {:already_started, _}}`).
5. **Prefer pattern-matching `maybe_*` helpers over broad `if`s.** E.g.:
   ```elixir
   defp maybe_warn_strategy_fallback(strategy, strategy), do: :ok
   defp maybe_warn_strategy_fallback(configured, _strategy), do: IO.puts(...)
   ```

## Target shape for `start/1`

```elixir
def start(project_dir) do
  config = ensure_config(project_dir)
  model = Config.model(config)
  Application.put_env(:jido_ai, :model_aliases, %{fast: model, capable: model})

  {configured_strategy, strategy} = resolve_configured_strategy(config)

  print_boot_sequence(project_dir, config, model, strategy)
  maybe_warn_strategy_fallback(configured_strategy, strategy)
  sync_project_state(project_dir)
  announce_provider_status(config)
  announce_discord_status()

  case JidoClaw.Jido.start_agent(Agent, id: "main") do
    {:ok, pid} ->
      state = boot_repl_session(pid, project_dir, config, model, strategy)
      loop(state)

    {:error, reason} ->
      Formatter.print_error("Failed to start agent: #{inspect(reason)}")
  end
end
```

Expected complexity for `start/1` after refactor: **~3** (one `case`, plus
straight-line orchestration). Each extracted helper should also stay ≤ 9.

## Helpers (file: `lib/jido_claw/cli/repl.ex`)

All private. Source lines refer to the current file.

| # | Helper | Source lines | Notes |
|---|---|---|---|
| 1 | `ensure_config(project_dir)` | 38–43 | `Setup.needed?` branch + `Setup.run` / `Config.load`. |
| 2 | `resolve_configured_strategy(config)` | 53–54 | Returns `{configured_strategy, strategy}` tuple so the warning can be issued *after* the banner. Uses existing `resolve_strategy/1` (line 427+). |
| 3 | `maybe_warn_strategy_fallback(configured, strategy)` | 67–73 | Two clauses: same-value clause is a no-op; differing-value clause does the `IO.puts` warning. |
| 4 | `print_boot_sequence(project_dir, config, model, strategy)` | 56–65 | Owns `mode` lookup and the `Branding.boot_sequence/2` call. |
| 5 | `sync_project_state(project_dir)` | 75–96 | `Startup.ensure_project_state/1` case + the `:sidecar_written` upgrade-available IO. Use pattern matching on `prompt_sync` value via `maybe_announce_prompt_upgrade/1` clauses. |
| 6 | `announce_provider_status(config)` | 98–116 | `Config.check_provider/1` case (three branches). |
| 7 | `announce_discord_status()` | 118–143 | Top-level entry; flattened (see below) so no helper retains the current `if -> case -> case` nesting. |
| 8 | `boot_repl_session(pid, project_dir, config, model, strategy)` | 147–225 | Entire `{:ok, pid} ->` arm body. Returns the `%__MODULE__{}` state. |

### Sub-helpers for `announce_discord_status/0`

Flatten the current `if -> case -> case` rather than carry it into a single
helper (which would shift the `Refactor.Nesting` smell, not remove it). Each
sub-helper has at most one branch:

```elixir
defp announce_discord_status do
  case System.get_env("DISCORD_BOT_TOKEN") do
    nil -> :ok
    _token -> announce_discord_consumer_group()
  end
end

defp announce_discord_consumer_group do
  case Process.whereis(Nostrum.ConsumerGroup) do
    nil -> announce_discord_failed_start()
    _pid -> announce_discord_connection(poll_discord_ready(10, 500))
  end
end

defp announce_discord_failed_start, do: ...           # the ✗ "failed to start" puts
defp announce_discord_connection(%{username: n}), do: # the ✓ "online as …" puts
defp announce_discord_connection(nil), do:            # the ✗ "failed to connect" puts
```

`poll_discord_ready/2` is the existing helper at line 507 — reused as-is.

### Sub-helpers for `boot_repl_session/5`

These keep #8 itself under the complexity limit and respect constraints 2–4.

| # | Sub-helper | Source lines | Notes |
|---|---|---|---|
| 8a | `ensure_session_worker!(tenant_id, session_id)` | 152–155 | Hard-matches `{:ok, _session_pid} = …` internally — constraint 3. Trailing `!` signals it crashes on failure. |
| 8b | `maybe_set_worker_session_uuid(tenant_id, session_id, session_uuid)` | 169–171 | Three clauses preserving the current `if session_uuid` truthiness — `nil` and `false` are no-ops, anything else calls `Worker.set_session_uuid/3`. **Kept separate from 8d** — constraint 2. |
| 8c | `inject_system_prompt_with_warning(pid, project_dir, session_record)` | 176–182 | `Startup.inject_system_prompt/3` case. |
| 8d | `bind_agent_to_worker(tenant_id, session_id, pid)` | 184–185 | Just `Worker.set_agent/3`. **Kept separate from 8b** — constraint 2. |
| 8e | `configure_display_from_config(config, model)` | 190–196 | The `Config.model_info/1` case that derives `context_window`, plus the `Display.configure/3` call. |
| 8f | `load_cron_jobs(project_dir)` | 202–205 | `Cron.Scheduler.load_persistent_jobs/2` case. Both arms are `:ok`; extraction is for symmetry. |
| 8g | `start_heartbeat(project_dir)` | 208 | Wraps `JidoClaw.Heartbeat.start_link/1` and explicitly ignores the result (`_ = …`) — constraint 4. |

`boot_repl_session/5` then reads as a flat sequence:

```elixir
defp boot_repl_session(pid, project_dir, config, model, strategy) do
  session_id = SessionId.new()
  tenant_id = "default"

  ensure_session_worker!(tenant_id, session_id)

  {workspace_uuid, session_uuid, session_record} =
    ensure_persisted_session(tenant_id, project_dir, session_id)

  maybe_set_worker_session_uuid(tenant_id, session_id, session_uuid)
  inject_system_prompt_with_warning(pid, project_dir, session_record)
  bind_agent_to_worker(tenant_id, session_id, pid)
  AgentTracker.register("main", pid, nil, nil)
  configure_display_from_config(config, model)

  profile = resolve_profile(session_id)
  Display.set_profile(profile)

  load_cron_jobs(project_dir)
  start_heartbeat(project_dir)

  %__MODULE__{
    agent_pid: pid,
    agent_id: "main",
    config: config,
    cwd: project_dir,
    model: model,
    session_id: session_id,
    session_uuid: session_uuid,
    workspace_uuid: workspace_uuid,
    tenant_id: tenant_id,
    started_at: System.monotonic_time(:second),
    strategy: strategy,
    profile: profile
  }
end
```

## Out of scope

- Public API: `start/1`, `resolve_strategy/1` (lines 427–433), `resolve_profile/1`
  (lines 441–450), `prepare_user_message/2` (lines 462–472) — unchanged.
- `ensure_persisted_session/3` and the workspace-policy helpers below it
  (lines 537–637) — already well-factored, leave alone.
- `loop/1`, `handle_message/2`, `poll_with_tool_display/3`, `display_new_tool_calls/2`,
  `tc_*` accessors, `extract_text/1`, `update_stats/1`, `goodbye_stats/1`,
  `format_elapsed/1`, `poll_discord_ready/2`, `model_name/1` — unrelated to the
  hotspot.
- Style nits flagged elsewhere in the credo baseline (AliasUsage, ModuleDoc,
  AliasOrder, etc.) in this file — Tier 3 work, separate PR.

## Verification

1. `mix format` — must apply cleanly.
2. `mix compile --warnings-as-errors`.
3. `mix credo lib/jido_claw/cli/repl.ex` — confirm the
   `Refactor.CyclomaticComplexity` finding on line 36 is gone and no extracted
   helper introduces a new complexity or nesting finding. The file's Tier 3
   style findings (`Design.AliasUsage`, `Readability.ModuleDoc`, etc.) are
   explicitly out of scope and may still appear.
4. `mix test test/jido_claw/cli/repl_test.exs` — the existing suite covers
   `resolve_strategy/1`, `resolve_profile/1`, `prepare_user_message/2`; none of
   them drive `start/1`. They should pass unmodified, which validates that the
   public surface and the only-tested-via-`@doc false` helpers were not
   disturbed.
5. **Validation gap (called out by user):** there is no automated test that
   drives `start/1` end-to-end, so boot-output equivalence is verified manually.
   Procedure:
   - Before the refactor, capture stdout from `mix jidoclaw` boot in a fresh
     project until the prompt appears.
   - Re-run after the refactor and `diff` the captured output.
   - Exercise each branch at least once: (a) a fresh project (triggers Setup
     wizard), (b) a configured project with a valid strategy, (c) a configured
     project with a deliberately invalid strategy in `.jido/config.yaml`
     (triggers `maybe_warn_strategy_fallback`'s warning clause and must
     still print *after* the boot banner), (d) `DISCORD_BOT_TOKEN` unset
     (Discord block is skipped), (e) `DISCORD_BOT_TOKEN` set to a bogus value
     (failure path renders).
   - Verify the system_prompt sidecar `:sidecar_written` notice still appears
     when `.jido/system_prompt.md.default` is freshly regenerated.
6. Confirm a second `mix jidoclaw` boot in the same `iex -S mix` session still
   succeeds (i.e. `start_heartbeat/1` tolerates `{:error, {:already_started, _}}`).

## Commit slicing

Single commit is fine — the diff is mechanical and easy to scan top-to-bottom.
If the user prefers a split, the natural cut is:

1. Helpers 1–7 (pre-agent-start phases) plus the new `start/1` skeleton.
2. Helper 8 and its sub-helpers (8a–8g).

Each commit compiles and passes the existing test suite independently.
