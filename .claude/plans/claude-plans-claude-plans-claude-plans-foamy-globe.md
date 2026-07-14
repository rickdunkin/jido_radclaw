# Plan: post-review round 2 — compile gate drops the Jido.Exec fork; escript `run` loses pre-boot env

## Context

The ancient-island post-review round (Jido.Exec fork + escript `app: nil` boot
chain) is implemented and sits unstaged. A new review reported two P1
findings; **both verified real** against the working tree:

**P1-1 — `jidoclaw.compile_check` removes the generated `Jido.Exec` fork
(VALIDATED).** The gate's sequence
([jidoclaw.compile_check.ex:42-63](lib/mix/tasks/jidoclaw.compile_check.ex))
runs `clean` → `compile.elixir` → `compile.app`, but never
`compile.jidoclaw_release_patches` — the custom compiler whose
`ensure_exec_fork!` is the fork BEAM's only writer
([compile.jidoclaw_release_patches.ex:47](lib/mix/tasks/compile.jidoclaw_release_patches.ex)).
`clean` deletes the app ebin (fork included); `compile.elixir` never runs
custom compilers; Mix's `compile.app` derives `:modules` from an ebin beam
scan (verified in installed Mix source, `modules_from/1`), so the regenerated
`jido_claw.app` also omits `Jido.Exec`. `DependencyPatches.ensure_loaded!`
prefers the app ebin but falls back to the dep BEAM — upstream, unpatched in
dev/test — so a post-gate no-recompile boot silently loses the tier-1
provenance witness. The inventory comment in `dependency_patches.ex` ("the
app-ebin candidate always exists in dev/test") is broken by exactly this
sequence. `mix precommit` masks it end-to-end only because the partitioned
test phase spawns fresh `mix` sessions whose full `compile` re-runs the
custom compiler.

**P1-2 — the escript `run` path loses its pre-boot mode/model config
(VALIDATED).** `RunCommand.boot/2`
([run_command.ex:240-246](lib/jido_claw/cli/run_command.ex)) uses
NON-persistent `Application.put_env/3` for `:jido_ai :model_aliases`,
`:jido_claw :mode / :skip_discord / :project_dir`, then the escript's boot fn
runs `ensure_all_started(:jido_claw)`
([main.ex:61-69](lib/jido_claw/cli/main.ex)). Under the escript's `app: nil`,
nothing is loaded when `boot/2` runs; Mix's generated escript main applies the
embedded config with `:application.set_env(..., persistent: true)` (verified
in installed Mix source, escript.build.ex:390) BEFORE `main/1`, and
`config.exs` sets `mode: :both` + the model-alias catalog — so
`Application.load` re-applies those spec/persistent entries over the plain
puts and clobbers the two CONFIG-DEFINED values: the one-shot binary boots
Phoenix (`:both`) and uses config-default models. (`:project_dir` and
`:skip_discord` are absent from config; `Application.load/1` preserves
pre-load keys the spec/persistent set doesn't define, so those two survive
today — the fix protects all four uniformly anyway.) Every OTHER escript
branch in `main.ex` already uses
`persistent: true` with a comment describing exactly this hazard
(main.ex:78-82, 156-166); the run path was missed, and the no-op boot stub in
[run_command_test.exs:114](test/jido_claw/cli/run_command_test.exs) can never
expose it. The `mix jidoclaw run` path is unaffected (Mix loads the app before
the task runs, so post-load puts stick — and persistent puts behave
identically there).

**Coverage decision (operator-approved):** for P1-1, instead of a literal
subprocess integration test (full app recompile + `_build` copy, ~1-2 min
added to every suite run), `compile_check` SELF-ASSERTS at the end of its
sequence — the assert executes the real sequence on the real build on every
precommit, which is strictly more frequent than a suite row — plus fast
path-parameterized unit rows for the assert helper.

Greenfield: no compat shims. Nothing gets committed; work lands unstaged and
folds into the existing #16 commit-2 slice.

---

## Fix 1 — `lib/mix/tasks/jidoclaw.compile_check.ex`: regenerate + self-assert the fork

Restructure `run/1` (behavior-preserving for the diagnostics surface):

1. `Task.rerun("clean", [])` — unchanged.
2. `Task.rerun("compile.elixir", ["--return-errors"])` — unchanged capture.
3. Split `{tolerated, blocking}` and, when `blocking != []`, print + raise
   **immediately** (tolerated logging stays). Rationale: with compile errors
   the `JidoClaw.Core.JidoExecPatch` beam may not exist, and running the
   patch compiler first would raise `Code.ensure_loaded!` noise INSTEAD of
   the real diagnostics list. Skipping the artifact steps on a failing gate
   is safe — precommit halts, no later same-session steps run.
4. On the clean/warning-tolerated path: `Mix.Project.build_structure()`
   (existing), then
   **`{_status, patch_diags} = Task.rerun("compile.jidoclaw_release_patches", [])`**
   (NEW — comment: this compiler is the generated `Jido.Exec` fork's only
   writer; `clean` removed the app-side BEAM and `compile.elixir` never runs
   custom compilers; it must precede `compile.app`, whose modules list is an
   ebin beam scan). Run `patch_diags` through the SAME allowlist split and
   print + raise on any blocking diagnostic — the fork's own compilation
   must not bypass the strict warning gate (see the generator change below).
   Then `Task.rerun("compile.app", [])` (existing), then
   **`assert_exec_fork!()`** (NEW), then the OK message (tolerated counts
   cover both diagnostic sources).

**Generator + compiler-task diagnostics plumbing** (the fork compiles via
`Code.compile_string/2` inside `JidoExecPatch.compile_patched!/1`, whose
warnings today are printed at best and returned nowhere — the gate can
report zero blocking warnings while the generated module emitted one):

- `lib/jido_claw/core/jido_exec_patch.ex`: the `Code.compile_string` call
  moves into a small `compile_with_diagnostics(source, file)` seam wrapping
  it in `Code.with_diagnostics/2` (used by `compile_patched!/1` — and
  directly testable with synthetic warning source); `generate!/2` returns
  the captured diagnostics list (was `:ok`), `verify_or_regenerate!/2`
  returns `:current | {:generated, [diagnostic]}` (greenfield — change the
  shapes, update the existing `jido_exec_patch_test.exs` rows that assert
  `:generated`/`:current`, and add `{:generated, []}` assertions — the
  pinned fork compiles warning-free today, so the empty list is also a
  canary).
- `lib/mix/tasks/compile.jidoclaw_release_patches.ex`: `run/1` returns the
  proper `Mix.Task.Compiler` contract — `{:ok | :noop, [Diagnostic.t()]}` —
  via a public map→`Mix.Task.Compiler.Diagnostic` conversion helper, and
  printing any warning via `Mix.shell()` so normal `mix compile` keeps
  them visible (`with_diagnostics` captures instead of printing).
- `lib/mix/tasks/jidoclaw.compile_check.ex`: the allowlist split becomes a
  public `split_diagnostics/1` (`{tolerated, blocking}`) that `run/1` uses
  for BOTH diagnostic sources — unit-testable without running the task.

**Red-path rows** (an implementation that accidentally DISCARDS captured
diagnostics must not pass a warning-free build): in
`jido_exec_patch_test.exs`, compile a tiny synthetic module with a
deliberate warning (unused variable; unique module name) through
`compile_with_diagnostics/2` and assert a non-empty diagnostics list with
the expected message — the same seam the real fork compile uses. In the new
compile_check test file: a synthetic captured-map diagnostic converts to a
well-formed `Diagnostic` struct (severity/file/message/position/
compiler_name), and `split_diagnostics/1` puts a synthetic warning
diagnostic into `blocking` under the current EMPTY allowlist.

`assert_exec_fork!/2` — public, path-parameterized AND **ownership-aware**
(`@doc` + `@spec`; the zero-arg private wrapper passes
`Mix.env()` + `Path.join(Mix.Project.build_path(), "lib")`), because the
fork's owner differs by env: in `:prod` the custom compiler RELOCATES the
BEAM into the `jido_action` ebin and removes the app-side copy
(`relocate_patch!/1`), so an unconditional app-ebin check would fail every
prod compile_check even with a correctly patched artifact:

- **non-prod** (`Mix.env() != :prod` — precommit's `:test`, bare dev runs):
  `JidoClaw.Core.JidoExecPatch.patched_beam_current?(lib/"jido_claw/ebin/Elixir.Jido.Exec.beam")`
  must be true (reuses the existing marker check — missing / unmarked /
  stale-pin all read false), else `Mix.raise` naming the sequence and
  pointing at `compile.jidoclaw_release_patches`; AND
  `:file.consult(lib/"jido_claw/ebin/jido_claw.app")` →
  `Jido.Exec in spec[:modules]`, else `Mix.raise` — the ORDERING pin (a
  current BEAM written after `compile.app` would pass the marker check but
  leave a stale `.app`).
- **`:prod`**: `patched_beam_current?` on the RELOCATED owner,
  `lib/"jido_action/ebin/Elixir.Jido.Exec.beam"`, else `Mix.raise`; AND
  `Jido.Exec in` the consulted `jido_action.app` modules (the dep's own
  `.app` already lists the upstream module — asserted for completeness);
  AND the SINGLE-OWNER invariant: the app-side
  `lib/"jido_claw/ebin/Elixir.Jido.Exec.beam"` must be ABSENT and
  `jido_claw.app` modules must EXCLUDE `Jido.Exec`, else `Mix.raise` — a
  relocation regression from move to copy would otherwise leave two
  `Jido.Exec` BEAMs and restore code-path-order-dependent module loading.

## Fix 2 — `lib/jido_claw/cli/run_command.ex`: load-then-put pre-boot priming

Extract the four `put_env` calls from `boot/2` into a public
`prime_boot_env(dir, model)` (`@doc` + `@spec`) that **loads the app specs
FIRST, then applies plain (non-persistent) overrides**:

1. `Application.load(:jido_claw)` + `Application.load(:jido_ai)`, each
   tolerating `{:error, {:already_loaded, _}}` — under the escript's
   `app: nil` this applies the spec + persistent embedded-config env NOW
   (the escript applies embedded config `persistent: true` at init;
   `config.exs` sets `mode: :both` + the model-alias catalog), so the load
   inside the later `ensure_all_started/1` is a no-op that can no longer
   clobber anything.
2. The existing four `Application.put_env/3` calls, unchanged and
   deliberately NON-persistent — after the load they override the live env
   and stick.

`boot/2` becomes `prime_boot_env(dir, Config.model(Config.load(dir)))` + the
unchanged boot_fn dispatch/rescue. Load-then-put is chosen over
`persistent: true` (main.ex's pattern) because this function also runs
inside the test VM on every `run_command_test.exs` row: persistent puts
would leave a persistent shadow that the existing non-persistent
setup/on_exit save/restore cannot clear (a later `Application.load`/reload
would resurrect the test value), while load-then-put writes nothing global —
the existing cleanup keeps working as-is, genuinely. On the `mix jidoclaw
run` path both loads are already-loaded no-ops and behavior is byte-identical
to today.

## Regression tests

**`test/mix/tasks/jidoclaw_compile_check_test.exs`** (NEW — home matches the
existing `test/mix/tasks/` convention). Fixture rows drive
`assert_exec_fork!/2` against ExUnit tmp lib dirs only — NEVER the live
`_build/test` (shared across precommit's partitions). Non-prod rows (env
`:test`):

- Generated fork BEAM (via `JidoExecPatch.generate!(JidoExecPatch.upstream_source_path(), tmp_lib/"jido_claw/ebin/Elixir.Jido.Exec.beam")`
  — same fixture technique as `jido_exec_patch_test.exs`'s incremental-build
  rows) + a minimal hand-written `jido_claw.app` whose modules include
  `Jido.Exec` → returns `:ok`.
- Missing BEAM → raises, message names `compile.jidoclaw_release_patches`.
- UPSTREAM dep BEAM copied in as the target (unmarked) → raises — the exact
  "gate leaves upstream Exec" failure mode.
- Current BEAM but `.app` modules WITHOUT `Jido.Exec` → raises — the
  compile.app ordering pin.
- Missing/unparseable `jido_claw.app` → raises.

Prod-shaped rows (env `:prod` — the relocation packaging branch stays
pinned):

- Marker-current BEAM at `tmp_lib/"jido_action/ebin/Elixir.Jido.Exec.beam"`
  + a `jido_action.app` listing `Jido.Exec`, NO app-side BEAM and a
  `jido_claw.app` WITHOUT `Jido.Exec` → `:ok` — the post-relocation shape
  must pass.
- Upstream (unmarked) BEAM at the dep location → raises.
- App-side marker-current BEAM but dep-side missing → raises — relocation
  didn't run.
- BOTH owner copies present (marker-current dep BEAM AND a lingering
  app-side BEAM, or `jido_claw.app` still listing `Jido.Exec`) → raises —
  the single-owner pin against a move→copy relocation regression.

**`test/jido_claw/core/jido_exec_patch_test.exs`**: one new pin beside the
existing escript `app: nil` row (~line 670):
`JidoClaw.MixProject.project()[:compilers]` contains
`:jidoclaw_release_patches` immediately before `:app` — removing/reordering
the custom compiler in `compilers/0` must fail a test, not just the gate.

**`test/jido_claw/cli/run_command_boot_env_test.exs`** (NEW — lean file, no
DB, `async: true`; the existing run_command_test setup is too heavy for
this). THE regression, faithful to the escript's unloaded-app state, in a
subprocess VM — args built as
`Enum.flat_map(ebins, &["-pa", &1]) ++ ["-e", script]` with
`ebins = Path.wildcard(Path.join(Mix.Project.build_path(), "lib/*/ebin"))`
(one path per `-pa` occurrence — Elixir does not accept a list after a
single flag), run via `System.cmd("elixir", args)` — `elixir` resolves from
the test VM's mise PATH; ~1s:

1. The script first seeds two labeled groups of `persistent: true` puts:
   **config-faithful** — `:jido_claw :mode → :both` and
   `:jido_ai :model_aliases → config-model map` (exactly what Mix's
   generated escript main does with embedded config) — and **adversarial** —
   `:jido_claw :skip_discord → false` and
   `:jido_claw :project_dir → "/adversarial"`. The adversarial pair is
   required for the assertions to mean anything: the subprocess runs the
   TEST build, whose config already sets `skip_discord: true`, so without an
   adversarial `false` seed the load alone would satisfy the assertion even
   if `prime_boot_env/2` stopped setting it.
2. Calls `JidoClaw.CLI.RunCommand.prime_boot_env("/primed/dir", "primed-model")`.
3. `Application.load(:jido_claw)` + `Application.load(:jido_ai)` — what
   `ensure_all_started/1` would do next (tolerate
   `{:error, {:already_loaded, _}}`; after the fix these are no-ops since
   prime already loaded).
4. Prints ALL FOUR primed values — `mode` / `project_dir` / `model_aliases`
   / `skip_discord` (inspect on one line).

The test asserts all four postconditions — `:cli`, `"/primed/dir"`, the
primed aliases, and `skip_discord == true`. The observed production failure
is the mode/model pair (config-defined, clobbered by the load with the old
put-before-load code — red; with the fix, green); the adversarially seeded
`project_dir`/`skip_discord` assertions prove ONLY the helper's post-load
override can produce the primed values — a config default (present in the
test build, possible in prod later) can never false-green them. (No
`:jido_claw` module boots; `prime_boot_env` only loads app specs and calls
`Application.put_env`, so the bare `-pa` VM needs no started deps.)

## Docs + deviations (same change)

- **`docs/system/mcp-server-surface.md`** (already modified unstaged): the
  incremental-build-owner paragraph gains the gap + fix — the warnings gate
  (`jidoclaw.compile_check`) hand-sequences compile tasks, so it now reruns
  `compile.jidoclaw_release_patches` between `compile.elixir` and
  `compile.app` and self-asserts the marker-current BEAM + `.app` membership
  at the env's owner (app ebin in dev/test; the relocated `jido_action` ebin
  in prod), and the fork's `Code.compile_string` diagnostics now flow
  through the compiler-task return into the gate's allowlist;
  add `lib/mix/tasks/jidoclaw.compile_check.ex` and
  `test/mix/tasks/jidoclaw_compile_check_test.exs` to BOTH the frontmatter
  `sources:` and `## Source map`; refresh `verified:`/`verified_sha`.
- **`docs/system/gateway-runtime-security.md`** (already modified unstaged):
  the escript persistent-put sentence (~line 106) widens to cover the run
  path and the SECOND sanctioned pattern — `RunCommand.prime_boot_env/2`
  loads the app specs first, then applies plain overrides (equivalent
  protection against the `Application.load` clobber, without persistent
  writes in the test VM); add `lib/jido_claw/cli/run_command.ex` and the
  new boot-env test to its `sources:`/source map; refresh
  `verified:`/`verified_sha`.
- **`AGENTS.md`** Known-limitations, the `compile_check` bullet: one clause —
  the gate re-runs the `jidoclaw_release_patches` compiler before
  `compile.app` and self-asserts the fork BEAM, so its clean sequence can
  never drop the generated `Jido.Exec` fork.
- **`docs/plans/pre-argus-wave-e-16/README.md`** `## Deviations` — one entry:
  `**Post-review round 3: compile_check fork regeneration + escript run
  persistent env** (forced; 2026-07-14)` — both findings, why each escaped
  (the gate hand-sequences compilers so the mix.exs `compilers/0` ordering
  never applied; the run path predates the `app: nil` flip and its no-op boot
  stub hid the load clobber), the fixes, the operator-approved
  self-assert-over-subprocess-integration coverage decision, and the two
  plan-review amendments (the fork's `Code.compile_string` diagnostics now
  ride the compiler-task return through the gate's allowlist; load-then-put
  chosen over `persistent: true` because prime runs inside the test VM,
  where a persistent shadow would outlive the non-persistent on_exit
  restore). Scope honesty: only the config-defined `mode`/`model_aliases`
  pair was actually clobbered (`Application.load/1` preserves pre-load keys
  the spec/persistent set doesn't define); the regression asserts all four
  primed values as a deliberately stronger invariant.
- No MCP surface change (no `surface_version` bump); no
  `jido_md.check`/`system_prompt.check` impact.

## Verification

1. Targeted first:
   `mise exec -- mix test test/mix/tasks/jidoclaw_compile_check_test.exs test/jido_claw/cli/run_command_boot_env_test.exs test/jido_claw/core/jido_exec_patch_test.exs test/jido_claw/cli/run_command_test.exs`
   — new rows green, zero regressions.
2. Live-gate proof of Fix 1 (the reviewer's exact repro, healed):
   `MIX_ENV=test mise exec -- mix jidoclaw.compile_check` (bare, in
   background, read the tail) — green, AND afterward
   `_build/test/lib/jido_claw/ebin/Elixir.Jido.Exec.beam` exists
   marker-current and `jido_claw.app` lists `Jido.Exec`. (This is precommit's
   own mutation of `_build/test`; run it before the final gate, not
   concurrently with a test run.)
3. **Final bar**: `mise exec -- mix precommit` — bare (never piped), in
   background, read the tail; iterate to green. Precommit re-runs the fixed
   compile_check with its new self-assert, which is the standing
   integration check. Known-flaky singleton suites (MCPServer, Prompt,
   PipelineStore, MultiSandbox) verified in ISOLATION before blaming this
   change. Watch items: `@doc`/`@spec` on the new public helpers
   (`assert_exec_fork!/1`, `prime_boot_env/2`); no comment line starting
   with the word "step"; `system_docs.check` green with the two doc-page
   edits in the same change.
4. Optional (not blocking): the artifact-level twin of Fix 2 —
   `MIX_ENV=prod mise exec -- mix escript.build` and a `./jidoclaw run`
   against a configured dir asserting no Phoenix boot — heavy (needs
   DB/provider); the subprocess row is the durable guard.

## Files to stage (fold into the existing #16 commit-2 slice; nothing committed by the agent)

- `lib/mix/tasks/jidoclaw.compile_check.ex`
- `lib/jido_claw/core/jido_exec_patch.ex` (diagnostics capture +
  return-shape change)
- `lib/mix/tasks/compile.jidoclaw_release_patches.ex` (compiler-task
  diagnostics contract)
- `lib/jido_claw/cli/run_command.ex`
- `test/mix/tasks/jidoclaw_compile_check_test.exs` (NEW)
- `test/jido_claw/cli/run_command_boot_env_test.exs` (NEW)
- `test/jido_claw/core/jido_exec_patch_test.exs` (compilers-chain pin +
  `{:generated, []}` return-shape updates)
- `docs/system/mcp-server-surface.md`
- `docs/system/gateway-runtime-security.md`
- `AGENTS.md`
- `docs/plans/pre-argus-wave-e-16/README.md`
