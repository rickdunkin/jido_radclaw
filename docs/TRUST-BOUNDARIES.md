# Trust boundaries — the five laws

Ported from mateodaza/camus @ 53da91b31 (MIT), `docs/ROADMAP-0.3.md` ("the
design law every item must satisfy"), adapted to this codebase's vocabulary.
Landed with next-ten item 4 (camus C2-8) as the **review rubric for any
orchestration/gate change** and the acceptance frame for the verdict
normalizer (item 4 / C1-3) and the deterministic verify authority (item 5 /
C1-2).

The frame: this platform is a distributed transaction manager wrapped around
probabilistic agents. Bugs live at the trust boundaries — every place state
passes between an LLM and the engine. A change that hands state across that
line must answer all five questions; **a feature that can't answer all five
isn't designed yet.**

## The laws

1. **Every phase has allowed mutations.** State-changing effects live in
   engine/gate code (deterministic, reviewable, allowlisted) — never inside an
   agent's discretion. If an agent can mutate it mid-run, it is part of the
   attack/failure surface (cf. the ToolApproval require-list and the
   `.jido/` judge-asset pinning gap tracked as camus C2-7).

2. **Every handoff needs evidence.** An agent's relay of a result is a
   transcription to cross-check, never the source of truth. The engine reads
   exit codes, typed outputs, and durable rows itself; a judge's *output*
   enters only through a deterministic normalizer
   (`JidoClaw.Orchestration.Verdict` — three exits, schema drift fails closed
   to `{:infra, _}`, never coerced into a verdict).

3. **Every crash window needs resume semantics.** Any two durable writes that
   must land together ride one transaction; anything that can crash between
   "child failed" and "the failure was counted" must reconcile on restart (the
   composer's welded wave commits, `closed_wave_index`, and the
   recovered-failed-child arm are the worked examples). The event-sourced
   durability checklist below is this law's working form.

4. **Every "green" proves exactly what state it certified.** A verdict or
   disposition must name what it checked: a clean review names its lens; a
   deterministic verify binds to the exact state it certified and detects the
   tree changing around it. A green that outlives the state it certified is a
   laundered green. The shipped worked example (item 5 / C1-2):
   `clean:verify` lands only with a same-commit `:verify_certified`
   `{head, tree_digest, mode}` marker, convergence re-derives that tuple
   before `:converged`, a would-be green with a failed integrity capture is
   INCONCLUSIVE (never a pass), and tamper terminalizes ahead of every other
   branch.

5. **Every helper agent is untrusted around state-changing commands.** Prompts
   state enforced facts — they don't plead. Enforcement lives in the tool
   pipeline (approval gate, redaction, output caps, loop guard), not in
   instructions the model can ignore; a sandbox is the compensating control
   where a runner's internal calls bypass the pipeline.

## The event-sourced durability checklist (law 3's working form)

House checklist for durable/event-sourced composer & orchestration changes —
apply it to any change that appends events, folds projections, or terminalizes
runs:

- **Durable write never nested in a conditional notify** — append first, then
  notify; a skipped notify must never skip the write.
- **Projection mirrors the fold by construction** — derive durable deltas by
  diffing pre/post fold state (or route the in-memory mirror through the
  projection's own `apply_markers`), so `project(seed, log) == in-memory`
  can't drift.
- **Stable terminal symbols vs durable kinds** — the in-process terminal
  symbol (`:converged`, `:review_infra_failed`, …) and the durable event kind
  (`:route_converged`, `:route_review_infra_failed`, …) are distinct
  vocabularies; map them in one place.
- **Commit failure terminalizes** — a failed durable write is loud
  (`finish_failed`/logged stuck-parent), never "continue from memory as if it
  landed".
- **Reuse `terminal_status?`** — one source of truth for "can this run still
  make progress"; never a local status list.
- **Observe an in-flight child on restart** — a restart re-dispatch that
  dedupes onto a live child observes it (bounded poll), never fails or
  re-runs it.
- **Shared `build_start_opts`** — launch and recovery restore run parameters
  from the persisted parent config through the same code path (the
  `max_waves`/`wave_timeout_ms`/`infra_cap` pattern), so a restart never
  silently resets a caller's override.
- **All-terminal external-resource teardown gated on the `:ok` append** — tear
  down sessions/microVMs only after the terminal event durably committed; a
  failed append leaves the run recoverable, so teardown would strand the
  retry.
