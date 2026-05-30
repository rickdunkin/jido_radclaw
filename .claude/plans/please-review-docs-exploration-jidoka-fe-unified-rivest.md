# T1-2 Compaction → ADOPTED: per-agent keying + summarizer retries + full worker compaction

## Context

`docs/exploration/jidoka/FEATURES-WORTH-BORROWING.md` tracks Jidoka borrows. **T1-2 Compaction** is the only Tier-1 item still PARTIAL; documented path to ADOPTED: *"ship v2 per-agent keying + summarizer retries."* Deferrals: (1) per-`{agent_id, context_ref}` keying (snapshot is one slot in `Session.metadata["compaction"]`, slice read session-wide; the 7 workers share `session_uuid` so carry `compaction: [mode: :off]`); (2) summarizer retries.

User chose full **Option C** — *enable compaction for every agent, including spawned/workflow/follow-up sub-agents* — on a **greenfield** basis (no migration/back-compat; `[[project_greenfield_no_migrations]]`). All mix via `mise exec --` (OTP 28.5; `[[project_toolchain_mise_otp28]]`).

**Plan v4, after three source-grounded reviews.** Completing every agent's durable transcript makes compaction uniformly coherent, so **no owner gate** is needed.

### Coherence model

Each agent runs in its own process / `Jido.Thread`, so the in-memory projection the `RequestTransformer` filters is already per-agent. We make the durable layer match it: stamp a **compaction identity** on every `Message` row, persist sub-agents' user/result turns (today only tool rows are durable), filter the slice by identity, key the snapshot per identity. Then each agent's durable slice == its own projection by `request_id`.

### Two identities, kept separate

- **Runtime/trace `agent_id`** (`tool_context.agent_id`): `"main"`(REPL)/`session_id`(chat)/`"handoff:<uuid>:<tpl>"`/`"<tpl>_<uuid>"`. Used by Trace/AgentTracker/Jido registry. **Unchanged** — traces don't conflate.
- **Compaction identity** — one shared helper, used at every register site **and** the Compactor (so stored == derived):
  ```
  compaction_agent_id(agent_template, agent_id, session_id) =
    if agent_template == "main" or agent_id == session_id, do: "main", else: agent_id
  ```
  Main ⇒ `"main"` (both surfaces — chat main's `agent_id == session_id`; REPL main's template is `"main"`). Handoff ⇒ `"handoff:<session.id>:<tpl>"` (router.ex:349; `effective_uuid` is `session.id`; reader-reconstructable). Sub-agent ⇒ its `tag` (template `nil`, `tag != session_id`). **This avoids the trap that a naive `template in [nil,"main"]` rule would mis-map spawned children — whose template is `nil` (tool_context.ex:115) — onto `"main"`.**

---

## Findings addressed (three reviews → resolution)

| Finding | Resolution | Phase |
|---|---|---|
| **R1** sub-agents persist no user/result rows | Persist task(`:user`)/result(`:assistant`) for SpawnAgent/SendToAgent/StepAction via **direct `Message.append`** (live view untouched), stamped sub-agent identity + `subagent: true`, Recorder-flush before the result. No gate. | 3 |
| **R2** handoff context not in worker slice (`:system` row written during main's turn, main-scoped, handoff.ex:257-267) | Stamp the handoff `:system` row with the **target worker's** compaction id (`"handoff:<session.id>:<tpl>"`, shared Router helper) + enrich body (reason+summary+message). | 3 |
| **R3** per-key snapshot write race / raw-SQL stale-return | `set_compaction_snapshot` via **Ash `atomic_update(:metadata, fragment("jsonb_set(...)"))`** — atomic, correct return. | 5 |
| **R4** "main" id differs by surface | Compaction identity from the shared helper above (`agent_template`/`agent_id`/`session_id`), **runtime `agent_id` untouched**. | 2,4 |
| **R5** `AgentView`(559)/`Inspection`(702) call `Storage.latest/2` directly | Pass a reconstructed `:key` (AgentView: owner via Handoff.Registry else `"main"`; Inspection: inspected agent's id) + tests. | 5 |
| **R6** `MCP.Scope.wrap` (mcp_scope.ex:102,122) 3rd append path | Stamp `agent_id`+`subagent` from `tool_context`. | 2 |
| **identity-helper trap** child template is `nil` → naive rule compacts sub-agents as `"main"` | Helper keys on `agent_id == session_id` (above), not `template in [nil,"main"]`. | 2,4 |
| **`subagent` must be on `ToolContext`** (MCP stamps from tool_context) | Add `:subagent` to `@canonical_keys`; `child/2,3` forces `true`; workflow scope sets `true`; owner sites (`run_chat_turn`/REPL) set `false`. | 2 |
| **handoff-context proof was wrong** — `protect_first_n_turns` protects (not summarizes) the leading preambled turn; protected ids aren't in `summarized_request_ids` | Mechanism = protection (first compaction) + worker-scoped enriched `:system` row in the summarized source (re-compaction); **proof asserts post-transform LLM messages contain handoff context**, not "summarizer input did." Consider injecting handoff reason/summary into the worker's system prompt (`Router.maybe_inject_prompt`) as the always-kept guarantee. | 3,6 |
| **`subagent` nullability / SQL** | `subagent` **NOT NULL, default false** on both resources; add a named read **`for_session_primary`** filtering `subagent == false` (avoid `!= true` on nullable). | 2,3 |
| **view filter must cover all cold readers** | Switch `Session.Worker.load_messages/3`, `AgentView.cold_messages` (447), `AgentView.total_message_count`, and `JidoClaw.history/3` (jido_claw.ex:435) to `for_session_primary`. | 3 |
| **sub-agent error/timeout** swallowed (spawn_agent.ex:81, send_to_agent.ex:45) | Persist a terminal `:assistant`/`:system` row in **every** branch (`{:ok,_}`/`{:error,_}`/exception/timeout) so there are no dangling `:user` turns. | 3 |
| refinements | `lookup_telemetry/1`→`lookup_request_attrs/1`; `summarizer_max_retries` = additional attempts (default 1 ⇒ 2 total); fix `finalize(nil,…)` to trim a late `Task.shutdown` result to `config.max_summary_chars` (it currently passes `timeout_ms` as the limit) — own it (`[[feedback_no_preexisting]]`). | 1 |

---

## Phases

### Phase 1 — Summarizer retries + finalize fix (independent)
- **`config.ex`**: `summarizer_max_retries` (default **1**, additional attempts) + `summarizer_retry_backoff_ms` (default **250**) across struct/`@type`/docs/`default/0`/`off/0`/`@enforce_keys`; `validate/1` adds `check_non_negative`/`check_positive`.
- **`summarizer.ex`** (70-87): extract `run_attempt/3`; `attempt_summarize/4` retries `:summarizer_timeout|:summarizer_exit|:summarizer_backend`, never `:summarizer_exception`; `Process.sleep(backoff)` between. **Fix `finalize(nil, task, config, timeout_ms)`** (98-104): trim the late `Task.shutdown` result to `config.max_summary_chars` (currently passes `timeout_ms`). Emit `:retry` breadcrumb (`Trace.emit(:compaction,…)`); document worst-case latency; drop "No retries on v1."
- **Tests**: retry-then-succeed, exhaust→error, no-retry-on-exception, backoff, `:retry` telemetry, late-result trims to `max_summary_chars`; config defaults+validation.

### Phase 2 — Durable compaction identity + `subagent` on every row
- **Shared identity helper** (`JidoClaw.Reasoning.Compactor.Identity.resolve/3` or in `ToolContext`) = the rule above. Used at register sites + Compactor.
- **`tool_context.ex`**: add `:subagent` to `@canonical_keys` (so `build/1` preserves it); `child/2,3` forces `Map.put(:subagent, true)`; document. Owner builders pass `subagent: false`; workflow scope passes `true`.
- **`request_correlation.ex`** (+`cache.ex`): add `agent_id` (compaction identity) + `subagent` (**NOT NULL default false**); `:register` accept + cached scope.
- **`lib/jido_claw.ex`**: `register_correlation` — **move after `resolve_session_owner`** (line 185 → after 203); compute identity via helper from `routed_template`/`routed_agent_id`/`session_id`; `subagent: false`. `register_child_correlation/1`: identity = child `agent_id` (tag), `subagent: true`.
- **`cli/repl.ex`**: same correlation-after-routing change (343-366).
- **`message.ex`**: add `agent_id` + `subagent` (**NOT NULL default false**) + `:append` accept; index `[:session_id, :agent_id, :sequence]`.
- **`platform/session/worker.ex`**: `lookup_telemetry/1`→**`lookup_request_attrs/1`** incl. `agent_id`+`subagent`; add optional `agent_id`/`subagent` **override** to `add_message` (for the handoff `:system` row).
- **`conversations/recorder.ex`**: `resolve_scope/1` returns `agent_id`+`subagent`; `record_*` stamp them.
- **`tools/mcp_scope.ex`**: stamp `agent_id`+`subagent` from `tool_context`.
- **Migration**: `mise exec -- mix ash.codegen add_compaction_identity_to_messages`.

### Phase 3 — Sub-agent task/result persistence + handoff scoping + view filter
- **`tools/spawn_agent.ex`(81-97), `tools/send_to_agent.ex`(45-57), `workflows/step_action.ex`(93-109)**: persist task `:user` (direct `Message.append`, identity=tag, `subagent: true`) **before** dispatch; on completion `Recorder.flush(request_id,…)` then persist a terminal `:assistant` row. **All branches** write a terminal row: `{:ok, result}` (result), `{:error, reason}`/exception/timeout (a failure summary) — no dangling `:user` turns. **Ordering**: persist the terminal row **before** `AgentTracker.mark_complete/2` (spawn_agent.ex:88-90) and the `send_to_agent` equivalent, so `get_agent_result`/inspection never see a completed tracker racing missing durable history. **Centralize the stamping** (`session_id`/`agent_id`/`subagent`/actor/opts) in one tiny shared helper used by all four async paths + the terminal/error branches, so they don't drift.
- **Handoff `:system` row** (`tools/handoff.ex:257-267`): write with identity `"handoff:<session.id>:<to_template>"` (shared `Router.worker_agent_id/2`, extracted from router.ex:349) + `subagent: false`; enrich body with `reason`+`summary`+`message`.
- **Handoff-context survival**: ensure it lands in an always-retained spot. Primary mechanism: a **handoff-aware** prompt API — add `Startup.inject_handoff_prompt/4` (or a handoff-aware builder) that adds reason/summary as a worker system message **additively (NOT a replacement) — the base worker system prompt must still be present**; **do NOT overload the generic `Startup.inject_system_prompt/3`** (startup.ex:90), which injects the normal session prompt and is called as-is by `Router.maybe_inject_prompt/6` (router.ex:410). System messages are always kept by the transformer → survives all compactions. The worker-scoped `:system` row also feeds the summarized source for re-compactions. (`protect_first_n_turns` covers only the first compaction.)
- **`message.ex`**: add `for_session_primary` read (`filter subagent == false`, sort `sequence`).
- **View filter — switch every cold reader to `for_session_primary`**: `Session.Worker.load_messages/3` (290-301), `AgentView.cold_messages` (447), `AgentView.total_message_count`, `JidoClaw.history/3` (435).
- **Count semantics decision**: `AgentView.total_message_count` (the chat-visible count) additionally filters `role in [:user, :assistant, :system]` so the number matches what `to_view/1` renders. `load_messages`/`cold_messages` use `subagent == false` and rely on the existing `to_view/1` role-filtering (unchanged). (If a durable-row count is ever wanted, document it as distinct.)
- **Export stays full-fidelity (deliberately NOT switched to `for_session_primary`)**: `mix/tasks/jidoclaw.export.conversations.ex` (128) keeps reading `Message.for_session` so exports include sub-agent rows. For round-trip fidelity, add `agent_id` + `subagent` to the `Message` `:import` action's accept list and to the export format. State this intent explicitly in the export task.
- **Tests**: sub-agent turns persist user+tool+result rows tagged with the sub-agent id, terminal row on error/timeout; handoff `:system` row worker-scoped+enriched; cold readers show main+handoff, hide sub-agents.

### Phase 4 — Agent-scoped slice reads + Compactor uses them
- **`message.ex`**: `for_session_agent` (`session_id, agent_id`) + `since_watermark_for_agent` (`session_id, agent_id, watermark`) reads + `code_interface`.
- **`reasoning/compactor.ex`**: `load_slice_count/3` (557-583) uses `_for_agent` reads with the compaction identity from the shared helper (reads `tool_context[:agent_template]`/`[:agent_id]`/`[:session_id]`). Watermark stays per-session `sequence`.
- **Tests**: reads return only that agent's rows; main slice excludes handoff+sub-agent rows; a spawned sub-agent compacts under its own identity (not `"main"`) — guards the helper trap.

### Phase 5 — Per-agent snapshot keying + atomic write + reader updates
- **`session.ex`**: `set_compaction_snapshot` gains required `:key`; **Ash `atomic_update(:metadata, …)`** with a `jsonb_set` fragment. **Spike the fragment typing FIRST** (a focused test before the rest of Phase 5): the path arg needs an explicit `text[]` (e.g. `array['compactions', ?]::text[]` or a typed param) and the snapshot must be `Jason.encode!`-ed then cast `?::jsonb` — roughly `fragment("jsonb_set(coalesce(?, '{}'::jsonb), array['compactions', ?]::text[], ?::jsonb, true)", metadata, ^key, ^Jason.encode!(snapshot))`. `code_interface` → `args: [:key, :snapshot]`. (Use the **ash-framework** skill for atomic-update exprs.)
- **`reasoning/compactor/storage.ex`**: `persist/4`/`latest/2` require `:key`; `@type opts` updated; `parse_snapshot/1` reads `metadata["compactions"][key]`.
- **`reasoning/compactor.ex`**: `%Ctx{}` gains `:context_ref`+`:compaction_key`; `compaction_key = "#{identity}::#{context_ref || "default"}"`; thread through `storage_opts`/`%Ctx{}`/`manual_install/2`/`compact/3`/public `latest/2` (default `"main::default"`). `RequestTransformer` unchanged.
- **`agent_view.ex`(559)/`inspection.ex`(702)**: pass `:key`, **always derived by running the owner/inspected id through the same `compaction_agent_id` helper** — so a main API/chat session (whose inspected id is the runtime `session_id`) normalizes to `"main"`, not the raw id. No reader builds a key from a raw id. Update tests.
- **Tests**: two keys coexist; **concurrent distinct-key writes both survive** (atomic proof); update the direct-action test to `:key` arity.

### Phase 6 — Enable all 7 workers + coherence proof
- **`agent/workers/*.ex`** (7): `[mode: :off]` → `[mode: :auto]`.
- **`defaults_compaction_test.exs`** (68-83): → `%Config{mode: :auto}`.
- **Coherence proof** (central artifact): one session with main + a `handoff→reviewer` + a spawned sub-agent, all over threshold — assert (a) three independent snapshots, none clobbered; (b) each summarizer saw only its own rows; (c) **post-transform LLM messages for the reviewer contain BOTH the base worker system prompt AND the handoff context** (asserted through `Router.maybe_inject_prompt/6` → router.ex:410, across first AND re-compaction — confirms the handoff prompt is additive, not a replacement); (d) the sub-agent's slice is complete (task+terminal) and excluded from others' slices and from the primary view.

### Phase 7 — Docs + precommit (gate)
- `docs/.../FEATURES-WORTH-BORROWING.md`: **T1-2 → ADOPTED** (keying+retries closed; all 7 workers compact incl. sub-agents; transcripts completed). Update ◐→✓ graph/"First wave"/"Tier 2 sequencing".
- Confirm `jidoclaw.system_prompt.check` passes.
- **`mise exec -- mix precommit` green** (compile-werror, system_prompt.check, deps.unlock --unused, format, credo --strict, dialyzer --format short, test). Watch Credo (cyclomatic ≤ 11, nesting ≤ 3, no `BlanketRescue`); Dialyzer (`@type`/`%Config{}`/`%Ctx{}`/opts; 2-tuple ignores).

---

## Reuse / conventions
- `Config` helpers `check_non_negative/2`/`check_positive/2` exist; summarizer errors are `%ExecutionError{phase:}`; reuse `Trace.emit(:compaction,…)`.
- **Ash `atomic_update` + fragment** for JSONB write (atomic, correct return) — not raw SQL.
- Each helper defined **once**: compaction-identity (`resolve/3`), handoff worker id (`Router.worker_agent_id/2`). Reused by stampers/compactor/readers — no drift.
- Correlation→scope seams exist: `lookup_request_attrs/1` + `resolve_scope/1` — extend.
- **Direct `Message.append`** for sub-agent rows; `subagent` (NOT NULL) drives `for_session_primary`.
- Invoke the **`ash-framework` skill** before resource/action/atomic-update edits; `mix ash.codegen` (`:string`→`:text`).

## Critical files

| File | Phase | Change |
|---|---|---|
| `reasoning/compactor/config.ex` | 1 | retry fields + validation |
| `reasoning/compactor/summarizer.ex` | 1 | retry loop, `:retry` telemetry, finalize trim fix |
| `tool_context.ex` | 2 | `:subagent` canonical key; `child/2,3` forces `true` |
| `request_correlation.ex`(+`cache.ex`) | 2 | `agent_id`+`subagent` (NOT NULL) |
| `lib/jido_claw.ex` | 2,3,4 | identity helper; `register_correlation` after routing; child `subagent:true`; `history/3` primary filter |
| `cli/repl.ex` | 2 | correlation change |
| `message.ex` | 2,3,4 | `agent_id`+`subagent` attrs/index; `for_session_primary`/`for_session_agent`/`since_watermark_for_agent` reads |
| `platform/session/worker.ex` | 2,3 | `lookup_request_attrs/1`; `add_message` override; `load_messages` primary filter |
| `conversations/recorder.ex` | 2 | `resolve_scope`+`record_*` stamp identity/`subagent` |
| `tools/mcp_scope.ex` | 2 | stamp identity/`subagent` |
| `tools/spawn_agent.ex`,`tools/send_to_agent.ex`,`workflows/step_action.ex` | 3 | task/result rows incl. error/timeout terminal (+flush) |
| `tools/handoff.ex` | 3 | worker-scoped+enriched `:system` row |
| `agent/handoff/router.ex` | 3 | extract `worker_agent_id/2`; (handoff-context prompt injection) |
| `agent_view.ex` | 3,5 | `cold_messages`/`total_message_count` primary filter; pass `:key` |
| `inspection.ex` | 5 | pass `:key` |
| `session.ex` | 5 | `set_compaction_snapshot` `:key` + atomic `jsonb_set` |
| `reasoning/compactor/storage.ex` | 5 | per-`:key` |
| `reasoning/compactor.ex` | 4,5 | agent-filtered slice; identity; key threading |
| `agent/workers/*.ex` (7) | 6 | `:off`→`:auto` |
| migrations + snapshots | 2 | generated |
| `docs/.../FEATURES-WORTH-BORROWING.md` | 7 | T1-2 → ADOPTED |

## Verification
1. Per-phase tests: `mise exec -- mix test test/jido_claw/reasoning/compactor/ test/jido_claw/conversations/ test/jido_claw/tools/ test/jido_claw/workflows/ test/jido_claw/agent/defaults_compaction_test.exs`.
2. **Coherence proof** (Phase 6).
3. **Manual smoke** (`mise exec -- mix jidoclaw`): long main session, handoff, spawn — each compacts on its own slice; reviewer retains handoff context post-compaction. `inspect_agent/2`+`Trace`; **Tidewave** `execute_sql_query` to confirm `messages.agent_id`/`subagent` across all paths and `metadata->'compactions'` per-agent keys.
4. **`mise exec -- mix precommit` passes.**

**Highest residual implementation risk (test first, in isolation):** (a) the `jsonb_set` atomic-update fragment typing (Phase 5 spike); (b) the handoff-aware prompt injection actually placing context where the transformer always keeps it (Phase 3, proven by the Phase 6 post-transform assertion); (c) async sub-agent terminal-row ordering vs `mark_complete` (Phase 3). No architectural risk remains — these are the spots to cover with focused tests before wiring the rest.

## Out of scope / follow-ups
- Pruning orphaned sub-agent snapshots from `metadata["compactions"]` (bounded slow growth).
- Real `context_ref` lanes (key shape ready; still `"default"`).
- Per-worker threshold tuning; relocate `register_correlation/*` into `RequestCorrelation`.

## Commit plan (slicing guidance — NOT authorization to commit)
Seams, each precommit-green: **(1)** retries+finalize; **(2)** identity+`subagent` plumbing (3 write paths + ToolContext)+migration; **(3)** sub-agent persistence + handoff scoping + view filter; **(4)** agent-scoped reads + identity in compactor; **(5)** keying + atomic write + readers; **(6)** enable workers + coherence proof; **(7)** docs. Do not `git commit` without an explicit request (`[[feedback_never_commit_unprompted]]`).
