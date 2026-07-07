# Post-review fix: Codex runner fails closed on refused CODEX_HOME inject (review P2)

## Context

The PR-2 executor-seam code review surfaced one finding (P2), now **validated against
source**:

- `lib/jido_claw/forge/runners/codex.ex:86` calls
  `Sandbox.inject_env(client, %{"CODEX_HOME" => codex_home})` and **discards the
  result** — `init/2` returns `{:ok, state}` unconditionally once the config sync
  succeeds. (`inject_env`'s contract is `:ok | {:error, term()}` —
  `sandbox/behaviour.ex:18`.)
- The vendor executor hardwires `config_sync: :auth_only`
  (`forge_executor.ex:564`), which syncs `auth.json` alone — so `CODEX_HOME`
  taking effect is the ONLY thing keeping the operator's real `~/.codex` (host
  `config.toml`, host MCP servers) out of a read-only vendor session. A refused
  inject silently runs `codex exec` against the host config universe, defeating
  the isolation the mode exists to enforce.
- ClaudeCode handles the identical risk by failing closed:
  `claude_code.ex:248-251` returns `{:error, {:config_isolation_failed, reason}}`,
  regression-tested at `claude_code_test.exs:209-219` via the existing
  `StubSandbox.program_inject_env/2` (`test/support/stub_sandbox.ex:102` — its doc
  already names this exact use case). Codex has no such test; the "executor knobs
  (PR-2)" describe at `codex_test.exs:377` is its natural home.
- No new plumbing needed downstream: a runner-init error already propagates as
  `{:runner_init_failed, reason}` through the harness to a clean ForgeExecutor
  step error (the claude / `:no_credentials` proven path).

**Scoping decision** (mirrors claude + the PR-2 knob discipline "defaults preserve
the consolidator byte-for-byte"): fail closed **only under `config_sync:
:auth_only`** (the vendor posture, where isolation is load-bearing). `:full` (the
consolidator default) preserves its existing best-effort behavior: the synced
`auth.json`/`config.toml` are copies of the host's, so the *static config
surface* is equivalent on fallback — codex would still use the host dir for
mutable session/cache state, a hygiene degrade, not an isolation breach — and
claude's `:full` branch has no env inject at all. Goal: fix vendor `:auth_only`
isolation without changing consolidator behavior. The asymmetry gets pinned by a
test.

No other review findings; reviewer confirmed the rest of the PR-2 surface matched
the plan.

## Changes (TDD order — regression test first, confirm RED, then GREEN)

### 1. `test/jido_claw/forge/runners/codex_test.exs` — two tests in the "executor knobs (PR-2)" describe (:377)

Modeled byte-for-byte on `claude_code_test.exs:209-219`:

- `config_sync: :auth_only` + `StubSandbox.program_inject_env(client, {:error,
  :inject_env_refused})` ⇒ `Codex.init/2` returns
  `{:error, {:config_isolation_failed, :inject_env_refused}}` (RED until the fix).
- Companion pin for the deliberate asymmetry: default `config_sync: :full` with
  the same refused inject still returns `{:ok, _state}` (consolidator
  byte-for-byte — this one is GREEN before and after; it pins the decision).

Both use the describe's existing setup (`host` with auth.json + config.toml,
`forge_home`), `codex_home: Path.join(forge_home, ".codex")`.

### 2. `lib/jido_claw/forge/runners/codex.ex` — the fix

Restructure `init/2`'s success arm as a `with` (flattens, and matches claude's
any-error pass-through instead of the current `{:error, :no_credentials}`-only
match):

```elixir
with :ok <- sync_host_codex_config(client, codex_home, forge_home, config_sync),
     :ok <- inject_codex_home(client, codex_home, config_sync) do
  if prompt != "" do
    Sandbox.write_file(client, "#{forge_home}/session/context.md",
      PromptRedaction.redact(prompt))
  end

  {:ok, %{ ...unchanged state map... }}
end
```

New helper. Its comment states the why + the deliberate `:full` asymmetry —
phrased as "preserves the consolidator's existing best-effort behavior; static
config content is a host copy, though mutable session/cache state would land in
the host dir", never "content-identical":

```elixir
defp inject_codex_home(client, codex_home, :auth_only) do
  case Sandbox.inject_env(client, %{"CODEX_HOME" => codex_home}) do
    :ok -> :ok
    {:error, reason} -> {:error, {:config_isolation_failed, reason}}
  end
end

defp inject_codex_home(client, codex_home, _full) do
  _ = Sandbox.inject_env(client, %{"CODEX_HOME" => codex_home})
  :ok
end
```

Notes:
- The context.md write moves after the inject — deliberate and safe: no test
  asserts relative order (checked `codex_test.exs:67-122` — `env/1` equality and
  file-content assertions only), and skipping the write on a doomed init is
  strictly better.
- `sync_host_codex_config/4` itself is unchanged (still
  `:ok | {:error, :no_credentials}`).
- Moduledoc: extend the `config_sync` bullet with the fail-closed sentence
  (mirror claude_code.ex:18's "A failed env inject fails the init CLOSED").

### 3. `AGENTS.md` — one-phrase doc-truth touch

In the executor-seam paragraph, the fail-closed claim currently lives only inside
the claude parenthetical. Extend the codex clause: "codex `-s read-only` +
auth.json-only sync (a refused `CODEX_HOME` inject fails init CLOSED)". The
claude parenthetical and the next-ten README done-note (line 613) stay as
written — both remain true (historical release notes stay historical).

## Files touched

- `test/jido_claw/forge/runners/codex_test.exs` (two tests)
- `lib/jido_claw/forge/runners/codex.ex` (init restructure + helper + moduledoc)
- `AGENTS.md` (one phrase)

Nothing staged or committed — changes stay in the working tree with the rest of
the PR-2 work.

## Verification

1. RED first: run `mix test test/jido_claw/forge/runners/codex_test.exs` with only
   the new tests added — the fail-closed test must fail (init currently returns
   `{:ok, _}`), the `:full` pin passes.
2. GREEN: apply the fix, re-run the file — all pass. Also run
   `mix test test/jido_claw/forge/runners/claude_code_test.exs
   test/jido_claw/skills/steps/forge_executor/ test/jido_claw/skills/steps/forge_executor_test.exs`
   (adjacent surfaces).
3. **Completion bar**: `mix precommit` — run directly (never piped), report exact
   exit code + test counts verbatim, zero findings. Known caveat (memory): one
   unrelated timing test (MemoryExport / collector crash-recovery / :pg) may flake
   per full run — re-run rather than treat as a regression.
