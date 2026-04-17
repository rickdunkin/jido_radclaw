# v0.3 Code Review Fixes — VFS Bootstrap, Classifier, Iterative Workflow

## Context

The v0.3 "unified VFS across file tools and shell" milestone shipped, but a code review surfaced three accurate defects plus coordination hazards that undercut its core promise:

1. **File tools don't bootstrap the VFS workspace.** `Resolver.parse_path/2` silently falls back to local `File.*` when the workspace's `MountTable` has no entries. The only place that calls `Workspace.ensure_started/2` is `SessionManager.start_new_session/3`, so a fresh agent that calls `read_file("/project/mix.exs")` before any `run_command` fails with `:enoent`.
2. **The shell classifier misroutes host-only commands.** `check_no_metachars/1` does a MapSet-membership check on whitespace-delimited tokens. Operators attached to adjacent tokens (`cat /project/x|head`, `cat /project/x>out`) are classified as VFS-safe and executed against literal filenames.
3. **Iterative skills bypass the workspace propagation.** `RunSkill` passes `workspace_id` only to `:sequential` and `:dag`; `IterativeWorkflow.run/3` doesn't take one. Generator/evaluator steps fall back to fresh per-step workspaces — contradicting `docs/ROADMAP.md:72`.

Two additional coordination hazards surfaced during planning:

- **`project_dir` drift is invisible to `Workspace`.** `ensure_started/2` at `lib/jido_claw/vfs/workspace.ex:41` returns an existing pid without checking that the stored `project_dir` matches the incoming one. Once Resolver calls it on every file op, a reused `workspace_id` against a different repo would silently keep the stale `/project` mount.
- **Rebuilding a workspace desyncs live shell sessions.** If `SessionManager` already holds `ws -> dir_a` and a file tool rebuilds `ws` to `dir_b` via `Workspace.ensure_started/2`, the mount table flips immediately but the existing host/VFS sessions still reference `dir_a` until `SessionManager.ensure_session/3` notices drift on a later `run_command`. Between those moments, host cwd and VFS mount disagree — split-brain state.

## Critical Files

- `lib/jido_claw/vfs/resolver.ex` — opt-aware bootstrap, mount-check helper, strict error propagation
- `lib/jido_claw/vfs/workspace.ex` — `ensure_started/2` drift detection + session invalidation hook
- `lib/jido_claw/shell/session_manager.ex` — new `drop_sessions/1`; tighten `check_no_metachars/1`
- `lib/jido_claw/tools/read_file.ex` — thread `project_dir` through
- `lib/jido_claw/tools/write_file.ex` — thread `project_dir` through
- `lib/jido_claw/tools/edit_file.ex` — thread `project_dir` through
- `lib/jido_claw/tools/list_directory.ex` — call the centralized mount-check helper with full opts
- `lib/jido_claw/workflows/iterative_workflow.ex` — accept & propagate `workspace_id`; extract `build_step_params/4`
- `lib/jido_claw/tools/run_skill.ex` — pass `workspace_id` for `:iterative`
- `test/jido_claw/vfs/workspace_test.exs` — drift regression + session-invalidation coordination test
- `test/jido_claw/vfs/resolver_test.exs` — auto-bootstrap, no-bootstrap-for-URIs (with registry assertion), strict bootstrap-failure error
- `test/jido_claw/tools/read_file_test.exs` — auto-bootstrap + workspace reuse with changed project_dir
- `test/jido_claw/tools/{write_file,edit_file,list_directory}_test.exs` — auto-bootstrap sanity
- `test/jido_claw/shell/session_manager_vfs_test.exs` — embedded-operator classifier tests
- `test/jido_claw/workflows/iterative_workflow_test.exs` — unit test for `build_step_params/4`

---

## Fix 1 — Resolver auto-bootstrap + Workspace drift + session coordination

### 1a. `lib/jido_claw/vfs/workspace.ex` — drift detection, with session invalidation

Unify drift authority at the workspace layer. When `ensure_started/2` detects drift, it rebuilds the workspace *and* proactively drops any shell sessions the SessionManager is holding for that `workspace_id`. That closes the split-brain window: by the time `ensure_started/2` returns, the mount table, host session, and VFS session are all either rebuilt or invalidated — the next `run_command` will recreate the sessions consistently.

- Add `handle_call(:get_project_dir, _, state)` returning `{:reply, {:ok, state.project_dir}, state}`.
- Rewrite `ensure_started/2`:
  ```elixir
  def ensure_started(ws, pd) when is_binary(ws) and is_binary(pd) do
    case Registry.lookup(@registry, ws) do
      [{pid, _}] ->
        case GenServer.call(pid, :get_project_dir) do
          {:ok, ^pd} ->
            {:ok, pid}

          {:ok, old} ->
            Logger.warning(
              "[VFS.Workspace] project_dir drift for #{ws}: #{old} -> #{pd}; " <>
                "rebuilding workspace and invalidating shell sessions"
            )

            :ok = invalidate_shell_sessions(ws)
            :ok = teardown(ws)
            start_fresh(ws, pd)
        end

      [] ->
        start_fresh(ws, pd)
    end
  end

  defp invalidate_shell_sessions(ws) do
    case Process.whereis(JidoClaw.Shell.SessionManager) do
      nil -> :ok
      _pid -> JidoClaw.Shell.SessionManager.drop_sessions(ws)
    end
  end
  ```
- Extract today's DynamicSupervisor start logic into a private `start_fresh/2` for reuse from both branches.
- Keep `teardown/1` untouched: its current implementation doesn't touch SessionManager, so calling it from `ensure_started/2`'s drift branch *after* `invalidate_shell_sessions/1` avoids the SessionManager → Workspace → SessionManager reentrance problem.

### 1b. `lib/jido_claw/shell/session_manager.ex` — `drop_sessions/1`

Add a surgical API used only by the Workspace drift path. It stops the host + VFS sessions and removes the entry from state, but **does not** call `Workspace.teardown/1` (Workspace is already tearing itself down in the caller).

```elixir
@doc """
Stop and forget the shell sessions for `workspace_id` without tearing down
the VFS workspace. Used by `Workspace.ensure_started/2` on drift — the
workspace is already being rebuilt, so this avoids re-entry.
"""
@spec drop_sessions(String.t()) :: :ok
def drop_sessions(workspace_id) do
  GenServer.call(__MODULE__, {:drop_sessions, workspace_id})
end

# handle_call:
def handle_call({:drop_sessions, ws}, _from, state) do
  new_sessions =
    case Map.pop(state.sessions, ws) do
      {nil, sessions} ->
        sessions

      {%{host: h, vfs: v}, sessions} ->
        _ = ShellSession.stop(h)
        _ = ShellSession.stop(v)
        sessions
    end

  {:reply, :ok, %{state | sessions: new_sessions}}
end
```

`SessionManager.stop_session/1` keeps its existing behavior (stops sessions + tears down workspace) for the general "I'm done with this workspace" case. `ensure_session/3`'s own drift check (line 162) stays as defense-in-depth — it would now only fire if someone called `run_command` with a project_dir that differs from the Workspace's stored value *without* first going through `Workspace.ensure_started/2`. Expected to be unreachable in practice once Resolver bootstraps uniformly, but cheap to keep.

### 1c. `lib/jido_claw/vfs/resolver.ex` — strict opts-aware bootstrap + routing helper

1. Extend the `opts` contract for `read/2`, `write/3`, `ls/2` to accept `:project_dir`.
2. Add a `maybe_ensure_workspace/2` helper that distinguishes **not attempted** from **attempted-and-failed**. Bootstrap failures are no longer swallowed:
   ```elixir
   # :ok        — bootstrap not needed, or succeeded
   # {:error,_} — bootstrap attempted and failed (caller must return this)
   defp maybe_ensure_workspace(path, opts) do
     cond do
       remote?(path) ->
         :ok

       not String.starts_with?(path, "/") ->
         :ok

       true ->
         ws = Keyword.get(opts, :workspace_id)
         pd = Keyword.get(opts, :project_dir)

         if is_binary(ws) and ws != "" and is_binary(pd) and pd != "" do
           case JidoClaw.VFS.Workspace.ensure_started(ws, pd) do
             {:ok, _pid} -> :ok
             {:error, reason} -> {:error, {:workspace_bootstrap_failed, reason}}
           end
         else
           :ok
         end
     end
   end
   ```
   Each of `read/2`, `write/3`, `ls/2` wraps its body in `with :ok <- maybe_ensure_workspace(path, opts) do ... end`, so a bootstrap failure surfaces as `{:error, {:workspace_bootstrap_failed, reason}}` instead of silently falling through to local `File.*`.
3. Add a public `under_workspace_mount?/2` that accepts the **same opts** as `read/2` (not just `workspace_id`). It bootstraps via `maybe_ensure_workspace/2` before consulting the mount table, so callers branching on the result get correct routing on a fresh workspace:
   ```elixir
   @spec under_workspace_mount?(String.t(), keyword()) :: boolean()
   def under_workspace_mount?(path, opts) do
     with :ok <- maybe_ensure_workspace(path, opts),
          ws when is_binary(ws) and ws != "" <- Keyword.get(opts, :workspace_id),
          true <- String.starts_with?(path, "/") do
       match?({:ok, _, _}, Jido.Shell.VFS.MountTable.resolve(ws, path))
     else
       _ -> false
     end
   end
   ```
4. Update `@doc` blocks for the new `:project_dir` option.

### 1d. `lib/jido_claw/tools/{read_file,write_file,edit_file,list_directory}.ex`

- In each tool's `run/2`, extract `project_dir = get_in(context, [:tool_context, :project_dir]) || File.cwd!()` (matches the pattern in `run_command.ex:61` and `run_skill.ex:48`).
- Pass `workspace_id: workspace_id, project_dir: project_dir` into `Resolver.read/write/ls/under_workspace_mount?`.
- `list_directory.ex`: delete the local `under_workspace_mount?/2` at line 82. Replace the call site (line 52) with `Resolver.under_workspace_mount?(path, workspace_id: workspace_id, project_dir: project_dir)`. No duplicate bootstrap.

### Tests

- `test/jido_claw/vfs/workspace_test.exs`:
  - "drift detection rebuilds the workspace and points `/project` at the new dir": start `W` with `dir_a`, create `dir_b` with a distinct file, call `ensure_started(W, dir_b)`, assert `Jido.Shell.VFS.read_file(W, "/project/<dir_b_only_file>")` succeeds and reading a `dir_a`-only file fails.
  - "drift detection invalidates SessionManager sessions for the workspace": bootstrap `ws` via `SessionManager.run(ws, "true", ..., project_dir: dir_a)`, confirm `SessionManager.cwd(ws, :host) == {:ok, dir_a}`, then call `Workspace.ensure_started(ws, dir_b)`, assert `SessionManager.cwd(ws, :host) == {:error, :no_session}` (sessions were dropped; next `run_command` would rebuild them).
  - "no drift → same pid, same sessions": `ensure_started(W, same_dir)` returns the original pid; SessionManager sessions still alive.
- `test/jido_claw/vfs/resolver_test.exs`:
  - "auto-bootstraps when `:project_dir` opt is passed": a brand-new `workspace_id` + `project_dir` with no prior `Workspace.ensure_started/2` call reads `/project/foo.txt` successfully.
  - "does not bootstrap without `:project_dir`": existing MountTable-miss behavior (falls back to local).
  - "does not bootstrap for remote URIs": pass `:workspace_id` + `:project_dir` alongside `github://...` — assert `Registry.lookup(JidoClaw.VFS.WorkspaceRegistry, ws) == []` after the call. This verifies no workspace was started, not just "no raise."
  - "surfaces bootstrap failure instead of silently falling through": pass `:project_dir` = `""` (rejected by `Workspace.to_adapter_spec(:local, ...)` as `:local_missing_path`). Assert `{:error, {:workspace_bootstrap_failed, _}}` rather than a local fallback result.
- `test/jido_claw/tools/read_file_test.exs`:
  - "auto-bootstraps VFS when tool_context carries workspace_id + project_dir" (reviewer's repro).
  - "workspace reuse with a different project_dir picks up the new mount": call `ReadFile.run` with `ws1 + dir_a`, then again with `ws1 + dir_b` reading a file only in `dir_b`. Second call must succeed with `dir_b`'s content. Proves file-tool-initiated drift works end-to-end.
- `test/jido_claw/tools/{write_file,edit_file,list_directory}_test.exs`:
  - One auto-bootstrap test each (no duplication of the drift test; it's covered in `read_file_test.exs`).

---

## Fix 2 — Classifier rejects embedded shell operators

### `lib/jido_claw/shell/session_manager.ex`

- Keep `@host_forcing_tokens` as-is — `||` stays so `cat /project/x || true` still routes to host.
- Rewrite `check_no_metachars/1` to catch embedded operators while exempting only `&&` (the one whole-token chain that is sandbox-safe today). **`;` stays out of the embedded list** — `Jido.Shell.Command.Parser.parse_program/1` already models semicolon chaining, and a `;` inside a token means the parser has chain-split it. Forcing host on embedded `;` would be broader than the original design.

```elixir
@embedded_forcing_chars ["|", ">", "<", "`", "$(", "${", "&"]

defp check_no_metachars(command) do
  command
  |> String.split(~r/\s+/, trim: true)
  |> Enum.reduce_while(:ok, fn token, :ok ->
    cond do
      token == "&&" ->
        {:cont, :ok}

      MapSet.member?(@host_forcing_tokens, token) ->
        {:halt, :fallback_to_host}

      String.contains?(token, @embedded_forcing_chars) ->
        {:halt, :fallback_to_host}

      true ->
        {:cont, :ok}
    end
  end)
end
```

Trace:
- `cd /project && cat /project/mix.exs` — `&&` carved out, others clean → VFS ✓
- `cat /project/x || true` — `||` token is in `@host_forcing_tokens` → host ✓
- `cat /project/x|head` — `/project/x|head` contains `|` → host ✓
- `cat /project/x>out` / `>>log` / `<in` — embedded `>`/`<` → host ✓
- `foo&bar` — embedded `&` → host ✓
- `cat /project/a;cat /project/b` — parser chain-splits `;`, remaining tokens clean → VFS (matches original design)

### Tests

Add to `test/jido_claw/shell/session_manager_vfs_test.exs` under the `classifier` describe:

- `cat /project/README.md|head` → `:host`
- `cat /project/x>out` → `:host`
- `cat /project/x>>log` → `:host`
- `cat</project/in` → `:host`
- `foo&bar` → `:host`
- Regression: `cd /project && cat /project/mix.exs` → `:vfs` (the `&&` carveout still works)
- Regression: `cat /project/README.md || true` → `:host` (confirms `||` remains host-only)
- Keep the existing `echo '|'` test as-is.

---

## Fix 3 — Iterative workflow propagates `workspace_id` with a real test seam

### `lib/jido_claw/workflows/iterative_workflow.ex`

- Promote `run/3` to `run/4` with `opts \\ []`. Pull `workspace_id = Keyword.get(opts, :workspace_id)` at the top.
- Thread `workspace_id` through `iterate/N` — simplest path is to add it as an argument; if arity becomes unwieldy, bundle `{extra_context, project_dir, workspace_id}` into a private config map built once in `run/4`.
- **Extract the param construction into a public-for-test helper**:
  ```elixir
  @doc false
  @spec build_step_params(map(), String.t(), String.t(), String.t() | nil) :: map()
  def build_step_params(step, task, project_dir, workspace_id) do
    %{
      template: step.template,
      task: task,
      project_dir: project_dir,
      name: step.name
    }
    |> maybe_put(:workspace_id, workspace_id)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
  ```
- Both generator and evaluator call sites (currently `iterative_workflow.ex:175` and `:204`) delegate to `build_step_params/4` and pass the returned map to `StepAction.run(params, %{})`. `StepAction.resolve_workspace_id/3` (`step_action.ex:127`) already prefers `params[:workspace_id]`, so no change there.

### `lib/jido_claw/tools/run_skill.ex`

Replace the `:iterative` branch at `run_skill.ex:58-60`:

```elixir
:iterative ->
  JidoClaw.Workflows.IterativeWorkflow.run(
    skill,
    extra_context,
    project_dir,
    workspace_id: workspace_id
  )
```

Delete the `# IterativeWorkflow has its own signature — no workspace plumbing yet.` comment.

### Tests

In `test/jido_claw/workflows/iterative_workflow_test.exs`, add `describe "build_step_params/4"`:
- Includes `:workspace_id` when a non-nil binary is passed.
- Omits `:workspace_id` entirely when `nil` (so `StepAction.resolve_workspace_id/3`'s fallback chain still applies for legacy callers).
- Populates `template`, `task`, `project_dir`, `name` from the step/opts.

No arity-export checks — the helper test proves actual propagation.

---

## Verification

After implementing:

1. `mix format`.
2. `mix compile` (not `--warnings-as-errors` — pre-existing anubis_mcp redefinition warnings are out of scope; do not treat that flag as a gate).
3. Focused test sweep:
   ```
   mix test \
     test/jido_claw/vfs/workspace_test.exs \
     test/jido_claw/vfs/resolver_test.exs \
     test/jido_claw/shell/session_manager_vfs_test.exs \
     test/jido_claw/tools/read_file_test.exs \
     test/jido_claw/tools/write_file_test.exs \
     test/jido_claw/tools/edit_file_test.exs \
     test/jido_claw/tools/list_directory_test.exs \
     test/jido_claw/workflows/iterative_workflow_test.exs
   ```
4. `mix test` full suite — no regressions elsewhere.
5. The reviewer's `ReadFile.run(..., tool_context: %{workspace_id: "ws-no-mount-...", project_dir: tmp})` scenario is codified as the "auto-bootstraps VFS when tool_context carries workspace_id + project_dir" test in `read_file_test.exs`. No manual `Application.ensure_all_started(:jido_claw)` repro — dev-time Endpoint/Discord startup can fail and muddy the signal; ExUnit brings up only what's needed.
6. Classifier manual smoke (optional, not a gate): in `iex -S mix`, once app boot is clean, spot-check `SessionManager.classify/2` for the pipe/redirect/chain cases. Authoritative coverage is in the test suite above.
