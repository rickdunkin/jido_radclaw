# AR-8c review fix — gate swarm-tool privacy on the *resolved* template

## Context

The AR-8c code review surfaced one finding (P2):

> The swarm tools can bypass composer-private policy when `:agent_templates` is overridden.
> `spawn_agent.ex` and `send_to_agent.ex` check privacy with `Templates.composer_private?/1`
> (hardcoded to the canonical registry) but launch the template resolved through the
> configurable `templates()` provider. If `:agent_templates` points at a provider returning
> `sandbox: :prototype`/`:docker` or `composer_private: true`, the guard checks a different
> source than the one it launches, so a private template slips through.

**Validated — the finding is real.** Two distinct override seams exist:

- `:agent_templates` — a provider **module**, read by each tool's `templates()` helper
  (`spawn_agent.ex:354`, `send_to_agent.ex:236`), used for the actual launch.
- `:agent_templates_override` — a **map**, consulted *inside* `JidoClaw.Agent.Templates.get/1`,
  which is what `composer_private?/1` resolves through.

The guard (`Templates.composer_private?/1`) always hits `JidoClaw.Agent.Templates`; the launch
(`templates().get/1`) hits whatever module `:agent_templates` names. When that module is **not**
`JidoClaw.Agent.Templates`, the two diverge: the guard reads the canonical registry, the tool
launches from the provider. A provider that resolves a canonically-public name (e.g. `"coder"`)
to a `composer_private: true` / sandboxed template passes the guard (canonical `"coder"` is
public) yet launches the private worker — exactly the safety-gate bypass AR-8c's privacy hardening
exists to prevent.

**Scope is exactly the two swarm tools.** The other four privacy surfaces resolve *and* check
through the same canonical `JidoClaw.Agent.Templates` (no `templates()` provider seam):
`handoff.ex:91/236`, `router.ex:294-295` and `:359-366`, `worker.ex:433/439`. They cannot diverge;
they need no change. The reviewer's "no other correctness issues" is correct.

**Threat-model framing (honest severity).** `:agent_templates` is operator config, not
LLM-reachable, so a misbehaving LLM cannot trigger this on its own — it's a latent correctness
defect / defense-in-depth gap, not a live exploit. But it makes the privacy guard *decorative*
under provider override (the guard and launch must agree to mean anything), and the fix is cheap
and local. Worth doing.

**Done = `mix precommit` passes.**

## The fix — gate on the resolved template, single source of "private"

Resolve the template through the **same provider** that launches it, then gate on that **resolved
map** — never re-resolve the name against the canonical registry. This makes divergence
structurally impossible (the guard and the launch read the identical object) without expanding the
provider contract (providers still only need `get/1`).

### 1. `lib/jido_claw/agent/templates.ex` — extract a map-based predicate

Add `composer_private_template?/1` as the single definition of "what makes a template private",
operating on an already-resolved map, and have the existing name-based `composer_private?/1`
delegate to it (keeps DRY; zero behavior change for the canonical callers):

```elixir
@spec composer_private?(String.t()) :: boolean()
def composer_private?(name) do
  case get(name) do
    {:ok, template} -> composer_private_template?(template)
    _ -> false
  end
end

@doc """
True when an **already-resolved** template map is composer-private — sandboxed
(`:sandbox in [:prototype, :docker]`) or carrying the explicit `:composer_private`
flag. The map-shaped companion to `composer_private?/1`, for the reachability
surfaces that resolve a template through a configurable provider (`spawn_agent` /
`send_to_agent`'s `:agent_templates` seam): they must gate on the *resolved* map,
not re-resolve the name against the canonical registry, or an overridden provider
could launch a private template the name-based guard never saw. Reads keys
defensively so an un-hydrated provider map defaults to public.
"""
@spec composer_private_template?(map()) :: boolean()
def composer_private_template?(template) when is_map(template) do
  Map.get(template, :sandbox, :none) in [:prototype, :docker] or
    Map.get(template, :composer_private, false) == true
end
```

`Map.get/3` defaults (not the dot-access the current `composer_private?/1` uses) matter: a custom
provider may return an un-hydrated map with no `:sandbox`/`:composer_private` keys → safely
`false`. **Intentionally atom-shaped only** — `:sandbox`/`:composer_private` atom keys and
`:prototype`/`:docker` atom values match today's provider contract (`@templates` + every test
stub); do **not** add string-key/string-value coercion. The provider contract is atom-keyed maps;
broadening the predicate to accept `"prototype"` etc. would silently widen what counts as a valid
provider map with no caller that needs it. `external_tools?/1` keeps delegating to the name-based
`composer_private?/1` (the MCP Consumer calls it by name) — unchanged. Update the
`## composer_private policy` moduledoc so it names both: `composer_private?/1` for name-based
canonical surfaces, `composer_private_template?/1` for provider-seam surfaces.

### 2. `lib/jido_claw/tools/spawn_agent.ex` — resolve, then gate on the resolved map

Move the `templates().get/1` call up into `spawn_from_template/5`, gate on
`composer_private_template?/1` against the resolved template, and pass the resolved `template` into
`do_spawn_from_template/6` (drop its now-redundant re-resolve):

```elixir
defp spawn_from_template(template_name, task, tag, context, scope_opts) do
  case templates().get(template_name) do
    {:ok, template} ->
      if Templates.composer_private_template?(template) do
        {:error, composer_private_error(template_name)}
      else
        do_spawn_from_template(template, template_name, task, tag, context, scope_opts)
      end

    {:error, reason} ->
      {:error, reason}
  end
end

defp do_spawn_from_template(template, template_name, task, tag, context, scope_opts) do
  case jido_runtime().start_subagent(template.module, id: tag) do
    {:ok, subagent_pid} ->
      register_spawned_agent(subagent_pid, template, template_name, task, tag, context, scope_opts)
    {:error, reason} ->
      {:error, Error.execution_error("Failed to spawn agent.", phase: :spawn,
        details: %{reason: inspect(reason), template: template_name})}
  end
end
```

Behavior is identical for every existing case (known public → spawn; known private / unknown →
same error). Only the divergent-provider case flips from leak → refused. Update the comment at
`spawn_agent.ex:56-61` to describe gating on the resolved template.

### 3. `lib/jido_claw/tools/send_to_agent.ex` — same shape

Rework `template_for_agent/2` to resolve first (via the existing `resolve_template/2`, which already
uses `templates().get/1`), then gate on the resolved map:

```elixir
defp template_for_agent(agent_id, entry) do
  case entry do
    %{template: template_name} when is_binary(template_name) ->
      with {:ok, template} <- resolve_template(agent_id, template_name) do
        if Templates.composer_private_template?(template) do
          {:error, composer_private_error(template_name)}
        else
          {:ok, template}
        end
      end

    other ->
      {:error, Error.execution_error("Agent '#{agent_id}' has invalid tracker metadata.",
        phase: :tracker_lookup, details: %{agent_id: agent_id, metadata: inspect(other)})}
  end
end
```

`resolve_template/2` is unchanged. For every existing private test the entry's template is
resolvable (real or `:agent_templates_override`), so resolution succeeds then the privacy error
fires — same final `{:error, %{details: %{reason: :composer_private}}}`. Update the comment at
`send_to_agent.ex:172-175`.

## Tests

- **`test/jido_claw/tools/spawn_agent_test.exs`** — add a `DivergentTemplates` stub whose
  `get("coder")` returns `%{module: FakeWorker, composer_private: true}`, set `:agent_templates`
  to it (with `FakeRuntime` + `spawn_agent_test_pid`), and assert `SpawnAgent.run(%{template:
  "coder", ...})` returns `details.reason == :composer_private` and `child_count == 0`. This test
  **fails before the fix** (canonical `"coder"` is public → the tool calls
  `FakeRuntime.start_subagent`, which `spawn`s a `Process.sleep(:infinity)` pid). To prove the
  pre-fix failure **without leaking that sleeping process**, do not use bare `refute_receive` —
  instead receive-and-kill so the pre-fix run cleans up the pid it just proved was wrongly
  spawned:

  ```elixir
  receive do
    {:start_agent, _opts, pid} ->
      Process.exit(pid, :kill)
      flunk("composer-private template was spawned despite the resolved-map guard")
  after
    200 -> :ok
  end
  ```

  Post-fix the guard fires before `start_subagent`, so nothing arrives and the `after` clause
  passes cleanly (model the rest on the existing AR-8c refusal test at `:211`).
- **`test/jido_claw/tools/send_to_agent_test.exs`** — add a `DivergentTemplates` stub whose
  `get("docs_writer")` returns `%{module: FakeWorker, composer_private: true}`, set
  `:agent_templates` to it, and assert the follow-up to `docs_writer_123` (default `FakeTracker`
  maps it to `%{template: "docs_writer"}`) returns `details.reason == :composer_private` with no
  `:ask_sync` (model on the existing AR-8c refusal test at `:297`).
- **`test/jido_claw/templates_test.exs`** — unit-test `composer_private_template?/1` directly:
  `%{sandbox: :prototype}` / `%{sandbox: :docker}` / `%{composer_private: true}` → `true`;
  `%{sandbox: :none}` / `%{}` (un-hydrated) / `%{module: _, description: _}` → `false`. Add it to
  the existing `composer_private?/1` describe block.
- All existing `composer_private?` tests stay green (delegation is behavior-preserving); all
  existing swarm-tool tests stay green (no behavior change for non-divergent providers).

## Critical files

| File | Change |
| --- | --- |
| `lib/jido_claw/agent/templates.ex` | Add `composer_private_template?/1`; `composer_private?/1` delegates to it; moduledoc names both |
| `lib/jido_claw/tools/spawn_agent.ex` | Resolve via `templates().get/1` first; gate on `composer_private_template?/1`; thread resolved `template` into `do_spawn_from_template/6` |
| `lib/jido_claw/tools/send_to_agent.ex` | `template_for_agent/2`: resolve first, gate on `composer_private_template?/1` |
| `test/jido_claw/tools/spawn_agent_test.exs` | `DivergentTemplates` stub + divergence-refusal test |
| `test/jido_claw/tools/send_to_agent_test.exs` | `DivergentTemplates` stub + divergence-refusal test |
| `test/jido_claw/templates_test.exs` | `composer_private_template?/1` unit tests |

**Reused (do not reinvent):** `templates()` provider seam and `resolve_template/2` (already in the
tools); `composer_private_error/1` (already in both tools); `composer_private?/1` delegation target;
`FakeWorker` / `FakeRuntime` / `FakeTracker` test stubs.

**No change** to `handoff.ex`, `router.ex`, `worker.ex` — they resolve and check through the same
canonical `JidoClaw.Agent.Templates`, so they cannot diverge.

## `mix precommit` watch-items (from prior new-code gotchas)

- `composer_private_template?/1` is public → needs `@spec` + `@doc` (credo-strict). Predicate name
  ends in `?`, doesn't start with `is` ✓.
- ExSlop step-comment trap — no comment line may start with the word "step".
- ExDNA cross-file duplicate-clone gate — the resolve-then-gate block appears in both tools but is
  not byte-identical (different surrounding code/function names); if it ever trips, split or pragma
  per existing precedent rather than collapsing the two tools' distinct error shapes.
- `compile_check` runs a clean recompile with an empty warning allowlist — keep warning-free.

## Verification

1. `mix format` then `mix compile --warnings-as-errors`.
2. Targeted: `mix test test/jido_claw/tools/spawn_agent_test.exs test/jido_claw/tools/send_to_agent_test.exs test/jido_claw/templates_test.exs`.
3. Confirm the two new divergence tests **fail on the pre-fix tree** (guard reads canonical) and
   pass after — proves the test actually guards the bug.
4. Re-run the AR-8c loop test to confirm no regression:
   `mix test test/jido_claw/route_composer/composer_system_loop_test.exs`.
5. **Completion gate: `mix precommit` must pass.** (Run bare in the background and read the output
   tail — never pipe through `tail`, which masks the exit code.)

## Out of scope

- The provider-aware-predicate alternative (`templates().composer_private?(name)`) — rejected: it
  expands the provider contract so every stub module (`FakeTemplates`, `BlockingTemplates`,
  `RestrictedTemplates`, …) must implement `composer_private?/1` or crash. Gating on the resolved
  map needs only `get/1`, which every provider already has.
- A per-tool (vs per-template) MCP approval overlay and any other AR-8c deferrals — untouched.
