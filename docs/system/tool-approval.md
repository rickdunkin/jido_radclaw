---
type: subsystem
description: Per-tool-call human-approval checkpoint on the conversation axis — durable run-less AgentCases, single-use approvals, the fail-closed shell floor.
sources:
  - lib/jido_claw/security/tool_approval.ex
  - lib/jido_claw/orchestration/tool_approvals.ex
  - lib/jido_claw/security/shell_command.ex
  - lib/jido_claw/orchestration/cases.ex
verified: 2026-07-07
verified_sha: "a1fa5215"
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
- **Param patterns**: in-module `@require_patterns`, e.g. `run_command` commands
  matching `git commit`/`git push`/`crontab`.
- **Shell-floor scopes**: the `:opaque` floor covers command-runners wrapping a gated
  root/shell (`xargs`/`parallel`/`ssh`/`su -c`/`flock`/`find -exec`, `scope: :runner`)
  and interpreter one-liners / stdin programs (`python -c`, `node -e/-p`, `perl -e`,
  `echo … | python`, `python -`, `scope: :interpreter`).
- **Decision surfaces**: operators decide via the same surfaces as workflow gates
  (REPL `/gates`, web `/approvals`) through `Cases.decide/4`'s run-less branch.
- **Context guarantee**: the `tool_context` nesting the gate relies on is guaranteed by
  `JidoClaw.ToolContext.ensure_nested/1` in the wrapper — the live ReAct path arrives
  flat.

## Config & telemetry

`enabled?: true` by default; `enabled?: false` in test (tests drive `gate/4` with
explicit opts).

## Residuals & accepted risks

Documented escape valves — conscious `run_command` residuals, NOT gated:

- the `npx`/`nix run` family (running an arbitrary package is statically unknowable);
- interpreter *script-file* invocations (`python foo.py`, `… | python foo.py`);
- the pre-existing login-file-alias / script-file-indirection cases (`bash deploy.sh`).

The `:docker` shell-floor skip (`tool_approval.ex`) suppresses all of it inside a
provisioned microVM.

## Source map

- `lib/jido_claw/security/tool_approval.ex` — `gate/4`, `default_require/0`,
  `@require_patterns`, the `:docker` skip
- `lib/jido_claw/orchestration/tool_approvals.ex` — the producer: fingerprinting,
  FOR-UPDATE fence, consume semantics
- `lib/jido_claw/security/shell_command.ex` — `analyze/1`, the `:opaque` floor,
  runner/interpreter scopes
- `lib/jido_claw/orchestration/cases.ex` — `decide/4` run-less branch
- `lib/jido_claw/tool_context.ex` — `ensure_nested/1`
