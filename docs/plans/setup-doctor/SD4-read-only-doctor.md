# SD4 — Read-only doctor (`--check`) — **#17a**

*Builds: `Doctor.derive/2` + report, the minimal check-lane boot, `--setup
--check` (mix + escript), `/setup check` (REPL), and the check exit codes.
Depends on: SD1, SD2, SD3. Contracts owned: INV-9, INV-14, INV-24, ST-4,
OD-2 (page creation), OD-3 (health law), HD-1, HD-2, HD-3, HD-5, HD-6, HD-7,
HD-10. **This is the first useful user-facing deliverable** — an honest "is
this install healthy" answer that mutates nothing. The repair loop and any
global mutation are explicitly out (SD6); the generation authority is
explicitly out (SD5).*

> **What this owns.** A pure derivation from install state to a typed check
> list, printed honestly, exiting honestly — beside today's **untouched**
> wizard. After SD4: `mix jidoclaw --setup --check`, `./jidoclaw --setup
> --check`, and `/setup check` exist and change nothing; plain `/setup`
> still behaves exactly as it does today (wholesale wizard) until SD6
> replaces the default lane.

## Design

### 1. `Doctor` — pure derivation (`lib/jido_claw/cli/setup/doctor.ex`)

```elixir
@type step :: :config | :provider_key | :voyage_key | :model | :database
@type status :: :ok | :gap | :error | :unsupported | :unavailable
@type check :: %{step: step(), status: status(), detail: String.t(),
                 reason: atom() | nil,          # machine-readable, e.g. :unparseable | :unknown_provider
                 repairable?: boolean(),
                 source: :persisted | :ambient | :missing | nil,  # credential steps (EnvResolver's union)
                 durable?: boolean() | nil,     # display + persist-offer input ONLY (OD-3)
                 data: map()}                   # typed repair payload (e.g. ollama inventory); %{} otherwise
@spec derive(String.t(), keyword()) :: {map(), [check()]}   # probes injected via opts
@spec repairs([check()]) :: [step()]        # :gap/:error AND repairable?; :database always print-only
@spec persist_offers([check()]) :: [step()] # the NON-GAP lane: :ok credential checks with durable?: false
@spec healthy?([check()]) :: boolean()      # :ok/:unsupported pass; :unavailable/:gap/:error FAIL
@spec print([check()]) :: :ok
```

`:unsupported` = expected-absent capability (healthy); `:unavailable` =
indeterminate (fails). `repairable?` is set by the check, never inferred
from status. `derive/2` performs zero mutations of any kind. `repairs/1` and
`persist_offers/1` are pure derivations shipped now and consumed by SD6.

### 2. The checks

- **`:config`** — dispatch on **`File.exists?`** of `.jido/config.yaml`
  (`read_user_config` maps missing AND empty to `{:ok, %{}}`), then
  deterministic validation BEFORE any probe: broken YAML → `:error`
  `:unparseable`, `repairable?: false` (backup-and-replace guidance printed;
  the file is never auto-touched); provider missing/unknown → repairable
  `:gap`; literal `ollama_cloud` **normalizes to ollama during validation**
  (HD-5); malformed `providers` subtree — non-map container, non-map ACTIVE
  entry, non-binary `api_key_env`/`base_url`, or an `api_key_env` failing
  INV-26's name rule (validated BEFORE any resolution) → `:gap`
  `:invalid_provider_config`. **Model-VALUE problems emit as `step: :model`
  checks, not `:config`** (repair dispatch is per-step): non-binary /
  prefix-mismatch (modulo ollama_cloud; split `parts: 2`, HD-6) / blank
  native id (`"openai:"`) / component-less openrouter id (`"openrouter:/"`)
  → `:model` `:gap` `:invalid_model`/`:provider_model_mismatch`. Probes are
  SKIPPED unless config validates.
- **`:provider_key` + `:model`** — **trust classifies FIRST** (INV-7): a
  non-default `base_url`/`api_key_env` without an `EndpointTrust`
  confirmation → `:config` `:gap` `:unconfirmed_override`; probe never
  invoked, custom-named credential never read, both dependent checks
  `:unavailable`. Then **credential absence classifies BEFORE any probe**
  (INV-24). Otherwise ONE probe pass feeds both (openrouter takes two
  requests); checks carry `source`/`durable?`. Routing on machine-readable
  probe fields only: only `auth: :invalid` yields the key-repairable gap;
  `access: :denied` + `auth: :ok` keeps `:provider_key` `:ok` and sends
  `:model` to non-repairable `:unavailable`; `endpoint: :divergent` →
  `:model` `:unavailable` reason `:endpoint_divergence`, both URLs in
  detail.
- **`:voyage_key`** — EnvResolver presence + `source`/`durable?`
  (presence-only, no probe); policy SHARED with BootGuard (INV-14).
- **`:database`** — SD3's `migration_status/1`: N pending → `:gap`
  (print-only); `:migration_drift` → non-repairable `:gap`; unreadable →
  `:unavailable`.

### 3. Minimal check-lane boot + entry points

- **Mix arm** (`lib/mix/tasks/jidoclaw.ex:65-75`): the `--setup` head parses
  `--check`; the check lane runs `Mix.Task.run("app.config")` +
  `ensure_all_started([:inets, :ssl, :req_llm])` (INV-9 — registry/catalog
  populated tree-less; dotenv-safe by SD1's INV-8). Keep the plain
  `:project_dir` put; the wizard lane keeps `app.start` untouched until SD6.
- **Escript arm** (`main.ex:75-87`, HD-1): the `--check` branch boots via
  `Application.load(:jido_claw)` (tolerate `{:already_loaded, _}`) +
  `ensure_all_started([:inets, :ssl, :req_llm])`, routed through an
  injectable seam mirroring `cli_app_starter` so the
  `jido_exec_patch_test.exs:651-679` fall-through pin survives (HD-3 —
  update the row in the same change). Exits via the seam-aware `halt!/1`.
- **Delete `:force_setup`** (HD-2 — dead at HEAD): the `main.ex:82` write,
  the `setup.ex:22` cond head, the `@cli_env_keys` entry (:616).
- **REPL**: `/setup check` + `/setup --check` heads above `"/setup"` in
  `commands.ex`; never exits the REPL; mutates nothing.
- **Exit codes**: check dispositions `:check_healthy | :check_unhealthy`
  (ST-4); the pure disposition→code mapper returns 0 iff `healthy?/1`, else
  1. Flags are safe against project-dir resolution (`startup.ex:330-338`
  skips `--`-prefixed args — verified).
- The JidoClaw supervision tree NEVER starts on the check lane.

### 4. What SD4 deliberately does not do

Plain `/setup` / `--setup` (config absent or present) is byte-identical to
today — the wizard, full boot and all. No repairs, no persist offers
(the pure `repairs/1`/`persist_offers/1` functions exist, unconsumed), no
`Setup.run` signature change, no wizard rework. SD6 owns the default lane.

## Decisions

- **D1 — endpoint verdict disposition before SD5 lands.** With no authority,
  generation resolves provider defaults while config says otherwise — for
  any override-configured install (including auto-cloud ollama configs),
  `endpoint: :divergent` is the TRUE state. Recommend **honest red**:
  `--check` fails with detail naming both URLs and "generation does not yet
  consume configured endpoints" — matching the doctor's whole ethos and
  creating the right pressure toward SD5. Alternative (an
  informational-amber `:unsupported` until SD5 ships) hides a real
  divergence; take it only if the interview prefers a quiet interim.
  Whichever is chosen, the flip lands in SD5's Deviations.
- **D2 — voyage-required-policy predicate location** (shared with BootGuard,
  INV-14): extract into the boot-guard module vs a config helper — pick at
  build, pin with the opt-out row either way.

## Test plan

`doctor_test.exs` (async: true; tmp dirs; injected probes — never live
network): healthy → all `:ok`/`:unsupported`, `repairs == []`, `healthy?`;
per-check gap/error rows (broken YAML non-repairable + guidance;
unknown-provider; ollama_cloud normalization; every malformed-subtree +
malformed-NAME row proving no System-env function and no dotenv write is
ever reached; model-value rows on `step: :model` incl. multi-colon ids;
missing-credential rows with the probe fun NEVER invoked; ollama keyless
exempt); trust rows (unconfirmed override → `:unconfirmed_override`, probe
never invoked, custom var never read — ambient seam proves no lookup;
malformed trust fails closed; the `run_command` exploit row — agent-written
artifacts arm nothing); `endpoint: :divergent` → `:model` `:unavailable`
with both URLs; `:migration_drift` fails `healthy?`; pending migrations →
gap NOT in `repairs/1`; `durable?: false` alone never fails `healthy?`
(OD-3 pin); voyage opt-out row (INV-14); derive performs zero mutations;
no-config check-only regression (fresh tmp dir → `:config` gap, zero
prompts, directory bytes untouched). Entry-point rows: pure
disposition→code mapping; the updated `jido_exec_patch_test` `["--setup"]`
row (halt(2) pin preserved); pruned `@cli_env_keys`. House style: mix-task
output via `ExUnit.CaptureIO` (HD-7).

## Verification (beyond the suite)

- `mise exec -- mix jidoclaw --setup --check` on this checkout — must not
  start the app tree; prints the derivation; exits honestly.
- Corrupt `.jido/config.yaml` in a scratch dir → `:config` `:error`, no
  wizard launch.
- Fresh-VM minimal drive: `--setup --check` in a scratch dir with a cloud
  config proves the `:req_llm` registry populates tree-less (INV-9).
- **Escript smoke** (precommit never builds it): `mise exec -- mix
  escript.build`, then `./jidoclaw --setup --check` in a scratch dir — pin
  the printed derivation + exit status, no app-tree side effects.

## Docs & reconciliation (lands with this WS)

- **Create `docs/system/setup-doctor.md`** (OD-2) + the AGENTS.md Key
  Patterns bullet + the `docs/system/README.md` index entry, same commit
  (`system_docs.check` enforces the pairing). Scope at SD4: check contract,
  minimal boot, durability laws (OD-3), the probe table (SD2), migration
  bounds (SD3), trust gating, disposition→exit map — with an explicit
  "repairs land in SD6 / generation authority in SD5" status block.
- **docs/SETUP.md**: document `--check` / `/setup check` (the wizard docs
  stay as-is until SD6).
- `docs/exploration/pms/pad/PD-FIRST-WAVE.md` item 3 +
  `docs/plans/pre-argus-do-now/README.md` §17: dated **PARTIAL** Status —
  #17a shipped (check surface); repairs (SD6) pending.
- HD-10 check: re-verify `cli/main.ex` edits stay outside
  gateway-runtime-security.md's claims.
- `## Deviations` maintained in this doc as built.

## Cross-references

- [CONTRACTS.md](CONTRACTS.md) — INV-7, INV-9, INV-14, INV-24, INV-26,
  ST-4, OD-2, OD-3, HD-1/2/3/5/6/7/10.
- [SD1](SD1-configuration-foundation.md) resolver/derivation/trust ·
  [SD2](SD2-provider-diagnostics.md) probe ·
  [SD3](SD3-migration-diagnostics.md) DB probe ·
  [SD6](SD6-repair-and-reconfigure.md) consumes `repairs/1` +
  `persist_offers/1` and replaces the default lane.
