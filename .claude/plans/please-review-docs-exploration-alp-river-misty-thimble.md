# AR-6 — Psychology / Persona Layer

## Context

`docs/exploration/alp-river/FEATURES-WORTH-BORROWING.md` tracks eight features ported
from the Alp River Claude-Code plugin. Seven have shipped; **AR-6 (the persona layer) is
the last not-started independent borrow** (AR-7's pervasive extension is the only other
open tail). It is rated "cheap, genuinely novel, ~a day on top of AR-5."

**The need.** jido_radclaw's specialized sub-agents are differentiated only by role
(`:description` + tool subset). Alp River adds a thin **advisory "voice"** — a 5-line
persona (Belief / Drive / Default move / Voice / Conflict rule) — so a security reviewer
reasons like a *defender* (threat-model first), a fixer like a *cynic* (what can be
deleted), a prototyper like an *optimist* (ship a tracer). It is pure prompt assembly with
a hard safety valve: every persona ends with the identical **conflict rule** — *"Your role
contract is mandatory; persona is advisory voice. On conflict, the role and the codebase
win."*

**The outcome.** A new `JidoClaw.Persona` registry (mirroring the shipped `JidoClaw.Doctrine`)
injects a `## PSYCHOLOGY: <Name>` block into spawned/composed sub-agent prompts through the
existing AR-5 seam (`Agent.SubagentPrompt.build/2`), with section-level persona gating, and with
no behavioral change to the main agent. **Done = `mix precommit` green.**

> **Revised after design review.** Five issues were caught and folded in: (1) the composer
> stage must travel on a **dedicated `catalog_stage_name`** option, not the overloaded
> `step_name` (which doubles as the YAML/skill label); (2) `:psychology` is a **section-level**
> toggle — `:doctrine` stays the master injection gate (the "independent" claim was overstated);
> (3) **handoff-routed workers are excluded** by the same seam boundary AR-5 has — called out;
> (4) the composer seam gets **telemetry + a wave-builder test**; (5) the **conflict rule is
> single-sourced** in the renderer.

## Decisions (locked with the user + review)

1. **Per-stage keying (faithful), via a dedicated option.** Personas key off the **catalog
   stage name** first, with the **template name** as fallback. The four code reviewers are four
   catalog *stages* (`security-reviewer` / `quality-reviewer` / `correctness-reviewer` /
   `architecture-reviewer`) over the **single `"reviewer"` template**, so template-only keying
   (how Doctrine keys) would collapse them to one voice; per-stage gives
   defender / craftsperson / skeptic / pragmatist. **The stage travels on a new, dedicated
   `catalog_stage_name` option set ONLY by `WaveBuilder`** — *not* the existing `step_name`,
   which is also the arbitrary YAML/skill-step label (`agent_step.ex:13-14`,
   `iterative_step.ex`). A skill step a user happens to name `"security-reviewer"` must **not**
   inherit a stage persona; with the dedicated option it gets `nil` → template fallback.
2. **Sub-agents only — the AR-5 seam's three paths.** Personas reach exactly where AR-5 doctrine
   reaches: initial spawn (`spawn_agent.ex`), skill/composer step (`agent_runner.ex`), and
   follow-up turn (`send_to_agent.ex`). The main agent (`"main"`, `prompt.ex`) gets none.
   **Boundary (explicit):** handoff-routed specialist workers inject through a *different* path
   (`router.ex:492-499` → `Startup.inject_system_prompt` / `inject_handoff_prompt`, the session
   prompt), so they receive **neither doctrine nor persona** — the same boundary AR-5 already
   has (`inject_subagent_prompt` has zero handoff callers). Extending to handoff is a separate
   change; v1 keeps AR-5's boundary unchanged.
3. **Section-level config toggle (`:doctrine` stays master).** A new
   `config :jido_claw, :psychology, enabled?:` (on in `config.exs`, off in `test.exs`) gates
   **only** the `## PSYCHOLOGY` block, checked inside `SubagentPrompt`'s `persona_section`. The
   pre-existing `:doctrine` flag remains the **master gate** in `Startup.inject_subagent_prompt`
   — it governs whether *any* assembled sub-agent prompt (role + doctrine + persona + blocks +
   JIDO.md) is injected at all. So with `:doctrine` **off**, nothing injects and persona is moot
   (not re-enabled by `:psychology`). The two flags are independent only in that toggling one
   never alters the other's section *within* an injected prompt. Persona needs its own flag so a
   test/operator turning doctrine **on** doesn't auto-surface persona text — `test.exs` keeps
   psychology off, leaving existing doctrine-on assembly tests unperturbed.
4. **No per-project overrides** (Alp River's `alpRiver.psychologyOverrides`) — explicit v1
   non-goal (greenfield; Doctrine has none either).

## How it rides the existing AR-5 seam (reuse, don't reinvent)

The seam already flows a template name to one assembly point; the composer stage name already
flows to the same injector as `step_name`. AR-6 adds one registry, one prompt section, and one
**dedicated** stage option alongside `step_name` — nothing else moves.

- `JidoClaw.Doctrine` (`lib/jido_claw/doctrine.ex`) — the **pattern to parallel**: compile-time
  priv-file slices, `@external_resource` per file, a string-keyed template map, `for_template/1`
  + `*_names/0`, and a drift-guard test.
- `Agent.SubagentPrompt.build/2` (`lib/jido_claw/agent/subagent_prompt.ex:22-31`) — the single
  assembly point; `doctrine_section/1` (`:55-60`) is the section-renderer pattern (empty string
  omits the header).
- `Startup.inject_subagent_prompt/3` (`lib/jido_claw/startup.ex:143-174`) — the gated injector,
  three callers, emits `[:jido_claw, :agent, :prompt_injected]` via `do_inject/5` (`:182-196`).
- The composer stage already reaches the injector: `wave_builder.ex:146-160` builds the
  `AgentStep` options → `agent_step.ex:51-68` → `AgentRunner.run(template, task, step_name, ctx)`
  (`agent_runner.ex:58`) → `inject_subagent_prompt` (`:79`). AR-6 threads a **second** value
  (`catalog_stage_name`) along this exact chain.

---

## Change set

### 1. New module — `lib/jido_claw/persona.ex`

Structural sibling of `Doctrine`, with three deliberate differences: (a) the 9 uniform persona
files load via **one comprehension** over `@persona_names` (not 9 named `@xxx_priv` attributes) —
the ExDNA clone-check mitigation (§ "Precommit"); (b) **two-level resolution** (`@stage_persona`
first, `@template_persona` fallback); (c) the **conflict rule is single-sourced** in `@conflict_rule`
and appended by the renderer, so every persona is guaranteed to carry the identical role-wins
safety valve and it can never drift. Persona identity is the **filename-stem string** (no
`String.to_atom` — `UnsafeToAtom` is enabled).

```elixir
defmodule JidoClaw.Persona do
  @moduledoc """
  AR-6 psychology persona registry: an advisory `## PSYCHOLOGY: <Name>` voice block injected
  into spawned sub-agents' system prompts via the AR-5 `SubagentPrompt` seam. Personas are
  authored-once priv-file text, resolved STAGE-FIRST (catalog stage name) with a TEMPLATE-name
  fallback — so the four reviewer stages over the single `reviewer` template get distinct voices.
  Advisory only: the renderer appends the single-sourced mandatory conflict rule ("the role and
  the codebase win") to every block. Independently gated by `config :jido_claw, :psychology`
  (checked in `SubagentPrompt`).
  """

  # Load the 9 uniform persona files with ONE comprehension over @persona_names — deliberately
  # unlike Doctrine's per-slice @xxx_priv attributes, so the two registries never form an ExDNA
  # clone family. Each file is an @external_resource (recompile on edit).
  @persona_dir Path.join([__DIR__, "..", "..", "priv", "defaults", "persona"])
  @persona_names ~w(craftsperson cynic defender detective optimist pragmatist skeptic teacher user-advocate)

  # The advisory safety valve — single-sourced HERE, not duplicated in the 9 files. Guarantees
  # every rendered persona carries the byte-identical role-wins rule; impossible to drift.
  @conflict_rule "Your role contract is mandatory; persona is advisory voice. " <>
                   "On conflict, the role and the codebase win."

  for name <- @persona_names do
    @external_resource Path.join(@persona_dir, name <> ".md")
  end

  @personas (for name <- @persona_names, into: %{} do
               {name, String.trim(File.read!(Path.join(@persona_dir, name <> ".md")))}
             end)

  # Catalog STAGE name → persona. The four reviewer stages (all the single `reviewer` template)
  # get DISTINCT voices — the whole point of per-stage keying.
  @stage_persona %{
    "planner" => "detective",
    "test-author" => "skeptic",
    "implementer" => "craftsperson",
    "security-reviewer" => "defender",
    "quality-reviewer" => "craftsperson",
    "correctness-reviewer" => "skeptic",
    "architecture-reviewer" => "pragmatist",
    "fixer" => "cynic",
    "sketch-build" => "optimist",
    "sketch-build-exec" => "optimist",
    "sketch-review" => "skeptic",
    "system-executor" => "teacher",
    "system-verifier" => "detective"
  }

  # TEMPLATE name → persona — the fallback for a direct spawn / follow-up / non-catalog step.
  # Total over all 13 worker templates (the drift guard asserts equality with `Templates.names/0`).
  @template_persona %{
    "coder" => "craftsperson",
    "fixer" => "cynic",
    "test_runner" => "skeptic",
    "reviewer" => "skeptic",
    "docs_writer" => "teacher",
    "researcher" => "detective",
    "refactorer" => "cynic",
    "verifier" => "skeptic",
    "sketch_build" => "optimist",
    "sketch_reviewer" => "skeptic",
    "sketch_build_exec" => "optimist",
    "system_executor" => "teacher",
    "system_verifier" => "detective"
  }

  @doc """
  Pick the persona name for a worker: the `@stage_persona` entry for `catalog_stage_name` when
  present, else the `@template_persona` entry for `template_name`, else `""`. `catalog_stage_name`
  is `nil` for a direct spawn / follow-up / non-composer skill step.
  """
  @spec resolve(String.t() | nil, String.t()) :: String.t()
  def resolve(catalog_stage_name, template_name) when is_binary(template_name) do
    stage_persona(catalog_stage_name) || Map.get(@template_persona, template_name, "")
  end

  @doc "Render one persona's `## PSYCHOLOGY: <Display>` block (4 sections + the appended conflict rule), or `\"\"`."
  @spec render(String.t()) :: String.t()
  def render(persona) when is_binary(persona) do
    case Map.get(@personas, persona) do
      nil -> ""
      body -> render_block(persona, body)
    end
  end

  @doc "Resolve `catalog_stage_name`/`template_name` to a persona and render its block (`\"\"` when none)."
  @spec render_for(String.t() | nil, String.t()) :: String.t()
  def render_for(catalog_stage_name, template_name) when is_binary(template_name) do
    render(resolve(catalog_stage_name, template_name))
  end

  @doc "Every persona name — one per `priv/defaults/persona/*.md`; the universe `render/1` accepts."
  @spec names() :: [String.t()]
  def names, do: @persona_names

  @doc "Catalog stage names that carry a persona — public surface for the drift test."
  @spec stage_names() :: [String.t()]
  def stage_names, do: Map.keys(@stage_persona)

  @doc "Worker templates that carry a fallback persona — equals `Templates.names/0` (drift test)."
  @spec template_names() :: [String.t()]
  def template_names, do: Map.keys(@template_persona)

  defp stage_persona(name) when is_binary(name), do: Map.get(@stage_persona, name)
  defp stage_persona(_other), do: nil

  defp render_block(persona, body) do
    "## PSYCHOLOGY: " <>
      display(persona) <>
      "\n\n" <>
      body <>
      "\n\n## Conflict rule\n" <>
      @conflict_rule
  end

  defp display(persona) do
    persona
    |> String.replace("-", " ")
    |> String.capitalize()
  end
end
```

`String.capitalize/1` reproduces Alp River's display rule (`"user-advocate"` → `"User advocate"`,
`"cynic"` → `"Cynic"`). `names/0` returns `@persona_names` directly so no two `Map.keys` accessors
form a contiguous identical run.

### 2. New priv files — `priv/defaults/persona/<name>.md` (9 files, **4 sections each**)

Each carries only the four **distinctive** sections (Belief / Drive / Default move / Voice) with
**space** headers; the renderer appends `## Conflict rule` + `@conflict_rule`. This is a deliberate,
faithful improvement over the source (the source repeats the rule in every file; we single-source
the safety valve). Content ported verbatim from `~/workspace/claws/alp-river/psychology/`, minus
the conflict-rule block. (Markdown is not linted; the files are not an ExDNA/reach concern.)

<details><summary>All 9 bodies (verbatim, conflict rule removed)</summary>

`craftsperson.md`
```markdown
## Belief
Code is read ten times more than it's written. Today's shortcut is tomorrow's outage.

## Drive
Durable quality. Internal consistency.

## Default move
Name things carefully. Delete more than you add. Refuse ugly merges.

## Voice
Evidence-based about decay. Quote precedents in the codebase.
```

`cynic.md`
```markdown
## Belief
The real enemy is accumulated complexity. Most "improvements" make things worse.

## Drive
Subtraction.

## Default move
Ask what could be deleted instead of what should be added.

## Voice
Skeptical of features and abstractions. Names the cheaper path of doing less.
```

`defender.md`
```markdown
## Belief
The world is adversarial. Users will paste anything; attackers will probe everything.

## Drive
Harden the seams.

## Default move
Read the input from the attacker's perspective. Find the abuse case before the fix.

## Voice
Threat-model first. Frame issues by failure mode and exploit vector.
```

`detective.md`
```markdown
## Belief
Symptoms lie. The named problem is rarely the actual problem.

## Drive
Chase the cause.

## Default move
Follow the tail. Pull the slowest cases. Find what they share.

## Voice
Trace-driven. Reasons from specific evidence to a hypothesis.
```

`optimist.md`
```markdown
## Belief
Experiments are cheap. Momentum compounds.

## Drive
Learn by trying. Forward motion.

## Default move
Ship a tracer fast. Measure. Decide on evidence.

## Voice
Forward-leaning. Frames decisions as cheap experiments, not commitments.
```

`pragmatist.md`
```markdown
## Belief
Ship beats perfect. The customer doesn't read your code.

## Drive
Progress, finished things, momentum.

## Default move
Smallest viable change. Defer cleanup until pain forces it.

## Voice
Direct triage. Frame work by impact, not elegance.
```

`skeptic.md`
```markdown
## Belief
Most code is wrong until proven. "It works" usually means "you didn't test the bad path."

## Drive
Catch failure before users do.

## Default move
Probe assumptions. Demand repro. Distrust green tests.

## Voice
Falsification first. Frame findings as failed assumptions.
```

`teacher.md`
```markdown
## Belief
The next maintainer is the actual customer. People grow more than code does.

## Drive
Leave durable understanding. Make the rationale legible.

## Default move
Write the why next to the what. Refuse to leave magic. Document the seam.

## Voice
Explains the reasoning trail. Treats the future reader as the audience.
```

`user-advocate.md`
```markdown
## Belief
Technical elegance that costs users is bankrupt.

## Drive
The person on the other end of the screen.

## Default move
Start from the user's experience, not the architecture. Refuse to reason backward from the code.

## Voice
Reframes internal issues as user-facing ones whenever possible.
```

</details>

### 3. `lib/jido_claw/agent/subagent_prompt.ex` — add the gated section

- `alias JidoClaw.Persona` (after `alias JidoClaw.Memory.Scope`; keep `AliasOrder` happy).
- `@psychology_defaults [enabled?: true]` (near `@db_errors`).
- `build/2` → `build/3` (default-arg `catalog_stage_name \\ nil`, so existing `build/2` callers and
  tests are untouched); splice `persona_section/2` **after** doctrine (mandatory contract first,
  advisory voice second):

```elixir
@spec build(String.t(), map(), String.t() | nil) :: String.t()
def build(template_name, tool_context, catalog_stage_name \\ nil)
    when is_binary(template_name) and is_map(tool_context) do
  project_dir = Map.get(tool_context, :project_dir) || File.cwd!()

  role_section(template_name) <>
    doctrine_section(template_name) <>
    persona_section(template_name, catalog_stage_name) <>
    PromptSections.blocks_section(blocks_for_context(tool_context)) <>
    PromptSections.jido_md_section(PromptSections.load_jido_md(project_dir))
end
```

- New private renderer + the persona gate (lives **here**, not at `Startup`). `Persona.render_for/2`
  already prepends its own dynamic `## PSYCHOLOGY: <Name>` header, so this only pads + gates:

```elixir
# Omit the `## PSYCHOLOGY` block when the persona layer is off or no persona resolves.
defp persona_section(template_name, catalog_stage_name) do
  if psychology_enabled?() do
    case Persona.render_for(catalog_stage_name, template_name) do
      "" -> ""
      text -> "\n" <> text <> "\n"
    end
  else
    ""
  end
end

defp psychology_enabled? do
  :jido_claw
  |> Application.get_env(:psychology, [])
  |> Keyword.get(:enabled?, @psychology_defaults[:enabled?])
end
```

### 4. `lib/jido_claw/startup.ex` — thread the stage + add it to telemetry

Add a trailing `catalog_stage_name \\ nil` arg (a **prompt-assembly input** — belongs here, not in
the canonical `tool_context`, which `ToolContext.build/1` would strip). The `doctrine_enabled?()`
master gate is unchanged. **Add `stage:` to the telemetry metadata** (the seam-test hook):

```elixir
@spec inject_subagent_prompt(pid(), String.t(), map(), String.t() | nil) :: :ok
def inject_subagent_prompt(pid, template_name, tool_context, catalog_stage_name \\ nil)
    when is_pid(pid) and is_binary(template_name) do
  if doctrine_enabled?() do
    project_dir = Map.get(tool_context, :project_dir) || File.cwd!()
    prompt = SubagentPrompt.build(template_name, tool_context, catalog_stage_name)

    meta = %{template: template_name, stage: catalog_stage_name}
    case do_inject(pid, prompt, project_dir, :doctrine, meta) do
      # ... :ok / {:error, reason} warning branch unchanged ...
```

`do_inject/5` already merges `extra_metadata` into the `[:jido_claw, :agent, :prompt_injected]`
event (`:188`) — so `stage:` rides through with no further change. `source: :doctrine` stays (it is
the injection-channel label, not the section).

### 5. `lib/jido_claw/route_composer/wave_builder.ex` — emit the dedicated option

`add_stage_step/3` (`:146-160`) adds `catalog_stage_name: stage.name` to the `AgentStep` options
(distinct from `step_name`, which stays the `StepResult.name` label):

```elixir
options = [
  template: template,
  task: stage.task,
  step_name: stage.name,
  catalog_stage_name: stage.name,
  context_format: :deps,
  upstream: [],
  consumes: []
]
```

Only `WaveBuilder` sets it. The skill compiler (`skills/compiler.ex`) builds `AgentStep`s with no
`catalog_stage_name` → `nil` → template fallback. (Composer stage steps use `max_retries: 0`, no
`:retry`/`:compensate`, so the saga cleanup path never reads it; the extra keyword key is inert there.)

### 6. `lib/jido_claw/skills/steps/agent_step.ex` + `agent_runner.ex` — pass it through

- `agent_step.ex:51-68` — read the option and forward it (the main run path only;
  `step_name` keeps its label role):
  ```elixir
  catalog_stage_name = Keyword.get(options, :catalog_stage_name)
  # ...
  AgentRunner.run(template, full_task, step_name, context, catalog_stage_name)
  ```
- `agent_runner.ex` — `run/4` → `run/5` with `catalog_stage_name \\ nil`; forward at `:79`:
  ```elixir
  @spec run(String.t(), String.t(), String.t() | nil, map(), String.t() | nil) ::
          {:ok, StepResult.t()} | {:error, binary()}
  def run(template_name, task, step_name, context, catalog_stage_name \\ nil) do
    # ... unchanged until line 79:
    _ = JidoClaw.Startup.inject_subagent_prompt(pid, template_name, tool_context, catalog_stage_name)
  ```

**Ripple (enumerated — both helpers use default args, so non-composer callers are untouched):**
- `AgentRunner.run` — 4 callers: `agent_step.ex:68` (composer + skill main path; now forwards the
  option, `nil` for skill steps), `agent_step.ex:130` (saga cleanup, 4-arg → `nil`),
  `iterative_step.ex:188` & `:225` (generator/evaluator, 4-arg → `nil` → template persona). ✓
- `inject_subagent_prompt` — 3 callers: `agent_runner.ex:79` (now 4-arg), `spawn_agent.ex:191` and
  `send_to_agent.ex:103` (**unchanged** 3-arg → `nil` → template fallback, the decided
  direct-spawn / follow-up behavior). ✓

### 7. Config — `config/config.exs` (after line 259) and `config/test.exs` (after line 25)

```elixir
# config/config.exs
# AR-6 persona block, gated WITHIN the (`:doctrine`-master-gated) sub-agent prompt. Toggling
# `:psychology` adds/removes ONLY the `## PSYCHOLOGY` section; it does NOT re-enable injection
# when `:doctrine` is off — `:doctrine` remains the master injection switch.
config :jido_claw, :psychology, enabled?: true
```

```elixir
# config/test.exs
# AR-6 personas off in test so existing spawn/skill prompt tests stay on today's behavior; the
# persona tests opt in via Application.put_env + on_exit (async: false), mirroring :doctrine.
config :jido_claw, :psychology, enabled?: false
```

---

## Persona roster (anchored on Alp River's `agent-map.json`)

**`@stage_persona`** — all 13 worker-bearing catalog stages (`triage`, `plan-gate`, `safety-gate`
are non-workers and never reach the seam):

| Stage (template) | Persona | Rationale |
| --- | --- | --- |
| `planner` (researcher) | **detective** | Investigator role (Alp River `*-investigator → detective`); reasons from evidence to a plan. |
| `test-author` (coder) | **skeptic** | "Distrust green tests" — the test-author voice. |
| `implementer` (coder) | **craftsperson** | Builder values durable quality; its reviewers supply orthogonal challenge. |
| `security-reviewer` (reviewer) | **defender** | Threat-model first — Alp River's headline `defender → security-reviewer`. |
| `quality-reviewer` (reviewer) | **craftsperson** | Style / clarity / duplication; quote precedents. |
| `correctness-reviewer` (reviewer) | **skeptic** | Falsification-first; probe edge cases. |
| `architecture-reviewer` (reviewer) | **pragmatist** | Counterweight to gold-plating: impact over elegance. |
| `fixer` (fixer) | **cynic** | `cynic → fixer` (Alp River); "what can be deleted". |
| `sketch-build` (sketch_build) | **optimist** | `optimist → *-prototyper`; ship a tracer fast. |
| `sketch-build-exec` (sketch_build_exec) | **optimist** | Same prototyper ethos, executed. |
| `sketch-review` (sketch_reviewer) | **skeptic** | Correctness-lens judge — consistent with correctness-reviewer. |
| `system-executor` (system_executor) | **teacher** | "Report what changed" = make the rationale legible. |
| `system-verifier` (system_verifier) | **detective** | Idempotent re-check / state assertion = chase the evidence. |

**`@template_persona`** — all 13 templates (fallback for direct spawn / follow-up; the **bare
`reviewer`** default is `skeptic`, overridden per-lens by the four stages above). Stage-shared
templates mirror their stage; spawn-only templates: `test_runner → skeptic`,
`docs_writer → teacher` (`teacher → capture/adr` in Alp River), `refactorer → cynic`,
`verifier → skeptic`.

**Persona coverage:** 8 of 9 are selected. **`user-advocate` is intentionally unused** — Alp River
anchors it to `design/ux-prototyper`, which has no analog in this backend catalog. It still ships,
loads, and `render/1`s (the drift test renders all 9), just isn't selected by `resolve/2` in v1.

---

## Precommit — the riskiest gate and how it stays green

Verified config: `.credo.exs:22` runs `{ExDNA.Credo, [excluded_macros: [:relationships]]}` (clone
defaults `min_mass: 30`, exact-match only); `Credo.Check.Design.DuplicatedCode` is disabled
(`.credo.exs:141`). `jidoclaw.system_prompt.check` inspects only `priv/defaults/system_prompt.md`'s
**tool** catalog (`system_prompt.check.ex:10,14`) — the new persona dir cannot trip it. The
`precommit` chain (`mix.exs:251-260`): compile_check → system_prompt.check → deps.unlock → format →
`reach.check --arch --smells --strict` → `credo --strict` → dialyzer → test.

**Riskiest gate: `credo --strict` → `ExDNA.Credo` clone check** (a committed memory flags near-twin
sibling modules). Mitigation is structural, not a pragma:

- Personas load via the **comprehension** over `@persona_names` + one `Path.join` helper — *not*
  Doctrine's 7 named `@xxx_priv` attributes. Removes the only contiguous block near `min_mass: 30`.
- Accessors are AST-mass ≤ ~13 each; a 4-form window sums < 30, so none is fingerprinted.
- `resolve/2`, `render/1`, `render_for/2`, `render_block/2`, `persona_section/2` have **no Doctrine
  twin** — unique by construction. Centralizing the conflict rule *reduces* duplication surface.

Other gates:
- **`format`**: one-pipe-per-line in `display/1` + `psychology_enabled?/0`; `render_block/2` uses a
  multi-line `<>` chain; all ≤120 cols.
- **`reach --smells --strict`**: `missing_external_resource` dormant (non-literal `Path.join` read,
  like Doctrine's passing `File.read!(@base_priv)`); `trivial_delegate` clean (public composing
  `def`s / multi-clause `defp`); `clone_consistency` clean (twins are contract-consistent).
  **Residual to watch: `behaviour_candidate`** on the `Persona`/`Doctrine` `template_names/0`
  similarity — if it fires, scope both in `.reach.exs`'s existing
  `behaviour_candidate: [ignore: [modules: [...]]]` list (`.reach.exs:114-136`, documented precedent).
- **`credo`** also: `PathExpandPriv` clean (`Path.join`), `UnsafeToAtom` clean (string identity),
  `Specs`/`ModuleDoc`/`NarratorDoc` satisfied.
- **`dialyzer`**: `@spec` on every public fn; updated specs on `AgentRunner.run/5`,
  `inject_subagent_prompt/4` (`... String.t() | nil) :: :ok`), and `build/3`.

---

## Tests

**New `test/jido_claw/persona_test.exs`** (pure, `async: true`; mirrors `doctrine_test.exs`):

- `render/1`: every `Persona.names()` renders `## PSYCHOLOGY:`, `## Belief`, and a `## Conflict
  rule` block; assert **`String.ends_with?(render(name), @expected_rule)`** for all 9, where
  `@expected_rule` is the conflict-rule literal **hardcoded in the test** (not a reference to
  `Persona`'s private `@conflict_rule`) — so the test proves the rendered public contract and
  catches drift in the module attribute itself; display rule
  (`"user-advocate"` → `"## PSYCHOLOGY: User advocate"`, `"cynic"` → `"Cynic"`); unknown → `""`.
- `resolve/2`: the four reviewer stages over `"reviewer"` resolve to **distinct** personas
  (`defender`/`skeptic`/`craftsperson`/`pragmatist`); `nil` stage → template persona; an **unmapped
  stage name → template persona** (the finding-#1 guarantee: a skill step named like a stage does
  not inherit the stage persona); neither mapped → `""`.
- **Drift guard** (load-bearing): every `stage_names()` is a real catalog stage
  (`RouteComposer.Catalog.valid?/1`); `Enum.sort(template_names()) == Enum.sort(Templates.names())`,
  `refute "main" in template_names()`, `Enum.all?(template_names(), &Templates.exists?/1)`; every
  stage key and template key renders non-empty via `render_for/2`.

**Extend `test/jido_claw/agent/subagent_prompt_test.exs`** (already `async: false` via `TenantCase`):
snapshot/restore `:psychology` in `setup` (`on_exit`), then a `build/3` describe flipping it **on**:
a stage-keyed reviewer (`build("reviewer", %{project_dir: dir}, "security-reviewer")`) renders
`## PSYCHOLOGY: Defender` **and** still carries `## DOCTRINE`; a template-only spawn
(`build("reviewer", %{project_dir: dir})`) renders `## PSYCHOLOGY: Skeptic`; flag **off** → no
`## PSYCHOLOGY`, doctrine unaffected.

**Extend `test/jido_claw/startup_subagent_prompt_test.exs`** (the seam proof for inject/4): also
snapshot/restore `:psychology`; with both flags on and the real Coder (`start_worker/0`), the
**4-arg** call `inject_subagent_prompt(pid, "reviewer", ctx, "security-reviewer")` fires telemetry
with `metadata.stage == "security-reviewer"`; the **3-arg** call yields `metadata.stage == nil`.
(Proves the stage flows inject/4 → build/3 → telemetry.)

**New `test/jido_claw/route_composer/wave_builder_*` assertion** (catalog → step option): build a
wave containing a reviewer stage and assert the built `AgentStep`'s options carry
`catalog_stage_name: "security-reviewer"` (distinct from `step_name`). (Proves `WaveBuilder` emits
the dedicated option; co-locate with the existing wave-builder test, or add one.)

**Composer seam + the regression guard (`agent_step_test.exs`)** — mirror the **existing**
real-worker telemetry pattern at `agent_runner_test.exs:476-509` (attach a `[:jido_claw, :agent,
:prompt_injected]` handler; bare `%{}` context → no DB writes; a real template worker so the pid
actually handles the `set_system_prompt` ReAct signal; `Task.start` the run and `assert_receive`
the **early** event — it fires before the LLM turn — then stop the worker via `metadata.pid`).
**Do not use `EchoStub`** — it overrides only `ask_sync/3` (`echo_stub.ex:24-30`) and is a plain
`Jido.Agent`, so it never emits the injection telemetry. Two cases, driving `AgentStep.run/3` with
wave-builder-shaped options (`template: "reviewer"`, `task`, `arguments: %{extra_context: ""}`):
  - **positive**: options include `catalog_stage_name: "security-reviewer"` → `metadata.stage ==
    "security-reviewer"` (and the worker's prompt carries `## PSYCHOLOGY: Defender`).
  - **negative (the bug guard)**: options set `step_name: "security-reviewer"` but **omit**
    `catalog_stage_name` → `metadata.stage == nil`. This is the direct regression test for finding
    #1: an arbitrary skill/step label that collides with a catalog stage name must **not** inherit
    the stage persona — it falls through to the template persona.

**Existing tests need no edits** — `:psychology` is off by default in `test.exs`, so `persona_section`
returns `""`; no existing test asserts persona presence/absence. The existing
`startup_subagent_prompt_test` flag-ON case calls the 3-arg form → metadata gains `stage: nil`
(it asserts `metadata.template`, not stage → still green). `agent_runner`/`agent_step`/`iterative_step`
tests run with both flags off → no injection text change; the new `run/5` / `AgentStep` option are
default-`nil` → byte-identical behavior.

---

## Verification (end-to-end)

1. **`mix precommit`** — the completion bar. Must be green (compile-no-warnings, system-prompt
   check, format, `reach --arch --smells --strict`, `credo --strict`, dialyzer, full suite).
2. Targeted while iterating:
   `mix test test/jido_claw/persona_test.exs test/jido_claw/agent/subagent_prompt_test.exs test/jido_claw/startup_subagent_prompt_test.exs test/jido_claw/skills/steps/agent_step_test.exs`.
3. If `credo --strict` flags ExDNA, reorder structurally (no pragma); if `reach` flags
   `behaviour_candidate`, add both modules to the existing `.reach.exs` ignore list.
4. **Manual smoke (Tidewave `project_eval`)** — per-stage divergence over one template + fallback:
   ```elixir
   Application.put_env(:jido_claw, :psychology, enabled?: true)
   d = System.tmp_dir!()
   sec  = JidoClaw.Agent.SubagentPrompt.build("reviewer", %{project_dir: d}, "security-reviewer")
   corr = JidoClaw.Agent.SubagentPrompt.build("reviewer", %{project_dir: d}, "correctness-reviewer")
   bare = JidoClaw.Agent.SubagentPrompt.build("reviewer", %{project_dir: d})
   {sec =~ "PSYCHOLOGY: Defender", corr =~ "PSYCHOLOGY: Skeptic", bare =~ "PSYCHOLOGY: Skeptic",
    sec =~ "the role and the codebase win"}   # full prompt CONTAINS the rule (Memory/JIDO follow)
   # => {true, true, true, true}
   ```

## Files

- **New**: `lib/jido_claw/persona.ex`; `priv/defaults/persona/{craftsperson,cynic,defender,detective,optimist,pragmatist,skeptic,teacher,user-advocate}.md`; `test/jido_claw/persona_test.exs`
- **Edit (lib)**: `lib/jido_claw/agent/subagent_prompt.ex` (build/3 + gated `persona_section/2`);
  `lib/jido_claw/startup.ex` (`inject_subagent_prompt/4` + `stage:` telemetry);
  `lib/jido_claw/route_composer/wave_builder.ex` (`catalog_stage_name` option);
  `lib/jido_claw/skills/steps/agent_step.ex` (read + forward the option);
  `lib/jido_claw/skills/steps/agent_runner.ex` (`run/5`); `config/config.exs`; `config/test.exs`
- **Edit (test)**: `test/jido_claw/agent/subagent_prompt_test.exs`;
  `test/jido_claw/startup_subagent_prompt_test.exs`;
  `test/jido_claw/skills/steps/agent_step_test.exs`; a wave-builder option assertion
