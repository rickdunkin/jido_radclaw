# Plan: Resolve the two /gql review findings (batch bypass + Phoenix label)

## Context

A code review of the argus P1 working diff reported two issues. Both are **verified
real** against source; this plan fixes both, regression-test-first. **Done means
`mix precommit` succeeds** (exact exit code + counts reported verbatim; the known
rotating-flake policy applies). Nothing gets committed.

### Verification of finding P1 — GraphQL transport batches bypass request-cost bounds: CONFIRMED

- The `/gql` forward pins `analyze_complexity: true, max_complexity: 200,
  token_limit: 5_000` (`lib/jido_claw/web/router.ex:85-91`) — but Absinthe.Plug
  natively parses **transport batches** and threads those limits into each batch
  element's own pipeline (`deps/absinthe_plug/lib/absinthe/plug/request.ex:75-91`,
  `request/query.ex`). The batch runner then always returns `{:ok, results}` → HTTP
  200 with a JSON list, element errors embedded (`deps/absinthe_plug/lib/absinthe/plug.ex:515-531`).
  So per-element enforcement holds but the **aggregate is unbounded**: N queries each
  under the limits ride one request, bounded only by `Plug.Parsers`' default 8 MB
  (`lib/jido_claw/web/endpoint.ex:32-37` sets no `:length`).
- **Three ingress vectors**, all live (endpoint parses `:json` and `:multipart`):
  1. POST JSON **array body** → `body_params["_json"]` list (`request.ex:60-62`);
  2. an **`operations` param** — query string or multipart field — converted to
     `_json` then JSON-decoded (`request.ex:125-131`);
  3. a **binary `_json` query param**, JSON-decoded by absinthe itself
     (`request.ex:139-141`).
  A guard on the array body alone would miss vectors 2–3.
- No legitimate consumer batches: `ui/` holds only the SDL golden (no Apollo client
  yet), GraphiQL posts single objects to `default_url: "/gql"`, and every route test
  posts single objects. **Decision: reject batching outright** (the reviewer's first
  option) — fail-closed, zero compat cost, no new config; an aggregate cap would add
  knob surface for zero users on a deliberately minimal read-only surface.

### Verification of finding P2 — Phoenix-only framework label breaks the JIDO.md round-trip: CONFIRMED

- `lib/jido_claw/platform/jido_md.ex:364` emits `"Phoenix "` (trailing space) when
  `phoenix` is a dep and `phoenix_live_view` is not; the render joins labels with
  `", "` (`jido_md.ex:452`); the checker's parser comma-splits and **trims** each
  label (`lib/jido_claw/platform/jido_md/check.ex:128-133`); and the check task
  derives the expected set from the same untrimmed `framework_names/1`
  (`lib/mix/tasks/jidoclaw.jido_md.check.ex:68`). Set comparison then reports BOTH
  `missing: Phoenix ` and `unexpected: Phoenix` — a freshly generated JIDO.md fails
  its own checker in any Phoenix-without-LiveView project.
- This repo has LiveView, so the committed `.jido/JIDO.md` is unaffected — no
  regeneration needed, `mix jidoclaw.jido_md.check` stays green.
- Existing tests cover only with-LiveView and dep-less scaffolds
  (`test/jido_claw/platform/jido_md_test.exs:69-103`) — the Phoenix-without-LiveView
  round-trip is exactly the missing case.

## Implementation steps

### Step 1 — P2: normalize the Phoenix label (regression tests first)

1. **Fixture correction first**: `generate_in/1` (`jido_md_test.exs:13-17`)
   unconditionally rewrites `mix.exs` with the dep-less scaffold — calling it after
   writing a Phoenix scaffold would erase the condition under test and false-green
   the round-trip. Extend it to `generate_in/2` with an optional `mix_exs` content
   arg **defaulting to the current dep-less scaffold string**, so every existing
   `generate_in(tmp_dir)` call site stays byte-identical; the helper writes the
   GIVEN scaffold, then generates and reads.
2. **Red tests** in `test/jido_claw/platform/jido_md_test.exs` (scaffold content per
   the existing detection-test pattern, `:69-92`):
   - `framework_names/1` describe: write a mix.exs with `{:phoenix, "~> 1.7"}` +
     `{:ecto_sql, "~> 3.13"}` and **no** `phoenix_live_view` directly (no generate
     involved, matching the sibling detection tests) →
     `framework_names(tmp_dir) == ["Phoenix", "Ecto"]` (red today: `"Phoenix "`).
   - Round-trip describe: `generate_in(tmp_dir, phoenix_scaffold)` — the scaffold
     rides through the helper and is never rewritten — then
     `Check.problems(content, opts) == []` with `framework_names:
     JidoMd.framework_names(tmp_dir)` derived after that write (red today: exactly
     the `missing: Phoenix ` + `unexpected: Phoenix` pair).
3. **Fix** `lib/jido_claw/platform/jido_md.ex:364`: build the label conditionally —
   `phoenix_label = if has_liveview, do: "Phoenix (with LiveView)", else: "Phoenix"`
   — and pass it to `maybe_add(has_phoenix, phoenix_label)`. No parser/renderer change.

### Step 2 — P1: reject transport batching (regression tests first)

1. **Red route tests** in `test/jido_claw/web/graphql_route_test.exs` (new section
   beside the pinned complexity/token tests, reusing `register_actor!`):
   - POST `/gql` with a JSON **array** body of 3 small queries (each individually
     under the limits) and a valid key → assert
     `json_response(conn, 400) == %{"error" => "batching_not_supported"}`.
     Red today: HTTP 200 with a JSON list.
   - GET `/gql?operations=<JSON-encoded 2-query batch>` with a valid key → 400 same
     envelope (covers the params vector end-to-end).
2. **New plug** `lib/jido_claw/web/plugs/graphql_batch_guard.ex`
   (`JidoClaw.Web.Plugs.GraphqlBatchGuard`, conventions per `GraphqlTenantGate`/
   `GraphiqlGuard`: `@behaviour Plug`, moduledoc stating the three vectors):
   - `call/2`: `fetch_query_params(conn)`, then halt
     `400 {"error": "batching_not_supported"}` (flat JSON, tenant-gate style) when
     `"_json"` **or** `"operations"` is present as a key in `conn.params` or
     `conn.body_params` (guard clause passes `%Plug.Conn.Unfetched{}` through as
     no-keys). **Presence-based, value-type-blind** — a list, a binary absinthe would
     later decode, or junk all halt, so the guard never replicates absinthe's decode
     and fails closed. Legitimate single requests (`query`/`variables`/
     `operationName`, or GET `?query=`) never carry either key.
   - Keep the halt inline in the plug (single call site) — a third sibling
     `halt_with/3` risks the ExSlop clone gate.
3. **Plug unit test** `test/jido_claw/web/plugs/graphql_batch_guard_test.exs`
   (the `GraphiqlGuardTest` `Plug.Test.conn` + direct `call/2` pattern): pass-through
   for a plain POST-with-query-body-params conn, a GET `?query=` conn, and an
   Unfetched-body conn; halts (400 + envelope + `conn.halted`) for `_json`-list body
   params, `_json`-binary query param, `operations` query param, `operations` body
   param (multipart shape).
4. **Router** `lib/jido_claw/web/router.ex`: `:graphql` pipeline becomes
   `GraphqlBatchGuard` → `GraphqlTenantGate` → `AshGraphql.Plug` (reject batches
   before the gate's DB activity check); update the pipeline comment (`:15-18`) and
   the `/gql` scope comment (`:73-77`) to name batching among the pinned controls.

No SDL change (transport-level only) — `mix jidoclaw.graphql.schema.check` untouched.

### Step 3 — docs (same change, machine-enforced pairing)

- `docs/system/graphql-surface.md`: frontmatter `sources:` + Source map gain the new
  plug and test; **Invariants** gains a "no transport batching" bullet (the three
  vectors, presence-based fail-closed rejection, 400 envelope, rationale: per-element
  limits made the aggregate unbounded); the pipeline-order bullet updates to the
  three-plug order; **Config & telemetry** notes the batch rejection beside the
  complexity/token rationale. `verified: 2026-07-11` already current.
- `AGENTS.md` GraphQL Read Surface bullet: update the pipeline description
  (`GraphqlBatchGuard` then `GraphqlTenantGate` then `AshGraphql.Plug`) + a clause
  that transport batching is rejected (aggregate-cost bypass). Keep pointing at the
  page (`mix jidoclaw.system_docs.check` enforces both directions).
- `docs/plans/argus-ui-bootstrap/README.md` `## Deviations` (:288): one entry per
  finding — review-driven corrections to plan-delivered work (batch guard added to
  the pinned controls; Frameworks label normalized), house style.

## Verification

1. Red→green per step: run the new test files before each fix (expect the exact reds
   above), then after (green) — never weaken an assertion.
2. Full suite sanity: `mix test test/jido_claw/web/graphql_route_test.exs
   test/jido_claw/web/plugs/ test/jido_claw/platform/` for the touched surfaces.
3. `mix precommit` — the full gate (format, compile_check, credo/reach strict zero,
   partitioned suite, schema/system_docs/jido_md/system_prompt checks). Run bare
   (never piped), report exact exit code and counts verbatim. One unrelated
   rotating-flake timing test ⇒ single re-run per the known policy; the same test
   failing twice is treated as real.

## Files touched

- `lib/jido_claw/platform/jido_md.ex` (label fix)
- `test/jido_claw/platform/jido_md_test.exs` (2 regression tests)
- `lib/jido_claw/web/plugs/graphql_batch_guard.ex` (new)
- `test/jido_claw/web/plugs/graphql_batch_guard_test.exs` (new)
- `lib/jido_claw/web/router.ex` (pipeline + comments)
- `test/jido_claw/web/graphql_route_test.exs` (2 regression tests)
- `docs/system/graphql-surface.md`, `AGENTS.md`,
  `docs/plans/argus-ui-bootstrap/README.md` (docs pairing + deviations log)
