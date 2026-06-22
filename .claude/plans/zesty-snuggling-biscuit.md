# AR-2 Composer — Phase 5: Observe over MCP (G2-1, §10.2)

## Context

The AR-2 deterministic route composer is built through Phase 4 (catalog + pure router, durable
envelope, triage seed, human gates — all committed). Today a running or finished composer run is
**opaque from outside the BEAM**: there is no way for an MCP client (Claude Code, Cursor) to
discover *what the composer can do* (its catalog of composable stages) or to read *what a specific
composer run is doing* (its current route / waves / held stages / dropped stages / live signals).

Phase 5 (§10.2 of `docs/exploration/alp-river/AR-2-COMPOSER-PLAN.md`) closes that gap with the
**observe surface**, in two pieces shipped together:

1. **Catalog as an MCP resource** at `jido://workflows/catalog` — a client can *discover* the
   composable surface, not just trigger it.
2. **A composer-aware single-run status tool** (`inspect_workflow`) — a client can read a composer
   run's live route / wave / held / dropped / live-signals.

Phase 5 is **purely additive, read-only code over existing durable state** — no new
`WorkflowEvent` kinds, no `WorkflowRun` schema change, no projection change, **no DB migration**.

### Decisions locked with the user

- **MCP only** — Phase 5 is the MCP observe surface. The web dashboard (`WorkflowsLive`) is **out
  of scope**; the `WorkflowsLive` render-assigns triad is **not** in the blast radius.
- **New dedicated tool** — leave `workflow_status` (the tenant rollup) untouched; add a separate
  single-run tool `inspect_workflow`, mirroring the `agent_status` → `inspect_agent` convention.
  Published tool count rises **22 → 23**.

### Revisions applied from plan review

- **(P1) Output shaping** — the tool must **not** `JsonSafe.encode/1` the whole map (that
  string-keys the top level, and jido_action splits `output_schema` on **atom** keys → required-key
  validation fails). Follow `InspectAgent` exactly: **top-level keys stay atoms; only nested values
  go through `JsonSafe.encode/1`** (`tools/inspect_agent.ex:101-132`).
- **(P1/P2) MCP-only is literal** — `workflow_status` is **not** registered on the REPL agent
  (`JidoClaw.Agent` has no `WorkflowStatus`, `lib/jido_claw/agent/agent.ex`). So `inspect_workflow`
  is MCP-only too: register **only** in `mcp_server.ex`; **do not touch `agent.ex`** and **no
  `system_prompt.md` change**.
- **(P2) `wave_paused` is non-load-bearing** — recovery derives a parked gate from a `wave_started`
  with no matching `wave_completed` + a materialized child, and explicitly does not rely on
  `wave_paused` (`lib/jido_claw/route_composer/route_composer.ex:1741`). So the blocked-on-gate
  signal is derived **authoritatively from child-run status** (`status == :awaiting_approval`), not
  from `wave_paused`. The pure summary surfaces only the reliable `wave_in_flight`.
- **(P2) No silent observe failures** — `snapshot/2` distinguishes *available* / *not-yet-composed*
  / *observe-unavailable* instead of collapsing an event-read error into "no composer state."
- **(P3) Execution-path test** — at least one `Jido.Exec.run/4` test (the validated path,
  precedent `test/jido_claw/tools/search_web_test.exs:166`) so output-schema validation is exercised,
  not just direct `run/2`.

### The design insight that makes 5b cheap

`RouteComposer.Projection.project/2` (`lib/jido_claw/route_composer/projection.ex:57`) **cannot**
rebuild composer state from a run row + log alone — it folds onto a *seed* (catalog + seeded
signals/artifacts) that lives only inside the running GenServer (`projection.ex:11-16`). **We
sidestep it.** Every wave durably appends a **self-contained `route_composed` snapshot**
(`lib/jido_claw/route_composer/route_composer.ex:1422-1434`) carrying `route / waves / held /
dropped / triggered_by / size / live / available / premises`. Reading the **latest `route_composed`
payload** (plus a tiny seed-free fold for `ran` / `wave_index` / `wave_in_flight`) gives the full
observe view for **running and terminal** runs, with **no seed**. The snapshot is **names/labels
only** (signal topics, stage names, artifact *names* via `Fold.available/1`, premises
`{path, est_size}`) — **no artifact values** — so it carries no redaction risk.

---

## Part A — Catalog MCP resource (`jido://workflows/catalog`)

The `jido_mcp` macro supports `resources:` on `publish:`; `MCPServer` just doesn't use it yet.
Registration is by an **exact `uri()` string** (no RFC-6570 templates) — exactly the
single-catalog shape §10.2 commits to. Serializer exists:
`Catalog.to_map(Catalog.all())` (`lib/jido_claw/route_composer/catalog.ex:219` + `stage.ex:147`)
returns the JSON-safe, string-keyed `%{name => stage_map}`. (Reviewer confirmed this part sound.)

### New module — `JidoClaw.MCPServer.Resources.WorkflowCatalog`
`lib/jido_claw/core/mcp_server/resources/workflow_catalog.ex`

```elixir
defmodule JidoClaw.MCPServer.Resources.WorkflowCatalog do
  @moduledoc "MCP resource exposing the deterministic route-composer catalog as JSON."
  @behaviour Jido.MCP.Server.Resource

  alias JidoClaw.RouteComposer.Catalog

  @uri "jido://workflows/catalog"

  @impl Jido.MCP.Server.Resource
  def uri, do: @uri
  @impl Jido.MCP.Server.Resource
  def name, do: "workflow_catalog"
  @impl Jido.MCP.Server.Resource
  def description,
    do: "The route-composer catalog: every composable stage (unit, routes, inputs/outputs, " <>
          "subscribes/publishes, locks) the deterministic composer can schedule."
  @impl Jido.MCP.Server.Resource
  def mime_type, do: "application/json"

  @impl Jido.MCP.Server.Resource
  def read(@uri, _frame), do: {:ok, %{"stages" => Catalog.to_map(Catalog.all())}}
  def read(_uri, _frame), do: {:error, :not_found}
end
```

`read/2` returns **`{:ok, map}`** — the jido_mcp runtime auto-`Response.json`-encodes a map
(`deps/jido_mcp/lib/jido_mcp/server/runtime.ex:207`); **not** the Anubis `{:reply, %Response{},
frame}` triple. Use explicit-module `@impl Jido.MCP.Server.Resource` (repo convention; credo
`ImplTrue`).

### Register on the server — `lib/jido_claw/core/mcp_server.ex`
Add a `resources:` key to the `publish:` map (currently `tools:` only, `mcp_server.ex:15-51`), and
add the new tool to `tools:` (Part B):

```elixir
publish: %{
  tools: [ ...existing 22..., JidoClaw.Tools.InspectWorkflow ],   # → 23
  resources: [JidoClaw.MCPServer.Resources.WorkflowCatalog]
}
```

---

## Part B — Composer-aware single-run status (`inspect_workflow`)

Four changes: shared accessor extraction, a seed-free summarizer, teaching
`WorkflowView.snapshot/2`, and the new MCP-only tool.

### B1. Extract `JidoClaw.RouteComposer.EventPayload` (shared tolerant accessors)
`lib/jido_claw/route_composer/event_payload.ex`

`Projection` has private tolerant payload accessors (`get/2`, `list_field/2`, `int_field/2`,
`projection.ex:212-233`) handling JSONB string-keys vs synthetic atom-keys (atom wins, else
string). `Observe` needs the same; duplicating them trips the duplicate-code credo gate (per
`project_precommit_newcode_gotchas`). **Extract once** into `EventPayload` (`get/2`, `list/2`,
`int/2`); both `Projection` and `Observe` call it. Mechanical, test-covered refactor of
`Projection` (its tests pin the behavior). (Reviewer confirmed this reasonable.)

### B2. New `JidoClaw.RouteComposer.Observe` — seed-free observe summarizer
`lib/jido_claw/route_composer/observe.ex`

Pure: `summarize([WorkflowEvent.t()]) :: map() | nil` (mirrors `Fold`/`Loop`/`Projection`). Returns
`nil` when no `route_composed` event exists yet.

```elixir
@spec summarize([map()]) :: map() | nil
def summarize(events) do
  events = Enum.sort_by(events, & &1.seq)
  case latest(events, :route_composed) do
    nil -> nil
    %{payload: snap} ->
      %{
        route: EventPayload.list(snap, :route),
        waves: EventPayload.get(snap, :waves) || [],
        held: EventPayload.get(snap, :held) || %{},
        dropped: EventPayload.get(snap, :dropped) || %{},
        triggered_by: EventPayload.get(snap, :triggered_by) || %{},
        size: EventPayload.get(snap, :size),
        live: EventPayload.list(snap, :live),
        available: EventPayload.list(snap, :available),
        premises: EventPayload.get(snap, :premises) || %{},
        ran: net_ran(events),                                   # wave_completed − stages_invalidated
        latest_started_wave_index: latest_started_wave_index(events),
        wave_in_flight: wave_in_flight?(events)  # latest wave_started.idx has NO wave_completed
      }
  end
end
```

- `net_ran/1` — fold in `seq` order: `wave_completed.stages` union, `stages_invalidated.stages`
  difference (matches `Projection`'s net `ran`).
- `latest_started_wave_index/1` — the `wave_index` of the latest `wave_started` (the wave
  currently/last launched; paired 1:1 with the latest `route_composed`; payloads confirmed
  `lib/jido_claw/route_composer/route_composer.ex:1422,1436`). **Deliberately named distinctly from
  `Projection`'s `wave_index`**, which means the *next/completed* index advanced by `wave_completed`
  — for a terminal run those two differ (latest-started `N` vs projected `N+1`), so this surface
  uses the unambiguous "latest started" name.
- `wave_in_flight?/1` — **reliable** signal that a wave is launched but not yet folded: the latest
  `wave_started.wave_index` has no matching `wave_completed`. (Deliberately does **not** read
  `wave_paused` — non-load-bearing per `route_composer.ex:1741`.) The authoritative
  *blocked-on-a-gate* determination is made in `snapshot/2` from child-run status (B3), not here.

### B3. Teach `WorkflowView.snapshot/2` composer-awareness
`lib/jido_claw/workflow_view.ex` (the unwired `snapshot/2`, `workflow_view.ex:38-54`)

Keep the base = `Visibility.run_view(run, :operator, now)` (preserves operator-scope redaction of
`error`/`result_summary`, raw nested values, **atom top-level keys**). For a composer run,
additively set a `:composer` key that is **always a map** (with an `available` flag) so an observe
failure is never silently indistinguishable from "no composer state":

```elixir
{:ok, run} -> {:ok, run |> base_view(now) |> put_composer(run, tenant_id, actor)}

defp put_composer(view, %WorkflowRun{workflow_type: "composer", id: id}, tenant_id, actor) do
  composer =
    case WorkflowEvent.for_run(id, tenant: tenant_id, actor: actor) do
      {:ok, events} ->
        case Observe.summarize(events) do
          nil -> %{available: false, reason: :not_yet_composed}
          summary -> summary |> Map.put(:available, true) |> put_gate_block(id, tenant_id, actor)
        end
      {:error, _} -> %{available: false, reason: :observe_unavailable}
    end
  Map.put(view, :composer, composer)
end
defp put_composer(view, _run, _tenant, _actor), do: view
```

**Authoritative blocked-on-gate signal** — `put_gate_block/4` queries child runs (parent stays
`:running` across a child gate pause, §6) for the reliable status. `WorkflowRun` already has
`has_many :child_runs` + an indexed `[:tenant_id, :parent_run_id]` (`workflow_run.ex:385,66`):

```elixir
# `WorkflowView` already `require`s + `alias`es `Ash.Query` (workflow_view.ex:6,8)
# and `read_runs/5` already uses `Query.filter` — reuse that alias, add no new one.
defp put_gate_block(summary, parent_id, tenant_id, actor) do
  WorkflowRun
  |> Query.filter(parent_run_id == ^parent_id and status == :awaiting_approval)
  |> Ash.read(tenant: tenant_id, actor: actor)
  |> case do
    {:ok, runs} ->
      ids = Enum.map(runs, & &1.id)
      Map.merge(summary, %{
        awaiting_approval_available: true,
        awaiting_approval: ids != [],
        awaiting_child_run_ids: ids
      })

    {:error, _} ->
      # Do NOT collapse a read failure to `awaiting_approval: false` — that is a
      # false negative for the exact gate-block state this surface exists to expose.
      # Mark the signal untrusted instead (no misleading `awaiting_approval` key).
      Map.put(summary, :awaiting_approval_available, false)
  end
end
```

On success the summary carries `awaiting_approval_available: true` + `awaiting_approval` (bool) +
`awaiting_child_run_ids`; on a read failure it carries only `awaiting_approval_available: false`
(no misleading `awaiting_approval: false`). These keys live **inside** the `composer` map, which is
`JsonSafe.encode`d as a whole, so their nil/bool/atom shapes are never `output_schema`-validated.
Note `held` (lock-held stages, from the `route_composed` snapshot) and `awaiting_approval` (gate
park) are **distinct** waiting states, both surfaced honestly.

### B4. New tool — `JidoClaw.Tools.InspectWorkflow`
`lib/jido_claw/tools/inspect_workflow.ex`

`use JidoClaw.Tools.Action`, `category: "introspection"`, `tags: ["workflow", "read"]`, required
`run_id` param (`replay_workflow.ex:34` precedent), tenant strictly from `tool_context.tenant_id`
(`workflow_status.ex:26`). Follows `InspectAgent`'s **atom-top-level / JsonSafe-nested** projection:

```elixir
@impl Jido.Action
def run(%{run_id: run_id}, context) do
  tool_context = Map.get(context, :tool_context, %{})
  case Map.get(tool_context, :tenant_id) do
    tenant when is_binary(tenant) and tenant != "" ->
      case WorkflowView.snapshot(run_id, %{tenant_id: tenant}) do
        {:ok, snapshot} -> {:ok, project(snapshot)}
        {:error, _} = err -> err
      end
    _ -> {:error, :tenant_required}
  end
end

# Top-level keys stay ATOMS (output_schema splits on atoms); nested terms are
# JsonSafe-encoded (no leaf atom/DateTime reaches the MCP boundary). Optional
# keys are added ONLY when non-nil: an optional output_schema field IS validated
# when present, so `composer: nil` (fails :map) / `duration_ms: nil` (fails
# :integer) must never be emitted — and omitting `composer` for a non-composer
# run is the intended shape. Mirrors tools/inspect_agent.ex:101-132 but with the
# nil-omission discipline made explicit.
defp project(s) do
  %{run_id: s.run_id}
  |> put_present(:name, s.name)
  |> put_present(:workflow_type, s.workflow_type)
  |> put_present(:status, stringify_nilable(s.status))
  |> put_present(:duration_ms, s.duration_ms)
  |> put_present(:started_at, JsonSafe.encode(s.started_at))
  |> put_present(:completed_at, JsonSafe.encode(s.completed_at))
  |> put_present(:error, s.error)
  |> put_present(:result_summary, JsonSafe.encode(s.result_summary))
  |> put_present(:deadline, JsonSafe.encode(s.deadline))
  |> put_present(:composer, encode_present(Map.get(s, :composer)))
end

# Add the key only for a non-nil value (an optional output_schema field is
# validated when PRESENT, so a present-but-nil value would fail its type).
defp put_present(map, _key, nil), do: map
defp put_present(map, key, value), do: Map.put(map, key, value)

# Encode only when there's something to encode (keeps `composer` absent on a
# non-composer run rather than `JsonSafe.encode(nil)`).
defp encode_present(nil), do: nil
defp encode_present(value), do: JsonSafe.encode(value)

# `status` is atom|string|nil; a bare to_string/1 would emit "nil". Mirror
# tools/inspect_agent.ex:136-137.
defp stringify_nilable(nil), do: nil
defp stringify_nilable(value), do: to_string(value)
```

`output_schema` — declare only what is type-stable after projection (jido_action validates *only
specified fields*, and *only when present*, `deps/jido_action/lib/jido_action.ex:297`): `run_id:
[type: :string, required: true]`, `name`/`workflow_type`/`status` `[type: :string, required:
false]`, `duration_ms: [type: :integer, required: false]`, `composer: [type: :map, required:
false]`. Because `project/1` omits any nil optional, none of these is ever present-with-nil. Omit
`result_summary` (string *or* map) / `deadline` / timestamps / `error` from the schema (let them
pass — extra response keys are allowed by both jido_action and the Anubis JSON-schema layer).
`{:error, :not_found | :tenant_required}` are normalized to wire errors by the `Tools.Action`
wrapper.

### B5. Register the tool — **MCP only**
Add `JidoClaw.Tools.InspectWorkflow` to `publish.tools` in `mcp_server.ex` (→ 23). **Do not** add
it to `lib/jido_claw/agent/agent.ex` (consistent with `workflow_status`, which is not REPL-agent
registered), so **no `system_prompt.md` change** is needed.

---

## Files

**Create**
| Path | Purpose |
| --- | --- |
| `lib/jido_claw/core/mcp_server/resources/workflow_catalog.ex` | `WorkflowCatalog` MCP resource (A) |
| `lib/jido_claw/route_composer/event_payload.ex` | Shared tolerant payload accessors (B1) |
| `lib/jido_claw/route_composer/observe.ex` | Seed-free observe summarizer (B2) |
| `lib/jido_claw/tools/inspect_workflow.ex` | New single-run status tool (B4) |

**Modify**
| Path | Change |
| --- | --- |
| `lib/jido_claw/core/mcp_server.ex` | Add `resources:` + `InspectWorkflow` to `publish:` |
| `lib/jido_claw/route_composer/projection.ex` | Use `EventPayload` (drop private accessor copies) |
| `lib/jido_claw/workflow_view.ex` | `snapshot/2` composer-awareness + child-status gate block (B3) |

**Docs (hygiene; not required for precommit)**
- `AGENTS.md` — tool count/list (22 → 23) + note the `jido://workflows/catalog` resource. (No
  `system_prompt.md` change — the tool is MCP-only.)

---

## Tests

- **Resource (pure, no server boot)** — `test/jido_claw/core/mcp_server/resources/workflow_catalog_test.exs`:
  `uri/0 == "jido://workflows/catalog"`, `mime_type/0 == "application/json"`,
  `{:ok, %{"stages" => stages}} = read(uri(), %{})` with `stages` a non-empty map keyed by stage
  names (`"triage"`, `"plan-gate"`). Frame arg is ignored by the impl (pass `%{}`).
- **MCP registration** — extend `test/jido_claw/mcp_server_test.exs` (async:false): count **22 →
  23** (`mcp_server_test.exs:60`); `InspectWorkflow in __publish__().tools`;
  `is_list(__publish__().resources)`; `WorkflowCatalog in __publish__().resources`.
- **`Observe.summarize/1` (pure unit)** — `test/jido_claw/route_composer/observe_test.exs`: `nil`
  when no `route_composed`; latest-`route_composed`-wins; `ran` = `wave_completed` −
  `stages_invalidated`; `latest_started_wave_index` = the latest `wave_started.wave_index`;
  **`wave_in_flight` true for a `wave_started` with no `wave_completed`, including the parked-gate
  case where NO `wave_paused` was recorded** (the reviewer's non-load-bearing case). Cover both
  string-keyed (DB) and atom-keyed (synthetic) payloads.
- **`WorkflowView.snapshot/2` (raw map shape)** — extend `test/jido_claw/workflow_view_test.exs`.
  This asserts the **pre-projection** shape (atom top-level keys, **atom** `composer.reason`): a
  composer run with appended composer events → `:composer` with `available: true` + route/held/etc.;
  a composer run with an `:awaiting_approval` child → `awaiting_approval: true` +
  `awaiting_child_run_ids`; a composer run with no composer events → `%{available: false, reason:
  :not_yet_composed}` (atom); a non-composer run → no `:composer` key; not-found / tenant isolation.
  Reuse the `WorkflowRun.create` + `set_status` corruption-sim setup; append composer events via the
  same path as the Phase-2c projection tests.
- **`InspectWorkflow` tool (projected shape)** — `test/jido_claw/tools/inspect_workflow_test.exs`
  (mirrors `replay_workflow_test.exs`). This asserts the **post-projection** shape: direct `run/2`
  on a composer run returns atom-top-level keys with a **string-keyed** nested `composer` whose
  `reason`/markers are **strings** (`"not_yet_composed"`, not `:not_yet_composed` — the
  `JsonSafe.encode/1` atom→string flip the snapshot test deliberately does *not* see); a
  **non-composer run's output omits the `composer` key** (no present-with-nil); missing tenant →
  `{:error, %{code: :tenant_required}}`; unknown run → not-found; redaction pin (T2-2): a secret in
  the run `error` is redacted via the inherited operator-scope view. **Plus an execution-path test** —
  `Jido.Exec.run(JidoClaw.Tools.InspectWorkflow, %{run_id: id}, %{tool_context: %{tenant_id: t}},
  log_level: :error)` succeeds for **both** a composer run (with `composer` present) and a
  non-composer run (without it) — exercising `output_schema` validation on both the present and
  absent optional-`composer` shapes (would have caught both the P1 string-keyed-output bug and the
  present-with-nil bug).

---

## Precommit gotchas (per project memory)

- **`compile_check`**: warning-free (clean recompile, empty allowlist).
- **credo strict**: `@spec` on every public function in new modules; explicit-module `@impl`
  (`Jido.MCP.Server.Resource` / `Jido.Action`), not `@impl true`; proper `alias` usage; the
  **`EventPayload` extraction keeps the duplicate-code check green** — don't re-inline; avoid the
  ExSlop wrapped-comment-starting-with-"step" trap.
- **dialyzer**: accurate specs (`Observe.summarize/1 :: map() | nil`).
- **Not triggered** (so reviewers don't expect churn): no Ash resource changes (no AshCredo
  visibility, no `belongs_to_allow_nil` test); no `WorkflowsLive` changes (render-assigns triad
  untouched); no new `WorkflowEvent` kind / projection-status / migration; no `agent.ex` /
  `system_prompt.md` change (MCP-only).
- **Flaky-suite caveat**: `mcp_server_test.exs` is `async:false` and flakes under concurrent load —
  verify it **in isolation**; grep for any other `== 22` tool-count assertion the +1 breaks.

---

## Verification (end-to-end)

1. **Targeted tests** (`mise exec -- mix test <file>`): the 5 files above; run `mcp_server_test.exs`
   in isolation.
2. **Resource read via the running server** — `mise exec -- mix jidoclaw --mcp`; from an MCP client
   (or Tidewave `project_eval`) issue `resources/list` (expect `jido://workflows/catalog`) and
   `resources/read` on it (expect the `{"stages": {...}}` JSON).
3. **Tool read** — drive a composer to a wave (`FrontDoor.start_composer/2` on a `code` path in
   `project_eval`), then `Jido.Exec.run(JidoClaw.Tools.InspectWorkflow, %{run_id: id},
   %{tool_context: %{tenant_id: t}}, [])`: confirm atom-top-level output, the `composer` map shows
   route/waves/held/live, and a parked-gate run shows `awaiting_approval: true` while parent status
   stays `:running`; confirm a non-composer run has no `composer` key.
4. **`mix precommit` green** — the definition of done.

---

## Explicitly out of scope (not deferrals of Phase 5 work)

- **Web dashboard composer rendering** (`WorkflowsLive`) — per the user decision; future work.
- **Per-item `jido://workflows/<id>` resource URIs** — blocked on upstream RFC-6570 template
  support (§10.2 / §15.11); the single catalog resource is the complete Phase 5 deliverable.
- **Terminal disposition (`:rejected`/`:abandoned`) in the observe summary** — a `Visibility`
  operator-scope concern (its `result_summary` filter drops `disposition`), not the route view
  §10.2 defines; `status` already shows `:cancelled`.
- **Catalog YAML overlay** (§10.3) — the resource serves whatever `Catalog.all()` returns and would
  reflect an overlay automatically if/when that lands.
- **Cluster lease (Phase 6, §10.1)** — deferred until clustering is real.
