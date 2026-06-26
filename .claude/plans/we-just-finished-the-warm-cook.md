# Fix AR-4 P1 — injection advances *blocked* producers against fabricated output

## Context

The AR-4 self-heal fixer loop (plan `please-review-docs-exploration-alp-river-smooth-kite.md`)
just landed (uncommitted working tree). A code review found one **P1**:

> Injection advances blocked producers because the mapper still fabricates required artifacts
> from `result`.

**The finding is VALID** — verified end-to-end by static analysis (the reviewer also confirmed
the core via Tidewave). The causal chain:

1. A no-lens producer (implementer/fixer/system-executor/sketch-build) can return
   `status: :blocked, summary: "BLOCKED…"` with **no** `diff`/`fix`/`prototype` field — the named
   output artifact is **not** a schema field (`coder_result/0`, `fixer_result/0`, `builder_result/0`
   have no `diff`/`fix`; `output_schema.ex:39-87`).
2. `AgentRunner` sets `StepResult.result = Output.extract_result(typed) = summary` (`output.ex:47`).
3. `DefaultMapper.output_value/3 → artifact_or_text/2 → coerce(result.result)` **fabricates**
   `%{"diff" => "BLOCKED…"}` from the summary (`default_mapper.ex:112-125`).
4. `Fold.available/1` marks an artifact available on **store presence**, ignoring its value
   (`fold.ex:43-44`); the router's drop-unsatisfiable keys on artifact **names** in
   `available ∪ produced`, never on value content (`router.ex:181-185`). So the consumer is
   **never dropped**.
5. The new `enforce_completion_signals/2` injects `code-written`/`plan-ready` for *every* producer
   that ran, regardless of `status` (`route_composer.ex:2011-2040`). The signal goes live →
   the reviewers (subscribe `code-written`, require `diff`) trigger and **review a "BLOCKED…"
   string as if it were a real diff** — injection-driven, also true for the fixer's `fix` and the
   planner's `plan`. The **system-executor and sketch-build variants are fabrication-*only*** (their
   consumer is ordered by a data edge / different trigger, not the injected completion signal —
   system-change/prototype aren't in `@completion_signals`), but share the identical root:
   summary-as-fabricated-artifact. The mapper guard below fixes **all** of them uniformly,
   regardless of trigger mechanism.

So the moduledoc "self-guard" claim (`route_composer.ex:2005-2010`) — "a blocked producer leaves
the consumer drop-unsatisfiable, so injection never advances an empty producer" — is **false**.
The injection makes this advance *deterministic* where pre-AR-4 it was LLM-dependent.

**Why the reviewer's two literal suggestions are insufficient (the subtle part):** simply gating
injection on completed status, or not fabricating output for a blocked producer, makes the
downstream consumer **dropped** (not *held*). With no lens stage having run, `lenses_clean?` is
vacuously true and `Loop.terminal/2` returns **`:converged`** (`loop.ex:84-101`) — a *silent false
success*, arguably worse than the garbage-advance. The correct fix must terminate **honestly**.

**Chosen approach (confirmed with the user):** refuse a blocked producer at the mapper boundary.
`WaveCollect.collect/4` already halts the wave loudly on any mapper `{:error, _}`
(`wave_collect.ex:56-62`) → `finish_failed` → `route_failed` (parent `:failed`) — the exact path the
existing test "a wave failure → route_failed" exercises (`composer_durable_test.exs:222`). The
emission never reaches injection/fold, so there is no garbage advance **and** no false-converge —
just an honest failure naming the blocked producer. Scope decisions: **give the researcher a
*required* `status` field** so the planner is covered structurally (it has none today) — *optional*
status would leave the hole half-open (a planner that can't draft a plan but **omits** status would
still get `plan` fabricated from `summary` + `plan-ready` injected and advance the implementer);
**only `:blocked` fails** — `:partial` proceeds (its summary is real, if incomplete, output; the
reviewer/fixer loop catches gaps).

**Outcome:** a blocked non-reviewer producer (implementer, fixer, system-executor,
sketch-build/exec, test-author, and — once it carries `status` — the planner) fails the wave
(`route_failed`, disposition surfaced via the error string) instead of advancing an automated
consumer against a fabricated "BLOCKED…" artifact or silently converging.

---

## The fix

### 1. The mapper guard — `lib/jido_claw/route_composer/emit/default_mapper.ex`

Add a status-aware refusal as the **first** leg of `map/2`, reusing the existing atom/string-tolerant
`known/3` (`default_mapper.ex:146-151`):

```elixir
def map(%StepResult{} = result, meta) do
  typed = result.typed_output || %{}

  with :ok <- refuse_blocked_producer(typed, meta),
       {:ok, {verdict_signals, verdict_artifacts}} <- verdict(typed, meta),
       signals = Enum.uniq(verdict_signals ++ explicit_signals(typed)),
       :ok <- validate_publishes(signals, meta) do
    artifacts = Map.merge(verdict_artifacts, output_artifacts(result, typed, meta))
    {:ok, %StageEmission{stage: meta.name, signals: signals, artifacts: artifacts}}
  end
end

# A non-reviewer producer (`lens == nil`) that reports `status: :blocked` produced no
# usable output — its named artifact (`diff`/`fix`/`plan`/`prototype`/`system-change`) is
# never a schema field, so `output_value/3` would fabricate it from the blocked `summary`
# (`result.result`). Refuse it LOUDLY so `WaveCollect` fails the wave (`route_failed`)
# rather than advancing a downstream consumer against a "BLOCKED…" string — or silently
# converging. Reviewers (`lens` set) carry `overall`, not `status`, so they never match.
# `:partial`/`:completed` proceed (a partial summary is real, if thin, output).
defp refuse_blocked_producer(typed, %{lens: nil, name: name}) do
  case known(typed, :status, "status") do
    s when s in [:blocked, "blocked"] -> {:error, {:producer_blocked, name}}
    _ -> :ok
  end
end

defp refuse_blocked_producer(_typed, _meta), do: :ok
```

- Scope predicate is **`meta.lens == nil` + `status ∈ [:blocked, "blocked"]`** only. Do **not**
  narrow it by `publishes ∩ @completion_signals` — that would re-open the system-executor
  (publishes only `scope-shift`) and sketch-build cases, which carry the identical bug.
- Update the module doc (`default_mapper.ex:2-28`) to list "a blocked non-reviewer producer"
  alongside the existing loud-error cases (undeclared signal, reviewer-without-lens), and note that
  `:partial`/`:completed` proceed (a `:partial` producer's summary is still usable, if incomplete,
  summary-backed output).

### 2. Give the planner a *required* `status` — `lib/jido_claw/agent/workers/researcher.ex`

Add a **required** `status` to the schema (Zoi object keys are required by default — matching the
already-required `status` on `coder_result/0`/`fixer_result/0`/`builder_result/0`/`sketch_worker`):

```elixir
status: Zoi.enum([:completed, :partial, :blocked]),
```

**Why required, not optional:** required closes the planner hole at the *schema* layer — a real
planner run must emit `status` (`on_validation_error: :repair`, already set, recovers a transient
omission), so a blocked planner can never silently fall through to summary-fabrication + injection.
Optional would leave that hole open. This is a (small, accepted) contract change to the shared
`researcher` template — but the `coder` template is *also* shared (implementer + test-author) and
already requires `status`, so this is consistent, and a research sub-agent reporting
`status: completed` is harmless. Update the worker `description` (`researcher.ex:8`) to instruct
emitting `status` (`blocked` when it cannot draft a usable plan).

**Do NOT also add a mapper rule treating *absent* status as blocked.** The hermetic composer stubs
(`composer_stubs.ex` — `StubWorker.ask/3` stamps the canned map as `:validated`, bypassing Zoi)
legitimately omit `status` and must proceed; an absent-status-is-blocked rule would break every
integration stub. Required-status-at-the-schema is the single correct enforcement point; the mapper
guard only acts on a *present* `:blocked`.

### 3. Reconcile the false-invariant docs (sweep — leave legitimate `drop-unsatisfiable` uses)

The user cares about no stale invariant text. Rewrite **only** the restatements of the *false*
self-guard claim; the router's real drop-unsatisfiable mechanism docs (`router.ex:17,22`,
`route_composer.ex:1163`) are correct and stay:

- `route_composer.ex:2005-2010` — **primary.** Replace the "SELF-GUARDS … drop-unsatisfiable …
  `status` is not even on `StageEmission`, so no status-gating is possible or needed" comment with
  the truth: a blocked non-reviewer producer is refused at the mapper
  (`{:error, {:producer_blocked, _}}`) and fails the wave (`route_failed`) before injection/fold
  ever runs.
- `route_composer.ex:175-181` — the `@completion_signals` / `tests-ready` `:deadlock` rationale:
  note a blocked test-author now route-fails at the mapper; `:deadlock` survives for the
  *completed-but-`tests-ready`-omitted* case.
- `output_schema.ex:24-32` — the `coder_result/0` note on the test-author lock: reconcile to the
  new route-fail-on-blocked behavior.

**Behavior change to call out** (no existing test asserts it — the only `:deadlock` test,
`loop_test.exs:100-102`, hand-builds a `held` map and never routes through the mapper): a blocked
`test-author` now yields `route_failed {:producer_blocked, "test-author"}` instead of `:deadlock`.
Both project to parent `:failed`; the new form is strictly more informative (names the producer).

### 4. Tests

- **`test/jido_claw/route_composer/default_mapper_test.exs`** (primary — model on the
  `{:undeclared_signals}` loud-failure test at `:160-164`):
  - blocked producer (`%StepResult{name: "implementer", result: "BLOCKED: …",
    typed_output: %{"status" => "blocked"}}`) → `{:error, {:producer_blocked, "implementer"}}`;
  - atom `:blocked` variant (parity, cf. `:101`);
  - **`:partial` still `{:ok, …}`** (locks the scope decision);
  - a reviewer whose typed output carries a stray `"status" => "blocked"` still maps its verdict
    (proves the `lens != nil` exclusion);
  - `"status" => "completed"` unchanged (existing `:174-212` cover this).
- **`test/jido_claw/route_composer/composer_durable_test.exs`** (integration — model directly on
  `:222-237`): `put_in(TestFixtures.phase1_stub_outputs(), ["coder", "status"], "blocked")`,
  `run_sync`, assert `summary.terminal == :failed`, `:route_failed in kinds(...)`,
  `parent.status == :failed`, `parent.error` starts with `"failed:"`. Add the analogous blocked
  **planner** case (`["researcher", "status"]`) proving the planner→implementer edge now fails
  instead of advancing.
- **`test/jido_claw/agent/workers/worker_output_schemas_test.exs`** — `status` is now **required**
  on the researcher: update the existing researcher sample (`:102-117`) to carry `status` (assert it
  parses to the atom), and add a negative test asserting a sample **missing** `status` is rejected
  (proves required — this is the planner "absent status" coverage the reviewer asked for; the
  hermetic composer stubs are unaffected since they bypass Zoi). Also confirm no other test parses
  the real researcher schema without `status` (`grep`).

---

## Files to modify

**Production:**
- `lib/jido_claw/route_composer/emit/default_mapper.ex` — `refuse_blocked_producer/2` guard + moduledoc
- `lib/jido_claw/agent/workers/researcher.ex` — **required** `status` field + description
- `lib/jido_claw/route_composer/route_composer.ex` — doc reconciliation (`:2005-2010`, `:175-181`)
- `lib/jido_claw/agent/workers/output_schema.ex` — doc reconciliation (`:24-32`)

**Tests:**
- `test/jido_claw/route_composer/default_mapper_test.exs`
- `test/jido_claw/route_composer/composer_durable_test.exs`
- `test/jido_claw/agent/workers/worker_output_schemas_test.exs`

No changes needed to `wave_collect.ex`, `fold.ex`, `router.ex`, `loop.ex`, `commit.ex`,
`workflow_event.ex`, or `projection.ex`. **No new terminal kind, no projection/workflow_event
change, no `@type terminal` change** — the fix rides the existing `route_failed` rails, keeping
`mix precommit` (dialyzer terminal-union exhaustiveness, etc.) low-risk.

---

## Reused substrate (do not reinvent)

- `DefaultMapper.known/3` (`default_mapper.ex:146`) — the atom/string-tolerant status lookup.
- `WaveCollect.collect/4` halt-on-`{:error,_}` (`wave_collect.ex:56-62`) → `finish_failed`
  (`route_composer.ex:1370`) → `finish({:failed, reason})` → `route_failed` — the whole failure path
  already exists and is tested (`composer_durable_test.exs:222`).
- `Reason.format/1` (via `format_terminal_error(:failed, …)`, `route_composer.ex:~2953`) — formats
  the `{:producer_blocked, name}` tuple; the existing test only asserts the `"failed:"` prefix.
- `TestFixtures.phase1_stub_outputs/1` + `phase1_template_override/1` — the stub harness; the
  regression test only `put_in`s a `status` key (no new fixture/override → clone gate stays clean).

---

## Verification (definition of done)

1. **`mix precommit` green** — the binding bar (strict compile, format, credo, reach strict,
   dialyzer, full test). Run the full pipeline, never piped through `tail`.
2. **Unit** (`default_mapper_test.exs`): blocked (string + atom) producer → `{:error,
   {:producer_blocked, name}}`; `:partial` and reviewer-with-stray-status still `{:ok, …}`.
3. **Integration** (`composer_durable_test.exs`): blocked implementer **and** blocked planner →
   `:failed` / `:route_failed` / `error` starts `"failed:"` — proving neither advances a consumer
   nor silently converges.
4. **Targeted regression** (the suite the reviewer ran, must stay green):
   `mix test test/jido_claw/route_composer/composer_self_heal_loop_test.exs
   test/jido_claw/route_composer/default_mapper_test.exs
   test/jido_claw/agent/workers/worker_output_schemas_test.exs`.
5. **Schema** (`worker_output_schemas_test.exs`): researcher **requires** `status` — parses with it,
   rejects a sample missing it.
6. **Doc sweep**: `grep -rn "SELF-GUARD\|self-guard\|no status-gating"
   lib/jido_claw/route_composer lib/jido_claw/agent/workers/output_schema.ex` returns nothing stale
   (the false claim is gone; legitimate `drop-unsatisfiable` mechanism docs remain).
