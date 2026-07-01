# Plan: Per-`<id>` MCP workflow resources (`jido://workflows/<stage>`)

*Design direction + phased adoption — not a commitment. Closes G2-1(b), the last
open tail of "MCP as a workflow-control surface."*

Land per-`<id>` MCP resources so an MCP client can read **one** composer-stage
definition by URI (`jido://workflows/triage`), a drill-down on the existing
`jido://workflows/catalog` resource. This is the sibling of G2-1(a), the
`workflow_events` tool (shipped) — both were the "narrower tail still open" on
G2-1 per
[`../../exploration/gust/FEATURES-WORTH-BORROWING.md`](../../exploration/gust/FEATURES-WORTH-BORROWING.md).

This doc is the deliverable that scoped G2-1(b) out of the G2-1(a) plan: (b)'s
mechanism carries **dep-integration risk that cannot be settled while planning**
(a novel `component` registration inside a `use Jido.MCP.Server` module), so it
gets a compile-time + live-read **Phase 0 spike** with an explicit gate. No (b)
code lands until that spike is green.

---

## Context & goal

`jido://workflows/catalog`
(`lib/jido_claw/core/mcp_server/resources/workflow_catalog.ex`) already serves the
**whole** route-composer catalog — every composable stage's unit / routes /
inputs-outputs / subscribes-publishes / locks — as `application/json`. It is a
single fixed-URI resource: a client can list the composable surface but cannot
address one stage.

**Goal:** add `jido://workflows/<stage_name>` — read ONE composer-stage
definition by id:

```
Catalog.get(name) |> Stage.to_map/1   # → {:ok, %{"stage" => stage_map}}
Catalog.get(unknown)                  # → {:error, :not_found}
```

reusing the exact serialization the catalog resource and the durable
parent-config already use (`Stage.to_map/1`, `lib/jido_claw/route_composer/stage.ex`).

### What `<id>` is

`<id>` identifies a **composer stage** — a `RouteComposer.Catalog` entry, e.g.
`triage`, `planner`, `implementer`, `plan-gate`. The id space is **finite,
compile-time, and stable**:

- `JidoClaw.RouteComposer.Catalog.names/0` — every stage name.
- `JidoClaw.RouteComposer.Catalog.get/1` — the `%Stage{}` or `nil`.
- `JidoClaw.RouteComposer.Catalog.valid?/1` — membership.

(The catalog validates at compile time — `CatalogValidator.validate/1` must return
`[]` or the build fails — so `<id>` never points at an incoherent stage.)

This is deliberately **not** a run-id resource (runs are addressed by the
`workflow_status` / `inspect_workflow` / `workflow_events` tools, which are
tenant-scoped; the catalog is global, static, tenant-independent config).

---

## Mechanism findings (the risk)

The naive read — "publish a templated resource" — does not exist in jido_mcp.
The findings below are what turns this from a one-liner into a spike.

### jido_mcp cannot express a resource template

- Its `publish` DSL normalizes only `tools` / `resources` / `prompts`
  (`deps/jido_mcp/lib/jido_mcp/server.ex:66-68`) — **no `resource_templates`
  key**.
- Its `Jido.MCP.Server.Resource` behaviour is **fixed-`uri/0` only**
  (`deps/jido_mcp/lib/jido_mcp/server/resource.ex`) — no `uri_template/0`.
- Its generated read bridge does **exact-URI matching**; a `jido://workflows/<x>`
  URI would never match a fixed `uri/0`.

### anubis_mcp supports templates natively — and bypasses jido_mcp's bridge

anubis (the transport/protocol layer jido_mcp sits on) already has the whole
template machinery:

- An `Anubis.Server.Component` with `type: :resource, uri_template:
  "…/{name}"` (`deps/anubis_mcp/lib/anubis/server/component/resource.ex:47-53`)
  is a template resource. RFC-6570 Level 1 (`{var}`) expansion
  (`component/resource.ex:66`); a component implements **`uri_template/0` XOR
  `uri/0`, never both** (`component/resource.ex:138`).
- It is listed by `resources/templates/list`
  (`deps/anubis_mcp/lib/anubis/server/handlers/resources.ex:31-34`, via
  `get_server_resource_templates/2`) — **NOT** `resources/list`, and **NOT**
  `MCPServer.__publish__().resources` (component templates never appear there —
  a test trap, see Phase 3).
- On `resources/read`, anubis matches **static resources first**
  (`resources.ex:53`, `find_static_resource/2` = exact `&(&1.uri == uri)`), then
  falls through to `try_resource_templates/5` (`resources.ex:60`), which
  `URITemplate.match`es each template (`resources.ex:122,146`) and routes a hit
  **directly** to the component module's `read/2` via the `%Resource{handler:
  mod}` clause (`resources.ex:189`), passing the parsed vars as `%{"params" =>
  %{"name" => …}}`. This path **bypasses jido_mcp's exact-URI bridge entirely.**

Two consequences:

1. **The existing catalog resource is unaffected** — it is a static resource,
   matched before templates, so `jido://workflows/catalog` keeps reading exactly
   as today (the template only catches URIs the static match misses).
2. **The chosen approach needs no dep patch** — anubis already routes template
   reads to the component's `read/2`.

### Chosen approach + residual risk

**Add an anubis `component` template resource inside `JidoClaw.MCPServer`
(`use Jido.MCP.Server`), no dep patch.**

The **residual risk** — the reason this is a spike, not a task — is novel:
`JidoClaw.MCPServer` is a `use Jido.MCP.Server` module, and it is **unverified
whether that macro layer surfaces an anubis `component`** (i.e. whether the
module's `__components__/1` includes a `component`-declared resource and whether
`get_server_resource_templates/2` therefore sees it) when the server is driven
through jido_mcp's generated `init/2` / handshake rather than a bare
`use Anubis.Server`. jido_mcp's generated `init/2` + `handle_resource_read/2` are
**not `defoverridable`** (only `authorize/2` is), so we cannot lean on overriding
them — we are relying purely on anubis's own template routing firing underneath.
That is exactly what Phase 0 proves or disproves against a live handshake.

---

## Phased outline

### Phase 0 — Spike (the gate)

Add a **minimal** `component`-based template resource to `JidoClaw.MCPServer`
(e.g. `uri_template: "jido://workflows/{name}"`, a trivial `read/2` returning a
constant map). Prove, via a **live MCP handshake test** (the existing
`mcp_server_test.exs` / handshake harness):

1. it **compiles** inside a `use Jido.MCP.Server` module;
2. it **appears** in `resources/templates/list` (equivalently
   `MCPServer.__components__(:resource)` carries it);
3. `resources/read jido://workflows/triage` **routes to `read/2`** with the parsed
   `name` (`%{"params" => %{"name" => "triage"}}`);
4. `resources/read jido://workflows/catalog` **still reads the static catalog
   correctly** (static-before-template ordering holds end-to-end).

**Gate: any of (1)–(4) failing → go to Phase 2.** All green → Phase 1.

### Phase 1 — Implement (spike green)

Flesh out the template resource's `read/2`:

```elixir
def read(%{"params" => %{"name" => name}}, frame) do
  case Catalog.get(name) do
    %Stage{} = stage ->
      {:reply, Response.json(Response.resource(), %{"stage" => Stage.to_map(stage)}), frame}

    nil ->
      {:error, Error.resource(:not_found, %{uri: "jido://workflows/#{name}"}), frame}
  end
end
```

(Exact `Response` / `Error` construction to be confirmed against what Phase 0's
live read accepts — anubis `component` resources return a `{:reply, %Response{},
frame}` triple, unlike the static catalog resource, whose bare `{:ok, map}` is
auto-`Response.json`-wrapped by jido_mcp's runtime.) Register it on the server
alongside the static catalog resource. Payload shape mirrors the catalog's
`Stage.to_map/1` output so the drill-down is byte-identical to one entry of the
catalog's `stages` map.

### Phase 2 — Contingency (spike red)

Patch a dep, **preferring jido_mcp over anubis** (anubis already has the template
routing/matching machinery — the gap is only jido_mcp's *registration* layer):

- **First choice:** add `resource_templates` support to jido_mcp's `publish` DSL
  (`deps/jido_mcp/lib/jido_mcp/server.ex`) + a
  `Runtime.register_resource_template`, delegating to anubis's
  `Frame.register_resource_template/3` and the existing template read path. This
  is additive and small.
- **Only if that proves infeasible:** patch `Anubis.Server.Handlers.Resources`
  (the sibling of the already-patched `Anubis.Server.Handlers.Tools`).

Register whichever patch via `@patched_modules` in
`lib/jido_claw/core/dependency_patches.ex` (precedent: `{Anubis.Server.Handlers.Tools,
:anubis_mcp}` + `lib/jido_claw/core/anubis_tools_handler_patch.ex`).

### Phase 3 — Tests + precommit + docs

- **Unit:** known stage (`jido://workflows/triage` → its `Stage.to_map/1`),
  unknown stage → `:not_found`, and the static `jido://workflows/catalog` still
  reads.
- **Registration assertion — the trap:** assert via a **live
  `resources/templates/list`** and/or **`MCPServer.__components__(:resource)`**,
  **NOT** `MCPServer.__publish__().resources` (component templates never appear
  in the publish list — asserting there is a false green).
- Update the AGENTS.md **Exposed resources** line (add `jido://workflows/<stage>`
  next to the catalog resource).
- Flip the G2-1(b) status in
  [`../../exploration/gust/FEATURES-WORTH-BORROWING.md`](../../exploration/gust/FEATURES-WORTH-BORROWING.md)
  (the "Status of the two tails" paragraph + the MCP comparison-table row) from
  "design-doc'd" to shipped.
- `mix precommit` green (mirror the new-code snags the G2-1(a) verification hit:
  `@moduledoc` + `@spec`s + credo strict + ExSlop step-comment trap).

---

## Follow-on questions (record, don't implement)

- **A `skill` id namespace** — optionally add `jido://workflows/skill/<name>` (or
  a second template) later to read a user-authored skill definition, not just a
  composer stage.
- **Enumerate concrete stage resources** — optionally also list every stage as a
  concrete resource in `resources/list` (in addition to the template in
  `resources/templates/list`), so a client that does not expand templates still
  sees the finite id set. Cheap given `Catalog.names/0`; deferred because the
  template + catalog resource already cover discovery.

---

## Files touched (when (b) lands — none in this doc's plan)

- `lib/jido_claw/core/mcp_server.ex` — register the template resource (and, in
  Phase 2 only, a `resource_templates:` publish key).
- `lib/jido_claw/core/mcp_server/resources/workflow_stage.ex` — **new** template
  resource (`component`, `uri_template: "jido://workflows/{name}"`).
- (Phase 2 only) `deps`-mirroring patch module + `dependency_patches.ex`
  registration.
- `test/jido_claw/mcp_server_test.exs` (or a new resources test) — templates-list
  + read + catalog-still-reads.
- `AGENTS.md`, `docs/exploration/gust/FEATURES-WORTH-BORROWING.md` — resource line
  + G2-1(b) status.
