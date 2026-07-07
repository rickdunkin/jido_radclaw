# Plan: `docs/system/` — a guarded per-subsystem documentation layer

## Context

AGENTS.md has become the de facto system wiki and is saturating: 58.6KB across 280 lines,
11 single lines over 2,000 chars, the longest (the Executor Seam bullet) at 10,326 chars
— and it grew ~4KB from external edits during this planning session alone.
Each shipped program welds another mega-paragraph into `### Key Patterns`, the whole file
is loaded into every agent session, and there is no per-subsystem home for deep truth
(ARCHITECTURE.md is broad-shallow; moduledocs are per-module). There is also no `docs/`
root index over its ~100 markdown files.

The approach synthesizes three researched sources (approved 2026-07-07): **OKF SPEC**
(`~/workspace/research/docs/knowledge-catalog/okf/SPEC.md` — frontmatter + index
conventions, mechanically checkable; it ships no validator, we write our own tiny one),
**openwiki** (maintenance patterns only, not the tool: surgical updates, hub +
back-reference, "why shaped this way / things to watch" page rhythm), and **Karpathy's
llm-wiki** (the operating model already practiced in `docs/exploration/`, extended to the
system's own docs).

**User decisions of record**: 5-step approach approved; AGENTS.md shrink posture =
**contract + pointer** (each mega-bullet keeps its 2–5-sentence load-bearing invariants +
a link; mechanics/config/telemetry/residuals move to the page).

## Verified constraints

- Precommit alias (`mix.exs:263-273`): the new check slots after `jidoclaw.jido_md.check`.
  Also add `"jidoclaw.system_docs.check": :test` to `cli/0`'s `preferred_envs`
  (mix.exs:63 — this repo uses `cli/0` + `preferred_envs`, not `preferred_cli_env`).
- Guard template: thin Mix.Task (`lib/mix/tasks/jidoclaw.jido_md.check.ex`) + pure
  validator (`lib/jido_claw/platform/jido_md/check.ex`) — `problems` returns `[]` when in
  sync, name-**set** comparisons (`expected -- actual` / `actual -- expected`), public
  `@doc`'d parsers tested directly, injectable `path_exists?`. Unit-test shape:
  `test/jido_claw/platform/jido_md/check_test.exs` (in-memory fixtures, exact-message
  asserts).
- YAML: `yaml_elixir ~> 2.12` direct dep; `YamlElixir.read_from_string/1` (unused so far)
  is the frontmatter parse. **Verified**: yamerl's default schema has no timestamp type,
  so unquoted `verified: 2026-07-07` parses as the **string** `"2026-07-07"` (safe for
  `is_binary` + regex); an all-digit sha would parse as an integer, so the template
  **quotes `verified_sha`**. `ymlr` is transitive-only — don't use. No frontmatter parser
  or markdown-link extractor exists in `lib/` — both are net-new (small).
- AGENTS.md couplings: usage_rules-managed region is lines 146–280
  (`<!-- usage-rules-start/end -->`); only lines 1–145 may be restructured, and
  `usage_rules.sync` (not in precommit) only touches the managed region. `CLAUDE.md` is
  `@AGENTS.md` — no edit. **Known limitations** (AGENTS.md:59-62) stays inline —
  `jidoclaw.compile_check.ex:22,29` comments cite it. Key Patterns mega-bullets are
  :87-97; the seven one-liners :80-86 stay inline; MCP Server Mode is :37-62 with the two
  mega-paragraphs at :55 and :57.
- No runtime code or test parses AGENTS.md / ARCHITECTURE.md / SETUP.md /
  TRUST-BOUNDARIES.md; neither `system_prompt.md` copy references them; `README.md:9-11`
  badges link to `docs/ARCHITECTURE.md` (stays put).
- `.claude/workflows/doc-reconcile.js` is fully generic (`{doc, source}` pairs) — covers
  `docs/system/` with zero code change. `.agents/skills/explore-repo/SKILL.md` hardcodes
  `docs/exploration/` in its collision sweep (optional one-line addition).

## Design

### The layer: `docs/system/`

`docs/system/README.md` — conventions + index in one file (the `docs/exploration/README.md`
role): frontmatter schema, page skeleton, the same-PR + atomicity rules, the check's
contract, and a **line-anchored bullet index** (`- [Title](page.md) — description`) the
check set-compares against directory contents.

**12 seed pages**, distilled (not rewritten) from the AGENTS.md mega-sections:

| Page | Source (AGENTS.md) | type |
| --- | --- | --- |
| `loop-guard.md` (first — worked exemplar) | Loop Guard :90 | subsystem |
| `output-shaping.md` | Output Shaping :87 | subsystem |
| `context-compaction.md` | Context Compaction :88 | subsystem |
| `tool-approval.md` | Tool Approval Gate :89 | subsystem |
| `verdict-normalizer.md` | Verdict Normalizer :91 | subsystem |
| `verify-authority.md` | Deterministic Verify Authority :92 | subsystem |
| `terminal-statuses.md` | Honest Terminal Statuses + Stall Detection :93 | subsystem |
| `mcp-consumption.md` | External MCP Tool Consumption :94 | subsystem |
| `lua-code-mode.md` | Lua Code-Mode Queries :95 | subsystem |
| `eval-harness.md` | Deterministic Eval Harness :96 | subsystem |
| `executor-seam.md` | Executor Seam :97 | subsystem |
| `mcp-server-surface.md` (last — also moves :55/:57 paragraphs) | MCP Server Mode :37-62 | surface |

**Frontmatter schema** (required keys enforced; extra keys tolerated — guard enforces the
contract, not a sealed schema):

```yaml
---
type: subsystem            # required; closed vocab: subsystem | surface | contract
description: <one line>    # required, non-empty
sources:                   # required, non-empty list of repo-relative paths (must exist;
  - lib/jido_claw/...      #   absolute /- or ~-led paths AND `..` traversal segments rejected)
verified: 2026-07-07       # required, YYYY-MM-DD (format only; freshness is doc-reconcile's job)
verified_sha: "1c90e385"   # optional; when present: non-empty binary, ~r/^[0-9a-f]{7,40}$/
---
```

`verified_sha` note: an unquoted all-digit sha parses as an **integer** (verified against
yamerl's default schema), so the is-binary + hex check mechanically forces quoting.
`contract` is reserved now (valid, unused) for a future cross-cutting contract page so no
guard change is needed later. **Pointer policy**: the inbound-AGENTS.md-pointer
requirement applies to every page regardless of `type` — a future contract page would be
cited from AGENTS.md exactly as TRUST-BOUNDARIES.md is today. If a page class ever
genuinely doesn't belong in AGENTS.md, that's the named trigger for a frontmatter opt-out
(e.g. `agents_pointer: false`), not now.

**Page skeleton** (each mega-bullet already contains all of these): `# Title` → `## What
& why` → `## Invariants & contracts` (the sentences kept inline in AGENTS.md, verbatim or
near) → `## Mechanics` (the bulk of the moved detail: port provenance + shas, windows/
TTLs, deviation rationales) → `## Config & telemetry` → `## Residuals & accepted risks` →
`## Source map`. **Source-map refs are backticked `path[:line]` text, never markdown
links** — keeps them out of the link check by construction. `:line` is optional (a
path-only entry is valid for a whole module, directory, or test file) but encouraged for
function-level claims; all are drift-tolerant "start here" pointers per house convention.

### AGENTS.md restructure (lines 1–145 only)

- Each mega-bullet → contract + pointer per the approved Loop Guard preview: seam/
  position, envelope/retry semantics, fail-open/closed posture, non-negotiables — ending
  `→ [docs/system/<page>.md](docs/system/<page>.md)`.
- MCP Server Mode keeps the `.mcp.json` quickstart + Known limitations; only the two
  mega-paragraphs (:55, :57) move.
- New short `## Documentation` section: `docs/system/README.md` is the hub; the same-PR
  rule ("a change touching subsystem X updates `docs/system/<X>.md` in the same change,
  bumping `verified:`"); the atomicity rule (below); reconcile passes via doc-reconcile.
- Target ≈ 20–25KB (from 58,647 bytes at plan time — re-measure at implementation; the
  file accretes between sessions, which is the problem being solved); usage_rules region
  byte-identical.
- **Re-verify anchors at implementation start** (the file moves): the plan's :NN line
  refs were re-confirmed after a mid-session external edit (markers 146/280, mega-bullets
  :87-97, MCP paragraphs :55/:57, Known limitations :59) but must be re-checked once more
  before the first edit; anchor on the marker/heading text, not the numbers.

### The drift check

- **Task** `lib/mix/tasks/jidoclaw.system_docs.check.ex`
  (`Mix.Tasks.Jidoclaw.SystemDocs.Check`): owns all File I/O — globs `docs/system/*.md`,
  splits out README, reads pages into `%{path, content}`, reads `AGENTS.md` (for the
  pointer checks), delegates, `Mix.shell().error` each problem + `Mix.raise` on drift,
  one-line info on success. Pure file I/O — no `Application.load`.
- **Validator** `lib/jido_claw/platform/system_docs/check.ex`
  (`JidoClaw.SystemDocs.Check`), pure. API:
  - `problems(opts)` — `:pages`, `:readme`, `:agents_md` (AGENTS.md content),
    `:path_exists?` (default `&File.exists?/1`); orchestrates per-page checks + link
    resolution + index set-match + AGENTS.md pointer checks; messages prefixed with the
    offending file path.
  - `page_problems(page, path_exists?)` — frontmatter present/terminated/parses/is-map
    (each a distinct problem, fail closed); required keys present; `type` in vocab;
    `description` non-empty binary; `sources` non-empty list of relative existing paths
    (absolute `/`-/`~`-led AND `..`-segment paths rejected); `verified` matches
    `~r/^\d{4}-\d{2}-\d{2}$/`; `verified_sha` when present is a non-empty binary matching
    `~r/^[0-9a-f]{7,40}$/`; body contains `## Source map` **with at least one backticked
    `path[:line]` entry** (a backticked token containing `/`, optional `:\d+` suffix —
    heading alone is not evidence, an empty section fails).
  - Public parsers, tested directly: `split_frontmatter/1`
    (`{:ok, map, body} | {:error, reason}`), `doc_links/1` (relative `.md` targets;
    `http(s)://` and pure `#anchor` links excluded; `#anchor` suffixes stripped),
    `index_entries/1` (page basenames from line-anchored `- [Title](page.md) — …`
    entries under `## Index`; missing heading = fail-closed problem),
    `agents_pointers/1` (all `docs/system/<slug>.md` occurrences in the hand-written
    region — content before `<!-- usage-rules-start -->`; marker absent → whole file;
    slug regex `(?:README|[a-z0-9][a-z0-9-]*)\.md` — README included so the Documentation
    section's hub pointer is itself validated, while prose placeholders like
    `docs/system/<X>.md` in the rule text can never match or false-fail).
  - Link resolution: resolve against the page's dir; targets inside `docs/system/` must
    be in the page set (or README); targets outside (e.g. `../ARCHITECTURE.md`) must
    satisfy `path_exists?` **and the resolved path must not escape the repo root**
    (containment asserted on the resolved relative path, e.g. expand against a virtual
    root and require the prefix to survive).
  - **AGENTS.md pointer checks (v1, both directions)**: every `agents_pointers/1` target
    must exist in the page set ∪ README ("broken AGENTS.md pointer"); every page must
    have ≥1 inbound AGENTS.md pointer ("page never referenced from AGENTS.md") — this
    machine-enforces the atomicity rule: a shrunk-bullet-without-page breaks direction
    one, a page-without-shrunk-bullet breaks direction two. README is exempt from the
    inbound requirement (it gets one anyway via the `## Documentation` section).
  - Index set-match: names not counts — `missing:` and `unexpected:` both reported (a
    same-count rename yields both).
- Frontmatter splitter: first line must be exactly `---`; scan to the next `---`
  (none → unterminated); `YamlElixir.read_from_string/1`; non-map/`nil` result →
  "frontmatter is not a mapping". Structure as `with`, not nested `case` (credo nesting
  ≤3, complexity ≤11).

## Non-goals (recorded)

No `log.md` (git history + `docs/reports/` are the log), no graph viewer, no
generated-docs-as-authority (generation may bootstrap; pages are owned artifacts), no
moves of ARCHITECTURE.md / SETUP.md / TRUST-BOUNDARIES.md, no exploration-corpus format
changes (the ades/pms index-cell bloat is a separate later task), no MCP resource
exposure of docs (possible follow-up), root `docs/README.md` not guarded in v1.
**Known residual**: `verified` freshness is unenforced (the validator can't know the
correct date) — that's doc-reconcile's job. (Atomicity, by contrast, IS machine-enforced
in v1 via the bidirectional AGENTS.md pointer checks — promoted from residual to
requirement at plan review.)

## Files

**New**: `docs/system/README.md`, 12 pages per the table, `docs/README.md` (root index,
prose: maps system/, exploration/, plans/, reports/, _archive/, ARCHITECTURE.md,
SETUP.md, TRUST-BOUNDARIES.md),
`lib/mix/tasks/jidoclaw.system_docs.check.ex`,
`lib/jido_claw/platform/system_docs/check.ex`,
`test/jido_claw/platform/system_docs/check_test.exs`.

**Edited**: `AGENTS.md` (lines 1–145 only), `mix.exs` (alias + `cli/0` `preferred_envs`),
`.agents/skills/explore-repo/SKILL.md` (optional, one collision-sweep line).

**Untouched**: `CLAUDE.md`, `README.md`, `docs/ARCHITECTURE.md`, `docs/SETUP.md`,
`docs/TRUST-BOUNDARIES.md`, both `system_prompt.md` copies, `docs/exploration/`.

## Implementation order (commit-sized; guard green from the moment it's wired)

1. **Validator + task + unit tests, unwired.** No `docs/system/` yet; precommit passes
   because the task isn't invoked and the new code clears credo/reach/dialyzer/test.
   Lands the red/green proof of every drift class before any doc exists.
2. **Scaffold + wire, green on empty corpus.** `docs/system/README.md` (conventions +
   empty `## Index`), AGENTS.md `## Documentation` section, wire alias + `cli/0`
   `preferred_envs`, add the integration test (committed corpus passes `problems == []` —
   the jido_md round-trip analog), optional explore-repo sweep line. Green because: zero
   pages → zero inbound-pointer requirements, and the Documentation section's
   `docs/system/README.md` pointer is extracted (README matches the pointer regex) and
   resolves against page-set ∪ README.
3. **3–14: one page per commit.** Each commit adds `docs/system/<page>.md` + its index
   row + shrinks the matching AGENTS.md bullet (**atomicity: a bullet only shrinks in the
   commit that creates its page** — now machine-enforced: the new page's inbound-pointer
   requirement is satisfied exactly by the shrunk bullet's pointer). `loop-guard.md`
   first (worked exemplar), `mcp-server-surface.md` last (also moves the :55/:57
   paragraphs). Index set-match holds after every commit.
4. **Close out**: root `docs/README.md`; full `mix precommit` at zero findings.

## Test plan

Unit tests (`async: true`, in-memory fixtures, `path_exists?` injected, exact-message
asserts — one committed red/green proof per drift class): clean fixture → `[]`;
frontmatter missing / unterminated / non-map / malformed YAML; each missing required key;
`type` outside vocab (+ each valid value clean); `sources` not-a-list / empty / absolute
/ `..`-traversal / nonexistent; bad `verified` format; `verified_sha` as integer
(unquoted all-digit) / non-hex / empty flagged, absent clean; `## Source map` missing OR
present-but-empty (no backticked entry) flagged; broken intra-system link flagged, valid
link clean, repo-root-escaping link (`../../outside.md`) flagged, `http(s)://` URL and
backticked `foo.ex:12` ref NOT flagged; index `missing:` / `unexpected:` / same-count
rename yields both; AGENTS.md pointer to a nonexistent page flagged, page with zero
inbound AGENTS.md pointers flagged, pointer occurrences inside the usage-rules region
ignored; public parsers asserted directly. Integration test: real committed corpus
(pages + README + AGENTS.md) is self-consistent.

## Gotchas (from design review)

- **ExSlop duplicate-clone**: `jido_md.check`'s `check_name_set/4` and
  `system_prompt.check`'s `compare_names/5` are already two near-sibling set-diffs. Write
  the index set-diff inline with its own message strings (a 3rd identical contiguous defp
  trips the clone check); do NOT extract a shared helper (reach flags trivial
  forwarders).
- **credo --strict** on new lib code: `@moduledoc` + `@spec` everywhere, lines ≤120,
  nesting ≤3 / complexity ≤11, predicate names end in `?` (never `is_`), no TODO tags,
  StrictModuleLayout, ExSlop comment register (why/contract, never step narration).
  credo doesn't lint `docs/` (`included: ["lib/", "test/"]`).
- **dialyzer**: handle both `YamlElixir.read_from_string/1` arms explicitly; spec
  `path_exists?` as `(String.t() -> boolean())`.
- **Manual probes**: any ad-hoc YAML/parser verification uses `mix run --no-start -e …`
  — bare `mix run` boots the app and can collide with a running endpoint.

## Verification

1. `mix test test/jido_claw/platform/system_docs/check_test.exs` — all drift-class tests
   green (each proven red against its broken fixture during development).
2. Live drill once during implementation: remove an index entry →
   `mix jidoclaw.system_docs.check` fails with the named problem; restore → green.
3. Content-preservation review: every fact removed from an AGENTS.md bullet appears in
   its page (the pre-change bullet text is the page's raw material); usage_rules region
   (146–280) shows no diff hunk.
4. Full `mix precommit` — exit code and test counts reported verbatim; all four doc
   guards green. (Known rotating full-suite flake: one unrelated timing test may flake —
   re-run, don't mask.)
5. `wc -c AGENTS.md` ≈ 20–25KB (from 58,647 at plan time).

## Post-approval housekeeping (not implementation)

Save the plan-review lessons to session memory (blocked during plan mode): (a) a guard
for something the same change makes load-bearing ships in v1, never as a deferred
residual (the AGENTS.md-pointer promotion); (b) optional frontmatter/config keys still
need present-case type validation — YAML retypes unquoted scalars (all-digit sha →
integer); (c) path validators that reject absolute paths must also reject `..`
traversal and assert resolved-path containment.
