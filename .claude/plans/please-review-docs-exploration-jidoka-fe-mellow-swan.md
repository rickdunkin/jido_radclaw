# Per-Template Approval Policy (native tools)

## Context

The two headline V2 borrows in `docs/exploration/jidoka/FEATURES-WORTH-BORROWING-V2.md` — **V2-1** (per-tool-call approval gate) and **V2-2** (external MCP consumption) — are both shipped and working, but both sit at **PARTIAL** with a *shared* deferred item:

> per-template `require_approval` lists — **blocked on threading `:agent_template` into spawned-child `ToolContext`s** (`child/2` clears it today, so template policy would silently not apply to spawned agents).

Today the approval gate's require-list is **global**: every agent — the main agent, a handoff-routed worker, a spawned swarm sub-agent, a skill-step worker — gates the same flat set of tools. There is no way to say "the `coder` worker must get approval before `write_file`, but the main agent need not," because:

1. The gate (`ToolApproval.native_requirement/3`) never looks at *which* template is calling — it only consults the global `require` list.
2. The tool_context build for spawned/step workers drops `:agent_template` (`child/2` nulls it; `agent_runner`'s `resolve_scope/2` never sets it), so those agents carry no template identity even if the gate looked.

This is the only remaining *load-bearing* deferred item on V2-1 (input/output controls are explicitly "not load-bearing for this threat model"), and closing it is the **shared enabler** that also unblocks V2-2's per-template MCP allowlist later. It is threat-model-aligned (LLM-misbehavior containment: a worker class can be held to a stricter policy than the main agent) and mirrors the existing `forward_context` per-template visibility policy.

**Intended outcome:** each agent template may declare additional tools that require human approval; the policy applies consistently across **every** surface a templated agent can call tools from — handoff, swarm spawn, swarm follow-up, and skill steps. Default is `[]` (zero behavior change). Scope is **native tools only**.

> **Note on scope:** the user selected the "smallest coherent unit." Two plan-review rounds folded in items that are part of *correctness*, not scope creep: the skill-step spawn surface (`agent_runner`) is a real bypass; approvals must be template-scoped or one template can reuse another's approval; and operator visibility must reach both the CLI and the web inbox. Each is flagged below.

## What we're building

A per-template `:require_approval` field on agent templates, **strictly additive** over the global require-list (a template can only gate *more*, never weaken the global gate), threaded so the gate honors it for every templated-agent surface, with approvals scoped to the calling template and surfaced in both operator inboxes.

### Key design decisions

- **Additive, never subtractive.** The template policy only adds tools to the gated set. The global `require` list + shell param-patterns remain the safety floor for *all* agents.
- **Malformed config falls back to the global floor (`[]`), with a warning — not `:all`.** (Honest framing: this is *not* "fail closed" for the per-template layer — that layer fails *open*, adding nothing — but the global require-list still gates every genuinely dangerous tool, so the system stays safe.) We diverge from `forward_context` (which fails to `:none`) deliberately: there the failure mode is information disclosure, so "reveal nothing" is the floor; here the dangerous capabilities are already covered by the global list. Failing to `:all` would gate *every* tool for that worker (`read_file`…) — a self-inflicted DoS with no marginal security. `:all` stays a *valid explicit* operator value; only the malformed/typo fallback is `[]`.
- **Approvals are template-scoped (DECISION — recommended; named precisely per review).** The fingerprint includes `agent_template`, **not** `agent_id` — so two `coder` instances issuing the identical call still collapse to one pending case (intended; we are *not* doing per-agent-instance approvals). We bump the fingerprint term `:v1` → `:v2` and add `agent_template`, and add it to operator-facing case details. **This applies to every approval reason — global require-list and param-pattern approvals as well as the new per-template overlay** — because the fingerprint is computed in `tool_approvals.ex` regardless of *why* the gate fired. So a globally-gated `git_commit` approved for `"main"` is not reusable by `"coder"`; each template is approved independently. That is the right security behavior (consent is per-template), just stated explicitly. *Consequence:* the same operation by two different *templates* requires two approvals — slightly more friction, materially more correct. (Minimal alternative if preferred: add `agent_template` to `details` only, leave the fingerprint `:v1`; cross-template reuse stays possible. The plan assumes the recommended version.)
  - **Deployment note (per review):** bumping the term orphans **all** unconsumed `:tool_call` `AgentCase`s at deploy time — not just `pending` ones. Classification only finds rows matching the freshly-computed `:v2` fingerprint (tool_approvals.ex:150), so an old `:v1` *approved-but-unconsumed* case won't be consumed by a `:v2` retry (it re-pends + re-prompts) and an old `:v1` *rejected* case won't enforce deny-once (it re-pends). Harmless for this greenfield/dev deployment; if it ever matters, the cleanup path is to delete every non-terminal/unconsumed `:tool_call` case (pending + approved-unconsumed + rejected-unconsumed) on deploy.
- **Reason precision preserved (per review).** Check order in `native_requirement` is **global require-list → param-pattern → template policy**, so `run_command "git commit"` under a template that broadly gates `run_command` still surfaces the more useful `{:pattern, :command}` reason.
- **Identity-safety (verified).** `Compactor.Identity.resolve/3` (identity.ex:44-50) keys on the literal `"main"` template and `agent_id == session_id` — never on a worker template name. A spawned/step sub-agent's `agent_id` is its tag (≠ `session_id`, ≠ `"main"`), so `resolve("coder", tag, session_id)` returns the tag, **identical** to today's `resolve(nil, …)`. Setting `:agent_template` on spawned/step children does not perturb compaction keying, `register_child_correlation` (lib/jido_claw.ex:309-314), or `compactor.ex:266`. A grep confirmed every *other* `:agent_template` reader works off a different surface (session metadata, tracker metadata, owner module) — **no regression surface**.

## Implementation

### Part A — template field + gate read (covers the handoff surface immediately)

**`lib/jido_claw/agent/templates.ex`** — mirror the `forward_context` plumbing:
- Add `ensure_require_approval/1` to the `hydrate_template/1` pipe (templates.ex:98-102), after `ensure_forward_context`.
- `validate_ra/2`: accept `:all`; accept a list iff every element is a **non-empty binary** → keep; else warn + fall back to `[]` (mirrors `warn_fc/2` at templates.ex:131-138). This catches non-list / non-binary / empty / atom footguns at hydration. *(We keep the stricter "entry ∈ this template's own tools" check at test time — see config-sanity sweep — rather than at hydration, to keep `hydrate_template` decoupled from tool-module resolution and the hot gate path cheap. Since templates are static today, the test fully covers typos; if templates ever become operator-editable, promote that check into `validate_ra/2`.)*
- Default to `[]` when the key is absent.
- Public `require_approval/1` resolving **through `get/1`** (so the `:agent_templates_override` test hook works), returning `[]` for `{:error, _}` (e.g. `"main"`, not in `@templates`).
- Moduledoc: note the deliberate `[]`-not-`:none` asymmetry and that it is "fall back to the global floor," not per-layer fail-closed.
- Shipped templates keep `require_approval: []` (omit the key) — zero behavior change.

**`lib/jido_claw/security/tool_approval.ex`** — thread context, consult the template:
- `requirement/3 → requirement/4`, `native_requirement/3 → native_requirement/4`, adding `context` (only caller is `gate/4`; MCP/pattern paths ignore it).
- Order `:listed` → `pattern_match` → template. Keep flat (≤3 nesting per `.credo.exs`); never return `false` from a branch (the gate treats any non-`nil` as a reason):
  ```elixir
  defp template_name(%{tool_context: %{agent_template: n}}) when is_binary(n), do: n
  defp template_name(_), do: nil

  defp gated_by_template?(_tool, :all), do: true
  defp gated_by_template?(tool, list) when is_list(list), do: tool in list

  defp template_requirement(tool, context) do
    name = template_name(context)
    cond do
      is_nil(name) -> nil
      gated_by_template?(tool, Templates.require_approval(name)) -> {:template, name}
      true -> nil
    end
  end
  ```
  `template_name/1` is nil-safe on the no-tenant / passthrough `ensure_nested` path (absent `:tool_context`) — `nil` ⇒ global floor only, the correct fail-state.
- Add one `reason_suffix({:template, name})` clause (tool_approval.ex:263-269). `route/3`/`decide/5` are reason-agnostic.
- Add `alias JidoClaw.Agent.Templates` (the module only aliases `ToolApprovals` today at tool_approval.ex:59) — or fully-qualify the `Templates.require_approval/1` calls.
- Update the moduledoc "What is gated" section.

**`lib/jido_claw/orchestration/tool_approvals.ex`** — template-scope + normalize:
- Add a normalization helper (per review): `defp agent_template(scope)` → the value when `is_binary`, else `nil` (guards against an atom/non-JSON value from a future/test caller).
- `fingerprint/3` (tool_approvals.ex:96-103): term → `{:v2, tenant_id, session_key, agent_template(scope), tool, canonical_params(params)}`. The partial unique index `agent_cases_pending_fingerprint_index` indexes the stored hash — no migration (greenfield).
- `details/3` (tool_approvals.ex:243-253): `put_present("agent_template", agent_template(scope))` (nil → omitted).

### Part B — set `:agent_template` on every spawned/step child (three sites)

Honors the contract at tool_context.ex:142-144 ("callers that need a specific template attribution should set it explicitly after the call"). `child/2` stays as-is. The handoff surface needs no change (per-turn build at lib/jido_claw.ex:242 / repl.ex:412 already sets it from `routed_template`).

- **`lib/jido_claw/tools/spawn_agent.ex`** (spawn_agent.ex:94-99): `Map.put(:agent_template, template_name)` on `base_tool_context` after `child/3`, **before** the `swarm_depth` put and **before** `register_child_correlation` (line 100). `template_name` is in scope.
- **`lib/jido_claw/tools/send_to_agent.ex`** (send_to_agent.ex:45-50): same, using `entry.template` (a binary, per `template_for_agent/2` at send_to_agent.ex:145), **before** `register_child_correlation` (line 50).
- **`lib/jido_claw/skills/steps/agent_runner.ex`** (agent_runner.ex:48-56): builds via `ToolContext.build(scoped)` (line 54) where `resolve_scope/2` omits the template. Set it before `register_child_correlation` (line 56) — `Map.put(build(scoped), :agent_template, template_name)` in the `with` binding (`template_name` is the function arg). Leave `resolve_scope/2`'s public signature unchanged.

### Part C — operator visibility parity (web inbox; CLI already shows `details`)

- **`lib/jido_claw/web/live/approvals_live.ex`**: after the `tool:` block (approvals_live.ex:61-66), add a render conditional on `details_value(gate, "agent_template")` (the existing `details_value/2` helper at line 226 reads `gate.details[key]`), e.g. `template: <code>{details_value(gate, "agent_template")}</code>`. Also render `details_value(gate, "arguments")` so web operators see the call args the CLI already exposes — safe to include because `ToolTranscript.summarize_args/2` already caps it to three keys and short values.

## Files to change

| File | Change |
| --- | --- |
| `lib/jido_claw/agent/templates.ex` | `:require_approval` field, `ensure_require_approval/1`, `validate_ra/2` (shape-check → `[]` floor), public `require_approval/1`, moduledoc |
| `lib/jido_claw/security/tool_approval.ex` | thread `context`; template check (list→pattern→template); `{:template, name}` reason + suffix; moduledoc |
| `lib/jido_claw/orchestration/tool_approvals.ex` | normalize helper; `fingerprint/3` → `:v2` + `agent_template`; `details/3` + `agent_template` |
| `lib/jido_claw/tools/spawn_agent.ex` | set `:agent_template` (Part B) |
| `lib/jido_claw/tools/send_to_agent.ex` | set `:agent_template` (Part B) |
| `lib/jido_claw/skills/steps/agent_runner.ex` | set `:agent_template` (Part B) |
| `lib/jido_claw/web/live/approvals_live.ex` | render `details["agent_template"]` (Part C) |

## Test plan

**Extend existing:**
- `test/jido_claw/templates_test.exs` — new `describe "require_approval hydration"`: default `[]`; valid `["read_file"]` and `:all` survive; malformed (non-list / non-binary element / empty string) → `[]` + warns. Add a `with_ra_override/2` helper paralleling `with_fc_override`. (Use **real** tool names, per review.)
- `test/jido_claw/security/tool_approval_test.exs`:
  - `describe "requirement logic"`: override a **real** worker (`coder`, which carries `read_file`) with `require_approval: ["read_file"]` + `agent_template: "coder"` in `ctx/1` scope ⇒ `:approval_pending`; `:all` gates everything; `agent_template: "main"` and absent `tool_context` ⇒ ungated; a call hitting **both** a param-pattern and a broad template policy returns the `{:pattern, …}` reason (order check).
  - **Live wrapper-shape test (per review):** `Victim.run(%{arg: "x"}, flat)` with a **flat** context carrying `tenant_id` + `agent_template` at top level (no `:tool_context`) — proves the ReAct flat-merge path is lifted by `ensure_nested/1` and gated (mirrors tool_approval_test.exs:214-215).
  - `describe "config-sanity coverage"` (reuses the block-local helpers): sweep asserting every shipped template's `require_approval` is `:all` or a list whose entries are each in **that template's own** `module.strategy_opts()[:tools]` names (the accessor `templates.ex:141` already uses) — not the broad MCP-inclusive `wrapped_tool_names/0`. Trivial today (all `[]`); a live typo guard once entries are added.
- `test/jido_claw/orchestration/tool_approvals_test.exs` — update fingerprint determinism/canonicalization tests for the `:v2` shape; add: distinct `agent_template`s ⇒ distinct fingerprints ⇒ distinct pending cases (no cross-template reuse); same template ⇒ same fingerprint (collapses); a non-binary `agent_template` normalizes to the same hash as `nil`; `details` includes `agent_template`.
- `test/jido_claw/tool_context_test.exs` — keep the `child/2`-still-nulls assertion; add that an explicit post-`child` `Map.put(:agent_template, "coder")` survives.
- `test/jido_claw/reasoning/compactor/identity_test.exs` — regression pin: `assert Identity.resolve("coder", "child_tag_42", "sess-123") == "child_tag_42"`.

**New (Part B integration) — assert the child/step context carries the template:**
- `test/jido_claw/tools/spawn_agent_test.exs` — mirror "applies the template's forward_context policy" (the `FakeWorker` stub captures `opts[:tool_context]` via `ask_sync`): assert `tool_context.agent_template == "<template>"`.
- `test/jido_claw/tools/send_to_agent_test.exs` — analogous for the follow-up child.
- `test/jido_claw/skills/steps/agent_runner_test.exs` — assert the step worker's tool_context carries `template_name` (extend if the file exists; else a focused test via the `:step_agent_server` stub).

**Part C:** if an `approvals_live` LiveView test exists, assert a `:tool_call` case with `details["agent_template"]` renders the template; otherwise a light render assertion is optional.

## Verification

1. **`mix precommit` must pass with zero findings** — the definition of done. The alias (mix.exs:252-261) runs, in order: `jidoclaw.compile_check` → `jidoclaw.system_prompt.check` → `deps.unlock --unused` → `format --check-formatted` → `reach.check --arch --smells --strict` → `credo --strict` → `dialyzer --format short` → `test`. Notes:
   - **dialyzer** must stay clean — give `require_approval/1` a precise spec (`[String.t()] | :all`), and ensure the new gate returns/normalizer typecheck.
   - **system_prompt.check** and **deps.unlock --unused** should be unaffected (no tool-set or dependency changes), but both must pass.
   - Don't pipe precommit through `tail`; for string-building in new code use `IO.iodata_to_binary`/`<>` consistently (credo/reach ping-pong). Keep new gate helpers flat (≤3 nesting); introduce no fixed-shape maps in `templates.ex` (no `reach:disable` there).
2. **Targeted suites** while iterating: `mix test test/jido_claw/security/tool_approval_test.exs test/jido_claw/orchestration/tool_approvals_test.exs test/jido_claw/templates_test.exs test/jido_claw/tool_context_test.exs test/jido_claw/tools/spawn_agent_test.exs test/jido_claw/tools/send_to_agent_test.exs test/jido_claw/skills/steps/agent_runner_test.exs test/jido_claw/reasoning/compactor/identity_test.exs`.
3. **End-to-end sanity via Tidewave `project_eval`** once green: register a stub via `:agent_templates_override` with `require_approval: ["read_file"]`; `ToolApproval.gate("read_file", %{...}, %{tool_context: %{tenant_id: "default", session_id: "s", agent_template: "<stub>"}}, enabled?: true, require: [])` ⇒ `{:error, %{code: :approval_pending}}`; repeat with `agent_template: "main"` ⇒ `:ok`. Confirm two distinct templates produce two distinct pending cases for the identical call, and the case `details` carries `agent_template`.
4. After landing, V2-1's "per-template require_approval" deferral and the native half of V2-2's "per-template allowlist enforcement" can be updated in `FEATURES-WORTH-BORROWING-V2.md` (follow-up doc edit, not part of this code change unless requested).
