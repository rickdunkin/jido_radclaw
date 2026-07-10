---
type: subsystem
description: Per-tool-call human-approval checkpoint on the conversation axis — durable run-less AgentCases, single-use approvals, the fail-closed shell floor.
sources:
  - lib/jido_claw/security/tool_approval.ex
  - lib/jido_claw/security/tool_approval/mount_config_cache.ex
  - lib/jido_claw/vfs/adapter_policy.ex
  - lib/jido_claw/core/config.ex
  - lib/jido_claw/orchestration/tool_approvals.ex
  - lib/jido_claw/orchestration/case_producer.ex
  - lib/jido_claw/security/shell_command.ex
  - lib/jido_claw/orchestration/cases.ex
  - lib/jido_claw/agent/templates.ex
verified: 2026-07-10
verified_sha: "b2cae5cd"
---

# Tool Approval Gate

## What & why

A per-tool-call human-approval checkpoint on the conversation axis, complementing the
workflow-axis Reactor gate family. Dangerous tools (and dangerous *parameterizations*
of broad tools like `run_command`) park as durable approval cases an operator decides
on the same surfaces as workflow gates.

## Invariants & contracts

- The shared `Tools.Action` wrapper runs `JidoClaw.Security.ToolApproval.gate/4` as its
  FIRST stage (before redact/shape/cap). A require-listed tool **or** a param-pattern
  trigger routes through `JidoClaw.Orchestration.ToolApprovals.request/3`.
- The producer maps a canonical `{tenant, session, tool, args}` fingerprint to a
  durable run-less `AgentCase` (kind `:tool_call`) and the tool returns a non-retryable
  `{:error, %{code: :approval_pending | :approval_denied | :approval_unavailable}}`
  envelope the LLM relays.
- Approvals are **single-use** (`:consume`), rejections are **deny-once**
  (`:consume_rejection`). The FOR-UPDATE re-read in the producer transaction is the
  real concurrency fence — the `change filter` on the case actions is not a DB fence in
  ash_postgres 2.9 — and the named partial unique index
  `agent_cases_pending_fingerprint_index` collapses the open race.
- **Shell-floor reach (S-M1)**: the `run_command` param-pattern runs
  `JidoClaw.Security.ShellCommand.analyze/1`, whose fail-closed `:opaque` floor gates
  on the flag/reach alone, never by parsing the wrapped code, and fails closed on any
  dynamic runner/interpreter arg.

## Mechanics

- **Require-list**: `config :jido_claw, :tool_approval, require:` — default
  `network_share, kill_agent, schedule_task, unschedule_task, git_commit, forget,
  replay_workflow`, single-sourced in `ToolApproval.default_require/0`.
- **Param patterns and VFS writes**: in-module `@require_patterns` covers
  `run_command` commands matching `git commit`/`git push`/`crontab`.
  `write_file`/`edit_file` use `JidoClaw.VFS.AdapterPolicy`, the VFS-owned adapter
  registry shared with workspace config parsing and URI routing: registered remote
  schemes, remote live modules, and configured remote adapters consume the same
  durable approval. Only explicitly registered local modules bypass it; unknown
  live modules or config adapter keys fail closed to approval. Absolute paths are
  first canonicalized with the execution path's exact rules — `Path.expand("/")`
  plus duplicate-slash collapse, mirroring `Jido.Shell.VFS.normalize_path/1` —
  before **both** the live mount-table resolution and the config classification,
  so traversal (`/project/../publish/…`) and dup-slash forms classify under the
  mount the write actually lands on, and only then resolved against the live
  workspace mount table. Relative paths classify non-remote by design: execution
  cannot route them to a remote mount (the Resolver project jail rejects escaping
  relatives before any mount), and `edit_file`'s write leg independently fails
  closed on traversal (`Jido.VFS.RelativePath` → `{:error, :traversal}`). The
  config fallback re-reads `.jido/config.yaml` on
  every decision through a one-second, process-tree-killed `head` capture capped at
  256,000 bytes and requiring a stable regular-file lstat. Only the parsed
  `vfs.mounts` list is cached, under `{project_dir, sha256(content)}` in a bounded
  64-entry ETS cache. Workspace bootstrap and the cache share
  `JidoClaw.Config.vfs_mounts/1`, so a scalar/malformed `vfs` container is contained
  as a typed error (fail-soft at bootstrap, fail-closed at the gate) and the cached
  error cannot repeatedly reach `get_in` traversal. Thus same-mtime edits take
  effect on the next gate without reparsing unchanged YAML; read/parse/cache
  uncertainty fails closed to approval. Ordinary local project edits remain ungated.
- **Shell-floor scopes**: the `:opaque` floor covers command-runners wrapping a gated
  root/shell (`xargs`/`parallel`/`ssh`/`su -c`/`flock`/`find -exec`, `scope: :runner`)
  and interpreter one-liners / stdin programs (`python -c`, `node -e/-p`, `perl -e`,
  `echo … | python`, `python -`, `scope: :interpreter`).
- **Decision surfaces**: operators decide via the same surfaces as workflow gates
  (REPL `/gates`, web `/approvals`) through `Cases.decide/4`'s run-less branch.
  Item 7 PR-4's `:needs_input` cases share the run-less commit path but are
  kind-dispatched FIRST (a needs-input case can be run-less too, and the shape
  branch would eat it): approve requires a non-blank `decision_comment` — the
  comment IS the answer, refused blank with `{:error, :answer_required}` — and
  `Cases.abandon/3` refuses the kind outright (`{:error, :not_abandonable}`),
  checked before the workflow-case guard. Its `AgentCase.consume` claim reuses the
  tool-call single-use action (the producer is
  `JidoClaw.Orchestration.NeedsInput`; mechanics →
  [executor-seam.md](executor-seam.md)).
- **Context guarantee**: the `tool_context` nesting the gate relies on is guaranteed by
  `JidoClaw.ToolContext.ensure_nested/1` in the wrapper — the live ReAct path arrives
  flat.
- **Authoritative system verification**: the shipped `system_verifier` template adds
  `run_command` to its per-template `require_approval` overlay. Its reverse-verify
  verdict can drive a system route, so every exact host command is surfaced to an
  operator and consumes a durable single-use approval before execution. The ordinary
  code-route test runner remains able to run test commands without this blanket gate;
  those LLM results diagnose failures while deterministic engine verification owns the
  code-route verdict.

## Config & telemetry

`enabled?: true` by default; `enabled?: false` in test (tests drive `gate/4` with
explicit opts). `:tool_approval_mount_cache_max_entries` defaults to 64 and clamps
at 1,024. Cache lookups emit
`[:jido_claw, :security, :tool_approval_mount_cache]` with count 1 and result
`:hit | :miss`; no path, digest, YAML, or credentials ride telemetry.

## Residuals & accepted risks

Documented escape valves — conscious `run_command` residuals, NOT gated:

- the `npx`/`nix run` family (running an arbitrary package is statically unknowable);
- interpreter *script-file* invocations (`python foo.py`, `… | python foo.py`);
- the pre-existing login-file-alias / script-file-indirection cases (`bash deploy.sh`).

The `:docker` shell-floor skip (`tool_approval.ex`) suppresses all of it inside a
provisioned microVM.

## Source map

- `lib/jido_claw/security/tool_approval.ex` — `gate/4`, `default_require/0`,
  `@require_patterns`, bounded fresh mount-config reads, the `:docker` skip
- `lib/jido_claw/security/tool_approval/mount_config_cache.ex` — bounded
  content-digest mount parsing cache
- `lib/jido_claw/vfs/adapter_policy.ex` — adapter key/module/scheme locality;
  unknown or non-local classifications fail closed to remote
- `lib/jido_claw/core/config.ex` — shared typed `vfs_mounts/1` accessor
- `lib/jido_claw/orchestration/tool_approvals.ex` — the producer: fingerprinting,
  FOR-UPDATE fence, consume semantics
- `lib/jido_claw/orchestration/case_producer.ex` — the shared producer primitives
  (`lock_by_fingerprint/3`, `resolve_session_id/3`) this producer and
  `NeedsInput` both transact through
- `lib/jido_claw/security/shell_command.ex` — `analyze/1`, the `:opaque` floor,
  runner/interpreter scopes
- `lib/jido_claw/orchestration/cases.ex` — `decide/4` run-less branch + the
  `:needs_input` kind dispatch (answer guard, abandon refusal)
- `lib/jido_claw/tool_context.ex` — `ensure_nested/1`
