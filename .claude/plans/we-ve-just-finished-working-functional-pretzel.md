# Resolve code-review findings on the H1/H2 work

## Context

The H1/H2 security work (plan `please-review-docs-reports-code-review-2-eager-sunbeam.md`) is done; a follow-up review produced 3 findings. All three were verified against source and are **valid**:

1. **[P2] `PHX_HOST` in the environment breaks `gateway_exposure_test.exs`.** The `configure/1` describe's setup (test/jido_claw/web/gateway_exposure_test.exs:55-59) captures the *live* endpoint env as `original` — but `Application.start/2` has already run `load_dotenv()` + `GatewayExposure.configure!()` (lib/jido_claw/application.ex:39-44). With `PHX_HOST` set (env var or `.env`, the documented dev setup), the captured baseline is already exposed. Traced exactly 2 failures, matching the reviewer's repro:
   - `"nil is a no-op"` asserts `config[:http][:ip] == {127,0,0,1}` → it's `{0,0,0,0}`.
   - `"valid hosts extend origins"` expects `host_origins ++ base_origins`, but `base_origins` already contains `"//box.ts.net:4000"`, which `Enum.uniq` in `apply_exposure/1` dedupes → list mismatch.
2. **[P3] Sidecar port changes leave `check_origin` pinned to 4000.** `Desktop.Sidecar.maybe_configure_endpoint/0` (lib/jido_claw/desktop/sidecar.ex:30-40) sets `http[:port]` to a random/env port but inherits the base `//…:4000` origins — a browser at `localhost:<other-port>` would get LiveView/WS origin 403s. Still dead code (grep confirms no callers); per the prior decision, full L19 deletion stays out of scope — defuse the footgun instead.
3. **[P3] Docs contradict the implemented `/admin` behavior.** `RequireAuth` redirects unauthenticated users to `/sign-in` (lib/jido_claw/web/plugs/require_auth.ex); only signed-in non-admins hit `RequireAdmin`'s 404. The route test already asserts exactly this (test/jido_claw/web/admin_route_test.exs:27-41). Two doc spots claim 404-for-signed-out: README.md:394 and docs/SETUP.md:208. Doc fix only — no behavior change: redirect-for-signed-out matches every authenticated route, so it advertises nothing.

## Fix 1 — pin a known baseline in `gateway_exposure_test.exs` (P2)

Replace the `configure/1` describe setup: save the live config, install the config.exs baseline for the three keys `configure/1` touches, restore the live config in `on_exit`. `%{original: ...}` becomes the baseline, so every existing assertion works unchanged and deterministically.

```elixir
# The app has already loaded .env and run GatewayExposure.configure!/0
# (application.ex) by the time tests run, so the live endpoint env may
# already be exposed (e.g. a dev PHX_HOST). Pin the keys configure/1
# touches to the config.exs baseline; restore the live config afterwards.
setup do
  live = Application.get_env(:jido_claw, @endpoint_key, [])

  baseline =
    live
    |> Keyword.update(
      :http,
      [ip: {127, 0, 0, 1}, port: 4000],
      &Keyword.merge(&1, ip: {127, 0, 0, 1}, port: 4000)
    )
    |> Keyword.update(:url, [host: "localhost"], &Keyword.put(&1, :host, "localhost"))
    |> Keyword.put(:check_origin, ["//localhost:4000", "//127.0.0.1:4000", "//[::1]:4000"])

  Application.put_env(:jido_claw, @endpoint_key, baseline)
  on_exit(fn -> Application.put_env(:jido_claw, @endpoint_key, live) end)
  %{original: baseline}
end
```

`:http`/`:url` are deep-merged via `Keyword.update` so unrelated nested endpoint config survives; `:check_origin` is a flat list that may contain live host origins, so it alone is replaced wholesale. No test-body changes needed. Restoring `live` (not the baseline) in `on_exit` keeps the real env intact for other test files (e.g. `admin_route_test.exs`, which starts the endpoint).

## Fix 2 — re-pin sidecar origins to the chosen port (P3)

In `lib/jido_claw/desktop/sidecar.ex` `maybe_configure_endpoint/0`, after the existing `:http` deep-merge, replace `check_origin` with the loopback trio pinned to the sidecar port (replace, don't extend — the sidecar binds loopback only, so loopback origins at the bound port are exactly the valid set):

```elixir
|> Keyword.put(:check_origin, [
  "//localhost:#{port}",
  "//127.0.0.1:#{port}",
  "//[::1]:#{port}"
])
```

Extend the existing comment: base origins are pinned to the default gateway port and would 403 WS connections on any other port. Deleting the module (+ the `JIDOCLAW_PORT` parse guard) stays tracked as L19.

**New test `test/jido_claw/desktop/sidecar_test.exs`** — locks in the selected-port `check_origin` behavior since this is the second latent footgun defused in this dead path. `async: false`; setup saves and restores `JIDOCLAW_DESKTOP`, `JIDOCLAW_PORT`, `BURRITO_TARGET`, and the endpoint Application env (same save/restore discipline as `gateway_exposure_test.exs`). Cases:

- desktop env unset → `maybe_configure_endpoint/0` returns `:not_desktop`, endpoint env untouched.
- `JIDOCLAW_DESKTOP=true` + `JIDOCLAW_PORT=4321` → returns `{:ok, 4321}`; `http` is loopback ip + port 4321 with other `http` keys preserved; `server: true`; `check_origin == ["//localhost:4321", "//127.0.0.1:4321", "//[::1]:4321"]`.

## Fix 3 — correct the `/admin` docs (P3)

- `README.md:394`: replace "Non-allowlisted (and signed-out) users get a 404 for `/admin`." with: "Signed-in users who aren't allowlisted get a 404 for `/admin`; signed-out users are redirected to `/sign-in`, as on any authenticated route."
- `docs/SETUP.md:208`: replace the trailing "— it 404s for everyone otherwise." with: "— signed-in users who aren't allowlisted get a 404 (signed-out users are redirected to `/sign-in`)."

Grep confirmed these are the only two spots with the wrong claim; the `RequireAdmin` moduledoc is accurate at plug level and needs no change.

## Files touched

| File | Change |
| --- | --- |
| `test/jido_claw/web/gateway_exposure_test.exs` | setup pins baseline env (deep-merged) instead of trusting live env |
| `lib/jido_claw/desktop/sidecar.ex` | `check_origin` re-pinned to sidecar port |
| `test/jido_claw/desktop/sidecar_test.exs` | new — `:not_desktop` no-op + selected-port loopback/origin merge |
| `README.md` | `/admin` 404 wording |
| `docs/SETUP.md` | `/admin` 404 wording |

## Verification

1. **The reviewer's repro must now pass**: `env PHX_HOST=box.ts.net mix test test/jido_claw/web/gateway_exposure_test.exs` (was 2 failures), plus a plain `mix test test/jido_claw/web/gateway_exposure_test.exs`.
2. New sidecar test: `mix test test/jido_claw/desktop/sidecar_test.exs`.
3. Full gates: `mix format`, `mix jidoclaw.compile_check`, `mix credo --strict`, `mix test`.
