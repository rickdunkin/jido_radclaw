# Unadopted Jidoka Ideas — Standing & Triggers

Companion to [`FEATURES-WORTH-BORROWING.md`](FEATURES-WORTH-BORROWING.md) and [`FEATURES-WORTH-BORROWING-V2.md`](FEATURES-WORTH-BORROWING-V2.md). Those two are the inventory and adoption record; this doc rolls up only the **live remainder** — ideas jidoka surfaced that were never implemented here and were *deferred or put on watch*, not rejected. For each: where it stands in the code today, whether it's worth adopting now, and the trigger that would change that verdict. Entries the inventories closed as SUPERSEDED / N/A with no deferral are not repeated here — they're settled.

Compiled **2026-07-02**, against jidoka `9469dc09` (2026-06-17, `0.8.0-beta.1`) and the same-day reconcile of the two inventories. Verdicts are weighted by the project threat model (LLM-misbehavior containment and leakage hygiene over external-attacker hardening; personal tailnet deployment). Ordered by trigger proximity — nearest first.

| # | Idea | Source entry | Adopt now? | Trigger distance |
| --- | --- | --- | --- | --- |
| 1 | Deterministic eval harness | V2-5 | ✅ Adopted 2026-07-03 | Trigger fired (unadopted-next-five items 3+4 rewrote the doctrine surface); shipped as `JidoClaw.Eval` |
| 2 | LLM-authored bounded plans (`compose_skill`) | V2-7 | No — watch | AR-2 built the substrate; authorship posture change still unjustified |
| 3 | Cron async dispatch + stuck watchdog | V1 T2-5 note | No | First stuck job, or long agent turns on cron becoming routine |
| 4 | Per-tool MCP approval overlay | V2-2 deferral | No | A server mixing benign + dangerous tools that one template needs both of |
| 5 | Input/output boundary controls | V2-1 deferral | No | Untrusted input sources, or an upstream veto hook |
| 6 | Tenant agent-builder (Import/Export) | V1 T2-6 | No | Tenant-facing builder UI reaching the roadmap |
| 7 | Real `context_ref` compaction lanes | V1 T1-2 residue | No | A producer running multiple lanes under one agent identity |
| 8 | Per-spawn `forward_context` narrowing | V1 T2-3 note | No | Ad-hoc lower-trust child spawns from a trusted template |
| 9 | `Chat.Stream` sugar | V1 T3-8 | No | Next REPL/streaming rework |
| 10 | Effect journal + deterministic replay at the agent loop | V2 Already-Covered WATCH row | No — upstream-gated | `jido_ai` absorbing the V2 runtime |

---

## 1. Deterministic eval harness (V2-5) — ✅ ADOPTED 2026-07-03

**Standing**: SHIPPED as the minimal slice — `JidoClaw.Eval` + `JidoClaw.Eval.{Case, Run}` in `lib/jido_claw/eval/` (unadopted-next-five item 5). `Case` packages `{kind, request, assertions}` and `run_case/2` executes it against **production functions only** (the jidoka design intent, preserved: the runner adds no new runtime path) across four kinds — `:prompt` (the assembled `SubagentPrompt.build/3`), `:schema` (`Jido.AI.Output.parse/2` over a worker's `strategy_opts()[:output]`), `:composer` (`RouteComposer.run_sync/1` through the real gate dance), and `:coherence` (a doctrine slice's prose vs per-token schema probes — pinning the prose-half/schema-half field contracts this entry called load-bearing). 10 seed cases in `test/jido_claw/eval/` pin the post-AR-9 surface: the coder/reviewer/plan-drafter/plan-arbiter assembled prompts, the reviewer-verdict and arbiter decision-memo schemas, the tie-break rung/verdict and `likely`/`unsure` token coherences, and an armed adopt-memo composer e2e. Unknown assertion keys fail loudly (an `:unknown_assertion` record fails the run) — a deliberate deviation from jidoka's silent skip, since drift-catching is the point. **Stub-list note**: the six stubs this entry named (and the V2-5 entry's four) are accurate-but-partial subsets of `test/support/` — all seven files exist — but the shipped harness consumes *none* of them directly; it calls production functions, and the composer case arms the existing composer stubs via app env exactly as the loop tests do.

**Now?** Done. The bar was met, not skipped: items 3+4 of the unadopted-next-five program were "the next material rewrite of the doctrine slices" — a new arbiter persona (the 10th), two new doctrine slices (`tie_break`, `code_doctrine` — registry now 11), and the arbiter memo's prose-half/schema-half field contract.

**Trigger**: fired 2026-07-03 (items 3+4 above). Follow-on growth stays demand-gated — add a seed case when a prompt-surface regression escapes the ordinary suite, not ahead of it; the scope guard was "a harness plus a first case set, not an eval program."

## 2. LLM-authored bounded plans / `compose_skill` (V2-7)

**Standing**: the jidoka-novel kernel — the LLM as plan *author* — remains unadopted, but its substrate changed shape underneath it. AR-2 shipped the deterministic route composer (`JidoClaw.RouteComposer`, `compose_route/4`, catalog discoverable at `jido://workflows/catalog`, waves/gates/leases/replay), which delivers "bounded plans over an allowlisted catalog" from the *platform* side, signal-driven and deterministic. `Workflows.StepNormalizer` (the validation half of the original translation sketch) also still exists.

**Now?** No — the composer deliberately keeps composition deterministic; handing authorship to the LLM is a posture change, not a feature gap. But the entry's cost estimate is now stale in the cheap direction: a `compose_skill`-style tool would validate LLM-emitted routes against the composer's *existing* catalog rather than needing new infrastructure (and certainly not embedded Lua).

**Trigger**: transcripts showing recurring multi-step freestyle tool-looping that a bounded plan would structure, or an operator ask for ad-hoc routes without writing YAML.

**Cross-link (2026-07-02)**: the medium half — sandboxed LLM-facing Lua — resurfaced in [`../amber/FEATURES-WORTH-BORROWING.md`](../amber/FEATURES-WORTH-BORROWING.md) **AM-1**: a read-only `docs` + `eval` code-mode pair over the Ash read-models that *computes reads* rather than authoring plans, so this verdict stands (the "certainly not embedded Lua" clause above is about plan authorship, and AM-1 stays off that axis — argued inline in its entry). AM-1 lifts V2-7's `Lua.Policy` envelope + `call_trace` shape; if this trigger fires, AM-1's binding substrate is where a `jido.workflow(...)` binding would slot in, behind this entry's own posture gate.

## 3. Cron async dispatch + stuck watchdog (V1 T2-5 operational note)

**Standing**: dispatch is still synchronous inside `Platform.Cron.Worker`'s tick (the in-code comment keeps the deferral explicit: a watchdog "would need async dispatch"); a hung dispatch blocks that job's GenServer indefinitely, undetected. WS4a's `Cron.Owner` reconcile converges *missing* workers, but a stuck worker is alive — reconcile doesn't help. The risk profile has grown since the note: cron is now cluster-wide across every active tenant, and `:agent`/`:workflow` targets can legitimately run long.

**Now?** Not yet — no observed incident, and it's a real design change (async dispatch + liveness watchdog + an overlap policy).

**Trigger**: the first stuck job, or long agent turns on cron becoming routine. Note the coupling: going async invalidates T2-5's "overlap can't occur under synchronous single-worker dispatch" N/A rationale, so jidoka's `overlap: :skip | :allow` + `skip_count` idea re-enters scope in the same change — adopt them together.

## 4. Per-tool (vs per-server) MCP approval overlay (V2-2 deferral)

**Standing**: unchanged and deliberate — approval is per-server (`require_approval`), reach is per-template (`templates:` allowlist), unknown `mcp_*` names fail closed to gated. The per-template reach-allowlist superseded the overlay's primary use (capability scoping per worker class), and building the overlay means the `mcp_requirement/2`-resolves-before-the-native-overlay surgery the reach design deliberately avoided.

**Now?** No.

**Trigger**: a configured server whose tool list mixes benign and dangerous tools that the *same* template legitimately needs — per-server trust too coarse, reach unable to split it. That is the one shape the current two axes can't express. (If the mix is splittable by template, reach already covers it.)

## 5. Input/output boundary controls (V2-1 deferral)

**Standing**: the operation boundary shipped (the tool-approval gate, now with the S-M1 shell floor); input controls (`max_input_length`-style) and output boundary controls were never built — declared outside the threat model, since the sole operator is trusted and containment targets tool *effects*, not resource abuse.

**Now?** No.

**Trigger**: either exposure to untrusted input sources (multi-tenant chat, public Discord channels widening beyond the operator), or the second upstream watch trigger firing — `jido_ai` growing a tool-execution/turn middleware hook, which would make the enforcement point nearly free and also relocate V2-1's gate out of the `Tools.Action` wrapper.

## 6. Tenant agent-builder / Import-Export round-trip (V1 T2-6 + V2 table row)

**Standing**: templates remain compiled-in — a 13-entry static `@templates` map over `Agent.Workers.*` modules; no file import, no allowlist registries, no `priv/templates/`. jidoka's reference shape (V2 `Jidoka.Import`/`Jidoka.Export`: DSL and JSON/YAML both producing the same `Agent.Spec`, everything executable resolved through caller-supplied allowlist registries, `max_import_bytes/depth/nodes` hardening) survived re-verification byte-exact and is stable.

**Now?** No — tenant-supplied agents are still not a use case.

**Trigger**: "user creates an agent in the web UI without writing Elixir" reaching the roadmap. Lift V2's import schema and adapt the registries to per-tenant `Agent.Templates` allowlists, per the entry's sketch.

## 7. Real `context_ref` compaction lanes (V1 T1-2 residue)

**Standing**: still a no-op — the Compactor's key shape (`"<identity>::<context_ref|default>"`) accepts a `context_ref` from tool context, but no producer sets one; every key trails `::default`.

**Now?** No — a dead lane with zero carrying cost.

**Trigger**: any surface running multiple independent conversation lanes under one agent identity (per-channel lanes on a shared session, or composer stages sharing an identity). Until a producer exists there is literally nothing to build.

## 8. Per-spawn `forward_context` override (V1 T2-3 divergence note)

**Standing**: visibility policy remains template-only — operator config, fail-closed validation in `hydrate_template/1` — exactly the security posture the entry chose. The "per-spawn LLM-override param" it named as a documented future enhancement was never built.

**Now?** No — and if ever built, constrain it to *narrowing only* (a spawn may request less visibility than its template grants, never more); a widening param would invert the boundary that made T2-3 a real control rather than a suggestion.

**Trigger**: a recurring case of a trusted template spawning ad-hoc lower-trust children (e.g., main spawning a researcher against untrusted web input) where minting a dedicated tighter template each time proves too heavy.

## 9. `Chat.Stream` sugar (V1 T3-8)

**Standing**: permanent-PARTIAL — streaming works via `Jido.AI.Request.Handle` plus the display/LiveView assigns; jidoka's wrapper (V2's `Jidoka.Stream`: an `Enumerable` of events with `text_delta/1`, `thinking_delta/1`, `await/2`, deliberately decoupled from Jido.AI internals) is better ergonomics, not missing capability.

**Now?** No — cosmetic.

**Trigger**: the next time the REPL/streaming surface is reworked anyway, or a second streaming consumer appears (scripting/API use). Lift the V2 event-struct-backed shape at that point, not before.

## 10. Effect journal + deterministic replay at the agent loop (V2 Already-Covered WATCH row)

**Standing**: unchanged N/A-as-a-borrow — adopting it means replacing the `jido_ai`-owned ReAct loop, a rewrite rather than a borrow. jido_radclaw already converges on the same idea at every axis it *does* own: the workflow axis (Reactor event log, definition fingerprint, replay) and — since AR-2 — the composer (durable event log + projection + replay gates). jidoka's implementation is stable and effectively dormant (no substantive commits since 2026-06-12).

**Now?** No — upstream-gated by design.

**Trigger**: the first upstream watch trigger — `jido_ai` absorbing V2's effect-journal/deterministic-replay runtime. If that fires, this is not a single borrow but a program-level re-audit: the V2 doc's whole Already-Covered table flips, and V2-1's enforcement point moves. Treat it as the "V3 moment."

---

**Minor footnote** (tracked here so the inventories stay clean): ~~T2-4's `blocks_count` still loads full `Block` rows to `length/1` — swap to `Ash.count/2` opportunistically next time someone is in `Memory`/`Inspection`; not worth a work item.~~ **Done 2026-07-02** — but not the naive swap: the list is label-deduped, so a raw-row `Ash.count` would over-count; `namespace_info/1` now counts DB-side via `Ash.Query.distinct(:label)` over the same scope-chain read (pinned by a same-label-two-scopes test).
