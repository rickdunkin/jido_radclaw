# Plan: Resolve code-review findings on the T2-2 AgentView changeset

## Context

The in-flight (unstaged + untracked) "T2-2 AgentView completion" changeset made `WorkflowRun`
and Forge `Session` tenant-required, added `workspace_uuid`/parent agent scoping, rewired
`Tools.ListAgents` through a new `SwarmScope`/`SwarmView`, and deleted
`Orchestration.RunSummaryFeed`. A code review surfaced three findings. I validated all three
against the actual code (see evidence inline). This plan fixes them.

The **done bar** is explicit: `mise exec -- mix precommit` must succeed. That alias runs **7 gated steps**
(`mix.exs:240-248`), so this plan must leave the *entire* changeset green — not just the three
findings:

```
compile --warnings-as-errors → jidoclaw.system_prompt.check → deps.unlock --unused →
format → credo --strict → dialyzer --format short → test (prepends ash.setup --quiet)
```

**Toolchain:** always invoke mix via `mise exec -- mix …`. `mise.toml` pins `erlang = 28.5`;
a bare `mix` uses the shell-default OTP and fails compiling `:memento`.

---

## Fix 1 — `Inspection.active_workflows` silently returns `[]` (VALID)

**Root cause.** `inspection.ex:758-773` calls `WorkflowRun.list_active()` with no tenant/actor.
`WorkflowRun` now has `multitenancy strategy(:attribute), global?(false)` (`workflow_run.ex:15-19`)
plus the `JidoClaw.Resource` read policy `tenant_id == ^actor(:tenant_id)` (`resource.ex:53-55`),
so the call errors; `safe/1` (`inspection.ex:811-821`) swallows it to `nil` → `[]`. The field is
permanently empty on all five summary paths.

**Chosen approach: thread tenant/actor.** No cross-tenant leak, reuses the
existing `JidoClaw.Authorization.Actor.system/1` + `list_active` code-interface, no shared-macro
change — identical to how `WorkflowView`/`ForgeView` already read tenant-scoped data
(`forge_view.ex:50,73`, `workflow_view.ex`).

- Replace the arity-0 `active_workflows/0` (`inspection.ex:758-773`) with
  `active_workflows(tenant_id, actor \\ nil)`:
  - binary `tenant_id` → `actor = actor || Actor.system(tenant_id)`, then
    `safe(fn -> WorkflowRun.list_active(tenant: tenant_id, actor: actor) end)`; keep the existing
    `is_list/1` map-to-entry / `_ -> []` shape (extract the row→map into a small `workflow_entry/1`).
  - non-binary `tenant_id` (nil) → `[]` (genuine best-effort; documented in a one-line comment).
- Update the five call sites to pass the tenant already in scope:
  - `handoff_session_summary` (`:572`) and `plain_session_summary` (`:598`) → `active_workflows(tenant_id, actor)` (both already bind `tenant_id` + `actor`).
  - `session_map_summary/3` (`:545`) → `active_workflows(tenant_id)` (binds `tenant_id`, no actor — derives system actor).
  - `pid_summary` (`:420`) and `agent_id_summary` (`:490`) → `active_workflows(Keyword.get(opts, :tenant_id))` (may be nil → stays `[]`, unchanged behavior for those paths).
- The `Summary` struct and its `workflows` typespec (`inspection/summary.ex:37-42,66,89`) are
  **unchanged**; `inspect_workflow/1`'s separately-synthesized `workflows` is untouched.

**Test** (`test/jido_claw/inspection_test.exs`, mirroring the `inspect_workflow/1` tests at
`:532-563`): seed running `WorkflowRun`s under tenants A and B. Assert:
- a session-path summary built **for tenant A** includes A's run and **excludes** tenant B's run
  (proves scoping, not just non-emptiness);
- a genuinely tenant-less path — e.g. `Inspection.inspect_agent(agent_id)` with no `:tenant_id`
  opt, which routes through the `agent_id_summary`/`pid_summary` branch — yields `workflows: []`.

---

## Fix 2 — `ForgeView.snapshot/2` ignores its `workspace_id` scope key (VALID)

**Root cause.** `snapshot/2` (`forge_view.ex:45-61`) accepts `workspace_id` via `scope_keys/0`
(`:130`) but only reads `tenant_id`/`actor` and filters by `Session.by_name/2`
(`session.ex:145-149`, name-only + attribute-tenancy). `build/1` *does* honor workspace
(`read_active_sessions/3`, `forge_view.ex:91-103`); `snapshot/2` is inconsistent. `snapshot/2` is
brand-new untracked code with no production caller yet — fix the contract before it lands.

**Fix (no resource change — mirrors `build/1`'s nil/non-nil semantics).** In `snapshot/2`, extract
`workspace_id = Keyword.get(opts, :workspace_id)`, then post-check the loaded session:

```elixir
case Session.by_name(session_id, tenant: tenant_id, actor: actor) do
  {:ok, %Session{} = session} ->
    if workspace_match?(session, workspace_id),
      do: {:ok, session_to_map(session, live_ids())},
      else: {:error, :not_found}
  {:ok, nil} -> {:error, :not_found}
  {:error, _} -> {:error, :not_found}
end
```

with `defp workspace_match?(_s, nil), do: true` / `workspace_match?(%Session{workspace_id: ws}, ws), do: true` /
`workspace_match?(_, _), do: false`. `Session.workspace_id` is a public attribute
(`session.ex:167-170`) already projected by `session_to_map/2` (`forge_view.ex:108`).

**Test** (`test/jido_claw/forge_view_test.exs`): the suite already seeds via `seed_workspace/1`
+ `Persistence.record_session_started/2`. Add a same-tenant/different-workspace case: seed a
second workspace under `tenant_a`, record a session in it, assert
`snapshot(session, %{tenant_id: tenant_a, workspace_id: workspace_a.id})` → `{:error, :not_found}`,
while the matching `workspace_id` (and the no-`workspace_id` call) → `{:ok, _}`.

---

## Fix 3 — Stale docs after `RunSummaryFeed` deletion + `ListAgents` rewire (VALID)

`application.ex` cleanly removed the only supervised Orchestration child (`RunSummaryFeed`);
there are **no dangling code references** (compile is safe). Only docs are stale. Edit each:

**`RunSummaryFeed` (deleted module) — remove live-system mentions** (the historical
`T2-2-AGENTVIEW-COMPLETION-PLAN.md` narrates the removal and intentionally keeps its references):
- `README.md:506-507` — remove the empty `Orchestration → RunSummaryFeed` supervision-tree branch (no supervised orchestration process remains).
- `README.md:555` — remove the `JidoClaw.Orchestration.RunSummaryFeed` row from the OTP Process Overview table.
- `README.md:1057` — remove the `run_summary_feed.ex` line from the source-tree listing.
- `docs/ARCHITECTURE.md:54-55` — remove the `Orchestration → RunSummaryFeed` application-tree branch.
- `docs/ARCHITECTURE.md:244-245` — remove the `RunSummaryFeed (GenServer, started in supervision tree) → Streams workflow events` block (keep the `RunPubSub` entry above it).
- `docs/ARCHITECTURE.md:732` — remove the `├── Orchestration (RunSummaryFeed)` boot-sequence line.
- `docs/exploration/argus/OVERVIEW.md:565` — replace "`RunSummaryFeed` GenServer subscribes." with the current subscriber: **`DashboardLive` subscribes via `RunPubSub.subscribe_all/0`** (`dashboard_live.ex:17`), handling run events at `dashboard_live.ex:97`.

**`RunPubSub` "no publishers" claims are now false — `WorkflowRunner` publishes, `DashboardLive` consumes:**

This changeset wired `WorkflowRunner` to broadcast `:run_started`/`:run_completed`/`:run_failed`
via `RunPubSub.broadcast/2` (`workflow_runner.ex:108,172,199,218`), consumed by `DashboardLive`
(`dashboard_live.ex:17,97`). Correct every stale "no publishers / zero callers" claim in
`docs/exploration/argus/OVERVIEW.md`:
- `:180` — "topics are defined but no code publishes to them" → now published by `WorkflowRunner` (run-level lifecycle events).
- `:324` — keep the first column `workflows:run:<id>` (the proposed Phoenix **channel** contract — distinct from the internal PubSub topics `orchestration:run:<id>`/`orchestration:runs`). Fix only the source/status cell: "`Orchestration.RunPubSub` (exists, no publishers)" → "`Orchestration.RunPubSub` (published by `WorkflowRunner`)", and the remaining action is the channel proxy (the "wire up the runner to publish" half is done), mirroring the `forge:*` rows above.
- `:487` — roadmap item: the "broadcast on `RunPubSub`" half is done; verify against `workflow_runner.ex` whether `WorkflowStep` persistence / `plan_workflow.ex` wiring genuinely remains, and keep only the still-open parts.
- `:566` — "Zero callers of `RunPubSub.broadcast/2` … `dashboard_live.ex:79` comment 'RunPubSub — not yet broadcast'" is stale on both counts: `WorkflowRunner` is the caller, and that dashboard comment is gone (now `dashboard_live.ex:97`: "Run events (RunPubSub — broadcast by JidoClaw.Orchestration.WorkflowRunner)"). Rewrite to state the runner publishes and the dashboard consumes.
- `:582` — "`orchestration:run:<id>`, `orchestration:runs` — defined, no publishers." → "defined; published by `WorkflowRunner`, consumed by `DashboardLive`."

**`ListAgents` "untouched" claim is false:**
- `docs/exploration/jidoka/FEATURES-WORTH-BORROWING.md:207` — replace "the pre-existing tool is `Tools.ListAgents`, untouched here" with the truth: `Tools.ListAgents` was rewired in this changeset to route through the new `Tools.SwarmScope` + `JidoClaw.SwarmView` (gaining tenant/workspace/parent scoping) rather than calling the process-global `JidoClaw.Jido.list_agents/0`.

The `OVERVIEW.md`/`FEATURES-WORTH-BORROWING.md` edits are in exploration docs; the
README/ARCHITECTURE supervision trees describe the running system and are the priority.

---

## Fix 4 — Make `mise exec -- mix precommit` green (the done bar)

The review only confirmed `format --check-formatted`, the *targeted* plan suite (95 tests), and
`ash_postgres.generate_migrations --check`. It did **not** confirm `credo --strict`, `dialyzer`,
`jidoclaw.system_prompt.check`, or the **full** `mix test`. So after Fixes 1–3:

1. Run `mise exec -- mix precommit` and triage each gate in order.
2. Likely-relevant gates and how to clear them:
   - **compile --warnings-as-errors** — resolve any unused-var/alias warnings introduced (e.g. the new `actor` thread in `inspection.ex`).
   - **jidoclaw.system_prompt.check** — if it fails, `.jido/system_prompt.md` drifted from `priv/defaults/system_prompt.md`; sync per AGENTS.md (copy default → `.jido/`). Don't expect drift unless the changeset edited tool/skill descriptions in the defaults.
   - **deps.unlock --unused** — prunes `mix.lock`; non-failing.
   - **format** — `mise exec -- mix format`.
   - **credo --strict** — `.credo.exs` runs `AshCredo` + `ExDNA` (AI duplication) checks in strict mode; fix anything my edits or the wider changeset trip.
   - **dialyzer --format short** — ensure the new `active_workflows/2` and `workspace_match?/2` specs/clauses don't introduce contract errors; first run may rebuild the PLT (slow).
   - **test** — full suite, not just the plan subset.
3. **Fix failures introduced by this changeset** (Fixes 1–3 and the surrounding T2-2 work) so each
   gate passes. If a gate — especially `credo`/`dialyzer` — reveals a **broad backlog clearly
   unrelated to this patch**, stop and report scope to the user rather than mass-editing, so the
   precommit bar doesn't balloon into fixing the whole codebase's lint/type debt.

---

## Verification

- **Primary gate:** `mise exec -- mix precommit` exits 0 (all 7 steps). This is the definition of done.
- **Targeted (faster inner loop while iterating):**
  `mise exec -- mix test test/jido_claw/inspection_test.exs test/jido_claw/forge_view_test.exs`
- **Fix 1 runtime proof (Tidewave `project_eval`):** create a tenant + a running `WorkflowRun`
  under it, call `Inspection.inspect_*` on a session in that tenant, confirm `summary.workflows`
  is non-empty; confirm it is `[]` with no tenant. Optionally confirm the old path returned `[]`.
- **Fix 2:** the new same-tenant/different-workspace test goes red before the `snapshot/2` change
  and green after.
- **Fix 3:** `grep -rn "RunSummaryFeed\|run_summary_feed" README.md docs/` returns only the T2-2
  *plan* doc (`T2-2-AGENTVIEW-COMPLETION-PLAN.md`, which legitimately narrates the removal) — no
  hits in `README.md`/`docs/ARCHITECTURE.md`/`OVERVIEW.md`; `grep -n "no publishers\|Zero callers\|not yet broadcast" docs/exploration/argus/OVERVIEW.md`
  returns nothing (all `RunPubSub` publisher claims now name `WorkflowRunner`/`DashboardLive`); and
  the `FEATURES-WORTH-BORROWING.md:207` line no longer says "untouched".

## Notes / non-goals

- No change to the `Summary` struct shape, the `JidoClaw.Resource` macro, or `WorkflowRun`'s
  actions (no new global action) — tenant plumbing keeps the blast radius minimal.
- No new migration; Fix 2 is a code-level post-filter reusing existing attributes/actions.
- Commits are **not** part of this plan — I will not `git commit` unless you explicitly ask.
