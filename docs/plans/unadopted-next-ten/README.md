# Plan: Next ten items from the exploration inventories

*A sequenced work queue — not new design. Selected 2026-07-02, the same day the
[next-five queue](../unadopted-next-five/README.md) was scoped (its items 1–2
done, 3–5 in flight), from the four same-day inventories holding live Tier-1
material — [camus](../../exploration/camus/FEATURES-WORTH-BORROWING.md),
[ouroboros](../../exploration/ouroboros/FEATURES-WORTH-BORROWING.md),
[amber](../../exploration/amber/FEATURES-WORTH-BORROWING.md), and
[osa](../../exploration/osa/FEATURES-WORTH-BORROWING.md) — with riders from
[osa-claude-code](../../exploration/osa-claude-code/FEATURES-WORTH-BORROWING.md)
(reference-grade only, by its own verdict) and
[optimal-engine](../../exploration/optimal-engine/FEATURES-WORTH-BORROWING.md).
This queue assumes the next-five program has completed: AR-9 shipped whole (plan
wave + arbiter declaring its tier through the wired seam), the `code-doctrine`
slice authored, and the eval harness's minimal slice landed.*

**Selection principle.** Same discipline as the five-item queue, one tier out.
An item is admitted only if (a) the operator already endorsed its direction
(camus C1-1, agreed 2026-07-02), (b) its trigger is *satisfied by the act of
deciding to work* — a BORROW-PATTERN entry over a gap verified 2026-07-02 with
no external gate — or (c) its trigger is *fired by the next-five queue
completing* (the eval harness and the arbiter's tier declaration). The three
UNADOPTED rollups
([gust](../../exploration/gust/UNADOPTED-IDEAS.md),
[jidoka](../../exploration/jidoka/UNADOPTED-IDEAS.md),
[alp-river](../../exploration/alp-river/UNADOPTED-IDEAS.md)) contributed
nothing new here: everything left in them is evidence-, demand-, or
circumstance-gated, and those verdicts hold. The admitted items cluster on the
two gaps camus and ouroboros converged on independently — **the composer's
judgment layer trusts LLM self-reports end to end**, and **the front door
composes on unexamined premises** — plus the three thin capability wins the osa
and amber docs rated best effort-to-leverage. Convergence across unrelated
projects is the corpus's own strongest design-validation signal; it picked this
list.

These four inventories carry no Status lines yet (camus precedent: statuses
arrive with the first adoption pass) — **this queue is that pass**. Each item
ends by reconciling its source entry: add the Status line, correct any claims
the implementation falsified (the next-five queue's own habit — both its done
items shipped with corrections to their entries' claims), and update
cross-refs.

> **Riders on the in-flight queue — these land inside next-five #3 (AR-9 PR-3),
> not here; recorded so they don't slip:** camus **C3-5** (fold the
> plan-quality STANDARDS rubric into the challenger prompts; add `acceptance`
> to the planner's task schema — a dedicated field, not an overloaded carrier)
> and ouroboros **OB3-2** (the arming/trigger-matrix precedent for the
> `multi-plan` signal; label a same-model panel fallback honestly; if the
> arbiter memo carries confidence, consume it or drop it — never collect-and-
> ignore).

**Effort legend**: XS ≤ 2h · S ≤ 1 day · M 2–4 days · L ~1 week. File:line refs
are as-of 2026-07-02, inherited from the source inventories (verified there;
re-verify at build time).

| # | Wave | Item | Source | Effort | Shape |
| --- | --- | --- | --- | --- | --- |
| 1 | A | Headless one-shot + CLI session resume — ✅ DONE 2026-07-03 | osa OS1-5 (+ CC2-2 rider) | S | One session |
| 2 | A | Doom-loop guard — ✅ DONE 2026-07-03 | osa OS1-2 | S | One session (pure module + pipeline hook) |
| 3 | A | Lua code-mode pair (`lua_docs`/`lua_query`) — ✅ DONE 2026-07-03 | amber AM-1 (+ jidoka V2-7 hardening) | S–M | Single PR (two tools + policy envelope) |
| 4 | B | Verdict normalizer (infra ≠ verdict ≠ inconclusive) — ✅ DONE 2026-07-03 | camus C1-3 | M | Single PR |
| 5 | B | Deterministic verify authority + sealed heads — ✅ DONE 2026-07-05 | camus C1-2 + C1-6(a) | M | 2 commits (verify stage / commit facts) |
| 6 | B | Honest terminal statuses + stall detection — ✅ DONE 2026-07-06 | camus C1-4 + C1-5 | M | 2 commits (fingerprints / gate + disposition) |
| 7 | B | Executor seam (cross-vendor review first config) | camus C1-1 | M–L | **Must be broken down — 4 PRs** |
| 8 | C | Ambiguity clarify loop | ouroboros OB1-1 | S–M | Single PR |
| 9 | C | Structured premises: acceptance criteria + lint | ouroboros OB1-2 | M | 2 commits (keys + lint / consumers) |
| 10 | C | Evidence floor (claims vs transcript) | ouroboros OB1-3 (+ camus C1-6c) | M | 2–3 commits |

**Sequencing.** Wave A (#1–3) is filler-grade and independent of everything —
including the still-running next-five items, so these can interleave now. Wave
B (#4–7) is the verification program: strictly 4 → 5 → 6; #7 can start any time
after #4 (its normalizer is the deposit-tool contract) and is probably last as
the heavyweight. **None of Wave B depends on AR-9** (the camus doc's own
finding). Wave C (#8–10) is the front door: 8 → 9; #10 wants #4's vocabulary
and gets richer once #9's acceptance criteria exist (its `ShellCommand` masking
piece is independent). B and C are swappable, but B-first removes the one
cross-wave wait and gives #9's criteria a deterministic consumer. Total is
roughly **5–6 weeks — about double the next-five program** — so treat each wave
as its own commit/decision point and re-check this doc's premises at each
boundary. The next-five cron rule carries over: **if a stuck cron job shows up
while this program runs, the async-dispatch + watchdog pair replaces a Wave-A
item** (and re-opens `overlap: :skip|:allow` — adopt them together).

---

## 1. Headless one-shot + CLI session resume — S (osa OS1-5) — ✅ DONE 2026-07-03

> **Done 2026-07-03**, with corrections to this entry's claims (mirrored into
> the source entries — osa OS1-5 + OQ-4, osa-claude-code CC2-2): (a) "thin
> plumbing over shipped substrate" was two-thirds true — the CLI plumbing and
> the most-recent-session read were thin, but "the Worker already hydrates
> `state.messages`" is **view-only**; nothing seeded `Jido.AI.Context` from
> Postgres, so a resumed session looked resumed while the model remembered
> nothing. The net-new mechanism is `JidoClaw.Conversations.ContextRestore`
> (chat-transcript-only `ai.react.context.modify` `:replace`/`:restore`,
> `refs.request_id` preserved so per-agent compaction snapshots keep filtering
> after resume), generalized into **`chat/4`** — not `chat/3` as written — via
> `context_restore: :best_effort | :strict` (strict for explicit
> `--session`/`--continue`: a user who asked for history never gets a silent
> amnesic turn; side effect: cron `:main` sessions became restart-resumable for
> free). (b) Resume had to carry the session's own `kind`/`external_id`
> through `unique_external`, and one-shot runs got a new **`:cli_run`** kind so
> `--continue` (= newest OPEN `:repl`/`:cli_run` on the workspace, plus a
> workspace-ownership guard on `--session`) can never resume a web `:api`
> thread. (c) Step 1's "exit code from the outcome envelope" needed a real
> contract — OQ-4 pinned as `0/1/2/3` (success / error·failed·timeout /
> usage·config / gate-pending), with `composer_ack: :detailed` added to
> `chat/4` so the runner gets the parent run id structurally, awaits it by
> polling (`RunAwait` — composer-parent terminals don't broadcast), and probes
> gates via `pending_for_session` (inline gates are invisible in the return)
> plus the new `pending_for_run_tree` (the parent stays `:running` while a
> child wave parks). (d) The CC2-2 rider shipped as both halves of a
> prefix-identity test (system bytes via shared `Startup.resolve_prompt/2`;
> tools wire-order via `Config.reqllm_tools/1`), scoped honestly to the
> native/no-MCP set + resume-neutrality.

The best effort-to-leverage item on the osa list, and both halves are thin
plumbing over shipped substrate: `JidoClaw.chat/3` is already what cron and the
web surface call, sessions are durable, and the Worker already hydrates
`state.messages` from Postgres when rows exist (`repl.ex:214-218`) — but every
non-flag arg to `mix jidoclaw` drops into the interactive REPL and every boot
mints a fresh `SessionId`.

**Plan:**

1. `mix jidoclaw run "<prompt>" [--format text|json] [--session <uuid>]
   [--continue]` → resolve project, boot without the REPL UI, `ensure_session`
   (existing UUID or fresh), `JidoClaw.chat/3`, print, exit code from the
   outcome envelope.
2. REPL side: `--resume <uuid>` / `--continue` (most recent session for the
   workspace) plus a `/sessions` list.
3. Pin osa OQ-4 (the headless approval contract) as part of this item: a gated
   tool in a non-interactive run prints the pending `AgentCase` id and exits
   with a distinct code — the gate family already returns `:approval_pending`;
   this is purely an exit-contract decision.
4. **CC2-2 rider at resume time**: whatever constitutes our cached prompt
   prefix must be reconstructed byte-identically on resume, or every resume
   pays a silent `cache_creation` regression. Add the test that resumes a
   session and asserts prefix identity (the `deferred_tools_delta` lesson —
   the one genuinely wired thing in osa-claude-code).

**Payoff beyond ergonomics:** scriptability — CI checks, cron-from-shell,
external harnesses, piping — and the entry point #7's canary rider and the eval
harness both want.

## 2. Doom-loop guard — S (osa OS1-2) — ✅ DONE 2026-07-03

> **Done 2026-07-03**, with corrections to this entry's claims (mirrored into
> the source entry, osa OS1-2): landed as `JidoClaw.Agent.LoopGuard` (pure core
> + fail-open facade) + `LoopGuard.Store` (per-`{tenant, session, agent}`
> KeyStates keyed via `Compactor.Identity`; in-memory, **per node**), wired
> into `Tools.Action` after the approval gate — pre-execution `check` (the 4th
> identical call / 101st call never runs; an improvement over OSA's post-batch
> check) + post-normalize `observe_result` (skip-lists approval/doom envelopes
> as non-executions). Corrections: (a) step 1's contract shape shipped, but as
> our redesign — OSA folds the nudge into `:ok` via system-message injection +
> a pdict counter; (b) "reset on any clean success" was OSA's *moduledoc*, not
> its code (which never cleared) — we shipped **per-tool** clearing so the
> edit-fail→read-ok→edit-fail repair loop still accumulates; (c) step 2's
> "pipeline … already sees every call + normalized error" holds only for calls
> reaching `run/2` — param-validation/timeout/exception/output-validation
> failures are documented, test-pinned residuals; (d) `(tool, args_hash,
> error?)` shipped typed: SHA-256 over deterministic ETF (not `phash2`), typed
> error classification incl. both error-bearing OK shapes — run_command's
> nonzero exit (directive appended to `output`, not `message`) and the MCP
> proxies' re-surfaced `{:ok, %{"isError" => true}}` domain failures
> (directive appended as a `content` text item) — no `@error_indicators`
> sniffing; (e)
> the halt envelope carries `details: %{retry: false, trigger: …}` — proven
> non-retryable at BOTH retry layers by an Exec/Turn-driven contract test
> (`:doom_loop` is outside jido_ai's whitelist AND jido_action defaults
> unknown-code maps to retryable without the hint); (f) the property tests
> (step 4) are the repo's first. Halt decay: sticky 5 min (`halt_ttl_ms`) then
> full key reset; idle keys expire after 30 min; cap is per key **per node**.

The only guard on the tool loop today is jido_ai's soft nudge on *consecutive
identical* signatures — no failure-awareness, no window (A-B-A-B oscillation
passes), no hard stop short of `max_iterations: 25`. Unattended surfaces (cron
`:agent` jobs, MCP-driven turns, composer stage agents) can burn real budget
re-running a failing tool.

**Plan:**

1. `JidoClaw.Agent.LoopGuard` — pure
   `check(window, opts) :: :ok | {:nudge, directive} | {:halt, reason}` over
   recent `(tool, args_hash, error?)` tuples. Port all three osa mechanisms:
   identical-call window (4-in-8, success-agnostic — catches useless-success
   loops), failure signatures (3-in-20, reset on any clean success), absolute
   per-session cap (100, warn at 80%).
2. Feed from the shared `Tools.Action` pipeline (which already sees every call
   + normalized error), per-`{tenant, session, agent}` sliding window in
   tracked state — not the process dictionary (their integration is the part
   we rewrite).
3. Staged response: recovery directive as tool-result payload up to twice
   (signatures cleared each time), then a non-retryable
   `{:error, %{code: :doom_loop}}` envelope — same shape as the approval-gate
   errors, so the loop terminates cleanly.
4. Port the suggestion table + thresholds verbatim (attribution:
   `Miosa-osa/OSA @ f60e933b, Apache-2.0`); emit `:guardrail` Trace events;
   property-test the windows (reset-on-success, consecutive vs windowed).

## 3. Lua code-mode pair — S–M (amber AM-1) — ✅ DONE 2026-07-03

> **Done 2026-07-03**, with corrections to this entry's claims (mirrored into
> the source entry, amber AM-1): shipped as **`lua_query`** + `lua_docs`
> (operator decision — the entry's own title said `lua_eval`, colliding with
> the dep's generic action name) with **six** bindings, not four: the sketched
> `jido.runs/events/cases/solutions` plus `jido.run(id)`
> (`WorkflowView.snapshot/2`) and `jido.output(ref, opts)` (stored tool-output
> slices behind fetch_output's S-M2 scoping, via the extracted shared
> `Tools.OutputRef`). Corrections: (a) **the VM is not Luerl** — `lua
> 1.0.0-rc.3` is a from-scratch pure-Elixir VM (Luerl backed only `≤ 0.x`),
> and its deterministic budgets (`max_instructions`, `max_string_bytes`,
> absent from LuaEval) are wired as policy caps; (b) step 1's "ToolApproval →
> redaction → shaping → cap wrap it automatically" **overstated the cap**:
> `OutputLimit` bounds string *leaves* only and the shaper never touches this
> tool, so the Runner enforces its own aggregate `max_result_bytes` (32KB)
> bound on the final envelope — over-cap results ERROR (`:lua_result_too_large`),
> never silently truncate; (c) the default sandbox misses `print`/`debug` —
> `print` writes model-controlled text to host `IO.puts` past the redaction
> boundary — so both are sandboxed post-`Lua.new`; (d) budget refusals are
> latched in `CallTrace.refused?/1` and re-checked **post-eval** because
> in-script `pcall` can swallow the refusal raise; (e) jidoka's
> `max_parallel_calls` dropped (no parallel host calls), `:lua_timeout` made
> non-retryable (same script + same caps re-times-out — deviation from
> LuaEval), and the solutions binding is **lexical-only** via a new
> `resolve_embedding?: false` Matcher opt (a read-only sandbox must not
> trigger Voyage egress/cost).

The amber doc's gem, Path A (no new deps): the VM is already a hard dep
(`lua 1.0.0-rc.3` via jido_shell) and the hardened eval action
(`Jido.Tools.LuaEval`: timeout+kill, `max_heap_bytes`, call-depth, deadline
propagation) compiles in-tree and is registered nowhere. Today an MCP client
composing a cross-run question pages `workflow_events` and correlates in model
context; this collapses it to one scripted read.

**Plan:**

1. `JidoClaw.Tools.LuaQuery` (`use JidoClaw.Tools.Action`, so
   ToolApproval → redaction → shaping → cap wrap it automatically): Lua VM +
   LuaEval's hardening lifted wholesale; a small host-function table bound to
   explicit **read-only** code-interface calls — `jido.runs(filter)`,
   `jido.events(run_id, opts)`, `jido.cases(filter)`, `jido.solutions(query)`
   — each closing over `tenant`/`session` from `tool_context` (present-nil
   coercion per the ToolContext trap).
2. Sibling `lua_docs` rendered **from the same binding table** (single-source
   capability + docs — the `Stage.to_map/1` / G2-1b precedent).
3. Bound reach with jidoka V2-7's `Lua.Policy` envelope on top of the resource
   caps (they limit different things): per-eval host-call budget (12),
   script-size cap (6KB), a read-only-bindings invariant asserted at
   registration, and a `call_trace`-style audit emitted as Trace events.
4. Publish to the served MCP list and register for the in-REPL agent. Gate
   policy: read-only bindings ⇒ not require-listed; the day any write binding
   lands, require-list the tool (same as `replay_workflow`).

**Scope notes:** `ash_lua` as a dep stays blocked (`lua ~> 0.3` vs our locked
`1.0.0-rc.3`); V2-7's plan-authorship verdict stays untouched (this computes
reads, authors nothing).

## 4. Verdict normalizer — M (camus C1-3) — ✅ DONE 2026-07-03

> **Done 2026-07-03**, with corrections to this entry's claims (mirrored into
> the source entry, camus C1-3): shipped as `JidoClaw.Orchestration.Verdict`
> (envelope + behaviour + `format_reason/1` bounded renderer) with two kind
> modules (`Verdict.Review`, `Verdict.IterativeEval`), the emission `outcome`
> carrier (`StageEmission` — fail-closed decode on the DB trust boundary), the
> `:stage_infra` / `:route_review_infra_failed` durable vocabulary, and both
> composer lanes. Corrections: (a) `parse_verdict/1` was at clauses :134-154
> (spec :133), not ":133-154" — now **deleted**, subsumed by
> `Verdict.IterativeEval` (map/text parsing preserved incl. last-token-wins);
> (b) the "malformed verdict → failed iteration" framing **understated the
> composer half**: `DefaultMapper.verdict/2` dispatched on output *shape*, so
> a reviewer whose `overall` drifted out of enum silently emitted an EMPTY
> emission — the lens never went clean and the run mis-terminalized
> `:not_converged` (never `:route_failed`), and a degenerate `request_changes`
> with zero findings summoned the fixer with empty feedback, burning
> `rerun_cap` toward a false `:fix_failed`; the fix dispatches on **lens
> presence, not shape**. (c) Step 2's "decrements a separate infra-retry
> budget" shipped per-STAGE (`infra_counts`/`infra_cap`, default 2 ⇒ 3
> attempts = camus's total) and **persisted in parent config** so a restart
> keeps a caller's override (`rerun_cap` still has that gap — noted, not
> swept). Scope grew by operator decision: the self-contradiction guard covers
> ANY non-approve (`request_changes` OR `comment`) with zero findings; a
> **lens-only cohort's wave-execution error** rides the same infra budget
> (Lane B, incl. the recovered-failed-child dedupe arm and — post-review P1
> fix — the dedupe-hit observe arms, observed-failed / observe-timeout /
> observe-reload, which pre-fix bypassed Lane B to a generic `route_failed`
> purely on failure timing relative to a restart; `closed_wave_index`
> closes the failed wave for rebuild AND `Observe`/`WorkflowView` — mixed
> cohorts keep `route_failed`); Review field coverage is routing-critical-only
> (camus-faithful; prose fields pass through). `{:inconclusive, _}` is typed +
> consumed defensively; #5 (done 2026-07-05) is now its live producer. Rider
> C2-8 landed as `docs/TRUST-BOUNDARIES.md` (five laws + the materialized
> durability checklist) with the AGENTS.md pointer.

First of the verification program because everything downstream lands on it:
there is no single normalization module for judge outputs, and the crucial loop
rule is missing — `IterativeStep.parse_verdict/1`
(`skills/steps/iterative_step.ex:133-154`) treats a malformed verdict as a
failed iteration, exactly the infra-vs-verdict conflation camus names the #1
cause of runaway loops.

**Plan:**

1. `JidoClaw.Orchestration.Verdict` envelope + normalizer behaviour:
   `normalize(stage_kind, raw) :: {:verdict, %Verdict{}} | {:infra, reason} |
   {:inconclusive, reason}`, fail-closed rules lifted from camus `adapter.py`
   — nonzero exit, empty/unparseable output, out-of-enum verdict, missing
   findings list, out-of-range priority (refuse to silently demote), and the
   self-contradiction guard ("patch is incorrect" with zero blocking findings
   is an *infra* error).
2. Composer loop consumes it: `{:infra, _}` decrements a separate infra-retry
   budget (camus: 2) **without touching the stage `rerun_cap`**, then
   terminalizes as a distinct `review_infra_failed` disposition — never
   `:fix_failed`, never clean. Emit `:infra` occurrences as Trace events.
3. Route `IterativeStep` through the same normalizer (the named live bug).
4. **Rider — camus C2-8:** land the five trust-boundary laws as a short docs
   section (AGENTS.md or `docs/`), cross-linked to the durability checklist —
   the acceptance frame for this item and #5. Costs a paragraph.

**Note:** hermes T1-4 (the provider-level sibling taxonomy) stays NOT_ADOPTED —
camus's judge-boundary version is narrower and independently adoptable first.
This normalizer is also #7's deposit-tool contract; build it with that consumer
in mind.

## 5. Deterministic verify authority + sealed heads — M (camus C1-2 + C1-6a) — ✅ DONE 2026-07-05

> **Done 2026-07-05**, with corrections to this entry's claims (mirrored into
> the source entries, camus C1-2 + C1-6): shipped as
> `JidoClaw.Orchestration.Verify` (+ `Envelope`/`Git`/`OsCmdRunner`/`Config`),
> the catalog's `{:verify, "default"}` stage (`Reactors.VerifyStage`, a
> NON-halting module reactor — the gate shape minus the park), the
> `:route_verify_tampered` terminal + `:stage_tampered`/`:head_observed`/
> `:verify_certified`/`:verify_report_recorded` marker vocabulary, the
> `verify_oath` doctrine slice (+ `lua_query`/`lua_docs` on the three judges,
> the OH1-3 rider), and `Tools.GitCommit`'s engine facts (C1-6a). Corrections:
> (a) step 2's envelope is richer than sketched (`checks[]`,
> `integrity_note`, per-failure `exit`/`reason`, `mode`/`tree_digest`/
> `sealed_head`) and runs TWO modes — camus's sealed model applies only when
> an engine-observed `sealed_head` exists; today's non-committing routes get
> a `working_tree` mode (dirty-before is a FACT, integrity = HEAD stability +
> a content-addressed `git diff --binary` digest); (b) camus's degrade-OPEN
> on failed git capture is corrected law-4-side: a would-be green with a
> failed capture is `integrity_unavailable` INCONCLUSIVE, never a pass;
> (c) "refuse loudly" = a loud inconclusive envelope riding the #4 infra
> lane (config errors too — never a wave failure), not a raise; (d) step 3's
> "convergence requires pass whose head matches" shipped as the welded
> `:verify_certified` marker + an uncertified-green reclassification BEFORE
> the fold + a convergence-time MODE-SPECIFIC re-check (retract + re-verify
> on mismatch/unreadable, bounded by `rerun_cap` → `:verify_failed`);
> (e) "wire as a stage" needed a NEW peel — Kahn leveling co-locates verify
> with the reviewers, so `Loop.defer_solo_verify/2` (the INVERSE of the gate
> peel) makes it run last; (f) the OR2-2 rider folded in as config shapes
> (`verify:` `checks:` registry + per-run override persisted in parent
> config; unknown-name override refuses loudly; camus wins over orca on
> timeout ⇒ inconclusive), not as new event kinds — first-fail-stops is
> inherent (a red blocks convergence); (g) OH1-3's forced-verdict-at-cap is
> satisfied engine-side (cap exhaustion always terminalizes a named
> disposition), no new machinery. No shell, ever: argv-list commands via
> `Core.OsCmd` with execvp-style argv0 resolution. OQ-4's design note lives
> in `Verify.Config`'s moduledoc; the camus C2-7 mid-run config-edit freeze
> is a documented parked residual.

The camus doc's "single most valuable item." Verification never gates on an
exit code today: the verifier *agents* run `mix test` and self-report, the loop
authority reads the LLM's interpretation, and nothing head-binds a green or
detects the tree changing around a verification — the run-6 cover-up class
(verifier edits the code under verification) is undetectable in our current
shape. We hold the structural advantage camus lacks: our engine can run the
command and read the exit code itself.

**Plan:**

1. Pin camus OQ-4 first (a short design note): verify-command source of truth
   is `.jido/config.yaml` `verify_cmd:` per project, `mix precommit` as this
   repo's default, refuse loudly when nothing resolves.
2. `JidoClaw.Orchestration.Verify` (engine-side, no LLM): run the gate command
   with a timeout; emit the camus envelope
   `{pass, inconclusive, tampered, failures[{stage, kind, log_tail}], head}`
   with `head` from `git rev-parse HEAD` and a before/after tracked-porcelain
   snapshot. Classification table lifted from `verify.py`: exit 127 →
   `missing_tool`, timeout sentinel → `timeout`, "no tests" → `no_tests` — all
   inconclusive-not-failed; `uncommitted_state`/`tracked_mutation`/`head_moved`
   are RED, never inconclusive; no-verifier-resolves is loud, never a pass.
3. Wire as a composer *stage that is not an agent* (gates prove the catalog
   models those); the envelope lands in a `WorkflowEvent`; code-path
   convergence requires `pass: true` whose `head` matches the sealed head.
4. **C1-6(a) — sealed heads:** `Tools.GitCommit` (and any composer commit step)
   appends engine-derived facts — rev-parse before/after, `committed?` ⇔ head
   moved, staged-empty as an explicit `:no_changes` outcome — stamped into the
   event, and convergence records `sealed_head`.
5. LLM verifier workers stay for *diagnosis* of a red, never the verdict; lift
   `VERIFY_OATH` verbatim into any prompt where a verify must run through an
   agent anyway (remote/system path).

**Scope notes:** C1-6(c) (worker `files_changed` vs porcelain) deliberately
moves to #10; C1-6(d)/(e) (receipt rows, gate-owned git flags) wait for the
AR-10 shipping tail, per the source entry.

**Rider — orca OR2-2 (added 2026-07-04,
[inventory](../../exploration/pms/orca/FEATURES-WORTH-BORROWING.md)):** orca
ships this item's shape as product — fold in its wiring details (named gate
registry + per-phase attach + per-unit override resolution;
`GateStarted`/`GateRan` events carrying `triggering_phase_run_id` provenance;
first-fail-stops-progression) and invert its one anti-pattern: an unresolvable
gate name must fail loud, never silently skip.

**Rider — OpenHelm OH1-3 (added 2026-07-04 connective pass,
[inventory](../../exploration/pms/openhelm/FEATURES-WORTH-BORROWING.md) /
[first wave](../../exploration/pms/openhelm/OH-FIRST-WAVE.md)):** give the judge
**read-only deterministic tools** rather than transcript-only input (our
`lua_query` is the natural vehicle — sandboxed, lexical-only, tenant-scoped);
cap the judge and **force a committed verdict at the cap** (their
`run-verifier.ts:42-64`) — never a silent failure.

## 6. Honest terminal statuses + stall detection — M (camus C1-4 + C1-5) — ✅ DONE 2026-07-06

> **Done 2026-07-06** (C1-5 + C1-4 + the C3-2/OQ-1/BO2-6/OH1-3/TR1-2a→PD1-1
> riders), with corrections to this entry's claims (mirrored into the source
> entries): (a) step 1's "`seen_keys`/`prior_keys` are derivable from wave
> artifacts already in the event log" is **FALSE** — findings persist as
> encrypted `ComposerArtifact` rows the projection never decrypts, so the
> cross-wave identity rides a welded `:finding_keys` marker (hex keys + enum
> marks only — redaction posture) that the projection folds; (b) step 2's
> "rides the T2-5 Spark DSL" understates the novelty — the composer parent is
> a GenServer (`workflow_type: "composer"`, no Reactor checkpoint) and an
> `:awaiting_approval` composer row is recovery's dangling-gate arm, so C1-4
> shipped as a **parent-stays-`:running`, child-less park** (`ReviewStallGate`
> is presentation-only) + kind-dispatched `Cases.decide`/`abandon` branches —
> never `GateStep`/`GateResume`. Decisions as ratified: finding identity =
> required short `title` + `FindingKey` (`{:v1, file, title}` through
> `CanonicalHash.sha256_term/1`; title downcased, file NOT; un-keyable
> findings excluded from stall detection); orca OQ-1 — severity stays
> descriptive and the release decision is **per-finding waive records,
> all-or-reject** on the gate (`{:error, :incomplete_waiver}` short of
> complete coverage, never auto-reject), recorded on the case's `:approved`
> timeline event — the BO2-6 debt ledger (`Cases.waived_findings_ledger/2` +
> the `jido.debt` Lua binding). The gate fires only on a **green AND
> certified** #5 verify (`verify_green_certified?/1`); verify-less/red routes
> keep today's terminals (a red-verify stall lands `fix_failed` via the
> `finish_fixish` fall-through). Headless CLI exit for `done_with_findings`
> stays **0** (OQ-4 pinned), disposition marked in text + JSON. Scope grew by
> operator decision: rider 6 executed exactly as its superseded note says
> (PD1-1's fused stability contract + the PD2-1 slim `jido://bootstrap`
> shipped here — `SurfaceVersion`, app-version `server_info`,
> `jido://_meta/version`, the served-surface golden), and #4's flagged
> `rerun_cap` persistence gap is closed (persisted beside `infra_cap`,
> restart-proven). Detection deviations recorded in the camus entry:
> whole-Hook-R suppression on a stop (not just the fixer weld); no named
> `review_stalled?/1` (composed `fix_stop_lenses/1`); marks decode asymmetry
> (emission boundary fails the whole block closed, projection drops entries).

Today every composer disposition projects into the `:failed` family — a run
whose fix loop capped out with a *green verify* is indistinguishable in kind
from one that never compiled — and findings have no cross-wave identity, so a
stale flag or a genuine impasse consumes every rerun before terminalizing.
Nearly free here because the squidie gate/case machinery is exactly the right
substrate; what's missing is one gate kind, two dispositions, and a
fingerprint.

**Plan:**

1. **C1-5 first (it's the trigger feeder):** per-finding canonical fingerprint
   computed engine-side — normalize file path + title, drop line numbers (they
   shift under fix diffs), hash the canonicalized term (the squidie T1-3 house
   rule, not a rendered string). Keep `seen_keys`/`prior_keys` per lens in
   projected state — derivable from wave artifacts already in the event log,
   so resume-safe for free. Rules verbatim: repeat-across-consecutive-waves →
   stuck; reappear-after-absence → oscillating; never dispatch a fix wave the
   route has no re-review budget to check.
2. New `HumanGate` kind `review_stall` (rides the T2-5 Spark DSL): raised on
   rerun-cap exhaustion *or* a C1-5 stop **and** a green #5 verify; the case
   carries the surviving findings + the certified `head` (+ the
   confidence-trend garnish, advisory only).
3. Approve = land: the run completes off the already-proven artifacts, no
   re-implementation, terminal disposition `done_with_findings` — projecting to
   `:completed` with `result.disposition` set (camus OQ-2's disposition-first
   answer; promote to a DB status only if surfaces need to index on it).
   Reject = `:fix_failed` as today.
4. Surface rule ported everywhere (REPL `/gates`, web dashboards,
   `workflow_status`/`inspect_workflow`): an aggregate containing a
   findings-deferred run is itself marked, never plain green.
5. **Rider — camus C3-2:** a `resume_hint` field on gate cases (populated by
   the raising stage, rendered verbatim on all surfaces) — trivial once the
   new kind exists; the camus doc says "do it with C1-4."
6. **Rider — ades/traycer TR1-2a (added 2026-07-03,
   [inventory](../../exploration/ades/traycer/FEATURES-WORTH-BORROWING.md)):**
   the MCP served-surface golden test — freeze the served tool-name list +
   `jido://` resource URIs against a committed fixture (traycer's
   released-surface discipline; editor clients already consume this surface,
   and this item's step 4 touches those tools' outputs — names, not output
   shapes, so no conflict). ~1h, zero dependencies; good same-session filler.
   Coordination note while in the gate family: argus §5's `:review` kind
   extends the same `Gate.Kinds` list `review_stall` joins — design the
   disposition vocabularies together (traycer TR3-2's `superseded` belongs in
   that conversation; second lander rebases a one-line list edit).
   *(Superseded as a standalone build 2026-07-04: pad PD1-1's fused
   stability-contract PR — [PD-FIRST-WAVE item 1](../../exploration/pms/pad/PD-FIRST-WAVE.md)
   — absorbs this golden test and adds the advertisement half (surface-version
   constant, handshake/meta exposure); build that instead, then stamp the
   traycer TR1-2(a) slice's Status PARTIAL per the pad first-wave's note.)*
7. **Rider — orca OQ-1 (added 2026-07-04,
   [inventory](../../exploration/pms/orca/FEATURES-WORTH-BORROWING.md)):** that
   same disposition conversation gains a concrete question — does finding
   severity grow a release-semantics axis (orca ships `blocking|advisory` in
   the verdict itself) or does the release decision stay on the gate
   (per-finding waive/ack at decision time), preserving C1-3's findings-win
   conservatism? Decide once, for `review_stall` and argus `:review` together.
8. **Rider — bosun BO2-6 (added 2026-07-04,
   [inventory](../../exploration/pms/bosun/FEATURES-WORTH-BORROWING.md)):** the
   disposition conversation also gains the field's shipped middle-terminal
   vocabulary — bosun's `accept_with_debt` + severity-counted debt ledger is
   `done_with_findings` as product (make the waved-through findings a queryable
   ledger view — a filter over gate decisions in the event log, no new table);
   its `reprompt_same | reprompt_new_session | new_attempt` split is a cleaner
   retry vocabulary than a binary rerun; and its attempt-cap escalation
   (`attemptCount >= 4` ⇒ `manual_review`) is a shipped trigger shape for
   `review_stall`.
9. **Rider — OpenHelm OH1-3 (added 2026-07-04 connective pass,
   [inventory](../../exploration/pms/openhelm/FEATURES-WORTH-BORROWING.md)):**
   the `partially_succeeded` / `permanent_failure` split with an **enforced
   transition table** (`db/queries/runs.ts:48-57`) is the shipped field shape
   for this item's dispositions — `succeeded` accepts no further transitions.
10. **Rider — pad PD3-3 (added 2026-07-04 connective pass,
    [inventory](../../exploration/pms/pad/FEATURES-WORTH-BORROWING.md)):** the
    rider-6 disposition-vocabulary conversation (where traycer TR3-2's
    `superseded` already sits) gains pad's derived-closure lineage badges — an
    item pointed at by a terminal `supersedes`/`implements` link renders
    closed-as-`superseded_by`/`implemented_by`, computed display-only, while
    `split_from` deliberately does not auto-close.

## 7. Executor seam — M–L, must be broken down (camus C1-1)

> **PR-1 (template binding + `:fake`/`:shell` executors) DONE 2026-07-06**, with
> corrections to this entry's claims — the item-level Status and the camus C1-1
> source reconciliation wait for PR-4: (a) "`AgentRunner` branches on it"
> understated the envelope — both arms share one tool-context builder + the
> extracted `run_recorded` never-crash envelope (correlation BEFORE any Forge
> resource exists; task/terminal transcript rows uniform across executors), and
> the forge arm must **publish the terminal signal itself**
> (`ai.request.completed`/`failed` — `Conversations.Recorder`'s flush barrier
> and the correlation finalizer wait on a signal only the in-process
> AgentServer emitted; without it every forge step stalls a full flush timeout
> at `record_terminal`; PR-2 inherits the fix via `run_forge`). (b) The binding
> grew a second key — `executor_config:` (a map, so PR-2 adds keys without a
> new top-level field; PR-1 uses only `%{command: _}` for `{:forge, :shell}` —
> operator config in the `verify_cmd` trust class, never the stage task, and a
> command-less shell template is refused at hydration); validation **raises**
> (the `:max_iterations` loud posture, not fc/ra/sandbox's warn+fail-closed —
> the tight direction here is refuse-to-run), the full five-kind union
> hydrates with dispatch refusing the unbuilt kinds ("not implemented until
> PR-2"), and a `{:forge, _}` executor refuses a `:prototype`/`:docker`
> `:sandbox` policy (the VFS-jail axis is dead on a forge session; PR-2's
> session-sandbox knob lives in `executor_config`). (c) "hands the eval
> harness deterministic fake-backed stages" needed finer-than-template fixture
> keys — real catalogs reuse one template across stages — so
> `:executor_fake_outputs` resolves `{:stage, template, step_name}` →
> `{:fragment, template, fragment}` (exactly-one contain-match, else fail
> closed) → plain template, ANY tuple key disabling the plain fallback (the
> composer StubWorker rule as lib code), all resolved before provisioning;
> fake/stdout output is schema-validated against the template module's
> declared `output` with live-faithful failure consequences (lens stage ⇒ #4's
> infra lane, producer ⇒ result-text artifact fallback — never a fabricated
> verdict). Payoff proven: a `:composer` eval case converges through the real
> `DefaultMapper`/`Verdict` flow armed by `:agent_templates_override` +
> `:executor_fake_outputs` alone — neither `:step_agent_server` nor
> `:route_composer_stub_outputs`. (d) Sessions are real minimal Forge sessions
> (`claim: false`, `sandbox: :local` ⇒ HostShell even under a prod
> `FORGE_SANDBOX=docker`, `start_session_ready(expected_backend:)`, result
> captured before the `try/after` `stop_session`); the spec carries
> `workspace_uuid`, never the runtime `workspace_id` string (the front-door
> `forge_exec_spec/3` precedent — `Persistence.scope_from_spec/1` casts it to
> the Session's `:uuid`). (e) The cost note's residual is now concrete: Forge
> `Manager` per-runner caps (`shell: 20`; module runners like the new generic
> `Forge.Runners.StaticFake` fall to `max_sessions: 50` — the consolidator's
> `Runners.Fake` untouched) can `:runner_at_capacity` a wide parallel wave —
> a per-step error, not a crash. "Untouched templates stay byte-identical"
> holds at the raw source and in-process behavior; hydrated maps gain
> `executor: :in_process` + `executor_config: %{}` (test-pinned).
> `:needs_input` maps to a step error until PR-4's gate case; telemetry
> counter `jido_claw.executor.total`.

> **PR-2 (the Forge-backed vendor path) DONE 2026-07-06**, with corrections to
> this entry's claims — the item-level Status and the camus C1-1 source
> reconciliation still wait for PR-4: (a) "validates against the template's
> output schema" is really the compile-time-normalized `%Jido.AI.Output{}`
> from `strategy_opts()[:output]` (`Output.parse/2` — maps AND binary JSON,
> string keys coerced), validated **in the per-step `Deposit` box** at deposit
> time (invalid ⇒ bounded MCP `isError`, the CLI fixes and retries in-session;
> valid ⇒ last-valid-wins); "**through #4's normalizer**" holds at
> `DefaultMapper`'s existing lens dispatch — normalize-at-deposit is not
> well-defined (producers have no normalize kind), so a no/invalid-deposit
> lens stage lands `typed: nil` ⇒ `normalize(:review, %{})` ⇒ the infra lane
> (eval-pinned: a drifted `overall` exhausts `infra_cap` into
> `review_infra_failed`, never a verdict). Single-channel per camus OQ-1(c):
> CLI stdout is never parsed into typed — it feeds `ARTIFACTS:` extraction
> and the no-deposit fallback text only, and a valid deposit is ALSO the
> transcript projection (typed summary, not raw stream-json). (b) The scoped
> machinery generalized OUT of the consolidator rather than beside it:
> `JidoClaw.MCP.{ScopedEndpoint, ScopedForward, LoopbackClient}` with the
> consolidator migrated and its `MCPEndpoint`/`Plug.RunForward` deleted —
> superseding PR-1's "`Runners.Fake` untouched" (it now rides the
> session-aware `LoopbackClient`, which sends the `notifications/initialized`
> the real lifecycle requires once a client echoes `mcp-session-id`). The
> deposit tool advertises via the JSON-Schema-map schema class (the MCP-proxy
> pass-through): the keyword `type: :map` form validates atom-keyed maps only
> and would reject every real string-keyed CLI deposit. (c) Hardwired
> read-only + isolation (operator decision 2): codex `-s read-only`; claude
> `--tools Read,Glob,Grep` + `--allowedTools`(+deposit tool) +
> `--permission-mode dontAsk` + `--strict-mcp-config`, `config_sync:
> :auth_only` (codex auth.json alone; claude credentials-only into an
> isolated per-run `CLAUDE_CONFIG_DIR` via exec-based writes, failing init
> CLOSED on a refused env inject). `workspace:` hydrates `:repo` default
> WRITTEN INTO the config (normalizing validators, P2a) with `:repo`
> requiring `project_dir` pre-flight; `:scratch`/`:none` differ only in the
> prompt note this wave. Vendor `timeout_ms` defaults 240s (clamped
> 30s–600s) — deliberately under the composer's 300s wave deadline (raising
> one means raising the other). Vendor prompts carry the FULL subagent
> contract (P1a): `Startup.subagent_prompt/3` (same `:doctrine` master gate)
> prepends `SubagentPrompt.build/3`, `catalog_stage_name` now threads down
> the forge arm (stage personas hold across the executor swap), deposit
> instruction LAST; redaction rides the runners' existing argv
> `PromptRedaction`. Resource acquisition is a total unwinding reducer (box →
> endpoint → forge home → client config; a partial acquisition tears down
> exactly what it acquired). `{:forge, :custom}` stays refused at dispatch
> (reworded — no roadmap PR named). (d) The **live smoke shipped three real
> fixes** (the build-time-verification gate earning its keep): (i) the shared
> client config now writes `"type": "http"` — claude ≥2.x reads a bare `url`
> entry as legacy SSE and never connects (the consolidator's old config had
> the bare shape); (ii) `HostShell.cli_exec_argv/2` (née `apply_ulimits/2`)
> always wraps the CLI-runner argv with `exec "$0" "$@" </dev/null` — OsCmd's
> port never delivers stdin EOF and `codex exec` reads piped stdin TO EOF, so
> every codex session (consolidator's too) hung until timeout; (iii) the
> codex `-c` inline table gained `default_tools_approval_mode="approve"` —
> codex ≥0.142 gates MCP tool calls behind a per-server approval whose
> default prompt is auto-cancelled headless ("user cancelled MCP tool call").
> `CLAUDE_CONFIG_DIR` isolation proved live and total: a fresh dir reports
> "Not logged in" on a fully-authenticated host (no fallback needed); both
> CLIs landed real deposits through the loopback endpoint under the read-only
> posture. Residual notes: the codex runner's `gpt-5-codex` default model is
> rejected on ChatGPT-plan accounts (operators declare `model` in
> `executor_config` or codex config); macOS hosts without
> `~/.claude/credentials.json` (Keychain auth) surface `:no_credentials` —
> the Linux/prod sync story is unit-pinned. No production template declares a
> vendor binding (PR-3's cross-vendor lane is the first declarer).

**Direction agreed 2026-07-02** (recorded in the camus doc's revision note):
build the seam, not the pairing. One hard binding stands between the shipped
substrate and the whole family — `AgentRunner` always spawns an in-process
worker from `Templates.get/1`, while Forge already holds the full session
contract, both vendor CLIs, and a proven headless driver (the consolidator's
`RunServer` + per-run MCP deposit pattern,
`memory/consolidator/run_server.ex:516-541`).

**Suggested 4 PRs:**

1. **PR-1 — template binding + in-process/fake (S–M) — DONE 2026-07-06:**
   `executor: :in_process (default) | {:forge, :codex | :claude_code | :shell
   | :custom | :fake}` in the `Templates` registry; `AgentRunner` branches on
   it; land `:fake` (and `:shell`) first — proves the seam cheaply and hands
   the eval harness deterministic fake-backed stages. Untouched templates stay
   byte-identical. *(Shipped as sketched plus the deviations in the note
   above; the seam lives in `Skills.Steps.ForgeExecutor`.)*
2. **PR-2 — the Forge-backed path (M) — DONE 2026-07-06:** session
   provisioning per the consolidator pattern; a `workspace: :repo | :scratch
   | :none` template knob; a scoped per-run MCP endpoint whose single deposit
   tool (`submit_structured_output`) validates against the template's output
   schema **through #4's normalizer** — schema drift is `{:infra, _}`, never
   a verdict. Read-only stages only in this wave. *(Shipped as sketched plus
   the deviations in the note above; the vendor arm lives in
   `Skills.Steps.ForgeExecutor`, the shared scoped-MCP machinery in
   `JidoClaw.MCP.{ScopedEndpoint, ScopedForward, LoopbackClient}`.)*
3. **PR-3 — cross-vendor review configuration (S–M):** the invariant enforced
   at resolution — a review-lens stage whose resolved executor shares the
   implementer's vendor is *held* (fail closed, mirroring `review.sh`'s
   unknown-backend refusal) unless the operator opts into degraded
   independence in `.jido/config.yaml`; fresh session per re-review wave; lift
   `review-prompt.md`'s adversarial persona + "correct but incomplete must NOT
   pass" completeness clause for the review templates; outbound prompt
   assembly passes the redaction root before egress to a second vendor.
4. **PR-4 — hardening residuals (S):** `needs_input` → gate-case mapping
   (first wave treats it as `blocked` → infra-retry); the write-capable-stage
   sandbox requirement; the remaining OQ-1 questions (workspace
   materialization, override precedence — coordinate any *stage-level*
   executor override with AR-9 PR-1's conditionally-put options shape so the
   two override mechanisms stay one shape).

**Cost note (from the source):** a Forge session per execution is heavyweight
next to an in-process spawn — template-level opt-in keeps the choice deliberate
(right for a handful of review/plan stages per run, wrong for high-frequency
stages).

## 8. Ambiguity clarify loop — S–M (ouroboros OB1-1)

The cheapest high-leverage start in the ouroboros doc: triage's `ambiguous`
early signal is defined (`triage/prompt.ex:53`), mapped (`front_door.ex:95`),
published into every route (`route_composer/catalog.ex:72`) — **and consumed by
nothing**. Detection already ships; only the response is missing. Plan-shape
risk (the reason AR-9 exists) is downstream of unexamined premises; this is the
cheaper, earlier intervention.

**Plan:**

1. Conversation-axis, no catalog change (ouroboros OQ-1's own
   recommendation): when the triage verdict carries `ambiguous` (start
   signal-gated — OQ-4; add a `significant-build ∧ no-criteria` trigger only
   if misses show up), the front door enters a bounded clarify loop (2–4
   questions/round, hard round cap) instead of composing. A
   `Triage.LLM`-pattern scorer (tool-less `generate_object`, `model:
   :capable`) scores the dimension set per round.
2. Port the constants verbatim with attribution
   (`Q00/ouroboros @ e905a41c, MIT`): weights (goal 0.40 / constraints 0.30 /
   success-criteria 0.30; brownfield adds context 0.15 and rebalances),
   per-dimension floors (0.75/0.65/0.70/0.60), threshold ≤ 0.2, 2-round
   stability streak.
3. **The deterministic anti-gaming floor from day one:** count open
   gaps/contradictory answers in loop state; take `max(llm_score, floor)` —
   one line that kills the self-grading failure mode.
4. On pass, fold answers into premises (#9's shape) and compose; on operator
   override or round cap, compose with `degraded: true` + `unresolved_slots`
   premises — the labeled-partial-product posture, and `scope-shift`
   self-reports get sharper targets for free.

**Rider — orca OR2-5 (added 2026-07-04,
[inventory](../../exploration/pms/orca/FEATURES-WORTH-BORROWING.md)):** shipped
field shapes for this loop — the ambiguity-ledger item (`{question,
why_it_matters, risk_if_unanswered, recommended_default_assumption,
user_input_required, status, user_answer}`), `readiness_status ∈
ready_for_tasks | ready_with_assumptions | blocked_needs_user_input`, and the
explicit accept-assumptions gate (unresolved `user_input_required` items block
accept unless the operator opts into the recommended defaults).

## 9. Structured premises: acceptance criteria + lint — M (ouroboros OB1-2)

The keystone entry — it upgrades three shipped mechanisms at once. The AR-9
PR-2 premises pipe carries launch *assumptions*, not criteria; certificate
`specification` is transient free text filled at call time; skill
`verification_criteria` is a hardcoded generic list.

**Plan:**

1. Typed optional premises keys — `"acceptance_criteria"` (list of strings),
   `"evaluation_principles"` (name/description/weight), `"exit_conditions"`,
   `"degraded"`/`"unresolved_slots"` — written by #8's clarify loop (or by
   triage for clear asks). Premises are durable composer state already; pin
   the JSONB round-trip shapes at the boundary and keep
   `PremisesContext.render/1` total — absent criteria render byte-identical
   prompts.
2. Port the GradeGate checks as a pure `Premises.Lint` (vague-term regex bank,
   the ~11 observable-AC patterns, >9-AC advisory; transcribed with
   attribution). Run before route composition: findings downgrade to a warning
   in the plan-gate payload; blockers loop back into #8's clarify round. Skip
   the template auto-repairer (its output reads as boilerplate; our loop has a
   human).
3. Consume on both ends: reviewer-lens stage tasks and `verify_certificate`'s
   `specification` read the criteria block from premises when present. Per-AC
   verdict fan-out (the `checklist_verify` shape) is deferred until the eval
   harness gives verdicts durable rows (OQ-2's map-first answer).
4. Reconcile the gepa cross-link when done: an AC that shipped with a run is a
   labeled eval-task candidate — this answers GP1-3's provenance question
   (gepa OQ-2) and feeds the item-5 harness case pool.

**Rider — orca OR2-5/OQ-2 (added 2026-07-04,
[inventory](../../exploration/pms/orca/FEATURES-WORTH-BORROWING.md)):** fold
orca's deterministic per-task quality gate into step 2's lint (their
`validate_task_quality`: ≥1 task, meaningful specs, relevant-files present —
one repair re-prompt, then fail loud), and reserve the acceptance-criteria id
linkage in step 1's schema so a criterion-mapped review payload (orca OR1-1's
`criterion_mappings`, argus §5.3's stretch shape) has a producer when it's
wanted.

**Rider — OpenHelm OH1-3 (added 2026-07-04 connective pass,
[inventory](../../exploration/pms/openhelm/FEATURES-WORTH-BORROWING.md)):**
reserve `outcome_spec`-shaped fields (`endState` / `check` / `stopBound`) for
the cron/automation producers — OpenHelm makes the contract **required at
creation** for agent-created jobs; creation, not review time, is the
enforcement point.

## 10. Evidence floor — M (ouroboros OB1-3, absorbing camus C1-6c)

Worker stages self-report through typed envelopes and prose, and nothing
cross-checks the claims against the transcript we already store durably
(`ToolOutput` full capture under refs; Trace events). The house
no-masked-gates rule ("pipes mask exit codes and have shipped a false green
before") exists only as memory — ouroboros codified the same rule as an
analyzer.

**Plan:**

1. Pure `JidoClaw.Verify.Evidence`: given a stage's claims and the wave's
   tool-call records, classify each claim
   `supported | unsupported | form_mismatch` — deliberately excluding the
   agent's final self-report from the evidence base, so claims can't support
   themselves. The conservative override rule governs everything: only ever
   flip a *claimed pass* on a positive discrepancy ("can't verify ⇒ trust the
   agent").
2. Producer side: the coder/fixer Envelope gains an optional `evidence` block
   (`commands_run`/`files_touched`/`tests_passed` — string lists, per the
   Envelope round-trip rule), requested via a doctrine slice (the AR-5 seam —
   pairs with `confidence_tagging` and the next-five `code-doctrine` slice).
   Absent block ⇒ posture unchanged.
3. Consumer side: the review wave receives the classification;
   `FABRICATION_SUSPECTED` findings route into the existing AR-4 fix loop —
   never a hard executor gate (heed ouroboros's own #1202 rollback: as a gate
   it broke layered scaffolds; as verify-stage input it's all upside).
   `files_touched` claims reconcile against the wave's porcelain delta
   (C1-6c) — Trace warning first, held stage later.
4. Port the output-masking checks into `Security.ShellCommand` (it already
   parses invocations this deeply for the approval gate; this adds a read-side
   "would this exit code survive its plumbing" fact — pipefail/filter
   plumbing, skip-flag detection; attribution line).
5. Second slice once #9's ACs exist: extract-assertions-then-grep (their
   `verification/` variant), same flip-only rule. OQ-3 scope for v1:
   `tests_passed` first, coder/fixer templates only, masking as findings-only.

**Rider — OpenHelm OH1-3 (added 2026-07-04 connective pass,
[inventory](../../exploration/pms/openhelm/FEATURES-WORTH-BORROWING.md)):**
claimed-vs-observed as the sharpest single check (`verifiedDelta`,
`planner/schemas.ts:142-185`) — and **count fabrication breaches** rather than
only demoting the run; carry their compaction guard (suppress log-count-based
demotion on compacted transcripts).

---

## Riders (attach to items, don't take slots)

- **camus C2-8** (five trust-boundary laws) — lands with #4 (in its plan).
- **osa-claude-code CC2-2** (resume cache-fix + byte-identical-prefix test) —
  lands inside #1 (in its plan).
- **camus C2-2 — canary (`mix jidoclaw.canary`)**: known-answer RED/GREEN
  stages proving #5's envelope round-trips head-bound on the operator's
  machine, plus optional `--runner`/`--review` stages proving #7's lane before
  an unattended run depends on it. Queue it as the validation pass after #5
  and #7's PR-2; #1 makes it scriptable. S–M when it fires.
- **optimal-engine OE1-2 + OE1-1** — fold OE1-2's three design decisions
  (JSONL fixture datasets, persisted run results, deterministic-first judge
  behind a pluggable seam) into the next-five item-5 harness as it lands;
  OE1-1's compaction-fidelity family is the first post-queue case set (and the
  acceptance test for any future summary-prompt swap).
- **osa OS2-6** (effort levels) — trigger fires once AR-9 ships the
  `effort` vocabulary: a `/effort low|medium|high` session override sharing
  the composer enum, and wire-or-delete the vestigial `max_iterations` config
  knob (it currently misleads). S when picked up.

## Deliberately not picked — alternates and the program after

**First alternate: osa OS1-1 compaction resilience** (+ CC1-1's 9-section
structured summary prompt and CC1-2's summarizer-overflow degrade; OE1-1 is its
acceptance test). Promote it over a Wave-A item on the first observed
overflow-dead-turn or summarizer-failure incident — the same incident-promotion
rule the next-five queue used for cron. Its OS1-1b half (conversation-overflow
recovery) is additionally seam-gated on osa OQ-3 (where the provider error
surfaces), which is why it isn't in the ten.

**Second alternate: osa OS1-4 injection guard.** The expensive parts (hardened
Unicode de-obfuscation normalizer + 300-case labeled corpus) are handed to us;
promotes when MCP/web consumption widens beyond the current posture or on the
first injection incident. Note regardless of timing: the normalizer half also
belongs in the redaction root — an escape-split or homoglyph-obfuscated secret
is the same evasion class the ANSI root strip already handles.

**Program 3 — the learning loop** (the program after this queue, now unblocked
by the eval substrate the next-five queue creates): gepa **GP1-2 → GP1-3 →
GP1-4 → GP1-1** (EvalRecord contract, eval sets + minibatch gate, candidate
store, the reflective loop — then GP2-1's Pareto frontier), with empirica
**EM1-1** (negative-knowledge memory kinds + decision-point surfacing) and
**EM1-2** (the calibration ledger — its trigger technically fires when the
arbiter memos + eval harness land, but its first consumers are read-only
dashboards, so it keeps) and optimal-engine **OE2-2** (provenance stamps on
consolidator writes — or ride it into any earlier consolidator session). One
row shape deliberately serves both programs: GP1-2's EvalRecord and EM1-2's
CalibrationSample.

**Absorbed rather than picked:** empirica EM2-2 (typed success criteria) — its
territory is covered by #9's criteria + #5's deterministic evaluator; reconcile
the empirica entry when those land, carrying its two honesty rules (no-signal
skips stay visible; never declare a check you haven't implemented). Ouroboros
OB2-2 (progress-aware loop stops) largely collapses into #6 (C1-5's
fingerprints are the same mechanism); its residue (grade-regression stop,
refuse-to-converge-on-a-no-op-diff) stays evidence-gated, as does OB2-3
(unstuck personas, which rides those stops) and OB2-1 (gate-command detector —
fires when verify waves run on repos beyond this one).

**The operator-trust garnish, demand-paced:** camus C2-1 (budget gate at wave
boundaries — needs the OQ-3 unit decision first) and C2-4 (last-event-age
staleness warning — nearly free over the event log, and the observation layer
that would produce alp-river #9's idle-watchdog evidence). C2-3/C2-6
(doctor/ground preflight) follow #5 naturally if env-caused verify
inconclusives show up in practice.

**Everything else holds its parked verdict.** WS6 (argus second node), cron
async (incident rule above), artifact handles (the `stage_prompt` bytes
telemetry is now live — watch the numbers before building), the YAML catalog
overlay + file-watch, G2-2's JSON-RPC runner protocol, disk-of-truth, the
jidoka tail (per-tool MCP overlay, boundary controls, agent-builder,
`context_ref` lanes, `forward_context` narrowing, `Chat.Stream`, effect
journal), AR-10's shipping tail (usage-gated; note #5's C1-6a and the eventual
receipts-in-full are what make it trustworthy when it fires), and everything
osa-claude-code touched that isn't a rider here (CC1-3's skill-invocation lane
and CC1-4's deferred-tools correction stay filed under osa OS2-3/OS1-3, both
still lane/seam-gated on OQ-5/OQ-1).
