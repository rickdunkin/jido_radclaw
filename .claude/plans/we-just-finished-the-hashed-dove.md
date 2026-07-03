# Fix review P1: LoopGuard counts MCP `isError: true` results as successes

## Context

The doom-loop guard (next-ten #2, just shipped) classifies tool results typed-ly: `{:error, _}` tuples and run_command's `{:ok, %{exit_code: n≠0}}` are failures; everything else `{:ok, _}` is success. But generated MCP proxies **deliberately** re-surface MCP domain failures as `{:ok, %{"isError" => true, ...}}` (`lib/jido_claw/mcp/proxy_generator.ex:263` — so the failure reaches the model as data instead of being mangled by `Error.normalize`). The review's P1: those results fall to `classify_result({:ok, _}) -> :success` (`lib/jido_claw/agent/loop_guard.ex:261`).

**Validated this session** (code reading + live Tidewave):

- `classify_result({:ok, %{"isError" => true, "content" => [...]}}, params)` → `:success` — confirmed live.
- `Error.normalize_result/1` passes the string-keyed shape through untouched (`error.ex:81-88` only converts atom-keyed `%{status: :failed}`), and `observe_result` sits right after normalize (`action.ex:74-75`), so the guard sees exactly this raw shape.
- Consequences confirmed: (a) repeated failing external MCP calls with **varied args** never accumulate failure signatures — mechanism 2 (3-in-20) is blind to the primary MCP error contract; (b) worse, each such "success" **clears** that tool's prior signatures via per-tool clearing (`loop_guard.ex:482-487`), erasing genuine transport-error (`{:error, _}`) signatures for the same `mcp_*` tool. The identical-args pre-execution check still catches exact repeats (success-agnostic).
- **Corollary the review missed** (confirmed live): `append_directive/2` has no clause for the string-keyed shape — it falls to the pass-through at `loop_guard.ex:322`. A classification-only fix would make `check_result` count recoveries and clear signatures while the model **never sees the nudge directive**. Delivery must be fixed together with classification.

One finding total; this plan resolves it (classification + delivery + docs + tests). Done = bare `mix precommit` exits 0.

## Fix

### 1. `lib/jido_claw/agent/loop_guard.ex` (the only lib change)

**Classification** — two clauses before `classify_result({:ok, _output}, _)` at `:261`, mirroring the `{:error, _}` / `{:error, _, _}` pair above:

```elixir
def classify_result({:ok, %{"isError" => true} = output}, params),
  do: {:failure, mcp_error_text(output, params)}

def classify_result({:ok, %{"isError" => true} = output, _effects}, params),
  do: {:failure, mcp_error_text(output, params)}
```

- **Flag-only match, no tool-name gating**: matches the shaper's `mcp_is_error/1` precedent (`output_shaper.ex:433` — keys on the shape, boolean flag). No native tool returns this shape (rg-verified: `isError` appears only in the MCP consume/serve paths), and gating on name would ripple `classify_result/2`'s public contract. Literal `true` means `"isError" => false` / non-boolean values keep classifying `:success`.
- The `exit_code` clause's 2-tuple-only stance is a pre-existing asymmetry (run_command returns 2-tuples) — untouched.

**Signature text** — `mcp_error_text/2` next to `exit_text/3` (`:271`): `Enum.map_join` the binary `"text"` values of the `"content"` list (items may lack `"type"` — see `output_shaper_test.exs:676`; skip non-map/non-binary items), `String.trim`; blank/absent content → `"isError (args:#{digest_prefix(params)})"` — reuses the existing `digest_prefix/1` (`:281`) and mirrors `exit_text`'s blank-output fallback (distinct silent failures must not collide into one signature).

**Nudge delivery** — two clauses in the `append_directive/2` OK-shape group (`:315-320`; no overlap with the atom-keyed `%{output: _}` clauses):

```elixir
def append_directive({:ok, %{"isError" => true} = result}, directive),
  do: {:ok, append_mcp_content(result, directive)}

def append_directive({:ok, %{"isError" => true} = result, effects}, directive),
  do: {:ok, append_mcp_content(result, directive), effects}
```

`append_mcp_content/2`: when `"content"` is a list, append `%{"type" => "text", "text" => directive}` (**append**, not prepend — the directive must read after the error text; list-of-maps append, not string building, so the iodata rule doesn't apply); absent → `Map.put_new(result, "content", [item])`; non-list (malformed per spec) → unchanged (never mangle data; the staged halt still fires on a later trigger). Downstream is safe either way: below the inline cap the map passes through the shaper structurally; above it, `shape_mcp_payload` re-serializes the whole map and the tail-preserving elision keeps the appended item.

**Docs in-module**: `classify_result` @doc (the sentence "the run_command nonzero-exit shape is the one error-bearing `{:ok, _}`" is now false — name both error-bearing OK shapes: nonzero `exit_code`, and the MCP `"isError" => true` contract re-surfaced by the proxies); `append_directive` @doc (add the content-item delivery); moduledoc mechanism-2 paragraph (`:22-31`). The file-wide `reach:disable fixed_shape_map` (`:5`) already covers the new string-keyed literals.

### 2. Tests — red first (confirm they fail against current lib, then fix to green)

**Unit** (`test/jido_claw/agent/loop_guard_test.exs`, existing describes):

- `classify_result/2` describe (`:220`): isError → `{:failure, <content text>}` (2- and 3-tuple); multi-item content joined; items lacking `"type"` still extracted; blank/absent content → `"isError (args:<8-hex>)"` fallback varying with params (mirror the exit_text fallback tests at `:236-248`); `"isError" => false` and `"isError" => "true"` → `:success`.
- `append_directive/2` describe (`:272`): directive appended as the **last** content item with original items intact; effects preserved on the 3-tuple; absent content → one-item list; non-list content → result unchanged.

**Integration** (`test/jido_claw/tools/loop_guard_integration_test.exs`, inline-tool + put_env/Store.reset pattern already in the file `:22-164`):

- New `McpErrorEcho` fake (`use JidoClaw.Tools.Action, name: "mcp_loop_guard_echo"` — mcp_-rooted for fidelity) echoing `{:ok, %{"content" => [%{"type" => "text", "text" => <msg>}], "isError" => true}}`.
- Staged-flow test mirroring `:172`: 9 varied-`:index` calls with the same content text → calls 3 and 6 carry the `[DOOM LOOP RECOVERY:` directive as an appended content item on the **final piped result**; call 9 → `{:error, %{code: :doom_loop, details: %{retry: false, trigger: :failure_signature}}}`; call 10 blocked pre-execution (sticky halt, `refute_receive`).
- No-clear regression (the review's sharpest consequence): 2 transport failures `{:error, %{message: "connection refused"}}` + 1 isError result with content text `"connection refused"` for the same tool → the 3rd call nudges (pre-fix, the isError call cleared the two signatures and recorded nothing — this is the red test).
- Clearing still works in the genuine direction: isError failures interleaved with one `"isError" => false` success → success clears, no trigger from the stale pair.
- **Test hygiene (all new signature-mechanism tests)**: every call carries a varied `:index` param — as the staged-flow test at `:172` does — so the identical-call precheck can never fire and mask the failure-signature behavior being proven.
- `assert match?(pattern, x), "msg"` form where a message is wanted.

### 3. Doc sweep (false-invariant restatements — rg-swept, complete list)

- `AGENTS.md:90` Loop Guard bullet, two spots: mechanism 2's "typed classification — `{:error, _}` tuples or run_command's `{:ok, %{exit_code: n}}` with `n != 0`" gains the MCP `{:ok, %{"isError" => true}}` proxy contract; the delivery parenthetical "(`message`, or `output` for the nonzero-exit OK shape)" gains "or an appended `content` text item for the MCP isError shape".
- `docs/exploration/osa/FEATURES-WORTH-BORROWING.md:87-88` correction (d): same classification addition.
- `docs/plans/unadopted-next-ten/README.md`: no classification restatement (rg-verified) — no change.

## Verification

1. Red: run the two test files with the new tests before touching lib — new assertions must fail for the stated reason (`:success` classification / unchanged delivery).
2. Green: `mix test test/jido_claw/agent/loop_guard_test.exs test/jido_claw/tools/loop_guard_integration_test.exs` (plus `test/jido_claw/agent/loop_guard/store_test.exs` untouched-but-adjacent).
3. **Gate: bare `mix precommit`** — no pipes, report exact exit code + test counts verbatim; zero credo/reach/exslop findings. Done = exit 0. (Known full-suite flake: `MemoryExportTest` capture_log race — passes in isolation, not a regression.)

Nothing committed; changes stay unstaged alongside the existing session's work.

## House-gotcha checklist

File-wide `fixed_shape_map` disable already present in `loop_guard.ex` · new helpers are single-site defps (no exslop clone seams, no trivial forwarders) · directive strings stay interpolation-built; `content ++ [item]` is a list append, not string concat · integration fakes echo canned results (reach scans test/support — same shapes as existing fakes) · guard config untouched (`enabled?: false` in test; integration arms via put_env + restore, Store.reset in setup, `async: false`).
