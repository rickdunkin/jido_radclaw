# Plan: unadopted-next-five — items 1 & 2

## Context

`docs/plans/unadopted-next-five/README.md` (selected 2026-07-02) queues five items from the three UNADOPTED-IDEAS rollups. Items 1 and 2 are the head of the queue — independent of everything and of each other:

1. **`git push` approval gate + recorded one-liner sweep** — `tool_approval.ex` gates `git commit` but `run_command "git push"` publishes to a remote ungated; bundled with the AR-1 doc/code residuals and the jidoka `blocks_count` footnote.
2. **G2-1b per-stage MCP catalog resources** — `jido://workflows/{name}` template resource, following the existing design doc `docs/plans/mcp-workflow-resources/README.md` verbatim, gated on its Phase 0 spike.

Constraints from the request: plan is complete only when `mix precommit` passes; greenfield (no data/path compat concerns); **no commits — everything stays unstaged** (overrides the queue's "3 small commits" framing); no deferrals — item 2's spike red-path is an explicit stop-and-discuss checkpoint, not a deferral.

### Exploration corrections to the queue's own claims (load-bearing)

- **`git push` is benign today, not opaque.** The queue (item 1 step 1) says an unresolved git subcommand "already falls to `{:opaque, scope: :git}`". Actually only `commit` and `config` are special-cased; an unknown non-alias subcommand returns a default `%Invocation{}` — no effect, no gate (`git.ex:203-221`, comment at `:212-213`). So the push gate needs real detection (a `pushes?` invocation fact mirroring `commits?`), not just a require-pattern line.
- **`Cases.retract/3` citations: 4 files, not 3.** The false claim (`gates/plan_gate.ex:11`) + three race-fence-anchor citations (`orchestration/gate_disposition.ex:8`, `orchestration/workflow_event/projection.ex:118`, `orchestration/agent_case.ex:207`), plus a passing mention in `orchestration/workflow_log.ex:164`.
- **`blocks_count` counts label-deduped rows** (`memory.ex:193-198` group_by label → min_by scope rank), so a naive `Ash.count` swap would over-count. The existing test (`namespace_info_test.exs:43`, `blocks_count: 2`) uses two *distinct* labels in one scope — it does **not** discriminate deduped-vs-raw; a discriminating test must be added first.
- **No live MCP handshake harness exists.** The design doc's "live handshake test" has no existing harness; the repo precedent is driving anubis handler functions directly against the real server module (`test/jido_claw/core/anubis_tools_handler_patch_test.exs`).

## Decisions taken while you were away (veto any at approval)

Asked via question tool, no response after 60s — took the recommended option on each:

1. **Scope = items 1 + 2** (not item-1-only; not pulling in item 3's PR-1).
2. **`Cases.retract/3`: full deletion** — fn + `commit_retract/5` + tests + the now-producerless `:approval_retracted` durable event kind + projection arms. Greenfield, zero production callers (verified: definition + test callers only).
3. **Spike red ⇒ pause and discuss** — report exactly which of the 4 gate points failed; we choose Phase 2 dep-patch vs clean kill together. (Green ⇒ continue Phases 1+3 without stopping.)
4. **Spike test fidelity = in-process drive** — call jido_mcp's generated `init/2` on a real `%Frame{}`, then drive `Anubis.Server.Handlers.Resources.handle_templates_list/3` + `handle_read/3` against the real `JidoClaw.MCPServer`. No new stdio subprocess harness.

---

## Item 1a — `git push` gate

Mirror the `commit` detection exactly; push is pattern-only (there is no native `git_push` tool to require-list).

**`lib/jido_claw/security/shell_command/git.ex`**
- `Invocation` struct (`:57-75`): add `pushes?: false` field + `t()` typespec entry; moduledoc bullet mirroring the `commits?` bullet (`:11-14`).
- `classify_candidate/6`: add `{"push", _dyns}` clause setting `pushes?: true`, beside the `{"commit", _dyns}` clause (`git.ex:206-207`). Alias chains (`git -c alias.p=push p`) work for free via `resolve_nested` re-entering `classify_candidate`; `!`-shell aliases stay opaque; dynamic subcommands stay opaque.

**`lib/jido_claw/security/shell_command.ex`**
- `push_effect/1` mirroring `commit_effect/1` (`:626-627`), wired into `invocation_effects/1` (`:620`): `commit_effect(inv.commits?) ++ push_effect(inv.pushes?) ++ ...`. Evidence: `effect(:git_push, %{reason: :resolved})`.
- Add `:git_push` to `@effect_kinds` (`:157-166`), the `@type effect_kind` union (`:140-148`), and the moduledoc "Effects, not booleans" enumeration (`:22-52`). (`ToolApproval.valid_matcher?/1` validates against `effect_kinds/0`, so this must land with the matcher.)
- Wider prose sweep in the same file: the top-level moduledoc (`:4`) names the gated shell equivalents as `git commit`/`crontab` — add push; `command_present?/3`'s docs (`:436`) describe the "git gating floor" as commit/config-only — reframe them as the **legacy commit/config matcher**, with no behavioral widening: `{:effect, :git_push}` is the push path, and `command_present?(…, subcommand: "commit")` keeps matching commit only.

**`lib/jido_claw/security/tool_approval.ex`**
- Add `{:effect, :git_push}` to `@require_patterns["run_command"]` (`:158-177`).
- Update the leading comment ("The five `{:effect, _}` entries" → six, `:140-157`) and the "What is gated" moduledoc section (`:31-88`).

**Tests (red first — the tool_approval passthrough test at `:281` currently asserts `git push origin "$branch"` is `:ok`; it must flip):**
- `test/jido_claw/security/shell_command_test.exs`: new describe `git effects: resolved push` mirroring `git effects: resolved commit` (`:372-399`), asserting `:git_push` via the existing `assert_effect/refute_effect` helpers for: plain `git push` / `git push origin main`, `git -C "my dir" push`, env-prefixed (`FOO=bar git push`), `sudo git push`, `/usr/bin/git push`, `sh -c "git push"`, `bash -lc "git push"`, multiline (`echo x\ngit push`), backgrounded (`git push &`), inline alias (`git -c alias.p=push p`), redirect form. Negatives: `git log && echo push`, `echo "git push"`, alias-to-benign, shell alias `git -c 'alias.p=!git push' p` stays `:opaque` (not `:git_push`).
- Same file `:592-603` ("a dynamic value in a known value position never gates by itself" uses `git push origin "$branch"`): swap the fixture to a non-gated subcommand (e.g. `git fetch origin "$branch"`) to preserve the test's intent, and assert the push form carries exactly `:git_push` with no opacity in the new describe.
- Check the invariants block (`:555-608`) for anything enumerating effect kinds; extend if so.
- `test/jido_claw/security/tool_approval_test.exs`: add push bypass forms to the pend test (`:157-203`); **move** `git push origin "$branch"` from the benign-passthrough list (`:281`) into pend; add a `git push` line to `@floor_tripping` (`:735-748`) proving the `:docker` skip still holds (`:750-764`).

**Docs (incl. the agent-facing prompt surface — `mix precommit` cannot catch prose drift here, so this is a checklist item):**
- AGENTS.md Tool Approval Gate bullet — extend the `@require_patterns` example ("commands matching `git commit`/`crontab`" → add `git push`).
- `priv/defaults/system_prompt.md` "Operation Approvals" section (~`:75-90`) — the shell-equivalents example ("such as `git commit ...`") gains `git push`.
- `.jido/system_prompt.md.default` gets the same one-line edit. The **live** `.jido/system_prompt.md` has no Operation Approvals section at all (it has diverged from the default), so it gets a targeted **insertion of the approvals section** (push included) — not a line edit, not a wholesale copy; flag the divergence in the final report.

## Item 1b — AR-1 residuals: fix false claim, delete `Cases.retract/3` (full)

**The truth to state:** stale-approval retraction rides the composer's signal axis — `route_composer.ex:2892-2940` (`stale_approval?` → `retract_stale_approval` → `Commit.append_markers` with `signals_retracted`/`stages_invalidated`), never `Cases.retract/3`.

- `lib/jido_claw/gates/plan_gate.ex:9-11` — rewrite the false "rides `Cases.retract/3`" sentence to point at the composer signal-axis path.
- Delete from `lib/jido_claw/orchestration/cases.ex`: `retract/3` (`:209-231`), `commit_retract/5` (`:491-513` incl. the `:482-490` comment), `ensure_not_resumed/3` (`:550` — its only callers are `:222`/`:498`, both inside the deleted pair), the moduledoc §"Stale-approval retraction (AR-1)" (`:54-66`) and refs at `:26`, `:97`, `:199`; fix the `:386` comment citing `commit_retract`'s lock order.
- Delete the `:approval_retracted` durable kind + arms: `lib/jido_claw/orchestration/workflow_event.ex:111` (kind list); `lib/jido_claw/orchestration/workflow_event/projection.ex` — `next_status(:running, :approval_retracted)` (`:134`), `status_attrs(:approval_retracted, ...)` (`:213`), kind in the list at `:70`, docs/comments at `:56`, `:115-118`, `:184`.
- Delete the retract-only Ash resource surface: `AgentCase.reopen` — the `define(:reopen)` code interface (`agent_case.ex:100`) and the `update :reopen` action + its comment (`agent_case.ex:203-208`; only production caller is `commit_retract`, `cases.ex:499`); the `:retracted` kind from `AgentCaseEvent`'s type list (`agent_case_event.ex:108`; only producer is `cases.ex:509`). Check whether the `one_of` constraint change needs codegen (it shouldn't — app-side constraint, not a DB enum); if `mix ash.codegen` produces anything, one squashed named codegen per repo convention.
- Sweep the anchor citations: `gate_disposition.ex:8` (drop `Cases.retract/3` from the lock-order list), `agent_case.ex:207` (rewrite the "event-log half of the race fence" sentence), `workflow_log.ex:164` ("decision/abandon/retract commits" → drop retract).
- Tests: delete the retract tests in `test/jido_claw/orchestration/gate_lifecycle_test.exs` (incl. `:165` asserting `:approval_retracted in kinds`) and the `:not_workflow_case` retract test in `test/jido_claw/orchestration/cases_tool_call_test.exs`.
- After the sweep: `rg -n "retract" lib/` must show only composer signal-axis retraction (and `Fold`'s clean/findings signal retraction); `rg -n "approval_retracted|:retracted|reopen|ensure_not_resumed" lib/ test/` must come back empty (modulo unrelated words).

## Item 1c — `blocks_count` → DB-side distinct-label count

Site: `lib/jido_claw/memory.ex:242` (`length(list_blocks_for_scope_chain(scope))` inside `namespace_info/1`).

- **Semantics to preserve:** count of **distinct labels** over the scope-chain filter (equivalent to the deduped list length — rank/min_by only picks *which* row wins per label, never changes the count).
- **Discriminating test first (red):** extend `test/jido_claw/memory/namespace_info_test.exs` — write the *same* label at two chain scopes (e.g. workspace + session) plus one unique label; assert `blocks_count` equals the deduped count (raw count would be +1).
- **Implementation:** new private `count_blocks_for_scope_chain/1` in `memory.ex` used by `namespace_info/1`: build the query via the code interface (`Block.query_to_for_scope_chain/…` — the `define(:for_scope_chain, …)` at `block.ex:100` should expose it; add the interface form if not), then `Ash.Query.unset(:sort)` **before** `Ash.Query.distinct(:label)` (+ `select([:label])`) into `Ash.count/2` with the same `tenant`/`actor: Actor.system(...)` opts. The unset is load-bearing: the read action's preparation pins `sort(position: :asc, inserted_at: :desc)` (`block.ex:479`), and Postgres `DISTINCT ON` requires the ORDER BY to lead with the distinct field. **Explicit acceptance check:** verify via Tidewave `project_eval` that the generated SQL counts over a distinct subquery (correct count on the overlapping-label fixture), before trusting green. Mirror `list_blocks_for_scope_chain/1`'s fail-soft contract (`rescue @db_errors` / `catch :exit` → `0`).
- **Bounded fallback (same change, only if ash_postgres 2.9 provably won't compose count-over-distinct):** read with `Ash.Query.select([:label])` and count distinct labels in memory — still eliminates the full-row load. The discriminating test is the arbiter either way.
- No consumer changes: `namespace_info/1`'s moduledoc ("count of label-deduped Block-tier rows", `memory.ex:220-232`) stays true; `Inspection.Summary` / `inspect_agent` shapes unchanged.
- Watch (from repo memories): keep code-interface opts to `[:tenant, :actor]`; expect the AshCredo read-action/code-interface gauntlet if hand-building queries.

## Item 2 — G2-1b per-stage MCP resources (spike-gated; follow `docs/plans/mcp-workflow-resources/README.md`)

### Phase 0 — spike (checkpoint)

- New `lib/jido_claw/core/mcp_server/resources/workflow_stage.ex`: minimal anubis component resource — `use Anubis.Server.Component, type: :resource, uri_template: "jido://workflows/{name}", name: "workflow_stage", mime_type: "application/json"` — with a trivial `read/2` returning a constant, per the worked example in `deps/anubis_mcp/lib/anubis/server/component/resource.ex:44-64`. **`name:` and `mime_type:` are explicit:** the concrete failure risk is `mime_type` — it defaults to `"text/plain"` and is copied into protocol output (`component.ex:43`, `response.ex:680`). For `name`, anubis falls back to a module-derived name at list time when `module.name/0` is nil (`server.ex:371`), but an explicit `"workflow_stage"` pins a stable public id rather than a derived one. The spike/Phase 3 tests assert `name` + `uri_template` + `mime_type` on the templates-list surface, and `mimeType`/URI/content on the read response — `name` belongs to the templates-list surface only, not the read response.
- Register in `lib/jido_claw/core/mcp_server.ex` via the `component/2` macro (already imported through `use Jido.MCP.Server` → `use Anubis.Server`, `deps/anubis_mcp/lib/anubis/server.ex:286,328`). The `publish:` map is untouched (templates never go there).
- New test (in-process drive; precedent: `anubis_tools_handler_patch_test.exs`) proving the 4 gate points against the **real** `JidoClaw.MCPServer`:
  1. compiles inside the `use Jido.MCP.Server` module (implicit);
  2. registration proven **both** ways: `MCPServer.__components__(:resource)` carries the component (compile-time registration), **and** the `Anubis.Server.Handlers.Resources.handle_templates_list/3` result contains the template entry — the handler is the acceptance surface. Pick the assertion layer deliberately: the handler returns `%Resource{}` structs, not JSON-cased maps (`resources.ex:31`); `uriTemplate`/`mimeType` casing only appears via the `JSON.Encoder` impl (`component/resource.ex:231`). So assert struct fields (`name`, `uri_template`, `mime_type`) on the direct result, or JSON round-trip the payload and assert protocol keys;
  3. `handle_read/3` on `jido://workflows/triage` routes to `read/2` with parsed `%{"params" => %{"name" => "triage"}}`;
  4. `jido://workflows/catalog` still reads the static catalog (static-before-template ordering), with the frame built through the generated `init/2` so jido_mcp's registration path is exercised.
- **False-green trap (design doc `:87-89`, `:190-192`):** never assert the template via `MCPServer.__publish__().resources` — component templates never appear there (that's the surface `test/jido_claw/mcp_server_test.exs:129-134` uses for the *static* catalog only).
- **Any gate point red → STOP.** Report which point failed and the mechanism; we decide Phase 2 (additive jido_mcp `publish`-DSL patch via the `dependency_patches.ex` precedent) vs clean kill together.

### Green → Phases 1+3

- Real `read/2` (design doc `:147-157`, matches the real contracts — `Catalog.get/1` returns `%Stage{} | nil`, `Stage.to_map/1` returns a bare string-keyed map):
  - `%Stage{}` → `{:reply, Response.json(Response.resource(), %{"stage" => Stage.to_map(stage)}), frame}`
  - `nil` → `{:error, Error.resource(:not_found, %{uri: "jido://workflows/#{name}"}), frame}`
  - Exact `Response`/`Error` construction validated against the spike's live read (the component triple contract differs from the static resource's auto-wrapped `{:ok, map}` — `jido_mcp/server/runtime.ex:207`).
- Tests: known stage (`triage`) payload byte-identical to the catalog's `stages["triage"]` entry (`Catalog.to_map/1` single-sourcing); unknown name → not-found error; JSON-safety (`Jason.encode!`); static catalog test untouched and green; registration asserted only via `__components__(:resource)` / templates-list.
- Docs: AGENTS.md — "Exposed resources" line (`:56`) gains `jido://workflows/<stage>`; also the serving mention at `:89` ("24 tools + the `jido://workflows/catalog` resource").

## Doc reconciliation (whole entries, not just status lines)

Item 1 (after code green):
- `docs/exploration/alp-river/UNADOPTED-IDEAS.md`: git-push footnote (`:185-188`) → shipped, dated; table row #4 (`:23`) "its footnoted `git push` sibling: yes" → done; entry #4 prose (`:94-95`); AR-1 footnote (`:189-194`) → both residuals resolved (moduledoc fixed, `Cases.retract` deleted), correct its "three moduledocs" count in passing.
- `docs/exploration/alp-river/FEATURES-WORTH-BORROWING-V2.md`: AR-10 ungated-push observations (`:172`, `:191-202`, `:223-224`, `:333`) — now-false present-tense claims updated.
- `docs/exploration/alp-river/FEATURES-WORTH-BORROWING.md`: AR-1 Tail-update residuals paragraph (`:396-412`) → resolved+dated; fix the present-tense "stale-approval retraction is `Cases.retract`" at `:392`.
- Historical mentions of `approval_retracted` in squidie docs (`FEATURES-WORTH-BORROWING.md:226`, `T1-1-WORKFLOW-EVENT-LOG-PLAN.md:35`, `REACTOR-ADOPTION.md:84`) and `alp-river/AR-2-COMPOSER-PLAN.md:821`: add a one-line dated "(removed 2026-07-02 — vestigial, no production caller)" note rather than rewriting shipped history.
- `docs/exploration/jidoka/UNADOPTED-IDEAS.md` footnote (`:102-104`) → done; sweep the matching T2-4 mention in `docs/exploration/jidoka/FEATURES-WORTH-BORROWING.md`.

Item 2 (after code green):
- `docs/exploration/gust/UNADOPTED-IDEAS.md` entry #1 (table row `:19`, entry `:27-44`) → shipped.
- `docs/exploration/gust/FEATURES-WORTH-BORROWING.md`: flip G2-1(b) in all four spots (`:59`, `:282-288`, `:400`, `:413-414`) following the G2-1a "**SHIPPED**" convention (`:277-282`).
- `docs/plans/mcp-workflow-resources/README.md`: dated status header (Phase 0 outcome, Phases 1+3 shipped; Phase 2 not needed — or the actual outcome).

Both: mark items 1 & 2 done in `docs/plans/unadopted-next-five/README.md`.

## Verification

1. Red first where specified: the flipped passthrough test (1a), the discriminating dedup test (1c) — confirm each fails before the code change, then goes green. Spike test (2) is itself the evidence gate.
2. Targeted runs (never piped): `mix test test/jido_claw/security/shell_command_test.exs test/jido_claw/security/tool_approval_test.exs`, `mix test test/jido_claw/memory/namespace_info_test.exs`, `mix test test/jido_claw/orchestration/gate_lifecycle_test.exs test/jido_claw/orchestration/cases_tool_call_test.exs`, the new MCP resource tests + `mix test test/jido_claw/mcp_server_test.exs test/jido_claw/core/mcp_server/resources/workflow_catalog_test.exs`.
3. Tidewave `project_eval` to verify the distinct-count SQL and to sanity-drive `WorkflowStage.read/2` live.
4. Full gate: `mix precommit` run directly; report exit code + counts verbatim. Known flaky (repo memory): `MemoryExportTest` capture_log race in full suite — passes in isolation; not a regression. Watch: ExSlop clone check on the mirrored `push_effect`/test describes; reach smells; credo strict; the currently-empty compile_check allowlist stays empty.
5. No commits; everything left unstaged. `git status` reviewed at the end so only intended files are touched.

## Files touched (summary)

Code: `security/shell_command/git.ex`, `security/shell_command.ex`, `security/tool_approval.ex`, `gates/plan_gate.ex`, `orchestration/{cases.ex,workflow_event.ex,workflow_event/projection.ex,gate_disposition.ex,agent_case.ex,agent_case_event.ex,workflow_log.ex}`, `memory.ex` (+ maybe `memory/resources/block.ex` interface), `core/mcp_server.ex`, new `core/mcp_server/resources/workflow_stage.ex`.
Tests: `security/shell_command_test.exs`, `security/tool_approval_test.exs`, `memory/namespace_info_test.exs`, `orchestration/gate_lifecycle_test.exs`, `orchestration/cases_tool_call_test.exs`, new MCP workflow-stage/spike test.
Docs/prompt surface: `AGENTS.md`, `priv/defaults/system_prompt.md`, `.jido/system_prompt.md.default`, live `.jido/system_prompt.md` (targeted edit — diverged from default), alp-river UNADOPTED + V1 + V2 (+ AR-2 plan note), jidoka UNADOPTED + FEATURES, gust UNADOPTED + FEATURES, squidie one-line notes ×3, `docs/plans/mcp-workflow-resources/README.md`, `docs/plans/unadopted-next-five/README.md`.
