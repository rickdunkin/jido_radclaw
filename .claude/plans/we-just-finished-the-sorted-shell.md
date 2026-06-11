# Follow-up Review Fixes — Charlist Format-Arg Leak + Token-Only Proxy Userinfo

## Context

The secrets-cluster plan (H7/H8/H9/M1/M2) landed and a follow-up code review of those changes found two P1 gaps. **Both validated during planning** — source-level reading plus Tidewave repros:

- **P1-1 (gap in the M2 fix)** — `lib/jido_claw/security/redaction/log_redactor.ex:157`: `redact_meta_value/2`'s cond has `charlist?(value) -> value` (deliberate opaque pass-through), and the `{format, args}` msg shape walks args through that same walker (line 81). Confirmed: `LogRedactor.filter/2` on `{"token=~s", [~c"sk-abcdefghijklmnopqrstuvwxyz01"]}` returns the raw key and `:io_lib.format` renders `token=sk-...` — `~s` accepts charlists, so this is a real structured-Logger leak. The same clause also covers charlist values in meta (non-skip keys) and `{:report, ...}` payloads — one shared hole.
- **P1-2 (gap in the H9 fix)** — `lib/jido_claw/security/redaction/env.ex:216-218`: `proxy_value_has_creds?/1` = `@url_with_creds` OR `@bare_userinfo`, and **both regexes require a `:` inside the userinfo** (`user:pass@`). Confirmed: with `HTTP_PROXY=http://token@proxy.example.com:8080` (and scheme-less `token@proxy.example.com:8080`), `Env.scrubbed_cmd_env/0` emits no unset tuple — the credentialed proxy value is inherited by every spawned child, including LLM-driven CLIs.

**Done-criterion: `mix precommit` passes** (compile_check → system_prompt.check → deps.unlock --unused → format check → reach.check → credo --strict → dialyzer → full test).

---

## Fix 1 — redact charlists in the value walker

**File:** `lib/jido_claw/security/redaction/log_redactor.ex`

1. Line 157: `charlist?(value) -> value` → `charlist?(value) -> redact_charlist(value)`. Keep it as the **first** cond branch — charlists are text leaves like binaries (line 31-32 comment): redacted at any depth, never depth-bounded, never walked char-by-char.
2. New private `redact_charlist/1` next to `redact_binary/1` (line 195), mirroring the existing charlist round-trip idiom in `redact_format/1` (lines 212-221):
   - `List.to_string(value)` → `redact_binary/1` (keeps the invalid-UTF8 guard) → **if unchanged, return the original list** (byte-identical pass-through for benign charlists and `~w`-style plain integer lists); if changed, `String.to_charlist(redacted)`.
   - `rescue _e in [ArgumentError, UnicodeConversionError] -> value` — exactly the `redact_format/1` rescue list. Invalid code points (e.g. `[999_999_999_999]` inside crash terms) pass through unchanged instead of escaping to `filter/2`'s catch, which would drop the whole event.
3. Update the now-stale comment at lines 185-187 ("Charlists are opaque pass-through"): charlists are redacted as text via binary round-trip; only the char-by-char walk stays forbidden.

This one clause fixes all three shapes sharing the walker: format args, meta values, report payloads. No change needed to `redact_format/1` (format strings already handled) or the `{:string, _}` / iodata clauses (already `IO.iodata_to_binary`-based).

**Tests (`test/jido_claw/security/redaction/log_redactor_test.exs`):**
- Format describe: `{"token=~s", [~c"sk-abcdefghijklmnopqrstuvwxyz01"]}` → exact msg `{"token=~s", [~c"[REDACTED:API_KEY]"]}` (arg redacted **and still a charlist**).
- Meta describe: charlist under a non-skip key — `%{note: ~c"token sk-..."}` → `~c"token [REDACTED:API_KEY]"`.
- Charlist inside a tuple `crash_reason`: `%{crash_reason: {:badarg, ~c"sk-..."}}` → tuple shape preserved, inner charlist redacted.
- Byte-identical no-ops: `{"~w", [[1, 2, 3]]}` (plain integer list survives the round-trip as the original list) and `{"~s", [~c"hello"]}`.
- Rescue-path pin (per the permanent-test-over-spot-check rule): `{"~w", [[999_999_999_999]]}` → msg unchanged, filter does **not** return `:stop`.
- Must keep passing unchanged: "charlist formats stay charlists" (lines 146-150 — its `[~c"x"]` arg doubles as a no-op shape pin) and the skip-set test (line 44-50, `file: ~c"/path"`).

## Fix 2 — any authority userinfo marks a proxy value credentialed

**File:** `lib/jido_claw/security/redaction/env.ex`

1. Replace `proxy_value_has_creds?/1` (lines 216-218) with authority-based detection — any `@` in the authority (after an optional `scheme://`) is userinfo, with or without a password. Per RFC 3986 the authority ends at the first `/`, `?`, **or** `#`, so split on all three:
   ```elixir
   defp proxy_value_has_creds?(value) do
     value
     |> strip_scheme()
     |> String.split(["/", "?", "#"], parts: 2)
     |> hd()
     |> String.contains?("@")
   end

   defp strip_scheme(value) do
     case String.split(value, "://", parts: 2) do
       [_scheme, rest] -> rest
       [_] -> value
     end
   end
   ```
   Strict superset of the old check: `user:pass@` forms still dropped; token-only `http://token@host:8080` and bare `token@host:8080` now dropped; plain `host:port`, `http://host:8080`, IPv6 `http://[::1]:8080` still inherited; an `@` past the authority — path (`http://proxy:8080/p@th`) or query (`http://proxy.example.com?x=a@b`) — does not false-positive.
2. **Delete `@bare_userinfo`** (lines 108-110 incl. comment) — now unused, and `mix jidoclaw.compile_check` fails on the unused-attribute warning. **Keep `@url_with_creds`** — still used by `redact_value/2` (lines 142-143).
3. Moduledoc proxy bullet (lines 48-53): broaden to "inherited only when the value carries no userinfo — any `@` in the authority drops the var (`http://user:pass@proxy:8080`, `http://token@proxy:8080`, and scheme-less forms); plain `proxy:8080` survives."
4. `scrubbed_port_env/1` delegates to `scrubbed_cmd_env/1` — covered automatically. Override semantics untouched, so the consumer suites (`host_shell_test.exs`, `backend_host_test.exs`) are unaffected.

**Tests (`test/jido_claw/security/redaction/env_test.exs`,** extend the proxy test at lines 174-189 using the existing `put_named_env/2` save/restore helper**):**
- `HTTP_PROXY=http://token@proxy.example.com:8080` → `{"HTTP_PROXY", nil}` asserted.
- `HTTP_PROXY=token@proxy.example.com:8080` (scheme-less token-only) → unset tuple asserted.
- `HTTP_PROXY=http://proxy.example.com:8080/p@th` and `HTTP_PROXY=http://proxy.example.com?x=a@b` → **not** dropped (pins authority-only scoping: `@` in path/query is not userinfo).
- All four existing proxy assertions stay byte-identical (plain forms survive; `user:pass@` forms dropped).

## Out of scope (noted, not fixed)

`redact_value/2`'s display-path URL masking still only matches `user:pass@` — a token-only userinfo URL shown in `/profile current` falls through to `Patterns.redact/1`. Not flagged by the review, display-side, lower stakes than child inheritance; raise separately if wanted.

---

## Sequencing

Independent fixes; either order. Run the targeted suite after each:

1. **Fix 1** — `mix test test/jido_claw/security/redaction/log_redactor_test.exs`
2. **Fix 2** — `mix test test/jido_claw/security/redaction/env_test.exs`

If committing: per prior convention, one `fix:` commit per finding, staging only that finding's source+test pair (the tree still holds the prior plan's uncommitted changes — stage surgically).

## Verification

1. Targeted suites above.
2. Re-run the two planning repros via Tidewave: the charlist format-arg event must render `token=[REDACTED:API_KEY]`; `scrubbed_cmd_env/0` with both token-only proxy forms must emit `{"HTTP_PROXY", nil}` (and plain forms must not).
3. `mix format`, then **`mix precommit`** — the done-criterion. Watch: `jidoclaw.compile_check` (unused `@bare_userinfo` if the deletion is missed), `credo --strict` on the new helpers, dialyzer, full suite.
4. **Report annotations** (`docs/reports/code-review-2026-06-10.md`, only after precommit is green): two fragments are now factually stale and must be updated — M2's line 219 says "charlists opaque" (describes the leak as a feature) → charlists redacted via binary round-trip; H9's line 136 says credentials are dropped "in either `scheme://user:pass@host` or scheme-less `user:pass@host` form" → any authority userinfo, including token-only, drops the var. One sentence each, note the 2026-06-11 follow-up review.

## Risks / gotchas

- **No-op must return the original list** in `redact_charlist/1` — returning the round-tripped conversion breaks the byte-identical pins (`[[1,2,3]]` for `~w`, `[~c"x"]`, skip-set meta).
- **`@bare_userinfo` deletion is mandatory**, not cleanup — compile_check treats the unused-attribute warning as failure.
- **Rescue list must be exactly `[ArgumentError, UnicodeConversionError]`** (the `redact_format/1` idiom) — anything escaping to `filter/2`'s catch drops the whole log event.
- env tests stay `async: false` and must use `put_named_env/2` (save/restore) for real var names like `HTTP_PROXY`.
