# Complete env scrubbing across all child-process spawn paths

## Context

A code review of the recent credo-cleanup branch raised a P1: the new `JidoClaw.Security.Redaction.Env.scrubbed_cmd_env/0` helper (which returns `[{key, nil}]` unset-tuples for secret-named env vars) was applied to many `System.cmd` call sites, but several child-process paths still leak the parent environment — meaning git hooks, forge host-shell commands, and shell-tool commands all inherit `*_TOKEN`/`*_KEY`/etc. secrets.

**The finding is verified valid.** Empirically confirmed (via `elixir -e` with a fake `FAKE_SECRET_TOKEN`):

- `System.cmd(env: [])` → child **still sees** the secret (`:env` *extends* parent env, never replaces it)
- `System.cmd(env: [{"VAR", nil}])` → unset works
- bare `Port.open` → inherits full parent env
- `Port.open(..., {:env, [{~c"VAR", false}]})` → unset works (ports use charlists + `false`, not `nil`)

A full sweep of `lib/` found the only spawn mechanisms in use are `System.cmd` and `Port.open` (no `System.shell`, `:os.cmd`, MuonTrap, etc.). Unscrubbed sites — the review's three plus **two more the review missed**:

| Site | Mechanism | Issue |
|---|---|---|
| `lib/jido_claw/tools/git_commit.ex:28` | `System.cmd` ×2 | `cmd_opts` has no `:env` — `git add`/`git commit` (and commit hooks) inherit secrets |
| `lib/jido_claw/tools/git_status.ex:20` | `System.cmd` ×2 | same pattern, missed by review (sibling `git_diff.ex`/`project_info.ex` already scrub) |
| `lib/jido_claw/forge/runner/host_shell.ex:73,126,135` | `System.cmd` | passes `env: sandbox.env` which only *extends* parent env; inherited secrets remain |
| `lib/jido_claw/forge/runner/host_shell.ex:156` | `Port.open` | `spawn/4` has no `:env` opt at all |
| `lib/jido_claw/forge/sandbox/docker.ex:121` | `Port.open` | `spawn/4` host-side `sbx` client process, no `:env`, missed by review |
| `lib/jido_claw/shell/backend_host.ex:130` | `Port.open` | passes `{:env, port_env}` built from session env — additive only, inherited secrets remain |

Why not the systemic alternative (delete secrets from the BEAM's own env at boot): LLM provider clients and Ecto read env vars lazily at runtime, so the app itself needs them. Per-call-site scrubbing is the architecture the repo already chose; this change completes it consistently, following the reviewer's suggested approach.

## Approach

Extend `JidoClaw.Security.Redaction.Env` (`lib/jido_claw/security/redaction/env.ex`) with override-merging and a Port variant, then apply at the 6 sites. Precedence rule per the module's existing contract ("a child that genuinely needs one must re-add it explicitly"): **intentional overrides win over the scrub list**.

### 1. Helper changes — `lib/jido_claw/security/redaction/env.ex`

Replace `scrubbed_cmd_env/0` with `scrubbed_cmd_env(overrides \\ [])` (existing zero-arg call sites keep working):

```elixir
@spec scrubbed_cmd_env(Enumerable.t()) :: [{String.t(), String.t() | nil}]
def scrubbed_cmd_env(overrides \\ []) do
  override_map =
    Map.new(overrides, fn {k, v} -> {to_string(k), if(is_nil(v), do: nil, else: to_string(v))} end)

  unsets =
    for {key, _} <- System.get_env(),
        sensitive_key?(key),
        not Map.has_key?(override_map, key),
        do: {key, nil}

  unsets ++ Map.to_list(override_map)
end
```

Key/value coercion via `to_string` absorbs the stringify logic currently duplicated at HostShell/BackendHost call sites; explicit `nil` values are preserved (still mean "unset").

Add `scrubbed_port_env(overrides \\ [])` — same merge, port-shaped output (`Port.open` `:env` needs charlists and `false` to unset):

```elixir
@spec scrubbed_port_env(Enumerable.t()) :: [{charlist(), charlist() | false}]
def scrubbed_port_env(overrides \\ []) do
  for {k, v} <- scrubbed_cmd_env(overrides) do
    {String.to_charlist(k), if(is_nil(v), do: false, else: String.to_charlist(v))}
  end
end
```

Update the `scrubbed_cmd_env` `@doc` (it currently says "for `System.cmd`/`Port.open` call sites" — wrong for ports) to point Port callers at `scrubbed_port_env/1`.

### 2. Call-site fixes

- **`lib/jido_claw/tools/git_commit.ex:28`** — `cmd_opts = [cd: project_dir, stderr_to_stdout: true, env: Env.scrubbed_cmd_env()]`; add `alias JidoClaw.Security.Redaction.Env` (match `git_diff.ex:16`).
- **`lib/jido_claw/tools/git_status.ex:20`** — identical fix.
- **`lib/jido_claw/forge/runner/host_shell.ex`** — at the three env-build spots (lines 70, 94, 112), replace `env = Enum.map(sandbox.env, fn {k, v} -> {to_string(k), to_string(v)} end)` with `env = Env.scrubbed_cmd_env(sandbox.env)` (helper now does the coercion; sandbox-injected vars win). In `spawn/4` (line 156), extend the port opts to `[:binary, :exit_status, args: args, env: Env.scrubbed_port_env()]` — keyword sugar must stay trailing; `{:env, ...}` placed after `args:` is a syntax error. Add alias.
- **`lib/jido_claw/forge/sandbox/docker.ex:121`** — in `spawn/4`, same trailing-keyword form: `[:binary, :exit_status, args: ["exec", sandbox_name, command | args], env: Env.scrubbed_port_env()]` (alias already present).
- **`lib/jido_claw/shell/backend_host.ex:124-127`** — replace the manual `port_env` charlist build with `port_env = Env.scrubbed_port_env(env)` (session env wins over scrubbing); the port opts already use the explicit `{:env, port_env}` tuple form and stay unchanged. Add alias.

### 3. Tests

- **`test/jido_claw/security/redaction/env_test.exs`** (currently has zero `scrubbed_*` coverage) — flip the module to `async: false`: `scrubbed_cmd_env/1` enumerates the global process env via `System.get_env/0`, so async tests could observe each other's temporary fake secrets if any assertion gets exact. New describe blocks for `scrubbed_cmd_env/1` and `scrubbed_port_env/1`: a put-env'd unique `JIDO_TEST_<unique>_TOKEN` appears as `{name, nil}` / `{~c"name", false}`; an override with the same name wins (no unset tuple emitted); non-sensitive overrides pass through coerced; `nil` override value preserved as unset. Unique var names + `on_exit` cleanup.
- **`test/jido_claw/forge/runner/host_shell_test.exs`** (exists, `async: false`) — leak regressions: put fake `..._TOKEN`; `HostShell.exec(client, ~s(printf %s "$VAR"), [])` returns `{"", 0}`; after `inject_env(client, %{"INJECTED_TOKEN" => "ok"})` the injected var **is** visible (override precedence); `spawn/4` port doesn't see the fake var.
- **`test/jido_claw/tools/git_commit_test.exs`** (exists, `async: false`) — hook-leak regression: write `.git/hooks/pre-commit` that does `printf '%s' "$JIDO_TEST_..._TOKEN" > hook_leak.txt` and `File.chmod!(hook, 0o755)`, put the fake var, run `GitCommit.run/2`, then assert the commit succeeds, **`hook_leak.txt` exists** (proves the hook actually ran), and its content is `""` (proves the hook did not see the token).
- **New `test/jido_claw/shell/backend_host_test.exs`** (no coverage exists) — `init(%{session_pid: self()})`, `execute(state, ~s(printf %s "$FAKE_TOKEN"), [], [])`, collect `{:command_event, {:output, _}}` / `{:command_finished, _}` messages: fake secret absent; with `env: %{"SESSION_TOKEN" => "ok"}` in state/exec_opts, "ok" present.
- Docker `spawn/4` is `:docker_sandbox`-tagged territory (excluded by default); the one-line change mirrors the others — no new test.

### 4. Verification

1. `mix format` then targeted runs: `mix test test/jido_claw/security/redaction/env_test.exs test/jido_claw/forge/runner/host_shell_test.exs test/jido_claw/tools/git_commit_test.exs test/jido_claw/shell/backend_host_test.exs`
2. Full `mix test` — specifically watching forge/shell suites for anything that relied on inherited env.
3. `mix credo --strict` (matching the original green check) and `mix jidoclaw.compile_check` (repo's precommit gate).
4. End-to-end spot check mirroring the reviewer's repro: with a fake `CODEX_REVIEW_SECRET_TOKEN` exported, run the git-commit hook test and the HostShell exec test — child must not see it.

## Behavior-change callouts (intentional, flag for user awareness)

- **Shell tool sessions** (`BackendHost`) and **HostShell forge runs** will no longer see secret-named vars inherited from the parent (e.g. `gh` losing an ambient `GITHUB_TOKEN`). This is the established repo-wide posture; re-adding works via session env / `inject_env`, which override the scrub.
- `git commit` hooks lose ambient secrets; local add/commit/status/diff need none.
