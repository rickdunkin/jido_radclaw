# v0.3 — VFS Integration for File Tools (Maximal Scope, Revised)

## Context

The roadmap's v0.3 milestone calls for a unified VFS so file tools and shell commands share a mount-point namespace — an agent should be able to `cat /project/mix.exs` and `cat /upstream/mix.exs` in the same workflow.

Audit shows ~70% of the scaffolding is already in place, unwired:
- `JidoClaw.VFS.Resolver` (`lib/jido_claw/vfs/resolver.ex`) routes URI schemes to `jido_vfs` adapters.
- `ReadFile`, `WriteFile`, `ListDirectory` already use the Resolver.
- `jido_shell` (dep) ships `Jido.Shell.VFS` + `MountTable` + `FilesystemSupervisor` — workspace-scoped mount API.
- `jido_shell` also ships a VFS-aware sandbox: `Jido.Shell.Backend.Local` + built-in commands (`cat`, `ls`, `cd`, `pwd`, `mkdir`, `rm`, `cp`, `echo`, `write`, `env`, `bash`) that resolve all paths through `Jido.Shell.VFS.read_file(workspace_id, path)`. See `deps/jido_shell/lib/jido_shell/command/cat.ex:30`, `cd.ex:36`.
- `EditFile` bypasses the Resolver. `SearchCode` stays local-only (user deferred).
- `SessionManager.start_new_session/2` uses `BackendHost` with `cwd: File.cwd!()` and no mounts.

The approach: **two backends per workspace** — keep BackendHost for host-shell commands (unchanged), add a parallel VFS sandbox session via `Jido.Shell.Backend.Local` for VFS-aware built-ins. `SessionManager.run/4` classifies the command and routes.

## Approach — Dual-session routing

Per workspace, `SessionManager` holds two jido_shell sessions:

1. **Host session** — `BackendHost`, `cwd = project_dir`. Runs real `sh -c` for anything that needs host binaries (`git`, `mix`, `npm`, pipelines, subshells). Behavior matches today.
2. **VFS session** — `Jido.Shell.Backend.Local`, workspace mounted with `/project → Local(project_dir)` plus config-declared mounts. Handles `cat`, `ls`, `cd`, `pwd`, `mkdir`, `rm`, `cp`, `echo`, `write`, `env`, `bash -c "<sandbox-script>"`. All paths resolve through `Jido.Shell.VFS` with the workspace's mount table. VFS session cwd starts at `/project`.

**Classifier — VFS route is strictly opt-in.** `SessionManager.run/4` sends a command to the VFS session only when **all** of the following hold:

1. `Jido.Shell.Command.Parser.parse_program/1` (`deps/jido_shell/lib/jido_shell/command/parser.ex:46`) succeeds. The parser is quote-aware (`echo '|'` tokenizes `|` as a literal arg) and handles `;` / `&&` chaining. Parse error (unclosed quotes, unrecognized structure) → host.
2. Every command in the parsed program is in the sandbox allowlist (`cat`, `ls`, `cd`, `pwd`, `mkdir`, `rm`, `cp`, `echo`, `write`, `env`, `bash`).
3. **No token across the whole program is a shell operator** that the parser doesn't model. This is a token-set check: `|`, `||`, `>`, `>>`, `<`, `&`, `2>&1`, or any token containing backticks, `$(…)`, or `${…}`. This is the only catch for pipe/redirect — because parser tokenization strips the quote info, `echo '|'` will also be forced to host. Accept the minor false positive; the agent can use `force: :vfs` if they really need a literal pipe char.
4. At least one argument (across all commands in the program) is an absolute path that `Jido.Shell.VFS.MountTable.resolve(workspace_id, path)` returns `{:ok, _, _}` for. Using `MountTable.resolve/2` (not a separate prefix matcher) keeps routing aligned with actual VFS resolution semantics.
5. **All** absolute path args resolve to a mount — no mixing host paths and mount paths in one command.

Otherwise → host. This keeps today's behavior for `cat README.md`, `ls`, `git status`, `cat /tmp/foo`, `cat /project/x | head` (token `|` → host), `mix test`. Mount paths are only used when the agent explicitly asks for `/project/...` or `/upstream/...` in a simple sandbox-native program.

**Caveat about VFS `cd` state.** Because bare `ls`, `pwd`, and `cat relative/path` all lack a mount-prefixed arg, they route to host, which means the VFS session's working directory is only observable when the agent uses `cd X && cat Y` (chained within one classifier call) or passes `force: :vfs`. Document this clearly in the tool description.

`run_command` grows an optional `force: :host | :vfs` override for the rare cases where the classifier is wrong or the agent wants to drive the VFS session directly — documented in the tool description so the agent can self-correct.

File tools (`ReadFile`, `WriteFile`, `EditFile`, `ListDirectory`) go through `Resolver` with a new `{:vfs, workspace_id, path}` branch that calls `Jido.Shell.VFS.read_file/2` / `write_file/3` / `list_dir/2` — same mount table as the VFS session. On `MountTable.resolve/2 → :no_mount`, Resolver falls through to host `File.*` so `/tmp/foo`, `/Users/...` keep working.

**Workspace identity = session identity.** Use the existing `session_id` (REPL, `JidoClaw.chat/3`) as `workspace_id`. No parallel namespace, no slug/hash — the logical ID is never used as a filesystem path in this design. `RunCommand`'s schema keeps its `"default"` default so existing tests and non-agent callers continue to work unchanged; Resolver's `:no_mount` fallback makes missing mount tables harmless.

**`project_dir` is threaded, not inferred.** `RunCommand` reads both `workspace_id` and `project_dir` from `tool_context` (REPL and `chat/3` already put `project_dir` there) and passes both to `SessionManager.run/4`. SessionManager uses the `project_dir` from the first call for a given workspace_id to bootstrap the sessions + mounts. If a subsequent `run/4` arrives for the same workspace_id with a **different** `project_dir`, SessionManager tears down the existing sessions and rebuilds — log a warning about the drift. `"default"` workspace_id collisions across callers become self-healing this way instead of silently sharing state.

## Phase 1 — VFS Workspace process + mount bootstrap

**New module:** `lib/jido_claw/vfs/workspace.ex` (GenServer, one per workspace_id, registered via `Registry`).
- `ensure_started(workspace_id, project_dir)` — idempotent; returns `{:ok, pid}` or `{:error, reason}`. `project_dir` is **required and explicit** so the mount source always matches the caller's session context (REPL/chat/workflow), never drifting from `File.cwd!()`. On init, the workspace calls `JidoClaw.Config.load(project_dir)` directly (not the default-arity form) to avoid the same `File.cwd!()` drift in config loading (`lib/jido_claw/core/config.ex:66`). **The default `/project` mount is fail-fast**: if it can't be established, init errors out and `ensure_started` returns `{:error, _}`. Without `/project`, the VFS session has no useful state.
- `mounts(workspace_id)` — returns `Jido.Shell.VFS.list_mounts/1`.
- `mount(workspace_id, path, adapter_key, user_opts)` — accepts a config-friendly adapter key + opts map and **translates to the real `jido_vfs` adapter option shape** (see translation table below) before calling `Jido.Shell.VFS.mount/4`. Emits telemetry. **For non-default mounts only**: wraps the mount call in `try/rescue` (some adapters like `Jido.VFS.Adapter.Git` can raise during `configure/1` — see `deps/jido_vfs/lib/jido_vfs/adapter/git.ex:79`); any rescue path logs `Logger.warning` and continues. `{:error, _}` returns from `Jido.Shell.VFS.mount/4` are treated the same way. Default `/project` mount bypasses the rescue and propagates errors.
- `teardown(workspace_id)` — `Jido.Shell.VFS.unmount_workspace/2` then stop the GenServer.

**Adapter option translation (Workspace is the only place that knows this mapping):**

| Config key | Adapter module | Translation |
|---|---|---|
| `local`    | `Jido.VFS.Adapter.Local`    | `path: X` → `prefix: X` (`deps/jido_vfs/lib/jido_vfs/adapter/local.ex:80`) |
| `in_memory`| `Jido.VFS.Adapter.InMemory` | pass through `name:` |
| `github`   | `Jido.VFS.Adapter.GitHub`   | `owner:`, `repo:`, `ref:` pass through; `auth:` from `GITHUB_TOKEN` if present, else omitted. **Public repos work without auth**, so no pre-flight warning (`deps/jido_vfs/lib/jido_vfs/adapter/github.ex:97`). A failed fetch later logs a warning with a hint about `GITHUB_TOKEN`. |
| `s3`       | `Jido.VFS.Adapter.S3`       | `bucket: X` + `config: [region: Y, …]` shape (`deps/jido_vfs/lib/jido_vfs/adapter/s3.ex:279`). Pull region from env/config. |
| `git`      | `Jido.VFS.Adapter.Git`      | `path:` pass through. |

On init, the workspace reads configuration:
- **Default**: `mount("/project", :local, path: project_dir)`.
- **Config-driven extras** from `JidoClaw.Config` under `vfs.mounts` (see Phase 4).

**New module:** `lib/jido_claw/vfs/workspace_supervisor.ex` — `DynamicSupervisor`.
**New module:** `JidoClaw.VFS.WorkspaceRegistry` — `Registry` (unique keys).

**Modified** `lib/jido_claw/application.ex` — add `{Registry, keys: :unique, name: JidoClaw.VFS.WorkspaceRegistry}` and `JidoClaw.VFS.WorkspaceSupervisor` in `core_children/0`, **before** the existing `SessionManager`.

## Phase 2 — Dual-session SessionManager

**Modified** `lib/jido_claw/shell/session_manager.ex`:
- `defstruct sessions: %{}` — value becomes `%{host: session_id, vfs: session_id, project_dir: path}`.
- New `run/4` signature: `run(workspace_id, command, timeout, opts)` where `opts` includes `project_dir:` (required in the new code path; defaults to `File.cwd!()` only in `run/3` for legacy callers) and `force: :host | :vfs | nil`.
- `ensure_session(ws, project_dir, state)`:
  - If no session exists: `start_new_session(ws, project_dir, state)`.
  - If session exists but `state.sessions[ws].project_dir != project_dir`: `Logger.warning` about the drift, tear down and rebuild.
- `start_new_session(workspace_id, project_dir, state)` is a `with` chain with unwind on partial failure. **Both sessions share the same `workspace_id`** so they look up mounts in the shared MountTable; only the `session_id:` opt distinguishes them:
  1. `{:ok, _pid} <- JidoClaw.VFS.Workspace.ensure_started(workspace_id, project_dir)`.
  2. `{:ok, host_id} <- ShellSession.start(workspace_id, session_id: "#{workspace_id}:host", cwd: project_dir, backend: {BackendHost, %{}})`.
  3. `{:ok, vfs_id} <- ShellSession.start(workspace_id, session_id: "#{workspace_id}:vfs", cwd: "/project", backend: {Jido.Shell.Backend.Local, %{workspace_id: workspace_id}})`.
  4. On any failure, a `cleanup_failed_start/3` helper unwinds whatever succeeded: stops any started sessions and calls `Workspace.teardown/1`. Returns `{:error, reason}` with no leaked state.
- `handle_call({:run, ws, cmd, t, opts}, …)`:
  1. `ensure_session(ws, opts[:project_dir], state)` returns both session IDs.
  2. If `opts[:force]` is set → route directly. Otherwise, `classify(cmd, ws)` → `:vfs` or `:host` using `Jido.Shell.VFS.MountTable.resolve(ws, path)` per absolute-path arg (no separate prefix matcher).
  3. Route to `execute_command(session_ids[target], cmd, timeout)`.
- `stop_session/1` (current line 95) tears down both sessions **and** calls `JidoClaw.VFS.Workspace.teardown(workspace_id)`.
- `cwd/1` stays single-valued and returns the **host cwd** — that matches today's API semantics and avoids breaking callers. Add `cwd(workspace_id, :vfs)` if a second read is ever needed.

**No changes to `BackendHost`.** Its behavior is preserved bit-for-bit — existing workflows (`git status`, `mix test`, pipes, redirects) keep working against the real project dir. No staging dir, no cwd change, no symlinks.

## Phase 3 — Resolver + file tools

**Modified** `lib/jido_claw/vfs/resolver.ex`:
- Extend `read/1`, `write/2`, `ls/1` to accept an optional `opts` keyword list with `:workspace_id`.
- Before the `{:local, path}` fall-through in `parse_path/1`, add a new branch that triggers only when:
  - `workspace_id` is present,
  - path starts with `/` and is not a URI,
  - `Jido.Shell.VFS.MountTable.resolve(workspace_id, path)` returns `{:ok, mount, rel}`.
  Only then route through `Jido.Shell.VFS.read_file/2` / `write_file/3` / `list_dir/2`. On `:no_mount`, continue to the existing `{:local, path}` branch — no regression for `/tmp/foo`, `/Users/...`, absolute paths outside a mount.
- **Fix the API surface to match `Jido.Shell.VFS`:** `read_file/2`, `write_file/3`, `list_dir/2` return stat structs (not bare names). Resolver's `ls` branch maps `list_dir` results to `& &1.name` to preserve the existing public return shape (`{:ok, [String.t()]}`).

**Modified file tools:**
- `lib/jido_claw/tools/read_file.ex` (line 33), `write_file.ex` (line 31), `list_directory.ex` (line 35): read `workspace_id = get_in(context, [:tool_context, :workspace_id])` and pass it through to `Resolver.*`.
- `lib/jido_claw/tools/edit_file.ex` (lines 25, 41): replace `File.read/1` and `File.write/2` with `Resolver.read(path, workspace_id: ws)` / `Resolver.write(path, content, workspace_id: ws)`.

**workspace_id + project_dir plumbing — the full list of callers to update:**
- `lib/jido_claw/cli/repl.ex:196` — `tool_context: %{project_dir: state.cwd, workspace_id: state.session_id}`.
- `lib/jido_claw.ex:59` — `tool_context: %{project_dir: File.cwd!(), workspace_id: session_id}`.
- `lib/jido_claw/workflows/step_action.ex:30` — today invents a new workspace_id when none is passed, giving each workflow step an isolated workspace. Change: accept `workspace_id` and `project_dir` from the incoming context and pass them into tool invocations. If genuinely absent, fall through to the current invent-a-new-id behavior (tests rely on that).
- `lib/jido_claw/workflows/skill_workflow.ex:113` and `lib/jido_claw/workflows/plan_workflow.ex:292` — currently call `StepAction.run/2` with empty context. Thread the caller's `workspace_id` and `project_dir` through so a multi-step skill or plan shares one VFS/shell workspace across steps.
- `lib/jido_claw/tools/spawn_agent.ex:53` — propagate parent's `workspace_id` and `project_dir` into the spawned agent's tool_context so sub-agents share the mount table.
- `lib/jido_claw/tools/send_to_agent.ex:38` — same.
- `lib/jido_claw/tools/run_command.ex:33` — currently only reads `workspace_id` from context. Must also read `project_dir = get_in(context, [:tool_context, :project_dir]) || File.cwd!()` and pass it to `SessionManager.run/4` as `project_dir:`. Keep the `workspace_id` `"default"` fallback for legacy callers. Add a `force: :host | :vfs | nil` param passed through to `SessionManager.run/4`.

## Phase 4 — Config-driven mounts

**Modified** `lib/jido_claw/core/config.ex` (module is `JidoClaw.Config`) — add a `vfs.mounts` schema key:

```yaml
# .jido/config.yaml
vfs:
  mounts:
    - path: /scratch
      adapter: in_memory
    - path: /upstream
      adapter: github
      owner: anthropic
      repo: anthropic-sdk-python
      ref: main     # optional, defaults to "main"
    - path: /artifacts
      adapter: s3
      bucket: my-builds
      region: us-east-1   # optional; falls back to AWS_REGION / ex_aws config
```

`JidoClaw.VFS.Workspace.ensure_started/2` reads this list and calls the workspace's `mount/4` for each after the default `/project` mount. The workspace's internal translation layer converts these to real adapter opts (`path:` → `prefix:` for Local, `{bucket:, config:}` shape for S3). Mount failures (missing bucket, bad region, network-dependent validation) → `Logger.warning` + skip that specific mount; session startup still succeeds. GitHub public repos work credential-free; the warning only fires on actual fetch failure.

Document the fail-soft behavior in `JidoClaw.VFS.Workspace`'s moduledoc.

## Phase 5 — Tests

All tests use `workspace_id = "test-#{System.unique_integer([:positive])}"` with an `on_exit` calling `JidoClaw.VFS.Workspace.teardown/1` to prevent ETS cross-contamination in `Jido.Shell.VFS.MountTable`.

**New** `test/jido_claw/vfs/workspace_test.exs`
- Default `/project` mount bootstraps.
- `/project` bootstrap failure → `ensure_started/2` returns `{:error, _}` (fail-fast).
- Non-default mount (e.g. S3 with a bad config) → `Logger.warning` + other mounts still succeed.
- `mount/4` for InMemory works; writes round-trip.
- `teardown/1` unmounts + stops the GenServer; subsequent `list_mounts` returns `[]`.

**New** `test/jido_claw/vfs/resolver_test.exs`
- URI branches unchanged.
- New `{:vfs, ws, path}` branch round-trips via InMemory mount.
- `:no_mount` fallback: `/tmp/some-host-path` still routes to `File.*` when workspace_id is passed.
- Fallback when `workspace_id: nil` (legacy callers).

**Modified** `read_file_test.exs`, `write_file_test.exs`, `edit_file_test.exs`, `list_directory_test.exs`
- Add cases using `tool_context: %{workspace_id: ws}` with an InMemory mount.
- Existing `tmp_dir` tests still pass (fallback path).

**New** `test/jido_claw/shell/session_manager_vfs_test.exs`
- Classifier routes `cat /project/README.md` to VFS; `git --version` to host; `cat /project/x | head` to host (pipe token); `cat /tmp/foo` to host (no mount); `cat /project/x /tmp/foo` to host (mixed); `ls` (no args) to host; `echo '|'` to host (accepted false positive); `cd /project && cat /project/mix.exs` to VFS (chained allowlist + mount args).
- `force: :host` sends `cat /project/x` to host anyway; `force: :vfs` sends `ls` to VFS.
- Two sessions have distinct CWDs (VFS=`/project`, Host=project_dir).
- Reusing the same workspace_id with a different project_dir triggers a rebuild (assert via telemetry or new session PID).
- **Partial startup failure**: stub `ShellSession.start` to fail on the second session — assert both the workspace and the first session are cleaned up; `SessionManager` state has no leak.
- `stop_session/1` tears down both sessions + unmounts.
- `cat /project/mix.exs` returns the real `mix.exs` content.
- GitHub mount: fetch failure logs a warning with a `GITHUB_TOKEN` hint (stub the adapter to return an error — no real network).

**Modified** `test/jido_claw/workflows/*_test.exs`
- Skill workflow with `workspace_id` in caller context: assert every step sees the same `workspace_id` in its tool_context (i.e., `StepAction` doesn't invent a new one when one was passed).
- Same for plan workflow.

Deterministic only — no real GitHub or S3 hits. `Jido.VFS.Adapter.InMemory` is the only remote-style adapter used in tests.

## Critical files to modify

| File | Change |
|---|---|
| `lib/jido_claw/vfs/resolver.ex` | Add `:vfs` branch + `:workspace_id` opt; fix `list_dir` result shape. |
| `lib/jido_claw/shell/session_manager.ex` | Dual sessions, command classifier, teardown hook. |
| `lib/jido_claw/application.ex` | Register WorkspaceRegistry + WorkspaceSupervisor. |
| `lib/jido_claw/tools/edit_file.ex` | Route through Resolver. |
| `lib/jido_claw/tools/read_file.ex`, `write_file.ex`, `list_directory.ex` | Thread workspace_id from tool_context. |
| `lib/jido_claw/tools/run_command.ex` | Add `force: :host | :vfs` passthrough; keep `"default"` workspace fallback. |
| `lib/jido_claw/tools/spawn_agent.ex`, `send_to_agent.ex` | Propagate workspace_id + project_dir to sub-agents. |
| `lib/jido_claw/workflows/step_action.ex` | Accept workspace_id/project_dir from context; fall back to current behavior when absent. |
| `lib/jido_claw/workflows/skill_workflow.ex`, `plan_workflow.ex` | Thread workspace_id/project_dir into `StepAction.run/2`. |
| `lib/jido_claw/cli/repl.ex`, `lib/jido_claw.ex` | Put `workspace_id: session_id` + `project_dir` into tool_context. |
| `lib/jido_claw/core/config.ex` (`JidoClaw.Config`) | Schema for `vfs.mounts`. |

**New files**: `lib/jido_claw/vfs/workspace.ex`, `lib/jido_claw/vfs/workspace_supervisor.ex`, plus test files listed above. `BackendHost` is unchanged.

## Risks / edge cases

1. **Classifier false positives on quoted metachars.** `echo '|'` tokenizes `|` as a literal arg but the token-level metachar check will force it to host. Accept as a minor inconvenience; `force: :vfs` is the escape hatch.
2. **`bash -c "..."` runs the jido_shell sandbox script language, not host bash.** Document clearly in the agent's system prompt. Agents that want real bash must not pass `bash -c` — write the body directly (`git status`, not `bash -c 'git status'`).
3. **VFS `cd` state only visible within a single chained invocation or under `force: :vfs`.** Bare `ls` and `pwd` always go to host because they have no mount-prefix args. Document this tradeoff in the `run_command` tool description.
4. **`cd` persistence is per-session.** `cd` on the host side doesn't affect the VFS session and vice versa. Document in the system prompt.
5. **`/project` bootstrap is mandatory.** If it can't be mounted, `ensure_started/2` errors — don't swallow. Extra mounts (`/upstream`, `/artifacts`, …) are fail-soft: warn and continue. The `Workspace.mount/4` implementation wraps non-default mounts in `try/rescue` because some adapters raise (e.g., `Jido.VFS.Adapter.Git`).
9. **Partial startup failure in `SessionManager.start_new_session/3`.** If the workspace starts but one session fails, the `with` chain unwinds: stop the other session (if already started) and `Workspace.teardown/1`. No leaked sessions or mounts. Covered by a dedicated test.
10. **Workflow continuity.** Without threading `workspace_id` + `project_dir` through `SkillWorkflow`/`PlanWorkflow` → `StepAction`, each step gets an isolated workspace and shell state doesn't persist across steps. Phase 3 plumbs this; regression tests cover it.
6. **Mount state lost on node restart.** `Jido.Shell.VFS.MountTable` is ETS. `Workspace` re-bootstraps on start, so fine for single-node. Flag for v0.6.
7. **Parallel test contamination.** MountTable is global ETS keyed by workspace_id — unique per-test IDs plus `on_exit` teardown is mandatory.
8. **workspace_id reuse with different `project_dir`.** SessionManager detects drift and rebuilds the sessions + workspace, with a warning log. Prevents `"default"` collisions from silently sharing state.

## Verification

End-to-end checks before declaring v0.3 complete:

1. `mix compile --warnings-as-errors` — strict compile.
2. `mix format --check-formatted` — format gate.
3. `mix test` — full suite green (existing 772 + new VFS tests, no flakes).
4. Manual REPL smoke (`mix jidoclaw`):
   - `read_file` tool with `/project/mix.exs` → returns mix.exs contents (VFS path).
   - `read_file` tool with `/tmp/foo` (create ahead of time) → returns via host fallback.
   - `run_command` with `cat /project/mix.exs` → returns contents via VFS session.
   - `run_command` with `git status` → works via host session, unchanged.
   - `run_command` with `mix test --help` → host session, unchanged.
   - With a GitHub mount in `.jido/config.yaml`: `run_command` `cat /upstream/README.md` → fetches through `Jido.VFS.Adapter.GitHub`.
5. Tidewave MCP spot checks:
   - `project_eval` `Jido.Shell.VFS.list_mounts("repl-<uuid>")` after a REPL session is open — returns the expected mount list.
   - `get_source_location` for `JidoClaw.VFS.Workspace` confirms module loaded.
6. Update `docs/ROADMAP.md`: v0.3 → **Status: Complete**; decide whether the current-state `v0.3.0` header advances to `v0.4.0-dev`.

## Out of scope (explicit)

- `SearchCode` remote support — deferred (user decision).
- GitHub/S3 writes from the shell — VFS adapters are read-only for GitHub; S3 is write-capable but not exposed to the shell command surface in this milestone.
- VFS-aware diffing across adapters — mentioned in the roadmap but not a v0.3 gate.
- Persisting mount table across node restarts — defer to v0.6.
- FUSE / chroot / host-shell path rewriting — rejected; dual-session avoids the problem.
