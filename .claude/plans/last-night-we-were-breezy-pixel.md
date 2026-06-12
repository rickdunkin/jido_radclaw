# OutputShaper: token-efficient tool output with reversible full-output storage

## Context

Verbose command output (`mix test`, `mix compile`, `git diff`) is the biggest avoidable burn on agent context. Today's caps are blind **head** truncations — `Shell.SessionManager` caps `run_command` output at 10KB head-keep, `git_diff` slices at 15KB head-keep, `OutputLimit` backstops at 32KB head-keep. For test/build output the signal (failures, summary) lives at the **tail**, so the current caps keep the noise and drop the signal. This is the rtk critique, adapted to JidoClaw's advantage: because JidoClaw owns tool dispatch *and* persistence, shaping can be format-aware **and reversible** (the captured output — complete up to the 512KB capture cap, flagged `truncated` beyond it — stored under a ref, retrievable via a new `fetch_output` tool) — something an external proxy like rtk structurally cannot do. Shaped output also compounds with the existing context Compactor: slower context growth means later, rarer compaction.

Rule that keeps it safe: **compress the green, never the red** — success noise becomes counts; error detail stays verbatim.

## Verified architecture facts

- Every tool wraps `run/2` via `JidoClaw.Tools.Action.__before_compile__` (`lib/jido_claw/tools/action.ex:36-44`): `MCPScope.wrap → super → Error.normalize_result → OutputRedaction.redact_result → OutputLimit.truncate_result`. The shaper inserts between redaction and the cap — redaction must see the full original (shaping is a form of truncation), and `OutputLimit` stays as dumb backstop. `@jidoclaw_tool_name` (a **string**, e.g. `"run_command"`), `params`, and `enriched_context` are all in scope in the generated code.
- `Error.normalize_result/1` runs first and converts `{:ok, %{status: :failed}}` → `{:error, ...}`, so the shaper sees a clean ok/error split. It must pass `{:error, _}` / `{:error, _, effects}` through untouched and handle both `{:ok, map}` and `{:ok, map, effects}`.
- **Critical constraint**: `run_command` output is pre-truncated to 10KB inside `SessionManager.finalize_output/2` (`lib/jido_claw/shell/session_manager.ex:1434-1452`, `@max_output_chars 10_000` at line 43) — the full bytes accumulate in `acc` and are discarded. The shaper can only see full output if RunCommand requests a larger capture. Backend runaway guards sit far above 512KB (host non-streaming 10MB; SSH non-streaming valve `@max_ssh_output_bytes 1_000_000`), so a 512KB capture needs no guard changes.
- `run_command` success shape is `{:ok, %{output: string, exit_code: int}}`; its `output_schema` requires `output: :string` + `exit_code: :integer`; unknown extra keys pass through. The whole map is `Jason.encode!`-ed into `{"ok":true,"result":{...}}` for the LLM (`Jido.AI.Turn.format_tool_result_content/1`).
- `tool_context` (in `enriched_context`) carries `tenant_id`, `session_uuid` (UUID FK → `Conversations.Session`), `agent_id`, `project_dir`, `actor`, etc. (`lib/jido_claw/tool_context.ex:42-54`). Under MCP serve-mode `MCPScope.Initializer` attempts to resolve a Session, so `session_uuid` is normally present but can be nil when that fails.
- No blob/ref store exists; no ExUnit/compiler parser exists anywhere — both net-new. Resource template: `JidoClaw.Conversations.Session` (`lib/jido_claw/conversations/resources/session.ex`) for tenant boilerplate; `Forge.Resources.ExecSession` for the output+byte-count shape. Best-effort persistence pattern: `Compactor.Storage` + `SubagentTranscript`'s `actor || Actor.system(tenant_id)` (`subagent_transcript.ex:148`; `Actor.system/1` exists at `authorization/actor.ex:33`).
- `OutputLimit.valid_utf8_prefix/1` is public — reusable for clean head cuts.
- Trace collector already attaches `[:jido_claw, :output, :event]` with `event_name_label(:output, ...)` falling back to `metadata.name` — zero collector wiring needed for a shaping Trace event.
- Config convention: `config :jido_claw, :workflow_recovery, enabled?: true` (config.exs:195) overridden `false` in test.exs:16. Marker-conformance tests (`output_redaction_test.exs:71-89`) iterate `JidoClaw.Agent.tool_modules()` — any tool built with `use JidoClaw.Tools.Action` passes automatically.

## Decisions

| Decision | Choice | Why |
|---|---|---|
| Ship shaping without the ref store? | **No** — ref store + `fetch_output` are part of Phase 1 | Shaping drops detail; without a retrieval path the agent re-runs commands and the savings evaporate. Reversibility is the safety property. |
| Default on/off | `enabled?: true` in config.exs, `false` in test.exs | Benefit by default with a kill switch; existing 10KB-truncation tests stay green; shaping tests opt in via `Application.put_env` + `on_exit` restore. |
| Shaped result shape | `output` stays a compact **string**; add sibling keys `shaped`, `output_ref`, `captured_bytes`, `truncated`, `summary` | Preserves the `output_schema` contract; extra keys pass through; JSON envelope makes string-vs-struct cosmetic for the LLM. |
| SessionManager plumbing | Thread one explicit `capture` integer arg through the collect/finalize chain, sourced from a `:capture_bytes` opt | Surgical; byte-identical behavior when the opt is absent. |
| Allowlist dispatch | Shaper acts only on tool names `"run_command"` (P1) and `"git_diff"` (P2); everything else passes through | Recursion guard (never shapes `fetch_output`), zero blast radius on read_file/search_code/etc. |
| Streamed runs | Shaper passes through on **effective** streaming (`OutputShaper.effective_streaming?/1` — requested AND not MCP serve-mode); no ref stored | User saw the live stream; the 50KB preview is already bounded; storing a preview as "full output" would mislead. Raw-param checks would wrongly skip shaping for MCP callers whose streaming request gets dropped. |
| Reversibility degradation | No tenant (deterministically unstorable) ⇒ **pass through, don't shape**; transient store failure ⇒ shaped-without-ref, the one documented exception | If storage can never happen, shaping would always violate the safety rule. On a one-off failure, the shaped body still carries the red verbatim — passing 512KB through would let OutputLimit's 32KB head-cut drop the failures at the tail, which is worse. |
| Retention | Best-effort prune-on-insert (delete rows older than `ref_ttl_days` for the tenant, fully rescued) | No new process or cron wiring; co-located with the write. |
| Command fingerprint | Local `sha256(downcase/trim/collapse-ws(command))` helper over the **raw** command; column stored from Phase 1, delta line lands Phase 2 | Decoupled from `Solutions.Fingerprint`'s description/language shape; hashing raw keeps fingerprints stable; historical rows comparable when delta lights up. |
| Re-redact after ANSI strip; redact the stored `command` | Shaper runs `Patterns.redact/1` on the ANSI-stripped text and on `params.command` before storing | ANSI escapes can interrupt a secret so `OutputRedaction` misses it; stripping reassembles it. And `params` never pass through result redaction, so a `curl -H "Authorization: …"` command would otherwise land in the DB verbatim. |
| Telemetry | `counter("jido_claw.tool.shaping.total")` + `sum("jido_claw.tool.shaping.bytes_saved")` on one event `[:jido_claw, :tool, :shaping]`; Trace event via existing `:output` category | Metric name's last segment is the measurement, so both metrics hang off the same event with measurements `%{total: 1, bytes_saved: n}`; zero collector changes. |

---

## Phase 1 — shaper + mix-test filter + generic fallback + ref store + fetch_output

### 1. Config — `config/config.exs` + `config/test.exs`

After the `:workflow_recovery` block (config.exs:195):

```elixir
config :jido_claw, :output_shaping,
  enabled?: true,
  min_shape_bytes: 2_048,          # outputs smaller than this pass through untouched
  capture_bytes: 512 * 1024,       # SessionManager capture when shaping on (non-streaming)
  ref_ttl_days: 7,
  failures_budget_bytes: 24 * 1024, # verbatim failure blocks budget; remainder counted
  generic_head_bytes: 2_048,
  generic_tail_bytes: 4_096
```

No `store_refs?` knob: reversibility is part of shaping, not an option — shaping that drops detail without a retrieval path would violate the safety rule, so `enabled?` is the single kill switch and storage is always attempted when the shaper acts (best-effort degradation on failure still applies).

In `config/test.exs` (near the `:workflow_recovery` override): `config :jido_claw, :output_shaping, enabled?: false`.

### 2. ToolOutput resource + migration (consult the **ash-framework skill** first)

**New** `lib/jido_claw/conversations/resources/tool_output.ex` — `JidoClaw.Conversations.ToolOutput`, table `tool_outputs`. Mirror `Conversations.Session`'s boilerplate exactly (`use JidoClaw.Resource, domain: JidoClaw.Conversations`, attribute-strategy multitenancy on a plain `tenant_id` **string** attribute — no `belongs_to :tenant`).

- Attributes: `uuid_primary_key :id`; `ref` (string, required); `tenant_id` (string, required, **not in `accept`** — set via the `tenant:` option per local Ash convention, see `test/support/jido_claw/tenant_case.ex`); nullable `belongs_to :session, JidoClaw.Conversations.Session` (`attribute_writable?: true` — nil when MCP session resolution failed) with a `before_action` check that a present session's `tenant_id` matches the row's tenant (mirrors Session's workspace check); `command_fingerprint` (string, nullable); `tool` (string, required); `command` (string, nullable, **stored pre-redacted**); `content` (string, required, **`public?: false`** like ExecSession's `output`); `byte_size` (integer); `truncated` (boolean, default false — upstream capture cap hit, content is *captured* not *full*); `exit_code` (integer, nullable); `summary` (map, nullable — lean parsed structure for the Phase 2 delta); `timestamps()`.
- Identity `unique_ref` on `(tenant_id, ref)`; custom indexes `(tenant_id, session_id, command_fingerprint)` and `(tenant_id, inserted_at)`.
- Actions + code_interface: `create :store` (primary); `read :by_ref` (get?, arg `ref`); `read :latest_for_fingerprint` (get?, args `session_id` + `command_fingerprint` + `tool`, sort `inserted_at: :desc`, limit 1 — filtering on `tool` keeps comparisons within one tool once `git_diff` joins the store in P2); an `:expired` read (filter `inserted_at < ^arg(:cutoff)`) feeding `Ash.bulk_destroy` for pruning — copy the expired-sweep shape from `lib/jido_claw/conversations/resources/request_correlation.ex:280`; **and the `read :by_id_global` action** (get by id, `multitenancy(:bypass)`) — `use JidoClaw.Resource` injects a policy bypass that references it and the module fails to compile without it (see the warning in `lib/jido_claw/orchestration/workflow_event.ex:8` and `lib/jido_claw/resource.ex:55`).

**Modify** `lib/jido_claw/conversations/domain.ex` — add `resource(JidoClaw.Conversations.ToolOutput)`.

**Migration**: `mix ash.codegen add_tool_output_store` → review generated migration in `priv/repo/migrations/`.

### 3. Store boundary — new `lib/jido_claw/tools/output_shaper/store.ex`

`JidoClaw.Tools.OutputShaper.Store.put(attrs, tool_context) :: {:ok, ref} | :error` — the best-effort persistence seam (pattern: `Compactor.Storage` + `SubagentTranscript`):

- Asserts `tool_context[:tenant_id]` is present — but tenant absence is handled **upstream** as an OutputShaper pass-through guard (see §5), so `Store.put` only ever runs when storage is possible; a missing tenant here is a defensive `:error`, not an expected path.
- `actor = tool_context[:actor] || JidoClaw.Authorization.Actor.system(tenant_id)`; `session_id = tool_context[:session_uuid]` (the UUID, **not** the string `:session_id`). Call as `ToolOutput.store(attrs, tenant: tenant_id, actor: actor)` — tenant threads via the `tenant:` option, never as an accepted attribute.
- `command` is redacted with `JidoClaw.Security.Redaction.Patterns.redact/1` before storing (params bypass result redaction); the fingerprint is computed on the raw command before redaction.
- `ref = "out_" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)`; retry once on unique-violation.
- After a successful insert, best-effort prune rows older than `ref_ttl_days` for this tenant via the `:expired` read + `Ash.bulk_destroy` (the `request_correlation.ex:280` sweep shape; fully rescued — a prune failure never fails the store).
- Whole function wrapped in `try/rescue`: log warning + `JidoClaw.Trace.emit(:output, %{event: :error, ...})`, return `:error`. Storage must never block the tool result.

### 4. Parsers (pure modules, no DB)

**New** `lib/jido_claw/tools/output_shaper/mix_test.ex` — `parse(text) :: {:ok, %{body, summary, compressed?}} | :nomatch`:
- Find the ExUnit summary line (`N tests, M failures` + variants: doctests, invalid, skipped, excluded), `Finished in …`, seed line. Capture failure blocks (`~r/^\s{0,2}\d+\) /m` … up to next block/summary) **verbatim**, up to `failures_budget_bytes`; beyond that, a "…and N more failures" count line (ref-free — the footer carries the ref).
- Compose: one summary header line, blank line, verbatim failure blocks. **Body only — no ref hint**: the ref doesn't exist until `Store.put/2` succeeds, so parsers return `%{body, summary, compressed?: bool}` and `OutputShaper` appends the single footer line afterwards (ref hint on store success, "(full output unavailable)" on failure).
- `summary` map: `%{passed, failed, skipped, invalid, failures: [%{test, location, error}], finished_in, seed}` — **lean by design**: `error` is the first line only. The verbatim blocks live solely in `output`; the whole result map is JSON-encoded for the LLM, so duplicating block text in `summary` would pay for every failure twice. Lean identifiers are also all the Phase 2 delta comparison needs.
- Return `:nomatch` (→ generic fallback) when: no summary line (input was upstream-truncated — also detect existing truncation markers), or `failures > 0` but zero blocks parsed. Never claim green when red was unparseable.

**New** `lib/jido_claw/tools/output_shaper/generic.ex` — `head_tail(text, head_bytes, tail_bytes)`:
- Below `head + tail` → signal no-compress (caller passes original through).
- Else `head <> "\n\n... [elided N bytes] ...\n\n" <> tail`, both cuts UTF-8-safe (reuse `OutputLimit.valid_utf8_prefix/1` for the head; add a suffix analog). The elision marker is **ref-free** — the shaper appends the ref footer after storage resolves, same as the mix_test path. Strictly better than today's head-only for logs — keeps the tail where errors live.

ANSI: a small `strip_ansi/1` helper (CSI + OSC regexes) applied before parsing **and** before storage (cleaner `fetch_output` grep). **Security-critical follow-up**: ANSI escapes can sit *inside* a secret (`sk-\e[0mabc…`), so the upstream `OutputRedaction` pass may have missed it and stripping reassembles it — always re-run `Patterns.redact/1` on the stripped text before it is parsed, shaped, or stored.

### 5. OutputShaper stage — new `lib/jido_claw/tools/output_shaper.ex`

`JidoClaw.Tools.OutputShaper.shape_result(result, tool_name, params, enriched_context) :: result`

Pass-through guards (return input unchanged), centered on one public predicate **`shapeable?(tool_name, params, context)`** combining: enabled?; tool in `~w(run_command)` (P2 adds `git_diff`); not **effective** streaming (own helper `effective_streaming?/1` — not the raw param: under MCP serve-mode the streaming request is dropped, so a `stream_to_display: true` MCP call must still be captured and shaped); and `tenant_id` present in `tool_context` (without it storage is deterministically impossible, so shaping would always violate reversibility). RunCommand uses the **same predicate** for its capture decision (§7), so capture and shaping can never disagree. Result-dependent guards on top: `{:error, _}` / `{:error, _, effects}` untouched; text field below `min_shape_bytes`.

For `{:ok, %{output: text} = map}` (and 3-tuple, preserving `effects`):
1. `clean = text |> strip_ansi() |> Patterns.redact()` — the re-redaction is mandatory (see §4); also detect upstream truncation with **exact suffix matches** against the known markers, not a substring scan (real output could contain the phrase): `String.ends_with?` on SessionManager's truncation notes, or an anchored regex for OutputLimit's `[tool output truncated: original N bytes, cap M bytes]` suffix. **Centralize the marker strings**: SessionManager owns them, so promote its note literals to public doc-false helpers (e.g. `SessionManager.truncation_note(streaming?)`) used both by `finalize_output/3` and the shaper's detection — marker-text drift then breaks at one definition site instead of silently disabling `truncated?`.
2. `detect_format(params[:command])` → `:mix_test | :generic` (P1). Detection regex tolerates env-var prefixes: `~r/^\s*(\w+=\S+\s+)*mix\s+test\b/`.
3. Run parser; `:nomatch` → generic head+tail; if the body doesn't actually compress, pass original through (telemetry `bytes_saved: 0`).
4. `Store.put` the full `clean` text (+ `tool`, redacted `command`, `command_fingerprint` of the raw command, `exit_code`, `byte_size`, `truncated`, lean `summary`) → ref or `:error`.
5. Append the footer to the parser body **after** storage resolves (parsers are ref-unaware): on success `"[full output: N bytes — fetch_output ref=out_…]"`, or `"[captured output (upstream-truncated): N bytes — fetch_output ref=out_…]"` when `truncated?` (the ref holds what was captured, which above `capture_bytes` is not everything); on **transient** store failure `"(full output unavailable)"` so the LLM can't hallucinate a ref. That failure path is **the single documented best-effort exception** to reversibility: the shaped body still carries the failures verbatim, whereas passing the 512KB capture through would let OutputLimit's 32KB head-cut drop them at the tail — strictly worse. (Deterministic unstorability — no tenant — never reaches here; it's a §5 pass-through guard.) Build the shaped map: `%{output: body <> footer, exit_code: exit_code, shaped: true, captured_bytes: n, truncated: truncated?, output_ref: ref_or_absent, summary: summary}`.
6. Emit telemetry (step 8).

Public config accessors mirroring `OutputLimit.max_bytes/0`: `enabled?/0`, `capture_bytes/0`, etc. (read `Application.get_env(:jido_claw, :output_shaping, [])` per call). Entire `shape_result/4` body wrapped in `try/rescue` → log + Trace error event + **return original result**. Shaped run_command text example:

```
mix test — 311 passed, 2 failed (Finished in 4.2s, seed 12345)

  1) test handles nil (MyApp.FooTest)
     ** (MatchError) no match of right hand side value: nil
     test/foo_test.exs:42

[full output: 184320 bytes — fetch_output ref=out_a1b2c3d4e5f6]
```

### 6. Pipeline insertion — modify `lib/jido_claw/tools/action.ex`

In `__before_compile__` (line 38-43), add the alias and one stage:

```elixir
super(params, enriched_context)
|> Error.normalize_result()
|> OutputRedaction.redact_result()
|> OutputShaper.shape_result(@jidoclaw_tool_name, params, enriched_context)
|> OutputLimit.truncate_result()
```

Ordering is load-bearing: redact (must see the full original) → shape (semantic compression) → cap (dumb backstop).

### 7. Capture plumbing — modify `session_manager.ex` + `run_command.ex`

**SessionManager**: thread an explicit `capture` integer (default = current behavior) through the chain: `execute_command/5` (line 1199) and `execute_ssh_command/6` (line 1312, `_opts` becomes used) compute `capture = Keyword.get(opts, :capture_bytes) || legacy_cap(streaming?)`, then pass through `collect_output/3→4`, `do_collect/5→6`, `collect_ssh_output/4→5`, `do_collect_ssh/6→7`, `ok_output/3→4`, `output_limit_error/3→4`, into `finalize_output(acc, streaming?, capture)` (line 1434) which uses `capture` as the cap instead of the hardcoded constants. Truncation note text still keyed on `streaming?`, unchanged. Document `:capture_bytes` in the `run/4` docstring opts list (line 99-106). No opt ⇒ byte-identical to today.

**RunCommand**: the streaming/shapeability helpers live on **`OutputShaper`** (`effective_streaming?(params)` reads `stream_to_display` under both atom and string keys AND `Application.get_env(:jido_claw, :serve_mode) != :mcp`; `shapeable?/3` builds on it — see §5) so the dependency stays one-way: RunCommand already calls `OutputShaper.capture_bytes/0`, and having the shaper call back into RunCommand would risk a compile-dependency cycle. RunCommand uses `effective_streaming?/1` to replace the inline drop logic in `maybe_put_streaming/3` (run_command.ex:178-192). The capture decision must use the **full** `shapeable?("run_command", params, enriched)` predicate — computed once in `run/2` where `enriched` is in scope, threaded as a flag into `dispatch_opts`, and applied where opts are built (lines 139-144, 161-164) as `capture_bytes: OutputShaper.capture_bytes()`. Gating capture on anything weaker breaks: a no-tenant call with only an enabled?+non-streaming check would capture 512KB, skip shaping, and land on OutputLimit's 32KB head-cut instead of the legacy 10KB behavior. The shared predicate also closes the MCP edge: an MCP caller passing `stream_to_display: true` gets no stream (dropped as today) but full capture + shaping instead of silently falling back to the legacy 10KB head-truncation.

### 8. Telemetry — modify `lib/jido_claw/core/telemetry.ex`

- `metrics/0` (tool section, ~line 41): add `sum("jido_claw.tool.shaping.bytes_saved", tags: [:tool])` and `counter("jido_claw.tool.shaping.total", tags: [:tool, :format])` — both derive from the **same event** `[:jido_claw, :tool, :shaping]` (Telemetry.Metrics treats the name's last segment as the measurement), so one execute serves both.
- New helper `emit_shaping(tool, format, bytes_saved)` → `:telemetry.execute([:jido_claw, :tool, :shaping], %{bytes_saved: bytes_saved, total: 1}, %{tool: tool, format: format})`.
- From the shaper also `JidoClaw.Trace.emit(:output, %{event: :shaped, name: tool, format: fmt, ref: ref}, %{bytes_saved: n, captured_bytes: c, shaped_bytes: s})` — `captured_bytes` consistently everywhere (it's what the shaper received, not a pre-capture original); `:output` category already attached and labeled (collector.ex:104, 426); arg order is `(category, metadata, measurements)`.

### 9. fetch_output tool — new `lib/jido_claw/tools/fetch_output.ex`

`JidoClaw.Tools.FetchOutput`, `use JidoClaw.Tools.Action, name: "fetch_output"` (markers/pipeline come free; the allowlist keeps the shaper off its results; OutputLimit backstops a greedy fetch at 32KB).

- `schema`: `ref` (string, required); `grep` (string regex — compiled with `Regex.compile/1`, an invalid pattern returns a clean `{:error, "invalid grep regex: …"}` rather than raising); `tail` (int lines); `head` (int lines); `offset` (int, default 0) + `limit` (int, default 2000) line window mirroring read_file. Document precedence in the descriptions: grep > tail > head > offset/limit.
- `output_schema`: `content` (string, required), `total_lines` (int, required), `returned_lines` (int, required), plus `truncated` (boolean) and `captured_bytes` (int) passed through from the row — a later fetch keeps the capture-completeness context the first shaped result had.
- Resolve tenant/actor from `enriched.tool_context` (RunCommand's `get_in` pattern); `ToolOutput.by_ref` tenant-scoped; missing ref → `{:error, "no stored output for ref …"}`.

### 10. Registration + docs

- `lib/jido_claw/agent/agent.ex` tools list — add `JidoClaw.Tools.FetchOutput` (with the core tools group).
- Workers that carry RunCommand: `lib/jido_claw/agent/workers/coder.ex`, `refactorer.ex`, `test_runner.ex`, `verifier.ex` — add `FetchOutput` to each `tools:` list.
- `lib/jido_claw/core/mcp_server.ex` publish list — add `FetchOutput` (MCP run_command output is shaped too; without it MCP callers can't drill in). 21 → 22 tools.
- `priv/defaults/system_prompt.md` (hand-edit): header count 31 → 32; rewrite the `run_command` doc block line "Output is truncated at ~10KB…" to describe shaping + `output_ref` + `fetch_output`; add a `fetch_output` block; update the worker tool table and Tool Selection Quick Reference. Then **manually copy to `.jido/system_prompt.md`** (AGENTS.md requirement).
- `AGENTS.md`: MCP tools list + count (21 → 22, add `fetch_output`); "~31 tools" mentions; add a short Output Shaping bullet under Key Patterns (alongside the Context Compaction one).

### 11. Phase 1 tests

| File | Asserts |
|---|---|
| `test/jido_claw/tools/output_shaper/mix_test_test.exs` (new, async) | Canned ExUnit fixtures: all-pass → counts only; failures kept verbatim + counts + `summary` shape; variants (doctests/skipped/excluded/invalid); truncated input → `:nomatch`; failures>0 with unparseable blocks → `:nomatch`; failure-budget elision |
| `test/jido_claw/tools/output_shaper/generic_test.exs` (new, async) | head+tail budgets, UTF-8-safe cuts both ends, below-threshold no-compress signal |
| `test/jido_claw/tools/output_shaper_test.exs` (new) | Via inline `use JidoClaw.Tools.Action` echo modules (output_limit_test pattern): disabled ⇒ pass-through; errors/3-tuples untouched (`effects` preserved); non-allowlisted tool untouched; effective-streaming guard (real streaming passes through; MCP-mode "streaming requested" still shapes); **no-tenant ⇒ pass-through unshaped**; shaped map shape incl. footer-after-store ordering; ref-less degradation on *transient* store failure; parser exception ⇒ original returned; telemetry via test handler. Config via `Application.put_env` + `on_exit` restore (compactor-test seam pattern) |
| `test/jido_claw/conversations/resources/tool_output_test.exs` (new, `JidoClaw.TenantCase`, async: false) | store/by_ref/latest_for_fingerprint/prune; tenant isolation; `content` not exposed publicly |
| `test/jido_claw/tools/fetch_output_test.exs` (new, TenantCase, async: false) | grep/tail/head/offset+limit slices; invalid grep regex → clean tool error; missing ref error; cross-tenant ref not found |
| `test/jido_claw/shell/session_manager_capture_test.exs` (new, async: false — no generic `session_manager_test.exs` exists; sibling files are `session_manager_vfs_test.exs` / `session_manager_ssh_test.exs`) | `capture_bytes: 200_000` opt returns ~200KB uncapped; without opt legacy 10KB cap holds; pins the exact truncation-note strings exposed by `SessionManager.truncation_note/1` (shaper suffix-matching depends on them) |
| `test/jido_claw/tools/run_command_test.exs` (extend) | Existing 10KB tests unchanged (test env has shaping off). New describe with shaping enabled: fake `mix` script on PATH (`PATH=/tmp/fake:$PATH mix test` matches detection, emits >10KB canned ExUnit output) ⇒ shaped output + `output_ref` + fetch_output roundtrip. No-tenant regression: shaping enabled but no `tenant_id` in tool_context ⇒ no `capture_bytes` requested, legacy 10KB cap, unshaped output |
| `test/jido_claw/tools/output_redaction_test.exs` | No change — FetchOutput passes the marker conformance loop automatically once registered |

---

## Phase 2 — mix compile filter + git_diff shaping + previous-run delta

Each independently cuttable.

1. **`output_shaper/mix_compile.ex`** (new): collapse `Compiling N files` progress → count; warnings/errors verbatim; `summary: %{warnings, errors}`; `:nomatch` → generic. Detection `~r/^\s*(\w+=\S+\s+)*mix\s+compile\b/`. (`mix do …` deliberately falls to generic.)
2. **git_diff** — modify `lib/jido_claw/tools/git_diff.ex`: when `OutputShaper.shapeable?("git_diff", params, enriched)` (the full predicate — not just enabled?, for the same capture-before-shaper reason as §7), return the full diff (System.cmd already has it) and let the shaper handle it; otherwise keep the legacy 15KB slice (test env unchanged). Add `"git_diff"` to the allowlist with field `:diff`. New **`output_shaper/git_diff.ex`**: per-file stat header (`N files changed, +X/−Y`, per-file `path | +a −b`), then as much diff body as fits a budget, ref hint for the rest; `summary: %{files_changed, insertions, deletions, files: [...]}`. Preserve required `diff: :string` key. Update existing `git_diff` tests (15KB assertion now only under shaping-off). **Also add `FetchOutput` to `workers/reviewer.ex`** — it carries `GitDiff` but not `RunCommand`, so it gains a shaped tool only now.
3. **Previous-run delta** (run_command with a parsed `summary`, `session_uuid` present): before storing, `ToolOutput.latest_for_fingerprint(session_uuid, fingerprint, "run_command")`; compare failure sets → prepend `"↻ same 2 failures as previous run"` or `"↻ failures changed: was 3, now 2 (1 new)"` to the shaped text. Best-effort: any lookup error ⇒ skip silently. Tests: TenantCase cases seeding a prior row, asserting same/changed/new-failure delta lines and silence when `session_uuid` is nil.
4. Parser tests for mix_compile and git_diff (fixtures: warnings-only, errors, empty diff, binary files).

## Implementation notes (reviewer watch-its)

- `shapeable?/3` must be deliberately **cheap and side-effect-free** — RunCommand calls it before execution and OutputShaper calls it again after; it's a pure read of config + params + context.
- The `SessionManager.truncation_note/1` helper dependency is strictly one-way: OutputShaper → SessionManager. SessionManager must never call back into OutputShaper.
- `ToolOutput.latest_for_fingerprint/3`'s read-action argument order and `code_interface` definition must match the Phase 2 call shape exactly: `(session_id, command_fingerprint, tool)`.

## Edge cases to honor

- **Shaping disabled** = byte-identical legacy behavior everywhere (no `capture_bytes` opt, no shaping, git_diff legacy slice).
- **MCP serve-mode**: `session_uuid` nil → store with `session_id: nil` (ref still tenant-scoped fetchable); no tenant at all → **pass through unshaped** (deterministically unstorable ⇒ reversibility can't hold).
- **Upstream-truncated input** (streamed previews, >512KB commands): parsers detect missing summaries/markers → generic fallback; never fabricate counts. Stored rows carry `truncated: true` and the hint says "captured output", not "full output" — the ref is honest about what it holds.
- `mix jidoclaw.compile_check` is the warning gate — watch unused-var warnings when threading `capture` through SessionManager.

## Verification

1. `mix format && mix jidoclaw.compile_check`
2. Targeted: `mix test test/jido_claw/tools/output_shaper_test.exs test/jido_claw/tools/output_shaper test/jido_claw/tools/fetch_output_test.exs test/jido_claw/conversations/resources/tool_output_test.exs test/jido_claw/tools/run_command_test.exs test/jido_claw/shell/session_manager_capture_test.exs`
3. Full `mix test` (runs `ash.setup --quiet`, applying the new migration).
4. Live check: `mix jidoclaw`, ask the agent to run `mix test` in a sample project → observe compact summary + `output_ref` in the tool result; ask it to `fetch_output` with grep/tail; confirm rows via Tidewave (`SELECT ref, tool, byte_size, exit_code FROM tool_outputs`).
5. Telemetry sanity: shaping events visible in the Trace timeline (`:output` category) for the request.

## Out of scope (noted for later)

- AgentTracker per-agent `bytes_saved` rollup and a dashboard panel (Telemetry + Trace events land now; surfacing is a follow-up).
- Shaping other verbose tools (`browse_web`, `search_code`) — allowlist makes additions one-line later.
- Raising the streaming-preview cap.
