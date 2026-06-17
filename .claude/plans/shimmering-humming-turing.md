# Generic MCP output shaping (+ ANSI redaction hardening)

## Context

`docs/exploration/jidoka/FEATURES-WORTH-BORROWING-V2.md` records the Jidoka-V2 borrowing program
as complete; the remaining items are deliberate deferrals. The chosen next item is the **V2-2 deferred
"generic MCP output shaping"** gap.

**The bug.** External MCP tools are generated proxy `Jido.Action`s (`lib/jido_claw/mcp/proxy_generator.ex`)
returning `{:ok, data}` — the raw MCP `tools/call` result, an arbitrary map (typically
`%{"content" => [%{"type" => "text", "text" => ...}], "isError" => bool}`). They ride the shared
`JidoClaw.Tools.Action` pipeline (`lib/jido_claw/tools/action.ex:50-65`):
`ToolApproval.gate → Error.normalize → OutputRedaction → OutputShaper.shape_result → OutputLimit`.
But `OutputShaper` is hard-allowlisted to native tools (`@shapeable_tools %{"run_command" => :output,
"git_diff" => :diff}`, `output_shaper.ex:59`), so MCP results skip shaping/ref-storage and fall to
`OutputLimit.truncate_result` (`output_limit.ex:17-25`), which **blind-head-cuts each oversized string
field at 32KB, dropping the tail (where errors live) with no `fetch_output` recovery ref.**

**The fix.** Give oversized MCP results the same reversible head+tail shaping + ref-storage native tools
get. Verified facts that shaped the design (this plan was revised against a careful review):

- jido_ai JSON-encodes the **whole** MCP result map to the model (`deps/jido_ai/lib/jido_ai/turn.ex:381→391→818`),
  so `isError` is the model's only failure signal and `Error.normalize` does **not** promote it
  (`lib/jido_claw/tools/error.ex` acts only on atom `:status`). A naive collapse to one field would drop it.
- `data` is already JSON-safe (it's `Jason.encode!`'d on every call today), so JSON serialization is faithful
  with no new crash surface.
- `data` arrives at the shaper already redacted (`OutputRedaction`, `output_redaction.ex:11,18-31`) but **not
  ANSI-stripped**. Because `Jason.encode!` escapes `ESC` as ``, stripping ANSI *after* serialization is a
  dead no-op — an ANSI-split secret would survive into stored content and the model-facing body. So ANSI must be
  stripped *before* redaction, at the source. We fix this at the **root in `OutputRedaction`** (decided in
  review) — closing the leak for every tool and every path (incl. under-cap MCP passthrough) and letting the
  shaping path consume already-clean data.

## Part A — ANSI redaction hardening (root fix)

1. **New module** `lib/jido_claw/security/redaction/ansi.ex` — `JidoClaw.Security.Redaction.Ansi` holding the
   three ANSI regexes (`@ansi_csi`/`@ansi_osc`/`@ansi_two_byte`) and `strip/1`, **moved verbatim from**
   `OutputShaper` (`output_shaper.ex:61-66,498-505`). Pure leaf module, no deps → no cycle; `tools→security`
   is unconstrained by `.reach.exs` (which only guards web/data layers).

2. **`lib/jido_claw/tools/output_redaction.ex`** — add `Ansi` to the existing
   `alias JidoClaw.Security.Redaction.{Env, Patterns}`, then strip ANSI before **both** value redaction and key
   classification (finding #3 — an ANSI-split *key* like `"api_\e[0mkey"` otherwise dodges `sensitive_key?/1` and
   its value leaks):
   - binary value clause (`output_redaction.ex:18`): `Patterns.redact(value)` → `value |> Ansi.strip() |> Patterns.redact()`.
   - `sensitive_key?/1` (`:48,:54`) and `binary_payload_key?/1` (`:57,:63`) classify through a new private
     `classified_key/1` covering **both** key types (`is_atom → Atom.to_string |> Ansi.strip`; `is_binary →
     Ansi.strip`) **without mutating the emitted key** (the `Map.new` at `:21` keeps the original) — so an
     ANSI-split key can't dodge classification (atoms only defensively; they come from code, not external JSON).
   (Stripping ANSI from LLM/tool-bound text is benign — the model doesn't render ANSI.) The 3 `redact/1` callers
   (`action.ex:61` result path, `search_web.ex:43` + `proxy_generator.ex:241` outbound arg scrubs) are all benign;
   the outbound mutation is made intentional via a test (finding #4).

3. **`lib/jido_claw/tools/output_shaper.ex`** — drop the local `strip_ansi/1` + the 3 regex module attrs;
   alias `Ansi`; in `shape_text/6` use `Ansi.strip(text)` (kept as belt-and-suspenders; now redundant with the
   upstream pass but harmless). Update the test comment at `output_shaper_test.exs:341-343` whose premise
   ("upstream OutputRedaction misses the split key") is now false — the secret is caught upstream.

## Part B — Generic MCP shaping (inside `OutputShaper`)

Fully contained to `OutputShaper`: `action.ex:62` already calls `OutputShaper.shape_result(result,
@jidoclaw_tool_name, params, ctx)` for every tool, and a proxy's name is `mcp_<server>_<tool>`. Approach is
**collapse-and-extract**: above the inline cap, serialize → store full (capture-capped) → return a fresh
wrapper with a bounded `:output` body, **lifting `isError` so the failure signal survives**. Below the cap the
full structured result passes through untouched.

1. **Predicate `mcp_shapeable?/2`** (public, `@doc`+`@spec`, beside `shapeable?/3`), fail-closed like
   `shapeable?/3`:
   ```elixir
   def mcp_shapeable?(tool_name, context) when is_binary(tool_name),
     do: enabled?() and String.starts_with?(tool_name, "mcp_") and tenant_present?(context)
   def mcp_shapeable?(_tool_name, _context), do: false
   ```
   Leave `shapeable?/3` (native allowlist + capture-sizing contract, called by `run_command.ex`) untouched.

2. **Route in `shape_result/4`** — `cond`: native `shapeable?/3` → `safe_shape`; else `mcp_shapeable?/2` →
   `safe_shape_mcp`; else passthrough.

3. **`safe_shape_mcp/3`** — rescued like `safe_shape/4` (file already has `# reach:disable-for-this-file
   bare_rescue`; on fault → log + `emit_error_trace` + return original ⟹ degrades to today's behavior).
   `do_shape_mcp/3` dispatches `{:ok, data}` / `{:ok, data, effects}` (effects preserved) to
   `shape_mcp_payload/3`; anything else passes through.

4. **`shape_mcp_payload/3`** — the core (order matters: shape decision on the **original** serialized size,
   storage cap applied **inside** the shape branch — findings #1 & #2):
   - `{encodability, serialized} = mcp_serialize(data)` — `data` arrives ANSI-clean + redacted (Part A), so
     **no per-leaf cleaning needed**. `is_binary` → `{:encodable, data}` **only when `String.valid?(data)`** (a
     non-UTF-8 binary would otherwise pass through and later fail jido_ai's `Jason.encode!`), else the
     `:unencodable` inspect branch; non-binary → `Jason.encode(data, pretty: true)` → `{:ok, j}` ⟹
     `{:encodable, j}`, `{:error, _}` ⟹ `{:unencodable, inspect(data, pretty: true, limit: :infinity,
     printable_limit: :infinity)}`.
   - **Trigger: unencodable OR over the inline cap** (findings #1 & #3-followup): `if encodability == :unencodable
     or byte_size(serialized) > OutputLimit.max_bytes()` → shape, else return original `data`. Two reasons,
     one condition: keying the *size* test on `serialized` (not the capped size) stops a `capture_bytes`
     misconfigured *below* the inline cap from letting a huge payload cap small, skip shaping, and fall back to
     `OutputLimit`'s ref-less cut; and force-wrapping `:unencodable` data (data is JSON-safe today, so this is
     defensive) prevents a passthrough of non-encodable `data` from later crashing jido_ai's `Jason.encode!`
     (`turn.ex:818`) — instead it collapses to a JSON-safe `inspect`-based `:output` wrapper.
   - **Tail-preserving capture cap** (finding #2): `{clean, truncated?} = cap_capture(serialized)` =
     `Generic.fit(serialized, capture_bytes())` (default 512KB, `output_shaper.ex:102`): `{:ok, fitted}` →
     `{fitted, true}` (head+**tail** elision, so the errors-at-the-tail survive in storage — MCP already holds the
     full payload in memory, unlike `run_command`'s streamed prefix cap), `:nocompress` → `{serialized, false}`.
     Keeps `ToolOutput.content` (no DB size constraint) bounded ≤ `capture_bytes`.
   - **Shape:** `body = mcp_head_tail(clean)` (`Generic.head_tail(clean, generic_head_bytes(),
     generic_tail_bytes())` → body, or `clean` on `:nocompress`), then **reuse `finish_shape/6`**:
     ```elixir
     finish_shape(
       put_present(%{}, "isError", mcp_is_error(data)),  # fresh map; "isError" string key = same spelling as
       :output,                                          # normal results (finding #3); collision-free
       %{text: serialized, clean: clean, body: body, summary: nil, format: :mcp, truncated?: truncated?},
       tool, %{}, ctx)
     ```
     Verified `finish_shape` is generic for a non-native tool + `%{}` params/base: `command_for`/`delta_line`
     return nil/`""`, `exit_code_of(%{...})` → nil, footer honors `truncated?`, it stores `clean`, bounds `body`
     to the cap via `Generic.fit/2`, emits telemetry/trace (`format: :mcp`), and returns
     `%{"isError" => v, output: body<>footer, shaped: true, captured_bytes: byte_size(clean), truncated: ?,
     output_ref: ref}`. No new result-map shape, no duplicated store/footer/fit/emit ⟹ no `reach --smells`
     `fixed_shape_map`, `credo` long-function, or dead-branch risk.

5. **Helpers**: `mcp_serialize/1` (→ `{:encodable | :unencodable, binary}`); `cap_capture/1` (= `Generic.fit/2`
   against `capture_bytes()`, tail-preserving); `mcp_head_tail/1` (= `Generic.head_tail/3`, or `clean` on
   `:nocompress`); `mcp_is_error/1` (`%{"isError" => v} when is_boolean(v) -> v; _ -> nil`). `finish_shape`'s own
   `Generic.fit(body, max_bytes - footer)` still guarantees the final `:output` ≤ the inline cap for any
   `capture_bytes`/`max_bytes` combination.

6. **Footer wording** (shared-helper tweak): generalize `footer_line(ref, bytes, true)` (`output_shaper.ex:523-525`)
   from `"captured output (upstream-truncated)"` to `"captured output (truncated)"` — for MCP the cap happens
   *inside* the shaper, not upstream, and the word is accurate for both paths. The footer text is not parsed
   anywhere (`upstream_truncated?/1` keys on `SessionManager.truncation_note`, a different string), so this is
   wording-only; update the native assertion at `output_shaper_test.exs:376`.

### Key decisions (settled in review)

- **Collapse + lift `isError`**, not full structure preservation: for >32KB results inline structure is
  unusable anyway and recoverable via the ref; collapse bounds untrusted external output to the cap
  (threat-model aligned), is collision-proof (fresh all-atom-key wrapper + the one `"isError"` string key), and
  reuses `finish_shape`. Lifting the spec-standard `isError` is the sole format-aware concession.
- **Pretty JSON throughout** (finding #5): best for `fetch_output` readability; the trigger is therefore
  **deliberately conservative** (pretty inflates size vs. the compact JSON jido_ai sends) — documented, not
  fixed, since over-collapsing only bounds context more.
- **Shape on original size; cap storage tail-preserving** (findings #1, #2): the shape decision keys on the full
  serialized size (robust to a `capture_bytes < max_bytes` misconfig), and the `capture_bytes` storage ceiling uses
  head+tail elision (`Generic.fit`) so errors at the tail survive — MCP has the full payload in memory.
- **Reuse, don't fork** `finish_shape` — the single biggest lever for staying lint-clean.

## Tests

Run as `mise exec -- mix` (mise-latest toolchain). Approval gate + shaping are `enabled?: false` in
`config/test.exs`, so MCP tests call `enable_shaping/1` (the disabled gate lets the echo result reach the shaper).

- **`test/jido_claw/security/redaction/ansi_test.exs`** (new) — `Ansi.strip/1` over CSI / OSC / two-byte
  sequences (mirrors `output_shaper/generic_test.exs` style).
- **`test/jido_claw/tools/output_redaction_test.exs`** — add: (a) an ANSI-split secret *value*
  (`"sk-ant-\e[0m" <> 24-char tail`) reassembled + redacted by `redact/1`; (b) benign ANSI stripped from values;
  (c) **ANSI-split sensitive *key*** (finding #3) — `redact(%{"api_\e[0mkey" => "plain-value"})` redacts the value
  to `"[REDACTED]"` while leaving the emitted key unmutated.
- **`test/jido_claw/tools/output_shaper_test.exs`** — new `describe "external MCP generic shaping"` with an
  inline `McpEcho` (`use JidoClaw.Tools.Action, name: "mcp_test_echo"`), reusing `enable_shaping/1`,
  `cap_output_bytes/1`, `scope/0`, `seed_full`, `actor_for`:
  - oversized map (`%{"content"=>[%{"text"=>big}], "isError"=>true}`, pretty-serialized > cap) → `shaped`,
    `output_ref =~ ~r/^out_/`, `byte_size(output) <= cap`, `output =~ "... [elided"`, ends with the footer,
    refute `"[tool output truncated"`, `result["isError"] == true`, `captured_bytes > 0`, `truncated == false`;
    `Jason.encode!(result)` does not raise; `ToolOutput.by_ref` round-trips (`content` has the text's tail,
    `tool == "mcp_test_echo"`, `command == nil`, `command_fingerprint == nil`).
  - **payload > `capture_bytes`, tail preserved** (findings #1 & #2): `cap_output_bytes(4096)` +
    `enable_shaping(capture_bytes: 8192)`, text `"HEAD_SENTINEL" <> filler <> "TAIL_SENTINEL"` serializing > 8192 →
    `truncated == true`, footer `=~ "captured output (truncated)"`, `byte_size(row.content) <= 8192`,
    **`row.content =~ "TAIL_SENTINEL"`** (tail survives the cap), `row.content =~ "... [elided"`.
  - **`capture_bytes < max_bytes` misconfig** (finding #1): `cap_output_bytes(4096)` + `enable_shaping(capture_bytes: 1024)`,
    `byte_size(serialized) > 4096` → still **shaped** (not passthrough to `OutputLimit`), `byte_size(output) <= 4096`.
  - under-cap → **structured passthrough** (`result == data`, incl. `"isError"`/`"content"`, no `:shaped`). Word
    the test precisely (finding #4): identity is *shaper-relative* — the shaper is a no-op on its already
    OutputRedaction-processed (ANSI-stripped/redacted) input — NOT raw-tool-output identity, which Part A
    intentionally mutates upstream.
  - **unencodable `data`** (finding #3-followup): both a non-JSON term (e.g. a bare tuple/PID) **and a non-UTF-8
    binary under the cap** → force-shaped regardless of size into a wrapper whose `Jason.encode!/1` does not raise
    (proves the jido_ai crash is averted); `output_ref` round-trips the `inspect`-rendered content.
  - many small fields summing past the cap → collapses (pins the conservative total trigger as intended).
  - no tenant → passthrough; `{:error,_}` passthrough; `{:ok, data, effects}` preserves effects.
  - store failure (sessionless ctx w/ bogus `session_uuid`) → no `output_ref`, `"(full output unavailable)"`,
    still bounded `<= cap`, refute `"[tool output truncated"`.
  - bare-binary `data` > cap → shaped + ref + round-trip (no `"isError"` key).
  - disabled config → byte-identical passthrough.
  - **ANSI-split secret under the cap** (finding #2 / user test): small MCP result whose raw text holds an
    ANSI-split secret → redacted (proves Part A closes the under-cap path, passthrough now safe).
  - `mcp_shapeable?/2` table: true `"mcp_x_y"`+tenant+enabled; false for native/non-`mcp_`/`"mcpfoo"`/no-tenant/
    disabled/**non-binary tool name** (fail-closed, finding #4).
  - `"isError"` spelling: `false` preserved; absent → no `"isError"` key.
  - **generated-proxy integration** (user asks): build a proxy via `ProxyGenerator.build_modules/3` backed by a
    `JidoClaw.MCP.Client` stub (mirror `test/jido_claw/mcp/proxy_generator_test.exs`) that **records its `call_tool`
    args**. Run it through the pipeline with tenant context and assert (a) an oversized inbound result is shaped +
    round-trips (not only the inline echo); (b) **outbound ANSI is stripped** — params with an ANSI-laden arg reach
    the stub scrubbed (finding #4, documenting the intentional outbound mutation).

## Docs to update

- `OutputShaper` moduledoc + the `@shapeable_tools` comment — describe the parallel generic `mcp_` path
  (collapse-above-cap, capture-capped storage, `isError` lifted, conservative pretty-JSON trigger).
- `AGENTS.md` — the "Output Shaping" bullet's "`run_command`/`git_diff`-only" claims and the "External MCP Tool
  Consumption" bullet's "NOT format-shaped/`fetch_output`-stored" claim; note the global ANSI-strip in
  `OutputRedaction`.
- `docs/exploration/jidoka/FEATURES-WORTH-BORROWING-V2.md` — flip the V2-2 "generic MCP output shaping"
  deferral to shipped (dated 2026-06-17), noting the `OutputRedaction` ANSI hardening folded in.

## Verification

Toolchain: `mise exec -- mix`. Run gate commands **bare** (never piped to `tail` — a pipe masks the exit code).

1. `mise exec -- mix test test/jido_claw/security/redaction/ansi_test.exs test/jido_claw/tools/output_redaction_test.exs test/jido_claw/tools/output_shaper_test.exs`.
2. `mise exec -- mix test test/jido_claw/tools/ test/jido_claw/mcp/` — neighbouring suites; **confirms no tool
   relied on ANSI codes reaching the model** (the Part-A blast-radius check).
3. **`mise exec -- mix precommit`** — the completion bar: `jidoclaw.compile_check` (zero warnings + allowlist),
   `reach.check --arch --smells --strict`, `credo --strict`, `dialyzer`, full suite. Run in background, read the
   output tail. (The Stop hook's separate `compile --warnings-as-errors` always fails on the two intentional
   `pull_request_coordinator` warnings — not this change; `compile_check`/`precommit` are the real gates.)
4. Optional Tidewave `project_eval`: drive an `mcp_`-named echo with an oversized map; confirm the
   `%{"isError"=>_, output:, shaped: true, output_ref:}` wrapper + a `ToolOutput.by_ref` round-trip.

## Out of scope (deliberate)

- Structure-preserving per-leaf shaping (collapse is simpler/lint-clean/context-bounding; structure recoverable
  via ref); format-aware MCP `content[].text` extraction (stays generic; only `isError` lifted).
- Other V2-2 deferrals: reconnect/re-discovery, per-tool approval overlay, per-tool allowlist granularity.
