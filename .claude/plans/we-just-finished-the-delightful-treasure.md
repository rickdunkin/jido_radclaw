# Plan: PR-3 review-fix — strict config read + present-null refusals (ReviewIndependence)

## Context

The PR-3 cross-vendor review work (all currently uncommitted working-tree changes) was
code-reviewed; two findings landed. Both are **verified valid** (static read of
`review_independence.ex` + `config.ex`, plus Tidewave YamlElixir probes reproducing the
reviewer's evidence). Both are fail-open holes in a module whose own moduledoc promises
the opposite ("a typo must not read as 'unconfigured'"). **Done means `mix precommit`
passes** (run directly, never piped; exit code + counts verbatim). Nothing committed.

### Finding validation

**P1 — CONFIRMED.** `load_review/1` (review_independence.ex:182) calls tolerant
`Config.load/1` (config.ex:78-81), which collapses ANY YAML read/parse failure to `%{}`.
Verified: `YamlElixir.read_from_string("review:\n  executor: codex\n  independence: [\n")`
→ `{:error, %YamlElixir.ParsingError{message: "malformed yaml"}}` → `load/1` swallows →
`review` key absent → `{:ok, :strict}` / `{:ok, :default}`. A malformed config bypasses
the launch fence AND the dispatch overlay — the in-process reviewer dispatches as if the
knob never existed.

**P2 — CONFIRMED.** Blank YAML keys parse present-null (`"review:\n  executor:\n"` →
`%{"review" => %{"executor" => nil}}`), and three sites conflate present-nil with absent:
`mode_from/1` :226 (`Map.get` → nil clause ⇒ silently `:strict`), `binding_from/1` :247
(⇒ silently `:default` — fail-open past the fence), `translate_config(nil)` :276 (⇒
silently `%{}`).

**Same-class extension (fix too):** a bare `review:` (present-null SECTION,
`%{"review" => nil}`) hits `load_review`'s `nil -> {:ok, nil}` clause (:183) via the
`Map.get`-based `Config.review/1` accessor — treated as absent. The existing test
"a non-map review: section is a loud error, never treated as absent" (:206) pins the
intent for non-map values; null is non-map. Fixing P2 without this leaves the identical
trap one level up.

**Key implementation fact (probed):** `YamlElixir.read_from_file` classifies eisdir/open
failures as `FileNotFoundError` too — so absent-vs-unreadable CANNOT be distinguished
through it. The strict reader must `File.read/1` itself (`{:error, :enoent}` = absent;
any other read error = fail closed) and parse via `YamlElixir.read_from_string/1`.

**No existing test pins the buggy behavior** (nothing writes blank keys or malformed
files) — regression tests can go red-first cleanly. `Config.review/1` has exactly ONE
caller (review_independence.ex:182) and zero test/doc references — safe to remove.

## Fix design

### 1. `lib/jido_claw/core/config.ex` — strict reader + tolerant `load/1` unchanged in behavior

- **New `read_user_config/1`** — `@spec read_user_config(String.t()) :: {:ok, map()} | {:error, String.t()}`,
  with a short `@doc` carrying the load-bearing distinction: this is the public STRICT
  raw-user-config API (fail closed on a present-but-broken file, raw unmerged map),
  vs. `load/1`'s tolerant merged view for boot/wizard surfaces.
  Path via existing `Path.join([project_dir, ".jido", "config.yaml"])` shape. Semantics:
  - `File.read` → `{:error, :enoent}` ⇒ `{:ok, %{}}` (absent file/dir = nothing configured);
  - `File.read` → any other `{:error, reason}` ⇒ `{:error, "cannot read .jido/config.yaml: #{inspect(reason)}"}` (eacces/eisdir fail CLOSED);
  - parse `{:ok, map}` ⇒ `{:ok, map}` (RAW user map — no defaults merge, so present-vs-absent keys stay distinguishable);
  - parse `{:ok, nil}` ⇒ `{:ok, %{}}` (empty/null doc: parse succeeded, provably no keys);
  - parse `{:ok, other}` ⇒ `{:error, "root of .jido/config.yaml must be a map, got <type word>"}` — describe the TYPE (a list / a scalar), never inspect the value (a whole-file dump could carry secrets into a durable terminal — redaction posture);
  - parse `{:error, e}` ⇒ `{:error, "cannot parse .jido/config.yaml: #{Exception.message(e)}"}` (parser messages are bounded/content-free).
- **Refactor `load/1`** to read through it, collapsing `{:error, _}` to `%{}` —
  byte-identical for every case (verified mapping: missing/parse-error/non-map-root/nil-root
  all produced `%{}` before; defaults merge + ollama auto-detection untouched).
- **Delete `review/1`** (config.ex:139-149): its `Map.get` shape IS the present-null trap;
  single caller moves to `Map.fetch` on the raw map. No other references exist.
- Moduledoc note: `load/1` stays tolerant for boot/wizard surfaces; `read_user_config/1`
  is the fail-closed lane for consumers that must not treat a broken file as absent.

### 2. `lib/jido_claw/orchestration/review_independence.ex` — fetch semantics, all four sites

- `load_review/1` (:181-197): call `AppConfig.read_user_config(project_dir)`;
  `{:error, msg}` ⇒ `{:error, {:invalid_review_config, "review config fails closed — " <> msg}}`
  (keep the SINGLE `{:invalid_review_config, _}` tag — the composer/dispatch integration
  tests already match it; the message discriminates). On `{:ok, config}`:
  `Map.fetch(config, "review")` — `:error` ⇒ `{:ok, nil}` (absent); `{:ok, section} when
  is_map(section)` ⇒ `validate_section(section)`; `{:ok, other}` (incl. nil) ⇒ the existing
  "review: must be a map …, got: #{inspect(other)}" error.
- `mode_from/1` (:225-242): `Map.fetch(section, "independence")` — `:error` ⇒ `{:ok, :strict}`;
  `{:ok, "strict" | "degraded"}` ⇒ as named; `{:ok, other}` (incl. nil) ⇒ existing loud error
  (message already handles nil via `inspect`).
- `binding_from/1` (:246-251): `Map.fetch(section, "executor")` — `:error` ⇒ `{:ok, :default}`;
  `{:ok, executor}` ⇒ `parse_binding(executor, Map.fetch(section, "executor_config"))`
  (a null executor flows to `parse_kind(nil)` → the existing `invalid_kind` loud error).
- `translate_config/1` (:276-297): re-key clauses on the fetch result — `:error` ⇒
  `{:ok, %{}}` (key absent); `{:ok, %{} = raw}` ⇒ existing whitelist/translate;
  `{:ok, other}` (incl. nil) ⇒ existing "executor_config must be a map, got: …" error.
- Moduledoc "Parsing posture" paragraph + the `load_review` nil-safety comment: add the
  file-level strictness (unreadable/unparseable config.yaml refuses loudly; absent file
  stays absent) and the present-null rule (present-nil ≠ absent, all four keys/section).

No changes to `check_route/2` / `apply_executor/3` / `mode/1` /
`configured_reviewer_binding/1` bodies — all route through `load_review` +
`mode_from`/`binding_from`, so the fixes cover every entry point. Error-tuple shape
unchanged ⇒ composer launch (`{:error, {:start_failed, {:invalid_review_config, _}}}`,
pinned at composer_review_independence_test.exs:167) and dispatch step-error
(agent_runner_review_dispatch_test.exs:110) surfacing paths already integration-tested.

## Test plan (red first, then green — house rule)

### `test/jido_claw/orchestration/review_independence_test.exs` — new describe "strict config read (fail closed)"

Uses the existing `project_with_config!/1` + `empty_project!/0` helpers. All of these are
RED today except the byte-identical guards:

1. **P1 regression**: malformed file (`"review:\n  executor: codex\n  independence: [\n"`)
   ⇒ `{:error, {:invalid_review_config, msg}}` with `msg =~ "config.yaml"` from ALL FOUR
   entry points: `mode/1`, `configured_reviewer_binding/1`, `check_route(review_catalog(), dir)`,
   and `apply_executor(reviewer_template, "reviewer", %{project_dir: dir})`.
2. **P2 — null section**: `"review:\n"` ⇒ error, `msg =~ "must be a map"`.
3. **P2 — null executor**: `"review:\n  executor:\n"` ⇒ error, `msg =~ "codex | claude_code"`.
4. **P2 — null independence**: `"review:\n  executor: codex\n  independence:\n"` ⇒ error,
   `msg =~ "strict | degraded"`.
5. **P2 — null executor_config**: `"review:\n  executor: codex\n  executor_config:\n"` ⇒
   error, `msg =~ "executor_config must be a map"`.
6. **Unreadable ≠ absent**: `.jido/config.yaml` created as a DIRECTORY (deterministic
   eisdir, no chmod flakiness) ⇒ `{:error, {:invalid_review_config, _}}` — pins the
   enoent-only absence rule.
7. **Byte-identical guards stay green**: absent file (`empty_project!`), config without a
   `review:` section, and `review: {}` (empty MAP section — valid no-op, unlike null) ⇒
   `{:ok, :strict}` / `{:ok, :default}`.

### `test/jido_claw/core/config_test.exs` — extend

- `read_user_config/1`: absent dir/file ⇒ `{:ok, %{}}`; valid YAML ⇒ raw map (assert NO
  `"providers"` defaults key — proves unmerged); malformed YAML ⇒ `{:error, msg}`
  (`=~ "parse"`); non-map root (`"- a\n- b\n"`) ⇒ `{:error, msg}`; empty file ⇒ `{:ok, %{}}`.
- `load/1` tolerance pins (regression fence for the refactor — permanent-test-over-spot-check):
  malformed YAML, absent file, AND a non-map root (`"- a\n- b\n"`) all ⇒ defaults map
  (`provider/1` == "ollama") — the non-map-root case pins the one mapping where
  `read_user_config` errors but `load/1` must still collapse byte-identically.

### Ripple check (run, expect green, no edits)

`composer_review_independence_test.exs`, `agent_runner_review_dispatch_test.exs`,
`templates_test.exs` — all use valid or section-shape-broken configs; error tuple/tag
unchanged.

## Docs truth-ups (same working tree, pre-commit — not historical docs)

- **AGENTS.md** PR-3 sentence ("The YAML boundary is Verify.Config-strict (…)"): add the
  two new clauses — an unreadable/unparseable `.jido/config.yaml` refuses loudly (strict
  `Config.read_user_config/1`; absent file stays absent; `Config.load/1` keeps the
  tolerant collapse for boot/wizard) and present-null keys (`review:` / `executor:` /
  `executor_config:` / `independence:`) refuse loudly (present-nil ≠ absent).
- **docs/plans/unadopted-next-ten/README.md** item-7 PR-3 done-note (:647-region, "The
  YAML boundary is Verify.Config-strict:" sentence): same two clauses.

## Implementation order

1. Write the new tests (both files) → run the two test files → confirm the new tests
   FAIL red (and exactly which), existing stay green.
2. `config.ex`: `read_user_config/1` + `load/1` refactor + delete `review/1`.
3. `review_independence.ex`: the four fetch-semantics sites + moduledoc/comment updates.
4. Re-run targeted: `mix test test/jido_claw/orchestration/review_independence_test.exs
   test/jido_claw/core/config_test.exs test/jido_claw/route_composer/composer_review_independence_test.exs
   test/jido_claw/skills/steps/agent_runner_review_dispatch_test.exs test/jido_claw/templates_test.exs` → all green.
5. Docs truth-ups (AGENTS.md + README done-note).
6. `mix precommit` — run directly (never piped); report exact exit code + test counts
   verbatim. Known rotating full-suite flakes (MemoryExport / collector recovery / :pg):
   re-run once per project memory, never twice for the same test.

Gate watch-list: credo strict + ExSlop (no `String.to_atom`, no new rescue in config.ex —
case-based; small interpolations fine), reach (no new arch edge — RI→Config exists; no
trivial forwarder — `read_user_config` does real work), dialyzer (exact `{:ok, map()} |
{:error, String.t()}` union), format.

## Files touched

- `lib/jido_claw/core/config.ex`
- `lib/jido_claw/orchestration/review_independence.ex`
- `test/jido_claw/orchestration/review_independence_test.exs`
- `test/jido_claw/core/config_test.exs`
- `AGENTS.md`, `docs/plans/unadopted-next-ten/README.md`

## Notes & non-goals

- **Adjacent, observed, NOT fixed** (not in the findings): `Verify.Config` reads through
  the same tolerant `Config.load/1` (verify/config.ex:114) — a malformed config.yaml
  silently falls through to mix auto-detect for `verify_cmd`. Different stakes (a verify
  still RUNS, vs. the review fence silently disabling) and a runtime-semantics decision
  of its own; flagged for a separate call.
- Blast-radius note (deliberate): with the fix, a malformed `.jido/config.yaml` refuses
  EVERY composer launch on that project with an actionable config error — fail closed is
  the module's documented posture; the alternative is the P1 bug.
- Reviewer's staging note (plans staged, implementation unstaged): no action — commit
  only when asked; staging state untouched.
- `Config.load/1` behavior is NOT changed for any existing consumer (boot/wizard tolerance
  preserved and now pinned by test).
