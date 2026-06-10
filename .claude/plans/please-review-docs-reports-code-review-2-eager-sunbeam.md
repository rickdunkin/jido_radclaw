# Fix H1 + H2 from code-review-2026-06-10

## Context

The 2026-06-10 code review flags two HIGH security findings that together "make the privileged surface reachable" under the default `mode: :both` (gateway on, binds 0.0.0.0:4000):

- **H1**: `/admin` (AshAdmin) is gated only by `RequireAuth` — any logged-in user passes; there is no role concept anywhere. AshAdmin then runs with `authorize?: false`, bypassing the `forbid_if(always())` policies on User/Token/SecretRef and exposing every tenant's rows.
- **H2**: `check_origin: false` is the base endpoint config (`config/config.exs:206`); only prod overrides it. Combined with `same_site: "Lax"` cookies, any web page the signed-in operator visits can open an authenticated cross-origin WebSocket (`/ws`, `/live`) and drive privileged events (CSWSH).

Decisions made with the user:
- **H1 gate mechanism**: env-driven email allowlist (`JIDOCLAW_ADMIN_EMAILS`), no DB migration.
- **H2 remote access**: operator uses the dashboard from other machines (Tailscale), so `PHX_HOST` is the opt-in exposure knob; **defaults are loopback + port-pinned origin allowlist in every env** (per plan review: secure-by-default must not be dev-only; wildcard-port origins rejected as too loose).

### Two findings that correct the report's suggested fixes (verified against source)

1. **AshAdmin cannot be forced into `authorize?: true` server-side.** `AshAdmin.Router.__session__/3` (deps/ash_admin/lib/ash_admin/router.ex:137-154) applies cookie replication *after* merging any custom `:session` MFA — client cookies always win (absent cookies overwrite custom values with `nil`). Worse, `AshAdmin.ActorPlug.Plug.actor_assigns/2` (deps .../actor_plug/plug.ex:16) prefers client-supplied LiveView connect params over the session entirely. The actor/authorizing state is client-controlled **by design**; the only sound fix is a hard gate in front of the route. The plan gates at two layers (plug + `on_mount`).
2. **`runtime.exs` cannot see `.env` vars.** `JidoClaw.Application.start/2` calls `load_dotenv()` (application.ex:38) *after* runtime config has evaluated. So both new env knobs are read later: `JIDOCLAW_ADMIN_EMAILS` at request time, `PHX_HOST` right after `load_dotenv()` (the same pattern `Desktop.Sidecar.maybe_configure_endpoint/0` uses).

---

## H1 — Gate /admin behind an admin email allowlist

### 1. New module `JidoClaw.Web.AdminAccess` — `lib/jido_claw/web/admin_access.ex`

- `admin?(user)` — `false` for `nil`; otherwise membership test of `user.email |> to_string() |> String.downcase()` (email is `Ash.CiString`) in `admin_emails()`.
- `admin_emails()` — `(Application.get_env(:jido_claw, :admin_emails) || System.get_env("JIDOCLAW_ADMIN_EMAILS")) |> parse_admin_emails()`. **Both sources go through the same normalizer.** Read per call so `.env`-loaded values work (see finding 2). Default `[]` → `/admin` unreachable for everyone until explicitly granted.
- `parse_admin_emails/1` — public pure function with clauses: `nil → []`; binary → split on `,`, trim, downcase, drop blanks; list → map `to_string/1`, trim, downcase, drop blanks.

### 2. New plug `JidoClaw.Web.Plugs.RequireAdmin` — `lib/jido_claw/web/plugs/require_admin.ex`

Pattern after `lib/jido_claw/web/plugs/require_auth.ex`. Reads `conn.assigns[:current_user]` (set by `RequireAuth`, which must run first); non-admin or missing user → `send_resp(conn, 404, "Not Found") |> halt()`. 404, not 403/redirect, so the admin surface isn't advertised to non-admin authenticated users.

### 3. `:live_admin_required` on_mount hook — `lib/jido_claw/web/live_user_auth.ex`

New `on_mount/4` clause following the existing `:live_user_required` shape (reuse `assign_current_user/2`):
- no user → `{:halt, redirect(socket, to: "/sign-in")}`
- user but not `AdminAccess.admin?/1` → `{:halt, redirect(socket, to: "/dashboard")}`
- admin → `{:cont, socket}`

### 4. Router wiring — `lib/jido_claw/web/router.ex`

```elixir
pipeline :require_admin do
  plug(JidoClaw.Web.Plugs.RequireAdmin)
end

scope "/" do
  pipe_through([:browser, :require_browser_auth, :require_admin])
  ash_admin("/admin", on_mount: [{JidoClaw.Web.LiveUserAuth, :live_admin_required}])
end
```

Why both layers: the plug gates the disconnected render (which mints the signed LiveView session needed to join the `:ash_admin` live_session over WS); the `on_mount` hook independently gates new WebSocket mounts and reconnects. **Revocation semantics (documented in the router comment, not oversold):** removing an email from the allowlist takes effect on the next HTTP request / LV mount / reconnect — an already-connected AshAdmin LiveView keeps its process until disconnect. Acceptable for a break-glass operator surface. The comment also notes that AshAdmin's in-UI actor/authorizing toggles are client-controlled, so this gate is the security boundary.

Leave the dev-only `live_dashboard` scope as-is (already compiled out of prod).

### 5. Tests

- `test/jido_claw/web/admin_access_test.exs` (new) — `parse_admin_emails/1` clauses (nil/binary/list, commas, whitespace, case, blanks); `admin?/1` with nil and user structs; Application-config seam normalization.
- `test/jido_claw/web/plugs/require_admin_test.exs` (new) — direct plug invocation pattern like `test/jido_claw/web/plugs/api_key_auth_test.exs`, using the `Application.put_env(:jido_claw, :admin_emails, [...])` seam with `on_exit` cleanup. Cases: empty allowlist → 404 halt; allowlisted email passes untouched; non-allowlisted → 404; case-insensitive match; no `current_user` assign → 404. Plus: `:live_admin_required` with an empty session halts with redirect to `/sign-in` (no DB needed).
- **Route-level integration test** (new, e.g. `test/jido_claw/web/admin_route_test.exs`) — catches forgetting to wire the pipeline around `ash_admin("/admin")`, which plug unit tests cannot. Approach:
  - Add `server: false` for the endpoint in `config/test.exs` (standard Phoenix convention; harmless since `mode: :cli` never starts it under the app tree), then `start_supervised(JidoClaw.Web.Endpoint)` in the test and dispatch via `Phoenix.ConnTest` with `@endpoint JidoClaw.Web.Endpoint` (PubSub is already running from the app's Core children).
  - Mint a real signed-in session: create a user through the `register_with_password` action (`authorize?: false`; tokens are enabled so obtain a token-bearing user — fall back to the `sign_in_with_password` action if register doesn't attach token metadata), then `AshAuthentication.Plug.Helpers.store_in_session(conn, user)`. Use the existing DB case template the web tests use (`JidoClaw.TenantCase` / data case with SQL sandbox).
  - Cases: unauthenticated `GET /admin` → redirect to `/sign-in`; signed-in non-admin → 404; allowlisted admin → 200 disconnected render (AshAdmin smoke).

---

## H2 — Loopback default + port-pinned origin allowlist; validated `PHX_HOST` opt-in

### 1. `config/config.exs` — secure base defaults for every env (lines 198-206)

```elixir
http: [ip: {127, 0, 0, 1}, port: 4000],
...
check_origin: ["//localhost:4000", "//127.0.0.1:4000", "//[::1]:4000"]
```

- **Loopback bind in the base config**, not dev-only: releases/staging built on the base config stay loopback unless `PHX_HOST` opts in. Any non-local deployment must set `PHX_HOST` (documented in README).
- **Explicit, port-pinned allowlist instead of `check_origin: true`**: Phoenix's `true` compares only against `url[:host]` ("localhost"), which would reject a browser at `http://127.0.0.1:4000`. Entries are scheme-agnostic but pinned to the gateway port — a port-less entry like `//localhost` is an any-port wildcard in Phoenix, which would let a page on e.g. `localhost:3000` open a cookie-bearing socket to `:4000`. Comment that the port must stay in sync with `http[:port]`.
- Requests with no Origin header (CLI/scripts per README's `ws://localhost:4000/ws` usage) are unaffected by origin checks.
- No `config/dev.exs` change needed — dev inherits the base.

### 2. New module `JidoClaw.Web.GatewayExposure` — `lib/jido_claw/web/gateway_exposure.ex`

The `PHX_HOST` parse/merge logic lives in a small dedicated module (testable; keeps `application.ex` lean). `JidoClaw.Application.start/2` calls `GatewayExposure.configure!()` immediately after `load_dotenv()` (application.ex:38), before children are built. Comment the call with the runtime.exs-vs-`.env` ordering rationale.

- `parse_hosts/1` (public, pure): takes the raw env string (or nil), splits on `,`, and **round-trips every candidate through `URI.parse`** — entries containing `://` are parsed directly, bare entries as `URI.parse("//" <> entry)`. Keep `{host, port}` where `uri.host` is non-empty; `uri.port` is the explicitly-provided port or `nil` (drop scheme-implied defaults only when no port was written — i.e. detect explicit port by checking the raw entry, or parse without scheme so `port` is only set when written). Hosts with paths get the path discarded by taking `uri.host`; unbracketed IPv6, blanks, and unparseable entries are dropped. IPv6 hosts are re-bracketed when rebuilding origin strings.
- `configure!/0` reads `System.get_env("PHX_HOST")`; `configure/1` (public for tests) takes the raw string:
  - No valid hosts but env was set → `Logger.warning` + no-op (defaults stay loopback/locked).
  - With valid hosts, merge into the `:jido_claw, JidoClaw.Web.Endpoint` env via `Application.put_env`:
    - `check_origin:` — `Enum.uniq(host_origins ++ base_origins)`, where each host origin is `"//#{host}:#{port}"` using the **explicitly provided port, else the configured gateway port** (`http[:port]` from current endpoint config, default 4000) — no wildcard-port entries; `base_origins` is the current config value when it's a list (else `[]`). Extends, never replaces, so loopback origins keep working.
    - `url: [host: first_host]` — **host only**, provided ports are never propagated to `url`.
    - `http[:ip] = {0, 0, 0, 0}` via `Keyword.update` (preserve `port:` and other keys).
- Port policy, documented in the moduledoc + README: `PHX_HOST=box.ts.net` pins origins to the gateway port (direct access); fronting with a TLS proxy needs the proxy port spelled out, e.g. `PHX_HOST=box.ts.net:443`.

### 3. `config/runtime.exs` — drop the now-redundant prod `check_origin`

Remove `host = System.get_env("PHX_HOST", "localhost")` and the `check_origin:` key from the prod endpoint block (keep `secret_key_base`). Single source of truth: base allowlist + `GatewayExposure` (which runs later and would override anyway). Note the prod behavior change: without `PHX_HOST`, prod now binds loopback with localhost-only origins (intentional, per review).

### 4. `config/test.exs` — add `server: false` for the endpoint

Enables `start_supervised(JidoClaw.Web.Endpoint)` in the route test without binding a port; no other test impact (`mode: :cli` already prevents app-tree startup; no socket/channel tests exist).

### 5. `lib/jido_claw/desktop/sidecar.ex` — defuse the H2-shaped footgun in the dead merge

Two changes to `maybe_configure_endpoint/0` (lines 22-42): drop `check_origin: false`, **and** replace the shallow `Keyword.merge(..., http: [port: port])` — which would discard the new base `http[:ip]` and fall back to all-interfaces if this code is ever wired — with a deep merge that preserves/sets loopback: `Keyword.update(config, :http, [ip: {127, 0, 0, 1}, port: port], &Keyword.merge(&1, ip: {127, 0, 0, 1}, port: port))` (loopback is correct for a desktop sidecar). Full L19 cleanup (deleting the dead module) stays out of scope.

### 6. Tests

- `test/jido_claw/web/gateway_exposure_test.exs` (new):
  - `parse_hosts/1` edge cases: nil/blank → `[]`; plain host; `host:port`; comma list with whitespace; `https://host/path` → host kept, path dropped; bracketed IPv6 kept, unbracketed dropped; junk dropped.
  - `configure/1` merge behavior (`async: false`, capture and restore the endpoint's Application env in `on_exit`): unset/nil → no-op, loopback + base origins intact; comma hosts → origins extended (base entries preserved, host entries pinned to gateway port, explicit port respected), `http[:ip]` becomes `{0,0,0,0}`, `url[:host]` is the first host; junk-only input → warns and no-ops.

---

## Docs

- README (dashboard section, ~line 155/373): the gateway now binds `127.0.0.1:4000` in **all** envs by default; to reach it from another machine (e.g. Tailscale), set `PHX_HOST=<host>[,<host2>]` (MagicDNS name and/or tailnet IP; append `:port` only when fronting with a proxy on a non-gateway port; IPv6 must be bracketed) in `.env` or the environment — this rebinds 0.0.0.0 and pins WebSocket origins to those hosts; to enable `/admin`, set `JIDOCLAW_ADMIN_EMAILS=you@example.com`.
- `docs/SETUP.md` if it lists env vars: add both new vars.

## Verification

1. Gates: `mix format`, `mix jidoclaw.compile_check`, `mix credo --strict`, `mix test`.
2. New tests: `mix test test/jido_claw/web/admin_access_test.exs test/jido_claw/web/plugs/require_admin_test.exs test/jido_claw/web/admin_route_test.exs test/jido_claw/web/gateway_exposure_test.exs`.
3. Manual H2 (run gateway in dev):
   - `lsof -nP -iTCP:4000 -sTCP:LISTEN` shows `127.0.0.1` (not `*`).
   - Forged-origin WS handshake rejected (403 + "Could not check origin" log):
     `curl -i "http://127.0.0.1:4000/ws/websocket?vsn=2.0.0" -H "Origin: https://evil.example" -H "Connection: Upgrade" -H "Upgrade: websocket" -H "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ=="`
   - `Origin: http://localhost:3000` is also rejected (port pinning), while `Origin: http://localhost:4000` and `Origin: http://127.0.0.1:4000` pass the origin stage (proceed to socket auth instead of origin rejection).
   - Signed-in dashboard works at both `http://localhost:4000` and `http://127.0.0.1:4000`.
   - With `PHX_HOST=<tailnet-name>` set (via `.env`): `lsof` shows `*:4000`; WS with `Origin: http://<tailnet-name>:4000` passes the origin stage; evil origin still rejected; localhost origins still accepted.
   - With `PHX_HOST="http://garbage/path,"`-style junk: boot logs a warning and stays loopback.
4. Manual H1: without `JIDOCLAW_ADMIN_EMAILS`, signed-in `GET /admin` → 404. With own email in `.env`, `/admin` renders and AshAdmin functions normally.

## Files touched

| File | Change |
| --- | --- |
| `lib/jido_claw/web/admin_access.ex` | new — `parse_admin_emails/1`, `admin_emails/0`, `admin?/1` |
| `lib/jido_claw/web/plugs/require_admin.ex` | new — 404 gate plug |
| `lib/jido_claw/web/live_user_auth.ex` | add `:live_admin_required` clause |
| `lib/jido_claw/web/router.ex` | `:require_admin` pipeline; gate + `on_mount` on `ash_admin`; trust-model + revocation comment |
| `lib/jido_claw/web/gateway_exposure.ex` | new — `parse_hosts/1`, `configure!/0`, `configure/1` |
| `lib/jido_claw/application.ex` | call `GatewayExposure.configure!()` after `load_dotenv()` |
| `config/config.exs` | loopback bind + port-pinned origin allowlist |
| `config/runtime.exs` | drop prod `check_origin` (subsumed) |
| `config/test.exs` | endpoint `server: false` |
| `lib/jido_claw/desktop/sidecar.ex` | drop `check_origin: false`; deep-merge `http` preserving loopback `ip` |
| `test/jido_claw/web/admin_access_test.exs` | new |
| `test/jido_claw/web/plugs/require_admin_test.exs` | new |
| `test/jido_claw/web/admin_route_test.exs` | new — route-level non-admin 404 + admin smoke + unauthenticated redirect |
| `test/jido_claw/web/gateway_exposure_test.exs` | new — parser edges + merge no-op/extend/junk cases |
| `README.md` (+ `docs/SETUP.md` if applicable) | document `PHX_HOST` + `JIDOCLAW_ADMIN_EMAILS` |

Out of scope (related report findings, untouched): H3 RpcChannel tenant leak, H16 Folio authorization, L1 tenant default-allow, full L19 sidecar deletion.
