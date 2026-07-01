# Implement G2-1 — MCP as a workflow-control surface (close the two open tails)

## Context

`docs/exploration/gust/FEATURES-WORTH-BORROWING.md` records **G2-1 (MCP as a
workflow-control surface)** as *largely shipped* — `run_skill`, `workflow_status`,
`inspect_workflow`, `replay_workflow`, and the `jido://workflows/catalog` resource
all exist. Two narrow items remain open (per the 2026-07-01 status):

- **(a) Per-run raw logs/events over MCP** — there is no `get_logs_on_task`
  analogue. `inspect_workflow` returns a *derived* composer summary, never the raw
  `WorkflowEvent` feed for a run.
- **(b) Per-`<id>` resources `jido://workflows/<id>`** — only the single fixed
  catalog resource exists; jido_mcp's `publish` DSL has no `resource_templates` key.

**Goal:** close (a) with a new MCP tool, and close (b) via a dedicated phased
design doc (its mechanism carries dep-integration risk that must be validated by a
compile-time + live-read spike, which cannot be settled while planning).

**Decisions already made (with the user):**
- **(a)** is implemented now, fully, precommit-green.
- **(b)** is scoped into its **own phased design doc**; this plan authors that doc
  but does not write (b)'s code.
- For **(b)**, `<id>` identifies a **composer stage** (a `RouteComposer.Catalog`
  entry, e.g. `triage`, `planner`) — a drill-down on the catalog resource.

### Output-size reality (corrects an earlier assumption)

A raw event feed can be large, and **the tool must bound its own output** — the
shared wrapper does NOT cap the whole result:

- `Tools.OutputLimit.truncate/2` (`lib/jido_claw/tools/output_limit.ex:16-43`)
  recurses into maps/lists and truncates only **individual binary leaves** over
  32 KB. A list of many events is never capped as a whole.
- `Tools.OutputShaper` is **not** engaged: `shapeable?/3`
  (`output_shaper.ex:193`) allowlists only `run_command`/`git_diff`, and the
  generic path is `mcp_*`-only — `workflow_events` matches neither.
- Append-time capping is explicitly **per-leaf, not a whole-payload budget**
  (`workflow_event/changes/allocate.ex:122-129`; leaf cap 64 KB), and payloads are
  "single-large-LLM-text leaves."

∴ **Part A implements byte-aware pagination** (a per-page serialized-size budget +
a per-event fit/truncate step + a count cap + a seq cursor) so both the whole page
AND every individual event are bounded — for the direct `WorkflowView.event_feed/3`
API as well as through the tool. This is the load-bearing correctness requirement,
not a nicety; it does not lean on `OutputLimit` (which only trims per-leaf).

The plan is **not complete until `mix precommit` passes.** Nothing is committed;
all changes stay unstaged.

---

## Part A — `workflow_events` MCP tool (the `get_logs_on_task` analogue)

A new MCP-only read tool returning a run's raw `WorkflowEvent` feed
(seq / kind / occurred_at / payload / metadata), **byte-bounded and seq-paginated**.
It mirrors `inspect_workflow` for tenant-scoping and projection discipline; the
query reuses the existing `WorkflowEvent.for_run/2` code interface.

### A1. Add `WorkflowView.event_feed/3`
**File:** `lib/jido_claw/workflow_view.ex` (already `require`s/`alias`es `Ash.Query`,
`Actor`, `JsonSafe`, `WorkflowEvent`, `WorkflowRun`; add an alias for
`JidoClaw.Orchestration.Replay.EventReader`). Add module attrs:
`@event_feed_default_limit 50`, `@event_feed_max_limit 200`,
`@event_feed_byte_budget 24 * 1024` (all tunable; the byte budget is the real
bound, the count cap is a memory/fetch pre-bound).

```elixir
@spec event_feed(String.t(), map() | keyword(), map() | keyword()) ::
        {:ok, map()} | {:error, :tenant_required | :not_found | :event_feed_unavailable}
def event_feed(run_id, scope_or_opts, opts \\ []) when is_binary(run_id) do
  with {:ok, scope} <- JidoClaw.RuntimeScope.require_tenant(scope_or_opts, scope_keys()) do
    tenant_id = Keyword.fetch!(scope, :tenant_id)
    actor = Keyword.get(scope, :actor) || Actor.system(tenant_id)
    opts = Enum.to_list(opts)          # normalize: keyword OR ATOM-keyed map (string keys out of contract; @doc says so)

    case WorkflowRun.by_id(run_id, tenant: tenant_id, actor: actor) do
      {:ok, %WorkflowRun{} = run} -> read_event_feed(run, tenant_id, actor, opts)
      _ -> {:error, :not_found}        # nil OR {:error,_} → clean not_found (snapshot/2 pattern)
    end
  end
end
```

`read_event_feed/4`:
- `count_cap = clamp(opts[:limit], 1, @event_feed_max_limit, default @event_feed_default_limit)`;
  `after_seq = non-neg-int-or-nil(opts[:after_seq])`.
- Fetch candidates through the **neutral swappable seam**
  `Replay.EventReader.for_run/2` (default `&WorkflowEvent.for_run/2`; overridable via
  `config :jido_claw, :replay_event_reader`) — so the impl path and the failure-test
  path are the SAME seam. Ash guidance: prefer the `query:` option over a manual
  `Ash.Query`; `for_run` already sorts `seq: :asc`:
  ```elixir
  q = [limit: count_cap + 1]          # +1 sentinel: detect "has more" without the boundary bug
  q = if after_seq, do: [filter: [seq: [greater_than: after_seq]]] ++ q, else: q
  EventReader.for_run(run.id, query: q, tenant: tenant_id, actor: actor)
  ```
  (Extend `EventReader`'s **contract**, not just prose: its `@doc`/`@spec` must state
  a swapped reader MUST honor `query:` opts — `limit`/`filter`/`sort` — or
  `event_feed/3` pagination silently breaks; the default `&WorkflowEvent.for_run/2`
  already honors them. Also name `event_feed/3` as a third consumer.)
- **On `{:error, _}` (run already confirmed to exist) → `{:error, :event_feed_unavailable}`**
  — do NOT collapse a read failure to an empty feed (a diagnostic tool; an empty
  list is a misleading false negative). (Contrast `read_runs/5`, a best-effort
  dashboard rollup that swallows errors.)
- On `{:ok, rows}`:
  - `sentinel? = length(rows) > count_cap`; `bounded = Enum.take(rows, count_cap)`.
  - `projected = Enum.map(bounded, &(&1 |> event_to_map() |> fit_event(@event_feed_byte_budget)))`.
    **`fit_event/2` bounds EACH event**: if its JSON size exceeds the budget, replace
    the oversized `payload`/`metadata` with a bounded marker map
    (`%{"truncated" => true, "preview" => <utf8-safe JSON prefix>, "bytes" => <orig
    size>}`) and stamp `"truncated" => true` on the event. This makes the feed
    self-bounding for **every** caller (direct API included), and closes the
    multi-leaf case `OutputLimit`'s per-leaf 32 KB trim misses.
  - `page = byte_fold(projected, @event_feed_byte_budget)` — a `reduce_while`
    accumulating JSON size, halting before it would exceed budget, always keeping
    ≥1 event. **Account for the serialized LIST, not just the sum of events:** seed
    the running total with the `[]` framing and add a `,` separator per extra event,
    so it is the actual page bytes that are bounded. `fit_event` targets the budget
    minus that framing reserve, so even a lone fitted event's serialized page stays
    ≤ budget — with **no reliance on `OutputLimit`** (that stays belt-and-suspenders).
  - `has_more? = sentinel? or length(page) < length(projected)`.
  - `next_seq = if has_more?, do: page |> List.last() |> Map.get("seq"), else: nil`.
  - `{:ok, %{run_id: run.id, run_status: run.status, count: length(page),
    events: page, next_seq: next_seq}}`.
- `event_to_map/1` → **string-keyed** `%{"seq" | "kind"(to_string) |
  "occurred_at"(JsonSafe) | "payload"(JsonSafe) | "metadata"(JsonSafe)}`.

### A2. Add the tool module
**New file:** `lib/jido_claw/tools/workflow_events.ex` — copy the *shape* of
`lib/jido_claw/tools/inspect_workflow.ex`:

- `use JidoClaw.Tools.Action, name: "workflow_events", category: "introspection",
  tags: ["workflow", "read"], description: <discover → page loop>` — the wrapper
  gives redaction / MCP-scope / approval-gate / `Error.normalize_result` for free.
- **`schema`** (input): `run_id` (`:string`, required); `after_seq` (`:integer`,
  optional — return events with `seq > after_seq`; pass back the previous
  `next_seq`); `limit` (`:integer`, optional — page target, default 50, capped 200,
  but pages are additionally byte-bounded, so a page may be smaller).
- **`output_schema`**: declare **only** type-stable atom-keyed scalars — `run_id`
  (req string), `run_status` (opt string), `count` (req integer), `next_seq` (opt
  integer). **Do NOT declare `events`** — `{:list, :map}` demands atom keys and
  NimbleOptions `:map` = `{:map, :atom, :any}` rejects the string-keyed JsonSafe'd
  event maps; it passes through as an unvalidated extra key (the `composer`
  precedent, confirmed allowed by `jido_action`). **Never** use the key `status`
  (the wrapper's `Error.normalize_result/1` promotes `{:ok, %{status: "failed"}}`
  to an error) — use `run_status`.
- **`run/2`** (`@impl Jido.Action`): read tenant from
  `context.tool_context.tenant_id` (binary & non-empty, else `{:error,
  :tenant_required}`); build **keyword** opts
  (`params |> Map.take([:after_seq, :limit]) |> Map.to_list()`) and call
  `WorkflowView.event_feed/3` (which also normalizes map/keyword defensively);
  project the `{:ok, feed}` to atom-top-level (`run_id`, `count`, `events`) with
  `put_present/3` for optional `run_status`/`next_seq` (copy `put_present/3` +
  `stringify_nilable/1` verbatim from `inspect_workflow.ex`); relay `{:error, _}`.

Moduledoc must state: MCP-only surface; tenant-from-context; the feed is
byte-paginated (payloads redacted at append, leaf-capped by the wrapper) and a
read failure surfaces as `:event_feed_unavailable`, never an empty page.

### A3. Register + confirm MCP-only surface
**File:** `lib/jido_claw/core/mcp_server.ex` — add `JidoClaw.Tools.WorkflowEvents`
to the `publish.tools` list (near `WorkflowStatus`/`InspectWorkflow`) with an
"MCP-only" comment mirroring the existing markers. **Do NOT** add it to
`lib/jido_claw/agent/agent.ex` — omission from that list is how "MCP-only" is
enforced. `published_tool_modules/0` picks it up automatically (marker sweeps cover
it).

### A4. Tests
**New file:** `test/jido_claw/tools/workflow_events_test.exs` — mirror
`test/jido_claw/tools/inspect_workflow_test.exs` (`use JidoClaw.TenantCase,
async: false`; `seed_tenant/1`; `actor_for/1`; `WorkflowRun.create/2`;
`WorkflowLog.append/4`; `tool_ctx(%{tenant: t}) => %{tool_context: %{tenant_id: t}}`).
Cover:
- happy path: appended events return **seq-ascending**, atom top-level keys,
  string-keyed nested event maps, `count` correct.
- pagination by count: `after_seq` skips consumed events; a full page sets a
  non-nil `next_seq`; the final partial page sets `next_seq: nil`.
- **exact-boundary correctness (the +1 sentinel):** with exactly `limit` events and
  none beyond, `next_seq` is `nil` (not a phantom page).
- `{:error, %{code: :tenant_required}}` with no tenant in `tool_context` (assert the
  normalized `%{code: …}` wire shape).
- `{:error, %{code: :not_found}}` for an unknown run id; **cross-tenant isolation:**
  a run seeded in tenant A is `:not_found` under a tenant-B context.
- redaction pin: append an event whose payload embeds `"sk-" <>
  String.duplicate("z", 24)`; assert `refute Jason.encode!(output) =~ secret`.
- full `Jido.Exec.run(WorkflowEvents, …)` path so `output_schema` validation is
  exercised (the `events` extra-key pass-through must survive).

**Extend** `test/jido_claw/workflow_view_test.exs` (exists) with an
`event_feed/3` describe:
- **opts accepted as a keyword list AND an atom-keyed map** (contract is atom-keyed;
  the direct map-opts test the reviewer asked for).
- **page-level byte budget:** append several ~20 KB-payload events; assert the
  returned `count` is below the requested `limit` and `next_seq` is set (byte-trimmed,
  not count-trimmed).
- **single oversized event is fit, not dropped:** one event with a payload larger
  than the budget → exactly 1 returned event with `"truncated" => true`, its
  `payload` a bounded marker map, and the JSON-encoded event ≤ budget.
- **event-read failure → `{:error, :event_feed_unavailable}`:** set
  `:replay_event_reader` to a stub returning `{:error, :boom}` (the impl reads
  through that seam), assert the tuple; through the tool, assert
  `%{code: :event_feed_unavailable}`.
- unknown run id / cross-tenant → `:not_found`.

**Update** `test/jido_claw/mcp_server_test.exs` —
- line ~68: `test "publishes 23 tools"` → **24** (title + `Enum.count(...) == 24`).
- add `test "includes the workflow event-feed tool (MCP-only surface)"` asserting
  `JidoClaw.Tools.WorkflowEvents in MCPServer.__publish__().tools`.

Marker-sweep suites (`tools/output_redaction_test.exs`,
`tools/real_tree_capability_test.exs`, `security/tool_approval_test.exs`) iterate the
published set and should pass unchanged (the tool uses the wrapper) — run to confirm,
don't pre-edit.

### A5. Doc / count updates
- `AGENTS.md`: bump "**23 tools**" → **24** (lines 38 and 89) and append
  `workflow_events` to the **Exposed tools** list (after `replay_workflow`; note it,
  like `inspect_workflow`, is not on the in-REPL agent). The architecture "~32 tools"
  REPL count is unrelated and unaffected (MCP-only tool).
- `docs/exploration/gust/FEATURES-WORTH-BORROWING.md` (already modified in-tree):
  mark G2-1 open item **(a) shipped** (`workflow_events`, byte-paginated) and note
  **(b)** is scoped into its own design doc (link it); update the "MCP" comparison row.
- Safety sweep: `grep -rn "23 " AGENTS.md docs lib` for any other stale count.

---

## Part B — Author the per-`<id>` resource design doc (no (b) code in this plan)

**New file:** `docs/plans/mcp-workflow-resources/README.md` (following the
`docs/plans/clustering/` precedent). It is the deliverable; (b)'s code lands in the
follow-up it defines. Content:

**Context & goal.** `jido://workflows/<stage_name>` — read ONE composer-stage
definition by id (`Catalog.get(name) |> Stage.to_map/1`), a drill-down on
`jido://workflows/catalog`. `<id>` = a `RouteComposer.Catalog` stage name (finite,
compile-time, stable — `catalog.ex` `names/0`/`get/1`).

**Mechanism findings (the risk).**
- jido_mcp `publish` DSL has **no** `resource_templates` key
  (`deps/jido_mcp/.../server.ex:65-69`); its `Resource` behaviour is fixed-`uri/0`
  only; its generated `init/2` + `handle_resource_read/2` are **not**
  `defoverridable` (only `authorize/2` — `server.ex:160`); its read bridge does
  exact-URI matching.
- **anubis_mcp supports templates natively:** an `Anubis.Server.Component`
  (`type: :resource, uri_template: "…/{name}"`, `component/resource.ex:43-64`) is
  discovered via `module.__components__()`, listed by `resources/templates/list`,
  and its `read/2` is routed **directly by anubis** (the `handler: mod` clause,
  `handlers/resources.ex:189-202`) with parsed vars as `%{"params" => %{"name" =>
  …}}` — **bypassing jido_mcp's bridge**. Static resources are matched **before**
  templates (`resources.ex:53`), so the existing fixed-URI catalog is unaffected.
- ∴ **chosen approach: an anubis `component` template resource inside
  `JidoClaw.MCPServer` — no dep patch.** The residual risk (novel: a `component`
  in a `use Jido.MCP.Server` module) is exactly what Phase 0 spikes.

**Phased outline (the doc's own phases):**
- **Phase 0 — Spike.** Add a minimal `component`-based template resource; confirm it
  (1) compiles inside `JidoClaw.MCPServer`, (2) appears in `resources/templates/list`,
  (3) routes `resources/read jido://workflows/triage` to `read/2` with the parsed
  `name`, and (4) leaves `jido://workflows/catalog` reading correctly — via a live
  MCP handshake test. **Gate:** any failure → Phase 2.
- **Phase 1 — Implement (spike green).** Template resource `read/2` →
  `Catalog.get(name)` → `{:reply, Response.json(Response.resource(),
  %{"stage" => Stage.to_map(stage)}), frame}`; unknown name →
  `{:error, Error.resource(:not_found, …), frame}`. Register on the server.
- **Phase 2 — Contingency (spike red).** Dep patch, **preferring jido_mcp over
  anubis** (anubis already has the template routing/matching machinery, so the gap
  is only jido_mcp's registration layer): add `resource_templates` support to
  jido_mcp's `publish`/`Runtime.register_resource_template` (delegating to anubis's
  `Frame.register_resource_template/3` + existing `handle_read` template path).
  Only if that proves infeasible, patch `Anubis.Server.Handlers.Resources` (sibling
  of the already-patched `Anubis.Server.Handlers.Tools`). Register via
  `@patched_modules` in `dependency_patches.ex` (precedent:
  `anubis_tools_handler_patch.ex`).
- **Phase 3 — Tests + precommit + docs.** Unit (known/unknown stage; catalog still
  reads). **Assert registration via a live `resources/templates/list` and/or
  `MCPServer.__components__(:resource)` — NOT `MCPServer.__publish__().resources`**
  (component templates never appear there). Update AGENTS.md resources line; flip the
  G2-1 (b) status in `FEATURES-WORTH-BORROWING.md`. `mix precommit` green.
- **Follow-on questions to record:** optionally add a `skill` id namespace later;
  optionally also enumerate concrete stage resources in `resources/list`.

---

## Verification (run via `mise exec -- mix`)

1. `mise exec -- mix format`
2. Targeted tests first:
   `mise exec -- mix test test/jido_claw/tools/workflow_events_test.exs test/jido_claw/workflow_view_test.exs test/jido_claw/mcp_server_test.exs`
   then marker sweeps:
   `mise exec -- mix test test/jido_claw/tools/output_redaction_test.exs test/jido_claw/tools/real_tree_capability_test.exs test/jido_claw/security/tool_approval_test.exs`
3. Live sanity via Tidewave `project_eval` (optional): seed a tenant + run + several
   `WorkflowLog.append/4` events (mix small and ~20 KB payloads), then call
   `JidoClaw.Tools.WorkflowEvents.run(%{run_id: id, limit: 5}, %{tool_context:
   %{tenant_id: t}})` and confirm the page is byte-bounded and `next_seq` advances.
4. **Gate:** run `mise exec -- mix precommit` **bare, in the background**, then read
   the output tail (never pipe through `tail` — that masks the exit code). Fix until
   green. Known new-code snags (mirror `inspect_workflow.ex`, which passes):
   `@moduledoc` + `@impl Jido.Action` + `@spec`s (credo strict Specs/ImplTrue),
   alias usage, and avoid comment lines beginning with the word "step" (ExSlop
   EXS3004).

## Files touched

**Implement (Part A):**
- `lib/jido_claw/workflow_view.ex` — add `event_feed/3` (+ `read_event_feed`,
  `event_to_map`, `fit_event`, `byte_fold` helpers; reads via the
  `Replay.EventReader` seam using `for_run`'s `query:` option).
- `lib/jido_claw/orchestration/replay/event_reader.ex` — contract update: `@doc`/
  `@spec` states swapped readers must honor `query:` opts (limit/filter/sort); name
  `event_feed/3` as a third consumer.
- `lib/jido_claw/tools/workflow_events.ex` — **new** tool (mirrors `inspect_workflow`).
- `lib/jido_claw/core/mcp_server.ex` — add to `publish.tools`.
- `test/jido_claw/tools/workflow_events_test.exs` — **new**.
- `test/jido_claw/workflow_view_test.exs` — add `event_feed/3` describe.
- `test/jido_claw/mcp_server_test.exs` — 23→24 + surface test.
- `AGENTS.md`, `docs/exploration/gust/FEATURES-WORTH-BORROWING.md` — counts + G2-1 status.

**Author (Part B):**
- `docs/plans/mcp-workflow-resources/README.md` — **new** phased design doc for the
  per-stage resource (no (b) code in this plan).

## Suggested commit (do NOT run — left for the user)

`feat: add workflow_events MCP tool (G2-1a) + design doc for per-stage resources (G2-1b)`
