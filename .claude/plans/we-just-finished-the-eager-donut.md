# Fix code-review findings P1 + P2 in the browse_web destination-policy gate

## Context

A code review of the just-shipped destination-policy work (plan `please-review-docs-exploration-squidie-f-peaceful-parasol.md`) reported two findings. **Both verified real** against the working tree, with parser behavior probed via Tidewave `project_eval` (Elixir 1.20.1 / OTP 27 on this machine):

**P1 — VALID. Post-navigation re-check skipped when the URL string is unchanged.**
`lib/jido_claw/tools/browse_web.ex:98` — `defp recheck(url, url), do: :ok` short-circuits the post-nav policy check whenever `final == url`. DNS rebinding *never* changes the URL string, so the equal-string "optimization" removes the defense in exactly the attack case. Worse, when an adapter reports no final URL, `final_url/3` falls back to the requested `url` itself (`browse_web.ex:109-111`), so those adapters get **zero** post-navigation protection. Always re-checking re-resolves the hostname a second time, which catches typical TTL-0 rebinds at the response-leak step (an alternating resolver can still slip through — that stays a documented gap).

**P2 — VALID, and slightly broader than reported. Host canonicalization differs from WHATWG browser parsing.**
`lib/jido_claw/security/destination_policy.ex:175` classifies only what `:inet.parse_address/1` accepts. Probes confirmed the differential forms fall to the DNS branch (relying on resolver failure — bypassable by NXDOMAIN-hijacking/wildcard resolvers, which are common):

| host | `:inet.parse_address` | WHATWG browser | today's behavior |
|---|---|---|---|
| `127.0.0.1.` / `10.0.0.1.` / `0x7f.0.0.1.` | `{:error, :einval}` | strips trailing dot → IP | DNS branch (fragile fail-closed) |
| `%31%32%37.0.0.1` / `127.0.0.1%2e` | `:einval` (URI.new keeps host encoded) | percent-decodes once → IP | DNS branch |
| `0x7f.0x0.0x0.0x1` | `:einval` (Erlang quirk) | hex parts → `127.0.0.1` | DNS branch — **new finding from probing** |
| `0177.0.0.1` (dotted octal), `0x7f000001`, `127.0.1`, `127.0x1` | parses, BSD semantics | same | already affirmatively denied — no hole |

Fix-relevant probe facts: `URI.decode("%zz")` passes through unchanged (no raise); `URI.decode("ex%ffample.com")` yields invalid UTF-8 on which `String.to_charlist/1` **raises** `UnicodeConversionError` (the decode step must guard); `URI.new` rejects raw non-ASCII hosts (`{:error, ":"}`), so IDN is already fail-closed pre-decode; `URI.new("http://%zz/")` succeeds (malformed `%` reaches us).

The review offered "canonicalization **or** fail-closed tests" — canonicalization is the right call: tests alone would pin today's hijackable DNS-failure reliance, while decoding upgrades these to affirmative classification. The `0x7f.0x0.0x0.0x1` quirk additionally requires the WHATWG **ends-in-a-number** rule (numeric-looking hosts must parse as IPv4 or be denied — never resolved as DNS names; browsers refuse all-numeric hostnames too, so there is no false-deny for browsable sites).

**Plan revision after user review**: do NOT strip a trailing dot globally — WHATWG keeps trailing dots on domain hosts (`example.com.` stays the FQDN `example.com.` in the browser); only IPv4-candidate hosts get one trailing label dropped. So: try IP classification on the decoded host as-is, retry once on the dot-stripped candidate, apply `ends_in_number?` to the IPv4 candidate, and resolve domain hosts **as decoded** (resolver receives `~c"example.com."`, dot preserved). Also adopted: deny WHATWG-forbidden bytes (decoded `/`, `@`, `?`, `#`, `:`, `\`, …) on the hostname path outright instead of depending on resolver rejection — implemented as a charset allow-list.

**Done bar (user-stated): `mix precommit` must pass in full.**

## Implementation

### 1. P1 — `lib/jido_claw/tools/browse_web.ex`

Replace `recheck/2` (lines 98–105): **always** call `DestinationPolicy.check(final)`; keep the same-binary match only for error wording:

```elixir
defp recheck(final, requested) do
  case DestinationPolicy.check(final) do
    :ok -> :ok
    {:error, reason} -> {:error, recheck_denial(final, requested, reason)}
  end
end

defp recheck_denial(url, url, reason),
  do: "destination failed the post-navigation re-check: #{reason}"

defp recheck_denial(_final, _requested, reason),
  do: "page redirected to a blocked destination: #{reason}"
```

Update the comment block above `recheck_destination/4` (lines 83–91): the re-check is unconditional — a same-string final URL is re-resolved, so a rebinding hostname is caught before its response is quoted; adapters reporting no final URL now degrade to "re-check of the requested URL" (catches rebinds, misses true redirects) instead of nothing. Cost: one extra DNS resolution per hostname browse — fine for a security gate.

### 2. P2 — `lib/jido_claw/security/destination_policy.ex`

Add a decode step to `run_checks/2` (line 128) between `check_host` and `check_destination`:

```elixir
with :ok <- reject_backslash(url),
     {:ok, uri} <- parse(url),
     {:ok, scheme} <- check_scheme(uri),
     {:ok, host} <- check_host(uri, scheme),
     {:ok, decoded} <- decode_host(host, scheme) do
  check_destination(decoded, host, scheme, opts)
end
```

`decode_host/2` — one `URI.decode/1` pass, like browsers (probe: malformed `%zz` passes through unchanged, no rescue needed), then fail-closed guards on the result:
1. Deny if empty → "missing host".
2. Deny unless every byte is printable ASCII (`:binary.bin_to_list/1` + `Enum.all?(&(&1 in 0x21..0x7E))` — byte-safe on invalid UTF-8, **guards the `String.to_charlist` raise** on `%ff` decodes; covers encoded controls/space/DEL and non-ASCII — no IDNA mapping, documented fail-closed).
3. Deny if it still contains `%` (double-encoding; `%` is a WHATWG forbidden domain code point — browsers refuse these too).

**No global trailing-dot strip** — WHATWG preserves trailing dots on domain hosts (`example.com.` is resolved as the FQDN); only the IPv4-candidate path drops one trailing empty label.

`check_destination(decoded, host, scheme, opts)` — classification mirrors WHATWG host-parser order:

```elixir
case classify_literal(decoded) do
  {:ok, ip} ->
    check_addresses([ip], host, scheme, allow)

  :error ->
    cond do
      not dns_hostname?(decoded) ->
        deny(...)  # forbidden host characters — decoded `/ @ ? # : \ < > [ ] ^ |` etc.
                   # are WHATWG-forbidden; deny outright, never lean on resolver rejection
      ends_in_number?(decoded) ->
        deny(...)  # browsers would force this host through IPv4 parsing — an
                   # IP-literal form we cannot parse is never resolved as a DNS name
      true ->
        resolve_and_check(decoded, host, scheme, allow, opts)
    end
end
```

- `classify_literal/1`: `:inet.parse_address` on `decoded` as-is (v6 `::1`, v4 dec/hex/octal/short forms); on `:einval`, if `decoded` ends with `"."`, retry once on `String.replace_suffix(decoded, ".", "")` — the WHATWG IPv4-candidate normalization (`127.0.0.1.` → loopback). The stripped form is used **only** for literal classification, never for resolution.
- `dns_hostname?/1`: charset allow-list `[a-zA-Z0-9._-]` (LDH + underscore + dot). Strictly subsumes the WHATWG forbidden-domain set and also rejects never-legit-in-DNS sub-delims; v6 literals (containing `:`) classified above never reach it. Spec-faithful order: forbidden-char check (domain-to-ASCII failure) precedes ends-in-number. The denial message and `Logger.warning` carry the **original parsed host** + category only — never the decoded transform verbatim (same sanitization shape as every other denial).
- `ends_in_number?/1` (WHATWG, on `decoded`): split on `"."`; drop one trailing `""` part if present; if any remaining part is `""` → `false`; else the last part is a number when all ASCII digits (decimal + `0`-octal) or `"0x"`/`"0X"` + only hex digits (empty rest counts). Converts every residual Erlang-vs-WHATWG numeric-parse quirk (`0x7f.0x0.0x0.0x1`, future OTP drift) into an affirmative deny instead of a DNS query a hijacking resolver could answer.
- `resolve_and_check` gains the decoded arg (arity 5 — precedent: `resolve_family/5`): **resolve `decoded` as-is** — the name the browser would actually resolve. Encoded `%6c%6f…` = `localhost` now resolves-and-denies affirmatively; `example.com.` reaches the resolver as `~c"example.com."` with the FQDN dot preserved. Keep reporting/logging the **original** `host` in messages (the existing `(resolves to …)` clause in `range_message/3` already displays mismatches well).

Moduledoc updates: insert the decode + IPv4-candidate + forbidden-charset + ends-in-number steps into the "Check sequence" (noting domain trailing dots are preserved through resolution); add an IDN line (non-ASCII hosts fail closed; punycode works as plain ASCII); rewrite the rebinding bullet in "Honest limitations" — the unconditional post-nav re-check re-resolves, catching typical TTL-0 rebinds before the response is quoted, but a resolver alternating answers can still slip between checks and the browser's own fetch already happened.

### 3. Tests — `test/jido_claw/security/destination_policy_test.exs`

New `describe "host canonicalization (WHATWG browser parity)"` (stays `async: true`, opts-injected; for "no DNS" assertions pass `resolver: fn _, _ -> raise "resolver must not be called" end`):

- Trailing-dot + encoded literals **affirmatively classified** (assert `=~ "loopback"` / `"blocked address range"`, not "could not resolve"): `http://127.0.0.1./`, `http://10.0.0.1./`, `http://0x7f.0.0.1./`, `http://%31%32%37.0.0.1/`, `http://127.0.0.1%2e/`, plus dotted-octal `http://0177.0.0.1/` (pins the probed BSD parity).
- Ends-in-number fail-closed, resolver never called: `http://0x7f.0x0.0x0.0x1/` (probed `:einval`), `http://example.123/` (numeric TLD — browsers refuse these as failed IPv4), `http://example.0x/` (the `"0x"`-with-empty-rest edge counts as a number per WHATWG — user sanity-checked that browsers reject it).
- Forbidden decoded host bytes fail closed, resolver never called: hosts decoding to `/`, `@`, `?`, `#`, `:`, `\` — e.g. `http://a%2Fb/`, `http://a%40b/`, `http://a%3Fb/`, `http://a%23b/`, `http://a%3Ab/`, `http://a%5Cb/` (browsers refuse these as forbidden host code points; we must not lean on resolver rejection).
- Malformed-after-decode denials, resolver never called, **no crash**: `http://%2531%2532%2537.0.0.1/` (double-encoded), `http://%zz/`, `http://ex%ffample.com/` (the `UnicodeConversionError` guard).
- Decoded-name resolution: `http://%6c%6f%63%61%6c%68%6f%73%74/` with a resolver that `send`s the charlist it received → `assert_received {:resolved, ~c"localhost"}` and private answer → denied.
- FQDN trailing dot preserved through resolution: `http://example.com./` → resolver receives `~c"example.com."` (dot intact — WHATWG keeps trailing dots on domain hosts; stripping happens only for IPv4-literal candidacy), public answer → `:ok`.
- Allow punch-through on the classified literal: `allowed_cidrs: ["127.0.0.0/8"]` allows `http://127.0.0.1./` and `http://%31%32%37.0.0.1/`.

### 4. Stub — `test/support/stub_browser_adapter.ex`

Add scenario key `:on_navigate` (0-arity fun, run at the top of `navigate/3` when set; document in the moduledoc): lets a test change the world between the pre-navigation check and the post-navigation re-check — the deterministic stand-in for a DNS rebind.

### 5. Tests — `test/jido_claw/tools/browse_web_test.exs`

- **P1 regression** (the key new test): pre-check passes `http://127.0.0.1/` via a policy-env allow hole; the `:on_navigate` hook revokes it; final URL string never changes (stub `get_url` unscripted → nav metadata echoes the request). Assert `{:error, %{message: msg}}` with `msg =~ "post-navigation re-check"` and `refute msg =~ "redirect"`. On current code this test fails (gate skipped → stub `extract_content` raises → "browser error"), proving it pins the fix. Policy env helper follows the module's existing fetch/put/on_exit-restore convention **and merges overrides onto the current value with `Keyword.merge`** (never wholesale-replace the sublist).
- Pre-nav canonicalization through the tool's public shape (no adapter, hermetic — literal classification, no DNS): `http://127.0.0.1./` and `http://%31%32%37.0.0.1/` → `{:error, %{message: msg}}`, `msg =~ "allowed_cidrs"`.
- Existing redirect tests keep their `"redirect"` wording (final ≠ url path unchanged).

### 6. Docs

- `config/config.exs` (`:destination_policy` comment): adjust the non-goals sentence — the post-nav re-check now re-resolves (rebind leak-side mitigated); the browser's own internal *request* remains out of scope.
- `docs/exploration/squidie/FEATURES-WORTH-BORROWING.md`: extend the **Shipped (2026-06-12)** note with the post-review hardenings — unconditional post-navigation re-check (rebind re-resolution), WHATWG host parity (percent-decode once; trailing-dot strip only for IPv4-literal candidacy, FQDN dots preserved through resolution; ends-in-number and forbidden-host-byte forms fail closed).
- `AGENTS.md`: no further change (security row already updated).

## Verification

```bash
mix test test/jido_claw/security/destination_policy_test.exs
mix test test/jido_claw/tools/browse_web_test.exs
mix precommit        # the completion bar — must pass in full
```

`mix precommit` = `jidoclaw.compile_check` (no new allowlist entries), system-prompt drift check, `deps.unlock --unused` (no new dep), `format --check-formatted`, `reach.check --arch --smells --strict` + `credo --strict` (both at zero), `dialyzer`, full suite. No commit unless requested.

## Out of scope (unchanged, documented)

- Alternating-resolver rebinds and the browser's internal request path (needs BEAM-routed egress / OS proxy).
- IDNA/punycode mapping for non-ASCII hosts (they fail closed; punycode-form URLs work).
- Multicast/broadcast/reserved ranges; denial telemetry.
