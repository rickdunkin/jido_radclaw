# Resolve Code Review Findings: Step Normalizer Atom Loading & Map Collision Precedence

## Context

The recently-shipped credo cleanup (plan: `.claude/plans/we-ve-just-recently-added-floofy-feigenbaum.md`) eliminated 80 dual-key warnings but introduced two regressions caught in code review. Both are real correctness defects that must be fixed before the working-tree changes are committed.

**P1 — `StepNormalizer` depends on incidental atom loading.** `lib/jido_claw/workflows/step_normalizer.ex:40` uses `MapKeys.normalize_keys(step, :atom_existing)`. In a fresh BEAM after loading only `JidoClaw.Skills`, step-key atoms like `:task`, `:role`, `:template`, `:produces`, `:consumes` may not yet be interned — they're only interned when their referencing workflow modules load. `safe_existing_atom/1` then falls back to keeping the string, and downstream atom-only readers (e.g. `skill_workflow.ex:112-114`, `plan_workflow.ex:92-94`) return `nil` for those fields. Loaded skills can silently end up with `task == nil` and fail at runtime. The new `StepNormalizer` test only locks `:name`, `:role`, `:depends_on` — it would not have caught this.

**P2 — Top-level normalization changes mixed-key precedence.** `lib/jido_claw/core/map_keys.ex:127-137` `do_normalize_map/4` silently collides atom/string duplicate keys via `Map.put`. The surviving value depends on `Enum.reduce/3` iteration order (insertion order for small maps, hash order beyond) — in practice string-keyed entries written second tend to win. `Trust.normalize/1` (`trust.ex:189-191`) and `Memory.do_remember/3` (`memory.ex:218`) call this, but the pre-refactor code at these sites was atom-first via `Map.get(map, :k) || Map.get(map, "k")`. Example: `Trust.verification_score(%{verification: %{status: "failed"}, "verification" => %{"status" => "passed"}})` now scores as passed.

## Decisions (per user)

1. **Unknown step keys**: drop silently (allowlist becomes the canonical step shape).
2. **P2 fix**: add deterministic atom-first precedence to `MapKeys.normalize_keys/3` rather than reverting Trust/Memory to read-site `coalesce_field/3`. Symmetric for `:string` mode (string-first wins).

## Approach

1. Replace `StepNormalizer.normalize_step/1` with an in-module literal allowlist that maps the 7 canonical keys. This interns the atoms at compile time independently of which workflow modules have loaded.
2. Make `MapKeys.do_normalize_map/4` deterministic by partitioning the input by source-key type and ordering the reduce so the winning shape overwrites the losing shape (`:atom_existing` → atoms win; `:string` → strings win).
3. Add regression tests that lock both behaviors. The new `StepNormalizer` test must verify the fix works without relying on workflow modules being loaded.
4. Update moduledocs in `StepNormalizer` and `MapKeys.normalize_keys` to document the new contracts.

## Step 1 — `StepNormalizer` allowlist (P1)

**File:** `lib/jido_claw/workflows/step_normalizer.ex`

Replace the `normalize_step/1` body. Use an in-module `@canonical_keys` literal so all 7 atoms are interned at compile time of `StepNormalizer` itself — no dependency on workflow modules.

```elixir
@canonical_keys %{
  "name" => :name,
  "template" => :template,
  "task" => :task,
  "role" => :role,
  "depends_on" => :depends_on,
  "produces" => :produces,
  "consumes" => :consumes
}

@canonical_atoms Map.values(@canonical_keys)

defp normalize_step(step) when is_map(step) and not is_struct(step) do
  Enum.reduce(step, %{}, fn
    {k, v}, acc when is_atom(k) ->
      if k in @canonical_atoms, do: Map.put(acc, k, v), else: acc

    {k, v}, acc when is_binary(k) ->
      case Map.fetch(@canonical_keys, k) do
        {:ok, atom_key} -> Map.put(acc, atom_key, v)
        :error -> acc
      end

    _, acc ->
      acc
  end)
end

defp normalize_step(other), do: other
```

Update the moduledoc to list the canonical 7 keys, state that unknown keys are dropped, and remove the "no validation" sentence (the allowlist *is* shape policing).

## Step 2 — Atom-first precedence in `MapKeys.normalize_keys` (P2)

**File:** `lib/jido_claw/core/map_keys.ex`

Modify `do_normalize_map/4` (lines 127-137) to be deterministic on collisions. For `:atom_existing`, process string keys first so converted-to-atom values are overwritten when the genuine atom-keyed entry is processed. For `:string`, process atom keys first so genuine string-keyed entries win. The `Enum.split_with/2` partitions by source-key shape; concatenating in the right order lets `Enum.reduce/3` + `Map.put/3` enforce precedence regardless of original iteration order.

```elixir
defp do_normalize_map(map, mode, deep?, drop_unknown?) do
  map
  |> ordered_entries(mode)
  |> Enum.reduce(%{}, fn {k, v}, acc ->
    case convert_key(k, mode, drop_unknown?) do
      {:ok, new_key} ->
        Map.put(acc, new_key, maybe_walk(v, mode, deep?, drop_unknown?))

      :drop ->
        acc
    end
  end)
end

# :atom_existing — process strings first so genuine atom entries
#   overwrite their string counterparts (atom-first precedence).
# :string — process atoms first so genuine string entries overwrite
#   their atom counterparts (string-first precedence).
defp ordered_entries(map, :atom_existing) do
  {atoms, others} = Enum.split_with(map, fn {k, _} -> is_atom(k) end)
  others ++ atoms
end

defp ordered_entries(map, :string) do
  {atoms, others} = Enum.split_with(map, fn {k, _} -> is_atom(k) end)
  atoms ++ others
end
```

Update the moduledoc on `normalize_keys/3` to document the precedence contract:

> When the input map contains both `:key` and `"key"` for the same name, the canonical shape for the chosen mode wins: `:atom_existing` keeps the atom-keyed value; `:string` keeps the string-keyed value. Precedence is deterministic and applies recursively when `:deep` is true.

Because `:deep` recurses through `maybe_walk/4` → `do_normalize_map/4`, the precedence applies at every level automatically.

## Step 3 — Tests

### `test/jido_claw/workflows/step_normalizer_test.exs`

Add three tests; remove the now-misleading `ensure_atoms!/1` helper and `@keys` list.

```elixir
test "normalizes the full canonical step-key set" do
  steps = [
    %{
      "name" => "s",
      "task" => "t",
      "role" => "r",
      "template" => "tmpl",
      "depends_on" => ["a"],
      "produces" => %{x: 1},
      "consumes" => ["b"]
    }
  ]

  [out] = StepNormalizer.normalize(steps)

  assert Enum.sort(Map.keys(out)) ==
           [:consumes, :depends_on, :name, :produces, :role, :task, :template]

  # Lock values too — Map.keys/1 alone only proves the key shape survived,
  # not that values landed under the right atoms.
  assert out.name == "s"
  assert out.task == "t"
  assert out.role == "r"
  assert out.template == "tmpl"
  assert out.depends_on == ["a"]
  assert out.produces == %{x: 1}
  assert out.consumes == ["b"]
end

test "drops unknown string keys" do
  assert StepNormalizer.normalize([%{"name" => "ok", "bogus_field_xyz" => 1}]) ==
           [%{name: "ok"}]
end

test "drops unknown atom keys" do
  assert StepNormalizer.normalize([%{name: "ok", :__unused__ => 1}]) ==
           [%{name: "ok"}]
end
```

The first test must NOT call `ensure_atoms!/1` — the @canonical_keys literal in `StepNormalizer` is the only thing required to intern the step atoms at compile time. That is the contract we are locking.

### `test/jido_claw/core/map_keys_test.exs`

Add a new `describe "normalize_keys collision precedence"` block:

```elixir
describe "normalize_keys collision precedence" do
  test ":atom_existing — atom key wins on collision" do
    :collision_existing_atom_a

    out =
      MapKeys.normalize_keys(
        %{collision_existing_atom_a: 1, "collision_existing_atom_a" => 2},
        :atom_existing
      )

    assert out == %{collision_existing_atom_a: 1}
  end

  test ":atom_existing — precedence is deterministic across insertion orders" do
    :collision_existing_atom_b

    # String written first, atom second
    m1 = %{} |> Map.put("collision_existing_atom_b", 99) |> Map.put(:collision_existing_atom_b, 1)
    # Atom written first, string second
    m2 = %{} |> Map.put(:collision_existing_atom_b, 1) |> Map.put("collision_existing_atom_b", 99)

    assert MapKeys.normalize_keys(m1, :atom_existing) == %{collision_existing_atom_b: 1}
    assert MapKeys.normalize_keys(m2, :atom_existing) == %{collision_existing_atom_b: 1}
  end

  test ":string — string key wins on collision" do
    assert MapKeys.normalize_keys(%{foo: 1, "foo" => 2}, :string) == %{"foo" => 2}
  end

  test ":deep — atom-first precedence applies recursively" do
    :collision_nested_atom

    input = %{
      outer: %{collision_nested_atom: 1, "collision_nested_atom" => 2}
    }

    assert MapKeys.normalize_keys(input, :atom_existing, deep: true) ==
             %{outer: %{collision_nested_atom: 1}}
  end
end
```

### `test/jido_claw/memory/fact_test.exs`

Add a `describe "mixed-key attrs precedence"` block. The existing setup (`use JidoClaw.TenantCase, async: false` + `seed_tenant/1` + `Resolver.ensure_workspace/3`) is already in place, so this is a small additional test, not a new test module.

```elixir
describe "mixed-key attrs precedence" do
  test "atom keys win over string keys", %{
    tenant_id: tenant_id,
    tool_context: tc
  } do
    attrs = %{
      :key => "atom_label",
      "key" => "string_label",
      :content => "atom_content",
      "content" => "string_content",
      :type => "fact"
    }

    :ok = Memory.remember_from_user(attrs, tc)

    [fact] = Ash.read!(Fact, tenant: tenant_id, actor: actor_for(tenant_id))
    assert fact.label == "atom_label"
    assert fact.content == "atom_content"
  end
end
```

This locks the fix at the actual production boundary (`do_remember/3` via the public `remember_from_user/2`), not just at the `MapKeys.normalize_keys/3` unit-test layer.

### `test/jido_claw/solutions/trust_test.exs`

Add a new `describe "mixed-key precedence"` block. The atoms `:verification`, `:framework`, `:updated_at`, `:inserted_at`, `:tags`, `:sharing`, `:agent_id` are all interned when `Trust` loads (they appear as map-access literals in `trust.ex`).

```elixir
describe "mixed-key precedence" do
  test "atom verification wins over string verification" do
    solution = %{
      verification: %{status: "failed"},
      "verification" => %{"status" => "passed"}
    }

    assert Trust.verification_score(solution) == 0.0
  end

  test "atom framework wins over string framework in completeness" do
    solution = %{
      framework: "elixir",
      "framework" => "",
      verification: %{status: "passed"}
    }

    # Base 0.3 + framework 0.10 + verification 0.15 = 0.55
    assert_in_delta Trust.completeness_score(solution), 0.55, 1.0e-6
  end

  test "atom updated_at wins over string updated_at in freshness" do
    now = DateTime.utc_now()
    recent = now |> DateTime.add(-3 * 86_400, :second) |> DateTime.to_iso8601()
    old = now |> DateTime.add(-400 * 86_400, :second) |> DateTime.to_iso8601()

    solution = %{updated_at: recent, "updated_at" => old}

    assert Trust.freshness_score(solution, now) == 1.0
  end
end
```

## Step 4 — Moduledoc updates

- `StepNormalizer.@moduledoc` — list the canonical 7 keys; state unknown keys are dropped; remove "No validation".
- `MapKeys.normalize_keys/3 @doc` — add the precedence paragraph quoted in Step 2.

## Critical files modified

**lib/:**
- `lib/jido_claw/workflows/step_normalizer.ex` — allowlist + drop-unknown + moduledoc
- `lib/jido_claw/core/map_keys.ex` — `do_normalize_map/4` + `ordered_entries/2` + `@doc` precedence note

**test/:**
- `test/jido_claw/workflows/step_normalizer_test.exs` — canonical-set (with value assertions) + drop-unknown tests; remove `ensure_atoms!/1`
- `test/jido_claw/core/map_keys_test.exs` — collision precedence describe block
- `test/jido_claw/memory/fact_test.exs` — mixed-key attrs precedence describe block
- `test/jido_claw/solutions/trust_test.exs` — mixed-key precedence describe block

No changes to `lib/jido_claw/solutions/trust.ex` or `lib/jido_claw/memory.ex` — atom-first precedence in `normalize_keys` is the fix; the existing `normalize/1` call in Trust and `normalize_keys` call in Memory now behave correctly.

## Verification

1. **Step normalizer locks the canonical set without preinterning:**
   `mix test test/jido_claw/workflows/step_normalizer_test.exs` — the new full-canonical-set test must pass without `ensure_atoms!/1`.
2. **Collision precedence holds:**
   `mix test test/jido_claw/core/map_keys_test.exs` — new `describe` block green.
   `mix test test/jido_claw/solutions/trust_test.exs` — new `describe` block green; all existing tests still pass.
3. **Full suite:** `mix test` — green.
4. **Credo dual-key warnings stay at zero:**
   `mix credo --checks ExSlop.Check.Warning.DualKeyAccess --format json | jq '.issues | length'` → `0`.
5. **Strict compile:** `mix compile --warnings-as-errors`.
6. **Format:** `mix format --check-formatted`.
7. **End-to-end sanity check via Tidewave `project_eval`** (run before reload of all workflow modules):
   ```elixir
   JidoClaw.Skills.execution_mode(
     %JidoClaw.Skills{
       name: "demo",
       steps: [%{"name" => "s", "depends_on" => ["a"], "task" => "t", "role" => "r"}]
     }
   )
   ```
   Should return `:dag` (the `:depends_on` and `:name` keys survive). And `Map.get/2` for `:task` and `:role` on the same normalized step should return the expected values.

## Risks and mitigations

| Risk | Mitigation |
|------|------------|
| Dropping unknown step keys breaks an undocumented YAML field | Zero checked-in YAML; downstream readers (workflows, CLI, skills) reference only the canonical 7 keys; reviewer sign-off makes the contract explicit |
| Atom-first precedence surprises a caller of `NetworkFacade.normalize_keys/1` or `Harness` checkpoint load | Both pass single-shape inputs (wire data is string-only; checkpoint metadata is atom-only); collision is unreachable |
| Atom-first in `:string` mode (string-first) regresses `Protocol.normalize_keys/1` (wire encoding) | `Protocol` receives atom-keyed app data; no collisions in practice |
| Deterministic ordering still depends on `Enum.split_with/2` iteration which is map-order dependent | Order within each partition doesn't matter — only the *winning* partition is processed last; the new tests cover both insertion orders to lock this |
| `StepNormalizer` test that omits `ensure_atoms!/1` could pass by coincidence if another test loads workflow modules first | The literal `@canonical_keys` in `step_normalizer.ex` interns the atoms at compile time of that module itself; correctness is structural, not coincidental. Tests pin behavior; the `:atom_existing` path is no longer touched |
| Future `normalize_keys` caller depends on the previous (non-deterministic) collision behavior | None known. The previous behavior was undocumented and non-deterministic, so there's no contract to break. New moduledoc paragraph locks the new behavior |
