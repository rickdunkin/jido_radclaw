# Harden `CatalogValidator` structural checks (AR-2 Phase 0 review follow-ups)

## Context

Phase 0 of the AR-2 route composer shipped a pure `Stage` / `Catalog` / `Router` /
`Graph` / `CatalogValidator` stack. `CatalogValidator.validate/1` is the **structural
gate** the rest of the layer trusts: a clean result is supposed to guarantee the catalog
is well-formed enough that `Router.compose_route/4` can never produce a contract-violating
result. The plan billed group 0 ("structural well-formedness") as the replacement for the
dropped `gen-catalog` compile-time normalizer.

A code review found two gaps, and a review of the proposed fix surfaced two more
totality/crash-safety holes in `structural_for/2`. **All are confirmed empirically**
(Tidewave `project_eval`, mirroring the reviewer's method):

- **[P2] Atom-keyed catalog passes, then leaks atoms into the route.** `check_name/2`
  only checks `stage.name == key` via the same-variable trick; it never checks either is a
  binary. `%{a: %Stage{name: :a, …}}` validates clean and `Router.compose_route/4` returns
  `route: [:a]` — route elements are the catalog **keys**, so an atom key flows into the
  public `route: [String.t()]` result, violating the contract and the atom-safety rule
  (`stage.ex:18-20`).
- **[P3] Typed `Stage` fields are never shape-checked.** `structural_for/2` skips `task`,
  `lens`, `guard`, `model`, `effort`, `emit`. A stage with `guard: :stickyy`,
  `model: "fast"`, `effort: 5`, `emit: :wrong`, `task: 123`, `lens: :security` validates
  clean, despite `stage.ex:57-90` declaring closed enums / nilable strings for all of them.
- **[totality] Non-`%Stage{}` catalog value crashes.** `structural_for/2` assumes every
  value is a `%Stage{}`; `validate(%{"a" => %{not: "a stage"}})` raises a
  `FunctionClauseError` in `check_name/2` instead of returning a problem.
- **[crash-safety] A non-binary key with another malformed field crashes.** Field helpers
  build messages with `"#{name}"`; a tuple/atom key that also has, e.g., bad `routes` raises
  `protocol String.Chars not implemented for Tuple` *before* any problem is returned
  (`inspect/1` is total here, `"#{…}"` is not).

**Goal:** make `validate/1` a total, crash-safe structural gate — a clean result truly
implies a well-formed catalog, and any malformed shape yields a problem string rather than
an exception. **Done = `mix precommit` green** (the same hard bar as Phase 0). Everything
stays unstaged; no commits.

## Fix logic already simulated

A `project_eval` simulation of the restructured dispatch confirmed: valid stage → `[]`;
atom key → flagged; **tuple key + bad field → single key problem, no crash**; **non-`%Stage{}`
value → flagged, no crash**; valid non-default scalars (`:sticky`/`:capable`/`:high`/
`{:mapper,_}`) → `[]`; and `Catalog.all()` stays **clean** (the regression guard).

---

## Fix 1 — make `structural_for/2` total and crash-safe

`lib/jido_claw/route_composer/catalog_validator.ex`. Replace the single `structural_for/2`
(lines 96-107) with **three clauses**. Clause 1 guards `is_binary(name)` so every field
helper downstream only ever sees a binary key (its `"#{name}"` interpolation is then
crash-safe). A non-binary key with a valid `%Stage{}` value short-circuits to a single key
problem (the reviewer's preferred "return only the key problem" option). A non-`%Stage{}`
value short-circuits to a value-shape problem.

```elixir
defp structural_for(name, %Stage{} = stage) when is_binary(name) do
  List.flatten([
    check_name(name, stage),
    check_string_list(name, "routes", stage.routes),
    check_string_list(name, "output", stage.output),
    check_string_list(name, "subscribes", stage.subscribes),
    check_string_list(name, "publishes", stage.publishes),
    check_input_shape(name, stage.input),
    check_lock_shape(name, stage.lock),
    check_unit_shape(name, stage.unit),
    check_optional_string(name, "task", stage.task),
    check_optional_string(name, "lens", stage.lens),
    check_enum(name, "guard", stage.guard, [:sticky, nil]),
    check_enum(name, "model", stage.model, [:fast, :capable, nil]),
    check_enum(name, "effort", stage.effort, [:low, :medium, :high, nil]),
    check_emit(name, stage.emit)
  ])
end

defp structural_for(name, %Stage{}),
  do: ["#{inspect(name)}: catalog key must be a string"]

defp structural_for(name, _other),
  do: ["#{inspect(name)}: catalog entry must be a %JidoClaw.RouteComposer.Stage{}"]
```

Because the binary-key guarantee now lives in clause 1's guard, **`check_name/2` stays in
its original two-clause form** (unchanged) — it only ever receives a binary key + a
`%Stage{}`, so its `"#{name}"` is safe and it just keeps the name == key equality check:

```elixir
defp check_name(name, %Stage{name: name}), do: []

defp check_name(name, %Stage{name: other}),
  do: ["#{name}: stage name #{inspect(other)} does not match catalog key #{inspect(name)}"]
```

`sorted_stages/1` already tolerates mixed-type keys (`Enum.sort_by` uses Elixir total term
ordering, which never raises across types). `validate/1`'s `case structural(...) do [] ->
coherence ++ cycle …` already short-circuits, so the semantic groups run **only** when
every entry is a binary-keyed `%Stage{}` — coherence/cycle never see a malformed shape.

## Fix 2 — structural checks for the six typed fields

Same file (the six new entries are already in Fix 1's clause-1 list above). Add three small
helpers, placed **non-contiguously** among the existing group-0 helpers (distinct from each
other and from `check_unit_shape`, but spaced to stay clear of the clone gate):

```elixir
defp check_optional_string(_name, _field, value) when is_nil(value) or is_binary(value), do: []

defp check_optional_string(name, field, _value),
  do: ["#{name}: `#{field}` must be a string or nil"]

defp check_enum(name, field, value, allowed) do
  if value in allowed do
    []
  else
    ["#{name}: `#{field}` must be one of #{inspect(allowed)}"]
  end
end

defp check_emit(_name, :default), do: []
defp check_emit(_name, {:mapper, mapper}) when is_binary(mapper), do: []

defp check_emit(name, emit),
  do: ["#{name}: `emit` must be :default or {:mapper, string}, got #{inspect(emit)}"]
```

The enum allow-lists include `nil` (the struct defaults), so the starter catalog stays
clean. `check_optional_string` for `task` treats `nil` as valid — complementary to the
coherence `check_task/2`, which separately requires a *non-blank* task on a worker stage
with a required input.

## Fix 3 — tests (committed, per the permanent-test rule)

**`test/support/jido_claw/route_composer/fixtures.ex`** — extend `stage/1` to accept
`:model`, `:effort`, `:emit` (defaults match the struct defaults → `synthetic_catalog/0` /
`lock_catalog/1` unchanged). Update its `@doc`.

```elixir
model: Keyword.get(opts, :model),
effort: Keyword.get(opts, :effort),
emit: Keyword.get(opts, :emit, :default),
```

**`test/jido_claw/route_composer/catalog_validator_test.exs`** — add (all via the imported
`stage/1` builder; no raw `%Stage{}` literals → no clone risk):

1. **Atom key (Finding 1)** — `%{a: stage(name: :a, …)}` ⇒ a problem containing
   `"catalog key"`.
2. **Non-binary key + another bad field, no crash** — `%{{:weird} => stage(name: {:weird},
   routes: "notalist", …)}` ⇒ a problem containing `"catalog key"` (the test asserting it
   *returns* rather than raises is itself the crash-safety guard).
3. **Non-`%Stage{}` value, no crash** — `validate(%{"a" => %{not: "a stage"}})` ⇒ a problem
   containing `"Stage"`.
4. **Typed-field table (Finding 2)** — a `@typed_field_cases` list mirroring the existing
   `@coherence_cases`/`@structural_cases` style; each `contains` substring is unique to its
   field:

   ```elixir
   @typed_field_cases [
     %{name: "bad guard", opts: [guard: :nope], contains: "guard"},
     %{name: "bad model", opts: [model: "fast"], contains: "model"},
     %{name: "bad effort", opts: [effort: 5], contains: "effort"},
     %{name: "bad emit", opts: [emit: :wrong], contains: "emit"},
     %{name: "non-string task", opts: [task: 123], contains: "task"},
     %{name: "non-string lens", opts: [lens: :security], contains: "lens"}
   ]

   for row <- @typed_field_cases do
     test "structural typed field: #{row.name}" do
       row = unquote(Macro.escape(row))

       base = [name: "s", unit: {:seed, "s"}, routes: ["code"],
               sub: ["request-received"], pub: ["scope-shift"]]

       cat = %{"s" => TestFixtures.stage(Keyword.merge(base, row.opts))}
       assert Enum.any?(CatalogValidator.validate(cat), &String.contains?(&1, row.contains))
     end
   end
   ```

5. **Positive non-default scalars (no false positives)** — pin that valid non-default values
   pass end-to-end, so future catalogs can safely use them:

   ```elixir
   test "valid non-default scalar fields pass validation" do
     cat = %{
       "s" =>
         stage(
           name: "s", unit: {:worker_template, "coder"}, routes: ["code"],
           req: ["request"], out: ["diff"], sub: ["request-received"], pub: ["scope-shift"],
           task: "do the thing", lens: "security",
           guard: :sticky, model: :capable, effort: :high, emit: {:mapper, "x"}
         )
     }

     assert CatalogValidator.validate(cat) == []
   end
   ```

   (This catalog is also coherence-clean — `request` is a seed artifact, the worker task is
   non-blank, no lock/self-dep/cycle — so `validate/1` returns `[]` through every group.)

The existing tests are unaffected: every fixture is built via `stage/1` (valid typed-field
defaults) or a raw `%Stage{}` leaving these fields at valid defaults, so neither the
starter-catalog-clean test nor the short-circuit test regresses.

## Doc touch (minor)

Extend the `@moduledoc`'s group-0 description (around lines 14-22) to note structural
well-formedness now also covers the typed scalar fields (`task`/`lens` nilable strings;
`guard`/`model`/`effort` closed enums; `emit` as `:default | {:mapper, string}`) and that
non-`%Stage{}` values / non-string keys are rejected up front.

---

## Verification

1. **Targeted suite** — `mix test test/jido_claw/route_composer/` → the existing 75 pass
   plus the new atom-key, non-binary-key, non-`%Stage{}`, six typed-field, and positive
   cases.
2. **Single-file iteration** — `mix test test/jido_claw/route_composer/catalog_validator_test.exs`.
3. **Empirical re-check** (`project_eval`, post-edit): the four reproductions now return
   problem strings (no raise), and `CatalogValidator.validate(Catalog.all()) == []` still
   holds.
4. **The hard bar** — `mix precommit` green:
   - **Dialyzer watch-item.** The module already carries defensive catch-all clauses
     (`check_input_shape/2`, `check_unit_shape/2`, …) that Dialyzer accepts under the narrow
     `@spec validate(%{optional(String.t()) => Stage.t()})`, so the new `structural_for/2`
     defensive clauses should pass too. **If** Dialyzer reports the non-`%Stage{}` /
     non-binary-key clauses (or the `is_binary(name)` guard) as unreachable, widen that
     `@spec`'s input to `%{optional(term()) => term()}` — `validate/1`'s contract is to
     police arbitrary maps, and `coherence/1`/`cycle/1` run only after structural confirms
     every entry is a binary-keyed `%Stage{}`, so widening adds no real imprecision (`term()`
     ⊇ `map()` keeps the downstream field access valid).
   - **Clone gate** (`reach.check --smells --strict`): new helpers / test rows are distinct
     and table-driven; escape hatch if a smell still false-positives is
     `# reach:disable-for-this-file`.
   - **Credo `--strict`**: the original two-clause `check_name`, the small helpers, and the
     `if`-based `check_enum` stay under complexity limits; messages use plain interpolation,
     never `reduce` + `<>`.
   - Plus `format --check-formatted`, `system_prompt.check`, `deps.unlock --unused`.

## Critical files

- `lib/jido_claw/route_composer/catalog_validator.ex` — Fix 1 (3-clause `structural_for/2`,
  `check_name/2` unchanged), Fix 2 (typed-field checks + three helpers), moduledoc touch.
- `test/support/jido_claw/route_composer/fixtures.ex` — extend `stage/1`.
- `test/jido_claw/route_composer/catalog_validator_test.exs` — the new tests above.

## Memory anchors

`feedback_permanent_test_over_spot_check`, `project_precommit_zero_findings`,
`project_credo_reach_string_building`, `project_exslop_duplicate_clone_seams`.
