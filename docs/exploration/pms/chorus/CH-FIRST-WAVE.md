# CH first wave — the adoptable-now queue

*A sequenced grab-list, not new design. Extracted 2026-07-04 from the
[Chorus inventory](FEATURES-WORTH-BORROWING.md)'s "suggested first wave" — the
entries whose trigger is satisfied by the act of deciding to work (no argus slice
required). Everything else in the inventory is argus-slice-bound and stays there;
this doc exists so these don't wait on argus by association. Refs inherited from
the inventory (verified there 2026-07-04 @ jido_radclaw `609350aa`, Chorus
`47b5bb6`); re-verify at build time. **AGPL discipline applies**: Chorus supplies
contracts and rubrics only — every mechanism below is our-side wiring or a
reimplementation from the described behavior, never lifted code.*

**Queue discipline** (the next-five/next-ten habit): each item ends by reconciling
its source entry — add the dated Status line (the inventory carries none yet; this
queue is Chorus's first adoption pass), correct any claims the implementation
falsified, and update cross-refs the same session.

**Effort legend**: XS ≤ 2h · S ≤ 1 day · M 2–4 days.

| # | Item | Source | Effort | Shape |
| --- | --- | --- | --- | --- |
| 1 | Forge needs-input reply loop (surface the park, wire the reply) | [CH1-2a](FEATURES-WORTH-BORROWING.md#ch1-2-busy-thread-instruction-delivery--the-interrupt-taxonomy--flows-mid-run-steering-answer) | S | One re-broadcast + one LiveView affordance + guard tests |
| 2 | Headless-contract prompt fragment + env marker for Forge runners | [CH2-5](FEATURES-WORTH-BORROWING.md#ch2-5-the-headless_preamble-rubric--the-unbridged-approvals-contrast) | XS | One prompt fragment + spawn env + test |
| 3 | MC1-1 riders: anchor-ownership axis + group-teardown discipline | [CH2-6](FEATURES-WORTH-BORROWING.md#ch2-6-per-backend-resume-anchor-differences--the-codex-thread-id-map) + [CH3-2](FEATURES-WORTH-BORROWING.md#ch3-2-two-stage-group-kill-spec) | XS (inside MC1-1) | Rider on [MC-FIRST-WAVE item 2](../multica/MC-FIRST-WAVE.md) |

Items 1 and 2 are independent — slot either anywhere. Item 3 is not standalone:
it lands **inside** MC1-1's build whenever that queue item runs, and is recorded
here so it doesn't slip (the next-ten queue's rider habit).

---

## 1. CH1-2a — Forge needs-input reply loop (S)

**What**: close the dead-end CC1-2 found and this dig re-verified at HEAD — both
halves already exist, unwired. A running Forge harness parks at
`state: :needs_input` and broadcasts `{:needs_input, %{prompt: question}}` on the
**per-session** topic (`forge/harness.ex:661-663`, `forge/pubsub.ex:40-42`) that no
operator surface subscribes to (ForgeLive/DashboardLive listen on the sessions
topic and handle only start/recover/stop — `web/live/forge_live.ex:53-69`); the
reply primitive `Forge.apply_input/2` → `Harness.apply_input/2` routes input to
the waiting sandbox and flips `:needs_input → :ready` (`forge.ex:133-135`,
`harness.ex:90-92, 531-568`) — **zero callers in lib/**. Wire: (a) re-broadcast
`:needs_input` (and its clearing) onto the sessions-level topic — or subscribe the
LiveView per-session for sessions it renders; (b) render the parked state with the
question text and a reply box in ForgeLive; (c) submit through the existing
`Forge.apply_input/2`.

**The contract details, from the dig**: the *ask* may carry text anywhere, but the
*reply* enters only through an authenticated non-model surface (XA1-1 — never a
tool an agent could call); replying to a session that is not parked returns a
typed error, no silent queueing (Chorus's 409-read-only analog); a session that
terminates while parked must clear the parked presentation (no stale "waiting"
rows — SY2-2's reconciliation-releases rule); bound the input size (their 4000-char
validation is a fine default).

**Done when**: a Forge session that hits `:needs_input` is visibly parked on an
operator surface with its question; an authed reply resumes it end-to-end
(observable: the consolidator or a driven session continues past the park);
non-parked replies and post-termination staleness have tests; source entry CH1-2
gets a dated PARTIAL Status line (the (a) slice — the slice-6 CLI-adapter triangle
and interrupt taxonomy remain argus-bound).

## 2. CH2-5 — Headless-contract prompt fragment + env marker (XS)

**What**: our Forge CLI runners are headless (`-p` print-mode, stdin closed after
the prompt) but nothing *tells the agent that* — the failure mode is a run stalling
on a question no one can answer (orca's plan-mode deadlock is the same class).
Reimplement the HEADLESS_PREAMBLE rubric (`cli/prompts.mjs:44-92` — contract, not
text): a shared fragment in Forge runner prompt assembly stating (a) no human is
at the terminal — never invoke interactive/blocking prompts or ask-the-user tools;
(b) route any human-decision point through the platform's async channels (for our
runners today: return the structured `:blocked`-with-question shape the `Runner`
behaviour already defines, `forge/runner.ex:15-22` — which item 1 then surfaces);
(c) name the machine-readable marker — set `JIDOCLAW_HEADLESS=1` in the runner
spawn env so hooks/tools can branch on it.

**Done when**: every Forge CLI runner prompt carries the fragment (one assembly
point, not per-caller copies); the env marker is set at spawn and documented; a
test pins fragment presence; CH2-5 gets its Status line. Rider note: when MC1-1's
env-scrub lands, the marker rides the same env-construction site.

## 3. CH2-6 + CH3-2 — riders on MC1-1 (XS, inside that build)

**What**: two Chorus-sourced additions to record against
[MC-FIRST-WAVE item 2](../multica/MC-FIRST-WAVE.md) before it runs:

- **Anchor-ownership axis** (CH2-6): the runner resume state carries
  `anchor_ownership: :client | :backend` instead of special-casing codex inline —
  claude anchors are client-deterministic (mint the id, probe the transcript);
  codex anchors are backend-minted (capture from the first `thread.started`
  event) and trustworthy **only after a clean fresh exit** — persist backend-owned
  anchors on the Forge `Session` row (not a dotfile), only from clean exits.
  Chorus is the second implementation confirming the split is structural
  (multica's server-persisted flag-driven model is the third variant).
- **Group-teardown discipline** (CH3-2, the Forge half): spawn CLI children as
  process-group leaders where the host tier allows, and make runner stop/timeout
  teardown signal the **group** — graceful signal, bounded configurable window,
  then hard-kill the group — so MCP-server children of the CLI die with it
  (the scan's OpenHelm datapoint — dig-verified 2026-07-04 at
  `claude-code/runner.ts:197-212,782-811`: `detached:true` group leader,
  negative-pid SIGTERM, SIGKILL after 5s; Chorus's `process-killer` spec).
  Sandboxed
  tiers already get this from sandbox destruction; the host-side runner path is
  the one that can orphan.

**Done when**: MC1-1's done-when plus: the ownership axis exists in runner state
with both backends mapped; backend anchors persist only on clean exit; host-tier
runner teardown is group-scoped with a bounded window; CH2-6 and CH3-2 get Status
lines (CH3-2's argus half — the slice-6 CLI-adapter interrupt — stays in the
inventory).

---

**Collision notes**: none with `docs/plans/unadopted-next-ten/` (composer/judgment
work). Item 1 touches ForgeLive only additively; it is also the seed of the CC1-2
attention read-model — build it as a plain LiveView affordance now, and let the
argus slice-1 attention feed absorb it later rather than blocking on it. Item 3
must not run standalone — if MC1-1 is not in flight, it waits there.

**Status (2026-07-11)**: LANDED inside pre-argus Wave A #2 (MC1-1 build;
[docs/system/forge-session-resume.md](../../../system/forge-session-resume.md)).
`ResumeState.ownership :: :client | :backend` is a first-class axis: claude
anchors mint CLIENT-side pre-spawn (`--session-id`), codex anchors capture
`thread.started` as `:provisional` and promote only on a clean `:done` (the
CH2-6 backend-trust rule), and every copy persists fenced on the Forge
`Session` row — never a dotfile. Group-scoped teardown landed as
`ChildTracker` tagged incarnations + `OsCmd.terminate_tree/2`
(TERM → grace window with re-discovery → identity-verified STOP+KILL; CH3-2's
two-stage shape, process-table walk instead of setsid for macOS portability).

