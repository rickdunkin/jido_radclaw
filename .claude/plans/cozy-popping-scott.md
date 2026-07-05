# Post-review fixes: stale spawnable-template lists + memory.json prompt claim

## Context

The code review of the doc-truth sweep (`please-read-docs-reports-codebase-audit-bubbly-quail.md`)
found two P2s. **Both are validated**, and the mandated restatement sweep (rg every occurrence of a
false invariant) found the same two falsehoods on four more surfaces the review missed:

**Issue A — stale 7-name spawnable-template list (missing `fixer`).** Truth: 8 public templates —
`coder, docs_writer, fixer, refactorer, researcher, reviewer, test_runner, verifier` (16 total minus
the 8 `Templates.composer_private_template?/1` ones; `handoff` accepts the same 8 via
`reject_composer_private` + `reject_main`, `handoff.ex:89-92`). Sites:

| # | Surface | LLM-facing? | In review? |
|---|---|---|---|
| 1 | `lib/jido_claw/tools/spawn_agent.ex:6` (description) | yes | yes |
| 2 | `lib/jido_claw/tools/spawn_agent.ex:21` (schema `doc`) | yes | yes |
| 3 | `lib/jido_claw/tools/handoff.ex:37` (schema `doc`) | yes | **no** |
| 4 | `lib/jido_claw/tools/handoff.ex:6-7` (moduledoc) | no | **no** |
| 5 | `priv/defaults/system_prompt.md:144` + `.jido/system_prompt.md:144` (handoff params line) | yes | **no** |
| 6 | `priv/defaults/system_prompt.md:112-126` + mirror (swarm template table — no `fixer` row) | yes | **no** |
| 7 | `test/jido_claw/templates_test.exs:8,11,172,188` (7-name `@valid_names` + two inline `~w` lists + "all 7" test name) | no | **no** (user-caught) |

**Issue B — `remember` "saves to `.jido/memory.json`"** at `priv/defaults/system_prompt.md:252` +
`.jido/system_prompt.md:252` (files byte-identical, both tracked). Truth: `remember` →
`JidoClaw.Memory.remember_from_model/2` → Postgres `Memory.Fact` row (`memory.ex:2-8`,
`tools/remember.ex:4-6`). Same-class doc leftovers: `README.md:998` and `docs/SETUP.md:167` still
call `memory.json` "Persistent memory" (ARCHITECTURE:691 already has the correct phrasing to
mirror). Legitimate `memory.json` references stay: migration task, `fact.ex` `:imported_legacy`,
ROADMAP v0.6 "Why" block (historical), `docs/plans/**`, export-task tests.

**Coverage gap (review's note)**: `mix jidoclaw.system_prompt.check` validates only the tool-count
heading + tool-name set, and only on `priv/defaults/` — stale prose and the `.jido/` copy are
unguarded.

**Root-cause fix, not just a re-type**: the lists drifted because they're hand-maintained literals.
Verified against `deps/jido_action/lib/jido_action.ex:316-355`: `use Jido.Action` evaluates opts
inside the quoted module context (`Zoi.parse(…, opts_map)` on evaluated values) and splices the
literal schema AST into `def schema` where module attributes inline at compile time — so
**compile-time interpolation of a derived list into `description:`/`doc:` is safe**, and gives
auto-recompile-on-Templates-change.

**Done criterion**: `mix precommit` passes (run directly, never piped; exact exit code + counts
verbatim; known rotating single-flake → re-run per project memory).

## Workstream 1 — single source: `Templates.spawnable_names/0`

`lib/jido_claw/agent/templates.ex` — new public function next to `names/0`:

```elixir
@spec spawnable_names() :: [String.t()]
def spawnable_names do
  @templates
  |> Enum.reject(fn {_name, template} -> composer_private_template?(template) end)
  |> Enum.map(fn {name, _template} -> name end)
  |> Enum.sort()
end
```

- Derives from **raw** `@templates` entries — the privacy fields (`:sandbox`,
  `:composer_private`) are static on the raw maps and `composer_private_template?/1` reads them
  defensively, so classification is identical to the hydrated path **without** hydration
  (hydration calls `module.strategy_opts()`, which at compile time would drag all 16 worker
  modules into the callers' compile deps). Doc comment states this + that it's the single source
  for every spawnable-list surface. (Known nuance, fine to note in the doc: a *malformed* sandbox
  value would classify public here vs private hydrated — the static registry is clean and pinned
  by tests.)

**Restatement cleanup in `test/jido_claw/templates_test.exs` (site 7, user-caught)**: rename
`@valid_names` (`:8`) to `@spawnable_names` holding the literal 8-name set (adds `fixer`); point
the two inline `~w[…]` comprehension lists (`:11` in `get/1`, `:188` in `exists?/1`) at the
attribute so the file carries the list exactly once; retitle `:172` "should include all 7 expected
template names" → "should include all spawnable template names" (no count in prose — the
exactly-16 `names/0` count test at `:168` stays). New tests for the helper live in the same file
(see Tests).

## Workstream 2 — derive the tool metadata (the actual P2 fix)

**`lib/jido_claw/tools/spawn_agent.ex`** — before `use JidoClaw.Tools.Action` add:

```elixir
# Compile-time snapshot of the public template set: this module recompiles
# (and the LLM-facing strings re-render) whenever Templates changes.
@spawnable_inline Enum.join(JidoClaw.Agent.Templates.spawnable_names(), ", ")
```

Then interpolate: description → `"… Available templates: #{@spawnable_inline}. …"`; schema
`:template` doc → `"Agent template name (#{@spawnable_inline})"`. Existing `alias …Templates`
(line 37) stays where it is; the attribute uses the full module name.

**`lib/jido_claw/tools/handoff.ex`** — same attribute; interpolate into the schema `:to_template`
doc (`"Target worker template (#{@spawnable_inline}). 'main' is not a valid target …"`) and into
the moduledoc's "(one of …)" enumeration (attribute must be defined before `@moduledoc`; render
backticked names there via a `Enum.map_join(…, ", ", &"`#{&1}`")` variant if kept backticked).

Two one-line attributes across two modules — no contiguous identical `defp` seams (ExSlop-safe),
no trivial forwarders.

## Workstream 3 — migrate ALL existing partition sites onto the helper

(Shared-helper memory: enumerate all callers; leave no restatements.)

- `lib/jido_claw/platform/jido_md.ex:245-262` `template_names_lines/0`: replace the
  `Enum.split_with(Templates.list(), …)` partition with
  `spawnable = Templates.spawnable_names(); private = Enum.sort(Templates.names() -- spawnable)`;
  `names_inline/1` becomes name-list-shaped (`Enum.map_join(names, ", ", &"`#{&1}`")` — it has
  exactly these two callers). **Output must stay byte-identical** — the existing generate→check
  round-trip test pins this.
- `lib/mix/tasks/jidoclaw.jido_md.check.ex:53-67` `expected/0`: replace the `split_with` block
  with `spawnable_names: Templates.spawnable_names()` (also drops the check task's needless
  hydration).
- `templates_detail_section/0` and `composer_private_line/1` keep the hydrated `Templates.list/0`
  (they need descriptions/max_iterations) — untouched.

## Workstream 4 — system prompt content fixes (both copies, keep byte-identical)

Edit `priv/defaults/system_prompt.md`, then copy to `.jido/system_prompt.md` (the AGENTS.md manual
sync):

1. **:112-126 swarm table**: add the `fixer` row (from `workers/fixer.ex:21-35`): tools
   `read_file, write_file, edit_file, list_directory, search_code, run_command, fetch_output,
   git_status, git_diff, git_commit, project_info`, max iterations 25, purpose "Resolves open
   review findings, self-reports touched domains". Match the multi-line row style; place after
   `coder` (registry order). While in the table, verify the other 7 rows against each worker's
   `strategy_opts()` (verifier row already spot-checked correct) — fix any mismatch found, it's
   the same falsehood class.
2. **:144 handoff params**: add `fixer` to the `to_template` enumeration (same 8-name set).
3. **:252 remember**: replace the `.jido/memory.json` claim with the Postgres truth, phrased
   WITHOUT the string `memory.json` (it becomes a forbidden marker in WS5), e.g.
   `**remember** — Save a persistent memory entry (stored in the Postgres-backed memory store).
   Survives across sessions.` Parameters line unchanged.

## Workstream 5 — extend `mix jidoclaw.system_prompt.check` (closes the review's coverage gap)

`lib/mix/tasks/jidoclaw.system_prompt.check.ex`, same in-task accumulator style. One targeted
check **per falsehood surface found** (a floor check like "name appears backticked somewhere"
would pass with `fixer` in the table while the handoff line stays stale — per user review). All
markers **fail closed**: marker line/section absent or unparseable ⇒ problem, never a silent pass
(the existing `check_tool_count` nil-branch pattern).

- **`check_sync`**: `.jido/system_prompt.md` must byte-equal `priv/defaults/system_prompt.md` —
  makes the AGENTS.md manual-copy rule enforceable, and lets the content checks run once on the
  default copy while transitively covering the `.jido` one. Unreadable either file ⇒ problem.
- Content checks on `priv/defaults/system_prompt.md`:
  - existing tool count + tool entries (unchanged);
  - **`check_template_table`**: scoped from the "Agent templates and their exact tool access:"
    line to the next `**`/`###` line, collect `` ^\| `([a-z0-9_]+)` `` first-cell captures
    (continuation rows have no backticked first cell) → set-equal `Templates.spawnable_names()`
    (guards site 6);
  - **`check_handoff_targets`**: parse the `` `to_template` (one of a/b/c/…) `` enumeration
    (slash-separated names inside the parens) → set-equal `Templates.spawnable_names()` (guards
    site 5);
  - **`check_no_stale_storage_claims`**: content must NOT contain `memory.json` (message: live
    memory is Postgres-backed; the legacy file is v0.5).
- Success line keeps the tool count; failures keep the per-path prefix.

Red-first at the gate: extend the task **before** editing the .md files, run it, confirm it fails
on the real files (memory.json present; `fixer` missing from both the table set and the handoff
enumeration), then apply WS4 and re-run → green.

## Workstream 6 — adjacent doc one-liners

- `README.md:998`: `memory.json` tree comment → "Legacy v0.5 memory export (git-ignored) — live
  memory is in Postgres" (mirror ARCHITECTURE:691).
- `docs/SETUP.md:167`: same correction.
- `AGENTS.md` (`system_prompt.md` paragraph): one sentence noting the check now enforces the
  manual-copy rule (byte-equality of the two copies) plus spawnable-template set markers (table +
  handoff targets) and forbids stale storage claims.

## Tests (red-first where there's a bug to pin)

- `test/jido_claw/templates_test.exs` (exists): the WS1 restatement cleanup (8-name
  `@spawnable_names`, inline lists → attribute, retitled test), plus new tests:
  `spawnable_names/0 == @spawnable_names` (the **literal** sorted 8-name list — intentional
  friction on template changes, like the JIDO.md refresh), and every returned name satisfies
  `refute Templates.composer_private?(name)`.
- `test/jido_claw/tools/spawn_agent_test.exs` (exists): after WS1 lands but **before** WS2 —
  `SpawnAgent.description() =~ "Available templates: #{Enum.join(Templates.spawnable_names(), ", ")}."`
  and `SpawnAgent.schema()[:template][:doc]` contains `"(#{…join…})"`. Run → **confirm RED**
  (fixer missing from the literals) → apply WS2 → GREEN. (`description/0`/`schema/0` are
  generated by jido_action — `jido_action.ex:406,426`.)
- `test/jido_claw/tools/handoff_test.exs` (exists): same exact-substring assertion for
  `Handoff.schema()[:to_template][:doc]` — RED then GREEN.
- WS3 refactor is pinned by the existing jido_md generator round-trip tests (byte-identical
  output); WS5 is pinned by the red→green gate run on the real files (task has no unit-test file
  today; staying in kind).
- No existing tests pin the old 7-name strings (verified by grep), so nothing else flips.

## Sequencing

1. Update the two plan-review feedback memories (refinements, not new files):
   `feedback_false_invariant_codebase_sweep` — restatement sweeps must cover `test/` too, with
   per-name patterns (single distinctive names like `docs_writer`), not just the sequence formats
   found at the first sites (the `@valid_names ~w[…]` form evaded my comma-sequence greps);
   `feedback_drift_guards_name_sets_not_counts` — set-compare **each enumeration surface**
   separately; a whole-file "name appears somewhere" floor passes while one surface stays stale.
2. WS1 helper + templates_test cleanup/additions → green.
3. spawn_agent/handoff metadata tests → **confirm RED** → WS2 interpolation → green.
4. WS3 refactors → `mix test test/jido_claw/platform/jido_md_test.exs
   test/jido_claw/platform/jido_md/check_test.exs` + `mix jidoclaw.jido_md.check` → green,
   output byte-identical.
5. WS5 task extension → `mix jidoclaw.system_prompt.check` → **confirm RED on real files** →
   WS4 prompt edits (both copies, byte-identical) → re-run → green.
6. WS6 doc lines.
7. Verification (below).

## Verification

```bash
mix jidoclaw.system_prompt.check    # green, now covering both copies + new markers
mix jidoclaw.jido_md.check          # still "JIDO.md in sync (…)" — JIDO.md needs no refresh
mix test test/jido_claw/templates_test.exs test/jido_claw/tools/spawn_agent_test.exs \
  test/jido_claw/tools/handoff_test.exs test/jido_claw/platform/jido_md_test.exs \
  test/jido_claw/platform/jido_md/check_test.exs
mix precommit                       # full gate, run directly (never piped); report exact exit + counts
```

Zero credo/reach/dialyzer findings required. Traps to respect: `Enum.map_join` over
`<>`-around-join; no trivial forwarders; new tests never under `test/support`;
`mix jidoclaw.compile_check` must stay warning-clean (the interpolation attributes are used, so no
unused-attribute warnings).

## Commit/staging notes (when the user asks — not before)

Stage only this fix's files alongside the sweep's. The two staged `.claude/plans/*` files:
`…bubbly-quail.md` is this program's executed plan (plan files are tracked convention here);
`…pure-hennessy.md` belongs to another session — leave it out of any commit for this work.

## Out of scope

- `cli/branding.ex:119-124` boot animation still stat's the legacy `.jido/memory.json` for a size
  display — runtime behavior, a §2-class wire-or-delete decision, not a doc lie.
- Auditing the system prompt beyond the touched sections; extracting the system-prompt check into
  a pure module with its own test file (JidoMd.Check-style) — not needed for these findings.
- ROADMAP/plans/migration-task `memory.json` references — historical/legitimate, stay.
