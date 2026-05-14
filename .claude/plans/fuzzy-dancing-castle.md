# Dialyzer cleanup (round 1)

## Context

We just finished a Credo cleanup pass. Next target: the 9 dialyzer findings in
`.harness/latest.json`. They cluster into three groups, two of which share a
single root cause. Resolving all nine fits comfortably in one effort because the
bulk of the work is a small set of spec tightenings — no behavior changes.

## Findings, grouped

### Group A — `verify_certificate.ex` (7 findings, one root cause)

Lines 104/108/111 (`pattern_match`), 114/117 (`pattern_match_cov`), 130
(`no_return` on `run_reasoning/2`), 208 (`unused_fun` on `maybe_persist/4`).

**Root cause:** two upstream specs are too generic, so dialyzer cannot prove the
success path through `run_reasoning/2` and narrows the `else` block of `run/2`
in a way that makes the specific error atoms appear unreachable.

1. `JidoClaw.Reasoning.Telemetry.with_outcome/4` is declared as
   `(-> fun_result()) :: fun_result()` with
   `fun_result :: {:ok, map()} | {:error, term()}`. The `:ok` branch loses the
   shape of the inner map (it strips `%{certificate: _}` down to `map()`).
2. `JidoClaw.Reasoning.Certificates.parse_certificate/1` is declared as
   `:: {:ok, map()} | {:error, atom()}`. The specific atoms
   (`:no_certificate`, `:invalid_json`, `:invalid_shape`) get widened to
   `atom()`, then further widened through `execute_cert/2` →
   `with_outcome/4`'s `{:error, term()}`.

The `no_return` on `run_reasoning/2` and the `unused_fun` on `maybe_persist/4`
are downstream effects of (1): once dialyzer believes `run_reasoning/2` never
succeeds, the `with` in `run/2` is treated as always falling into `else`, and
the success arm (which is the only path that calls `maybe_persist/4`) is
considered unreachable.

### Group B — `pull_request_coordinator.ex` (1 finding)

Line 11 `guard_fail` on `do_attempt/5 when attempt > @max_attempts`.

**Root cause:** `validate_quality/1` is a stub that hardcodes
`{:ok, %{passed: true, checks: []}}`, so the retry path is unreachable. This
module is intentional scaffolding (all four files under
`lib/jido_claw/github/agents/` are stubs landed in the same commit) — the retry
loop is the deliberate hook for the "Iterative Evaluation" follow-up. We don't
want to delete the scaffold, and we don't want to lie to dialyzer with a fake
spec that the body contradicts.

### Group C — `deps/postgrex/lib/postgrex/type_module.ex` (1 finding)

Line 1045 `improper_list_constr` inside postgrex 0.22.1 (the project has no
`.dialyzer_ignore.exs` today — `mix.exs:37-42`).

## Approach

### Group A — tighten two specs (root cause fix)

**File:** `lib/jido_claw/reasoning/telemetry.ex:20-51`

- Make `fun_result` generic over its success-map shape and thread that variable
  through `with_outcome/4`:

  ```elixir
  @type fun_result(success) :: {:ok, success} | {:error, term()}

  @spec with_outcome(String.t(), String.t(), opts(), (-> fun_result(success))) ::
          fun_result(success)
        when success: map()
  ```

  Behavior is unchanged; the `try/rescue/catch` paths still produce
  `{:error, _}`, which fits the spec. Callers that already return plain
  `{:ok, map()}` continue to typecheck (`success` instantiates to `map()`).

- While touching this type, add the actually-used keys
  `:workspace_id` and `:agent_id` to `opts()` (lines 22-35). Both are passed
  by `verify_certificate.ex:143,147` and by `run_pipeline.ex`, but are absent
  from the type today.

**File:** `lib/jido_claw/reasoning/certificates.ex:299`

- Introduce a named error type and narrow the spec:

  ```elixir
  @type parse_error :: :no_certificate | :invalid_json | :invalid_shape

  @spec parse_certificate(String.t()) :: {:ok, map()} | {:error, parse_error()}
  ```

  Keep the input as `String.t()`. The non-binary fallback at line 308 is
  exercised by `test/jido_claw/reasoning/certificates_test.exs` (passing
  `nil`/`42` returns `{:error, :no_certificate}`), but every runtime caller
  feeds it `Output.extract_output/1`, which is spec'd to return `String.t()`.
  We're declaring the public contract — "pass a string" — and leaving the
  defensive clause as a belt-and-braces guard.

No edits to `verify_certificate.ex` itself — the cascade clears once dialyzer
can prove the success path and propagate the specific atoms.

### Group B — strict ignore entry, tied to the follow-up work

**File:** `.dialyzer_ignore.exs` (new file, see Group C)

Add a strict 3-tuple entry alongside the postgrex one:

```elixir
# Iterative Evaluation scaffolding: validate_quality/1 is a stub that
# hardcodes success, so the retry path in do_attempt/5 is unreachable and
# the @max_attempts guard can't fire yet. Remove this entry when
# validate_quality is fleshed out (or made injectable) as part of the
# Iterative Evaluation work — see commit 220ca05.
{"lib/jido_claw/github/agents/pull_request_coordinator.ex", :guard_fail, 11}
```

No source edits to the coordinator; the scaffold stays as-is, and the
suppression is narrow (one warning kind, one line) so any new finding in this
file still surfaces.

### Group C — narrow ignore entry for the postgrex finding

**New file:** `.dialyzer_ignore.exs`

```elixir
# Findings we can't fix locally. Use strict 3-tuple form
# {path, warning_kind, line} so suppression is scoped to the exact finding.
[
  # postgrex 0.22.1 — improper_list_constr at type_module.ex:1045. Upstream
  # behavior; revisit on the next postgrex bump.
  {"deps/postgrex/lib/postgrex/type_module.ex", :improper_list_constr, 1045},

  # See Group B above.
  {"lib/jido_claw/github/agents/pull_request_coordinator.ex", :guard_fail, 11}
]
```

**File:** `mix.exs:37-42`

Wire the ignore file into the dialyzer config:

```elixir
dialyzer: [
  plt_local_path: "priv/plts/dialyzer.plt",
  plt_core_path: "priv/plts/dialyzer-core.plt",
  plt_add_apps: [:ex_unit, :mix, :nostrum, :llm_db],
  flags: [:error_handling, :unknown, :no_opaque],
  ignore_warnings: ".dialyzer_ignore.exs"
]
```

`mix dialyzer` applies the ignore file before producing output, so the
`ex_harness` runner (which parses `mix dialyzer --format short --quiet`
unfiltered — see `deps/ex_harness/lib/ex_harness/dialyzer_runner.ex`) will no
longer count these two findings.

## Files modified

- `lib/jido_claw/reasoning/telemetry.ex` — generic `fun_result`, threaded spec, `:workspace_id`/`:agent_id` added to `opts()`
- `lib/jido_claw/reasoning/certificates.ex` — named `parse_error` type, tighter `parse_certificate/1` spec
- `mix.exs` — `:ignore_warnings` key
- `.dialyzer_ignore.exs` — new file, two strict entries

No edits to `pull_request_coordinator.ex` or `verify_certificate.ex`.

## Verification

1. `mix compile --warnings-as-errors` — confirm no new compile warnings from
   the spec changes.
2. `mix dialyzer` — expect all 9 findings cleared: 7 resolved by Group A's
   spec fixes (5 direct pattern/coverage warnings in `verify_certificate.ex`
   plus the 2 downstream `no_return`/`unused_fun` warnings), and 2 suppressed
   by the ignore file (PR coordinator guard, postgrex improper list).
3. `mix test test/jido_claw/tools/verify_certificate_test.exs` and
   `test/jido_claw/reasoning/` — confirm Group A spec tightening hasn't broken
   any caller at runtime. `with_outcome/4` has multiple call sites; `mix
   dialyzer` is the authoritative check, but the test suite gives faster
   feedback on regressions.
4. Re-run the harness and verify `dialyzer.summary.total` drops from 9 to 0
   in `.harness/latest.json`.

## Out of scope

- Fleshing out the GitHub PR coordinator scaffolding (TriageAgent /
  ResearchCoordinator / CoordinatorAgent / PullRequestCoordinator). The Group
  B ignore entry is explicitly tied to that follow-up.
- Upgrading postgrex past 0.22.1. The ignore entry is a placeholder until a
  routine dep bump removes the underlying warning.
