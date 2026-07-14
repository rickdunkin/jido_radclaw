# SD2 — Provider diagnostics

*Builds: `ProviderProbe` + the bounded Mint adapter + per-provider
auth/model semantics + the endpoint verdict. Depends on: SD1 (effective
settings + trust classification arrive derived; the probe never reads System
env). Contracts owned: INV-6, INV-17, INV-21, INV-22, INV-25, INV-29,
INV-30, ST-1, ST-2, HD-4, HD-11.*

> **What this owns.** A read-only, explicitly-parameterized probe of one
> provider: is the endpoint reachable, is the credential valid, is the
> configured model actually there, and does the configured endpoint match
> what generation would resolve. **Entirely read-only; credentials and
> settings are passed in — never resolved from global state.** Also the
> `check_provider/2` wrapper swap, which gives the existing REPL banner and
> wizard connection-test the corrected semantics (and gives queue #6's
> credential canary its probe — the XA2-3 surface).

## Current state

- `check_api_key` (`config.ex:362-379`) sends Bearer to ALL providers —
  wrong scheme for anthropic (`x-api-key` + `anthropic-version`) and google
  (`x-goog-api-key`); 5s `:httpc`, status-only.
- `check_ollama` (`config.ex:348-360`) never parses `/api/tags` — model
  membership is NEW behavior (HD-4).
- Nothing distinguishes 401 (bad key) from 403 (valid-but-restricted key),
  so a restricted key would loop a key-replacement repair.

## Design

### Contract

```elixir
# lib/jido_claw/core/config/provider_probe.ex
@spec probe(map(), keyword()) :: %{reachable: boolean(),
                                    auth: :ok | :invalid | :unknown,
                                    access: :ok | :denied | :unknown,     # machine-readable; never parse detail
                                    model: :present | :absent | :unknown | :unsupported,
                                    endpoint: :equal | :divergent | :not_applicable,
                                    inventory: [String.t()] | nil,        # ollama: decoded tags up to a hard cap
                                    inventory_truncated?: boolean() | nil,
                                    detail: String.t()}
```

Effective settings + credential arrive explicitly (SD1's derivation); the
probe never reads System env. Key-required providers short-circuit a nil
credential without invoking the adapter (defense in depth under SD4's
pre-classification). Unknown provider → total fallback (validation catches
it first).

### Per-provider semantics — retrieve-by-id, against the endpoint generation will use

Requests target the CONFIRMED (`EndpointTrust`) configured `base_url` when
present, else the provider's official base. Model presence via retrieval,
never first-page listing:

| Provider | Auth + model check | Notes |
|---|---|---|
| anthropic | `GET /v1/models/{id}` — `x-api-key` + `anthropic-version` | 403 = `access: :denied`, `auth: :ok` |
| openai / groq / xai | `GET /v1/models/{id}` — Bearer | groq ids carry `/` → INV-30 encoding |
| google | `GET /v1beta/models/{name}` — `x-goog-api-key` header (never query-string creds) | ST-1: invalid key arrives as **400 `API_KEY_INVALID`** → bounded total error-body decode |
| openrouter | TWO requests (INV-21): auth from `GET /api/v1/key` ONLY; model from `GET /api/v1/model/{author}/{slug}` (bearer sent; aliases + `:free` variants) | `/key` 403 = restricted valid key, never the key repair |
| ollama | `/api/tags` membership over the FULL decoded inventory (ST-2), `:latest` canonicalized both directions; typed `inventory` + `inventory_truncated?` ride the result (INV-29) | effective settings via SD1's derivation (auto-cloud, sentinel) |

Status mapping: 200 → auth ok + `:present`; 401 → `auth: :invalid`; **403 is
NOT a bad key** → `access: :denied` + `auth: :ok` (else `:unknown`), `model:
:unknown`; **404 → `:absent` only on a provider-OWNED endpoint** — on a
configured override it is non-repairable `model: :unknown` naming the route
(INV-22; the generation-only-gateway fixture pins it); other statuses →
`:unknown` with the status in detail (never conflated with unreachable);
transport error → `reachable: false`. An incomplete search can only yield
`:unknown`/`:unavailable`, never a repairable `:gap`.

### The endpoint verdict (INV-6) + canonicalizer (INV-17)

Computed for the ACTIVE provider whenever a `base_url` override is
configured, and for ollama always; `:not_applicable` only for an
override-less non-ollama provider. ONE arm, pure, fail-closed:
`effective_base_url(provider_mod, model, base_url: desired)` injects the
candidate on ReqLLM's opts leg (below `model.base_url`, above app config) —
result ≡ desired (canonicalized) ⇔ `:equal`; anything else, including a
model-level `base_url` and a resolver raise, → `:divergent`. No installed
state needed, so check mode stays mutation-free. Requires the resolver
runtime (`:req_llm` started — SD4's minimal boot provides it; full-boot
callers have it free). The two-layer canonicalizer (generic URI
validation/normalization for all; root↔`/v1` translation for ollama ONLY) is
shared with SD5's install guards. Named residual: per-request `base_url:`
opts would evade the check (structurally absent — no `lib/` call site passes
it; SD5 re-records this at the authority).

### The bounded Mint adapter (INV-25, HD-11)

Injectable adapter with a normalized contract — `request.(method, url,
headers) :: {:ok, %{status: non_neg_integer(), body: binary()}} | {:error,
term()}` — 5s deadline (injectable), timeout → `{:error, :timeout}` →
`reachable: false`. Default implementation is Mint-based with a **total
raw-response byte budget counted on transport messages BEFORE they feed
Mint's parser** (covers status+headers+trailers+body on every status);
exceed → close + `{:error, :response_too_large}` → `model: :unknown`, never
false-absent, never memory exhaustion. Promote `{:mint, "~> 1.9"}` to a
direct dep. No extra processes under minimal boot; mailbox drained on close.

### `check_provider/2` wrapper + both callers

`Config.check_provider/1` (`config.ex:334-346`) becomes
`check_provider(config, opts \\ [])` — thin wrapper deriving
`:ok | {:error, :unauthorized | :unreachable | :endpoint_divergence}`
(contract extension, deviation-logged); `opts` accepts `project_dir:` and/or
`credential:`. Both callers updated in the same change: the REPL banner
(`repl.ex:161-174` — a missed arm is a boot-time CaseClauseError) and the
wizard `test_connection` (`setup.ex:261-278`). A persisted-only credential
now resolves correctly when `project_dir ≠` process cwd.

## Decisions

- **D1 — wrapper trust behavior before SD4 exists.** Recommend the wrapper
  honors `EndpointTrust` from day one, fail-closed: an unconfirmed override
  is not probed and surfaces as a distinct error atom the banner prints
  honestly. The alternative (probe overrides untrusted until SD4) keeps the
  CB1-1 window open for the banner path; rejected unless the interview says
  otherwise.
- **D2 — probes on overrides that are confirmed but divergent.** The probe
  reports `endpoint: :divergent` as data; policy (what fails health) is
  SD4's D1. This WS only guarantees the field is total and honest.

## Test plan

`provider_probe_test.exs` (async: true; injected adapter/resolver):
per-provider request shapes (headers + exact URLs, including slash-bearing
groq ids and openrouter author/slug component encoding); ST-1 google 400/403
fixture rows; INV-21 openrouter rows (auth from `/key` only;
restricted-valid-key; bearer on lookup); canned-status table (404→`:absent`,
405→`:unknown`, 401 vs 403 split); nil-credential short-circuit;
configured-override routing + the generation-only-gateway 404 fixture;
sentinel rows through the derivation; endpoint rows (`localhost:11434` ≡
`…/v1`; non-ollama `/v1`-only difference → `:divergent`; query/userinfo/
missing-host/malformed-port → `:divergent`; model-level `base_url` fixture →
`:divergent`; resolver raise → `:divergent`); inventory rows (tagged/untagged
both directions, past-truncation still `:present`, cap-exceeded →
`:unknown`, typed fields ride the result). Mint-adapter glue against a local
`:gen_tcp` stub: normal decode, timeout mapping, oversized/unbounded bodies
on 200 AND 400 AND 500, never-terminated status/header/trailer streams —
budget trips, memory bounded. Wrapper rows: both callers' arms (banner
resolver-raise row pinned), persisted-only credential with `project_dir ≠`
cwd.

## Docs & reconciliation (lands with this WS)

- ades **XA2-3**
  (`docs/exploration/ades/Xantham-system-blueprint/FEATURES-WORTH-BORROWING.md:100`):
  dated cross-ref — the manual provider-check surface lands here; the
  scheduled canary (queue #6) stays separately tracked and should consume
  `ProviderProbe`.
- No system page yet (SD4 absorbs the probe table into
  `docs/system/setup-doctor.md`, OD-2).
- `## Deviations` maintained in this doc as built — including any provider
  verified at build to require raw (unencoded) slashes (INV-30's escape
  hatch).

## Cross-references

- [CONTRACTS.md](CONTRACTS.md) — INV-6, INV-17, INV-21, INV-22, INV-25,
  INV-29, INV-30, ST-1, ST-2, HD-4, HD-11.
- [SD1](SD1-configuration-foundation.md) — derivation + trust
  classification. [SD4](SD4-read-only-doctor.md) — the doctor consumes the
  probe's machine-readable fields (never detail).
  [SD5](SD5-runtime-provider-authority.md) — shares the canonicalizer;
  probe-what-you-use targets its resolution.
- Adjacent, recorded not built: routing the web-side
  `JidoClaw.Setup.CredentialValidator` through `ProviderProbe` is a
  follow-up.
