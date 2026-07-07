---
type: subsystem
description: Live per-agent context compaction plus the per-stage model/effort tiering seam in the single composed request transformer.
sources:
  - lib/jido_claw/reasoning/compactor.ex
  - lib/jido_claw/reasoning/compactor/request_transformer.ex
  - lib/jido_claw/reasoning/compactor/identity.ex
  - lib/jido_claw/conversations/subagent_transcript.ex
  - lib/jido_claw/route_composer/premises_context.ex
verified: 2026-07-07
verified_sha: "a1fa5215"
---

# Context Compaction

## What & why

Long sessions are compacted live via `JidoClaw.Reasoning.Compactor` so agents keep
working past context limits without losing durable history. The same request
transformer that applies the compaction trim also carries the per-stage model/effort
tiering seam (AR-9) — one composed transformer, no collisions.

## Invariants & contracts

- The `JidoClaw.Agent.Defaults` macro accepts `compaction: [...]` opts and injects an
  `on_before_cmd/2` override on `{:ai_react_start, _}` that runs
  `Compactor.maybe_compact/3` before delegating to `super`. The main `JidoClaw.Agent`
  and all 16 worker templates carry `compaction: [mode: :auto]`.
- **Per-agent keying**: each agent compacts its own slice keyed by
  `JidoClaw.Reasoning.Compactor.Identity`, with per-key snapshots persisted under
  `Session.metadata["compactions"][key]` via atomic `jsonb_set`.
- **Best-effort**: storage and summarizer failures are emitted via `:compaction` Trace
  events and logged, but never block the agent's forward progress.
- `JidoClaw.Reasoning.Compactor.RequestTransformer` is the app's **single COMPOSED
  transformer** (AR-9):
  the compaction `:messages` override plus the per-stage tiering overrides live in one
  module, so a tiered stage and compaction never collide.

## Mechanics

- **Identity keys**: `"main"` for both main surfaces, `"handoff:<uuid>:<tpl>"` for a
  routed worker, the spawn tag for a sub-agent. Snapshot
  `key = "<identity>::<context_ref|default>"`. Spawned/handoff sub-agents get coherent
  durable transcripts via `JidoClaw.Conversations.SubagentTranscript`.
- **The trim**: `RequestTransformer` (a `Jido.AI.Reasoning.ReAct.RequestTransformer`
  implementation) filters projected messages by
  `refs.request_id ∈ snapshot.summarized_request_ids` and injects the summary as a
  delimited user-role message.
- **Tiering seam**: the transformer reads `runtime_context[stage_tier_key()]`
  (`:__jido_claw_stage_tier__`) and returns per-turn `model:` /
  `llm_opts: [reasoning_effort: e]` overrides. A tiered composer stage (`%Stage{}`
  `model`/`effort`, carried by `WaveBuilder` into the step options) reaches it via
  `AgentRunner.run/6`, which puts the tier map in `tool_context` and pre-sets
  `request_transformer:` on the ask — same module ⇒ no Compactor collision, and
  `install_overrides` adds to `tool_context` rather than replacing it, preserving the
  tier key.
- **Declarers**: the `plan-arbiter` stage (AR-9 PR-4, the seam's designed first
  declarer) declares `model: :capable, effort: :high`; every other stage stays
  undeclared (session default).
- **Premises context (AR-9 PR-2)**: composer `premises` thread into every worker
  wave's `:extra_context` via `JidoClaw.RouteComposer.PremisesContext`
  (`compose_extra_context/2` in `route_composer.ex`); empty premises ⇒ byte-identical
  prompts, gate waves excluded.

## Config & telemetry

`:compaction` Trace events carry storage/summarizer failures. `AgentStep` emits
`[:jido_claw, :composer, :stage_prompt]` (`bytes` + stage/template) for composer
stages only.

## Residuals & accepted risks

Real `context_ref` lanes remain a no-op follow-up — no producer currently sets
`context_ref`, so keys normally trail `::default`, though the code accepts one if it
appears in tool context.

## Source map

- `lib/jido_claw/reasoning/compactor.ex` — `maybe_compact/3`, snapshot persistence
- `lib/jido_claw/reasoning/compactor/request_transformer.ex` — the composed
  transformer: `:messages` trim + `stage_tier_key()` overrides
- `lib/jido_claw/reasoning/compactor/identity.ex` — per-agent identity keys
- `lib/jido_claw/conversations/subagent_transcript.ex` — durable sub-agent transcripts
- `lib/jido_claw/route_composer/premises_context.ex` — `compose_extra_context/2`
- `lib/jido_claw/skills/steps/agent_runner.ex` — tier map into `tool_context`,
  transformer pre-set
