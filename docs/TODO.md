# Low-Priority Audit Findings (P3)

Items identified during the April 2026 codebase audit. These are real issues worth
addressing but are lower impact than the security, Ash, and OTP fixes being tackled first.

---

## 1. No `output_schema` on any Jido.Action tool

None of the 27 tools in `lib/jido_claw/tools/` define an `output_schema`. Each tool returns
ad-hoc maps with varying key shapes (e.g. `git_status` returns `%{status:, branch:}` while
`schedule_task` returns `%{result: "..."}` as a single string). Adding `output_schema`
definitions would enable downstream validation, better documentation for the LLM when
selecting and chaining tools, and type-safety for tool composition.

**Scope**: All 27 tool modules in `lib/jido_claw/tools/`.

---

## 2. No `category` / `tags` metadata on tools

The agent registration in `agent.ex` organizes tools into informal groups via comments
(`# Core tools (10)`, `# Swarm tools (5)`, etc.), but no tool defines `category` or `tags`
in its `use Jido.Action` options. Adding categories like `category: "filesystem"`,
`category: "git"`, `category: "swarm"` would enable filtered tool selection by the LLM
(send only relevant tools per context), better help/listing in the REPL, and tool permission
scoping.

**Scope**: All 27 tool modules in `lib/jido_claw/tools/`.

---

## 3. `IO.puts` with ANSI codes in `run_skill.ex`

`lib/jido_claw/tools/run_skill.ex` (line ~58) embeds ANSI-escaped terminal output directly
inside the tool action:

```elixir
IO.puts("  \e[33m...\e[0m \e[1mRunning skill:\e[0m #{skill.name} ...")
```

If this tool is called via MCP, the web dashboard, or Discord, the ANSI escape codes appear
as garbage text. Tool actions should return data; presentation belongs in the CLI layer
(e.g. `Display` module).

**Scope**: `lib/jido_claw/tools/run_skill.ex`.

---

## 4. `String.length/1` vs `byte_size/1` inconsistency for truncation

`lib/jido_claw/tools/git_diff.ex` (line 26) uses `String.length/1` for its 15,000-char
truncation check. `String.length/1` is O(n) because it counts grapheme clusters.
`run_command.ex` and `browse_web.ex` correctly use `byte_size/1` for their truncation
checks. This is both an inconsistency and a minor performance issue on large diffs.

**Scope**: `lib/jido_claw/tools/git_diff.ex`.

---

## 5. Navigation links use `<a>` instead of `<.link navigate=...>`

`lib/jido_claw/web/components/layouts/app.html.heex` uses plain `<a href="...">` for
navigation links. This causes full-page reloads on every navigation instead of LiveView's
client-side SPA-like navigation. All nav links should use `<.link navigate={...}>` to
preserve WebSocket connections and avoid flickering between page loads.

**Scope**: `lib/jido_claw/web/components/layouts/app.html.heex`.

---

## 6. `DashboardLive.handle_info/2` is a catch-all

`lib/jido_claw/web/live/dashboard_live.ex` (line ~59) has a single
`handle_info(_msg, socket)` clause that matches every message indiscriminately and triggers
a full data reload. This means any stray message (not just the expected PubSub updates from
`Forge.PubSub` and `RunPubSub`) triggers unnecessary database queries. It should
pattern-match on the specific PubSub message topics it subscribes to.

**Scope**: `lib/jido_claw/web/live/dashboard_live.ex`.

---

## 7. `SettingsLive` reads `Application.get_env` in render

`lib/jido_claw/web/live/settings_live.ex` (line ~34) calls
`Application.get_env(:jido_claw, :ash_domains, [])` inside the template during render.
Application env reads should happen once in `mount/3` and be stored as socket assigns so
they are not re-evaluated on every render cycle.

**Scope**: `lib/jido_claw/web/live/settings_live.ex`.

---

## 8. Same `signing_salt` for session cookie and LiveView

The `@session_options` in the endpoint and the `live_view: [signing_salt: ...]` in
`config.exs` both use `"jidoclaw_lv"`. These should be different values for defense in
depth -- if one salt is compromised, the other remains safe.

**Scope**: `lib/jido_claw/web/endpoint.ex`, `config/config.exs`.

---

## 9. Dead attributes on `ExecSession`

`JidoClaw.Forge.Resources.ExecSession` defines `duration_ms` and `output_size_bytes`
attributes that are never populated by any action. No create or update action accepts or
sets these fields. They are either dead schema fields from an incomplete implementation or
were superseded by another approach. Either wire them into the `:complete` action or remove
them and their corresponding database columns.

**Scope**: `lib/jido_claw/forge/resources/exec_session.ex`.

---

## 10. Duplicate create actions on `Forge.Session`

`JidoClaw.Forge.Resources.Session` defines both `:create` (primary, simple) and `:start`
(upsert). Both accept the same set of fields. The `:create` action appears to exist solely
for `claim_create` in `Persistence`, while `:start` handles upserts. These could likely be
consolidated into a single action with upsert behavior, reducing surface area and confusion
about which to call.

**Scope**: `lib/jido_claw/forge/resources/session.ex`, `lib/jido_claw/forge/persistence.ex`.

---

## 11. Missing identity on `IssueAnalysis`

`JidoClaw.GitHub.IssueAnalysis` has a `by_issue` read action that filters on
`[:repo_full_name, :issue_number]`, implying these should be unique together. Without an
`identity :unique_issue_per_repo, [:repo_full_name, :issue_number]`, duplicate analyses for
the same issue can be created silently. Add the identity and a corresponding unique database
index.

**Scope**: `lib/jido_claw/github/issue_analysis.ex`.
