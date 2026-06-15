# Plan: Resolve V2-6 code-review findings — sync stale `researcher` metadata

## Context

The V2-6 `search_web` borrow (plan: `please-review-docs-exploration-jidoka-fe-foamy-flask.md`)
gave the **Researcher** worker two web tools (`browse_web`, `search_web`) and updated its
description. That change landed in `researcher.ex` and in **both** `system_prompt.md` copies'
template tables — but three *other* places that also describe the researcher were left untouched,
so they now contradict the shipped capability. A code review flagged two findings; both are
**validated as real**:

- **[P2] Internally contradictory system prompt.** `Prompt.build_snapshot/2` appends
  `.jido/JIDO.md` verbatim *after* the updated base prompt (`lib/jido_claw/agent/prompt.ex:316-320`,
  via `jido_md_section/1` at `:267`). But `.jido/JIDO.md:110` (git-tracked) still lists the
  researcher as `read_file, search_code, list_directory, project_info` only — and the generator
  that stamps this block into *new* projects is equally stale (`lib/jido_claw/platform/jido_md.ex:96`).
  The base prompt says the researcher has web tools; the appended JIDO.md says it doesn't.
- **[P3] Stale runtime template description.** `lib/jido_claw/agent/templates.ex:64` describes the
  researcher as `"Explores and analyzes codebase structure"`. `spawn_agent` returns
  `template.description` in its tool output (`lib/jido_claw/tools/spawn_agent.ex:189`), so
  `spawn_agent` results don't reflect the new web-research capability. (`list_agents` surfaces only
  `agent_id | status | template`, not the description, so it's unaffected.)

**Outcome:** the researcher is described consistently as a codebase **+ web** researcher everywhere
it appears (matching what already shipped in `researcher.ex`), and `.jido/JIDO.md`'s tool catalog is
corrected to the real 33 tools so the appended prompt no longer contradicts the base catalog.
**Completion bar: `mix precommit` green.**

This is pure string synchronization to already-decided wording — no new logic, no schema/test changes.

## Why this is safe (no test breakage)

- `test/jido_claw/templates_test.exs:25-27` asserts only that a `:description` *key exists*, never its content.
- The JIDO.md tests (`prompt_test.exs:253-281`, `git_project_dir_test.exs:45`) write their own
  temp-dir JIDO.md and never read the real `.jido/JIDO.md`. `prompt_test.exs:238-250` asserts template
  *names* appear (they still do). The catalog-coupling test (`prompt_test.exs:200-218`) reads
  `priv/defaults/system_prompt.md`, **not** JIDO.md, so the tool-table edits can't affect it.
- A full `grep` sweep of `lib/ priv/ docs/ .jido/` confirms these three are the **only** sites
  describing the researcher's tools/capability; every other `researcher` mention is a bare
  template-name reference (skills/agents YAML, handoff lists, skill DAGs).

## Changes

### 1. `lib/jido_claw/agent/templates.ex` — runtime description (Finding 2)

Replace the researcher entry (`:64-67`). Wrap the description onto its own line, matching the
existing `verifier` entry's multi-line shape (and keeping it within `mix format`'s 98-col limit):

```elixir
    "researcher" => %{
      module: JidoClaw.Agent.Workers.Researcher,
      description:
        "Explores and analyzes codebase structure, and researches the web (read-only)",
      model: :fast
    },
```

### 2. `.jido/JIDO.md` — committed self-knowledge file (Finding 1 + tool-count drift)

**Two edits** to the copy `Prompt.build_snapshot/2` actually appends.

**(2a) Researcher block (`:109-113`)** — replace with:

```markdown
### `researcher`
- **Tools**: read_file, search_code, list_directory, project_info, browse_web, search_web
- **Max iterations**: 15
- **Use for**: Codebase exploration, architecture analysis, dependency mapping, web research (discover with search_web, read with browse_web)
- **Strength**: Read-only exploration of the codebase and public web research
```

(`JidoMd.ensure/1` only regenerates JIDO.md when it's absent — it exists, so these hand-edits
persist and are never overwritten.)

**(2b) Tools section** — the header (`:183`) says `30`, the tables list only `25`, and the agent
really has `33`. Set the header to `## Tools (33 total)` and add the 8 omitted tools (descriptions
copied verbatim from the `system_prompt.md` catalog). One row each into three existing subsections:

```markdown
### Shell & Git
… existing rows …
| `fetch_output` | Retrieve the full stored output behind an output_ref |

### Swarm Orchestration
… existing rows …
| `handoff` | Transfer conversation ownership to a specialized worker template |

### Memory & Solutions
… existing rows …
| `forget` | Remove or invalidate stored memory entries |
```

…plus two new subsections, placed after **Skills & Network** and before **Scheduling** (matching
the `agent.ex` group order — Browser, then Reasoning):

```markdown
### Browser
| Tool | Description |
|------|-------------|
| `browse_web` | Fetch and read web pages using a headless browser |
| `search_web` | Search the web via Brave Search; returns ranked results (title, URL, snippet) |

### Reasoning
| Tool | Description |
|------|-------------|
| `reason` | Apply a structured reasoning strategy to a complex problem |
| `run_pipeline` | Chain multiple reasoning strategies sequentially |
| `verify_certificate` | Verify code using semi-formal reasoning certificates |
```

Recount: File Ops 6 + Shell&Git 5 + Swarm 6 + Memory&Solutions 5 + Skills&Network 3 + Browser 2 +
Reasoning 3 + Scheduling 3 = **33** — header == body == `Agent.tool_modules()`.

### 3. `lib/jido_claw/platform/jido_md.ex` — generator template (Finding 1, prevents regression)

Inside the `jido_md_content/5` heredoc, replace the researcher block (`:95-98`) so freshly
generated JIDO.md files are correct from the start:

```markdown
    ### `researcher`
    - **Tools**: read_file, search_code, list_directory, project_info, browse_web, search_web
    - **Max iterations**: 15
    - **Use for**: Codebase exploration, architecture analysis, dependency mapping, understanding unfamiliar code, web research (discover with search_web, read with browse_web)
```

(Preserve the 4-space heredoc indentation already on these lines.)

## Out of scope (noted, not fixed)

Beyond the researcher row and the tool count fixed here, `.jido/JIDO.md` and the `jido_md.ex`
generator remain stale in other ways — wrong `Root:` path, missing `verifier` template (both the
committed file's "Agent Templates" list and the generator's "Available template names" line), and
dated model names. None are part of the V2-6 review findings, so this plan leaves them for a
possible separate JIDO.md-refresh pass.

## Verification (completion bar)

Run via `mise exec -- mix …`. Run gate commands **bare** (no `| tail` — a pipe masks the exit code)
in the background and read the output tail.

1. `mise exec -- mix format` — normalizes the wrapped `templates.ex` description; required before the format check.
2. `mise exec -- mix jidoclaw.compile_check` — strict compile (the precommit-safe gate; **not**
   `compile --warnings-as-errors`, which trips on the two intentional `pull_request_coordinator` warnings).
3. `mise exec -- mix test test/jido_claw/templates_test.exs test/jido_claw/prompt_test.exs` — the
   description/JIDO.md-adjacent tests stay green.
4. **`mise exec -- mix precommit`** — the hard completion bar; the plan is not "done" until this is green.
5. Sanity greps: `grep -n "search_web" .jido/JIDO.md lib/jido_claw/platform/jido_md.ex lib/jido_claw/agent/templates.ex`
   shows the web tools in all three; `grep -n "Tools (33 total)" .jido/JIDO.md` confirms the count;
   and the JIDO.md tool tables now list 33 rows (header == body == `Agent.tool_modules()`).

## Files to stage (when ready — I will leave everything unstaged)

- `lib/jido_claw/agent/templates.ex`
- `.jido/JIDO.md`
- `lib/jido_claw/platform/jido_md.ex`

Suggested commit message: `fix: sync researcher web-research capability across JIDO.md + template metadata`

(These build on the still-unstaged V2-6 change — `search_web.ex`, `researcher.ex`, both
`system_prompt.md` copies, etc. Stage them together or in sequence per your commit preference.)
