# SD1 — Configuration foundation

*Builds: one dotenv authority + pure configuration derivation. Depends on:
nothing — the keystone. Contracts owned: INV-8, INV-12, INV-15, INV-23,
INV-26, INV-7 (read-side), OD-3 (the `durable?/1` law).*

> **What this owns.** Everything the diagnostics and the authority read but
> never a surface that shows it: `EnvResolver` (credential resolution without
> booting), the single dotenv parse/serialize codec, the dependency
> dotenv-loader standdown, the pure effective-provider derivation extracted
> from `Config.load/1`, and the `EndpointTrust` read-side (fingerprint codec
> + classification). **No HTTP, no database, no CLI surface, no
> Application-env writes** — the only behavioral touch is refactoring the
> existing boot loader onto the shared codec, byte-compatible.

## Current state

- Full boot loads dotenv into System env (`application.ex:60` →
  `load_dotenv/0` :639-665) with the parse entangled in `application.ex`
  (:667-738); the serializer lives separately in `setup.ex:373` and escapes
  quotes the loader never unescapes (INV-12's poison).
- ReqLLM and LLMDB auto-load cwd `.env` at THEIR app start, before ours
  (INV-8) — gated on `:req_llm, :load_dotenv` (default true, syncs llm_db's
  flag) and `:llm_db, :load_dotenv`.
- `Config.load/1`'s auto-cloud branch re-reads System env directly
  (`config.ex:94-111` via `api_key/1` → `System.get_env` :280), so the
  provider decision is untestable without global state and unusable under a
  minimal (no-dotenv-loaded) boot.

## Design

### 1. `JidoClaw.Config.EnvResolver` (`lib/jido_claw/core/config/env_resolver.ex`)

```elixir
@type parse_problem :: %{construct: atom(), path: String.t(), line: pos_integer()}  # bounded
@type resolved :: %{value: String.t() | nil,                    # effective (ambient wins)
                    source: :ambient | :persisted | :missing
                          | :unparseable,                       # typed — NOT nil (INV-15)
                    problem: parse_problem() | nil,             # set iff :unparseable
                    persisted_value: String.t() | nil,          # first-precedence dotenv resolution
                    persisted_path: String.t() | nil}
@spec resolve(String.t(), [String.t()], keyword()) :: %{String.t() => resolved()}
@spec durable?(resolved()) :: boolean()
# opts: ambient: %{name => value} (default: System snapshot), cwd: (default File.cwd!)
```

Pure core with **injected ambient map + cwd** — tests stay `async: true` with
zero global mutation. Parses the SAME four-path first-wins chain the boot
loader uses (`project/.jido/.env` → `project/.env` → `cwd/.jido/.env` →
`cwd/.env`, `application.ex:647-653`) WITHOUT `System.put_env`; ambient wins
persisted for `value`/`source`.

**Durability is value-compared, not presence-inferred** (OD-3's law):
`durable?/1` = effective `value` non-blank AND equal to `persisted_value`.
Ambient `A` + persisted `B` is NOT durable (next boot flips to `B`; the
detail names the divergence); a blank higher-precedence entry shadowing a
real later one is NOT durable (**a `KEY=` line DEFINES the var** — preserved
in the shared parse); the full-boot case (dotenv already in System env,
`source: :ambient`) compares EQUAL and correctly reads durable.
`durable?(:unparseable) == false`.

### 2. One codec (INV-12) + the boot-loader rewire

Split `application.ex`'s entangled `put_env_if_unset/1` (:683-699) into a
pure ordered parse living in EnvResolver that BOTH the boot loader and the
resolver consume — one dotenv authority, correct `reach --arch` direction
(application.ex → core). Preserve exactly: per-key unset-only puts including
`""` values, path order + `Enum.uniq`, intra-file duplicate keys
first-occurrence-wins. Parser + serializer become one property-tested inverse
pair; the loader gains the matching unescape (greenfield, no compat shim);
the serializer REJECTS values dotenv cannot represent.
`application_test`'s `load_dotenv/0` suite (:36-102) stays green.

### 3. Dep-loader standdown + Dotenvy-construct detection (INV-8, INV-15)

`config.exs` sets both `load_dotenv: false` flags (compile-time; app-env pin
test). That makes our codec the authoritative parser for files Dotenvy used
to read, so syntax divergence is detected, never silent: support `export `,
detect `${...}` interpolation / multiline-or-unterminated quoted values /
ambiguous inline comments as typed `:unparseable` (file-level scan — a quoted
block is consumed whole; no phantom assignments). Boot logs a loud warning
naming file+line+construct; parity fixtures document every construct's
disposition. Compatibility note: the lost dep-side cwd auto-load is covered
by our chain's cwd fallback paths.

### 4. Pure effective-provider derivation

Extract `load/1`'s auto-cloud decision into a pure, TOTAL helper: raw user
config + resolved credential VALUE → effective provider settings (provider,
model, `base_url` including the auto-cloud override, explicit-`base_url`
preservation via the raw-user_config check `config.ex:102`). `load/1`
delegates with System-resolved credentials — full-boot behavior
byte-compatible, `config_test` stays green; doctor/probe paths call it with
EnvResolver values. Applies `normalize_api_key/2` (the
`OLLAMA_API_KEY=ollama` sentinel, INV-23) and is total over malformed raw
config (`providers: "bad"`, non-map entries, non-binary
`api_key_env`/`base_url` → typed absence, never raise). Includes the env-var
NAME rule (INV-26) as a validation helper for downstream consumers.

### 5. `EndpointTrust` read-side (INV-7)

The fingerprint codec + classification only: parse `JIDOCLAW_ENDPOINT_TRUST`
from an injected ambient snapshot into `{provider, base_url | :default,
api_key_env | :default}` entries (fail-closed on malformed), and classify a
derived provider-settings tuple as confirmed/unconfirmed. Full boot captures
the **pre-dotenv ambient snapshot** before `load_dotenv/0` runs (the
authority placement — no project-reachable file can inject it); minimal-boot
callers pass the raw System snapshot (dotenv never loaded there).
Enforcement points come later: SD2/SD4 (never probe unconfirmed), SD5
(never install unconfirmed), SD6 (interactive session-only confirm).

## Decisions

- **D1 — EndpointTrust lives here, not SD5.** The read-side is pure
  classification over injected state, exactly this WS's shape, and SD2/SD4
  need it before SD5 exists. SD5 owns enforcement at the authority; SD6 owns
  the interactive arm. (Recommended; revisit only if SD5's interview moves
  the fingerprint format.)
- **D2 — ship order within SD1**: codec + resolver + loader rewire first
  (self-verifying against `application_test`), then the dep-loader flags +
  construct detection (the behavior change), then derivation + trust. Each
  lands compile-green with its tests.

## Test plan

`env_resolver_test.exs` (async: true; tmp `.env` files; injected
ambient/cwd): persisted-only → `:persisted` + durable; ambient WINS
persisted; durability rows (ambient≠persisted → false; blank shadow → false;
full-boot-equal → true); four-path precedence; intra-file duplicate
first-wins; codec property rows (round-trip inverse for
quote/backslash/space values; serializer refuses newline/control); Dotenvy
construct fixtures each yielding typed `:unparseable` with no fall-through
and no phantom `OTHER` var; the dep-loader app-env pin. Derivation rows:
sentinel (ambient AND persisted `OLLAMA_API_KEY=ollama` → no auto-cloud),
explicit-base_url preservation, malformed-config totality.
`config_test` + `application_test` stay green (byte-compat proof).
Trust rows: fingerprint parse (valid/malformed→closed), classification of
default vs non-default settings.

## Docs & reconciliation (lands with this WS)

- No `docs/system/` page yet (SD4 creates it, OD-2) — but the dep-loader
  standdown is a user-visible behavior change: record the compatibility note
  (cwd `.env` still honored via our chain; unsupported constructs warn
  loudly) in the commit message + a short note the SD4 page will absorb.
- HD-10 check: `application.ex` edits are path-existence-only for the
  clustering/gateway-runtime-security/verify-authority pages — verify no
  semantic overlap at build, no `verified:` bumps expected.
- `## Deviations` maintained in this doc as built.

## Cross-references

- [CONTRACTS.md](CONTRACTS.md) — INV-8, INV-12, INV-15, INV-23, INV-26,
  INV-7, OD-3, HD-5, HD-6, HD-10.
- Consumers: [SD2](SD2-provider-diagnostics.md) (derivation feeds the probe),
  [SD4](SD4-read-only-doctor.md) (resolver + trust classification),
  [SD5](SD5-runtime-provider-authority.md) (derivation + trust enforcement),
  [SD6](SD6-repair-and-reconfigure.md) (codec serializer + winning-path
  upsert).
