# Doc-truth sweep — audit §3 + §3b + JIDO.md cluster (one PR)

## Context

The 2026-07-04 codebase audit (`docs/reports/codebase-audit-2026-07-04.md`) found top-level docs
rotted hard while AGENTS.md stayed current: tool counts (27 vs actual 35), template counts (6/7 vs
16), retired v0.4–v0.6 designs still documented as current, plus ~33 moduledoc one-liners citing
functions/modules/keys that don't exist (§3b). Two items were explicitly deferred INTO this sweep:
**§1.12** (the JIDO.md generator emits self-contradictory template lists) and the **§4 "JIDO.md
drift guard"** process item. Several of these surfaces are LLM-facing (`.jido/JIDO.md` is read by
the agent at boot), so the payoff is high. §1 bugs and §4 improvements already landed as batch PRs
(`8699af6a`, `f9407d87`); this is triage step 2.

**User decisions (confirmed):**
1. `.jido/JIDO.md` stays **committed**, guarded by a new marker-based `mix jidoclaw.jido_md.check`
   wired into precommit (modeled on `jidoclaw.system_prompt.check`), with a one-time refresh of the
   committed file.
2. **One PR** for the full sweep (§3 docs + §3b moduledocs + JIDO.md cluster + audit-report banner).
3. ROADMAP/PLAN docs get **status banners + targeted fixes** — no rewrites, no archival.

**Plan-review corrections (user, confirmed against source):** use the canonical privacy predicate
(`Templates.composer_private_template?/1`), never the raw `:composer_private` field (the three
`sketch_*` templates are private via `:sandbox`); the guard validates tool/skill **name sets**, not
just counts; the generator's stale **Skills** section joins the derived/checkable surface;
**historical release notes stay historical** (update current-state claims only); the current
**Ash-domain inventories** (README + ARCHITECTURE) are in scope; plus two [L] strings
(`config_yaml_content/0` `jido init`/`jido --setup`, README:1047 callback count).

Tree is clean (§4 batch committed at `f9407d87`); base on current `main`, new branch.

## Ground truths (re-derive at edit time, don't copy blindly)

| Claim | Truth | Derivation |
|---|---|---|
| Registered tools | **35** | `length(JidoClaw.Agent.tool_modules())` — list at `lib/jido_claw/agent/agent.ex:7-53` (incl. `lua_query`/`lua_docs`); names via `Enum.map(& &1.name())` |
| Tool modules on disk | 45 | audit ground-truth (AGENTS.md "32+" floor bump) |
| MCP tools | 26 | AGENTS.md / MCPServer (unchanged) |
| Worker templates | **16** | `JidoClaw.Agent.Templates.names()` (`templates.ex:255`) |
| Spawnable vs composer-private | **8 / 8** | partition hydrated `Templates.list/0` values with **`Templates.composer_private_template?/1`** (`templates.ex:334-338` — `:sandbox in [:prototype, :docker]` OR the `:composer_private` flag; raw-field filtering misclassifies the sketch trio). User-verified via `mix run --no-start` |
| Skills (built-in defaults) | **10** | `JidoClaw.Skills` `@default_skills` keys (`platform/skills.ex:63+`; filenames == skill names); matches committed `.jido/skills/*.yaml` (adds `sfr_review`, `verified_feature` over the documented 8). Three execution modes (`execution_mode/1`, `skills.ex:333`): sequential by default, DAG when steps carry `name`/`depends_on`, **iterative** when `mode: iterative` (generator/evaluator loop — two defaults use it, `skills.ex:182`) |
| Redaction regexes | **10** | `security/redaction/patterns.ex:13-34` `@patterns`; NO private-keys pattern exists |
| Sandbox callbacks | 8 required + 2 optional | `Forge.Sandbox.Behaviour` (README omits `exec_argv/4`); PLAN-docker banner says 10 total — consistent |
| Ash domains | **16** | `length(Application.get_env(:jido_claw, :ash_domains, []))` — the app's registered truth. User-verified via `mix run --no-start` |
| App version | 0.6.4 | `mix.exs:4` → runtime via `Application.spec(:jido_claw, :vsn)` |

---

## Workstream 1 — JIDO.md cluster (the only real code)

### 1a. Generator fix (§1.12 + stale sections) — `lib/jido_claw/platform/jido_md.ex` (`JidoClaw.JidoMd`)

Edit the `jido_md_content/5` heredoc (`:51-229`):
- **Project block (:63-65)**: add `- **Version**: #{app_vsn()}`; **delete** the `- **Root**: #{project_dir}` line
  (the one machine-absolute path — kills cross-machine instability at the source).
- **Template detail section (:75-108**, hardcoded 7 blocks incl `verifier`): replace with
  `#{templates_detail_section()}` — derived from `Templates.list/0`, sorted by name, ALL 16, each block:
  `` ### `name` `` / `- **Description**:` (from `:description`) / `- **Tools**:` (from
  `t.module.strategy_opts() |> Keyword.fetch!(:tools) |> Enum.map(& &1.name())` — same public accessor
  Templates hydration already uses; fallback if brittle: drop the Tools bullet) / `- **Max iterations**:`
  (hydrated) / for the composer-private 8: `- **Composer-internal**: used by the route composer; not
  spawnable via spawn_agent`. Private/public split via **`Templates.composer_private_template?/1`**
  on the hydrated maps — NOT the raw `:composer_private` field.
- **"Available template names:" (:146-147**, hardcoded 6): replace with `#{template_names_lines()}` —
  two generated lines: `Available template names:` = the **8 spawnable** (this line sits in
  spawn/skill-YAML context, so listing unspawnable names would be a new lie), then
  `Composer-internal (not spawnable): …` = the other 8. Same predicate split.
- **Skills section**: replace the hardcoded 3-skill table + "steps run sequentially" claim with
  `#{skills_section()}` — **scoped to the built-in skills list + execution-modes prose only**: one
  row per built-in skill (`- `name` — description`, both parseable from the `@default_skills` YAML
  strings), prose covering all three modes ("sequential by default; DAG when steps carry
  `name`/`depends_on`; **iterative** when `mode: iterative` with generator/evaluator roles" —
  `execution_mode/1`, `skills.ex:333`). The Custom Skills YAML example stays literal heredoc text
  after it, followed by `#{template_names_lines()}` — the template summary lives OUTSIDE
  `skills_section/0` (clear helper boundary: the two helpers don't overlap). If `Skills` exposes no
  public accessor for the defaults, add `JidoClaw.Skills.default_skill_names/0` (and
  `default_skill_entries/0` for name+description) reading `@default_skills` — tiny, compile-time,
  used by generator + check task.
- **New `## Tools (#{length(JidoClaw.Agent.tool_modules())} total)` section** (e.g. after Skills):
  one line-anchored bullet per tool `` - `name` `` (sorted, `Enum.map_join` — house rule: no
  `<>`-around-`Enum.join`), so the guard can set-compare names, not just count.
- **`config_yaml_content/0` (:231-236)**: `jido init` / `jido --setup` → the real surfaces
  (`mix jidoclaw` setup wizard, `/setup` REPL command; escript is `jidoclaw`).
- Memory section (:158-159): correct the `.jido/memory.json` storage claim (Postgres/Ash since v0.6).
- New private helpers: `app_vsn/0` (`to_string(Application.spec(:jido_claw, :vsn) || "0.0.0-dev")` —
  NOT `Mix.Project`; `ensure/1` runs at app boot/escript where Mix is absent; precedent
  `mcp/endpoint_config.ex:266`), `templates_detail_section/0`, `template_names_lines/0`,
  `tools_list/0`, `skills_section/0`.
- `ensure/1`, `generate/1`, detection/build-commands helpers: unchanged.

### 1b. New pure validator — `lib/jido_claw/platform/jido_md/check.ex` (`JidoClaw.JidoMd.Check`)

`problems(content, opts) :: [String.t()]` with opts `version:`, `tool_names:` (sorted, 35),
`template_names:` (all 16), `spawnable_names:` (8), `skill_names:` (10), `path_exists?:` (default
`&File.exists?/1` — injected so tests and the round-trip bind it). Accumulator style mirroring
`system_prompt.check`. Marker set:

| Marker | Parse | Expected |
|---|---|---|
| Version | `^- \*\*Version\*\*:\s*(.+)$` | `opts[:version]` |
| Tool count | `^## Tools \((\d+) total\)$` | `length(tool_names)` (anchored — no collision with the `Tools (33):` diagram line) |
| **Tool names** | first backticked token of line-anchored entries (`` ^- `name` `` bullets and `` ^\| `name` \| `` table rows) **scoped to the `## Tools` section** (heading → next `^## `; committed file has `###` subsections inside — h3 must not end the scope) | set-equal `tool_names` — catches same-count rename/add/remove |
| Template detail headers | `` ^### `([a-z0-9_]+)`$ `` set (scoped to the Agent Templates section) | == `template_names` |
| Summary line | names scanned from the `Available template names:` line(s) | == `spawnable_names` |
| **Skill names** | same line-anchored first-token parse scoped to the `## Skills` section | == `skill_names` |
| No machine path | `~r{/(Users|home)/\w}` | absent |
| Entry points | backticked paths in bullets under `- **Entry points**:` | each `path_exists?.(path)` (existence, not exact match — hand-curation stays allowed) |

Expose the pure parsers (`tool_names_in_section/1`, `template_names_in_detail/1`,
`template_names_in_summary/1`, `skill_names_in_section/1`) publicly — real regex work (reach-clean)
and the §1.12 test reads directly off them.

### 1c. New mix task — `lib/mix/tasks/jidoclaw.jido_md.check.ex` (`Mix.Tasks.Jidoclaw.JidoMd.Check`)

Thin shell on the `system_prompt.check` template: `_ = Application.load(:jido_claw)` (so `vsn` is
populated), `File.read!(".jido/JIDO.md")`, build opts from `Application.spec` +
`JidoClaw.Agent.tool_modules()` names + `Templates.list/0` split via
`Templates.composer_private_template?/1` + `Skills.default_skill_names()`, then `Check.problems/2`
→ `Mix.shell().info("JIDO.md in sync (…)")` or print problems + `Mix.raise`.

### 1d. mix.exs wiring

- `precommit` alias (`mix.exs:259-268`): insert `"jidoclaw.jido_md.check"` after
  `"jidoclaw.system_prompt.check"`.
- `cli/0` `preferred_envs` (`mix.exs:65`): add `"jidoclaw.jido_md.check": :test`.

### 1e. Committed `.jido/JIDO.md` one-time refresh (hand-edit until the check is green)

- `:12` Version 0.3.0 → **0.6.4**; `:13` delete the `/Users/rhl/…` Root line.
- `:17-18` entry points → `lib/jido_claw/cli/main.ex`, `lib/jido_claw/cli/repl.ex`; `:298`
  `lib/jido_claw/agents/` → `lib/jido_claw/agent/workers/`.
- `:33` diagram `Tools (33)` → 35; `:183` `## Tools (33 total)` → 35 and complete the tables to the
  full registered set (name set-equality now enforced — add `lua_query`/`lua_docs` and any others
  the tables miss).
- Supervision tree `:44-63`: delete the four nonexistent entries (`JidoClaw.Stats`,
  `JidoClaw.Tool.Approval`, `JidoClaw.Solutions.Store`, `JidoClaw.Solutions.Reputation`); keep
  `BackgroundProcess.Registry` (still supervised — its §2 wire-or-delete is pending); reconcile the
  rest against `application.ex`.
- Signal list `:70`: drop `jido_claw.memory.saved` (nothing emits it — same falsehood as §3b #33).
- Agent Templates + Skills sections: bring to the checked shape (16 detail blocks, the two names
  lines, 10 skills — pasting generator output for those sections is fine).

### 1f. Tests (red-first for §1.12)

- `test/jido_claw/platform/jido_md/check_test.exs` — `Check.problems/2` unit tests: crafted-clean
  content → `[]`; one tamper per marker: wrong version / wrong count / **renamed tool at same
  count** / detail-set mismatch / summary-set mismatch / **missing skill** / `/Users/x` present /
  dead entry-point path via `path_exists?: fn _ -> false end`.
- `test/jido_claw/platform/jido_md_test.exs` — generator tests, **all `@tag :tmp_dir`**
  (`generate/1` unconditionally writes `.jido/` — running at repo root would clobber the committed
  file): (1) **§1.12 regression** — scaffold a minimal Elixir project in tmp_dir, `generate/1`,
  assert detail-set == `Templates.names()` and summary-set == the predicate-derived spawnable set
  (**write this test FIRST, run it against the unmodified generator, confirm red** — detail=7/
  summary=6 — then apply 1a, confirm green); (2) **generate→check round-trip**:
  `Check.problems(generated, …real expected values…, path_exists?: &File.exists?(Path.join(tmp_dir, &1)))`
  == `[]` — pins the invariant that fresh generator output always passes the guard (covers tools,
  templates, and skills names at once); (3) Root-line absent / no `/Users|/home` path / Version +
  Tools markers present.

## Workstream 2 — §3 top-level docs (pure .md edits)

**Rule (user-confirmed): historical release notes stay historical.** Update current-state claims;
leave versioned release-note tables/sections (README `## v0.4.0 —` etc., ROADMAP completed
milestones) as written — they were true at the time. Annotate only where confusion is likely.
Classify each count-fix site by its surrounding context at edit time.

- **README.md** (1424 ln): 27→35 at the current-state sites (:33, :54, :597, :663 `## Tools (27)`,
  :1095, :1150 file-tree comment) — **NOT :1257** (v0.4.0 release-note table row "27 tools",
  historical); tools table :665-677 gains `fetch_output, forget, run_pipeline, verify_certificate,
  handoff, lua_query, lua_docs, search_web` and `browse`→`browse_web` (:677); :827
  `tool_approval_mode: :on_miss` → the real `:tool_approval` config
  (`enabled?`/`require`/`mcp_require_approval`); :1098 "7 types"→16; sandbox callbacks → 8 required
  + 2 optional at **both** :240 and :1047 (+`exec_argv/4`); :523 `Core.MCP`→`MCPServer`; :349+:1023
  "9 regex patterns"→10 and drop the nonexistent private-keys claim; skills table :718-731 8→10
  (+`sfr_review`, `verified_feature`); drop `JIDOCLAW_MODE` (:151, :932, :1390) **and
  `.env.example:35`**; **Domains & Resources table :164-171** — currently the old 6-domain set incl.
  the nonexistent `Orchestration.ApprovalGate` row: replace the exhaustive inventory with a
  drift-resistant summary (16 domains, a few representative rows, pointer to `lib/jido_claw/*`
  domain modules), and fix the ApprovalGate mention.
- **docs/ARCHITECTURE.md** (835 ln): `rest_for_one`→`:one_for_one` (:36, :721); 27→35 (:17, :122,
  :826 — verify context, they read current-state); Solutions Store/Reputation ETS+JSON→Postgres/Ash
  (:71-72, :457, :471, :611-613); Memory ETS/GenServer→Ash domain, no process (:73, :97, :690,
  :730); **Data Layer section :95-113** — rewrite the ":97 database separate from the ETS/JSON
  stores used for memory, solutions, skills" sentence (memory + solutions are Postgres now; skills
  remain YAML + GenServer cache) and replace the old 6-domain tree (incl. `ApprovalGate` :113) with
  the same drift-resistant summary form as README; `Orchestration.ApprovalGate` (:113, :228) →
  **`AgentCase`/`AgentCaseEvent` human-approval gate records** (the general gate surface: workflow
  gates + the run-less tool-approval branch — `orchestration.ex`, `agent_case.ex:41`); mention
  `kind: :tool_call` only where the text is specifically about the Security ToolApproval flow, not
  as the blanket replacement; strategy default `"react"`→`"auto"` (:530); `JidoClaw.Repl/Commands`→
  `CLI.*` (:338, :340, ~:736); `Jido.MCP.Server`→`JidoClaw.MCPServer` (:88); drop dead
  `StepHandler`, re-group `ContextBuilder` (:191-192).
- **CONTRIBUTING.md** (301 ln): 27→35 (:70, :96); "6 built-in"→16 (:77); Extension Points
  walkthrough (:145-227) — update every pre-refactor path to current locations (`agent/agent.ex`,
  `agent/workers/`, `agent/templates.ex`, `cli/commands.ex`, `cli/branding.ex`, `core/config.ex`,
  `cli/setup.ex`, `platform/jido_md.ex`, …; verify each on disk); Key Modules table + channel
  behaviour path (`platform/`).
- **docs/SETUP.md** (283 ln): `./jido`→`jidoclaw` (:60, :193); drop dead `JIDOCLAW_MODE` (:199,
  :213 — describe the real mode selection instead); :205 LiveDashboard is dev-only at
  `/live-dashboard`; `/dashboard` is the app dashboard.
- **docs/ROADMAP.md** (431 ln): banner + whole-entry reconcile (per memory: sweep every paragraph
  when flipping status): "Current State" :3/:5 → v0.6.4, 35 tools; v0.6 block :318-410 →
  **Shipped** (both `**Status: Planned**` at :320/:374), fix ETS-as-current claims (:60, :326-346),
  mark the migration table rows shipped (:404), note the `persistence: backend: ecto|file` fallback
  (:365-366) was dropped (design went Postgres-required). **:38 "6 domains (originally 7…)" is
  inside the completed v0.2.5 milestone — historical, leave it** (its parenthetical already handles
  the Folio note).
- **docs/BACKLOG.md**: :61 SearchCode already routes through `VFS.Resolver` (github/s3/git).
- **docs/PLAN-docker-sandbox-onecli.md**: top status banner — shipped as `Forge.Sandbox.*`
  (renamed from SpriteClient), Parts 1-2 done, callbacks grew 7→10; mark the two Part headings
  (:44, :202) done; fix :433 "all 7 callbacks"; leave interior SpriteClient design prose as history.
- **docs/PLAN-v0.6-memory.md** (5829 ln): top status banner (shipped; task namespace is
  `jidoclaw.*`); fix the ~18 `mix jido_claw.export.*/migrate.*` refs (:95, :99, :113, :1110, :1284,
  :2219-2222 incl. the stale task path, :2392, :2436, :2570, :2985, :3147, :3468, :3629, :3652,
  :4473, :5057, :5072, :5775) → `jidoclaw.*` (runbook commands must actually work; not release
  notes).
- **AGENTS.md**: :92 `ToolApproval.requirement/3` → private `requirement/4`; :105 "32+ tool
  modules" → 45; add one sentence next to the `system_prompt.md` note documenting the new
  `jidoclaw.jido_md.check` guard.

## Workstream 3 — §3b moduledoc sweep (38 files, comment-only except one)

Execute the audit §3b list verbatim — census confirmed **all 33 items still present**. Line moves
vs audit: embedding.ex → :7-8, rate_pacer runtime warn → :380, compactor "REPL command" → :767,
search_escape → :13. Representative pattern: fix the cited symbol/count/key to the verified truth
(e.g. `reviewer_verdict/3` → the real private `verdict/2` in
`agent/workers/{output_schema,sketch_reviewer,system_verifier}.ex`; "seven canonical keys" → 14 in
`tool_context.ex:108`; `:rate_limits` → `:rpm`/`:tpm` in `embeddings/rate_pacer.ex:39,380`).

One user-added item beyond the audit's 33: **`platform/skills.ex:2-41` moduledoc** — documents only
sequential + DAG execution; add the iterative mode (`mode: iterative`, generator/evaluator roles,
`execution_mode/1` :333) it already implements and two defaults use.

Two non-mechanical items:
- **`tools/get_agent_result.ex:17-18`** — delete the `message:`/`error:` `output_schema` fields
  (real code, optional, produced by no success path; error paths return the `Error.execution_error`
  envelope, a different shape). Verified: its test file references `message`/`details.error` only on
  the error-envelope branch — **no test changes needed**. Keep the `reach:disable` pragma line.
- **`embeddings/policy_resolver.ex:3-5`** — reword to the nuanced truth: the write path DOES gate on
  `resolve/1` (`backfill_worker.ex:285`) but hardcodes `stored_model = "voyage-4-large"` (:319);
  don't imply model translation. **No code change** — `model_for_storage/1` wire-or-delete is a §2
  decision, out of scope.

## Workstream 4 — audit report bookkeeping

`docs/reports/codebase-audit-2026-07-04.md`: add a `> **Status — updated <date>**` banner to §3/§3b
(mirroring the §1/§4 banners), per-entry ✅ markers, mark §1.12 fixed (generator now derives from
`Agent.Templates`/`Skills`) and the §4 JIDO.md-drift-guard deferral done, and update triage step 2.

## Sequencing

1. Branch off `main`. 2. Save the plan-review feedback memories (historical-docs rule; canonical
predicate over raw field; name-sets over counts in drift guards). 3. Write the §1.12 regression
test → run → **confirm red**. 4. Workstream 1a-1d (generator, Check, task, wiring; `Skills`
accessor if needed) → §1.12 test green, all new tests green. 5. Refresh `.jido/JIDO.md` (1e) until
`mix jidoclaw.jido_md.check` prints "in sync". 6. Workstream 2 docs. 7. Workstream 3 sweep.
8. Workstream 4 banner. 9. Verification. Commit only when user asks; stage everything
change-related, exclude the stray untracked plan file from the other session.

## Verification

```bash
mix jidoclaw.jido_md.check          # "JIDO.md in sync (version 0.6.4, 35 tools, 16 templates, 10 skills)"
MIX_ENV=test mix test test/jido_claw/platform/jido_md_test.exs \
  test/jido_claw/platform/jido_md/check_test.exs \
  test/jido_claw/tools/get_agent_result_test.exs
mix precommit                       # full gate, run directly (never piped), report exact exit + counts
```
- Green = precommit exit 0, zero credo/reach/dialyzer findings, full suite counts verbatim (known
  rotating single-flake → re-run per project memory, don't paper over).
- Independent doc verifier: run `/doc-reconcile` over README/ARCHITECTURE/CONTRIBUTING/SETUP
  post-edit expecting zero corrections (codebase-description docs only — ROADMAP/PLAN stay manual
  per memory).

## Out of scope

§2 wire-or-delete decisions (incl. `model_for_storage/1`, BackgroundProcess.Registry, dead trace
channels); §1.9 forge fields (own follow-up doc); the `eventually`/`kinds/2` test dedup PR;
`docs/exploration/` untouched. Reach/credo traps to respect while implementing: `Enum.map_join` over
`<>`-chains, no trivial forwarders, no 3+ contiguous identical defp seams, new tests NOT under
`test/support`.
