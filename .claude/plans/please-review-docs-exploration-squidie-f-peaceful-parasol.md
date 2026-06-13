# Destination-Policy Gate for `browse_web` (last open squidie borrow)

## Context

Review of `docs/exploration/squidie/FEATURES-WORTH-BORROWING.md` (verified against the working tree): every tiered item (T1-1…T3-2) carries a **Shipped** marker and the code confirms it. Exactly **one** recommended borrow remains unshipped, from the 0.2.0 update note (lines 69–85): the **host-enforced destination policy** for `Tools.BrowseWeb`.

Today `browse_web` hands the LLM-supplied URL straight to an out-of-process headless browser (`Jido.Browser.navigate/2`, `lib/jido_claw/tools/browse_web.ex:70`) with zero validation — no scheme check, no loopback/RFC-1918/link-local/tailnet deny. This is the exact leakage path the threat model names: an injected page can steer the browser at internal services (local dashboard, admin endpoints, cloud metadata) and quote their content into the transcript. No SSRF/CIDR code exists anywhere in `lib/` (verified by grep); `browse_web` has zero tests; it is the only LLM-controlled egress (all other HTTP call sites are fixed-host).

**Everything else still open in the doc is explicitly deferred behind a prerequisite** — do NOT implement now:
- T1-2 retry-classifier gating → blocked on the hermes T1-4 provider error classifier (NOT_ADOPTED, different inventory doc)
- T2-4 lease/fencing behavior → gated on clustering; the data model (claim columns on `WorkflowRun`) already landed
- T3-1 second adapter (AgentTracker swarm tree) → gated on a dashboard tab needing it
- Async step-timeline Writer/barrier (§4.3) → deliberately deferred in both companion docs

After this gate ships, the squidie inventory is fully dispositioned.

**Plan revisions after user review (two rounds)** — round 1: (P1) parser differential — use `URI.new/1` fail-closed + reject backslashes, not `URI.parse/1`; (P1/P2) re-check the **final URL after navigation** so redirect/JS-nav to internal hosts can't leak response content; (P2) tool tests must assert the **public normalized error shape** `{:error, %{message: _}}`; (P2/P3) resolver `:timeout`/servfail fails the whole check closed (only `:nxdomain` counts as a benign empty family); (P3) log sanitized scheme/host/category, never the full URL. Rounds 2–3: final-URL lookup prefers **live browser state** (`Jido.Browser.get_url/2` first — accepting both `%{url: _}` and `%{"url" => _}` result shapes — then nav-metadata `"url"`/`:url`, then the requested URL), because Vibium/Web-CLI nav metadata merely echoes the requested URL (`adapters/vibium.ex:67`, `adapters/web/cli.ex:19`) — so this is adapter-agnostic *key lookup*, with redirect *detection* honestly documented as adapter-dependent; stub adapter implements **all required** behaviour callbacks plus optional `command/3` for `:get_url`, returns a raw `%Session{}` from `start_session/1`; the gate site is `execute/3` (not `/2`).

## Design decisions (settled during planning)

- **New pure module** `JidoClaw.Security.DestinationPolicy` (`lib/jido_claw/security/destination_policy.ex`) — `Security/` is the home for cross-cutting policy (`CrossTenantFK` is the analog). Hand-rolled CIDR math; **no new dependency**.
- **API**: `check(url, opts \\ []) :: :ok | {:error, String.t()}`. Reasons are human/LLM-readable strings; reason strings name host + denial category and end with one config-hint sentence mentioning `allowed_cidrs`.
- **Opts override config** (`:enabled?`, `:allowed_cidrs`, `:resolver`) so unit tests stay `async: true` with no `Application.put_env`. `resolver:` is a 2-arity fun `(charlist, :inet | :inet6) -> {:ok, [ip_tuple]} | {:error, term}` defaulting to `&:inet.getaddrs/2`.
- **Config**: `config :jido_claw, :destination_policy, enabled?: true, allowed_cidrs: []` in `config/config.exs` (after the `:output_shaping` block, ~line 214), mirroring the `:output_shaping` pattern (`@config_defaults` + `Application.get_env |> Keyword.get` fallback accessor, see `lib/jido_claw/tools/output_shaper.ex:73-120`). Key named `:destination_policy`, NOT "egress" (already means data-governance here). **No `config/test.exs` override** — default-on everywhere; tests inject via opts.
- **One allow mechanism**: a single `allowed_cidrs` string list (e.g. `["127.0.0.0/8", "::1/128"]`) punching holes in the deny set. Allow beats deny. No per-range booleans. Invalid CIDR strings are **logged + ignored** (a config typo must never crash the tool; a bad allow entry just grants nothing).
- **Observability**: one `Logger.warning` per denial, **sanitized** — scheme, host, and denial category only; never the full URL (userinfo/query may carry tokens). No telemetry event (no security-namespace handler exists; note the option in the moduledoc).

### Check sequence in `check/2`

1. `enabled?` false → `:ok` (kill switch, before any parsing).
2. **Reject any URL containing a backslash** (deny, "malformed URL"). WHATWG browsers normalize `\` to `/`; verified differential: `URI.parse("http://127.0.0.1\\@example.com/")` reports host `example.com` while a browser navigates to `127.0.0.1`.
3. **`URI.new(url)` — fail closed on `{:error, _}`**. Verified: `URI.new/1` rejects the backslash form, bad ports (`http://example.com:notaport/`), malformed IPv6 authority (`http://[::1/`), double-`@` (`http://a@b@c/`), and garbage — while accepting the exotic literal forms we must classify (`[::ffff:127.0.0.1]`, `2130706433`, `0x7f.0.0.1`). (`URI.parse/1` is NOT used — too permissive for a browser-bound gate.)
4. Scheme must be `http`/`https` (the browser would otherwise accept `file://` — local-file-leak vector). Deny others/`nil`.
5. Host must be a non-empty binary — **still required**: verified `URI.new("http://")` succeeds with `host: ""`.
6. `:inet.parse_address(String.to_charlist(host))` → `{:ok, ip}` → classify directly. Verified: this parser affirmatively normalizes decimal `2130706433`, hex `0x7f.0.0.1`, octal `017700000001`, short `127.1` → `{127,0,0,1}` — classified-and-denied, not merely fail-closed. `URI.new` strips IPv6 brackets (host `"::1"`), so no manual bracket handling.
7. Hostname branch: call resolver for **both** `:inet` and `:inet6`:
   - `{:ok, addrs}` → contributes addresses; `{:error, :nxdomain}` → benign empty contribution (also how no-AAAA surfaces).
   - **Any other error (`:timeout`, servfail, …) → fail the whole check closed** even if the other family returned public IPs — "we don't know" is not an allow.
   - Both families empty/nxdomain → fail closed (`"could not resolve host"`).
   - Else deny if **ANY** resolved address classifies denied (one private A/AAAA record poisons the host).

### `classify/1` deny set (built-in constants; allow-list checked first)

- **IPv4-mapped IPv6 unwrap FIRST**: 8-tuple with words 0–4 == 0, word 5 == `0xFFFF` → reconstruct embedded v4 (`::ffff:127.0.0.1` → `{0,0,0,0,0,65535,32512,1}`, verified) and recurse. The unwrapped address also feeds the allow-list check (so `allowed_cidrs: ["127.0.0.0/8"]` permits `[::ffff:127.0.0.1]`).
- **IPv4**: `0.0.0.0/8` (unspecified), `127.0.0.0/8` (loopback), `10.0.0.0/8` + `172.16.0.0/12` + `192.168.0.0/16` (RFC-1918), `169.254.0.0/16` (link-local; covers `169.254.169.254` metadata), `100.64.0.0/10` (CGNAT/tailnet).
- **IPv6**: `::/128`, `::1/128`, `fe80::/10` (link-local), `fc00::/7` (ULA).
- Out of scope, documented in moduledoc: multicast/broadcast/reserved ranges.
- **CIDR math**: ip tuple → integer (v4: 32-bit shift-or; v6: fold 8 words ×16 bits), match `addr >>> (width - prefix)` against the network int; guard `prefix == 0`. Separate function clauses for v4/v6/mapped (avoids reach `deep_nesting`). Dialyzer: `:inet.ip_address()` / `ip4_address()` / `ip6_address()` specs.
- **Moduledoc states limitations honestly**: the gate checks the URL pre-navigation plus the final URL post-navigation (live `get_url` preferred, nav metadata fallback); redirect *detection* is adapter-dependent — adapters that neither answer `:get_url`/`evaluate` nor report a real final URL degrade to pre-navigation-only protection. DNS-rebinding TOCTOU and the internal *request* a redirect triggers are NOT preventable from the BEAM (browser resolves/fetches independently, out of process) — what the post-nav check blocks is quoting the response into the transcript. Fully closing the request path needs BEAM-routed egress or an OS-level proxy. Single call site today; reusable for any future LLM-controlled egress.

## Implementation steps

1. **New** `lib/jido_claw/security/destination_policy.ex` — module per the design above.
2. **Edit** `config/config.exs` — add the `:destination_policy` block after `:output_shaping` (~line 214) with a comment covering the threat, the kill switch, the `allowed_cidrs` escape hatch (dev ergonomics: browsing your own `localhost:4000` dashboard requires `allowed_cidrs: ["127.0.0.0/8", "::1/128"]`), and the rebinding/request-path non-goals.
3. **Edit** `lib/jido_claw/tools/browse_web.ex` — two gates:
   - Alias `JidoClaw.Security.DestinationPolicy`; gate the inner `run/2` (lines 36–40): `with :ok <- DestinationPolicy.check(url), do: do_browse(url, action)`. Denial short-circuits **before** `Jido.Browser.start_session()`; the `{:error, binary}` flows through the `with` and the shared pipeline normalizes it downstream.
   - **Post-navigation re-check** in `execute/3` (`browse_web.ex:69-74`): on `{:ok, session, nav}`, resolve the final URL via a `final_url(session, nav, url)` helper, **preferring live browser state over nav metadata**: (1) `Jido.Browser.get_url(session)` (`deps/jido_browser/lib/jido_browser.ex:214-222` — adapter `command(:get_url)` or JS `window.location.href` fallback; on `{:ok, _s, m}` read `m[:url] || m["url"]` since the command path may be string-keyed and the JS path is atom-keyed); (2) on **any** `get_url` failure mode — `{:error, _}`, a non-map third element, a map with no url key, or a non-binary url value — silently fall through to nav metadata `Map.get(nav, "url")` (AgentBrowser — `adapters/agent_browser.ex:103-106`) then `Map.get(nav, :url)`; (3) the requested `url`. A broken adapter URL probe must never turn allowed browsing into a hard failure — the helper is total and never raises. **Honesty caveat (documented in moduledoc + shipped note)**: this is adapter-agnostic *key lookup*, but redirect detection is only as good as the adapter — Vibium and the Web CLI echo the *requested* URL in nav metadata (`adapters/vibium.ex:67`, `adapters/web/cli.ex:19`), so for adapters that neither support `:get_url`/`evaluate` nor report a real final URL, protection degrades to pre-navigation-only. If `final != url`, run `DestinationPolicy.check(final)`; on denial return an error naming the **redirect** ("page redirected to a blocked destination …") so the LLM understands the page did it. Only then `dispatch_action` (covers content/links/screenshot uniformly). Session cleanup already handled by `do_browse`'s end_session-after-result flow. Remaining honest gap: JS/meta-refresh navigation *after* this re-check window.
4. **New** `test/support/stub_browser_adapter.ex` — `Jido.Browser.Adapter` implementation with **ALL required callbacks**: `start_session/1`, `end_session/1`, `navigate/3`, `click/3`, `type/4`, `screenshot/2`, `extract_content/2` (only `evaluate/3` and `command/3` are optional — `deps/jido_browser/lib/jido_browser/adapter.ex:127`; stub the unused ones to return a benign error/no-op so nothing is left undefined for compile_check). **`start_session/1` returns a raw `%Jido.Browser.Session{}`**, not `{:ok, session}` — the behaviour is `Session.t() | {:error, term()}` and `Jido.Browser.start_session/1` wraps it (`jido_browser.ex:50-52`). `navigate/3` returns a configurable final-URL map — scenario read from `Application.get_env(:jido_claw, :stub_browser_scenario)` set per-test. Adapter selection is config-driven: `Application.get_env(:jido_browser, :adapter, ...)` (`deps/jido_browser/lib/jido_browser.ex:730`).
5. **New** `test/jido_claw/security/destination_policy_test.exs` — `use ExUnit.Case, async: true` (opts injection, no env mutation; model: `test/jido_claw/security/redaction/patterns_test.exs`). Cases:
   - Structural/parser: allows `https://example.com` + `http://example.com` (resolver stub → public IP); denies `file:///etc/passwd`, `ftp://…`, `http://` (empty host), garbage; **denies `http://127.0.0.1\@example.com/` (backslash differential), `http://example.com:notaport/`, `http://[::1/` (malformed v6), `http://a@b@c/`** — all fail-closed via backslash-reject/`URI.new`; `enabled?: false` opt → `:ok` even for `http://127.0.0.1/`.
   - IPv4 literals: deny one per range (127.0.0.1 + range edge, 10.0.0.5, 172.16.0.1, 192.168.1.1, 169.254.169.254, 100.64.0.1, 0.0.0.0); deny exotic forms `2130706433`, `0x7f.0.0.1`, `017700000001`, `127.1`; allow `8.8.8.8`.
   - IPv6 literals: deny `[::1]`, `[fe80::1]`, `[fc00::1]`, `[::]`, `[::ffff:127.0.0.1]`, `[::ffff:10.0.0.1]`; allow `[2606:4700:4700::1111]`.
   - `allowed_cidrs`: `["127.0.0.0/8"]` allows 127.0.0.1; `["10.1.2.0/24"]` allows 10.1.2.5, still denies 10.1.3.5 (mask correctness); `["::1/128"]` allows `[::1]`; mapped punch-through; invalid entries (`"not-a-cidr"`, `"10.0.0.0/99"`) ignored without crash while valid entries work (`ExUnit.CaptureLog`).
   - Resolver: resolved-to-private denied; public-v4 + `:nxdomain`-v6 allowed; public v4 + private v6 denied (deny-any); **`:nxdomain` both → fail closed; `:timeout` on ONE family + public on the other → fail closed** (the P2/P3 ruling); default resolver: `http://localhost/` denied (hermetic — `:inet.getaddrs(~c"localhost", :inet)` → `{:ok, [{127,0,0,1}]}`, verified).
   - Logging: denial log contains host + category but **not** path/query/userinfo (assert on captured log for a URL like `http://10.0.0.5/secret?token=abc`).
6. **New** `test/jido_claw/tools/browse_web_test.exs` — first test for this tool; `use ExUnit.Case, async: false` (sets `:jido_browser, :adapter` env; merge + on_exit-restore convention per `output_shaper_test.exs:41-51`). Call the **public** `JidoClaw.Tools.BrowseWeb.run(params, %{})`.
   - **Assert the public normalized shape**: `{:error, %{message: msg}}` — the shared wrapper (`tools/action.ex:40`) runs `Error.normalize_result/1`, which folds binary errors into `%{code: :tool_error, message: msg, details: %{}}` (`tools/error.ex:169`). Do NOT assert bare `{:error, binary}`.
   - Pre-nav denials (no adapter needed — short-circuit before `start_session`): `http://127.0.0.1/`, `http://169.254.169.254/`, `http://[::1]/`, `http://[::ffff:127.0.0.1]/`, `http://127.0.0.1\@example.com/`, `file:///etc/passwd` → `{:error, %{message: msg}}` with `msg =~ "allowed_cidrs"` on range denials.
   - Stub-adapter wiring tests (the stub's optional `command/3` implements `:get_url` per scenario, so both chain links are exercisable). **Hermeticity rule: every allowed/requested URL in these tests is a public IP literal (`http://8.8.8.8/`), never a hostname** — `BrowseWeb.run/2` calls `DestinationPolicy.check/1` with the *default* resolver, so a hostname like `example.com` would do live DNS. Cases: (a) **pass-through** — request `http://8.8.8.8/`, `:get_url` reports the same URL, extract_content returns content → `{:ok, %{content: _}}`; (b) **redirect denial via live URL, atom-keyed** — `:get_url` reports `%{url: "http://127.0.0.1/admin"}` (the JS-fallback shape; preferred chain link) → `{:error, %{message: msg}}`, `msg =~ "redirect"`, extract_content never invoked (stub raises/flags if called); (c) **redirect denial via live URL, string-keyed** — `:get_url` reports `%{"url" => "http://127.0.0.1/admin"}` (adapter-command shape) while nav metadata stays public → same denial (pins both key shapes on the live link); (d) **redirect denial via nav-metadata fallback** — `:get_url` unsupported/error, stub navigate reports `%{"url" => "http://127.0.0.1/admin"}` (AgentBrowser shape) → same denial (pins the fallback link).
7. **Edit** `docs/exploration/squidie/FEATURES-WORTH-BORROWING.md` — append a **Shipped (2026-06-12)** note to the 0.2.0 `Step.HTTP`/`Step.Elixir` bullet (lines 69–85) in house style (bolded marker + prose naming the module + sketch corrections: `URI.new` fail-closed + backslash reject after the parser-differential finding, post-navigation final-URL re-check, exotic literal forms affirmatively classified, deny-any across families, timeout-fails-closed, known rebinding/request-path gaps).
8. **Edit** `AGENTS.md` — extend the `security/` row of the subsystem table: `Encryption vault, secret redaction, browse_web destination-policy gate`.
9. **No change**: `config/test.exs`, `priv/defaults/system_prompt.md` (drift check validates only tool count + names — unchanged), MCP tool list (browse_web isn't MCP-exposed).

## Verification

```bash
mix test test/jido_claw/security/destination_policy_test.exs
mix test test/jido_claw/tools/browse_web_test.exs
mix precommit        # the completion bar — must pass in full
```

`mix precommit` = `jidoclaw.compile_check` (warnings-as-errors w/ allowlist — new code must need no allowlist entry), `jidoclaw.system_prompt.check`, `deps.unlock --unused` (clean — no new dep), `format --check-formatted`, `reach.check --arch --smells --strict`, `credo --strict` (both kept at **zero** findings), `dialyzer`, full test suite.

Risk check done during planning: zero existing tests or internal callers touch `browse_web` (single registration at `agent/agent.ex:38`), so the default-on gate breaks nothing.

## Out of scope (stated, not built)

- DNS-rebinding TOCTOU and the internal **request** a redirect triggers (browser fetches out-of-process before we see the final URL — the post-nav check blocks response *leakage*, not the request itself); JS/meta-refresh navigation after the post-nav re-check. Fully closing these needs BEAM-routed egress or an OS-level proxy.
- `.jido/config.yaml`-level per-project allows (app config suffices; add a `JidoClaw.Config` key later if operator ergonomics demand it).
- Multicast/broadcast/reserved deny ranges; telemetry event for denials.
- Everything in the "explicitly deferred" list in Context.
