# v0.4.3 Review Follow-Up

## Context

v0.4.3 introduced `auto` as the recommended reasoning selector and deprecated
`adaptive`. A post-merge review surfaced three leaks in the wiring plus two
residual risks. All findings verified against the code:

- **P1**: `AutoSelect` only excludes the literal names `react` and `adaptive`
  from auto picks. `StrategyStore` allows user aliases whose `base:` is one of
  those, and the classifier ranks every `StrategyRegistry.list/0` entry — so a
  `react`-based alias can win and crash (`:react` isn't a valid `RunStrategy`
  enum value), or an `adaptive`-based alias can win and silently reintroduce
  the nested selector that v0.4.3 removed.
- **P2a**: `Reason.run_auto/2` passes the classifier's pick straight to
  `Telemetry.with_outcome/4`. When that pick is a user alias, the
  `reasoning_outcomes.strategy` column stores the alias name, so
  `Statistics.best_strategies_for/2` fragments history across aliases instead
  of learning on `cot`/`tot`/etc.
- **P2b**: `/strategy <name>` now updates `state.strategy` and the
  `/strategies` view shows which is active, but `CLI.Repl.handle_message/2`
  never reads it. The REPL struct doesn't even declare a `:strategy` field.
  Selection is purely cosmetic.
- **Prompt drift**: Both system-prompt copies still say `adaptive |
  Auto-selects the best strategy…` and list `adaptive` in the "use reason
  when…" examples.
- **Strict compile**: `mix compile --warnings-as-errors` fails on the two
  Anubis patch modules because they redefine modules shipped by `anubis_mcp`.

The goal is to make the v0.4.3 surface match its story: `auto` is the real,
learnable default; aliases participate fairly without reintroducing selector
recursion; the REPL's `/strategy` choice actually influences subsequent turns;
docs match code; strict compile is green.

## Fix 1 — AutoSelect rejects aliases by resolved base

**Problem**: `@default_exclude ["react"]` is name-based; user aliases slip
through.

**Approach**: Add a base-level filter. The classifier already knows how to
resolve an alias back to its base via `StrategyRegistry.atom_for/1`.

- `lib/jido_claw/reasoning/classifier.ex:131` — extend `recommend/2` with a new
  `:exclude_bases` option (list of atoms). In the candidate pipeline after the
  existing `exclude` filter, drop any entry where
  `StrategyRegistry.atom_for(name)` resolves to an atom in `exclude_bases`.
  The existing `Enum.reject(&(&1.name == "adaptive"))` short-circuit stays —
  it's still the right check for the built-in `"adaptive"` row — but the new
  option covers aliases based on `:react` or `:adaptive`.
- `lib/jido_claw/reasoning/auto_select.ex:58` — replace `@default_exclude
  ["react"]` with `@default_exclude_bases [:react, :adaptive]`. In
  `select/2:84` pass `exclude_bases: @default_exclude_bases` instead of
  `exclude: @default_exclude`.
- Update the moduledoc and the `@doc` on `recommend/2` so the adaptive/react
  exclusion story reflects base-level filtering.

**Why `exclude_bases` and not hard-coding inside `recommend/2`**: `/classify`
and any future callers must still be able to see `react` in the pool. The
registry's self-filter of literal `"adaptive"` preserves the built-in's long-
standing "reachable by name, invisible to the ranker" behavior; the new
option is additive for callers that need stricter semantics.

## Fix 2 — Auto telemetry records the concrete base name

**Problem**: `Reason.run_auto/2:87` passes the classifier's user-facing pick
to `Telemetry.with_outcome/4`, so alias names land in
`reasoning_outcomes.strategy`.

**Approach**: Store `base_name` in the outcome row; preserve the alias (when
it differs) in `metadata` so diagnostics stay lossless.

- `lib/jido_claw/tools/reason.ex:65-91` — after resolving `base_name` (already
  computed at line 70), call `Telemetry.with_outcome(base_name, prompt, opts,
  fn -> runner.run(...) end)` instead of `Telemetry.with_outcome(concrete_strategy, …)`.
  Fold `alias_name: concrete_strategy` into the metadata map when
  `concrete_strategy != base_name`. Pass `base_name` (not `concrete_strategy`)
  to `format_runner_result/2` so the output surfaced to the agent matches the
  strategy that actually ran.
- Existing `reason_test.exs:154-193` still passes — it only asserts
  `refute result.strategy == "auto" / "adaptive"` and that a row with
  `selection_mode == "auto"` exists, both of which remain true.

## Fix 3 — REPL's `/strategy` actually influences chat turns

**Problem**: `CLI.Repl.handle_message/2` (line 210) sends the raw user
message to `Agent.ask/3` without ever reading `state.strategy`. The struct
at `repl.ex:9-18` doesn't even declare `:strategy`.

**Approach**: Thread strategy through from config → REPL state → boot banner
→ chat turns as a single source of truth. Project-wide default changes from
`"react"` to `"auto"` (the v0.4.3 story). The REPL prepends a one-line
preference hint to messages sent to the agent *but not* to messages saved
in session history, so history stays clean.

- `lib/jido_claw/core/config.ex:55` — change `@defaults["strategy"]` from
  `"react"` to `"auto"`. This is the product-default shift that aligns the
  rest of the system with the v0.4.3 story. `Config.strategy/1` already
  exists (line 104) and reads from this default.
- `lib/jido_claw/cli/repl.ex:9-18` — add `strategy: nil` to the struct.
  Not defaulted in the struct — the only correct source is `Config.strategy(config)`,
  set explicitly in `start/1` around line 153. Defaulting here would
  silently shadow `.jido/config.yaml`.
- `lib/jido_claw/cli/repl.ex:37-43` — pass `strategy: Config.strategy(config)`
  into `Branding.boot_sequence/2` (already accepts a `:strategy` opt at
  `branding.ex:46`, currently defaults to `"react"`). Banner, `/strategies`,
  and runtime all reflect the same value.
- `lib/jido_claw/cli/repl.ex:200-210` — extract a pure helper
  `prepare_user_message(message, strategy) :: String.t()` (marked `@doc
  false`, kept in the same module). Returns:
    - `message` unchanged for `"react"` (react is the agent's native loop —
      no hint needed).
    - `"[Reasoning preference: auto — invoke reason(strategy: \"auto\") for queries that benefit from structured reasoning; history-aware selection will pick a concrete strategy.]\n\n" <> message`
      for `"auto"`.
    - `"[Reasoning preference: #{strategy} — invoke reason(strategy: \"#{strategy}\") for queries that benefit from structured reasoning.]\n\n" <> message`
      for any other concrete strategy.
  **Ordering inside `handle_message/2`**: save the *raw* `message` via
  `Worker.add_message("default", state.session_id, :user, message)` first so
  session history captures what the user actually typed. Then compute
  `prepared = prepare_user_message(message, state.strategy)` and pass
  `prepared` to `Agent.ask/3`. The agent sees the hint; JSONL history does
  not.
- `lib/jido_claw/cli/commands.ex:603, 652` — replace `Map.get(state,
  :strategy, "react")` with `state.strategy`. Values are now guaranteed
  present (set at REPL init from Config).
- `lib/jido_claw/cli/commands.ex:635-637` — soften the copy to match reality.
  The choice is a *preference* the agent sees, not a dispatch override:
    - `"✓ Switched reasoning strategy to <name>"` →
      `"✓ Reasoning preference set to <name>"`
    - `"(Takes effect on next query)"` →
      `"(The agent will see this preference on the next query)"`
  Same softening at the `/strategy` (no arg) line 653 message and at
  `branding.ex:155` (`"Switch reasoning strategy"` → `"Set reasoning preference"`).

**Why hint, not hard dispatch**: Swapping the REPL to invoke `Reason.run/2`
directly for non-react strategies would strip tool-calling behavior. A
prompt hint keeps the agent's native react loop intact, surfaces the
preference visibly, and lets the LLM decide when to pull out `reason` based
on the query. The softened copy makes this preference-not-dispatch semantics
honest at the UX layer.

## Fix 4 — System prompts reflect the new selector name

- `priv/defaults/system_prompt.md:260` — swap the `adaptive` row for
  `| auto | Auto-selects the best strategy per prompt (history + heuristics) |`
  and move the row to the top of the table so the recommendation reads top-
  down. Drop the `adaptive` row entirely (it's still backward-compat
  accepted; it just shouldn't be advertised).
- `priv/defaults/system_prompt.md:267` — change `cot or adaptive` →
  `cot or auto` in the "Use reason when facing" bullet.
- `.jido/system_prompt.md:260, 267` — same edits, matching the defaults file.
  (The two files diverge normally because the project copy isn't auto-synced,
  per AGENTS.md; updating both manually is the expected workflow here.)

## Fix 5 — Strict compile passes on Anubis patches

**Problem**: `mix compile --warnings-as-errors` fails with
`redefining module Anubis.Server.Handlers.Tools` and `…Transport.STDIO`. Both
are intentional monkey-patches pending `anubis_mcp ~> 1.0`.

**Approach**: Declare `ignore_module_conflict: true` globally for the project
via `elixirc_options` in `mix.exs`. Honest framing:

- This is a **global suppression** for the whole compile run, not a
  file-scoped fix. Once set, every module-conflict warning — intentional or
  accidental — is silenced for that `mix compile`.
- Trade-off: an accidental `defmodule` that shadows an existing one would
  compile without warning. The mitigation is code review on new
  `defmodule`s plus the knowledge that we currently have exactly two
  intentional redefinitions, both living under `lib/jido_claw/core/`.
- This is explicitly temporary, paired with the existing header comments on
  both patch files saying "Remove this file once jido_mcp upgrades to
  anubis_mcp ~> 1.0." When the patches are removed, the `elixirc_options`
  entry should be removed with them.

Concrete change:

- `mix.exs` — in the `project/0` keyword list, add
  `elixirc_options: [ignore_module_conflict: true]` (merged with existing
  opts if any). Add an inline comment pointing at `lib/jido_claw/core/anubis_*`
  so the reason is discoverable at the top of the file.
- Cross-reference the trade-off in the `core/anubis_stdio_patch.ex` and
  `core/anubis_tools_handler_patch.ex` header comments — one sentence each,
  noting that strict compile relies on the `mix.exs` flag.
- Verify with `mix compile --warnings-as-errors` — should now be clean.

I considered and rejected two alternatives:
1. `Code.compiler_options/1` at the top of each patch file — sounds
   file-scoped but actually sets the flag globally for the compile session,
   with the added drawback that its activation depends on compile order.
   Worse than just setting it in `mix.exs` cleanly.
2. Moving patches to a separate OTP app or non-`elixirc_paths` directory
   compiled with different options — correct, but a much larger refactor
   than warranted for a patch slated for removal.

## Fix 6 — Test coverage for the gaps above

Current suite (`mix test test/jido_claw/reasoning test/jido_claw/tools/reason_test.exs`)
runs green but has no coverage for alias-based auto selection, concrete-winner
telemetry, or REPL strategy application. Add the following:

- `test/jido_claw/reasoning/auto_select_test.exs` — new describe block
  `"select/2 — alias exclusion"`. Copy the `with_user_strategy/2` helper
  pattern already in `test/jido_claw/reasoning/classifier_test.exs:258`
  and `test/jido_claw/tools/reason_test.exs:31` (writes a YAML into the
  live project's `.jido/strategies/`, calls `StrategyStore.reload/0`, runs
  the test, cleans up). Tests:
  - With a `react`-based alias seeded, `AutoSelect.select/2` never returns
    it even when history would favor it.
  - Same for an `adaptive`-based alias.
  - A `cot`-based alias with strong favorable history *can* be picked —
    verifies the base-exclusion is surgical, not over-broad.
- `test/jido_claw/tools/reason_test.exs` — the file already has
  `with_user_strategy/2` at line 31. Extend `"auto strategy"` describe:
  - When a user alias whose base is `cot` wins auto selection (seed
    favorable history for the alias via caller-supplied rows or force it
    deterministically), the outcome row's `strategy` column is `"cot"`
    (not the alias name), `base_strategy` is `"cot"`, and
    `metadata.alias_name` records the alias.
  - When a built-in wins (no alias involved), no `alias_name` key appears.
- `test/jido_claw/cli/repl_test.exs` (new file) —
  `describe "prepare_user_message/2"`:
  - `"react"` → message unchanged.
  - `"auto"` → message prepended with the auto-specific hint.
  - `"cot"` → message prepended with the concrete-strategy hint including
    `reason(strategy: "cot")`.
  Expose `prepare_user_message/2` as `@doc false` public (simplest; no
  macro or separate module needed). Pure function, no IO —
  `use ExUnit.Case, async: true`.

The four existing copies of `with_user_strategy/2` are a known duplication
smell but out of scope here — collapsing them into a single test helper
module is a separate cleanup.

No new tests for `mix compile --warnings-as-errors` — that's a CI concern,
not a unit test. Adding it to CI (if not already) is out of scope.

## Critical files

| File                                                       | Change                       |
| ---------------------------------------------------------- | ---------------------------- |
| `lib/jido_claw/reasoning/classifier.ex`                    | add `:exclude_bases` opt     |
| `lib/jido_claw/reasoning/auto_select.ex`                   | use `exclude_bases`          |
| `lib/jido_claw/tools/reason.ex`                            | telemetry = base_name        |
| `lib/jido_claw/core/config.ex`                             | default strategy = `"auto"`  |
| `lib/jido_claw/cli/repl.ex`                                | `:strategy` from Config + hint |
| `lib/jido_claw/cli/commands.ex`                            | read `state.strategy`, soften copy |
| `lib/jido_claw/cli/branding.ex`                            | soften `/strategy` help copy |
| `priv/defaults/system_prompt.md`                           | `adaptive` → `auto`          |
| `.jido/system_prompt.md`                                   | `adaptive` → `auto`          |
| `mix.exs`                                                  | `elixirc_options: [ignore_module_conflict: true]` + comment |
| `lib/jido_claw/core/anubis_stdio_patch.ex`                 | update header comment        |
| `lib/jido_claw/core/anubis_tools_handler_patch.ex`         | update header comment        |
| `test/jido_claw/reasoning/auto_select_test.exs`            | +alias exclusion tests       |
| `test/jido_claw/tools/reason_test.exs`                     | +base-name telemetry test    |
| `test/jido_claw/cli/repl_test.exs` (new)                   | `prepare_user_message/2`     |

## Verification

```bash
# 1. Strict compile (was failing; must now be green)
mix compile --warnings-as-errors

# 2. Format check
mix format --check-formatted

# 3. Full reasoning + tools + CLI suites
mix test test/jido_claw/reasoning test/jido_claw/tools/reason_test.exs test/jido_claw/cli

# 4. Manual REPL check: start the REPL, run /strategy auto, ask a casual
#    question, and verify the preference hint reaches the agent (visible
#    in -v logs or by tapping the signal bus).
iex -S mix jidoclaw
# > /strategy auto
# > Explain the difference between a struct and a map
# (Expect: agent considers invoking reason(strategy: "auto"); the outcome
# row, once written, has strategy = "cot"/"tot"/etc., never "auto".)

# 5. DB spot-check after a few auto turns — confirm no alias names leaked
#    into the strategy column.
mix ecto.migrate
# In psql or via tidewave project_eval:
#   JidoClaw.Repo.all(from r in JidoClaw.Reasoning.Resources.Outcome,
#     where: r.execution_kind == :strategy_run,
#     select: {r.strategy, r.base_strategy, r.metadata["alias_name"]})
# (Expect: `strategy` column is always one of cot/cod/tot/got/aot/trm;
# `alias_name` is set iff an alias won.)
```
