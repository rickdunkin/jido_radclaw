# Verdict normalizer (infra ≠ verdict ≠ inconclusive) — next-ten item 4, camus C1-3

## Context

Every boundary where a probabilistic judge's output enters the engine currently coerces ambiguity into a verdict. Two live conflations:

1. **Composer**: `DefaultMapper.verdict/2` (`lib/jido_claw/route_composer/emit/default_mapper.ex:99-107`) dispatches on output *shape* — a reviewer whose `overall` drifted out of enum silently emits an empty emission, the lens never goes clean, and the run mis-terminalizes `:not_converged`. A degenerate verdict (`request_changes` with zero findings) summons the fixer with empty feedback and burns `rerun_cap` toward a false `:fix_failed`.
2. **IterativeStep**: `parse_verdict/1` (`lib/jido_claw/skills/steps/iterative_step.ex:133-154`) maps every garbled/missing verdict to `:fail`, consuming an iteration exactly like a real fail — camus's "#1 cause of runaway loops."

Port camus's normalizer contract (`adapter.py:46-111`, `mateodaza/camus @ 53da91b3, MIT`): three exits — verdict / infra / inconclusive — with schema drift failing closed to **infra** (retried on a budget separate from `rerun_cap`, terminalizing as a distinct `review_infra_failed` disposition, never `:fix_failed`, never clean). This module is also item 7's deposit-tool contract (external CLI JSON that never passed Zoi) — `normalize/2` must be total over arbitrary input.

**Operator decisions (asked 2026-07-03):**
- **Self-contradiction guard covers any non-approve** (`:request_changes` OR `:comment`) with zero findings → infra.
- **Wave-execution errors included**: a failed wave whose dispatched cohort is lens-stages-only also classifies as infra (retry through the same budget). Mixed cohorts and commit failures keep today's loud `:route_failed`.
- **C2-8 rider**: new `docs/TRUST-BOUNDARIES.md` with the five laws + the event-sourced durability checklist materialized from house memory; pointer from AGENTS.md.

**Plan-review revisions (operator findings, 2026-07-03):** Lane B covers the recovered-failed-child arm (P1); `Observe`/`WorkflowView` learn `closed_wave_index` closes a wave (P2); `infra_cap` persisted in parent config (P2); `decode_outcome` fails closed on unknown-present shapes (P2); normalizer documents routing-critical-only field coverage (P2); trace events carry `run_id` (P3). Second pass (nits): recovered-child reason = `run.error || :failed_child`; `emission_entry/1` carries `outcome` into history; telemetry counter registered in `metrics/0`; `WorkflowEvent.Projection` unit test for the new kind; `format_reason/1` bounded.

Done = `mix precommit` passes (zero findings). Greenfield: no data/back-compat concerns. Nothing committed/staged.

---

## Step 1 — Pure normalizer modules (new)

**`lib/jido_claw/orchestration/verdict.ex`** — `JidoClaw.Orchestration.Verdict`: envelope struct + behaviour + kind dispatcher. Attribution comment: `# Ported from mateodaza/camus @ 53da91b3, MIT`. (Namespace note: `JidoClaw.Triage.Verdict` exists — different subsystem, no clash; don't alias both in one module.)

```elixir
@type reason :: atom() | {atom(), term()}
@type result :: {:verdict, t()} | {:infra, reason()} | {:inconclusive, reason()}
@type t :: %__MODULE__{clean?: boolean(), decision: atom() | nil, findings: [map()],
                       summary: String.t() | nil, source: map()}
defstruct clean?: false, decision: nil, findings: [], summary: nil, source: %{}

@callback normalize(raw :: term()) :: result()      # item-7 deposit / item-5 verify seam
@kinds %{review: __MODULE__.Review, iterative_eval: __MODULE__.IterativeEval}
@spec normalize(atom(), term()) :: result()          # dispatches via @kinds
@spec format_reason(reason()) :: String.t()          # for outcome strings / trace / terminal error
```

`format_reason/1` is **bounded**: reasons embedding raw malformed output render via `inspect(raw, limit: ..., printable_limit: ...)` plus a hard byte cap, so a huge garbage judge output never becomes a huge reason string in traces, history, or the terminal error.

Shared fail-closed primitives (blank-detection, atom/string-tolerant key reads modeled on `Triage.Verdict.from_map/1`'s whitelist style — never `String.to_atom/1`) live here to avoid ExSlop clone trips between the two kind modules.

**`lib/jido_claw/orchestration/verdict/review.ex`** — camus rules → our reviewer vocabulary (`output_schema.ex:127-146`: `overall ∈ {:approve, :request_changes, :comment}`, findings `severity ∈ {"info","warning","error"}`). Total over atom-/string-keyed maps and garbage. **Field coverage is routing-critical only** — `overall`, findings list-ness, finding map-ness, `severity` — because those alone decide the clean/findings/infra lanes; non-routing fields (`summary`, `action_needed`, per-finding `confidence`/`location`/`description`) pass through unvalidated as payload. This is camus-faithful (adapter.py validates verdict enum, findings list-ness, finding object-ness, priority; passes `title`/`body`/`confidence_score` through), avoids infra-retrying verdicts whose only flaw is a missing prose field (the item-7 deposit path would suffer most), and Zoi still enforces the full schema on the LLM path. State this in the moduledoc. Exit table:

| input | exit |
|---|---|
| `nil`, `""`, whitespace-only | `{:infra, :empty_output}` |
| non-map (`42`, `[]`, binary prose) | `{:infra, :not_a_map}` |
| missing/out-of-enum `overall` | `{:infra, {:invalid_overall, raw}}` |
| `findings` present but not a list | `{:infra, :findings_not_a_list}` |
| finding not a map | `{:infra, :malformed_finding}` |
| finding `severity` missing/out-of-enum (refuse to demote) | `{:infra, {:invalid_severity, raw}}` |
| non-approve (`:request_changes` or `:comment`) + zero findings | `{:infra, :self_contradiction}` |
| `:approve` + `[]` | `{:verdict, %V{clean?: true, decision: :approve}}` |
| `:approve` + findings (findings-win) | `{:verdict, %V{clean?: false, ...}}` |
| non-approve + findings | `{:verdict, %V{clean?: false, ...}}` |

`clean? = approve AND findings == []` — byte-compatible with today's `approve?/findings_empty?` mapping for all currently-valid outputs. No blocking/nonblocking split (all findings force revise, matching current semantics). Rule order mirrors adapter.py: emptiness → shape → overall enum → findings list → per-finding → self-contradiction.

**`lib/jido_claw/orchestration/verdict/iterative_eval.ex`** — subsumes `parse_verdict/1`: typed maps (`%{verdict: :pass|:fail}` atom/string keyed, per verifier schema `verifier.ex:25-34`) and legacy `VERDICT: PASS|FAIL` text (last-token-wins regex, keep the ExSlop `ListLast` disable). New exits: `nil`/empty → `{:infra, :empty_output}`; text without token → `{:infra, :no_verdict_token}`; map without/with out-of-enum verdict → `{:infra, {:invalid_verdict, raw}}`.

Neither kind emits `{:inconclusive, _}` yet (item 5's deterministic verify will); all consumers handle it defensively (fold into the infra lane).

## Step 2 — Emission carrier

**`lib/jido_claw/route_composer/stage_emission.ex`**: add `outcome` field — `@type outcome :: :ok | {:infra, String.t()} | {:inconclusive, String.t()}`, default `:ok`. `from_map/1` decodes via `pick(map, :outcome, "outcome", nil)` + `decode_outcome/1`, **fail-closed on the trust boundary** (child `WorkflowRun.result` is DB data): `nil` (absent — legacy rows and normal emissions) → `:ok`; recognized `%{"kind" => "infra"|"inconclusive", "reason" => r}` (atom/string tolerant) → decoded; **any other present value → `{:infra, "unrecognized outcome: " <> inspect(...)}`** so a malformed new child result can never be folded as ran.

**`lib/jido_claw/route_composer/steps/wave_collect.ex`**: `to_map/2` emits `"outcome"` **only when not `:ok`** (`:ok` omitted → existing persisted result maps stay byte-identical), encoding `{:infra, reason}` → `%{"kind" => "infra", "reason" => reason}` (reason already a formatted string).

## Step 3 — DefaultMapper routes lens stages through the normalizer

**`lib/jido_claw/route_composer/emit/default_mapper.ex`** — the core fix: `verdict/2` dispatches on **`lens` presence, not output shape** (a malformed reviewer output is still recognized as a reviewer). For `%{lens: lens} when is_binary(lens)`: `Verdict.normalize(:review, typed)` →
- `{:verdict, clean?: true}` → `{["clean:#{lens}"], %{}, :ok}`
- `{:verdict, clean?: false, findings: f}` → `{["findings:#{lens}"], %{"findings" => coerce(f)}, :ok}`
- `{:infra, r}` / `{:inconclusive, r}` (defensive) → `{[], %{}, {:infra, Verdict.format_reason(r)}}`

For `lens: nil`: keep the `{:reviewer_without_lens, name}` coherence error when the output is reviewer-shaped (`overall in @verdicts`), else pass through as today. On an infra outcome, `map/2` suppresses explicit signals AND output artifacts (emission is `signals: [], artifacts: %{}, outcome: {:infra, _}`). `approve?/findings/findings_empty?` move into `Verdict.Review`; delete here (no forwarders — reach). `refuse_blocked_producer`, `explicit_signals`, `output_artifacts`, `validate_publishes`, `coerce` unchanged. Producers (lens nil) never touch the normalizer.

## Step 4 — Durable vocabulary

**`lib/jido_claw/orchestration/workflow_event.ex`** (`one_of` at :95-160, additive, no migration): add `:stage_infra` (near `:stages_invalidated`) and `:route_review_infra_failed` (near `:route_fix_failed`).

**`lib/jido_claw/orchestration/workflow_event/projection.ex`**: `@route_terminal_kinds` += `:route_review_infra_failed`; explicit `next_status(status, :route_review_infra_failed) when status in @non_terminal → {:ok, :failed}` (kept OUT of `@route_failed_kinds` so the disposition-lifting clause isn't shadowed — the `:route_fix_failed` precedent, comment at :41-47); `status_attrs(:route_review_infra_failed, payload, occurred_at) → terminal_lifting_error_and_result(:failed, payload, occurred_at)` (reuses the shared helper at :259-267).

## Step 5 — Composer projection folds `infra_counts`

**`lib/jido_claw/route_composer/projection.ex`**: new `apply_event(%{kind: :stage_infra, payload: payload}, state)` — bumps `infra_counts` per stage (tolerant `Map.update` like `:stages_invalidated`'s `rerun_counts` at :142-159, reusing `bump_rerun_counts/2` and `advance_on_invalidation/2` for the **optional** `closed_wave_index`); never touches `ran`. Both lanes ride this one clause because `apply_markers/2` (:84-89) replays markers through `apply_event` — durable rebuild ≡ in-memory mirror by construction. Update the moduledoc "Folded kinds" list.

## Step 6 — Composer loop

**`lib/jido_claw/route_composer/route_composer.ex`**:

- **State/config**: `@default_infra_retry_cap 2` (camus INFRA_RETRIES; count > cap trips on the 4th attempt → 3 attempts, matching camus's 3 total) near `@default_rerun_cap` (:212); `init/1` adds `infra_counts: %{}`, `infra_cap: Keyword.get(opts, :infra_cap, @default_infra_retry_cap)` (:1078-1082). **Persist it for recovery**: `parent_config/3` (:453-462) gains `maybe_put("infra_cap", Keyword.get(opts, :infra_cap))` (conditional-put — the present-nil rule) and `build_start_opts/2` (:816-836) restores via `config["infra_cap"] || opts[:infra_cap] || @default_infra_retry_cap` (the `max_waves` pattern) — otherwise a restarted composer silently resets a caller's `infra_cap: 1` to default. (Note: `rerun_cap` has the same pre-existing gap; out of scope, don't touch.) No app-config key. Rebuild seeds `infra_counts` via `do_rebuild` → `ComposerProjection.project`.

- **Lane A — output-boundary infra** (`handle_wave_value/5` :1638-1671): partition after completion-signal injection (which only touches lens-nil producers — verified moot for infra'd reviewers):
  ```
  emissions = enforce_completion_signals(raw_emissions, state)
  {verdict_emissions, infra_emissions} = split by &1.outcome
  next_fold = Fold.fold(state, verdict_emissions)        # CRITICAL: fold_ran (fold.ex:95) adds every
                                                          # folded stage to ran — infra stays out
  deltas = wave_deltas(state, next_fold, dispatch, infra_stages)  # stages: dispatch -- infra_stages
                                                          # (keeps durable wave_completed.stages ≡ in-memory ran)
  {rerun_markers, _} = decide_rerun(next_fold, verdict_emissions)
  markers = infra_markers(infra_stages) ++ rerun_markers  # [stage_infra: %{stages: [...]}] — NO closed_wave_index
                                                          # (wave_completed advances the index); stage names only,
                                                          # no reasons in durable payload (redaction posture)
  apply_fn = &ComposerProjection.apply_markers(&1, markers)
  ```
  `Commit.commit_wave/5` needs **no changes** — markers append generically (`append_each` → `WorkflowLog.append`, verified commit.ex:264-273). On `:ok`: `record_wave(apply_fn.(next_fold), dispatch, display, run, emissions)` (full emissions → history for legibility — **requires extending `emission_entry/1` (:1754) to include `outcome`**, since history entries currently keep only `stage`/`signals`/`artifacts` and would silently drop it), trace after commit (durable-then-notify), `maybe_rerun_after_findings(next, verdict_emissions)`. `wave_deltas/3` → `/4` (:1817-1824).

- **Lane B — wave-execution-error infra**, one shared helper `wave_infra_failed/5`, **three entry points**:
  1. `handle_wave_result({:error, reason, run}, ...)` (:1619-1621) — live reactor-run failure;
  2. `handle_wave_value({:error, reason}, ...)` (:1673-1674) — decode/`:bad_wave_return` failure;
  3. **the recovered-failed-child arm** `handle_wave_result({:ok, {:existing_run, _}, run})` `:failed` branch (:1594-1595) — a crash after the child failed but before `stage_infra` was appended dedupes back here on restart; today it only bumps in-memory `wave_index`, which would bypass `infra_counts` and end as generic budget exhaustion. This arm has no live `reason`, so it passes `run.error || :failed_child` for trace/fallback consistency with the live arms.

  Each gates on `lens_only_dispatch?(dispatch, state.catalog)` (every dispatched stage has a binary `lens`); non-lens/mixed cohorts keep today's behavior (`finish_failed` for 1-2; the plain bump for 3). The helper:
  ```
  markers = [stage_infra: %{stages: dispatch, closed_wave_index: state.wave_index}]
  case Commit.append_markers(state.parent, markers, commit_opts(state)) do
    :ok -> next = record_wave(state, dispatch, display, run, [], true)   # failed history entry, index +1
           next = ComposerProjection.apply_markers(next, markers)         # counts bump; index max-idempotent
           trace, then continue to :tick (same return shape as the success path)
    {:error, :parent_terminal} | {:error, :parent_fenced} -> {:stop, :normal, state}
    {:error, _} -> finish_failed(...)                                     # can't record durably → loud
  end
  ```
  `closed_wave_index` is load-bearing (the `stages_invalidated` reject-parked-gate precedent, projection.ex:134-141): the failed wave never wrote `wave_completed`, so without it a restart rebuilds the old `wave_index` and the relaunch **dedupes onto the failed child** via `composer:<parent>:<wave_index>`. Ordering avoids double-advance: `record_wave` bumps to `idx+1` first; `apply_markers`' `max(current, idx+1)` is then idempotent. Commit-failure arm of the Lane A success path stays `finish_failed` unconditionally (house rule: commit-failure terminalizes).

- **Re-dispatch**: infra'd stages are absent from `ran` (never folded / never wave_completed), publishes unsatisfied → next tick's `Router.compose_route`/`Loop.dispatch_cohort` re-offer them naturally; each retry is a fresh wave (fresh idempotency key in both lanes).

- **Cap gate**: `over_budget?/1` (:3470-3472) += `or infra_capped?(state)`; new `infra_capped?` mirrors `rerun_capped?` (:3476-3478) over `infra_counts`/`infra_cap`. At the trip tick, dispatch is non-nil so the tick's `cond` routes through `budget_terminal/1` (:3509-3520) — add the infra clause **first** (a judge that never produced a trustworthy verdict outranks findings-derived exhaustion): `infra_capped?(state) -> {:review_infra_failed, infra_exhausted_stages(state)}` (stages where count > cap).

- **Terminal wiring** (mirror `:fix_failed` exactly): `@type terminal` (:278-288) += `:review_infra_failed`; `classify_terminal/1` (:3288-3297) passthrough clause; `terminal_event/3` (:3199-3221) → `{:route_review_infra_failed, %{error: ..., result: %{disposition: "review_infra_failed"}}}`; `format_terminal_error/2` (:3440-3453) → `"review_infra_failed: stages=" <> Enum.join(stages, ",")`; `@scrubbable_error_kinds` (:250-261) += `:route_review_infra_failed`. No `route_terminal_kind/1` change (specific clause wins, like fix_failed). Verified: no CLI/web/workflow_status/recovery/replay/cancellation code pattern-matches terminal kinds — the disposition surfaces generically; eval harness asserts `summary.terminal`, so `:review_infra_failed` is assertable with no harness change.

- **Trace + telemetry**: `JidoClaw.Trace.emit(:composer, %{event: :review_infra, run_id: state.parent_run_id, parent_run_id: state.parent_run_id, stage, reason, wave_index, lane: :output | :wave_error}, %{count: 1})` — `run_id` included because the collector indexes traces by `:run_id`/`:request_id` (collector.ex:343); new `:composer` category (composer's first Trace producer), fired post-commit. Add `JidoClaw.Telemetry.emit_composer_infra/2` to `lib/jido_claw/core/telemetry.ex` mirroring `emit_loop_guard/3`, **and register the counter in `metrics/0`** (otherwise the event exists but never reaches the standard metric surface).

## Step 7 — Observe + WorkflowView learn `closed_wave_index` closes a wave

**`lib/jido_claw/route_composer/observe.ex`**: generalize `wave_completed?/2` (:105-110) to `wave_closed?/2` — a wave `idx` is closed by a `wave_completed` with matching `wave_index` **or** any event whose payload carries `closed_wave_index == idx` (`:stage_infra` and `:stages_invalidated` uniformly — this also fixes the same latent in-flight-forever read for the pre-existing reject-parked-gate path, same helper, same semantics). Without this, a Lane B wave (which deliberately writes no `wave_completed`) reads as in-flight forever in `wave_in_flight?/1` (:98-103) — including on a terminal `review_infra_failed` run. `net_ran` needs no change (`:stage_infra` never touches `ran`).

**`lib/jido_claw/workflow_view.ex`**: add `:stage_infra` to the O-M1 kind filter (:244-252) so Observe can see the closing events; update the "four marker kinds" comment.

## Step 8 — IterativeStep (the named live bug; write its regression test RED first)

**`lib/jido_claw/skills/steps/iterative_step.ex`**: delete `parse_verdict/1` (single prod call site, verified). `run/3` config gains `infra_retries: Keyword.get(options, :infra_retries) || @default_infra_retries` (attr = 2). Refactor `run_evaluator/5` so eval_context builds once and an inner attempt loop carries `infra_attempt`:
- `{:verdict, clean?: true}` → `{:ok, [gen_result, eval_result]}`
- `{:verdict, clean?: false}` → `iterate(..., iteration + 1, ...)` (burns an iteration — unchanged semantics)
- `{:infra, r}` with attempts left → re-run the **evaluator only**, same iteration, same gen_result
- `{:infra, r}` exhausted → `{:error, "Evaluator infra failure after N retries: ..."}` (terminal; compensate/retry budget applies as today)
- `{:inconclusive, r}` → error (defensive)
- **AgentRunner `{:error, reason}` joins the infra retry lane** (symmetry with the composer wave-error decision — an evaluator run error is camus's exec-failure class); generator errors stay terminal (not a judge).

## Step 9 — C2-8 rider docs

**New `docs/TRUST-BOUNDARIES.md`**: the five trust-boundary laws from camus `docs/ROADMAP-0.3.md:20-35` adapted to our vocabulary ("script" → engine/gate code, "green" → verdict/disposition), attribution line (`mateodaza/camus @ 53da91b3, MIT`), framed as the review rubric for orchestration/gate changes and the acceptance frame for items 4-5. Sibling section: the event-sourced durability checklist materialized from house memory (durable write not nested in conditional notify; projection mirrors fold via pre/post diff; stable terminal symbols vs durable kind; commit-failure terminalizes; reuse `terminal_status?`; observe in-flight child on restart; shared `build_start_opts`; all-terminal external teardown gated on `:ok` append) — now the laws' law-3/law-4 cross-link target. **`AGENTS.md`**: one-line pointer + a short Key Patterns bullet for the verdict normalizer (house style: every shipped mechanism has one).

## Step 10 — Reconciliation (the item's closing habit)

- `docs/exploration/camus/FEATURES-WORTH-BORROWING.md` C1-3 (:80-92): Status blockquote after the Recommendation line — `**Done <date>** (next-ten #4)`, shipped modules, both lanes, corrections to falsified claims (collected during implementation; known already: parse_verdict was at :133-154 → clauses :134-154 and is now deleted; the "malformed verdict → failed iteration" framing understated that today's composer silently mis-terminalizes `:not_converged`, not `:route_failed`). C2-8 (:246-258): Status blockquote (landed as docs/TRUST-BOUNDARIES.md incl. materialized checklist).
- `docs/plans/unadopted-next-ten/README.md`: table row 4 + `## 4.` heading → `— ✅ DONE <date>`; Done-blockquote with the corrections list (items 1-3 convention).

---

## Tests (structure mirrors source)

| File | Scenarios |
|---|---|
| `test/jido_claw/orchestration/verdict_test.exs` (new) | Table tests per exit-table row, both kinds, atom+string keys, totality inputs (nil/""/42/[]/%{}); findings-win; non-approve+empty → self_contradiction (both `:request_changes` and `:comment`); non-routing fields pass through unvalidated; format_reason |
| `default_mapper_test.exs` | lens + bogus/missing/nil typed → `outcome: {:infra, _}`, empty signals/artifacts; severity "critical" → infra; existing clean/findings rows still `outcome: :ok` (regression); lens-nil reviewer-shaped output still `{:reviewer_without_lens, _}` |
| `stage_emission_test.exs` (create if absent) | outcome round-trip; `:ok` omitted from to_map (byte-identical); **unknown-present outcome shape decodes to `{:infra, _}`, never `:ok`** |
| `route_composer/projection_test.exs` | `:stage_infra` bumps `infra_counts`, leaves `ran` alone; with `closed_wave_index` advances `wave_index` (max-idempotent), without → untouched |
| `orchestration/workflow_event/projection_test.exs` | Unit coverage for `:route_review_infra_failed`: status authority (`next_status` non-terminal → `:failed`, terminal states refused), `status_attrs` lifts `error` + `result.disposition` (the exact spot where `:route_verify_failed`/`:route_fix_failed` needed careful clause ordering vs `@route_failed_kinds`) |
| `composer_self_heal_loop_test.exs` | (a) infra × 2 then clean → `:converged`, `rerun_counts` untouched (infra never consumed fix budget), `:stage_infra` events present; (b) infra `:always`, `infra_cap: 1` → `summary.terminal == :review_infra_failed`, `:route_review_infra_failed in kinds`, `refute :route_fix_failed`, `parent.status == :failed`, `parent.result["disposition"] == "review_infra_failed"`, `parent.error` prefix. Stub arming: new `:route_composer_review_infra_on` env knob + `TestFixtures.phase1_infra_reviewer/0` (`%{"overall" => "maybe", ...}`) + third branch in `SystemLoopWorker.output_for("reviewer", _)`; add `:infra_cap` to the harness `run/2` `Keyword.take` |
| same file (lane B) | lens-only wave error (timeout/crash stub) → infra retry → converge; exhausted → `:review_infra_failed`; mixed-cohort error → still `:route_failed`; fresh idempotency key on retry (no dedupe onto failed child) |
| `composer_durable_test.exs` | restart mid-infra → `infra_counts` rebuilt from `:stage_infra` log (both lanes; lane B also re-checks `wave_index` advanced past the failed wave); **P1 recovery: failed child exists at the current key with NO `stage_infra` yet → rebuild + relaunch dedupes onto it → the existing-run `:failed` arm appends `stage_infra` and counts it (ends `review_infra_failed`, not generic budget exhaustion)**; **`infra_cap: 1` survives restart via parent config (not reset to default)** |
| observe/workflow_view coverage (existing observe test file, or alongside) | a `closed_wave_index`-closed wave reads `wave_in_flight: false`; `:stage_infra` present in the WorkflowView kind filter (snapshot on a lane-B run) |
| `iterative_step_test.exs` | RED-first regression: EchoStub evaluator (emits no VERDICT token → infra) does NOT iterate; evaluator runs 1+`infra_retries` times; returns `{:error, "Evaluator infra failure..."}`. Existing "failing evaluator caps out" test rewired to a new `FailStub` (emits `VERDICT: FAIL`) — EchoStub is an *infra* input under the new contract. parse_verdict describe moves to verdict_test with flipped rows (`"nothing here"`/`""`/nil/`%{verdict: :unknown}` → infra) |

Support: `composer_stubs.ex`, `fixtures.ex`, new `FailStub` next to `PassStub`.

## Verification

1. Each step: targeted `mix test <file>` green before moving on; IterativeStep regression proven red→green.
2. Full gate: `mix precommit` — run bare (never piped), report exit code + counts verbatim. Zero credo/reach findings policy. Known flake: `MemoryExportTest` in full suite (passes in isolation — not a regression).
3. Watchpoints: Zoi map form untouched; no `String.to_atom` on input; `Enum.join`/iodata for terminal strings; no trivial defp forwarders (reach) — shared primitives live in `Verdict`, not delegated; no 3rd contiguous duplicate defp (ExSlop clone); `assert match?(..., ...)` when a message is attached; tenant-scoped durable tests use the existing `TenantCase` harnesses.

## Out of scope (not deferrals — outside the item's spec)

- `{:inconclusive, _}` producers (item 5's deterministic verify authority — the type + defensive handling ship now).
- Deposit-tool normalizer impl (item 7 PR-2 — the behaviour seam ships now).
- Eval-harness seed case for the new terminal (harness needs no change; `summary.terminal` already assertable).
- hermes T1-4 provider-level taxonomy stays NOT_ADOPTED (per the source entry).
- Persisting `rerun_cap` in parent config (same pre-existing gap `infra_cap` now avoids — noted, not swept in).
