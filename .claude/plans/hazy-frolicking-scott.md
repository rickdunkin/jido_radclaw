# AR-8b-2 review fixes — P1/P2/P3 (prototype summary + sketch graduation)

## Context

The AR-8b-2 sketch-graduation work (plan: `please-review-docs-exploration-alp-river-async-engelbart.md`)
shipped unstaged. A code review found three defects; all three are **verified real** (empirically, via
Tidewave). They are security/correctness regressions in two new modules:

- **P1 (secret leak):** `PrototypeSummary` truncates each prototype file **before** redacting it, so a secret
  straddling the 8 KB per-file cap is cut below the redaction regex's minimum match length and a **partial API
  key reaches the summarization LLM**. Confirmed: current order leaks `sk-ant-AAAAAAAAAAAA`; redact-first yields
  `[REDACTED:ANTHROPIC_KEY]`.
- **P2 (stale-candidate survival):** a `:secrets` sketch is supposed to clear any stale `pending_prototype` so a
  prior throwaway can't graduate into a sensitive context. The clear lives only in `start_composer`'s **success**
  branch, so a launch failure **or** an oscillation **debounce** lets the stale candidate survive. (User chose the
  **robust** fix — close both gaps.)
- **P3 (cap overshoot):** the total-bytes accumulator checks `total >= @max_total_bytes` **before** adding the
  next file, so it overshoots by up to one whole file. Confirmed: 8×7999-byte files reach **47 994** vs the
  **40 000** cap.

**Outcome:** redaction always sees full content before any truncation; the 40 KB cap becomes hard; and a
`:secrets` sketch clears stale candidates on *every* path (success, failure, debounce) — one clean invariant.

**Definition of done:** `mix precommit` passes (`jidoclaw.compile_check`, `format --check-formatted`,
`reach.check --arch --smells --strict`, `credo --strict`, `dialyzer --format short`, `test`). Leave unstaged; do
not commit.

---

## Fix 1 — P1 + P3 (`lib/jido_claw/front_door/prototype_summary.ex`)

Both live in the bounded-read helpers; fix together. Thread the **remaining total budget** into `read_one`, and
**redact before the byte cap**.

```elixir
defp accumulate_excerpt(_dir, _path, {acc, total}) when total >= @max_total_bytes,
  do: {:halt, {acc, total}}

defp accumulate_excerpt(dir, path, {acc, total}) do
  # P3: bound this file to the REMAINING total budget too — the `>=` guard above
  # only halts AFTER a file is added, so without this a near-full accumulator could
  # overshoot @max_total_bytes by almost one whole file.
  case read_one(dir, path, @max_total_bytes - total) do
    {:ok, excerpt} -> {:cont, {[excerpt | acc], total + byte_size(excerpt.content)}}
    :error -> {:cont, {acc, total}}
  end
end

defp read_one(dir, path, budget) do
  cap = min(@max_bytes_per_file, budget)

  case Resolver.read(path, project_dir: dir, local_only: true) do
    {:ok, raw} ->
      # P1: redact BEFORE the byte cap. Truncating first can split a secret across
      # the cap so the redaction regex (e.g. `sk-ant-…{20,}`) no longer matches and
      # a partial key reaches the LLM. scrub → redact(full) → cap → scrub (the cap
      # may split a multibyte char at the boundary; the trailing scrub re-cleans it).
      content =
        raw
        |> scrub_utf8()
        |> Patterns.redact()
        |> head_bytes(cap)
        |> scrub_utf8()

      excerpt_or_skip(Path.relative_to(path, dir), content)

    _error ->
      :error
  end
end
```

**Notes / invariants (verified):**
- The `>=` guard guarantees `budget >= 1` whenever the second clause runs, so `cap >= 1` and `head_bytes(_, cap)`
  is always valid. After the fix `total + byte_size(content) <= @max_total_bytes` — the overshoot is gone.
- **Both scrubs are load-bearing:** `Patterns.redact/1` does not raise on invalid UTF-8, but `head_bytes` **after**
  redact can produce invalid UTF-8 at the cap; the trailing `scrub_utf8` repairs it (the existing `scrub_utf8/1`
  doc at `:180-182` already anticipates "a multibyte char split by head_bytes/2" — keep that doc).
- **No new helper:** the `head_bytes |> scrub_utf8` pairing is the existing local idiom; there is no
  UTF-8-boundary-aware take helper in the codebase, and adding one would risk a reach clone. Keep `min(...)`; do
  **not** add a `budget <= 0` halt clause (the `>=` guard already covers it, and an extra short clause adds
  clone-window pressure).
- **Doc tweak:** in the moduledoc "Bounded" bullet, note the redact pass is now **O(file size)** (the whole file
  is already in memory via `Resolver.read` → `File.read`, so the only added cost is the regex over bytes beyond
  8 KB — acceptable for throwaway prototypes), and that the 12-files / 8 KB-per-file / 40 KB-total caps are hard.

---

## Fix 2 — P2 robust (`lib/jido_claw/front_door.ex`)

Move the sensitive-sketch clear **out of** `start_composer`'s success branch and into `decide/2`, **before** the
oscillation guard, so it runs on launch-success, launch-failure, **and** debounce.

**In `decide/2`** (composer branch, before `oscillation_guard/3`):
```elixir
if Verdict.composer?(verdict) do
  # P2: a `:secrets` sketch walls off cross-run graduation — clear any stale
  # candidate up front, BEFORE the guard, so neither a launch failure NOR a
  # debounce can let a prior non-sensitive prototype survive into a sensitive
  # context. (The new-candidate WRITE stays in start_composer's success branch.)
  clear_candidate_for_sensitive_sketch(verdict, session, ctx)

  case oscillation_guard(session, verdict.path, ctx) do
    ...
  end
else
  ...
end
```

**New helper — place it physically near `decide/2`** (e.g. right after `decide/2`), **not** in the C1
`write_pending_prototype` cluster (avoids a ≥4-contiguous-short-`defp` reach clone window — the top precommit
risk):
```elixir
# P2: a `:secrets` sketch clears any stale `pending_prototype` regardless of whether
# its own launch then succeeds, fails, or is debounced. (Replacing a candidate
# otherwise only happens on a write, so a never-launched sensitive sketch must clear
# explicitly.)
defp clear_candidate_for_sensitive_sketch(%Verdict{path: :sketch, signals: signals}, session, ctx) do
  if :secrets in signals, do: write_pending_prototype(session, ctx, nil), else: :ok
end

defp clear_candidate_for_sensitive_sketch(_verdict, _session, _ctx), do: :ok
```

**Simplify `set_sketch_candidate`:** delete the `set_sketch_candidate(:sketch, true, ...)` clause (the sensitive
clear now happens eagerly in `decide/2`). **Keep** the non-sensitive write clause **and** the catch-all no-op
(removing the catch-all would `FunctionClauseError` on `code`/`system` launches — a sensitive sketch now also
falls correctly to the catch-all). Update the stale call-site comment (currently "…set the durable graduation
candidate (non-sensitive) or clear any stale one (sensitive)…") to: *write the candidate only for a successful
**non-sensitive** sketch; a sensitive sketch already cleared any stale one in `decide/2`; no-op for code/system.*

**Verified safe:** for a sketch turn `pending_graduation/3` already returns `nil` (it's gated on
`path in [:code, :system]`), so `candidate`/`graduation` for the current turn are unaffected by the early clear;
the clear is an atomic `jsonb_set #-` delete (idempotent on an absent key) and short-circuits on a `nil` session.
The module doc at `:34-35` ("writes no candidate (and clears any stale one)") becomes true on **all** paths.

---

## Fix 3 — regression tests

| File | New test(s) |
| --- | --- |
| `test/jido_claw/front_door/prototype_summary_test.exs` | **P1 boundary:** pad so an `sk-ant-…` key *starts* ~byte 7 985 — straddling the 8 KB per-file cap but leaving comfortable room so the post-redaction `[REDACTED` prefix survives the cap (don't place it so close that even `[REDACTED` is cut). Assert captured content has **no** `sk-ant` fragment **and** contains `[REDACTED` (truncate-first would leak `sk-ant-AAA…`). **P3 hard cap:** fill 8 files of ~7 KB (>40 KB total) with a **sentinel** char (e.g. `"Z"`, absent from the `FILE:`/begin/end framing) → assert the **count of the sentinel** in the captured content is `<= 40_000` (counts only excerpt *content*, not framing — avoids a brittle total-size margin; current code admits ~48 KB of content). |
| `test/jido_claw/front_door_graduation_test.exs` | **P2 launch-failure clear** (next to the existing sensitive-clear test, `:238-261`): non-sensitive sketch writes a candidate → `:secrets` sketch with `front_door_create_mode: :error` ⇒ `{:composer, {:error, %{path: :sketch}}}` **and** `candidate(ctx) == nil`. |
| `test/jido_claw/front_door_oscillation_test.exs` | **P2 debounce clear** (in `describe "debounce + C1 interaction"`): seed thrashy `path_transitions` (`[{"code",1},{"sketch",2}]`) + a stale `pending_prototype` (`seed_candidate/3`) → `:secrets` sketch ⇒ `{:composer, {:error, %{path: :sketch}}}` **and** `metadata(ctx)["pending_prototype"] == nil`. |

Each test fails on current code and passes after its fix. Reuse the existing seams: `capturing_gen/1` /
`captured_content/0` (summary), `front_door_create_mode: :error` via `FrontDoorComposerStub`, and
`seed_transitions/2` / `seed_candidate/3` (oscillation).

---

## precommit watch-points (from the validation pass)

- **reach `--strict` clone (top risk):** keep `clear_candidate_for_sensitive_sketch/3` to two clauses and place it
  near `decide/2`, away from the other one-line `write_pending_prototype` delegators (min_mass 30, window 4).
  `read_one/3` and the P1/P3 edits create no clones.
- **credo `--strict`:** the 4-stage pipe is fine (SinglePipe/OneArityFunctionInPipe target single/anonymous pipes,
  not multi-stage named calls); keep one `|>` per line so `format --check-formatted` is happy. No new nesting or
  complexity. Private fns need no `@spec`/`@doc`.
- **dialyzer:** `read_one/2 → /3` has a single caller (updated in the same edit); the new helper's success typing
  is `:ok`. No risk.
- **compile_check (no warnings):** removing the `(:sketch, true, ...)` clause yields no unreachable/unused warning
  (the catch-all still covers it); `budget`/`cap` are both used.

## Verification

1. Targeted tests:
   `mix test test/jido_claw/front_door/prototype_summary_test.exs test/jido_claw/front_door_graduation_test.exs test/jido_claw/front_door_oscillation_test.exs`
2. **`mix precommit`** — the completion gate (full suite + strict format/credo/reach/dialyzer + compile_check).
