# Fix v0.6 Phase 3c code-review issues (consolidator + Codex runner)

## Context

v0.6 Phase 3c landed `JidoClaw.Forge.Runners.Codex` plus consolidator wiring for a per-call `harness: :codex` override. Code review flagged three issues; all three were verified by reading the affected code:

1. **P2** — `Consolidator.run_now(scope, harness: :codex)` against the checked-in default config silently runs Codex with the Claude model. The flat `:harness_options[:model]` is read regardless of the resolved harness, so `harness_model` is mislabeled (`"claude-opus-4-7"` for a Codex run) and the Codex CLI is invoked with `-m claude-opus-4-7`, which will fail.
2. **P2** — The Codex runner copies the user's `~/.codex/config.toml` verbatim into the per-run `$CODEX_HOME`, then shell-`>>`-appends a `[mcp_servers.consolidator]` block. If the user already declared that table, TOML 1.0 rejects the duplicate and Codex exits before our MCP server can be reached.
3. **P3** — `restore/2` in both runner tests is a no-op when the previous app-env value was `nil`. After `on_exit`, `:codex_home_dir` / `:claude_home_dir` / `:forge_home` are still pointing at tmp dirs that have since been `rm_rf`'d — those stale paths can leak into later async-`false` tests.

Bug 1 only triggers in production-shaped configs (the test suite's `harness_options` happens to omit `:model`, which is why CI passed). Bug 2 only triggers when an operator's host `~/.codex/config.toml` already names a server `consolidator`. Bug 3 is latent today but will bite the next test that reads those keys.

Reviewer also noted a documentation scope mismatch (Phase 3b plan deferred the Codex runner, Phase 3c implements it). That is an intentional split — Phase 3c plan exists at `docs/plans/v0.6/phase-3c-memory-codex.md`. No code change; just don't mislabel future PR prose.

## Issue 1 — Nest model under harness atom in `:harness_options`

**Approach**: Keep shared keys (`:sandbox_mode`, `:timeout_ms`, `:max_turns`) at the top level of `:harness_options`. Move harness-specific keys (`:model`, `:thinking_effort`) into nested per-harness keyword blocks (`:claude_code`, `:codex`, `:fake`). A small helper merges the shared block with the harness-specific block at lookup time.

This matches the reviewer's first prescription ("keep model defaults per harness") and lets operators set both Claude and Codex models without conflict. `default_await_timeout/0` in `lib/jido_claw/memory/consolidator.ex:119-127` already only reads `:timeout_ms` (shared) and is unaffected.

### Files to change

**`config/config.exs:290-296`** — restructure `:harness_options`:

```elixir
harness_options: [
  sandbox_mode: :local,
  timeout_ms: 600_000,
  max_turns: 60,
  claude_code: [
    model: "claude-opus-4-7",
    thinking_effort: "xhigh"
  ],
  codex: [
    model: "gpt-5-codex"
  ]
]
```

**`lib/jido_claw/memory/consolidator/run_server.ex`**:

- Add a helper near `base_runner_config/2` (line 494):
  ```elixir
  defp harness_specific_options(harness_options, harness) do
    shared = Keyword.drop(harness_options, [:claude_code, :codex, :fake])
    specific = Keyword.get(harness_options, harness, [])
    Keyword.merge(shared, specific)
  end
  ```
- Update `base_runner_config(:claude_code, opts)` (line 496) and `base_runner_config(:codex, opts)` (line 505) to call `harness_specific_options(opts, harness)` first, then read `:model` / `:thinking_effort` from the merged result. Built-in defaults (`"claude-opus-4-7"`, `"gpt-5-codex"`, etc.) stay as the final fallback.
- Update the seed at `run_server.ex:101-104` to read the harness-specific model:
  ```elixir
  effective_harness_model =
    consolidator_config()
    |> Keyword.get(:harness_options, [])
    |> harness_specific_options(harness)
    |> Keyword.get(:model)
  ```
- Update the comment at lines 98-100 to describe the nested shape.

**`test/jido_claw/memory/consolidator/run_server_test.exs`**:

- Lines 295-343: the "harness_model column tracks the configured model across consecutive runs" test currently sets `harness_options: [model: "model-A", ...]` against `harness: :fake`. Move the model into a `:fake` block:

  ```elixir
  harness_options: [
    sandbox_mode: :local,
    timeout_ms: 30_000,
    max_turns: 60,
    fake: [model: "model-A"]
  ]
  ```

  …and same for `"model-B"`. The helper handles `:fake` via `Keyword.get(opts, :fake, [])`, so no special branch is needed.

- The `:no_credentials` test at line 345-385 already relies on the `:codex` runner's built-in default and will pass unchanged once `base_runner_config(:codex, ...)` no longer reads a top-level `:model`.

- **Add a new test** in the same describe block — call it "per-call harness override picks the harness's nested model, not the global default's". It must reproduce the original bug. Shape:

  ```elixir
  Application.put_env(:jido_claw, @consolidator_key,
    enabled: true,
    min_input_count: 0,
    write_skip_rows: true,
    harness: :claude_code,
    harness_options: [
      sandbox_mode: :local,
      timeout_ms: 30_000,
      max_turns: 60,
      claude_code: [model: "claude-x"],
      codex: [model: "codex-y"]
    ]
  )

  # Empty $CODEX_HOME so the run hits :no_credentials before launching
  # the real CLI but still writes a ConsolidationRun row through the
  # error-egress path. Restore prev value via delete_env/put_env.

  assert {:error, "no_credentials"} =
           Consolidator.run_now(scope, harness: :codex,
                                       override_min_input_count: true,
                                       await_ms: 30_000)

  row = Ash.read!(ConsolidationRun, domain: @memory_domain)
        |> Enum.find(&(&1.harness == :codex and &1.tenant_id == scope.tenant_id))
  assert row.harness_model == "codex-y"  # NOT "claude-x"
  ```

  Without the fix, `harness_model` would be `"claude-x"` (the leak the reviewer flagged). With the fix, it is `"codex-y"`. This is the exact test case the reviewer asked for.

## Issue 2 — Inject consolidator MCP via Codex `-c` CLI flag instead of file mutation

**Approach**: Stop touching `$CODEX_HOME/config.toml` for MCP wiring. Keep the host `config.toml` sync as-is so operators retain provider/profile/proxy settings. Pass the consolidator MCP server as a `-c 'mcp_servers.consolidator.url="..."'` override on the `codex exec` argv in `run_iteration/3`. This sidesteps duplicate-table parsing entirely and preserves user config.

The Codex CLI's `-c key=value` dotted-key override accepts TOML literal values; `mcp_servers.consolidator.url="http://..."` is parsed as a complete table entry at startup. Since we never write that table to disk, there is no possibility of a duplicate-table conflict with the user's pre-existing `[mcp_servers.consolidator]` (if any). Their definition would still be loaded from `config.toml`, then overridden in-process by our `-c` value — which is the correct behavior for our per-run, ephemeral consolidator endpoint.

Alternatives rejected: writing a fresh minimal `config.toml` (loses user provider/profile config); parse-merge with a TOML encoder (new dep, extra code).

### Files to change

**`lib/jido_claw/forge/runners/codex.ex`**:

- **Keep** `@syncable_entries ~w(auth.json config.toml)` (line 36) — host config is preserved.
- **Delete** `append_consolidator_mcp/3` (lines 148-165) and its call site at line 49. No file mutation in `init/2`.
- In `init/2` (lines 41-79), still read `mcp_url = Map.get(config, :mcp_server_url)` and store it in the returned state under `:mcp_server_url` so `run_iteration/3` can read it.
- In `run_iteration/3` (lines 82-109), prepend the `-c` override to the existing `args` list when the URL is present. Insert immediately after `"exec"` so the order is `["exec", "-c", "mcp_servers.consolidator.url=\"#{url}\"", "-m", state.model, ...]`. The argv element is the literal string `mcp_servers.consolidator.url="..."` (the inner double quotes are part of the TOML value, not shell quoting).
- Lines 6-13 moduledoc: rewrite the "No `--mcp-config FILE`. MCP servers live in `$CODEX_HOME/config.toml`…" paragraph to describe the new posture: host `config.toml` is synced for provider/profile fidelity, and the per-run consolidator MCP server is injected via `-c` on the `codex exec` argv (not by mutating the file). Mention that this avoids duplicate-table errors when the host already declares `[mcp_servers.consolidator]`.

**`test/jido_claw/forge/runners/codex_test.exs`**:

- Lines 67-90 ("syncs auth + config, appends consolidator MCP block, injects CODEX_HOME"): rename to drop the "appends … MCP block" wording. Drop the assertion that scans for a `>>` append of `[mcp_servers.consolidator]` — there is no longer such a write. Keep the assertions that `auth.json` and `config.toml` are synced from the host, and that `CODEX_HOME` env injection happens.
- **Add a new test** exercising `run_iteration/3` to verify the `-c` flag is on the argv when `mcp_server_url` was set in the runner config. Use `StubSandbox.program_run/2` to register a canned response and inspect the recorded `Sandbox.run` argv via `StubSandbox.events/1`. Assert that the argv contains `"-c"` followed by `mcp_servers.consolidator.url="<url>"` immediately after `"exec"`.
- Existing parse-output tests at lines 200-318 are unaffected; the only run_iteration plumbing change is argv shape.

## Issue 3 — Test env restore deletes when previous was nil

**Approach**: Change the `nil`-clause of `restore/2` in both runner test files from `:ok` to `Application.delete_env(:jido_claw, key)`. This matches the inline pattern already used in `test/jido_claw/memory/consolidator/run_server_test.exs:356-358` and `:398-400` for the same `:codex_home_dir`/`:forge_home` keys.

### Files to change

**`test/jido_claw/forge/runners/codex_test.exs:328-329`**:

```elixir
defp restore(key, nil), do: Application.delete_env(:jido_claw, key)
defp restore(key, value), do: Application.put_env(:jido_claw, key, value)
```

**`test/jido_claw/forge/runners/claude_code_test.exs:115-116`** — identical change.

## Verification

```bash
mix test test/jido_claw/forge/runners/codex_test.exs \
         test/jido_claw/forge/runners/claude_code_test.exs \
         test/jido_claw/memory/consolidator/run_server_test.exs \
         test/jido_claw/memory/consolidator/prompt_test.exs
mix compile --warnings-as-errors
mix format lib/jido_claw/memory/consolidator/run_server.ex \
           lib/jido_claw/forge/runners/codex.ex \
           test/jido_claw/memory/consolidator/run_server_test.exs \
           test/jido_claw/forge/runners/codex_test.exs \
           test/jido_claw/forge/runners/claude_code_test.exs \
           config/config.exs
```

Note: `mix format --check-formatted` cannot run repo-wide right now because there's no root `.formatter.exs` inputs/subdirectories config. That's a separate repo issue; format the touched files explicitly as above.

Post-fix behavioral checks:

- **Issue 1 (default config)**: With the default checked-in `config/config.exs`, the existing `:no_credentials` test at `run_server_test.exs:345-385` writes a `ConsolidationRun` row with `harness: :codex, harness_model: "gpt-5-codex"` — never `"claude-opus-4-7"`.
- **Issue 1 (override + nested)**: The new test described above verifies that with both `claude_code: [model: "claude-x"]` and `codex: [model: "codex-y"]` configured and global `harness: :claude_code`, calling `run_now(scope, harness: :codex)` records `harness_model: "codex-y"`.
- **Issue 2**: After `Codex.run_iteration/3` with a `mcp_server_url` set, the recorded `Sandbox.run` argv contains `"-c"` and `mcp_servers.consolidator.url="<url>"` immediately following `"exec"`. No `:write` or `:exec` event mutates `${codex_home}/config.toml` to include `[mcp_servers.consolidator]`.
- **Issue 3**: After running either runner test in isolation against a fresh boot (where the relevant keys were `nil` before), `Application.get_env(:jido_claw, :codex_home_dir)` / `:claude_home_dir` / `:forge_home` returns `nil`, not a stale tmp path.

## Critical files

- `config/config.exs:290-296`
- `lib/jido_claw/memory/consolidator/run_server.ex:98-104,494-513`
- `lib/jido_claw/forge/runners/codex.ex:6-13,41-79,82-109,148-165` (delete the append helper, add `mcp_server_url` to state, prepend `-c` to argv)
- `test/jido_claw/memory/consolidator/run_server_test.exs:295-343` (update existing) plus a new test for the per-call harness override
- `test/jido_claw/forge/runners/codex_test.exs:67-90,328-329` plus a new run_iteration argv assertion
- `test/jido_claw/forge/runners/claude_code_test.exs:115-116`
