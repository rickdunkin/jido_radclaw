# AR-5 — Central Doctrine Injection into Sub-Agents

## Context

Source: `docs/exploration/alp-river/FEATURES-WORTH-BORROWING.md` §AR-5 (INDEPENDENT — pure
prompt assembly, no workflow-engine involvement). AR-5 is the enabler for AR-3 (reviewer
contract), AR-6 (personas), AR-7 (confidence-tagging) — those remain **separate items**, out
of scope here.

**The gap.** Today a spawned/skill-step worker's LLM never sees any JidoClaw-authored system
prompt. Verified facts:

- Workers never pass `:system_prompt` to `use Jido.AI.Agent`, so each runs on jido_ai's
  *generic default* ReAct prompt (`"You are a helpful AI assistant using the ReAct
  pattern…"`) — never a role, never project doctrine.
- A worker's `:description` is **metadata only** (surfaced in `spawn_agent`'s return payload and
  tool inspection) — it is **not** fed to the LLM (no dep reads `agent.description` for the
  prompt; confirmed no test asserts on its prose).
- The only mechanism that sets a real system prompt on a live agent pid is
  `Jido.AI.set_system_prompt/2`, called from exactly one place: `JidoClaw.Startup.do_inject/5`
  (`startup.ex:130`). It is wired only to the **main agent** (REPL/`chat`/handoff paths), never
  to `SpawnAgent` or the skill compiler's `AgentRunner`.
- Consequence: a coherent shared "doctrine" (the artifacts/produces convention) is **duplicated
  literally** — a prose sentence copy-pasted into 5 worker `:description` strings, plus an
  identical 9-line Zoi `artifacts` schema block in 5 workers' `output:` blocks.

**The change.** Give **spawn-agent and skill-step** sub-agents a real system prompt for the
first time — assembled from a central `JidoClaw.Doctrine` registry + reused Memory blocks +
reused JIDO.md — by injecting it onto the worker pid right after spawn, exactly the way the main
agent already replaces the default ReAct prompt via `Startup.inject_system_prompt`. Workers get
thinner (cite "your DOCTRINE block"); the artifacts convention becomes single-sourced.

**Scope boundary (handoff workers excluded).** Handoff-routed workers are *also* started via
`start_subagent` (`handoff/router.ex:427`), but they already receive a full prompt — the main
session prompt plus an additive handoff-context block — through `inject_prompt_for/4`
(`router.ex:469`). They are **not** prompt-starved like spawn/skill workers, so AR-5 deliberately
does not touch them; the wiring is the two spawn paths only. Composing doctrine *into* the
handoff prompt (fold `Doctrine.for_template/1` into `inject_prompt_for/4`) is a clean, isolated
extension point but a separate enhancement, out of scope for this minimal seam.

**Decisions confirmed with the user:** (1) **Minimal starter** doctrine content — seed the
seam + de-dup, let AR-3/6/7 expand content later; (2) **Fixed-in-code (Shape A)** registry — a
compile-time registry modeled on `JidoClaw.Reasoning.StrategyRegistry`, not a user-editable YAML
store. No data/path migration concerns (greenfield).

### Why these mechanics are safe (all verified against jido_ai + this tree)

- **`set_system_prompt` persists across turns.** It writes `config.system_prompt` +
  `context.system_prompt` (+ `run_context`) in the strategy state (`react/strategy.ex:868-887`),
  re-read every turn (`:669`, `:2056`). Inject **once at spawn** → it sticks for every later
  `ask`/`ask_sync` follow-up on the same pid (`SendToAgent` reuses the pid, never re-spawns).
- **No race calling it right after `start_subagent`.** `Jido.AgentServer.init/1` returns
  `{:ok, state, {:continue, :post_init}}`; the strategy (and its default prompt) is seeded in
  `handle_continue(:post_init)`, which BEAM runs *before* any mailbox message. Our
  `set_system_prompt` is a `GenServer.call` (a mailbox message) → it is serialized **after**
  `:post_init` and always wins. `Startup.inject_handoff_prompt/4` is the working precedent for
  this exact post-start injection.
- **Compaction/Recorder cannot clobber it.** Compaction rewrites only the message-history list
  and always keeps leading `:system` rows (`compactor/request_transformer.ex`); the Recorder
  plugin is an observer. The `on_before_cmd` `{:ai_react_start,_}` hook touches the action, not
  `config.system_prompt`.
- **`output:` accepts a function call.** `Jido.AI.Agent.__using__` runs
  `Code.eval_quoted(.., caller_env)` on the `output:` AST at the worker's compile time
  (`agent.ex:256-285`), so `artifacts: OutputSchema.artifacts()` evaluates and inlines the Zoi
  struct — **provided `OutputSchema` is a separate module** (Mix orders it first via the
  compile-dependency edge; do **not** define the helper in a worker and call it from that same
  worker's `use`).
- **Memory blocks reach workers with no shape mismatch.** `JidoClaw.Memory.Scope.resolve/1`
  (`scope.ex:75`) takes the *flat tool_context* the spawn paths already carry (`:tenant_id`,
  `:user_id`, `:workspace_uuid`, `:session_uuid`) and returns a `scope_record`;
  `Memory.namespace_info/1` (`memory.ex:237`) already demonstrates the exact
  `tool_context → resolve → list_blocks_for_scope_chain` chain we reuse. Note: the tool_context
  does **not** carry `:project_id` (not a `@canonical_keys` member; `ToolContext.build/1` and
  `AgentRunner.resolve_scope/2` don't set it), so `resolve/1` derives project from the workspace
  lookup when `:workspace_uuid` is present — workspace/session/user Blocks all resolve. Project-
  *only* Blocks would need `:project_id` added to `ToolContext.@canonical_keys` deliberately —
  out of scope for this minimal seam.

---

## Implementation (6 phases)

4 new modules + 3 priv doctrine files; 11 existing files edited. Phases are ordered so each
compiles green on its own.

### Phase 1 — De-dup the Zoi artifacts schema

**New:** `lib/jido_claw/agent/workers/output_schema.ex`

```elixir
defmodule JidoClaw.Agent.Workers.OutputSchema do
  @moduledoc "Shared Zoi schema fragments single-sourced across worker `output:` blocks (AR-5)."

  @doc "Runtime-artifacts object reused by 5 workers (optional url/port/files, preserve unknowns)."
  @spec artifacts() :: Zoi.schema()
  def artifacts do
    Zoi.object(
      %{
        url: Zoi.optional(Zoi.string()),
        port: Zoi.optional(Zoi.string()),
        files: Zoi.optional(Zoi.string())
      },
      unrecognized_keys: :preserve
    )
  end
end
```

**Edit the 5 workers** — replace the inline 9-line `artifacts:` block with
`artifacts: OutputSchema.artifacts()` (add `alias JidoClaw.Agent.Workers.OutputSchema` above the
`use`): `coder.ex:32-40`, `researcher.ex:36-44`, `refactorer.ex:32-40`, `docs_writer.ex:34-42`,
`test_runner.ex:35-43`. Reviewer/Verifier have no `artifacts` field — untouched.

**Verify:** `mix test test/jido_claw/agent/workers/worker_output_schemas_test.exs` — schema is
byte-identical (it parses `module.strategy_opts()[:output]`), so all describe blocks stay green
with zero test edits. This existing test is the de-dup regression gate.

### Phase 2 — Extract shared prompt-section renderers

**New:** `lib/jido_claw/agent/prompt_sections.ex` — move three helpers out of `Prompt`
(`prompt.ex:243-273`, `:456-463`) **verbatim**, made public, so `Prompt` and the new
`SubagentPrompt` single-source them:

```elixir
defmodule JidoClaw.Agent.PromptSections do
  @moduledoc "Shared dynamic prompt-section renderers for the main- and sub-agent assemblers."
  alias JidoClaw.Memory.Block

  @spec blocks_section([Block.t()]) :: String.t()   # "## Memory Blocks" section, "" for []
  @spec jido_md_section(String.t() | nil) :: String.t()
  @spec load_jido_md(String.t()) :: String.t() | nil # reads <project_dir>/.jido/JIDO.md
end
```

**Edit `lib/jido_claw/agent/prompt.ex`:** delete the three moved private clauses; add
`alias JidoClaw.Agent.PromptSections`; in `build_snapshot/2` call
`PromptSections.blocks_section/1`, `PromptSections.jido_md_section/1`,
`PromptSections.load_jido_md/1`. `Prompt` keeps its own `render_block_tier/1` (the
`scope_record`-input main-agent path). Output is **byte-identical** → `prompt_snapshot_test.exs`
(all 5 tests incl. the secret-redaction one) stays green, no edits.

> `JidoClaw.Memory.Block` is the module (it lives at `memory/resources/block.ex` but is *named*
> `JidoClaw.Memory.Block`). `Block.t()` is Ash-generated and `memory.ex:176` already specs
> `[Block.t()]` + passes dialyzer; if dialyzer ever flags it, fall back to `[map()]`.

### Phase 3 — The doctrine registry + the sub-agent prompt assembler

**New:** `lib/jido_claw/doctrine.ex` — Shape A compile-time registry (model:
`reasoning/strategy_registry.ex`). **All three** slices live in
`priv/defaults/doctrine/{base,artifacts,reviewer_min}.md`, each embedded via `@external_resource`
+ `File.read!` using `Path.join([__DIR__, "..", "..", "priv", ...])` (the `prompt.ex:26` pattern
— **never** `Path.expand("…priv…")`, ExSlop bans it):

```elixir
defmodule JidoClaw.Doctrine do
  @moduledoc """
  Central doctrine registry (AR-5): shared rules injected into spawned sub-agents'
  system prompts (spawn-agent + skill-step). Slices are authored-once priv-file text,
  gated per template by `@template_slices`. Workers cite "your DOCTRINE block" instead
  of duplicating rules.
  """
  # All three slices are priv-file-backed (consistent with system_prompt.md), each with
  # its own @external_resource above so recompiles track edits to the .md files:
  @slices %{
    base: File.read!(@base_priv),
    artifacts: File.read!(@artifacts_priv),
    reviewer_min: File.read!(@reviewer_min_priv)
  }
  @template_slices %{
    "coder" => [:base, :artifacts], "refactorer" => [:base, :artifacts],
    "docs_writer" => [:base, :artifacts], "researcher" => [:base, :artifacts],
    "test_runner" => [:base, :artifacts],
    "reviewer" => [:base, :reviewer_min], "verifier" => [:base, :reviewer_min]
  }

  @spec slice(atom()) :: String.t()              # one slice, "" for unknown key
  @spec for_template(String.t()) :: String.t()   # slices joined "\n\n", "" for unmapped (incl. "main")
  @spec list() :: [atom()]                        # all slice keys
  @spec template_names() :: [String.t()]          # @template_slices keys — public surface for the drift test
end
```

Single-sourced in code (no config-driven slice list — a config typo can never empty doctrine;
mirrors `ToolApproval.default_require/0`). `for_template("main")` → `""` (the main agent uses
`Prompt`, so doctrine never double-applies).

**New:** `lib/jido_claw/agent/subagent_prompt.ex` — the worker-scoped assembler (parallel to
`Prompt`, but never reads `.jido/system_prompt.md`; it builds a standalone prompt that *replaces*
the default ReAct prompt):

```elixir
defmodule JidoClaw.Agent.SubagentPrompt do
  @moduledoc "Assembles the system prompt injected into a spawned sub-agent (AR-5)."
  alias JidoClaw.Agent.{PromptSections, Templates}
  alias JidoClaw.Doctrine
  alias JidoClaw.Memory
  alias JidoClaw.Memory.Scope

  @doc """
  Build a sub-agent system prompt for `template_name` from the worker's `tool_context`
  (carries project_dir + scope keys). Composition: role (worker module `description/0`) +
  `## DOCTRINE` (Doctrine.for_template/1) + reused Memory blocks (scope resolved from the
  tool_context, best-effort) + reused JIDO.md. Total/never-raises: unknown template → generic
  role line; unresolvable/absent scope → no Block tier (mirrors the main-agent nil-scope path).
  """
  @spec build(String.t(), map()) :: String.t()
end
```

Internals: `project_dir = Map.get(tool_context, :project_dir) || File.cwd!()`. **Role** from the
worker module's richer `description/0` — `Templates.get/1` → `template.module`, then
`module.description()` guarded by `Code.ensure_loaded?/1` + `function_exported?(module, :description, 0)`
(the `agent_runner.ex:145-147` precedent), fallback `"# Role\nYou are a specialized sub-agent."`.
This is the worker's full role text (minus the artifacts prose thinned in Phase 5), **not** the
short parent-facing `Templates` label. **Doctrine** from `Doctrine.for_template/1` (omit the
`## DOCTRINE` header when `""`). **Blocks** from a private `blocks_for_context/1` =
`case Scope.resolve(tool_context) do {:ok, s} -> Memory.list_blocks_for_scope_chain(s); _ -> [] end`
wrapped `rescue _ in @db_errors -> []` / `catch :exit, _ -> []` (define
`@db_errors JidoClaw.Core.AshErrors.db_errors()` at the module top, as `prompt.ex:23` /
`memory.ex` do; carry the `# credo:disable-for-previous-line ExSlop.Check.Warning.RescueWithoutReraise`
pragma per `prompt.ex:329`). **JIDO.md** via `PromptSections.load_jido_md/1`.

### Phase 4 — The gated injection seam in `Startup` + wire both spawn paths

**Edit `lib/jido_claw/startup.ex`** — add `require Logger`, a `@doctrine_defaults [enabled?: true]`
attr, and one public function reusing the existing private `do_inject/5`:

```elixir
@doc """
Inject the AR-5 doctrine system prompt onto a freshly-spawned sub-agent pid — the first
system prompt workers receive. Gated by `config :jido_claw, :doctrine, enabled?:` (disabled →
no-op `:ok`). Best-effort: any failure logs and returns `:ok`, never blocking the spawn.
Reuses do_inject/5 (emits `[:jido_claw, :agent, :prompt_injected]`, source `:doctrine`).
"""
@spec inject_subagent_prompt(pid(), String.t(), map()) :: :ok
def inject_subagent_prompt(pid, template_name, tool_context)
    when is_pid(pid) and is_binary(template_name) do
  if doctrine_enabled?() do
    project_dir = Map.get(tool_context, :project_dir) || File.cwd!()
    prompt = JidoClaw.Agent.SubagentPrompt.build(template_name, tool_context)

    # do_inject/5 returns :ok | {:error, reason} (startup.ex:129-143) — log the error
    # tuple too, not just raises/exits.
    case do_inject(pid, prompt, project_dir, :doctrine, %{template: template_name}) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("[Doctrine] set_system_prompt failed (#{template_name}): #{inspect(reason)}")
        :ok
    end
  else
    :ok
  end
rescue
  # reach:disable-next-line bare_rescue
  e -> Logger.warning("[Doctrine] subagent prompt injection failed: #{Exception.message(e)}"); :ok
catch
  :exit, _ -> :ok            # dead/slow pid — never block the spawn
end
```

`doctrine_enabled?/0` = `Application.get_env(:jido_claw, :doctrine, []) |> Keyword.get(:enabled?, @doctrine_defaults[:enabled?])`
(the `output_shaper.ex:138-142` pattern). `do_inject/5` already takes an arbitrary `source` atom
+ extra-metadata map, so `:doctrine` / `%{template: …}` flow through unchanged.

**Wire — both sites sit right beside the existing best-effort `mcp().ensure_attached` call**
(same fire-and-forget treatment; the two are independent agent-config fields, order-insensitive):

- `lib/jido_claw/tools/spawn_agent.ex` — in `start_orchestration/7`'s supervised task, after the
  `mcp().ensure_attached(subagent_pid, template_name, 8_000)` at **line 167**:
  `_ = JidoClaw.Startup.inject_subagent_prompt(subagent_pid, template_name, child_tool_context)`
  (runs inside the Task so it never blocks the caller; `child_tool_context` carries project_dir +
  scope keys + `:agent_template`; runs before the first `SubagentTranscript.run`).
- `lib/jido_claw/skills/steps/agent_runner.ex` — in `run/4`'s `with` body, after the
  `mcp().ensure_attached(pid, template_name, 8_000)` at **line 67**:
  `_ = JidoClaw.Startup.inject_subagent_prompt(pid, template_name, tool_context)`.

### Phase 5 — Feature-flag config + thin worker descriptions

**Edit `config/config.exs`** (near the other flags, ~line 255): `config :jido_claw, :doctrine, enabled?: true`
with a short comment (kill switch; disabling restores legacy no-doctrine worker behavior).

**Edit `config/test.exs`** (near the other flags, ~line 20): `config :jido_claw, :doctrine, enabled?: false`
with a comment ("doctrine's own tests opt in via `Application.put_env` + `on_exit`, async: false")
— keeps the broad suite on today's behavior so existing spawn/skill tests are unaffected.

**Thin the 5 worker descriptions** (`coder.ex:6`, `refactorer.ex:6`, `docs_writer.ex:6`,
`researcher.ex:6`, `test_runner.ex:6`) — drop the duplicated trailing artifacts sentence
("…and `artifacts` (an object with optional `url`/`port`/`files` — use `{}` if none)."); the
behavioral contract now reaches the model via the `:artifacts` doctrine slice. (Leave the
separate short `templates.ex` descriptions alone — those *do* reach the parent LLM in
`spawn_agent`'s return payload.)

### Phase 6 — `mix precommit` green (gate; see checklist below)

---

## Doctrine content to seed (minimal starter)

Three slices. The reviewer slice is a deliberate **minimal placeholder** — the full Reviewer
Contract is AR-3.

- **`:base`** (all workers) — thin role + output discipline: "You are a specialized sub-agent…
  stay within your task and tools; return your structured output object exactly as your schema
  requires (no prose wrapper / code fences); be concise — report what you did, found, and any
  blockers."
- **`:artifacts`** (the 5 producing workers) — the de-duped produces/artifacts convention as a
  `## Runtime artifacts` block: report discovered runtime details (url/port/files) in the
  `artifacts` field; `{}` when none; don't invent values. (Single source replacing both the 5
  description sentences and conceptually aligning with `AgentRunner.inject_produces_instruction/2`.)
- **`:reviewer_min`** (reviewer, verifier) — `## Review discipline (summary)`: judge only what
  the diff/code shows; separate correctness from style; state a clear verdict; keep it short;
  "a fuller review contract may be supplied separately."

---

## Test plan

All new files; the two existing touched tests (`worker_output_schemas_test.exs`,
`prompt_snapshot_test.exs`) need **zero edits** (byte-identical schema / output).

- **T1 `test/jido_claw/doctrine_test.exs`** (`async: true`, no DB): `slice/1` non-empty for the 3
  keys, `""` for unknown; `for_template("coder")` contains base + artifacts text, NOT reviewer;
  `for_template("reviewer")` contains reviewer-min, NOT artifacts; `for_template("main")` and
  unknown → `""`. **Registry-drift guard:** every name in `Doctrine.template_names/0` satisfies
  `Templates.exists?/1`, and the set equals `Templates.names/0` (the 7 worker names; `"main"` is
  intentionally absent from both) — so a future worker added without doctrine fails this test.
- **T2 `test/jido_claw/agent/subagent_prompt_test.exs`** (`use JidoClaw.TenantCase, async: false`
  — needs the Block-tier DB read; model the Block write + scope on `prompt_snapshot_test.exs:41-71`):
  `build("coder", ctx_with_project_dir)` is non-empty, contains `## DOCTRINE` + artifacts text +
  the coder role, and NOT `Memory Blocks` when scope is unresolvable; `build("reviewer", …)` has
  reviewer-min not artifacts; with a real tenant/workspace scope in the tool_context + a written
  Block → contains `Memory Blocks` + the block label/value (proves `Scope.resolve` + section
  reuse); a Block written with a raw secret never appears unredacted (mirror
  `prompt_snapshot_test.exs:73-108` — proves redaction-at-write carries through `PromptSections`).
- **T3 `test/jido_claw/startup_subagent_prompt_test.exs`** — isolates the function's own branches
  (`async: false`, flips the flag via read-original/`put_env`/`on_exit`): attach a telemetry
  handler to `[:jido_claw, :agent, :prompt_injected]`. Flag ON → `inject_subagent_prompt(pid, "coder", ctx)`
  returns `:ok` and fires the event with `source: :doctrine`, `metadata.template == "coder"`
  (spawn a real worker via `JidoClaw.Jido.start_subagent(Workers.Coder, id: …)` — stop it in
  `on_exit` with `JidoClaw.Jido.stop_agent/1`); flag OFF → `:ok` and event does **not** fire
  (kill-switch proof); dead pid → `:ok` (best-effort `catch :exit`).
- **T4 wiring tests — prove the call sites actually invoke the seam.** Required because the flag
  is OFF globally in `config/test.exs`, so a future deletion of either call would otherwise slip
  through silently. Two cases, each `@tag :capture_log`, flag enabled via `put_env`/`on_exit`, a
  telemetry handler on `[:jido_claw, :agent, :prompt_injected]` asserting a `source: :doctrine`
  event with the right `metadata.template`. Injection succeeds only when the **pid/runtime**
  handles the ReAct `ai.react.set_system_prompt` signal — so map the template (via
  `:agent_templates_override`) to a `use Jido.AI.Agent`/`Defaults` module **and** use a real
  `JidoClaw.Jido.start_subagent/2` (the default runtime), **not** a fake runtime returning a
  sleeping pid (an AI-based module behind a sleeping pid still won't handle the signal). The event
  emits *before* the worker's own turn runs (a later LLM-less turn may error — absorbed by the tag
  — but the injection already fired):
  - **SpawnAgent** (extend `test/jido_claw/tools/spawn_agent_test.exs`): drive the spawn path; the
    orchestration Task fires the event right after `ensure_attached` (`spawn_agent.ex:167`).
    `assert_receive` the event.
  - **AgentRunner** (extend a skills-step test, e.g. alongside `step_retry_test.exs`): call
    `AgentRunner.run/4`; the event fires after `ensure_attached` (`agent_runner.ex:67`).
  - **Cleanup:** any worker started with a real runtime must be stopped in `on_exit` via
    `JidoClaw.Jido.stop_agent/1` so a failing assertion never leaks a supervised process.

---

## Precommit-readiness checklist (`mix.exs:366-375`)

1. **compile_check (zero warnings, empty allowlist):** `_ =` prefix on both fire-and-forget
   injection calls; `@moduledoc` on all 4 new modules; `OutputSchema.artifacts/0` is called at
   worker compile-time (no "unused"); PromptSections extraction leaves no orphaned private. No
   compile cycles (`OutputSchema`/`Doctrine`/`PromptSections` depend on nothing in `lib/` that
   depends back).
2. **system_prompt.check (tool-catalog drift):** AR-5 adds **no `Jido.Action` tool** → safe. (Do
   not add one.)
3. **deps.unlock --unused:** no new deps.
4. **format:** new files + the `output:` one-liner stay formatted.
5. **reach.check --strict:** `Path.join([__DIR__,…])` not `Path.expand` (PathExpandPriv); the two
   best-effort rescues carry the `RescueWithoutReraise`/`bare_rescue` pragmas per the
   `prompt.ex:329` / `startup.ex` precedents; comments explain *why* (no StepComment/Narrator);
   `render_block_tier` (Prompt, scope_record) vs `blocks_for_context` (SubagentPrompt,
   tool_context) are genuinely different inputs, not a clone.
6. **credo --strict:** every public fn has `@spec`; every module `@moduledoc`; no `@impl true`
   (none implement a behaviour); aliases ordered/used; no TODO/FIXME, no IO.inspect/dbg.
7. **dialyzer:** `Zoi.schema()` in `OutputSchema`'s spec — the dep's public type alias for
   `Zoi.Type.t()` (`zoi.ex:149`); **`Zoi.t()` does not exist**. `SubagentPrompt.build/2` spec uses
   `map()`; `inject_subagent_prompt/3` always returns `:ok`.
8. **test:** T1–T4 new; existing suite unaffected (flag OFF in `config/test.exs`).

Run bare in the background and read the tail (never pipe — `| tail` masks the exit code):
`mix precommit`. Pre-stages while iterating: `mix jidoclaw.compile_check`, `mix format`,
`mix credo --strict`, then targeted `mix test` files above.

---

## Open items to verify early during implementation (bounded; not deferrals)

1. **`output:` function-call compile (Phase 1).** Mechanism verified (jido_ai
   `Code.eval_quoted` in caller env) and empirically compiled in a probe. Confirm in-tree:
   `mix compile --force` clean + the worker_output_schemas test green. If a future jido_ai bump
   ever broke it, the isolated fallback is to revert this one de-dup (keep the rest of AR-5) — the
   blast radius is one phase.
2. **`Block.t()` in the `PromptSections.blocks_section/1` spec (Phase 2).** Expected to resolve
   (Ash-generated, already used in `memory.ex:176`); if dialyzer disagrees, spec `[map()]`.

No part of AR-5 is large enough to warrant its own design doc; the two items above are small,
bounded checks with clear fallbacks.

## Critical files

- New: `lib/jido_claw/agent/workers/output_schema.ex`, `lib/jido_claw/agent/prompt_sections.ex`,
  `lib/jido_claw/doctrine.ex`, `lib/jido_claw/agent/subagent_prompt.ex`,
  `priv/defaults/doctrine/*.md`.
- Edit: `lib/jido_claw/startup.ex` (new gated seam reusing `do_inject/5`),
  `lib/jido_claw/tools/spawn_agent.ex:167`, `lib/jido_claw/skills/steps/agent_runner.ex:67`,
  `lib/jido_claw/agent/prompt.ex` (extract to PromptSections), the 5 workers (Zoi de-dup +
  description thinning), `config/config.exs`, `config/test.exs`.
