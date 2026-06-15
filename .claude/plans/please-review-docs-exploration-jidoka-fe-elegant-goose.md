# Plan: Finish V2-4 cleanups + close out the Jidoka-V2 borrowing program

## Context

Source: `docs/exploration/jidoka/FEATURES-WORTH-BORROWING-V2.md`.

The three V2 borrows the doc flags for **dedicated work** are all committed:
**V2-1** approval gate (`7fa6267`, `28a01ce`), **V2-2** external MCP consumption
(`3cde549`, `ce96f02`), and **V2-4** replay preflight diagnostics (`e8704be`,
including its P1/P2/P3 review fixes). Everything else in the doc is confirmed
*appropriately deferred* — out of threat model (V2-1 input/output-length
controls), superseded (V2-2 per-tool overlay), or watch/opportunistic
(V2-3 trace split, V2-5 eval harness, V2-6 web search, V2-7 Lua DAGs) — with no
demand signal and nothing secretly half-done.

So the borrowing program is substantively complete. What's left is **closing out
V2-4**: two small cleanups the committed V2-4 plan files explicitly flagged as
*optional follow-ups* but never did, plus updating the doc to reflect reality.
Both cleanups remove real duplication V2-4 left behind:

1. **`Safety.terminal_statuses/0` is a zero-caller function** — it was added in
   `e8704be` expressly as a fold target for the duplicated terminal-status lists,
   but the fold was never done, so we shipped a dangling accessor. Resolving it
   properly (per your choice) means making `WorkflowEvent.Projection` the single
   source of the terminal-status set and folding **all** copies onto it.
2. **The replay test fixtures are copy-pasted** — `test/support/replay_fixtures.ex`
   (`JidoClaw.Test.ReplayFixtures`) was extracted to be shared, but only the new
   `diagnostics_test.exs` uses it; `replay_test.exs` and `replay_workflow_test.exs`
   still carry their own private duplicates (a real drift risk for the fixture YAML).

Greenfield — no migration/back-compat concerns. **Outcome**: one source of truth
for the terminal-status set, one source for the replay test fixture, and a doc
that records the program as complete.

**Done = `mise exec -- mix precommit` passes.**

## Scope (decided with the user)

- **Terminal-list dedup → single source in `WorkflowEvent.Projection`** (the broad,
  layering-correct option; ~6 production files).
- **Test-fixture fold** → `replay_test.exs` fully; `replay_workflow_test.exs`
  lightly (it keeps its intentionally-different fixture).
- **Doc close-out** → V2-4 → ADOPTED + program-complete note + fix the stale V2-6
  `jido_browser` claim.
- **Deferred (not in this plan)**: the V2-4 "P1 consumer-attach" follow-up — see
  *Deferred* below for why.

---

## 1. Terminal-status single source (`WorkflowEvent.Projection`)

The literal `[:completed, :failed, :cancelled, :abandoned]` is hand-copied in
**five** modules today:

| Site | Use context | Fold to |
| --- | --- | --- |
| `lib/jido_claw/orchestration/workflow_event/projection.ex` | — (owns the complement `@non_terminal`) | **becomes the source** |
| `lib/jido_claw/orchestration/replay/safety.ex:22` | `terminal_statuses/0` (dangling) + `terminal_status?/1` | delegate; **delete** `terminal_statuses/0` |
| `lib/jido_claw/orchestration/cancellation.ex:69` | **guard** (`:109`) + runtime (`:183`) | compile-time attr |
| `lib/jido_claw/orchestration/reactor_middleware.ex:115` | **guard** (`:173`) | compile-time attr |
| `lib/jido_claw/workflow_view.ex:15` | runtime arg (`:67`) | direct call |
| `lib/jido_claw/web/live/workflows_live.ex:16` | runtime body (`:462`) | direct call |

### 1a. Add the canonical accessors to `Projection`

`Projection` is a pure, dependency-free lifecycle state machine (it already owns
`@non_terminal [:pending, :running, :awaiting_approval]` at `projection.ex:47` and
`next_status/2`) with **no back-references to any consumer** — so consumers
depending on it (even at compile time) is cycle-free and is the correct layering
home. Add, next to `@non_terminal`:

```elixir
# The terminal run statuses — a run here can no longer make progress.
# Complement of @non_terminal; the single source every other module folds onto.
@terminal [:completed, :failed, :cancelled, :abandoned]

@doc "The terminal run statuses (the run can no longer make progress)."
@spec terminal_statuses() :: [atom()]
def terminal_statuses, do: @terminal

@doc "Whether `status` is terminal. Total: a non-atom returns false."
@spec terminal_status?(term()) :: boolean()
def terminal_status?(status) when is_atom(status), do: status in @terminal
def terminal_status?(_status), do: false
```

(`@doc` + `@spec` are required by the credo gate for new public functions.) The
**total** second clause is deliberate: the old `WorkflowsLive` body was `status in
@terminal`, which returns `false` for `nil`/weird values rather than raising — so
the canonical fn must preserve that (real `WorkflowRun.status` is a non-nil atom,
but the LiveView shouldn't crash on a stray value). The `@spec` is `term()` from
the start — the function is intentionally total, so the contract should say so
directly rather than wait for dialyzer to flag an `atom()`-only spec against the
catch-all.

### 1b. Fold the runtime sites (direct calls)

- `workflow_view.ex`: delete `@terminal_statuses` (line 15); at line 67 call
  `Projection.terminal_statuses()`; add `alias JidoClaw.Orchestration.WorkflowEvent.Projection`.
- `workflows_live.ex`: delete `@terminal` (line 16); rewrite `replayable?/1`
  (line 462) as `defp replayable?(status), do: Projection.terminal_status?(status)`;
  add the same alias. **Note:** this changes only a `defp` body — it adds **no new
  assign**, so the WorkflowsLive render-assigns triad (the 3-test-file hazard) is
  *not* triggered.

### 1c. Fold the guard sites (compile-time attribute substitution)

`when status in @terminal` is a guard; a runtime function call is illegal there.
But a module attribute is evaluated at compile time, so assigning it the *result*
of `Projection.terminal_statuses()` bakes a literal list into the guard:

```elixir
alias JidoClaw.Orchestration.WorkflowEvent.Projection
# replaces the hand-copied literal; the compile-time call bakes the literal list
# into the guard at `... when status in @terminal`.
@terminal Projection.terminal_statuses()
```

Apply in **`cancellation.ex`** (uses at `:109` guard + `:183` runtime — both keep
`status in @terminal` unchanged) and **`reactor_middleware.ex`** (use at `:173`
guard). Add the alias to each if absent (neither references `Projection` today).
*(Equally valid alternative if preferred: a `defguard is_terminal_status/1` on
`Projection` + `require Projection` in the consumers. The attribute form is
simpler and needs no `require`.)*

### 1d. Collapse `Safety`

In `replay/safety.ex`: **delete** `terminal_statuses/0` (now zero callers — its
purpose is superseded by `Projection`); remove the `@terminal` attribute; rewrite
`terminal_status?/1` to delegate — `def terminal_status?(status), do:
Projection.terminal_status?(status)` — keeping its existing callers
(`replay.ex:143`, `diagnostics.ex:232`) unchanged. Dropping Safety's own
`when is_atom(status)` guard is intentional — `Projection.terminal_status?/1` is
now total, so the delegate stays total (callers pass atoms regardless). Add the
`Projection` alias and update the Safety moduledoc bullet (the "mirrors / single source the duplicated
terminal lists can fold onto" wording is now stale — it *delegates to* Projection).

### 1e. The non-terminal/active set — explicitly out of scope (future cleanup)

The complement set `[:pending, :running, :awaiting_approval]` is *also* duplicated
across run-status consumers (`workflow_view.ex:14` `@active_statuses`,
`workflows_live.ex:466` `cancellable?/1`, `reactor_runner.ex:188` `@non_terminal`,
and the two Ash `filter(expr(...))` reads `workflow_run.ex:165`/`:171`). It is
**not** in this pass: the user scoped this cleanup to the *terminal* list, and a
non-terminal fold is genuinely harder — the two `workflow_run.ex` sites are Ash
expression contexts where a plain runtime call won't fold cleanly, and
`:pending`/`:running` also appear in **step-status** checks that must **not** be
swept in. If pursued later it's a parallel "single-source the non-terminal set in
`Projection`" pass (add `Projection.non_terminal_statuses/0`), explicitly scoped to
run-status consumers only. Recorded here so the omission is deliberate, not missed.

---

## 2. Test-fixture single source (`JidoClaw.Test.ReplayFixtures`)

`test/support/replay_fixtures.ex` already exposes public `fixture_name/0`,
`fixture_yaml/0`, `module_config/0`, `tmp_project_dir!/0`, `write_fixture!/1,2`,
`launch_fixture!/2,3,4`, `forge_terminal_run!/2`.

**Gotcha A — any helper kept locally must not clash with `import`.** A local
`def`/`defp` of the same name+arity as an imported function is a compile error. So
the mechanism differs per file by how much each keeps local:
- `replay_test.exs` shares almost everything (identical fixture) and keeps only a
  local `launch_fixture!` → `import JidoClaw.Test.ReplayFixtures, except:
  [launch_fixture!: 2, launch_fixture!: 3, launch_fixture!: 4]` (the shared fn's
  defaulted arities); the local wrapper calls `ReplayFixtures.launch_fixture!/4`.
- `replay_workflow_test.exs` keeps **both** a local `write_fixture!` *and*
  `launch_fixture!` (distinct fixture — see Gotcha C), so the cleaner move is **no
  `import`**: `alias JidoClaw.Test.ReplayFixtures` and qualify the one helper it
  borrows (`ReplayFixtures.tmp_project_dir!()`), sidestepping the `except` list
  entirely. (`diagnostics_test.exs` uses `import`; mixing styles across files is fine.)

**Gotcha B — the `:completed` assertion.** Each file's local `launch_fixture!`
does `assert run.status == :completed` and only handles the `{:ok,...}` path; the
shared `ReplayFixtures.launch_fixture!` deliberately returns the run for *both*
ok/error (to serve failure-path diagnostics tests) and does **not** assert. So the
local wrappers must keep the `assert run.status == :completed` after delegating.

**Gotcha C — different fixtures.** `replay_test.exs`'s `@fixture_yaml` (lines
36-48) is *identical* to `ReplayFixtures.fixture_yaml/0` (alpha→beta) → fold fully.
`replay_workflow_test.exs`'s `@fixture_yaml` (lines 25-33) is an intentionally
*different* single-step skill → it must keep its own YAML; do **not** route it
through the shared `write_fixture!`'s default (which writes the 2-step YAML).

### `replay_test.exs` (full fold)

- Add the `import ... except: [launch_fixture!: 2, launch_fixture!: 3, launch_fixture!: 4]` line.
- Delete the private `@fixture_name`/`@fixture_yaml` (34-48), `tmp_project_dir!`
  (796), `write_fixture!` (803), `forge_terminal_run!` (836), `module_config` (852).
  (Importing the shared `write_fixture!` is safe here — its default YAML is
  *identical* to this file's, so the no-arg `write_fixture!(dir)` calls are unchanged.)
- Keep a thin local `launch_fixture!(dir, ctx, overrides \\ %{}, inputs \\
  %{extra_context: "initial"})` that does `run = ReplayFixtures.launch_fixture!(dir,
  ctx, overrides, inputs); assert run.status == :completed; run`.
- Replace references to the old `@fixture_yaml`/`@fixture_name` (e.g. the disk-edit
  tests' `String.replace`, `Skills.load_skill`) with `fixture_yaml()`/`fixture_name()`.
- **Alias hygiene:** the now-delegating local `launch_fixture!` no longer calls
  `Compiler.compile`, so `alias JidoClaw.Skills.Compiler` (line 27) becomes unused
  → remove it (`compile_check` blocks on unused aliases). `Skills`/`ReactorRunner`/
  `DefinitionFingerprint` stay — still used by direct-run test bodies (e.g. the
  disk-edit `Skills.load_skill`).

### `replay_workflow_test.exs` (light fold — minimal, regression-aware)

This file's fixture is **intentionally different** (a 1-step `researcher`-only
skill; setup at lines 39-41 configures only `researcher`), so it is *not*
redundant with the shared YAML — keep it local. Share only the content-free helper.

- `alias JidoClaw.Test.ReplayFixtures` (no `import` — Gotcha A).
- **Keep local** `@fixture_yaml`/`@fixture_name` **and** `write_fixture!(dir, yaml \\
  @fixture_yaml)` — its default must stay this file's 1-step YAML.
  **The regression to avoid (finding #1):** the no-arg `write_fixture!(dir)` at
  `replay_workflow_test.exs:74` (and `&write_fixture!/1` at `:196`) relies on that
  default; if `write_fixture!` resolved to the shared 2-step
  `researcher`+`docs_writer` YAML, the unconfigured `docs_writer` step would run.
  Keeping `write_fixture!` local prevents it (it *may* delegate its body to
  `ReplayFixtures.write_fixture!(dir, yaml)` to share the path, but the default
  stays `@fixture_yaml`). This preserves the `:74`/`:77`/`:94` call sites exactly.
- Replace the private `tmp_project_dir!` (184) call sites with
  `ReplayFixtures.tmp_project_dir!()`; delete the private `tmp_project_dir!`.
- Keep the bespoke `launch_fixture!(ctx, dir \\ nil)`; **delegate** its run
  mechanics to `ReplayFixtures.launch_fixture!(dir, ctx, %{}, %{extra_context:
  ""})` after writing its own YAML, then `assert run.status == :completed`. (Shared
  launch passes `deadline: skill.deadline`; the 1-step fixture has no `deadline:`
  field → `nil` → behavior unchanged; verify during impl.)
- **Alias hygiene:** once `launch_fixture!` delegates (and `write_fixture!` delegates
  its body to `ReplayFixtures.write_fixture!/2`), `DefinitionFingerprint`,
  `ReactorRunner`, `Skills`, and `Compiler` (lines 16-19) are all unused → remove
  all four (`compile_check` blocks on unused aliases); the file then needs only
  `alias ReplayFixtures`. (If you instead keep the local run mechanics, keep those aliases.)

---

## 3. Doc close-out — `docs/exploration/jidoka/FEATURES-WORTH-BORROWING-V2.md`

Surgical edits, in the doc's existing voice:

- **V2-4 entry** (lines 80-86): change status to **ADOPTED** with a dated
  (2026-06-15) note: `Replay.diagnose/2` shipped (`e8704be`) — the two-axis
  recorded-health/replay-safety projection, surfaced in the `replay_workflow` MCP
  refusal detail (`to_mcp_map/1`) and the dashboard replay panel, with the P1/P2/P3
  review fixes folded in; the terminal-status set is now single-sourced in
  `Projection` and the replay test fixtures consolidated onto `ReplayFixtures`.
  Note the one remaining deferred follow-up (P1 consumer-attach — see below).
- **Sequencing section** (137-139): add a line that the three dedicated-work
  borrows (V2-1/V2-2/V2-4) are all shipped, so the active borrowing program is
  complete; V2-3/V2-5/V2-6/V2-7 remain watch/opportunistic per their entries.
- **V2-6 entry** (line ~102): fix the stale claim "the `jido_browser` dep, which
  jido_radclaw doesn't pull today" — `jido_browser ~> 2.0` *is* in `mix.exs:153`
  (its Brave-backed `SearchWeb` is already compiled), so V2-6 is cheaper than
  stated: a wrapped `search_web` tool + a Brave API key, no new dependency. (Doc
  accuracy only; V2-6 stays NOT_ADOPTED/deferred.)

---

## Deferred (explicitly, with rationale)

**V2-4 "P1 consumer-attach"** — making `replay_workflow.ex`'s `refusal_error/4`
(and `workflows_live.ex`'s catch-all) attach diagnostics on the raw-read-error
refusal path. Left out because it is **not** the clean one-clause change it first
appears: that path bubbles an *arbitrary* error term from `WorkflowEvent.for_run/3`
failing inside `replay.ex`'s `check_irreversible`, and the consumer catch-all also
legitimately handles `:not_found`/`:launch_failed` (which must *not* get
diagnostics). Doing it cleanly needs a `replay.ex` refusal-vocabulary normalization
(surface `{:not_replayable, :irreversible_check_failed}` so the existing
`{:not_replayable, _}` clause picks it up). And the path **self-degrades** anyway —
the same DB fault that breaks replay's event read also breaks `diagnose/2`'s own
event read, which degrades silently by design — and it's **untestable without
adding Mox** (the committed P1/P2/P3 plan documented this gap). Net negative for now;
flagged in the doc as the lone deferred V2-4 follow-up.

---

## Files to change

**Production (terminal-status single source):**
- `lib/jido_claw/orchestration/workflow_event/projection.ex` — new `@terminal` +
  `terminal_statuses/0` + total `terminal_status?/1`. (Non-terminal set out of scope — §1e.)
- `lib/jido_claw/orchestration/replay/safety.ex` — delete `terminal_statuses/0`,
  remove `@terminal`, delegate `terminal_status?/1`, alias + moduledoc fix.
- `lib/jido_claw/orchestration/cancellation.ex` — `@terminal Projection.terminal_statuses()` + alias.
- `lib/jido_claw/orchestration/reactor_middleware.ex` — same.
- `lib/jido_claw/workflow_view.ex` — `Projection.terminal_statuses()` at use site, remove attr, alias.
- `lib/jido_claw/web/live/workflows_live.ex` — `replayable?/1` → `Projection.terminal_status?/1`, remove attr, alias.

**Tests (fixture single source):**
- `test/jido_claw/orchestration/replay_test.exs` — full fold onto `ReplayFixtures`.
- `test/jido_claw/tools/replay_workflow_test.exs` — light fold: share only `tmp_project_dir!`; keep its distinct 1-step YAML + local `write_fixture!` (finding #1).

**Doc:**
- `docs/exploration/jidoka/FEATURES-WORTH-BORROWING-V2.md` — V2-4 → ADOPTED, program-complete note, V2-6 dep-claim fix.

No new WorkflowsLive assign, no `mcp_*`/approval/MCP surface touched, no Ash
resource or migration. The `reach` smells (`fixed_shape_map`/`behaviour_candidate`)
shouldn't fire on small list/bool accessors — confirm via the gate.

## Test plan & verification

Run via `mise exec -- mix` (toolchain = mise latest, OTP 29 / Elixir 1.20).

1. **Touched suites first** (fast feedback on the refactor):
   `mise exec -- mix test test/jido_claw/orchestration/ test/jido_claw/workflow_view_test.exs test/jido_claw/web/live/workflows_live_test.exs test/jido_claw/tools/replay_workflow_test.exs`
   — `workflow_view_test.exs` lives *outside* `orchestration/`, so it must be named
   explicitly (the glob misses it). Covers Projection, Cancellation,
   ReactorMiddleware, WorkflowView, the replay suite + diagnostics, WorkflowsLive,
   and the replay tool. The existing replay
   taxonomy is the regression net proving the terminal-gate behavior is unchanged;
   the guard sites (cancellation/reactor_middleware) are exercised by their
   `:already_terminal` / `:run_already_terminal` tests.
2. **Manual smoke** (optional, Tidewave `project_eval`): `Projection.terminal_statuses()`
   returns the list; a guard still matches (e.g. cancelling an already-completed run
   returns `:already_terminal`); `Safety.terminal_status?(:completed) == true`.
3. **The gate (definition of done):** `mise exec -- mix precommit` run **bare**
   (never piped — `| tail` masks the exit code) in the background, then read the
   output tail. It runs `jidoclaw.compile_check` (watch for any leftover unused
   `@terminal`/alias — a real blocker), `format --check-formatted`,
   `reach.check --smells --strict`, `credo --strict` (`@doc`+`@spec` on the new
   `Projection` fns), `dialyzer` (the `[atom()]`/`boolean()` specs), and `test`.
   **Not complete until `mix precommit` passes.**

Note: the Stop hook's `compile --warnings-as-errors` always fails on the 2
intentional `pull_request_coordinator` warnings — expected, **not** a signal from
this change; trust `jidoclaw.compile_check`/`precommit`, which tolerate exactly
those two.

## Suggested commit (do not run — leave unstaged)

After `mix precommit` passes, three focused commits make sense (or squash to one):

```
refactor: single-source the terminal-status set in WorkflowEvent.Projection

Fold the five hand-copied [:completed, :failed, :cancelled, :abandoned] lists
(workflow_view, workflows_live, cancellation, reactor_middleware, replay/safety)
onto Projection.terminal_statuses/0 + terminal_status?/1 — guard sites via
compile-time attribute substitution, runtime sites via direct calls. Removes the
zero-caller Safety.terminal_statuses/0 left as a fold target by the V2-4 commit.

test: consolidate replay fixtures onto JidoClaw.Test.ReplayFixtures

Fold replay_test.exs fully and replay_workflow_test.exs's generic helpers onto the
shared support module (replay_workflow_test keeps its distinct 1-step fixture).

docs: mark V2-4 ADOPTED and the Jidoka-V2 borrowing program complete
```
