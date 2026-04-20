# v0.4.4–v0.4.7 Code Review Fixes

## Context

A code review on v0.4.4–v0.4.7 surfaced two regressions that contradict documented behavior. Both are confirmed accurate by reading the source:

1. **[P1] StrategyStore crash on non-string YAML keys** — `lib/jido_claw/reasoning/strategy_store.ex:315` interpolates `raw_key` directly into a `Logger.warning/1` string. YAML permits complex keys (e.g. `? bad: key` yields a map, `? [a, b]` yields a list), which YamlElixir surfaces as terms that do not implement `String.Chars`. The interpolation then raises `Protocol.UndefinedError` *before* the `:drop` return, so a single malformed strategy file crashes the supervised `StrategyStore` at boot/reload — directly contradicting the moduledoc's "Lenient skipping" contract (`strategy_store.ex:44-51`).

2. **[P2] First accumulate stage bypasses `max_context_bytes`** — `lib/jido_claw/tools/run_pipeline.ex:425-434` pattern-matches `%{outputs: []}` and returns `{:ok, initial, %{}}` without ever consulting `stage_cap` or `pipeline_cap`. The moduledoc (`run_pipeline.ex:48-79`) and v0.4.7 ROADMAP entry both describe the cap as bounding "the composed prompt" in accumulate mode with no stage-1 exclusion. A pipeline configured with a small cap can still forward an arbitrarily large initial prompt to its first stage's model.

The goal is to restore the documented contracts, add regression coverage for both paths, and update the moduledoc to spell out first-stage semantics.

## Changes

### 1. StrategyStore — safe rendering of unknown prompt keys

**File**: `lib/jido_claw/reasoning/strategy_store.ex`

At `classify_prompt_entry/4` (around line 313-318), replace the unsafe interpolation so any term YamlElixir hands us can be logged without raising. The smallest possible patch is `inspect/1`:

```elixir
is_nil(atom_key) ->
  Logger.warning(
    "[StrategyStore] Unknown prompt key #{inspect(raw_key)} — dropping (known: #{known_prompt_key_list()})"
  )

  :drop
```

Default to this form. It's one character of diff at the call site, no helper needed, and `inspect/1` handles every term safely. The only cosmetic change is that string keys render as `"sytem"` instead of `'sytem'` in the warning — acceptable, and unambiguous for the edge cases this guards.

If preserving the current quoted look for normal string/atom keys matters, a `format_raw_key/1` helper (`is_binary` → `'#{k}'`, `is_atom` → `'#{Atom.to_string(k)}'`, else → `inspect`) is a valid alternative. Call the decision at implementation time; the behavior change is identical.

No other interpolations in this file touch `raw_key` — `grep '#{' strategy_store.ex` confirms line 315 is the only unsafe site.

### 2. RunPipeline — apply cap to the first accumulate stage

**File**: `lib/jido_claw/tools/run_pipeline.ex`

Replace the `%{outputs: []}` clause at lines 425-434 with a version that consults the cap. For the first stage, the "composed prompt" is just `initial`; no prior outputs exist to drop, so it's a simple fit/no-fit check. Fail-fast message mirrors the existing irreducible-failure format (line 477).

```elixir
defp compose_and_cap(
       %{context_mode: "accumulate"},
       initial,
       %{outputs: []},
       stage_cap,
       pipeline_cap
     ) do
  cap = stage_cap || pipeline_cap
  pre_cap_bytes = byte_size(initial)

  cond do
    is_nil(cap) ->
      {:ok, initial, %{}}

    pre_cap_bytes <= cap ->
      {:ok, initial, %{}}

    true ->
      reason = "max_context_bytes (#{cap}) exceeded by initial prompt alone"
      {:error, reason, initial, failure_cap_meta(pre_cap_bytes, [])}
  end
end
```

Reuses existing `failure_cap_meta/2` (line 520) — passing `[]` for dropped stages yields `dropped_stage_indexes: []`, consistent with the "no drops happened" state. The `{:error, reason, classification_prompt, cap_meta}` shape is handled by `run_stage_in_loop/9` (lines 292-326), which already routes cap failures through `Telemetry.with_outcome/4` and persists the `:error` row — no changes needed there.

### 3. Moduledoc — document the first-stage case

**File**: `lib/jido_claw/tools/run_pipeline.ex` (moduledoc, around lines 66-69)

Extend the fail-fast section so the stage-1 branch isn't left implicit. Insert after line 69:

> If the **initial prompt alone** exceeds the cap, stage 1 fails-fast with:
>
>     stage 1: max_context_bytes (C) exceeded by initial prompt alone
>
> (no prior outputs exist to drop).

### 4. Regression tests

**File**: `test/jido_claw/reasoning/strategy_store_test.exs`

Under the `"prompts"`-related describe block (near the existing "unknown sub-key is dropped with a warning" test at line 321), add a test that exercises a complex YAML key via explicit-key syntax. YamlElixir surfaces these as terms that do not implement `String.Chars` (the reviewer's repro with `? KEY : VALUE` produced a yamerl-shaped term); pre-fix the interpolation raises inside `start_store/1`. The test focuses on behavior — "the store does not crash and the valid sibling key survives" — rather than the exact shape of the term.

```elixir
test "non-String.Chars prompt key is skipped leniently (does not crash the store)",
     %{tmp_dir: tmp, strategies_dir: dir} do
  # YAML explicit-key syntax (`? KEY : VALUE`) lets the key be a non-scalar
  # term. YamlElixir returns it as a term that does not implement
  # String.Chars, so pre-fix the warning interpolation would raise.
  # This test asserts the store survives and siblings are preserved.
  write_yaml(dir, "weird_key.yaml", """
  name: weird_key
  base: cot
  prompts:
    ? nested: key
    : "some value"
    system: "kept"
  """)

  pid = start_store(tmp)
  [entry] = call(pid, :all)
  assert entry.prompts == %{system: "kept"}
end
```

If YamlElixir's parser rejects the explicit-key syntax on this version, fall back to a list key (`? [a, b]\n: "..."`). Either produces a non-`String.Chars` term that reproduces the crash pre-fix.

**File**: `test/jido_claw/tools/run_pipeline_test.exs`

Add two tests inside the existing `describe "max_context_bytes cap"` block (line 550):

```elixir
test "first accumulate stage fails fast when initial prompt alone exceeds the cap" do
  name = "cap_first_stage_fail_#{System.unique_integer([:positive])}"
  big_prompt = String.duplicate("x", 2_000)

  assert {:error, msg} =
           RunPipeline.run(
             %{
               pipeline_name: name,
               prompt: big_prompt,
               max_context_bytes: 500,
               stages: [
                 %{"strategy" => "cot", "context_mode" => "accumulate"},
                 %{"strategy" => "tot", "context_mode" => "accumulate"}
               ]
             },
             %{reasoning_runner: FixedBodyRunner}
           )

  assert msg =~ "stage 1: max_context_bytes (500) exceeded by initial prompt alone"

  rows = find_pipeline_rows(name)
  assert length(rows) == 1
  s1 = Enum.find(rows, fn r -> stage_index(r) == 1 end)
  assert s1.status == :error

  md = s1.metadata
  failure_reason = Map.get(md, "failure_reason") || Map.get(md, :failure_reason)
  pre_cap = Map.get(md, "accumulated_context_bytes_pre_cap")
  dropped = Map.get(md, "dropped_stage_indexes")
  assert failure_reason =~ "initial prompt alone"
  assert pre_cap == byte_size(big_prompt)
  # Locks in the "no drops were possible" metadata shape — there are no
  # prior stages to drop when stage 1 overflows.
  assert dropped == []
end

test "first accumulate stage passes through when initial prompt fits the cap" do
  name = "cap_first_stage_ok_#{System.unique_integer([:positive])}"

  assert {:ok, _result} =
           RunPipeline.run(
             %{
               pipeline_name: name,
               prompt: "INITIAL",
               max_context_bytes: 500,
               stages: [
                 %{"strategy" => "cot", "context_mode" => "accumulate"}
               ]
             },
             %{reasoning_runner: FixedBodyRunner}
           )

  rows = find_pipeline_rows(name)
  s1 = Enum.find(rows, fn r -> stage_index(r) == 1 end)
  # No drops occurred — no cap metadata recorded, matching existing
  # "success without drops" convention.
  refute Map.has_key?(s1.metadata, "accumulated_context_bytes_pre_cap")
  refute Map.has_key?(s1.metadata, "dropped_stage_indexes")
end
```

## Files touched

| File | Change |
|---|---|
| `lib/jido_claw/reasoning/strategy_store.ex` | Safe `format_raw_key/1` helper + call-site swap (line ~315) |
| `lib/jido_claw/tools/run_pipeline.ex` | First-stage cap check in `compose_and_cap/5` `%{outputs: []}` clause (lines ~425-434) + moduledoc addition (~line 69) |
| `test/jido_claw/reasoning/strategy_store_test.exs` | Regression test for non-stringable prompt key |
| `test/jido_claw/tools/run_pipeline_test.exs` | Regression tests for first-stage cap enforcement (fail + pass paths) |

## Verification

```bash
mix format
mix compile --warnings-as-errors
mix test test/jido_claw/reasoning/strategy_store_test.exs
mix test test/jido_claw/tools/run_pipeline_test.exs
```

Expected: all new and existing tests pass; no new warnings. The existing "stage-level cap overrides top-level cap" test (line 687) continues to pass because its initial prompt `"INITIAL"` (7 bytes) fits both the pipeline-level cap of 100 and stage 2's override of 100_000.

Also re-run the reviewer's original focused set to confirm no regressions:

```bash
mix test test/jido_claw/reasoning/strategy_store_test.exs \
         test/jido_claw/reasoning/pipeline_store_test.exs \
         test/jido_claw/reasoning/telemetry_test.exs \
         test/jido_claw/tools/reason_test.exs \
         test/jido_claw/tools/run_pipeline_test.exs
```

## Out of scope

- No other `#{}` interpolations in `strategy_store.ex` touch user-supplied terms (the rest use `inspect/1` or project-controlled values).
- No schema changes — cap failures already persist through the existing `reasoning_outcomes` metadata keys.
- No changes to `PipelineValidator` or `PipelineStore` — they don't touch the `max_context_bytes` enforcement path.
