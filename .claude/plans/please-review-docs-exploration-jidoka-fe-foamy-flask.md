# Plan: Implement V2-6 — `search_web` tool (Brave Search)

## Context

`docs/exploration/jidoka/FEATURES-WORTH-BORROWING-V2.md` (last updated 2026-06-15) states the active
Jidoka-V2 borrowing program is **complete**: V2-1 (approval gate), V2-2 (external MCP consumption), and
V2-4 (replay diagnostics) all shipped. A fresh audit confirms this — every remaining deferral holds up,
and a `TODO/FIXME/DEFERRED` sweep of the touched subsystems found **zero** actionable V2 loose ends.

The **one shovel-ready capability borrow left is V2-6 (web search)**. Today the platform has
`Tools.BrowseWeb` (fetch a known URL) but no web *discovery* — the main agent and the Researcher worker
can only follow URLs they already have. V2-6 closes that with a `search_web` tool.

The borrow is cheap: `jido_browser ~> 2.0` is already a dependency (`mix.exs:153`) and its Brave-backed
`Jido.Browser.Actions.SearchWeb` action is already compiled. No new dependency.

**Two corrections to the doc** surfaced during exploration: the real module is
`Jido.Browser.Actions.SearchWeb` (not the `Jidoka.Browser.Tools.SearchWeb` path the doc cites), and the
key env var is **`BRAVE_SEARCH_API_KEY`** (not `BRAVE_API_KEY`).

### Decisions taken (user + reviewer pass)

- **Reach**: the tool lands on the **main agent + the Researcher worker**.
- **Researcher gets `browse_web` too** — so it is a self-contained web researcher (discover *and* read),
  not discovery-only.
- **Outbound query is scrubbed** before it leaves the platform for Brave (leakage hygiene — the project's
  threat model). The wrapper only redacts *results*; the request itself must be scrubbed in the tool.

## Outcome

A `search_web` tool that wraps the compiled Brave action through the shared `JidoClaw.Tools.Action`
pipeline (result redaction, approval gate, shaping, cap, MCP scope — all inherited), plus an explicit
**outbound query scrub**. It **ships key-ready**: with no Brave key configured it returns a clean
`{:error, …}` ("API key not configured"), so `mix precommit` passes without a live key. Activation later
is a one-line `.env` entry.

---

## Files

**New:**
- `lib/jido_claw/tools/search_web.ex` — the tool
- `test/jido_claw/tools/search_web_test.exs` — its tests

**Modified:**
- `lib/jido_claw/agent/agent.ex` — register the tool; bump the `# Browser tools (1)` comment to `(2)`
- `lib/jido_claw/agent/workers/researcher.ex` — add **both** `JidoClaw.Tools.SearchWeb` and
  `JidoClaw.Tools.BrowseWeb` to its `tools:` list; update its `description` to reflect web research
- `priv/defaults/system_prompt.md` — catalog edits + template-table row (see "Prompt edits")
- `.jido/system_prompt.md` — same edits (the active agent reads this copy; kept in sync per AGENTS.md)
- `docs/ARCHITECTURE.md` — fix two drift spots (`:156` tool tree, `:832` dep table)

---

## Design — the tool

Mirror `lib/jido_claw/tools/browse_web.ex`, minus the destination gate (search hits a fixed Brave endpoint
— no LLM-controlled host, so no SSRF surface and no `DestinationPolicy` needed). Delegate to a **swappable
backend** for testability, and **scrub the outbound query**:

```elixir
defmodule JidoClaw.Tools.SearchWeb do
  @moduledoc false
  use JidoClaw.Tools.Action,
    name: "search_web",
    description:
      "Search the web via Brave Search and return ranked results (title, URL, snippet). " <>
        "Use to discover pages or docs when you don't already have a URL; follow up with browse_web to read one.",
    category: "browser",
    tags: ["browser", "web", "search"],
    output_schema: [
      query: [type: :string, required: true],
      results: [type: {:list, :map}, required: true],
      count: [type: :integer, required: true]
    ],
    schema: [
      query: [type: :string, required: true, doc: "Search query"],
      max_results: [type: :pos_integer, default: 10, doc: "Max results to return (1–20; upper bound capped by the backend)"],
      country: [type: :string, default: "us", doc: "Country code (e.g. us, gb, de)"],
      search_lang: [type: :string, default: "en", doc: "Language code"],
      freshness: [type: :string, doc: "Recency filter: pd (24h), pw (week), pm (month), py (year)"]
    ]

  alias JidoClaw.Tools.OutputRedaction

  @default_backend Jido.Browser.Actions.SearchWeb

  @impl Jido.Action
  def run(params, context) do
    # Outbound leakage hygiene: the shared wrapper only redacts the *result*, so
    # scrub the whole outbound param map here before it leaves the platform for
    # Brave — the exact MCP-proxy precedent (mcp/proxy_generator.ex:241), and
    # the same posture as Voyage's pre-redact. Scrubbing every string field
    # (not just :query) closes the gap that query/country/search_lang/freshness
    # are all plain strings in this schema. redact/1 preserves atom keys and
    # leaves the integer max_results untouched (output_redaction.ex:20-22), so
    # the dep reads the scrubbed map normally.
    scrubbed = OutputRedaction.redact(params)
    backend().run(scrubbed, context)
  end

  # Swappable backend mirrors the `:jido_browser, :adapter` seam (browse_web_test)
  # and the `voyage_module:` injection (retrieval_test). Production always uses the
  # real Brave action; tests inject a stub.
  defp backend, do: Application.get_env(:jido_claw, :search_web_backend, @default_backend)
end
```

**Why this shape (verified):**
- `Jido.Action.name/0` is compile-time metadata (`deps/jido_action/lib/jido_action.ex:406`), no global
  registry — so the dep action and this wrapper can share the name `"search_web"` without collision (only
  the wrapper is in any agent's `tools:`; the dep action is called directly via `.run/2`).
- `OutputRedaction.redact/1` is the exact outbound-arg scrubber the MCP proxy uses
  (`mcp/proxy_generator.ex:241`); it recurses with `Map.new` preserving keys (`output_redaction.ex:20-22`),
  applies `Patterns.redact/1` to every string value (`:18`), and leaves non-strings (the integer
  `max_results`) intact (`:33`). So all free-text outbound fields are scrubbed by the same rules as
  results, and the dep still reads `params.query` / `Map.get(params, :max_results, 10)` from the scrubbed
  map unchanged.
- **Not approval-gated**, deliberately: read-only against a fixed endpoint — intentionally absent from
  `ToolApproval.default_require/0`. Inbound results are still redacted/capped by the inherited pipeline
  (`OutputRedaction.redact` recurses into the `results` list-of-maps — confirmed at `output_redaction.ex:20,24`).
- `max_results` is `:pos_integer` (stricter than the dep's bare `:integer`): the schema rejects `0`/negative
  at validation, and the dep's `min(_, 20)` caps the upper bound — effective range a safe `1..20` with no
  duplicated cap logic.

### Researcher worker

`lib/jido_claw/agent/workers/researcher.ex`: add `JidoClaw.Tools.BrowseWeb` **and**
`JidoClaw.Tools.SearchWeb` to the `tools:` list (currently `read_file, search_code, list_directory,
project_info`), and update the `description` from "Read-only access for deep codebase investigation" to
include web research (still read-only — both tools are non-mutating). The existing output schema already
has an `artifacts.url` field, so no schema change. Worker prompts are generated from `tools:` (not the
hand-maintained catalog), so no separate worker prompt file.

### Config — zero changes

`load_dotenv/0` (`lib/jido_claw/application.ex:453`) loads `.env` / `.jido/.env` into the OS environment at
boot; the dep reads `BRAVE_SEARCH_API_KEY` via `System.get_env/1` at request time. So **activation is just
adding `BRAVE_SEARCH_API_KEY=…` to `.env`** — no `config/runtime.exs` wiring. Do **not** touch
`lib/jido_claw/core/mcp_server.ex`: `search_web` is an agent tool, not MCP-published (keeps
`mcp_server_test.exs:60`'s `== 22` green).

---

## Prompt edits

### Catalog coupling (test-enforced — do not skip)

`test/jido_claw/prompt_test.exs:200-218` reads `priv/defaults/system_prompt.md` **raw** and asserts the set
of line-start `**name**` bold entries **exactly equals** `JidoClaw.Agent.tool_modules()` names, plus the
literal `## Tool Catalog (N tools)` count. Both files say `## Tool Catalog (32 tools)` (line 11) for 32
main-agent tools; adding `search_web` to the main agent makes it 33. (Researcher's tools do **not** affect
this count — the test uses the main agent's list only.) In **both** prompt files:

1. Line 11: `## Tool Catalog (32 tools)` → `## Tool Catalog (33 tools)`.
2. Browser section header (`priv:340` / `.jido:322`): `### Browser (1 tool)` → `### Browser (2 tools)`.
3. Add **exactly one** line-start entry after the `**browse_web**` block (`priv:342` / `.jido:324`):
   `**search_web** — Search the web via Brave Search; returns ranked results (title, URL, snippet). Use to discover pages when you don't already have a URL, then browse_web to read one.`
4. Decision-framework tree (`priv:385` / `.jido:367`): add a sibling line pointing discovery at `search_web`.
5. Quick-reference table (`priv:566` / `.jido:548`): add `| Search the web for pages/docs | search_web |`.

Edits 4–5 begin with `│` / `|`, not `**`, so only edit 3 adds a token matching `^\*\*([a-z0-9_]+)\*\*` —
keeping `documented == registered`.

### Template-table row (correctness — not test-enforced, but the main agent relies on it)

`priv/defaults/system_prompt.md:120` (and `.jido`) has an "Agent templates and their exact tool access"
table the main agent reads to decide handoff/spawn. The `researcher` row currently lists
`read_file, search_code, list_directory, project_info`. Update it to add `browse_web, search_web` (wrap to
a second line to match the `coder`/`refactorer` multi-line format if it overflows the column) and update
its Purpose from "Codebase exploration, read-only" to e.g. "Codebase + web research, read-only". Both files.

### Sync stamp (`.jido/.system_prompt.sync`) — operational footnote

`.jido/.system_prompt.sync` is a machine-managed stamp (`default_sha` / `body_sha`, header "Managed by
JidoClaw. Do not edit.") that `Prompt.sync/1` reconciles on REPL boot (`agent/prompt.ex`, `startup.ex`):
when the bundled default has moved and the active `.jido/system_prompt.md` differs from it, the flow writes
a `.default` sidecar and announces a prompt upgrade. **Do not hand-edit the stamp.** Two implications:
(1) before editing, `diff priv/defaults/system_prompt.md .jido/system_prompt.md` — they currently show a
consistent ~18-line offset, so confirm exactly how they diverge and land my edits correctly in both;
(2) no test reads the stamp (so it can't fail precommit). Because `.jido/system_prompt.md` **already**
diverges from the bundled default and the stamp is **stale**, `Prompt.sync/1` will likely write/keep a
`.jido/system_prompt.md.default` sidecar (and announce a prompt upgrade) on boot — that is **expected, not
a bug**; the active prompt is replaced only when the operator runs `/upgrade-prompt`. The correct check is
that the **active `.jido/system_prompt.md` contains my edits**, not the absence of a sidecar.

---

## Auto-covered (no new test needed)

- `test/jido_claw/tools/output_redaction_test.exs:79-105` introspects every `tool_modules()` entry for the
  three `__jidoclaw_tool_*__` markers — `search_web` is auto-included and passes via `use JidoClaw.Tools.Action`.
- `test/jido_claw/security/tool_approval_test.exs:325-348` — `search_web` is not require-listed and not a
  `@require_patterns` key → safe; auto-included as a valid wrapped tool.

---

## Tests (new file, `async: false`)

Inline stub backend that records the outbound params it received and returns a scripted result. It sends
the captured params to a **test pid taken from app env** (`:search_web_test_pid`, set to `self()` in
setup) rather than assuming `self()` — direct `run/2` runs in the test process, but `Jido.Exec.run/4` may
run the action in a task, so app-env delivery is process-agnostic. Direct `run/2` tests use **atom-keyed**
params (the dep reads `params.query`).

The file is `async: false` *because* it mutates global state, so cleanup must be explicit: snapshot and
`on_exit`-restore **every** key touched — `:jido_claw`'s `:search_web_backend`, `:search_web_test_pid`,
and `:search_web_stub_result`, plus `:jido_browser, :brave_api_key` and the `BRAVE_SEARCH_API_KEY` env var
(snapshot with `Application.fetch_env/2` / `System.get_env/1`; restore the original or delete if it was unset).

```elixir
defmodule StubBackend do
  def run(params, _context) do
    if pid = Application.get_env(:jido_claw, :search_web_test_pid), do: send(pid, {:backend_received, params})
    Application.get_env(:jido_claw, :search_web_stub_result, {:ok, %{query: params.query, results: [], count: 0}})
  end
end
```

- **Success delegation** (stub): returns the ranked-results shape through the wrapper.
- **Error normalization** (stub returns `{:error, "…rate limit…"}`): asserts `{:error, %{message: msg}}`,
  `msg =~ "rate limit"` (the wrapper's `Error.normalize`).
- **Outbound query scrub** (direct `run/2`): query containing a real secret-shaped token —
  `"… sk-ant-aaaaaaaaaaaaaaaaaaaaaaaa …"` (`patterns.ex:15` → `[REDACTED:ANTHROPIC_KEY]`; **not** an email —
  there is no email pattern); `assert_received {:backend_received, %{query: q}}`, assert
  `q =~ "[REDACTED:ANTHROPIC_KEY]"` and the raw token is gone. Proves the request is scrubbed *before* leaving.
- **Inbound nested-result redaction** (stub): a result whose snippet contains an `sk-ant-…` token; assert
  it is redacted in the tool output (proves the pipeline reaches the nested `results` list — V2-2 "external
  results untrusted" guarantee; confirmed reachable at `output_redaction.ex:20,24`).
- **Not-configured** (real backend): clear `:jido_browser, :brave_api_key` **and** `BRAVE_SEARCH_API_KEY`
  (restore on_exit), assert `{:error, %{message: msg =~ "API key"}}`. Hermetic — `get_api_key/0`
  short-circuits before any `Req.get`, so no network even if a dev/CI has the key exported.
- **Full-path validation** via `Jido.Exec.run(SearchWeb, %{query: "elixir"}, %{}, log_level: :error)`
  (stub backend) — exercises Jido's param-schema validation (required `query`, defaults) and output_schema
  validation, which direct `run/2` calls bypass (`Jido.Exec.run/4` confirmed at
  `deps/jido_action/lib/jido_action/exec.ex:165`). Assert on the **returned** `{:ok, %{count: …}}` value
  (don't rely on `assert_received` here — the action may run in a task).

---

## Researcher-change verification

After editing `researcher.ex`, run `templates_test.exs`, `stats_test.exs`, and the worker tests. No test
currently asserts a fixed Researcher tool list or the template table (`grep "Tools Available" test/` is
empty), and no test asserts workers lack browser tools (`browse_web` appears only in `browse_web_test.exs`)
— so this is expected clean, but verify.

---

## Out of scope / deliberate non-goals

- Adding `search_web` to the MCP-published tool set (keeps the 22-tool MCP contract).
- A dedicated approval/destination policy for search (low-risk, fixed endpoint).
- `config/runtime.exs` wiring (redundant with `.env` auto-load + the dep's env fallback).
- **Web-results-first, by design**: this wraps `Jido.Browser.Actions.SearchWeb`, which uses Brave's
  standard web-search endpoint — the cheap V2-6 path since the dep action already exists. Brave's
  agent-oriented "LLM Context" endpoint is noted as a possible future upgrade, not pursued here.

---

## Verification (completion bar)

Run via `mise exec -- mix …`. Run gate commands **bare** (no `| tail` — a pipe masks the exit code) in the
background and read the output tail.

1. `mise exec -- mix jidoclaw.compile_check` — strict compile (the precommit-safe gate; **not**
   `compile --warnings-as-errors`, which trips on the two intentional `pull_request_coordinator` warnings).
2. `mise exec -- mix test test/jido_claw/tools/search_web_test.exs` — new tests pass.
3. `mise exec -- mix test test/jido_claw/prompt_test.exs test/jido_claw/tools/output_redaction_test.exs test/jido_claw/security/tool_approval_test.exs test/jido_claw/mcp_server_test.exs` — coupled tests (catalog match, marker sweep, approval sanity, MCP `== 22`).
4. `mise exec -- mix test test/jido_claw/templates_test.exs test/jido_claw/stats_test.exs` — Researcher change clean.
5. **`mise exec -- mix precommit`** — the user's hard completion bar; the plan is not "done" until this is green.
6. Prompt-sync sanity: confirm the **active** `.jido/system_prompt.md` contains the `search_web` + Researcher
   edits (grep it). On `mise exec -- mix jidoclaw` boot a `.jido/system_prompt.md.default` sidecar /
   prompt-upgrade notice is **expected** (the active prompt already diverged from the bundled default and the
   stamp is stale) — it is not a failure; clear it with `/upgrade-prompt` if desired.
7. *Optional live check (needs a Brave key you provide):* add `BRAVE_SEARCH_API_KEY=…` to `.env`, run
   `mise exec -- mix jidoclaw`, ask the agent to search the web, and confirm real ranked results.

---

## Files to stage (when you're ready — I will leave everything unstaged)

- `lib/jido_claw/tools/search_web.ex`
- `test/jido_claw/tools/search_web_test.exs`
- `lib/jido_claw/agent/agent.ex`
- `lib/jido_claw/agent/workers/researcher.ex`
- `priv/defaults/system_prompt.md`
- `.jido/system_prompt.md`
- `docs/ARCHITECTURE.md`

Suggested commit message: `feat: add search_web tool (Brave Search) — V2-6 borrow`

(Doc note for after merge: update V2-6's status in `FEATURES-WORTH-BORROWING-V2.md` to ADOPTED and correct
the module path / env-var name. Treat as a follow-up, not part of this change.)
