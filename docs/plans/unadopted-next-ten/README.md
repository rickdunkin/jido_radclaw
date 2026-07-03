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
| 4 | B | Verdict normalizer (infra ≠ verdict ≠ inconclusive) | camus C1-3 | M | Single PR |
| 5 | B | Deterministic verify authority + sealed heads | camus C1-2 + C1-6(a) | M | 2 commits (verify stage / commit facts) |
| 6 | B | Honest terminal statuses + stall detection | camus C1-4 + C1-5 | M | 2 commits (fingerprints / gate + disposition) |
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

## 4. Verdict normalizer — M (camus C1-3)

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

## 5. Deterministic verify authority + sealed heads — M (camus C1-2 + C1-6a)

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

## 6. Honest terminal statuses + stall detection — M (camus C1-4 + C1-5)

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

## 7. Executor seam — M–L, must be broken down (camus C1-1)

**Direction agreed 2026-07-02** (recorded in the camus doc's revision note):
build the seam, not the pairing. One hard binding stands between the shipped
substrate and the whole family — `AgentRunner` always spawns an in-process
worker from `Templates.get/1`, while Forge already holds the full session
contract, both vendor CLIs, and a proven headless driver (the consolidator's
`RunServer` + per-run MCP deposit pattern,
`memory/consolidator/run_server.ex:516-541`).

**Suggested 4 PRs:**

1. **PR-1 — template binding + in-process/fake (S–M):**
   `executor: :in_process (default) | {:forge, :codex | :claude_code | :shell
   | :custom | :fake}` in the `Templates` registry; `AgentRunner` branches on
   it; land `:fake` (and `:shell`) first — proves the seam cheaply and hands
   the eval harness deterministic fake-backed stages. Untouched templates stay
   byte-identical.
2. **PR-2 — the Forge-backed path (M):** session provisioning per the
   consolidator pattern; a `workspace: :repo | :scratch | :none` template
   knob; a scoped per-run MCP endpoint whose single deposit tool
   (`submit_structured_output`) validates against the template's output schema
   **through #4's normalizer** — schema drift is `{:infra, _}`, never a
   verdict. Read-only stages only in this wave.
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
