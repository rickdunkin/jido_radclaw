# Phase 5 — Read-Models + Graph Visualization (full scope)

## Context

`docs/exploration/squidie/FEATURES-WORTH-BORROWING.md` + `REACTOR-ADOPTION.md` track the Squidie/Rift/SquidSonar borrow program. Phases 0–4 are shipped and test-pinned (event log, status-as-projection, human gates, skills-on-Reactor, fingerprint+replay, boot recovery). The docs' explicit next-phase scope (`REACTOR-ADOPTION.md:77-79`) is **Phase 5**: deadline read-model (T2-1), actor-visibility redaction (T2-2), cron idempotency (T2-3), graph-layout visualization (T3-1/T3-2). §8 done-bar: *"the dashboard shows lateness, payloads are scope-redacted by default, and a double cron tick yields one run"* — plus the graph per the reconciliation note.

**User decisions (locked):** full Phase 5 including graph viz · payload reveal = per-run dashboard toggle (LLM/MCP surfaces permanently redacted) · deadlines at run **and** step level, explicit-declaration only.

**Review findings incorporated (rounds 2–3):** manual cron triggers must not consume the scheduled window's idempotency key (provenance passed as an `execute_job/2` argument, never stored in GenServer state); run-level deadlines thread through ALL three launch sites (cron, RunSkill, Replay — module replays preserve `original.config["deadline"]`); top-level `skill.deadline` validated in `Compiler.compile/1`; static step metadata projects on all three upsert actions; the synthetic collect step gets stamped `depends_on`; deadline semantics copy Squidie exactly (optional non-negative `due_soon`/`escalate_after`, `due_soon < within`, `0` allowed) with always-present non-negative `overdue_by_ms`; `Deadline.from_config/4` unwraps parse; iterative deadlines are loop-level only; `Visibility.run_view/step_view` take an explicit `now`, are shape-additive over the current MCP contract, and redact before truncating; deadlines are deliberately **excluded** from the definition fingerprint; LiveView colspans + refresh-state preservation handled.

Out of scope (deliberately deferred per docs): §4.11 lease *implementation*, live-run cancellation, async step-timeline Writer.

**Definition of done:** all four slices implemented + tested, and `mise exec -- mix precommit` passes (compile_check, system_prompt.check, deps.unlock --unused, format, reach --arch --smells --strict, credo --strict, dialyzer, test). New columns via `mise exec -- mix ash.codegen <name>` — never hand-written migrations. Greenfield: no data-migration/compat concerns.

---

## Slice 1 — T2-3 Cron idempotency (smallest blast radius)

A double-delivered **scheduled** cron tick must resolve to the existing run instead of starting a second reactor. A **manual** trigger must always run.

### Resource: `lib/jido_claw/orchestration/workflow_run.ex`
- New attribute: `idempotency_key :string, allow_nil? true, public? false, default nil` (place near `metadata`).
- New `identities do` block (resource has none today):
  `identity :unique_run_idempotency, [:idempotency_key], nils_distinct?: true` — explicit even though `true` is the Ash default; NULL-key runs must coexist. Attribute multitenancy auto-adds `tenant_id` to the generated unique index (verified against the `WorkflowStep.unique_step_per_run` migration).
- Add `:idempotency_key` to the `:create` action accept list.
- New read + code_interface: `read :by_idempotency_key` (`get? true`, `argument :idempotency_key, :string, allow_nil?: false`, `filter expr(idempotency_key == ^arg(:idempotency_key))`); `define(:by_idempotency_key, args: [:idempotency_key], get?: true)`.
- `mise exec -- mix ash.codegen add_workflow_run_idempotency_key` — verify the generated unique index is tenant-prefixed with `nulls_distinct: true`.

### Runner: `lib/jido_claw/orchestration/reactor_runner.ex`
- New opt `:idempotency_key` on `run/3` (document in moduledoc Options). Move the `Keyword.fetch(:tenant)/(:actor)` reads above the create `with` so the dedupe read can use them.
- **Read-first → create → unique-violation → re-read** (not upsert — the caller must know create-vs-conflict so it can skip execution):
  1. Key present → `WorkflowRun.by_idempotency_key(key, tenant:, actor:)`; on hit return `{:ok, {:existing_run, run.id}, run}` **immediately — no `Reactor.run`, no events appended, and no launch work at all: move the `replay_inputs` `term_to_binary` encoding (currently early, `reactor_runner.ex:182`) below this dedupe read** so the hit path skips it.
  2. Miss → create with `idempotency_key:` in the attrs map, proceed as today.
  3. Race backstop: when create returns `{:error, %Ash.Error.Invalid{}}` matching the `:unique_run_idempotency` identity (field `:idempotency_key`), re-read by key and return the winner as `{:ok, {:existing_run, id}, run}`. The declared identity is what makes Ash return a tuple instead of raising; if testing shows a raise instead, the file-level `reach:disable-for-this-file bare_rescue` pragma already covers a narrow fallback rescue (mirror `Allocate.attempt_step_upsert`'s pattern).
- Existing `@type run_result` (`{:ok, term(), run}`) already admits the new shape; document it.

### Firing provenance: `lib/jido_claw/platform/cron/worker.ex` + `lib/jido_claw/orchestration/workflow_runner.ex`
Manual triggers (`Cron.Worker.trigger/2` → `handle_cast(:trigger, state)` → `execute_job(state)`, `worker.ex:96`) reuse the same state as scheduled ticks — keying off `state.next_run` blindly would let `/cron trigger` consume the upcoming scheduled window's key and dedupe the real tick away. Fix by threading explicit provenance **without storing it**:

- Change to `execute_job(state, fire)`: it stamps a **local dispatch copy** (`%{state | fire: fire}`, requires a `fire: nil` field on the Worker struct) passed to `Dispatcher.dispatch/1`, while the GenServer state it returns derives from the original `state` — `fire` never persists into stored state or `get_state/2` output. `handle_info(:tick, …)` → `execute_job(state, {:scheduled, state.next_run})`; `handle_cast(:trigger, …)` → `execute_job(state, :manual)`. No dispatcher change.
- `WorkflowRunner.run_reactor/4` derives the key only from explicit scheduled provenance:
  - `Map.get(state, :fire)` = `{:scheduled, %DateTime{} = dt}` → `idempotency_key: "cron:#{state.id}:#{DateTime.to_iso8601(dt)}"`.
  - `:manual` / missing / non-DateTime → **no idempotency key** (always runs; operator intent). This replaces the earlier minute-truncation fallback entirely.
- Leave the `workspace_id` unique-integer line as-is (per-created-run workspace state, never reached on the dedupe path).
- `finalize/1` already maps any `{:ok, _, _}` → `:ok`, so dedupe doesn't increment the cron failure counter.

### Tests
- Extend `test/jido_claw/orchestration/reactor_runner_test.exs`: same key twice → same `run.id`, second call appends **zero** new `WorkflowEvent`s and doesn't execute steps; concurrent double-call (`Task.async` ×2, follow the sandbox-allowance precedent in `workflow_step_projection_test.exs` "concurrent named step events") → exactly one run, both callers get its id; no-key behavior unchanged.
- Extend `test/jido_claw/orchestration/workflow_runner_test.exs`: same state with `fire: {:scheduled, fixed_dt}` dispatched twice → one run, second returns `:ok`; `fire: :manual` twice → **two** runs, both with `idempotency_key == nil`; missing `:fire` → no key (regression for non-worker callers).
- Worker-level: assert tick threads `{:scheduled, next_run}` and trigger threads `:manual` into the dispatched map, **and that `get_state/2` afterwards still shows `fire: nil`** (extend the existing cron worker test with a capturing `:cron_workflow_runner` stub — the app-env seam in `Dispatcher.run_workflow/1` already exists).
- Pin `Ash.Resource.Info.identities(WorkflowRun)` includes `:unique_run_idempotency` with `nils_distinct?: true`.

---

## Slice 2 — T2-1 Deadline read-model (run + per-step)

Pure lateness evidence; never cancels anything.

### New pure module: `JidoClaw.Orchestration.Deadline` (`lib/jido_claw/orchestration/deadline.ex`)
- `parse(map | nil) :: {:ok, policy} | :none` — accepts string- or atom-keyed maps. **Squidie-faithful validation** (verified `squidie/.../deadline.ex:64-84`): `within` required **positive** integer; `due_soon` optional **non-negative** integer with `due_soon < within`; `escalate_after` optional **non-negative** integer (`0` = escalate immediately at due). Units: **seconds** (YAML is human/LLM-edited; Squidie's ms is an internal unit difference, documented). Invalid → `:none` at read time (the compiler rejects invalid declarations at compile time; `parse` stays total for whatever reaches storage).
- `evaluate(policy, started_at, now, completed_at) :: evidence | nil` — **Squidie-faithful math** (verified `:90-102`):
  - `due_at = started_at + within`; `due_soon_at = due_at − due_soon` (lead window before due, only when `due_soon` present); `escalate_at = due_at + escalate_after` (only when `escalate_after` present).
  - Effective time `t = completed_at || now` (terminal runs/steps freeze their evidence). Status, checking only thresholds that exist: `escalate_at && t >= escalate_at` → `:escalated`; `t >= due_at` → `:overdue`; `due_soon_at && t >= due_soon_at` → `:due_soon`; else `:on_time` (inclusive bounds — pin in tests). Missing `due_soon`/`escalate_after` make those statuses unreachable, never defaulted.
  - Evidence: `%{status, due_at, due_soon_at, escalate_at, overdue_by_ms}` (absent thresholds nil/omitted). `nil` when `started_at` is nil. **`overdue_by_ms` is always-present and non-negative:** `max(DateTime.diff(t, due_at, :millisecond), 0)` — `0` for on-time/due-soon (pin in tests; deliberately not Squidie's signed `remaining_ms`).
- `from_config(raw_map | nil, started_at, now, completed_at) :: evidence | nil` — convenience unwrapping `parse/1` (`:none` → nil); **this is what callers use** (fixes the `parse`/`evaluate` tuple mismatch).
- Pure (no Ash/IO); callers serialize DateTimes via existing `JidoClaw.Core.JsonSafe`.

### Run-level policy (no new column) — thread through ALL THREE launch sites
- Rides in `WorkflowRun.config["deadline"]` (existing `public? false` map).
- `Skills` struct (`lib/jido_claw/platform/skills.ex`): add `:deadline` to `defstruct`/`@type` (`map() | nil`); `parse_skill_file/1` captures top-level YAML `deadline:`.
- `ReactorRunner.run/3`: new `:deadline` opt folded into `run_config/3` output when present — store the **normalized policy returned by `Deadline.parse/1`**, not the raw input (stable config shape across atom/string-keyed YAML/test inputs; invalid → dropped with a log rather than failing the run).
- **Top-level validation:** per-step deadlines are validated by `validate_step_metadata/1`, but `skill.deadline` (parsed in `Skills.parse_skill_file/1`) would bypass it — add `validate_skill_deadline(skill)` to `Compiler.compile/1` before build (same error shape: `{:error, "Skill deadline …"}`), with tests for an invalid top-level block.
- **Launch sites** (all pass `deadline:`):
  1. `WorkflowRunner.run_reactor/4` (cron) → `skill.deadline`.
  2. `JidoClaw.Tools.RunSkill.do_run/2` (`lib/jido_claw/tools/run_skill.ex:64` — chat/MCP skill runs) → `skill.deadline`.
  3. `JidoClaw.Orchestration.Replay.launch/6` (`lib/jido_claw/orchestration/replay.ex:335`) → skill replays carry the **freshly re-resolved** `skill.deadline` (extend the resolved-definition map with `deadline:` for `kind: "skill"`); module-reactor replays preserve the original run's policy via `original.config["deadline"]` — `ReactorRunner.run/3` is a generic deadline-capable API, so module replays must not silently drop it.

### Per-step policy — ride the `irreversible:` rails end-to-end
- `lib/jido_claw/workflows/step_normalizer.ex`: add `"deadline" => :deadline` to `@canonical_keys`.
- `lib/jido_claw/skills/compiler.ex`: validate in the `step_metadata_error/1` cond (precedent: retry/compensate/irreversible) — nil OR a map passing the `Deadline.parse` rules above, else `{:error, "Step '<label>': deadline …"}`. Thread the **normalized** policy (`Deadline.parse` output, matching `run_config`'s convention) into `step_options/2` (compiler.ex:325-338) beside `irreversible:`.
- **Iterative mode (explicit decision):** deadlines are **loop-level only**. The generator role's `deadline:` is threaded onto the synthetic `IterativeStep` impl opts in `build_iterative/1` (the loop IS the single projected step); a `deadline:` on any other role → compile error ("iterative deadlines are loop-level; declare it on the generator step"). **Retrieval detail:** `IterativeStep.extract_roles/1` normalizes roles through code that drops unknown keys (`iterative_step.ex:250`), so the compiler reads the deadline via a small explicit helper over the **normalized raw skill steps** (find the generator-role step in `skill.steps`, take its `:deadline`) — never through `extract_roles`/`normalize_step`. It rides impl opts like `retry:`.
- `lib/jido_claw/orchestration/reactor_middleware.ex`: `deadline_policy/1` reader mirroring `irreversible_flag/1`; `put_present(:deadline, …)` in `step_payload/1` (shared by all step events — deliberate, see next point).
- `lib/jido_claw/orchestration/workflow_event/changes/allocate.ex`: project `deadline` in the **common `step_attrs/3`** (with a `put_valid(…, &valid_policy_map?/1)` guard), NOT the `:step_started` arm — a step row can be created by `step_completed`/`step_failed` when `step_started` was missed, and static metadata must survive that path.
- `lib/jido_claw/orchestration/workflow_step.ex`: new `attribute :deadline, :map, allow_nil? true, public? false`; add `:deadline` to the accept lists of **all three** projection upserts (`record_started`, `record_completed`, `record_failed`). Policy is static, so re-writing the same value on each event is safe. `mise exec -- mix ash.codegen add_workflow_step_deadline`.

### Fingerprint interaction (explicit decision)
Deadlines are **observability semantics, not execution semantics** — they are deliberately **excluded** from `DefinitionFingerprint`'s canonical term, so editing a deadline never trips replay's definition gate. Add a comment at the canonical-term builder (`lib/jido_claw/orchestration/definition_fingerprint.ex:~153`) and a test pinning that a deadline-only YAML edit leaves `for_skill/1` unchanged. (`depends_on` is already execution semantics and already hashed.)

### Surfaces
- `lib/jido_claw/workflow_view.ex`: `run_to_map/1` gains `deadline: Deadline.from_config(run.config["deadline"], run.started_at, now, run.completed_at)` (absorbed into `Visibility.run_view` in Slice 3). `to_mcp_map`'s `JsonSafe.encode` handles the DateTimes. MCP `workflow_status` tool inherits with zero changes — additive key only.
- `lib/jido_claw/web/live/workflows_live.ex`: "Deadline" column in the runs table + steps sub-table rendering a small badge (`:due_soon` amber, `:overdue`/`:escalated` red; nil → "—"; existing inline-style idiom). Capture one `now = DateTime.utc_now()` per render pass. **Bump both hard-coded `colspan="5"`s** (lines 174, 210) to the new column count.
- **Live refresh:** lateness crosses boundaries without any event, so add a 30s `Process.send_after(self(), :refresh_deadlines, 30_000)` timer (armed in `mount` under `connected?(socket)`, re-armed in `handle_info`) that re-runs `list_runs` (+ `list_steps` and graph rebuild if a run is expanded) while **preserving** `expanded_run_id`, `reveal_runs`, `steps_view`, and `replay_blocked` assigns.

### Tests
- New `test/jido_claw/orchestration/deadline_test.exs` (`async: true`, no DB): parse validity matrix incl. `due_soon == within` rejected, `due_soon: 0` / `escalate_after: 0` accepted; boundary-exact evaluate (at/just-before each threshold); missing `due_soon`/`escalate_after` make those statuses unreachable; completed-at freeze; nil anchor → nil; `from_config` unwrapping; `overdue_by_ms == 0` for on-time/due-soon and positive past due.
- Extend compiler tests (malformed/valid per-step `deadline:`; **invalid top-level `skill.deadline` → compile error**; iterative non-generator deadline → error; generator deadline lands on IterativeStep opts), `workflow_step_projection_test.exs` (policy projects via `step_started` AND via a started-less `step_completed`-only sequence), `reactor_runner_test.exs` (`:deadline` opt → `config["deadline"]`), RunSkill + Replay tests pinning the **deadline-source asymmetry** (skill replay uses the freshly re-resolved `skill.deadline` — including after a deadline-only edit, which must pass the fingerprint gate un-forced; module-reactor replay preserves `original.config["deadline"]`), `definition_fingerprint_test.exs` (deadline-only edit → same hash), WorkflowView test (overdue run reports `deadline.status`), LiveView render of the badge.

---

## Slice 3 — T2-2 Actor-visibility redaction (after 1+2; the flip lands together with the replacement surface)

### New module: `JidoClaw.Orchestration.Visibility` (`lib/jido_claw/orchestration/visibility.ex`)
- Scopes `:operator | :auditor`, always an explicit argument.
- `run_view(run, scope, now)` / `step_view(step, scope, now)` → plain maps; `redact_error(binary | nil, scope)`. **`now` is an explicit `DateTime` argument** (not read inside) so one timestamp serves a whole render/build pass — consistent durations + deadline evidence, deterministic tests. `WorkflowView.build` and the LiveView each capture `DateTime.utc_now()` once and thread it through.
  - `:operator` `run_view` **preserves the exact current `WorkflowView.run_to_map` key set** (`run_id, name, workflow_type, status, started_at, completed_at, duration_ms, error, result_summary`) **additively** extended with `deadline` (`Deadline.from_config(run.config["deadline"], run.started_at, now, run.completed_at)`) — the `workflow_status` MCP contract must not shrink. `result_summary` lifts the existing 200-char/key-filter logic applied **after** `Transcript.redact`; `error` is `Patterns`-scrubbed **then** truncated (redact-before-truncate, so truncation can't bisect a secret into a survivable fragment).
  - `:operator` `step_view` (explicit shape): `%{name, step_type, sequence, status, started_at, completed_at, deadline: Deadline.from_config(step.deadline, step.started_at, now, step.completed_at), error: redact_error(step.error, :operator)}` — **no `output` key at operator scope** (metadata + status only; the dashboard table doesn't render output today and the agent never needs it).
  - `:auditor`: the same keys plus `result: Transcript.redact(run.result)` / `output: Transcript.redact(step.output)` and untruncated (still `Patterns`-scrubbed) `error` — defense-in-depth; `Redaction.Env` already covers bare keys `password`/`secret`/`token`/`authorization`/`credential` + the `_KEY`/`_TOKEN`/… suffixes. Use `Transcript.redact` for maps — `Patterns.redact` alone only scans binaries.
- Lives in `Orchestration` (projects orchestration resources; precedent: `Allocate` already calls `Transcript.redact`).

### Callers
- `lib/jido_claw/workflow_view.ex` → thin wrapper over `Visibility.run_view(run, :operator, now)` with one `now` per `build` (permanently operator; this is the LLM/MCP surface).
- `lib/jido_claw/tools/replay_workflow.ex:64` → `Visibility.redact_error(run.error, :operator)`.
- `lib/jido_claw/web/live/workflows_live.ex`:
  - `reveal_runs :: MapSet` assign (default empty) + "Reveal payloads"/"Hide payloads" button per run in the Actions cell; `handle_event("reveal", %{"id" => id}, …)` toggles membership. `scope_for(run_id)` → `:auditor` iff member.
  - Keep `runs`/`steps` assigns as **structs**; project through `Visibility.run_view/step_view` at render with the current scope (reveal toggle re-renders without re-fetch). The expanded steps table's `step.error` (current line 202) and any payload cells render only projected values; a revealed run also reveals its expanded steps. The 30s refresh preserves `reveal_runs`.

### The `public?` flip
- `WorkflowRun.result`/`error` and `WorkflowStep.output`/`error` → `public?(false)`. Private attributes remain accepted in actions (the `set_checkpoint`/`resume_checkpoint` precedent) and readable on loaded structs — the struct-readers above all route through Visibility now.
- **Known consequence (accepted):** the Orchestration domain mounts `AshAdmin.Domain` (`lib/jido_claw/orchestration.ex:14`), so payloads disappear from AshAdmin views; the dashboard reveal toggle is the replacement surface.
- `mise exec -- mix ash.codegen flip_workflow_payload_visibility` to reconcile resource snapshots (commit whatever it emits, possibly nothing).

### Tests
- New `test/jido_claw/orchestration/visibility_test.exs`: both scopes over payloads containing a `"token"` key and an `sk-…`-shaped string — operator truncates+redacts; auditor returns full shape with `[REDACTED]` still applied; redact-before-truncate pinned (a secret straddling the 200-char boundary never leaks a prefix); operator run_view key set equals the legacy `run_to_map` set + `deadline`; nils pass through.
- **Security pins:** workflow_status / replay_workflow tool tests asserting a secret seeded into `result`/`error` never reaches MCP output (operator scope is not overridable there).
- LiveView: reveal toggles exactly that run to auditor; other runs stay operator; toggle off restores; refresh keeps reveal state.
- Guard: `Ash.Resource.Info.attribute(WorkflowRun, :result).public? == false` (and the other three).

---

## Slice 4 — T3-1/T3-2 Step-DAG visualization (port from SquidSonar, copy-don't-dep)

### 4a. Edge persistence — `depends_on` rides the same rails as `step_type`
- `lib/jido_claw/orchestration/workflow_step.ex`: `attribute :depends_on, {:array, :string}, public? true, allow_nil? true, default []`; accept on **all three** projection upserts (same static-metadata rule as `deadline`). `mise exec -- mix ash.codegen add_workflow_step_depends_on` (combinable with Slice 2's codegen if implemented together).
- `lib/jido_claw/skills/compiler.ex` `step_options/2` extras, by mode:
  - `:dag` → `depends_on: Enum.uniq(step_deps(step) ++ step_consumes(step))` (the same union the builder wires; targets are validated names).
  - **`:sequential` → no stamping.** Unnamed steps have nil YAML names (`step_display_name/1`), so predecessor edges would be partial and would disable the adapter fallback while orphaning unnamed nodes. The adapter's sequence-chain fallback renders the honest linear chain instead.
  - iterative → none (single node).
- **Collect step** (`add_collect/3`, compiler.ex:340): stamp `depends_on:` on the `CollectStep` impl opts from `order`'s display names, **nil-filtered** (named steps only) — otherwise the synthetic collect node renders isolated in every DAG skill (real deps exist → fallback disabled). Collect-to-unnamed-step edges are accepted as absent (adapter filters unknown names; layout drops dangling edges).
- `lib/jido_claw/orchestration/reactor_middleware.ex`: `put_present(:depends_on, depends_on(step))` in `step_payload/1` (nil for `[]` so it's omitted; plain step-name strings pass `Transcript` untouched).
- `lib/jido_claw/orchestration/workflow_event/changes/allocate.ex`: project in the common `step_attrs/3` with an all-binaries list guard.

### 4b. Layout port: `JidoClaw.Web.Components.GraphLayout` (`lib/jido_claw/web/components/graph_layout.ex`)
- Copy `~/workspace/claws/squid_sonar/lib/squid_sonar_web/workflow_graph_layout.ex` (~254 LOC pure): `build(%{nodes, edges})` → `%{width, height, nodes: [%{node, x, y, width, height}], segments, ports}`. Topo-by-input-order, longest-path columns, parent-preferring rows, dog-leg segments; back/unknown edges silently dropped (the safety net).
- Keep geometry constants (`@node_width 210`, `@node_height 58`, gaps/padding). **Delete** the deadline/recovery node-height variants and their helpers (`@recovery_node_height` etc., `deadline_node?/1`, `recovery_node?/1`, `has_callback?/1`, `map_value/2`) — `node_height/1` collapses to the constant.
- Moduledoc attribution (upstream LICENSE is **Apache-2.0**): "Adapted from SquidSonar (`SquidSonarWeb.WorkflowGraphLayout`), © its authors, Apache License 2.0 (dark-trench/squid_sonar); deadline/recovery variants removed."
- Upstream tests don't port (all four assert the dropped variant heights) — write fresh ones.

### 4c. Adapter: `JidoClaw.Web.Components.StepGraph` (`lib/jido_claw/web/components/step_graph.ex`)
- `build(steps)` → `%{nodes, edges}`: sort by `{sequence, name}`; nodes carry **name/label/status/step_type only — never output/error/config/deadline payloads** (leakage hygiene, composes with Slice 3). Node name = the projected `WorkflowStep.name` (YAML name, or the positional/collect fallback the projection already stores); map the synthetic collect's name to a friendly `"collect"` label.
- Edges from `depends_on` filtered to known names; **fallback** when the union of all `depends_on` is empty → synthesize the linear sequence chain (don't mix real + synthetic). Sequential skills always take the fallback (4a); DAG skills always have real edges incl. collect.

### 4d. Render + LiveView
- `lib/jido_claw/web/components/core_components.ex`: `workflow_graph/1` function component taking the prebuilt layout — absolutely-positioned divs (stage/segments/ports/nodes) using this repo's CSS variables (`var(--border)`, `var(--muted)`, `var(--surface)`); node interior reuses `<.status_badge status={…} />`; wrap in `overflow-x: auto` for wide graphs. No SVG, no new CSS classes.
- `lib/jido_claw/web/live/workflows_live.ex`: `steps_view: :graph` default + Graph/Table toggle buttons in the expanded cell (table keeps timestamps/error/deadline detail); compute `step_graph` at expand time from the step structs (rebuilt by the 30s refresh when expanded); `handle_event("set_steps_view", …)` with **explicit literal matching** (`"graph" -> :graph; "table" -> :table` — never `String.to_atom` on params); reset `step_graph`/`steps_view` on collapse.

### Tests
- `test/jido_claw/web/components/graph_layout_test.exs`: empty graph zeros; single node at padding origin; linear chain → columns 1..3, horizontal-only segments; diamond → fan-out rows + dog-leg present; back-edge dropped.
- `test/jido_claw/web/components/step_graph_test.exs`: edges from deps; unknown deps filtered; all-empty → sequence chain; **nodes contain no payload keys** (regression pin).
- Extend `workflow_step_projection_test.exs` (the existing `dag_skill/0` fixture already has `synthesize` with two deps) → `depends_on` lands on rows end-to-end **and the collect row's `depends_on` lists the named steps**; extend `reactor_middleware_test.exs` for the payload field.
- LiveView: toggle flips `steps_view`; expand populates `step_graph` (follow the existing hand-built-socket pattern in `workflow_step_projection_test.exs:226-239`).

---

## Risks / gate watch-items

- **reach `--smells --strict`:** layout/adapter emit recurring small maps → possible `fixed_shape_map` findings; use the documented file-local pragma (`# reach:disable-for-this-file fixed_shape_map`) or the `.reach.exs` module-ignore precedent. No function-length rule exists in `.reach.exs`. No new bare rescues (ReactorRunner's file pragma already covers Slice 1's fallback if needed).
- **Unique-violation shape:** the Slice-1 race test must verify Ash returns `{:error, %Ash.Error.Invalid{}}` (tuple path) — if it raises instead, switch to the narrow-rescue fallback noted above.
- **Flaky-suite caution** ([suite flaky tests] memory): the new concurrent tests follow the existing sandbox-allowance precedent; verify any failure in isolation before blaming the change.
- **`ash.codegen` discipline:** three small migrations (idempotency_key, step deadline, step depends_on — the latter two combinable); commit snapshots with them. `deps.unlock --unused` is clean (zero new deps — copy, don't dep).
- **WorkflowsLive churn:** Slices 2/3/4 all touch it (deadline column + timer → reveal toggle + Visibility projection → graph toggle). Implement in slice order; each leaves the file compiling + tested, colspans matching the column count, and refresh preserving `expanded_run_id`/`reveal_runs`/`steps_view`/`replay_blocked`.

## Verification

1. Per slice: targeted test files above via `mise exec -- mix test <file>`.
2. Full gate (required for "complete"): `mise exec -- mix precommit` run bare in background, read the output tail ([no pipe on gate commands] memory).
3. Manual smoke (optional): `mise exec -- mix jidoclaw` + dashboard → seed a run via a cron `target: :workflow` job or `run_skill`; check the Deadline column, payload redaction + Reveal toggle, Graph/Table toggle, manual `/cron trigger` not deduping; Tidewave `project_eval` / `execute_sql_query` to inspect `workflow_runs.idempotency_key` and `workflow_steps.depends_on`/`deadline`.
4. Docs: update `REACTOR-ADOPTION.md`'s status-reconciliation banner (Phase 5 shipped, what diverged) and `FEATURES-WORTH-BORROWING.md` entries T2-1/T2-2/T2-3/T3-1 with shipped notes — the established pattern from T1-3.
