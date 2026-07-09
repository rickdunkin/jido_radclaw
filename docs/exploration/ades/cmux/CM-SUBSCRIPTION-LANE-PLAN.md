# CM subscription lane — interactive-TUI driving + the teams-mailbox question

Design note + proposed spike sequence — **QUEUED 2026-07-09**: the §5 soft
trigger (operator go-ahead) fired; Spike 1 + Lane A ride
[docs/plans/pre-argus-do-now item 22](../../../plans/pre-argus-do-now/README.md).
Lane B stays spike-1-gated, Lane C stays SKIP. Sibling to [FEATURES-WORTH-BORROWING.md](FEATURES-WORTH-BORROWING.md),
spun out of its OQ-2 during the 2026-07-06 operator conversation that followed the dig.
Same pins as the inventory: cmux @ `48e69cbb05`, jido_radclaw @ `85cbe9f2` (working
tree). Epistemic labels are load-bearing in this doc: **[dig-verified]** = firsthand
code reads from the cmux dig; **[operator-premise]** = the operator's stated
expectation, recorded as the driver, not verified; **[hypothesis]** = plausible and
consistent with evidence, unmapped by us; **[inference]** = my reasoning on top.

## 1. Background and driver

**[operator-premise]** Anthropic has previously announced an intent to exclude headless
print mode (`claude -p`) and the Agent SDK from OAuth *subscription* usage (Pro/Max
plans), then backtracked on the timing. The operator fully expects the removal to
eventually land. Consequence if it does: every currently-sanctioned *programmatic*
driving surface — `-p`, `-p --resume`, Agent SDK sessions — carries revocation risk
under subscription auth; API-key billing would remain but changes the economics this
project runs on. The **interactive TUI is the subscription product itself** — the one
driving surface whose subscription access has never been threatened.

**[dig-verified, corpus]** The field already made this bet explicitly: termic
"PTY-spawns the *real* agent CLIs so inference rides existing Pro/Max plans (an
explicit bet against vendor SDKs)" ([ades scan](../README.md), termic row), and the
entire terminal-native quadrant (termic, muxara, herdr, cmux) drives or observes the
interactive CLI in production. Also grounding: our Forge runners **already run on the
operator's subscription credentials today** — `claude_code.ex` syncs host `~/.claude`
(`settings.json credentials.json …`) into the sandbox
(`lib/jido_claw/forge/runners/claude_code.ex:152-186`), so a `-p` fence lands directly
on our current `-p`-based runner.

**What this reframes**: the slice-6 / MC1-1 reading list (SYNTHESIS §5.6) currently
ranks driving surfaces by structure and observability — TC1-3's structured lanes
(app-server, agent SDK, ACP) at the top. This driver adds a **billing-surface axis**
the list lacks: the most structured surfaces are also the most revocable ones. The
hedge is an **interactive lane** — drive Claude through the TUI surface — built so it
can be the fallback if the fence lands, and evaluated now while `-p` still works.

## 2. The decomposition

"claude-teams" bundles three separable things. Naming them is what un-sticks the
design conversation:

| Layer | What it is | Do we need it? |
| --- | --- | --- |
| **Billing surface** | The interactive TUI session (subscription-sanctioned) | **Yes — the whole point** |
| **Coordination channel** | The teams mailbox (lead↔teammate message passing) | Want, **if it maps** (§3) |
| **Display layer** | tmux (what cmux impersonates; spawn + panes for humans) | No — except as a spawn hook in one lane-B shape (§4, B3) |

cmux's tmux impersonation (CM1-1) implements only the display layer. The mailbox — the
part this plan cares about — is the part cmux deliberately never touches.

## 3. What we know vs what is unmapped

**[dig-verified]** (all refs in [CM1-1/CM1-2](FEATURES-WORTH-BORROWING.md)):

- Teammates are enrolled **by the lead's Task tool** (named registration; a *nameless*
  Task runs an in-process subagent inside the lead's process — not separately
  sandboxable). Pane teammates respawn as **full interactive TUI instances** via
  `respawn-pane -k -- "cd … && env … claude …"` — with lead-supplied env **we never
  enumerated**.
- The tmux vocabulary carries spawn/layout/display only; no messaging rides it.
- Hooks work on interactive sessions — cmux's entire 17-agent state engine is
  hook-on-interactive, including needs-input detection via an async `PreToolUse` hook
  (the only signal under `--dangerously-skip-permissions`).
- Transcript JSONL under `~/.claude` is file-readable (cmux-vault syncs those files).
- Trust-gate mechanics: `CLAUDE_CODE_SANDBOXED=1` short-circuits the "trust this
  folder?" prompt; cmux grants it per-launch on explicit opt-in and never persists it
  into restore.
- Restore/resume: interactive `claude --resume <session_id>` is how cmux restores
  sessions (registry + durable-evidence gating + the argv sanitizer, CM2-3).

**[hypothesis — the operator's understanding, ours to verify]**: a teammate-mode
session communicates with the rest of the team via a **mailbox**. Consistent with the
observable evidence (SubagentStart/Stop hook events exist; teams is externally
observable; file-based state under `~/.claude` is how Claude Code does everything
else) — but the dig **did not map it**, and cmux cannot teach it to us. Unknowns that
decide everything: message paths and schema; member identity/enrollment (does a
fabricated team directory suffice, or does enrollment require live lead-session
state?); whether a teammate functions without a live lead (heartbeats? exit-on-lead-
death?); delivery semantics (turn-boundary only, or mid-turn?); what the lead-supplied
respawn env contains.

**[inference]** If the mailbox is file/socket-observable and enrollment is
data-not-process, lane B1 (fabricated lead) is open. If it is bound to live
lead-session internals, only B2/B3 (real lead) or lane A remain.

## 4. The lanes

**Lane A — bare interactive (the floor; no teams anywhere).** Interactive `claude`
in the sandbox under a **PTY-as-pacifier**: nobody renders or watches the TUI; the
process just needs `isatty()` to hold. That is `docker exec -t` in the Docker sandbox
and a `script -q /dev/null …`-class wrapper (or `unbuffer`) on HostShell — **not**
slice 8's PTY broker, not ghostty_ex. I/O model:

- **Input**: mailbox delivery at turn boundaries — write the queued message to the PTY
  + Enter when the Stop hook says the turn ended. (Interrupt-then-type is the human
  steering gesture if mid-turn injection is ever needed; not v1.)
- **Output**: transcript JSONL reads at turn boundaries + hook events — file-and-event
  based, **not scraping** (this corrects the inventory conversation's first-pass
  objection; the objection assumed TUI byte-stream scraping was the only read).
- **Turn state**: our own hooks injected **per-invocation** via `--settings` (CM2-4's
  zero-residue pattern — no global `~/.claude` edits), posting to a loopback endpoint
  (PR-2's loopback MCP deposit endpoint is the in-tree precedent for
  sandbox→engine loopback surfaces). SessionStart/UserPromptSubmit/Stop/Notification/
  PreToolUse give us engine-observed lifecycle; the relaying adapter applies the
  CM1-2/HD1-1 fences (per-session+turn generation gating, process-exit outranks
  everything, misroute no-ops).
- **Interactive prompts**: trust gate handled by the CM1-1 discipline
  (`CLAUDE_CODE_SANDBOXED` per-launch, never persisted); permissions via
  `--dangerously-skip-permissions` as today — with a noted upgrade path: bridge
  `PermissionRequest`/`AskUserQuestion` hook events to `AgentCase` and answer by
  keystroke (PR-4-flavored; not v1).
- **Restore**: interactive `--resume <session_id>` with CM2-3's sanitizer rules as
  acceptance criteria (prompts and trust bypasses never replay; HD2-2's argv table).

Assumption surface: small and made of stable product surfaces (TTY accepted; hooks
fire; transcript format) — every one already load-bearing for shipping products in the
corpus. **Lane A is worth building even if the mailbox never pans out and even if `-p`
never dies** — it is the contingency floor, and it is the `{:forge, :claude_code}`
interactive variant the executor seam can host.

**Lane B — teams mailbox as the message transport (the upgrade).** What it buys over
lane A **[inference, pending spike 1]**: typed messages with sender identity instead
of raw keystrokes; structured teammate→lead result reporting; possibly mid-turn
delivery; multi-agent addressing for free. Three sub-shapes, preference order
B1 > B3 > B2:

- **B1 — fabricated lead**: no lead process; we write the team registry and speak the
  lead's side of the mailbox. Cleanest — no vendor orchestrator runs, our composer
  stays the only lead. Open only if enrollment is data-not-process.
- **B3 — shim-as-provisioner**: a real (dumb) lead + our fake `tmux` whose
  `split-window` handler provisions **Forge sessions** instead of panes — the direct
  translation of cmux's shim (theirs → `surface.split`; ours → session provisioning
  with our env injection, hooks, identity stamping). Most faithful to the vendor flow;
  reintroduces a vendor orchestrator, bounded by making the lead a dispatch shell.
- **B2 — dumb lead, vendor spawn**: a real lead session used only for
  enrollment/relay. Burns a session and keeps vendor spawn semantics; least control.

Costs, all shapes: `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` is an **experimental flag**
that can churn faster than `-p` ever did; the protocol is unmapped; the full CM1-1
discipline applies (written assumption ledger, mock-backed contract tests, re-verify
per vendor release — cmux's Python mock-socket suite is the method to copy).

**Lane C — convention mailbox (recorded to close it): SKIP.** A skill/CLAUDE.md
instruction telling the session to poll an inbox file. Prompt-trust (delivery depends
on model compliance), burns turns polling, no engine-observed delivery receipt — the
Xantham file-convention class the corpus already filed as a negative reference.

## 5. Suggested sequence

1. **Spike 1 — map the mailbox** (observation only, ~half a day, no product code).
   Run a real teams session locally (outside the sandbox): fs-watch `~/.claude` while
   lead and teammate exchange messages; enumerate a teammate's env delta vs the lead;
   grep the claude bundle for team/inbox/mailbox strings; probe whether a teammate
   starts against a fabricated team dir and what happens when the lead dies.
   **Deliverable**: a protocol note in this directory (paths, message schema,
   identity/enrollment, lifecycle, lead-liveness requirements) that converts the
   [hypothesis] into pinned fact or kills it. **Kill criteria for lane B**: mailbox is
   in-process-only / not file-or-socket-observable / enrollment hard-bound to live
   lead internals. *Trigger to fire: operator go-ahead (it's cheap) — **fired 2026-07-09**; hard
   trigger regardless: any renewed Anthropic announcement about subscription
   headless removal.*
2. **Spike 2 — the interactive-lane floor (lane A end-to-end).** PTY-pacifier in both
   sandbox backends; per-invocation hook injection to a loopback endpoint;
   transcript-JSONL reader; turn-boundary mailbox delivery; wired as an executor-seam
   variant so it lands where PR-2/PR-3 already work rather than beside them.
   **Done-when**: a composer stage runs green driven through an interactive session
   with zero `-p` on the path, turn state engine-observed via hooks (never scraped),
   and restore proven via interactive `--resume` under the CM2-3 sanitizer rules.
   Independent of spike 1's outcome.
3. **Step 3 — decision gate.** With both spikes' evidence: lane A-only vs A+B1 vs
   A+B3 (B2 only if both better shapes are closed). Record the decision as a dated
   note in this doc; fold the chosen lane's acceptance criteria into the queued MC1-1
   build and executor PR-3 **as a rider, not a parallel build** (the HD2-2/CM2-3
   discipline — one resume/driving stack, never two).

## 6. Risks, held honestly

1. **The durability assumption is itself an assumption.** If billing pressure fences
   `-p`, the same pressure can eventually reach automated-*looking* interactive usage.
   "Interactive rides the subscription forever" goes in the ledger next to CM1-1's
   nine — likelier to hold, not guaranteed. This lane is a hedge, not a right; treat
   continued subscription viability as monitored, not assumed. (Personal-use
   automation of the operator's own plan is field-standard — termic/cmux/herdr — but
   the assumption class is the same.)
2. **Experimental-flag churn (lane B).** Teams internals can move faster than any
   deprecation timeline; without the contract-test discipline the mailbox lane breaks
   silently mid-run. CM1-1's ledger method is mandatory, not optional.
3. **Rate limits and accounts.** A fleet of interactive sessions on subscription
   accounts makes symphony SY1-4 (multi-account rotation + the rate-limit probe) and
   myrlin MY1-1 (credential lineage; three-state token health) live design inputs —
   Forge already syncs the operator's real `~/.claude` into sandboxes, so credential
   hygiene is already on this path.
4. **Two-orchestrator conflict returns in B2/B3.** Bounded by the dumb-lead
   constraint (the lead dispatches; the composer decides), and by preferring B1.
5. **Observability regression risk.** Lane A's turn-boundary granularity is coarser
   than stream-json deltas; acceptable for composer stages (turn-level is what the
   engine consumes), noted for anything that wants token streams.

## 7. Cross-references and collisions

```
this plan ──► executor PR-2/PR-3 (in flight at 85cbe9f2 — coordinate, don't fork)
          ──► MC1-1 / HD2-2 / CM2-3 (the one resume stack; lane outcomes land as riders)
          ──► CM1-1 (assumption-ledger + contract-test method; trust-gate polarity)
          ──► CM1-2 / HD1-1 (hook-relay fences for the adapter)
          ──► CM1-3 (hook-semantics classifier, if lane A bridges prompts to AgentCase)
          ──► CM2-4 (per-invocation --settings injection — the hook install pattern)
          ──► SY1-4 / MY1-1 (accounts, rotation, credential lineage)
          ──► SYNTHESIS §5.6 (gains the billing-surface axis when this graduates)
          ──► t3code TC1-3 (the structured lanes this hedges against losing)
```

Collision notes: PR-2's loopback endpoint is the natural hook-ingress precedent —
reuse it, don't mint a second loopback surface. The FEATURES doc's OQ-2 is sharpened
by this plan (teams-as-transport, not teams-as-orchestration) — pointer added there.
Nothing in this plan changes the inventory's verdicts: CM1-1 stays a banked reference;
this doc is the named consumer that would fire it.
