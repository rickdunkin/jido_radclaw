# Unadopted Gust Ideas — Standing & Triggers

Companion to [`FEATURES-WORTH-BORROWING.md`](FEATURES-WORTH-BORROWING.md). That doc is the
inventory and adoption record; this one rolls up only the **live remainder** — ideas gust
surfaced that were never implemented here and were *deferred or put on watch*, not rejected.
For each: where it stands in the code today, whether it's worth adopting now, and the trigger
that would change that verdict. Not repeated here because they're settled: the whole
Skip / Already-Covered table (rejected outright), the cancel-stays-off-MCP divergence (a
chosen posture, not a deferral), and G1-1 + G2-1/G2-1a themselves (shipped — only G1-1's
validation tail rides below as #2).

Compiled **2026-07-02**, against gust `590335e` (2026-07-02, the wait/resume-era tree) and
the same-day reconcile of the inventory. Verdicts are weighted by what the platform actually
runs today (single-node in anger, CLI-hosted Forge runners, a sole operator authoring YAML
by hand). Ordered by trigger proximity — nearest first.

| # | Idea | Source entry | Adopt now? | Trigger distance |
| --- | --- | --- | --- | --- |
| 1 | Per-`<id>` catalog resources (`jido://workflows/<stage>`) | G2-1b | **SHIPPED 2026-07-02** | Spike ran green; Phases 1+3 landed the same day (no dep patch) |
| 2 | Multi-node validation + lease ops (WS6) | G1-1 tail | Scheduled — circumstance-gated | Fires when a real second node (the argus tailnet) is imminent |
| 3 | Debounced `.jido/` YAML file-watch | G3-2 | No — dev QoL | Skill-YAML iteration friction, or a second live-reload consumer |
| 4 | Framed-port JSON-RPC runner protocol | G2-2 | No | A Python/non-CLI Forge runner (or hermes T1-1) reaching the roadmap |
| 5 | Disk-of-truth reconciliation | G3-3 | No — dormant | A file-canonical `.jido` store gaining a DB mirror |

---

## 1. Per-`<id>` catalog resources (G2-1b)

**SHIPPED 2026-07-02.** The Phase 0 spike ran **green on all four gate points** (the
anubis `component` template registers compile-time inside the `use Jido.MCP.Server`
module, lists under `resources/templates/list`, routes template reads to `read/2` with
the parsed name, and static-before-template ordering keeps the catalog URI untouched), so
Phases 1+3 landed the same day with **no dep patch** (Phase 2 never fired).
`JidoClaw.MCPServer.Resources.WorkflowStage` (`uri_template: "jido://workflows/{name}"`)
single-sources `Stage.to_map/1`, so a per-stage read is byte-identical to the catalog's
entry; unknown stage ⇒ resource not-found. Tests drive the real server module in-process
(`workflow_stage_test.exs`); registration is asserted via `__components__(:resource)` +
the templates-list handler, never `__publish__()` (the plan's false-green trap). Details:
[`docs/plans/mcp-workflow-resources/README.md`](../../plans/mcp-workflow-resources/README.md).

## 2. Multi-node validation + lease ops — the WS6 tail (G1-1)

**Standing**: the borrow itself shipped in full (WS1–WS5 + WS4a);
[`WS6-testing-and-ops.md`](../../plans/clustering/WS6-testing-and-ops.md) (size M, depends
on all) is the committed-but-unstarted remainder: a real multi-node `:peer` harness, the
deploy/ops config + `cluster_enabled` flip checklist, and lease telemetry/dashboard. Two
proofs ride it: WS5's cross-BEAM cast delivery has never run against a real second BEAM, and
the clustering README's own guardrail says don't enable `cluster_enabled` in a real
deployment without the harness having passed.

**Now?** Not an adoption decision — committed validation work, correctly circumstance-gated.
Nothing multi-node runs in anger, so it waits without cost.

**Trigger**: the argus clustered-tailnet deployment moving from future to imminent — WS6 is
the precondition for the `cluster_enabled` flip, not a follow-up. A single-node lease
incident (stalled reclaim, silent fence loss) would pull the telemetry slice forward on its
own.

## 3. Debounced `.jido/` YAML file-watch (G3-2)

**Standing**: unchanged — no watcher exists (`file_system` is still only a transitive credo
dep, absent from `mix.exs`). `JidoClaw.Skills` is a boot-time GenServer cache with a manual
`reload/0` (`platform/skills.ex:297`); `StrategyStore`/`PipelineStore` share the
boot-time-cache shape but expose **no reload at all** — watching them means adding one
first. Gust's template (`file_monitor/worker.ex`: dedup queue + `send_after` delay,
re-verified 2026-07-02) remains the ~40-line reference. AR-2's catalog never became a second
watch target (compile-time `%Stage{}` code).

**Now?** No — dev QoL for a sole operator; calling `Skills.reload/0` after editing YAML is
one line.

**Trigger**: skill-YAML iteration becoming a routine authoring loop (the friction is
per-edit), or a second consumer of live reload appearing — e.g. web-UI skill editing — at
which point the watcher and the missing store reloads land together.

## 4. Framed-port JSON-RPC runner protocol (G2-2)

**Standing**: still fully open, re-verified 2026-07-02 — Forge remains CLI-hosted runners
only (`shell`/`claude_code`/`codex`/`workflow`/`custom`/`fake` in `forge/harness.ex`'s
`resolve_runner/1`; `sbx`/docker are sandbox *clients*), every Forge port a plain
`:binary`/`:exit_status` byte stream, no warm pool (`forge/manager.ex` is concurrency caps
only). The reference protocol held steady upstream (gust_py was untouched by the wait
feature): `{:packet, 4}` framing, JSON messages `log`/`call`/`start`/`result`/`error` with a
synchronous `reply`, behind the clean parser/runtime/task_worker adapter seam. The port
adaptations stand as recorded in the inventory: warm process pool (not per-task fork-exec)
and drop the sync call-back-to-host surface.

**Now?** No — nothing on the roadmap needs a typed host↔script RPC; borrowing it early would
be a protocol without a consumer.

**Trigger**: a "RunPythonScript"-class Forge runner (or any non-CLI language runtime)
reaching the roadmap — or hermes T1-1 (programmatic tool calling, likewise NOT_ADOPTED; the
same gap seen from the other side) getting picked up. If either fires, design the two
against one protocol rather than growing two.

## 5. Disk-of-truth reconciliation (G3-3)

**Standing**: dormant, and more settled each pass — cron moved DB-native (the `cron_jobs`
Ash resource; `.jido/cron.yaml` legacy/backup), the file-canonical stores
(skills/strategies/pipelines) have no DB mirror, so boot re-parse *is* the reconciliation;
the one candidate that could have un-mooted it (AR-2's catalog) shipped as compile-time
code. Gust's shape (`dag/loader/worker.ex` → `Flows.delete_not_found_ids/1`, re-verified
2026-07-02) stays the ~20-line template.

**Now?** No — there is nothing to reconcile.

**Trigger**: any file-canonical `.jido` store gaining a DB mirror or projection (e.g. skills
indexed into Postgres for web-UI listing/search). The prune belongs in the same PR as the
mirror — adopt at that moment, not before.

---

**Footnotes** (tracked here so the inventory stays clean):

- **Live-node work-stealing / graceful-drain** is not an entry because it's a recorded
  non-goal (`docs/plans/clustering/README.md` §non-goals; dead-node-only reclaim inherited
  from gust deliberately — gust lacks it too). It un-non-goals only if a real multi-node
  deployment shows sustained load imbalance; that's a WS6-era conversation.
- **Gust's new wait/resume primitive** (`wait_for` + `TaskWaiter` + the `resume_task` MCP
  tool, 2026-06-26..07-02, found in the 2026-07-02 reconcile) was evaluated and needs no
  entry: the workflow-axis gate family + composer signal subscriptions already cover
  event-keyed pausing, with the approval semantics gust lacks. Recorded in the inventory's
  comparison table as "gap narrowed"; verdict unchanged.
