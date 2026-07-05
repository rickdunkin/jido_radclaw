# SY first wave — the adoptable-now queue

*A sequenced grab-list, not new design. Extracted 2026-07-04 from the
[symphony-lineage inventory](FEATURES-WORTH-BORROWING.md)'s "suggested first
wave" — the three pieces whose trigger is satisfied by the act of deciding to
work (no argus slice required). Everything else in the inventory is
argus-slice-bound and stays there; this doc exists so these three don't wait on
argus by association. Refs inherited from the inventory (verified there
2026-07-04 @ jido_radclaw `a9629f01`, symphony `4cbe3a9`, OpenSymphony
`8d101a0`); re-verify at build time.*

**Queue discipline** (the next-five/next-ten habit): each item ends by
reconciling its source entry — add the dated Status line (the inventory carries
none yet; this queue is the lineage's first adoption pass), correct any claims
the implementation falsified, and update cross-refs the same session.

**Effort legend**: XS ≤ 2h · S ≤ 1 day · M 2–4 days.

| # | Item | Source | Effort | Shape |
| --- | --- | --- | --- | --- |
| 1 | Scheduled provider credential canary (closes XA2-3) | [SY1-4](FEATURES-WORTH-BORROWING.md#sy1-4-multi-account-rotation--scheduled-rate-limit-probe--cli-credential-health-as-a-subsystem) (probe half) | S | One cron system job + durable result + transition-edge alerting |
| 2 | `.jido/config.yaml` fail-closed boot + last-known-good re-read | [SY1-3](FEATURES-WORTH-BORROWING.md#sy1-3-validated-config-contract-stack--db-less-ecto-schemas-fail-closed-boot-last-known-good-reload-strict-rendering) (near-term half) | S | One `load/1` rework + boot check + tests |
| 3 | Composer wave inactivity clock (typed stall reason) | [SY1-2](FEATURES-WORTH-BORROWING.md#sy1-2-orchestrator-dispatch-hygiene--reconcile-before-dispatch-revalidate-at-dispatch-backoffstallcaps) (sketch b) | M | Activity source + poll-loop check + typed terminal |
| — | *Rider*: continuation-turn prompt discipline ([SY3-3](FEATURES-WORTH-BORROWING.md#sy3-3-continuation-turn-prompt-discipline)) | rides MC first wave #2 (MC1-1) | — | Lands inside the warm-resume build, not here |

Items 1–3 are mutually independent — slot in any order (1 first is the best
value-per-effort: it closes a gap two corpora have now named). Item 3
soft-depends on MC first wave #1 (the `RunFailure` taxonomy): land the stall
reason as a taxonomy member if that module exists by then, else as a typed
composer terminal to be folded in when it does.

---

## 1. SY1-4 (probe half) — Scheduled provider credential canary (S)

**What**: close the XA2-3 gap — `Config.check_provider/1`
(`core/config.ex:240-252`: per-provider HTTP reachability/auth probe, 5s
timeout, `:ok | {:error, :unauthorized} | {:error, :unreachable}`) exists and
is called only from the REPL banner (`cli/repl.ex:161`) and the setup wizard
(`cli/setup.ex:264`) — never scheduled. Land it as a leader-owned cron
**system job** (the WS4a Owner gives single-node execution for free) probing
the configured provider(s) on an interval (default ~15 min — symphony's
poller cadence, `rate_limit_poller.ex:16-124`).

**Delivery rules** (the corpus-merged ones, so this doesn't become noise):
**transition-edge only** — alert on state *change* (`ok → unreachable`,
`unauthorized → ok`), never per-tick (Xantham's `==`-not-`>=` rule); the
notifier is scheduler-side, never agent behavior (XA1-2); result rows are
durable (a `Trace` `:infra`/`:guardrail` event + telemetry counter now — and
this becomes the first producer for the CC1-2 attention read-model when
slice 1 builds it, alongside the LoopGuard/cron-failure items already named
there).

**Second cut, optional** (only if/when running Claude subscription OAuth):
symphony's unified-ratelimit probe — a ~26-token `POST /v1/messages` parsing
`anthropic-ratelimit-unified-{5h,7d}-{status,reset,utilization}` headers
(`claude_code/rate_limit_probe.ex:14-209`) — turns the canary from
"reachable?" into "how much runway?". Not needed for the gap to close.

**Done when**: the job runs on schedule under cron ownership; a provider
going unreachable/unauthorized produces exactly one durable event + one log
at the transition (and one at recovery); telemetry counter exists; XA2-3's
entry in the Xantham inventory gets its Status line, and source entry SY1-4
gets a dated note that the probe half shipped (rotation half still TRACK).

## 2. SY1-3 (near-term half) — `.jido/config.yaml` fail-closed boot + last-known-good re-read (S)

**What**: `Config.load/1` (`core/config.ex:73-103`) re-reads the YAML on
**every call** and collapses *any* failure — missing file, parse error,
non-map top level — into silent `%{}` → defaults. That conflates one
legitimate case with two bad ones. Split the arms:

- **Missing file** → defaults, unchanged (first-run/no-config projects are
  normal).
- **Present but unparseable / non-map, at boot** → fail closed: refuse to
  start with the YAML error and path (symphony's rule: "if `symphony.yml` is
  missing or has invalid YAML at startup, Symphony does not boot" — ours
  keeps the missing-file arm legitimate).
- **Present but unparseable, at runtime re-read** → keep **last known good**:
  cache the last successful parse (`:persistent_term`), serve it with a
  loud warning naming the parse error, never silently degrade a live session
  to defaults (their `workflow_store.ex:141-152` semantics; our
  `MCP.EndpointConfig.parse/1` fail-closed-per-entry posture is the local
  exemplar for the style).

**Deliberately out of scope**: schema validation of the config *contents*
(that's SY1-3's main body, landing with the FLOW §9 store work) and any file
watcher (per-call re-read already gives reload semantics; the fix is only
what a failed re-read means).

**Done when**: a syntax error introduced into a live session's config.yaml
produces a warning + unchanged behavior (not a silent provider/model reset);
boot with a corrupt config refuses with the YAML error; boot with no config
still works; tests pin all three arms; source entry SY1-3 gets a dated
partial-ship note (near-term half only — the validated-store half stays
slice-bound).

## 3. SY1-2 (sketch b) — Composer wave inactivity clock (M)

**What**: the composer's only mid-wave clock is the wave timeout
(`@default_wave_timeout_ms 300_000`, `route_composer/route_composer.ex:227`,
enforced in `poll_existing_child/3` `:3319-3337`) — nothing distinguishes a
**wedged** agent (port hung, LLM stalled) from a **working** one, so a wedge
always burns the full wave budget, and long-wave stages (the AR-9 tiering
seam invites 15–30 min waves for `:capable`/`:high` stages) burn
proportionally more. Add symphony's stall clock (up
`orchestrator.ex:574-650`): no *activity* for `stall_timeout_ms` → cancel
the wave child with a typed stall reason; `<= 0` disables (their rule,
verbatim).

**The two design choices, called out**:

- **Activity source**: WorkflowEvent appends are the wrong signal — a
  healthy single agent step is legitimately silent between `step_started`
  and `step_completed`, so event-append inactivity false-positives on
  exactly the long steps this exists for. The right signal is agent-level
  liveness: last Trace/telemetry activity (tool executes, token deltas — the
  same `[:jido, :ai, :tool, :execute, :*]` stream AgentTracker already
  consumes, `agent_tracker.ex:266-278`) for the agents keyed to the wave's
  child run. Composer and child run on the same node (leases), so a
  node-local read is sound.
- **Default posture**: ship **disabled** (`stall_timeout_ms: 0`). At today's
  5-min default wave timeout a stall clock adds nothing; it pays when an
  operator raises per-stage timeouts. Document the knob next to
  `wave_timeout_ms`; revisit the default when AR-9-tiered long stages exist
  in a real route.

**Typed reason**: `:stage_stalled` (distinct from the existing
`:observe_timeout` — inactivity ≠ deadline, symphony's own distinction). If
MC first wave #1 (`RunFailure` taxonomy) has landed, register it there as a
platform-side member with the retryable set membership decided at that
boundary (a stall is retry-eligible; symphony retries it with backoff);
otherwise land it as a composer terminal reason and fold it into the
taxonomy when that module arrives.

**Done when**: a deliberately-wedged fake runner in a test wave is cancelled
at the stall threshold (not the wave timeout) with `:stage_stalled`; `<= 0`
verifiably disables; the reason reaches Trace events (bounded, tenant-stamped
— the composer's existing posture); source entry SY1-2 gets a dated
partial-ship note (sketch b only — a/c/d stay slice-bound).

---

**Collision notes**: none with `docs/plans/unadopted-next-ten/` (items 4–10
are composer/judgment work — item 3 here touches the composer's *polling
loop*, not the judgment lanes, but if a next-ten composer item is in flight,
sequence within the same session to avoid merge friction in
`route_composer.ex`). None with the MC first wave: item 1 touches
cron + `core/config.ex`, item 2 touches `core/config.ex` only, item 3
touches `route_composer.ex` — disjoint from MC's runner files (MC1-1/MC1-4)
except the shared taxonomy seam noted above. The SY3-3 rider must ship
inside MC #2's warm-resume change, not as a separate pass — recorded here so
it doesn't slip.
