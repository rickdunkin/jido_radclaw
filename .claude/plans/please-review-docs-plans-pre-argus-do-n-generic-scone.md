# Plan: pre-argus Wave E #17 — `/setup` as a state-derived doctor (PD3-1)

## Context

Executes **#17 only** from
[the pre-argus do-now queue](../../docs/plans/pre-argus-do-now/README.md):
`/setup` as a state-derived doctor (pad PD3-1). The six-item Wave E plan and
the two-item #16+#17 cut both proved too large; **#16 shipped separately**
(commit `4cf076dc`, 2026-07-12) and **#18–#21 stay deferred** (the draft
`.claude/plans/please-review-docs-plans-pre-argus-do-no-tranquil-hoare.md`
remains their reference). #17 is independent of all of them. Greenfield — no
compat shims.

Today, re-running setup replaces `config.yaml` wholesale, the wizard
session-only-sets credentials, and there is no way to check an install's
health without mutating it. This plan reworks `/setup` into per-step live
checks (config present/valid, provider key valid, voyage key, configured
model reachable, DB migrated), act-only-on-gaps repairs, and a `--check`
mode that prints the derivation and changes nothing.

The `#17` section of the prior draft
`.claude/plans/please-review-docs-plans-pre-argus-do-no-generic-popcorn.md`
carries **binding operator decisions** (interview 2026-07-12 + three
same-day review rounds); this plan is that section re-verified against HEAD
`4cf076dc` (2026-07-14, three-reader sweep + a dedicated integration
stress-test), extended by a **2026-07-14 operator interview** resolving
three new decisions the reduced scope and HEAD drift created:

1. **Ollama endpoint authority — Branch A (wire it).** Verified gap:
   `config.yaml`'s `providers.ollama.base_url` (incl. the auto-cloud
   `https://ollama.com` write, config.ex:94-111) is read ONLY by the health
   probe today — generation resolves through ReqLLM (per-request opt →
   `:req_llm` app env → provider default `http://localhost:11434/v1`,
   deps/req_llm options.ex `base_url_from_application_config`; the custom
   provider is `JidoClaw.Providers.Ollama`, registered config.exs:149-151)
   and **nothing installs the config value into that chain** (no lib/ call
   site passes `base_url:`; no `:req_llm` put anywhere). The doctor as
   drafted would certify an endpoint generation never uses. Decision: one
   guarded `Config.apply_generation_env/1` wires config → `:req_llm` app
   env at the boot seams and inside `Setup.run/2` (§3; the architecture
   review generalized it from ollama-only to every active provider with a
   configured `base_url` — same mechanism, one function). Known behavior
   change, accepted: a cloud key alongside a local daemon flips generation
   from localhost-proxied to ollama.com direct, and previously-ignored
   provider `base_url` overrides become live.
2. **Docs scope — system page + bullet.** Overrules the draft's "no
   docs/system page" line: new `docs/system/setup-doctor.md` + an AGENTS.md
   Key Patterns bullet (machine-guarded by `system_docs.check` both ways).
3. **Durability stays display-only.** The stress-test's `:not_durable` gap
   (valid-but-not-dotenv-persisted key fails `--check`) is REJECTED: it
   contradicts the binding "only `auth: :invalid` yields the key-repairable
   gap" rule, and a shell-profile-exported key is restart-safe yet reads
   non-durable — a permanent false red. Durability shows in the report
   (shell-profile caveat named in the detail) and drives the interactive
   persist-offer only; never `healthy?/1`.

**HEAD-drift corrections folded in** (vs the 2026-07-12 draft):

- **`cli/main.ex` was rewritten by the #16 commit**: the escript `--setup`
  arm is now `main.ex:75-87` — `persistent: true` app-env puts (comment
  :77-79: `app: nil` + `Application.load` clobbers non-persistent env) and
  boot via the checked `start_app_or_halt!()` (:83, def :114-123,
  injectable `cli_app_starter` seam, exit 2 on failure). Verified: the arm
  **exits after `Setup.run`** (ends with an `IO.puts` + `:ok`; the REPL is
  a separate `main/1` clause :89-102) — minimal boot composes cleanly.
- **`:force_setup` is dead code at HEAD**: writer main.ex:82, sole reader
  `Setup.needed?/1` (setup.ex:22) — never consulted on the escript arm
  (which calls `Setup.run` directly), and the mix arm never sets it. Delete
  the write, the `needed?/1` cond head, and the `@cli_env_keys` snapshot
  entry (jido_exec_patch_test.exs:616). repl.ex:95 / run_command.ex:230
  keep identical `needed?/1` behavior.
- `test/jido_claw/core/jido_exec_patch_test.exs:651-679` pins the
  `["--setup"]` argv through the checked-boot fall-through (injected
  starter error → `halt(2)`). The reworked arm must keep an equivalent pin:
  route its minimal boot through the same injectable-seam shape and update
  the row in the same change (decided: mirror the seam, don't drop the row).
- `check_ollama` (config.ex:348-360) is status-only today — it never parses
  the `/api/tags` body; the probe's tags-membership model check is **new
  behavior**.
- `ollama_cloud` is a wizard **pseudo-provider** (available_providers
  config.ex:385-397 includes it; setup.ex:247-254 + `build_config` :238 map
  it to provider `"ollama"` + `base_url`); a hand-edited
  `provider: "ollama_cloud"` would pass a literal membership test —
  **normalize ollama_cloud→ollama during `:config` validation** instead.
- Model ids are `provider:model` strings with possibly more colons
  (`"ollama:nemotron-3-super:cloud"`); split `parts: 2` (the repl.ex:988 /
  setup.ex:211 precedent).
- House mix-task test style is **`ExUnit.CaptureIO`** (`Mix.Shell.Process`
  has zero precedent); prompt/IO seams are injected opts (no seam exists
  today; prompts are raw `IO.gets`, setup.ex:418/:440).
- **No scratch-repo/`storage_up` precedent** exists — the cold-DB probe
  test is first-of-kind and must be partition-safe (`MIX_TEST_PARTITION`).
- `check_api_key`'s 5s timeout is at config.ex:370 (:353 is
  `check_ollama`'s); Req/Finch are direct deps but `:httpc` stays the
  decided adapter (zero extra apps under minimal boot; matches the replaced
  code).
- `Ecto.Migrator`'s listing **cannot be bounded**: `skip_table_creation`
  works (migrator.ex:555-565), but the versions SELECT runs
  `timeout: :infinity` (schema_migration.ex `@default_opts` via
  migrator.ex all_opts) — so the probe uses a bounded direct query instead
  (§1), keeping the read-only guarantee AND boundedness.
- Docs-page bumps: `core/config.ex` is in `tool-approval.md` sources and
  `application.ex` in clustering/gateway-runtime-security/verify-authority
  sources — path-existence only, no semantic overlap from these edits, so
  no `verified:` bumps; `cli/main.ex` is in gateway-runtime-security.md
  sources — re-check at build that the `--setup`-arm rework stays outside
  that page's claims (expected: yes).

**Stress-test resolutions taken as recommended** (deviation-logged, not
re-interviewed): google's invalid-key responses arrive as 400
`API_KEY_INVALID`, not 401 — bounded error-body decode added; ollama
membership computes over the FULL decoded inventory before any display
bound, with `:latest`-tag canonicalization both directions (never rewriting
config); ollama `:absent` repair is inventory-driven (picker over installed
models; empty inventory → non-repairable + `ollama pull` guidance) while
non-ollama `:absent` keeps the `pick_model` catalog repair; the check
disposition splits into `:check_healthy | :check_unhealthy` so the
disposition→exit mapper stays pure; the path-taking dotenv upsert requires
missing-or-regular by lstat (symlink/dir → refuse loudly, rescued to
`:session_only`); all DB probe test rows run on the scratch repo (the
already-started branch via a manually started scratch repo — never
`JidoClaw.Repo`, whose sandbox pool the probe must not touch).

**Review-hardened invariants (2026-07-14 plan reviews)** — verified
findings woven into the sections below; listed here as the non-obvious
design facts:

- **Load-safe `:req_llm` install**: `Application.load/1` does not load
  dependencies, and a plain put on an UNLOADED app is clobbered when
  `ensure_all_started` later loads it (the hazard run_command.ex:265-272's
  doc records; its `load_app_spec!/1` idiom is the fix). Exactly two
  install owners: `JidoClaw.Application.start/2` (full boots — OTP starts
  dependencies first, so this owner runs post-load BY CONSTRUCTION and no
  pre-boot `:req_llm` put exists on any path) + `Setup.run/2` (minimal
  boot, load-safe via `load_app_spec!`). Verified by a fresh-VM spot
  drive at build (the in-suite VM has already booted — an
  `ensure_all_started` pin there would be vacuous).
- **The generation bridge carries the CREDENTIAL too, authoritatively**:
  ReqLLM's key lookup (keys.ex `Keys.get/2`) reads per-request opt →
  `Application.get_env(:req_llm, :"<provider>_api_key")` → the provider's
  FIXED env var — our configurable `api_key_env` is invisible to
  generation, and `Provider.Defaults` always requires a key (keyless local
  ollama would fail generation despite a green probe). §3's install
  therefore bridges the doctor's effective resolution: present → the
  value (incl. the local placeholder); **absent → a BLOCKING empty
  install** — never a bare delete, which would let `Keys.get/2` fall
  through to a fixed env var the doctor never probed. Pinned through
  ReqLLM's real `Keys.get/2`.
- **The bridge is INERT under test-boot sanitization**: when
  `:sanitize_external_env` is enabled (config/test.exs — the test-boot
  credential-isolation guarantee), the bridge installs nothing; real
  ReqLLM state is exercised only by the explicit async: false live-pins
  rows with snapshot/restore.
- **Bridge refusal is typed and fail-closed on state — but the credential
  block SURVIVES refusal**: the bridge returns a desired-state result; a
  guard refusal clears bridge-owned ENDPOINT entries (a valid→invalid
  transition never leaves a stale endpoint installed) while the active
  provider's credential rule stays in force (value or blocking empty —
  clearing it would reopen the fixed-var fallthrough; `Keys.get/2` is
  tested AFTER refusal). Full boot does NOT fail — it logs the refused
  value loudly with `/setup --check` guidance and generation endpoints
  degrade to provider defaults (the doctor is the repair path; killing
  boot would remove it).
- **The endpoint authority covers EVERY provider with a configured
  `base_url`, not just ollama**: config already advertises e.g.
  OpenRouter's `base_url` as an override (jido_md.ex:329-334), and
  ReqLLM's `effective_base_url` order is `model.base_url` → request opts
  → app config → LLMDB metadata → provider default (options.ex:555-568,
  verified) — so the bridge installs the guard-passing override under
  `:req_llm, <provider>` for the ACTIVE provider generally and the probe
  requests go to the configured override when present (probe what
  generation will use).
- **The endpoint verdict has ONE arm — the real resolver, PURE**: no
  analytical `:equal` shortcut and no by-constant arm — either would
  blind the verdict to a model-level `base_url`, which outranks app
  config in ReqLLM's order. The comparison needs NO installed state:
  `effective_base_url(provider_mod, model, base_url: desired)` injects
  the candidate via the opts leg (below `model.base_url`, above app
  config), so result ≡ desired (canonicalized) ⇔ the bridge-applied
  resolution would win → `:equal`; anything else (incl. a model-level
  `base_url`, incl. a resolver raise) → `:divergent`, fail-closed. Check
  mode therefore mutates NOTHING — not even Application env.
- **Endpoint/credential overrides need OPERATOR TRUST from authority the
  agent tier cannot write** (the CB1-1 boundary — agent-writable
  `.jido/config.yaml` choosing both the destination `base_url` and the
  credential source `api_key_env` is the recorded crabbox
  credential-redirection shape; local config edits bypass tool approval,
  so a residual note is not a defense — and a `~/.jido` FILE store is no
  better: `run_command` shell redirection writes host paths unchanged,
  absolute-write approval covers `write_file`/`edit_file` only, and 0600
  cannot distinguish same-user processes). Trust therefore rides the
  **pre-dotenv AMBIENT host environment**: `JIDOCLAW_ENDPOINT_TRUST`
  (operator-exported; fingerprint entries {provider, exact normalized
  base_url | :default, api_key_env | :default}) is read from the ambient
  snapshot captured BEFORE any dotenv load, so no project-reachable file
  can inject it. A NON-default `base_url` or `api_key_env` arms the
  bridge, receives probe traffic, or has its credential READ only when
  attested there — or when the operator confirms interactively in /setup,
  which arms it **for that session only** and prints the exact `export`
  line for durable trust (no file write; the trust var is not persistable
  by us by design). Unconfirmed → nothing installed, NO request to the
  override, NO read of the custom var, `:config` `:gap` reason
  `:unconfirmed_override`; `--check` reports it honestly red. Defaults
  (official provider bases, localhost ollama, the constant ollama.com
  auto-cloud, default env names) need no confirmation. An **exploit row
  through the real `run_command` path** pins that an agent-written trust
  artifact (project file, dotenv line, redirected host file) arms
  nothing. Closes the #17-created slice of CB1-1; the general guard (SSH
  etc.) stays Wave D #15 (cross-ref recorded).
- **Dependency dotenv loaders are DISABLED**: ReqLLM and LLMDB each load
  cwd `.env` into System env at THEIR app start (req_llm application.ex —
  gated on `:req_llm, :load_dotenv`, default true, which also syncs
  llm_db's flag; llm_db dotenv.ex — `:llm_db, :load_dotenv`), which runs
  BEFORE `JidoClaw.Application.start/2` on full boot: with project_dir ≠
  cwd and conflicting keys, the cwd value would win as "ambient" while
  minimal `--check` resolves the project-owned value — the doctor would
  certify a credential generation doesn't use. config.exs sets both flags
  false (compile-time; app-env pin test), making JidoClaw's loader the
  ONE dotenv authority; the lost dep-side cwd auto-load is covered by our
  chain's cwd fallback paths (documented compatibility note).
- **Minimal boot starts the resolver runtime**: the doctor's minimal boot
  is `ensure_all_started([:inets, :ssl, :req_llm])` — req_llm's start
  ensures llm_db and populates the provider registry + model catalog the
  endpoint verdict needs (string model resolution falls through to an
  EMPTY registry otherwise); with the dotenv loaders disabled this start
  mutates nothing, and the JidoClaw supervision tree still never starts.
  A fresh-VM minimal `--setup --check` drive exercises endpoint
  resolution cold.
- **Bridge-owned state has an ownership registry**: the bridge records
  exactly which `:req_llm` entries it installed (typed state under
  `:jido_claw` app env) and clears/overwrites ONLY those; pre-existing
  operator-supplied `:req_llm` config for INACTIVE providers is never
  touched, and the ACTIVE provider's entries are documented as
  bridge-owned (the doctor's resolution is authoritative there by
  declaration). Tests seed pre-existing `:req_llm` config.
- **Local migration inventory is a compile-time manifest**: the escript
  bundles no `priv/` (main.ex:42-44), so directory listing would report
  a cold DB fully migrated — a generated `MigrationManifest` module
  (`@external_resource` over priv/repo/migrations, `{version, name}`
  pairs) is the ONE local inventory for mix and escript alike; a test
  pins manifest ≡ the live directory. Duplicate versions/names (local or
  DB) → `:unavailable`, never silently collapsed. The probe derives the
  migration table name/prefix from repo config (`:migration_source`,
  prefix — schema_migration.ex:40) and documents `:migration_repo` +
  dynamic repos as out of scope.
- **The dotenv parser and serializer are ONE codec**: today's serializer
  escapes quotes (setup.ex:373) but the loader only strips outer quotes
  and never unescapes — round-trip inequality would poison the
  value-compared `durable?/1` forever. The codec pair lives in
  EnvResolver (loader gains the matching unescape — greenfield), is
  property-tested as inverses, and persistence REJECTS values dotenv
  cannot represent (embedded newlines/control chars → honest
  `:session_only` + message).
- **The bridge applies ONLY on mutating lanes — but after EVERY
  desired-state change there**: `Application.start/2` (boot) and one
  reconciliation point in `Setup.run/2` invoked after every successful
  config write, credential installation, and session-trust confirmation —
  ReqLLM reads the app-config key BEFORE the fixed env var, so a repaired
  key installed only into System env stays shadowed by a prior
  blocking-empty, and a session-confirmed endpoint stays cleared from an
  earlier refusal; `:repaired` may never be reported while generation
  still resolves old state. The check lane — standalone `--check` AND
  in-REPL `/setup check` — performs ZERO mutations of any kind (the pure
  verdict above makes this free); no self-heal, no VM-local exception.
- **The voyage check shares BootGuard's policy**: with
  `:embeddings_strict_boot` disabled, BootGuard accepts a missing
  `VOYAGE_API_KEY` (boot_guard.ex) — the doctor reports `:voyage_key` as
  `:unsupported` (healthy) and excludes it from repairs AND persist
  offers; opt-out test pinned. A supported embeddings-disabled install
  converges healthy without an unused credential.
- **Disabling the dep loaders is a PARSER change, detected loudly and
  TYPED**: Dotenvy (the deps' loader) accepts `export ` prefixes,
  `${...}` interpolation, inline comments, and multiline quoted values
  our line codec does not. The shared parse SUPPORTS the `export ` prefix
  (trivial) and DETECTS the rest per line — and the detection is a
  first-class variant in EnvResolver's result (bounded construct + path +
  line metadata), NOT a nil: an unsupported higher-precedence definition
  must be distinguishable from a missing credential (it maps to
  `:unavailable` naming the construct, never the repairable
  `:missing_credential` lane) and must NOT fall through to
  lower-precedence files (that would resolve a value Dotenvy never
  produced). Detection is a FILE-LEVEL scan: an unsupported quoted block
  is consumed whole, so assignment-looking continuation lines never mint
  phantom credentials. Boot logs the loud warning; parity fixtures
  document each construct's disposition.
- **Valid session-only credentials stay healthy**: a repair that installs
  a VALID key whose persistence is then declined (or fails) yields
  `:repaired` with `repair_outcomes[step] = :session_only` and a loud
  won't-survive-restart warning — never `:gaps_remaining`/exit 1. The
  2026-07-12 draft line ("decline ⇒ gaps_remaining, exit 1") is
  SUPERSEDED by operator decision #3 (durability is display-only, never a
  health gate); dispositions derive from the final checks alone.
- **The `/v1` equivalence is OLLAMA'S translation, not URI identity**:
  the canonicalizer splits into generic URI validation + identity
  normalization (scheme/host/port/FULL path, default-port + trailing-
  slash normalization — all providers) and provider-specific endpoint
  translation (root ↔ `/v1` equivalence + `/v1` suffix insertion —
  ollama ONLY; its OpenAI-compat generation mount). For every other
  provider `/v1` is a semantic path segment: overrides differing only by
  `/v1` are `:divergent`, and fingerprints/installs carry the full
  normalized path verbatim (regression row pinned).
- **Migration reads are cardinality-bounded, not just time-bounded**: a
  corrupted/replaced migration table can return arbitrarily many rows
  within 5s — the probe runs a bounded `count(*)` first (implausible
  count vs the manifest → `:unavailable`), then a `LIMIT`-ed ordered
  select sized from the manifest, and duplicate detection via a bounded
  `GROUP BY … HAVING … LIMIT 1`; a high-cardinality scratch-table row
  pins that client memory does not scale with table size.
- **Intentional reconfiguration survives the doctor**: `/setup
  reconfigure` (REPL) and `--setup --reconfigure` (mix/escript) run the
  full wizard on a HEALTHY install — the doctor replaces the default
  path, not the ability to switch provider/model on purpose. Every doc
  surface describing `/setup`-replaces-config updates in the same change
  (README.md:443, branding.ex:183 help text, docs/ARCHITECTURE.md:594,
  generated-config comment templates).
- **Each credential is persist-offered at most once per invocation**: the
  persist-offer lane excludes steps already present in
  `repair_outcomes` (a declined/failed repair persistence is not
  re-prompted seconds later).
- **OpenRouter's model lookup sends the bearer** (its documented endpoint
  contract requires auth; the observed anonymous 200 is not a contract)
  — the auth VERDICT still comes exclusively from `GET /api/v1/key`.
- **Override-route 404s are never repairable absence**: on a configured
  `base_url`, a 404 proves only that the gateway lacks the metadata route
  → non-repairable `model: :unknown` (a generation-capable proxy without
  model retrieval must not loop `pick_model` on a healthy install);
  `:absent` requires a provider-OWNED endpoint.
- **Ollama local sentinel preserved**: `normalize_api_key/2`
  (config.ex:285-288) treats `OLLAMA_API_KEY=ollama` as no CLOUD
  credential — the derivation applies it (no auto-cloud reroute) while the
  credential bridge still installs the placeholder for generation.
- **Missing credentials classify BEFORE probing** (EnvResolver is
  authoritative without a network): deterministic repairable
  `:provider_key` gap, adapter never called; ollama key-optional exempt.
- **Response caps must hold on EVERY status and EVERY response part**:
  `:httpc` streams only 200/206 (error bodies arrive fully buffered), and
  body-chunk counting alone misses unbounded status lines/headers/trailers
  Mint buffers internally before emitting events — so the default adapter
  is Mint-based with a **total raw-response byte budget counted on the
  transport messages BEFORE they feed Mint's parser**; exceed → close +
  `{:error, :response_too_large}`. Mint promoted to a direct dep (1.9.1 in
  lock via finch). Oversized rows cover body (200/400/500) AND
  never-terminated status/header/trailer streams.
- **Env-var NAME validation** before any `System.get_env`/`put_env` or
  dotenv write: `api_key_env` must match `^[A-Za-z_][A-Za-z0-9_]*$` —
  `"A=B"`/NUL raise ArgumentError in System calls, and a
  whitespace/newline-bearing name would INJECT a second dotenv line
  through the upsert's line assembly (setup.ex:341). Malformed →
  `:invalid_provider_config`; the upsert re-validates at write time
  (defense in depth).
- **Repairs converge in ONE invocation**: the provider interview builds
  the complete selected-provider state (sanitized subtree, local/cloud
  endpoint choice, compatible model, credential collection), and the
  doctor's repair pass is a bounded re-derive-and-repair loop (each step
  at most one attempt per run, cycle-protected) so a repair that exposes
  the next gap still finishes without a second `/setup` run.
- **Persistence offers are a separate non-gap lane**: an `:ok` credential
  with `durable?: false` gets an interactive persist-offer
  (`Doctor.persist_offers/1`), and DECLINING stays healthy — durability
  never gates `healthy?/1` (operator decision #3).
- **Structured inventory crosses the doctor boundary**: the probe result
  carries typed `inventory`/`inventory_truncated?`, `Doctor.check` carries
  a typed `data` map, and the ollama repair picker consumes it — never
  detail-parsing, never a second probe.
- **Native ids percent-encode as path segments** (groq ids carry `/`;
  openrouter splits author/slug FIRST, encoding each component);
  per-provider request-shape rows pin exact URLs; a provider verified at
  build to require raw slashes gets a per-provider rule + deviation log.

**Hard gates:**

- **No PORT map** (posture/contract lift — docs/exploration/README.md rule).
- **Step 0**: materialize this plan as
  `docs/plans/pre-argus-wave-e-17/README.md` (wave-e-16 shape: Context,
  numbered work sections, Verification, Suggested commit slicing,
  `## Deviations` maintained as work proceeds).
- **Queue discipline**: dated Status lines on every source entry, falsified
  claims corrected, cross-refs updated same session.
- Run mix via `mise exec -- mix`. Gates bare (never piped), run in
  background, read the tail. Known-flaky singleton suites verified in
  ISOLATION before blaming new code.
- **Nothing committed by the agent**; work lands unstaged, ending with
  files-to-stage + suggested commit slicing. Completion bar:
  `mise exec -- mix precommit` green.
- New public functions need `@moduledoc`/`@spec` (credo strict); watch the
  known precommit gotchas (Specs/AliasUsage/ExSlop "step"-comment trap/
  ExDNA-dup; dialyzer; `reach --arch` direction — core modules never
  reference CLI modules, so the shared dotenv parse lives in core and
  application.ex consumes it).
- **No deferrals** inside the item: if a unit balloons mid-build, pause and
  surface it rather than silently shrinking scope.

---

## 1. Minimal doctor boot + entry-point rework

Both `mix jidoclaw --setup` (lib/mix/tasks/jidoclaw.ex:65-75 —
`Mix.Task.run("app.start")` :71) and escript `--setup` (main.ex:75-87 —
`start_app_or_halt!()` :83) boot the FULL app today; pending migrations can
crash boot before the doctor speaks, and check-only isn't read-only.

- **Mix arm**: `Mix.Task.run("app.config")` + `ensure_all_started([:inets,
  :ssl, :req_llm])` (:inets/:ssl are `extra_applications`, mix.exs:67;
  yaml_elixir is library-only, yamerl self-starts; `:req_llm` ensures
  llm_db and populates the provider registry + model catalog the endpoint
  verdict needs — safe to start tree-less because BOTH dep dotenv loaders
  are compile-time disabled, §2). app.config runs loadpaths + compile +
  config incl. runtime.exs (Repo config lands; `load_dotenv` never runs —
  the EnvResolver condition). Keep the plain `:project_dir` put (:67); drop
  `:first_run_setup_pending` (:69 — BootGuard reads it only at full app
  start, boot_guard.ex:46-47; moot here; the flag itself stays for the REPL
  first-run flow). Nothing downstream of `Setup.run` (:73) needs the app —
  verified. `System.halt` from the disposition mapping (precedent
  jidoclaw.ex:62); the "Setup complete" line becomes disposition-aware.
- **Escript arm**: replace `start_app_or_halt!()` on this arm only with
  `Application.load(:jido_claw)` (tolerate `{:error, {:already_loaded,
  _}}` — the release.ex:35-40 / run_command.ex load idiom) +
  `ensure_all_started([:inets, :ssl, :req_llm])`, routed through an
  injectable seam
  mirroring `cli_app_starter` so the jido_exec_patch_test fall-through pin
  survives (update the :651-679 row in the same change). Keep
  `:project_dir` `persistent: true` BEFORE `Application.load` (the :77-79
  comment is why); drop the `:first_run_setup_pending` and `:force_setup`
  puts (:81-82). Escripts run host OTP; runtime.exs already ran pre-`main`
  (main.ex:28). Exits via the seam-aware `halt!/1` (main.ex:140-153); exit
  0 stays a plain return.
- **Delete `:force_setup` entirely**: main.ex:82 write, setup.ex:22 cond
  head, jido_exec_patch_test.exs:616 `@cli_env_keys` entry. No live effect
  at HEAD (verified). Designed behavior deltas, recorded: healthy config +
  `--setup` → doctor report (not wizard); provider-less config → doctor
  `:missing_provider` repair; broken YAML → doctor `:unparseable`
  non-repairable + backup-and-replace guidance (REPL still boots on
  `Config.load` defaults — load/1 tolerates broken files :87-90).
- The wizard on these arms uses the same minimal boot (nothing in it needs
  the app tree; its probes get :inets/:ssl). The JidoClaw supervision tree
  NEVER starts on these arms.

**Read-only, BOUNDED DB probe** (`Doctor.migration_status/1`, repo module
supplied — never hardcoded `JidoClaw.Repo`; dynamic repos out of scope,
documented in the `@doc`):

- **Own-start claim, not a whereis branch**: Ecto's `with_repo/3` cleanup
  RESTARTS a repo it found already running (migrator.ex:846-851), and a
  `Process.whereis` pre-check leaves a TOCTOU window. The wrapper claims
  via `repo.start_link(pool_size: 2)`: `{:ok, pid}` → **`Process.unlink(pid)`
  immediately** (a repo crash must surface as probe errors, not kill the
  caller), probe inside `try/after` whose `after` stops EXACTLY the claimed
  pid; `{:error, {:already_started, _}}` → probe directly, NO cleanup (pin:
  pid identical before/after). Replicates `with_repo`'s app-start preamble
  (`:ecto_sql` + adapter apps) without its restart-child cleanup.
- **Local inventory is a compile-time manifest, not a directory listing**:
  the escript bundles no `priv/` (main.ex:42-44 — a dir listing there
  would report a cold DB fully migrated and an existing DB drifted). A
  generated `MigrationManifest` module (`@external_resource` over
  priv/repo/migrations; `{version, name}` pairs; 56 entries today) is the
  ONE local-inventory authority for the mix, REPL, and escript arms; a
  dev/test-env test pins manifest ≡ the live directory listing so it can
  never go stale silently.
- **Bounded lock-free listing** (deviation from the draft's
  `Ecto.Migrator.migrations/3` — its versions SELECT runs
  `timeout: :infinity` and cannot be bounded; a stuck lock would hang the
  doctor): the migration table name and prefix derive from the repo's
  config (`:migration_source` default `"schema_migrations"`, prefix
  default `public` — schema_migration.ex:40; `:migration_repo` and
  dynamic repos documented OUT OF SCOPE in the `@doc` — this probe
  targets JidoClaw's repository layout and goes `:unavailable` on
  nonstandard config rather than answering wrong). Bounded `to_regclass`
  existence check (5s, injectable) — absent → ALL manifest migrations
  pending; present → **time- AND cardinality-bounded reads** (a
  corrupted/replaced table can return arbitrarily many rows within the
  timeout): a `count(*)` first — implausible vs the manifest (manifest +
  slack) → `:unavailable` naming the count; then an ordered
  `SELECT version … LIMIT <manifest + slack + 1>` (all `timeout: 5_000`)
  + duplicate detection via a bounded `GROUP BY version HAVING count(*) >
  1 LIMIT 1` + **bidirectional compare** against the manifest: local-not-in-DB →
  pending count (`:gap` "run `mix ecto.migrate`", `repairable?: false` —
  print-only by decision); **DB-not-in-local → `:gap` `:migration_drift`,
  `repairable?: false`** (Ecto's `** FILE NOT FOUND **` state; wrong-branch
  guidance; fails `healthy?/1`); **duplicate versions or names on either
  side → `:unavailable` with the duplicates named** (rejected, never
  set-collapsed). Migration locks never block a plain SELECT
  under MVCC; an ACCESS EXCLUSIVE holder blocks only until the timeout →
  rescued `:unavailable`. DB/server absent → `:unavailable`, never a crash.
- Tests pin equivalence against a real `Ecto.Migrator.migrations/3` run
  (incl. a bogus-version drift case) on the scratch repo, plus the
  manifest≡directory pin.

## 2. Credentials must survive minimal boot — new `JidoClaw.Config.EnvResolver`

Full boot loads dotenv into System env (application.ex:60 → `load_dotenv/0`
:639-665) before provider resolution — skipping it would misdiagnose a
healthy persisted-only setup. New `lib/jido_claw/core/config/env_resolver.ex`:

```elixir
@type parse_problem :: %{construct: atom(), path: String.t(), line: pos_integer()}  # bounded
@type resolved :: %{value: String.t() | nil,                    # effective (ambient wins)
                    source: :ambient | :persisted | :missing
                          | :unparseable,                       # typed — NOT nil: a definition our codec
                                                                # cannot faithfully parse (Dotenvy construct)
                    problem: parse_problem() | nil,             # set iff :unparseable
                    persisted_value: String.t() | nil,          # first-precedence dotenv resolution
                    persisted_path: String.t() | nil}
@spec resolve(String.t(), [String.t()], keyword()) :: %{String.t() => resolved()}
@spec durable?(resolved()) :: boolean()
# :unparseable NEVER falls through to lower-precedence files (that would resolve a value
# Dotenvy never produced) and consumers map it to :unavailable naming the construct —
# never the repairable :missing_credential lane. durable?(:unparseable) == false.
# opts: ambient: %{name => value} (default: System snapshot), cwd: (default File.cwd!)
```

Pure core with **injected ambient map + cwd** — tests stay `async: true`
with zero global mutation. Parses the SAME four-path first-wins chain the
boot loader uses (`project/.jido/.env` → `project/.env` → `cwd/.jido/.env`
→ `cwd/.env`, application.ex:647-653) WITHOUT `System.put_env`; **ambient
wins persisted** for `value`/`source`. **Durability is value-compared, not
presence-inferred**: `durable?/1` = effective `value` non-blank AND equal
to `persisted_value` (the chain's own first-wins resolution). Ambient `A` +
persisted `B` is NOT durable (next boot flips to `B`; detail names the
divergence); a blank higher-precedence entry shadowing a real later one is
NOT durable (**a `KEY=` line DEFINES the var** — preserve that in the
shared parse); the full-boot case (dotenv already in System env,
`source: :ambient`) compares EQUAL and correctly reads durable. Durability
drives display + the interactive persist-offer ONLY — never `healthy?/1`
(operator decision #3; shell-profile caveat named in the detail).

Implementation: split application.ex's entangled `put_env_if_unset/1`
(:683-699) into a **pure ordered parse living in EnvResolver** (line split
:667-671, `#`/blank skip :673-681, `=` split `parts: 2`, trim,
quote handling :727-738) that BOTH the boot loader and the resolver consume
— one dotenv authority, correct `reach --arch` direction (application.ex →
core). **The authority holds only if the dependency loaders stand down**:
ReqLLM and LLMDB each auto-load cwd `.env` at THEIR app start, BEFORE
`JidoClaw.Application.start/2` — with project_dir ≠ cwd and conflicting
keys, the cwd value would land in System env first and win as "ambient"
while minimal `--check` resolves the project-owned value. config.exs sets
`config :req_llm, load_dotenv: false` and `config :llm_db, load_dotenv:
false` (compile-time; an app-env pin test guards both). **That makes our
codec the authoritative parser for files Dotenvy used to read, so syntax
divergence must be detected, never silent**: the shared parse SUPPORTS
the `export ` prefix (trivial strip) and DETECTS the Dotenvy constructs
it does not implement — `${...}` interpolation, multiline/unterminated
quoted values, ambiguous inline comments — with a **file-level scanner,
not per-line statelessness**: an unsupported quoted BLOCK is consumed
atomically to its closing quote (or end of file), so continuation content
that LOOKS like an assignment (`KEY="first\nOTHER=value\n"`) can never
mint a phantom `OTHER` credential into System env — the whole affected
definition becomes ONE typed `:unparseable` entry. The boot loader logs a
loud warning naming file+line+construct, and a credential resolving
through an affected definition reports `:unavailable` with the construct
named. Parity fixtures document every construct's disposition (supported
/ detected-warned); the cwd fallback paths in our chain cover the lost
auto-load for plain files. Preserve exactly: per-key unset-only puts
including `""` values,
path order + `Enum.uniq`, and **intra-file duplicate keys first-occurrence-
wins**. **Parser and serializer become ONE property-tested codec**: today
the upsert serializer escapes quotes (setup.ex:373) while the loader only
strips outer quotes and never unescapes — a quote/backslash-bearing value
would round-trip UNEQUAL and poison the value-compared `durable?/1`
forever. The codec pair (parse + serialize, inverse by property test)
lives in EnvResolver; the loader gains the matching unescape (greenfield
— no compat shim), and persistence REJECTS values dotenv cannot represent
(embedded newlines/control characters → the repair's honest
`:session_only` + message, never a mangled file line).
application_test's `load_dotenv/0` suite (:36-102) stays green. All
credential presence/valuation on setup paths flows through the resolver —
the doctor's checks, the wizard's already-set detection (setup.ex:169-173),
and the `check_provider/2` wrapper — so full-boot and minimal-boot agree.

## 3. Effective-provider derivation + the generation-env authority (Branch A)

**Shared derivation, total**: `Config.load/1`'s auto-cloud branch re-reads
System env (config.ex:94-111 via `api_key/1` → System.get_env :280;
explicit user base_url preserved via the raw-user_config check :102).
Extract the decision into a pure helper (raw user config + resolved
credential VALUE → effective provider settings: provider, model, base_url
incl. the auto-cloud override, explicit-base_url preservation): `load/1`
delegates with System-resolved credentials (full-boot behavior
byte-compatible, config_test stays green); the doctor/probe path calls it
with EnvResolver values. The helper **applies the existing per-provider
credential normalization** (`normalize_api_key/2`, config.ex:285-288 — the
`OLLAMA_API_KEY=ollama` local sentinel reads as NO cloud credential, so a
stock local setup never auto-cloud-routes; sentinel pins ride `load/1`,
the doctor, and `apply_generation_env/1`) and is **total over malformed
raw config** (`providers: "bad"`, non-map provider entry, non-binary
`api_key_env`/`base_url` → typed absence, never raise); the doctor's config
validation reports those before probing.

**New `Config.apply_generation_env/1`** (operator decision #1, Branch A):
the single config→ReqLLM generation bridge, installing BOTH legs for the
ACTIVE provider from the same shared derivation:

- **Endpoint** (ANY active provider with a configured `base_url`; ollama
  additionally gets the auto-cloud derivation): `Application.put_env(
  :req_llm, <provider>, base_url: <canonical root>[<> "/v1"])` — the
  app-config leg of ReqLLM's `effective_base_url` order (`model.base_url`
  → request opts → **app config** → LLMDB metadata → provider default,
  options.ex:555-568 verified), so a configured override (e.g. the
  OpenRouter proxy jido_md.ex:329-334 advertises) actually drives
  generation instead of being silently ignored. The `/v1` suffix rule is
  per-provider (ollama's OpenAI-compat mount; others install the
  canonical root verbatim — pinned per provider at build).
- **Credential** (any active provider): the EnvResolver-resolved value
  installed under `Application.put_env(:req_llm,
  :"<provider>_api_key", value)` — the app-config leg of ReqLLM's
  `Keys.get/2` order (per-request opt → app config → the provider's FIXED
  env var). Without this, a custom `api_key_env` probes green while
  generation reads the fixed var and finds nothing, and keyless local
  ollama fails generation's always-require-a-key rule
  (`Provider.Defaults`) — so local ollama installs the `"ollama"`
  placeholder. **The doctor's resolution is AUTHORITATIVE**: when the
  active provider's resolution is absent, the bridge installs a BLOCKING
  empty value (`""` — `Keys.get/2` returns its found-but-empty error)
  rather than deleting, because a bare delete would let generation fall
  through to a FIXED env var the doctor never probed
  (custom-name-missing/default-name-present is the regression row); a
  previously installed value for a now-inactive provider is cleared.
  Pinned through ReqLLM's REAL `Keys.get/2` (custom-`api_key_env`,
  keyless-ollama, blocking-empty, and inactive-provider-clear rows).

The bridge returns a **typed desired-state result**
(`{:ok, applied_state} | {:refused, reason}`), keeps an **ownership
registry** (typed state under the `:jido_claw` app env recording exactly
which `:req_llm` entries it installed — clear/overwrite touches ONLY
those; pre-existing operator-supplied `:req_llm` config for INACTIVE
providers is never touched, and the ACTIVE provider's entries are
documented as bridge-owned by declaration), and is **INERT when
`:sanitize_external_env` is enabled** (config/test.exs — the test-boot
credential-isolation guarantee at application.ex:30 covers only its
static deny list; the bridge must not re-arm an external provider from a
custom-named exported var during tests). On a guard refusal it **clears
its ENDPOINT entries while the credential rule stays in force** (value or
blocking empty — clearing the credential too would reopen the fixed-var
fallthrough; `Keys.get/2` is asserted AFTER a refusal), and full boot
does NOT fail: `Application.start/2` logs the refused value loudly with
`/setup --check` guidance and generation endpoints degrade to provider
defaults (the doctor is the repair path; a failing boot would remove it).
Fresh-invalid-boot, valid→invalid transition, and seeded pre-existing
`:req_llm` config rows test all three properties.

**Load-safe by construction**: it
first loads `:req_llm`'s app spec (the `load_app_spec!/1` idiom,
run_command.ex:287-292 — `Application.load/1` never loads dependencies, and
a put on an unloaded app is clobbered when `ensure_all_started` loads it
later); puts stay NON-persistent (the prime_boot_env doc :265-272 records
why — a persistent shadow would outlive test save/restores). Deterministic
guards shared with the probe's canonicalizer (§5): **absolute
hierarchical URI with scheme ∈ {http, https}, a NONBLANK host, and a
valid port; no userinfo/query/fragment; no whitespace/control characters**
(`https:/ollama.com` parses with a nil host and must refuse — a refused
value is never installed, so the verdict comparison never sees it);
refusal → the typed `{:refused, reason}`
path above + the doctor reports `:config` `:invalid_provider_config`;
destination logged at boot.
Call sites — **MUTATING lanes only, after EVERY desired-state change**:
**`JidoClaw.Application.start/2`** (after `load_dotenv`, before children —
OTP starts dependency apps first, so `:req_llm` is loaded by construction
and no pre-boot `:req_llm` put exists on any path; one owner covers REPL,
`mix jidoclaw run`, and gateway boots) and **one reconciliation point
inside `Setup.run/2`** invoked after every successful config write,
every credential installation, AND every session-trust confirmation — not
only config-file mutations: ReqLLM reads the app-config key BEFORE the
fixed env var (keys.ex), so a repaired key installed only into System env
would stay shadowed by a prior blocking-empty (or stale) app-config
value, and a session-confirmed endpoint would stay cleared from the
earlier refusal. The doctor may never report `:repaired` while
generation still resolves the old state (Setup-level live rows through
ReqLLM's REAL resolvers pin key + endpoint after each repair kind).
The CHECK lane (standalone `--check` and in-REPL `/setup check`) and
`Doctor.derive/2` perform ZERO mutations of any kind — no files, no
System env, no Application env; the checks never need the bridge because
the probe consumes DERIVED effective settings and the endpoint verdict is
the pure opts-injection comparison (§5). The in-suite test VM has already
booted before test_helper runs, so an `ensure_all_started` pin would be
vacuous — whole-boot behavior is verified by a **fresh-VM spot drive at
build** (recorded in Verification), while the live-pins suite covers the
bridge function directly against the real resolver.

**The CB1-1 boundary (endpoint/credential trust — `EndpointTrust`)**: the
bridge, the probe, and credential resolution honor a NON-default
`base_url` or NON-default `api_key_env` for the active provider only when
attested by **`JIDOCLAW_ENDPOINT_TRUST` read from the pre-dotenv AMBIENT
env snapshot** (fingerprint entries {provider, exact normalized base_url
| :default, api_key_env | :default}). Authority placement is the point:
the ungated local `.jido/config.yaml` edit makes the crabbox CB1-1 attack
shape live, and a host FILE store is equally forgeable — `run_command`
shell redirection writes `$HOME/...` unchanged (absolute-write approval
covers `write_file`/`edit_file`, not redirects; run_command.ex:39,
tool-approval.md:51) and 0600 cannot distinguish same-user processes —
while the pre-dotenv ambient snapshot is set only by the operator's own
shell, before any project-reachable file is read (minimal boot never
loads dotenv into System; full boot captures the snapshot first).
Malformed trust entries fail CLOSED (unconfirmed, named in detail). The
interactive `:unconfirmed_override` confirm repair arms the fingerprint
**for the running session only** (in-process state, never a file) and
prints the exact `export JIDOCLAW_ENDPOINT_TRUST=...` line for durable
trust; `--check` under an unconfirmed override reports the gap honestly.
Unconfirmed: bridge installs nothing for that leg, the probe sends NO
request to the override and reads NO custom-named credential. Defaults —
official provider bases, localhost ollama, the constant ollama.com
auto-cloud, per-provider default env names — need no confirmation. An
**exploit test through the real `run_command` path** pins that
agent-written artifacts (project config, dotenv lines, redirected host
files) arm nothing. System-page note: closes the #17-created slice of
CB1-1 (probe/generation egress); the general provenance guard (SSH
ServerRegistry etc.) remains Wave D #15, cross-ref recorded both ways.

## 4. New `lib/jido_claw/cli/setup/doctor.ex` — pure derivation

```elixir
@type step :: :config | :provider_key | :voyage_key | :model | :database
@type status :: :ok | :gap | :error | :unsupported | :unavailable
@type check :: %{step: step(), status: status(), detail: String.t(),
                 reason: atom() | nil,          # machine-readable, e.g. :unparseable | :unknown_provider
                 repairable?: boolean(),
                 source: :persisted | :ambient | :missing | nil,  # credential steps (EnvResolver's union;
                 durable?: boolean() | nil,     # session-ness lives in repair_outcomes, not here
                 data: map()}                   # typed repair payload (e.g. the ollama :model check carries
                                                # inventory: [String.t()] + inventory_truncated?: boolean());
                                                # %{} otherwise — repairs consume this, never parse detail
@spec derive(String.t(), keyword()) :: {map(), [check()]}   # probes injected via opts
@spec repairs([check()]) :: [step()]        # :gap/:error AND repairable?; :database always print-only
@spec persist_offers([check()]) :: [step()] # the NON-GAP lane: :ok credential checks with durable?: false
@spec healthy?([check()]) :: boolean()      # :ok/:unsupported pass; :unavailable/:gap/:error FAIL
@spec print([check()]) :: :ok
```

`:unsupported` = expected-absent capability (healthy); `:unavailable` =
indeterminate (fails `--check`). **`repairs/1` returns only repairable
checks** — `repairable?` is set by the check, not inferred from status.
`derive/2` performs zero mutations of any kind. Checks:

- `:config` — dispatch wizard-vs-doctor on **`File.exists?`** of
  `.jido/config.yaml` (`read_user_config` maps missing AND empty to
  `{:ok, %{}}` — config.ex:123-150, test-pinned), then `read_user_config` +
  **deterministic validation BEFORE any probe** (accessors return raw
  values despite string specs, config.ex:161-170): broken YAML → `:error`,
  reason `:unparseable`, **`repairable?: false`** (the merged writer
  refuses unparseable files by design — the doctor prints the parse error
  and an explicit backup-and-replace suggestion, and NEVER auto-touches the
  file); provider missing → `:gap` `:missing_provider`; provider ∉ known
  set → `:gap` `:unknown_provider` (both repairable: provider-subset
  interview); a literal `provider: "ollama_cloud"` **normalizes to ollama
  during validation** (never routes to the probe's unknown-provider
  fallback); malformed `providers` subtree — non-map container, non-map
  ACTIVE provider entry, non-binary `api_key_env`/`base_url`, **or an
  `api_key_env` not matching `^[A-Za-z_][A-Za-z0-9_]*$` (validated BEFORE
  any resolution — `"A=B"`/NUL raise ArgumentError in System env calls,
  and whitespace/newline-bearing names would inject a second dotenv line
  through the upsert's line assembly, setup.ex:341; the doctor and
  repairs never touch System env or the dotenv writer with a malformed
  name)** → `:gap` `:invalid_provider_config`
  (repairable: interview + merged write repair the active path; also the
  report surface for an `apply_generation_env`
  guard refusal). **Model-VALUE problems are emitted as `step: :model`
  checks, not `:config`** (repair dispatch is per-step): model non-binary /
  provider-prefix mismatch (modulo ollama_cloud→ollama; split `parts: 2` —
  multi-colon ids) / **a blank provider-native id after the split**
  (`"openai:"`) / **openrouter ids without two nonblank author+slug
  components** (`"openrouter:/"` — a collapsed id would hit
  collection-like routes and could even read falsely present) → `:model`
  `:gap`, reason `:invalid_model` / `:provider_model_mismatch`
  (repairable: `pick_model`; the adapter is NEVER invoked for an invalid
  local value). Probes are SKIPPED unless config validates.
- `:provider_key` + `:model` — **trust classifies FIRST**: a NON-default
  `base_url`/`api_key_env` without an `EndpointTrust` confirmation (§3)
  → `:config` `:gap` reason `:unconfirmed_override`, repairable ONLY
  interactively (the confirm repair); the probe fun is NEVER invoked, the
  custom-named credential is never read, and both dependent checks go
  `:unavailable` until confirmed. Then **credential absence classifies
  BEFORE any probe**: a key-required provider whose credential is locally
  absent (EnvResolver — authoritative without a network) → deterministic
  repairable `:provider_key` `:gap`, reason `:missing_credential`, with
  `:model` `:unavailable` (can't verify keyless) and the probe fun NEVER
  invoked (test-pinned; ollama is key-optional and exempt — the existing
  nil-key short-circuit at config.ex:364-365 is the precedent). Otherwise
  ONE probe pass feeds both (openrouter takes
  two requests), credential + effective settings from EnvResolver + the
  shared derivation; carries `source`/`durable?`. Only `auth: :invalid`
  yields the key-repairable gap; `access: :denied` with `auth: :ok` keeps
  `:provider_key` at `:ok` and sends `:model` to non-repairable
  `:unavailable`; `endpoint: :divergent` (§5) sends `:model` to
  non-repairable `:unavailable`, reason `:endpoint_divergence`, both URLs
  in the detail — all routed on the probe's machine-readable fields, never
  by parsing `detail`.
- `:voyage_key` — EnvResolver presence + `source`/`durable?` (presence-only,
  no probe). **Policy is SHARED with BootGuard**: when
  `:embeddings_strict_boot` is disabled (BootGuard deliberately accepts
  the missing key, boot_guard.ex) the check reports `:unsupported`
  (healthy) and is excluded from repairs AND persist offers — an
  embeddings-disabled install converges healthy without an unused
  credential (opt-out row pinned; the required-policy predicate is
  extracted so the two consumers cannot drift).
- `:database` — `migration_status/1` (§1): N pending → `:gap` (print-only);
  `:migration_drift` → non-repairable `:gap`; unreadable → `:unavailable`.

## 5. New `JidoClaw.Config.ProviderProbe` (`lib/jido_claw/core/config/provider_probe.ex`)

```elixir
@spec probe(map(), keyword()) :: %{reachable: boolean(),
                                    auth: :ok | :invalid | :unknown,
                                    access: :ok | :denied | :unknown,     # machine-readable; never parse detail
                                    model: :present | :absent | :unknown | :unsupported,
                                    endpoint: :equal | :divergent | :not_applicable,
                                    inventory: [String.t()] | nil,        # ollama: decoded tags up to the hard cap
                                    inventory_truncated?: boolean() | nil,
                                    detail: String.t()}
```

- **Retrieve-by-id, not first-page listing — against the endpoint
  generation will USE**: when the active provider has a CONFIRMED
  (`EndpointTrust`, §3) configured `base_url`, probe requests target it
  (probe-what-you-use; an UNCONFIRMED override is never probed — the
  doctor short-circuits at `:unconfirmed_override` before the probe),
  else the provider's official base — anthropic
  `GET /v1/models/{id}` (`x-api-key` + `anthropic-version`), openai/groq/xai
  `GET /v1/models/{id}` (Bearer), google `GET /v1beta/models/{name}` with
  **`x-goog-api-key` header** (never query-string creds). (Today's
  `check_api_key` config.ex:362-379 sends Bearer to ALL providers incl.
  anthropic/google — the probe fixes the native schemes; the thin wrapper
  inherits the fix.) 200 → auth ok + `:present`; **404 → `:absent` only
  on a provider-OWNED endpoint** — on a configured override, a 404 proves
  only that the gateway lacks the metadata route (a generation-capable
  proxy without model retrieval would otherwise loop `pick_model` forever
  on a healthy install), so override-route 404 → NON-repairable
  `model: :unknown` with the route named in detail (gateway fixture row —
  generation-only proxy — pins it);
  **401 → `auth: :invalid` — but 403 is NOT a bad key**: anthropic/google
  use 403 for permission problems → `access: :denied` + `auth: :ok`
  (else `auth: :unknown`), `model: :unknown`. **Google exception**: its
  invalid-key responses arrive as 400 with an `API_KEY_INVALID` ErrorInfo
  reason — bounded JSON error-body decode: `API_KEY_INVALID` →
  `auth: :invalid` (repairable); permission/restriction reasons or an
  undecodable 403 → `access: :denied` + `auth: :ok`; other/undecodable 400
  → `auth: :unknown`. Decode total, never raises. Other statuses →
  `:unknown` (detail carries the status — never conflated with
  unreachable); transport error → `reachable: false`. An incomplete search
  can only yield `:unknown`/`:unavailable`, never a repairable `:gap`.
- **OpenRouter — two requests** (operator-verified: its model lookup
  returns 200 without valid auth): auth via authenticated
  **`GET /api/v1/key`** — 200 → `:ok`; 401 → `:invalid`; **403 →
  `access: :denied` + `auth: :ok`** (OpenRouter's error contract
  distinguishes 401 authentication failures from 403 `permission_denied`
  on a VALID key — a restricted key must never trigger the
  key-replacement repair; ambiguous responses → `auth: :unknown`); model
  presence via **`GET /api/v1/model/{author}/{slug}`** (singular `model`;
  test aliases + `:free` variants; 200 → `:present`, 404 → `:absent`,
  informing `model` only; **the lookup SENDS the bearer** — OpenRouter's
  documented endpoint contract requires auth; the observed anonymous 200
  is behavior, not contract, and the auth VERDICT still comes exclusively
  from `/key`). Bounded total (two 5s budgets — documented).
- **Ollama**: effective settings via the shared derivation (§3); model
  check via `/api/tags` **membership over the FULL decoded inventory**
  computed BEFORE any display bound (NEW behavior — today's `check_ollama`
  is status-only), with `:latest` canonicalization both directions
  (tagless native id ≡ same + `:latest`; never rewrites config); the probe
  result carries the TYPED `inventory` (up to a hard safety cap) +
  `inventory_truncated?`, which the doctor preserves in the `:model`
  check's `data` map — the repair picker consumes that structure, never
  detail text and never a second probe (cap-exceeded body →
  `model: :unknown`, never false-absent → `:model` `:unavailable`); tags
  listed once (bounded) in the gap detail for humans.
- **`endpoint:` verdict — ONE arm, total, fail-closed, PURE** (computed
  for the ACTIVE provider whenever a `base_url` override is configured,
  and for ollama always; `:not_applicable` only for an override-less
  non-ollama provider): resolve
  `effective_base_url(provider_mod, model, base_url: desired)` — the
  candidate rides the OPTS leg (below `model.base_url`, above app
  config), so NO installed state is needed and check mode stays
  mutation-free; canonicalize both sides; result ≡ desired → `:equal`,
  anything else → `:divergent` — a model-level `base_url` (which outranks
  the bridge in ReqLLM's order) surfaces as `:divergent` by construction,
  and a resolver raise → `:divergent` (fail-closed, indeterminacy noted
  in detail). NO analytical shortcut, NO by-constant arm. Requires the
  resolver runtime: minimal boot starts `[:inets, :ssl, :req_llm]`
  (req_llm ensures llm_db + populates the registry/catalog;
  dotenv-disabled per §2, so the start mutates nothing). Canonicalizer
  (shared with §3's guards) — **two layers, deliberately split**: (1)
  generic URI validation + identity normalization for ALL providers —
  require an absolute hierarchical URI, scheme ∈ {http, https},
  **nonblank host, valid port**, no whitespace/control characters; reject
  query/fragment/userinfo, missing-host shapes (`https:/ollama.com`),
  opaque URIs, and malformed ports → `:divergent` (component named);
  normalize default ports + a trailing slash; compare
  scheme/host/port/**FULL path**; (2) provider-specific endpoint
  TRANSLATION — the root ↔ `/v1` equivalence and `/v1` suffix insertion
  belong to ollama ONLY (its OpenAI-compat generation mount); for every
  other provider `/v1` is a semantic path segment, so overrides differing
  only by `/v1` are `:divergent`, and fingerprints/installs carry the
  full normalized path verbatim (non-ollama `/v1` regression row
  pinned). Named residual: per-request
  `base_url:` opts would evade the check (structurally absent — no lib/
  call site passes it).
- **Canonical id contract**: config stores `provider:model` strings; the
  probe derives the provider-native id (strip our prefix `parts: 2`;
  google's `models/…` naming normalized) and reports in canonical form.
  **Native ids embed in URLs as percent-encoded path segments** (groq ids
  carry `/` — `meta-llama/…`; reserved chars in hand-edited ids must not
  reparse as route segments or query starts): openrouter splits the
  author/slug pair FIRST and encodes each component separately; every
  provider's request-shape test pins the exact URL for a slash-containing
  id (any provider verified at build to require RAW slashes gets its rule
  adjusted per-provider + deviation-logged — a mis-encoded id may only
  yield `:unknown`/`:absent`-with-detail, never a crash).
- **Key-required providers short-circuit a nil credential without the
  adapter** (defense in depth under the doctor's §4 pre-classification):
  the probe returns `auth: :invalid` with the remaining fields at their
  `:unknown` values and the adapter NEVER invoked (test-pinned).
- HTTP via an injectable adapter with a NORMALIZED contract —
  `request.(method, url, headers) :: {:ok, %{status: non_neg_integer(),
  body: binary()}} | {:error, term()}` — with the bounded 5s deadline
  (injectable); timeout → `{:error, :timeout}` → `reachable: false` with
  the timeout named. **The response cap is enforced WHILE RECEIVING, on
  EVERY status AND every response part**: `:httpc` cannot do this (its
  streaming applies only to 200/206 — error bodies arrive fully buffered,
  and `stream: :self` has no pull backpressure), and counting only parsed
  BODY chunks would still miss unbounded status lines, headers, and
  trailers that Mint's HTTP1 parser buffers internally before emitting
  any event. So the default adapter is **Mint-based with a total RAW-byte
  budget** (promote `{:mint, "~> 1.9"}` to a direct dep — 1.9.1 in lock
  via finch): each transport message's `byte_size` is counted against one
  whole-response budget BEFORE it feeds `Mint.HTTP.stream/2`, covering
  status+headers+trailers+body; exceed → connection CLOSED →
  `{:error, :response_too_large}`; per-message deadline within the 5s
  budget; mailbox drained on close; no extra processes under minimal
  boot. The probe maps `:response_too_large` to `model: :unknown` /
  `:unavailable`, never false-absent and never memory exhaustion. Adapter
  GLUE integration-tested against a local `:gen_tcp` stub: normal
  `/api/tags` JSON decode, timeout mapping, **oversized/unbounded chunked
  bodies on status 200 AND 400 AND 500**, and **never-terminated
  oversized status line / header block / trailer streams** (the raw
  budget trips in each, memory bounded); per-provider mapping unit-tested
  on canned normalized `{status, body}` values for EVERY clause. Credential + effective settings arrive explicitly; the probe
  never reads System env. Total unknown-provider fallback (defense only —
  validation catches it first).
- `Config.check_provider/1` (config.ex:334-346) becomes
  `check_provider(config, opts \\ [])` — thin wrapper deriving
  `:ok | {:error, :unauthorized | :unreachable | :endpoint_divergence}`
  (contract extension, deviation-logged), `opts` accepting `project_dir:`
  and/or `credential:`. **Both callers updated in the same change** — the
  REPL banner (repl.ex:161-174; a missed arm is a boot-time
  CaseClauseError; resolver-raise banner row test-pinned) and the wizard
  `test_connection` (setup.ex:261-278). Test: a persisted-only credential
  resolves correctly when project_dir ≠ process cwd.
- Adjacent, recorded not built: routing the web-side
  `JidoClaw.Setup.CredentialValidator` through ProviderProbe is a
  follow-up.

## 6. `cli/setup.ex` rework

- `run/1` → `run(project_dir, opts \\ [])` returning a **tagged result**:
  `{:ok, %{config: map(), checks: [Doctor.check()], disposition:
  :wizard_completed | :healthy | :repaired | :gaps_remaining |
  :check_healthy | :check_unhealthy, repair_outcomes: %{Doctor.step() =>
  :persisted | :session_only | :declined}}}` — the typed home for repair
  state the re-derive cannot honestly recompute (check dispositions derived
  from `Doctor.healthy?/1` so the disposition→exit mapper stays pure).
  `opts` carries **injectable prompt/IO, env-install, AND generation-env
  installer seams** (defaults: raw IO prompts, `System.put_env`,
  `Config.apply_generation_env/1`) so repair branching is testable and
  async test modules never touch the real `:req_llm`/System state — every
  assertion against REAL global environment lives in the async: false
  live-pins module.
  **`Setup` never calls `System.halt` anywhere** — exits are owned by the
  Mix/escript entrypoints via the disposition→code mapping (the REPL never
  exits). **All four callers updated + tested**: repl.ex `ensure_config`
  (:94-100, first-run unwrap — today it uses the bare map return),
  commands.ex `/setup` (:496-500) + `/config` (:502) — unwrap →
  `Config.model/1` **and refresh `Application.put_env(:jido_ai,
  :model_aliases, …)` mirroring repl.ex:70** (adjacent fix: an in-session
  `/setup` leaves aliases stale today), the mix arm, the escript arm.
  `run_command.ex`'s `ensure_configured` refusal (:229-235) untouched.
- Dispatch — **check_only routes FIRST and mutates NOTHING**: derive +
  print + report only — a missing config file is a `:config` gap, NEVER a
  wizard launch; zero prompts, zero file mutations, zero System-env
  mutations, zero Application-env mutations (the bridge never runs on
  this lane — §3's pure verdict makes it unnecessary). Then **reconfigure
  routes** (`reconfigure: true` opt): the
  full wizard runs regardless of health — the doctor replaces the DEFAULT
  path, not the ability to intentionally switch provider/model on a
  healthy install — followed by the same final derivation.
  Otherwise: config ABSENT → today's full wizard, **then a
  final derivation** (re-applying the generation env after the write) —
  post-wizard derive clean → `:wizard_completed`; remaining gaps →
  `:gaps_remaining` (summary says config was written AND names the gaps;
  checks always carry the final derivation — exiting 0 with pending
  migrations is exactly the failure minimal boot exists to expose). Config
  present → doctor: derive → print → then a **bounded
  re-derive-and-repair loop** (repair `repairs/1`, re-derive, repeat;
  cycle-protected — each step gets at most ONE repair attempt per
  invocation, so a repair that exposes the next gap — a provider switch
  needing a credential, a stale ollama base_url — still converges in one
  `/setup` run; a step whose attempt didn't clear its check is
  `:gaps_remaining`, never a silent success and never a re-prompt loop) →
  then the **persist-offer lane** (`Doctor.persist_offers/1` — `:ok`
  credential checks with `durable?: false`, interactive doctor mode only,
  NEVER check mode, **excluding any step already present in
  `repair_outcomes`** — a persistence just declined or failed inside a
  repair is never re-prompted seconds later): offer persisting the
  already-valid existing value via the same winning-path upsert; accepting
  records `:persisted` (after the durable re-resolve confirms),
  **declining stays healthy** — durability never gates `healthy?/1` or
  the disposition (operator decision #3) → closing summary carrying the
  final derivation.
- **Credential repairs — durability modeled, not inferred**: checks carry
  `source:`/`durable?:`; repair-offer logic keys on `durable?/1`. Repairs
  prompt for the key, **install into the live process (env-install seam)
  and VALIDATE BEFORE any persistence**: the candidate is installed
  session-only (an in-REPL repair must update the running VM or the live
  runtime keeps resolving the old value), the loop re-derives — the real
  probe judges it — and **persistence is offered ONLY once
  `:provider_key` reads `:ok`**; a probe-rejected candidate is NEVER
  written to dotenv (a mistyped key + eager accept would otherwise
  persist garbage the one-attempt guard can't correct this invocation —
  the gap stands honestly instead). Accepted persistence goes **via the
  0600 atomic upsert machinery** (persist_env_var, setup.ex:305-337),
  **written to the winning PROJECT-OWNED path**: `persisted_path` ∈ the two project paths →
  upsert in place (fixes the shadow; add a path-taking variant of the
  atomic upsert, **missing-or-regular by lstat — symlink/dir/other →
  refuse loudly, never write**); a cwd fallback outside project_dir →
  never mutate the external file — write `project/.env` (outranks both cwd
  paths) and name the external definition; defined nowhere → default
  `project/.env`; **the upsert re-validates the var name against
  `^[A-Za-z_][A-Za-z0-9_]*$` at write time** (defense in depth — a
  malformed name must never reach line assembly). Accept → re-resolve and
  mark `:persisted` ONLY when `durable?/1` confirms, else honest
  `:session_only` + loud message. **Declined or FAILED persistence of a
  VALID key never gates health** (superseded deviation — the 2026-07-12
  "decline ⇒ `:gaps_remaining`, exit 1" line contradicts operator
  decision #3's display-only durability): the outcome records
  `:session_only`, the summary carries a loud won't-survive-restart
  warning, and the DISPOSITION derives from the final checks alone — a
  live-valid credential yields `:repaired`, exit 0. Persistence FAILURE
  (I/O raise, lstat refusal) → the same rescued `:session_only` +
  message. The first-run wizard's
  `configure_api_key` (:161-196, session-only put_env :184) **reuses the
  same persist-offer flow**; its already-set detection (:169-173) reads
  the resolver. Voyage keeps prompt+persist — the `System.halt(1)` on
  decline (:121, the only halt in the file) is REMOVED: an EMPTY voyage
  prompt (no key given at all — a genuinely missing credential, distinct
  from declined persistence of a given key) = `:voyage_key` gap ⇒
  `:gaps_remaining` + BootGuard consequence printed; mix/escript exit 1
  from the mapping, REPL first-run warns and continues (deviations
  recorded).
- Other repairs (per-step dispatch; reason rides the check): `:model` —
  non-ollama `:absent`/`:invalid_model`/`:provider_model_mismatch` →
  `pick_model` (:198-234) + merged write; **ollama `:absent` →
  inventory-driven picker** (`"ollama:" <> native` from the check's typed
  `data` inventory, merged write; empty inventory → non-repairable +
  `ollama pull <model>` guidance; truncation noted, free-form fallback) —
  **the selection is verified by the loop's post-write re-derive**, which
  probes normally: an inventory pick re-derives green, and a FREE-FORM
  entry is proven only by that real re-probe (an absent free-form pick
  stays a gap → `:gaps_remaining` after its one attempt); `:config`
  (`:missing_provider`/`:unknown_provider`) — provider-subset interview
  that builds the COMPLETE selected-provider state in the same repair:
  sanitized active subtree, the local/cloud endpoint choice for ollama
  (the setup.ex:247-254 pseudo-provider mapping — a stale
  `providers.ollama.base_url` is replaced, not inherited), **a compatible
  model picked in the SAME interview** (one merged atomic write carrying
  all keys — a provider-only write would leave the old model and
  manufacture a fresh `:provider_model_mismatch`), and a missing
  credential for the newly selected provider surfaces as the
  `:provider_key` gap on the loop's next pass (still the same
  invocation); `:invalid_provider_config` **additionally SANITIZES before
  merging** — `deep_merge` (config.ex:617-624) preserves whatever the
  interview doesn't overwrite, so the repair explicitly replaces/drops the
  malformed fields of the ACTIVE provider subtree; `:config`
  **`:unconfirmed_override`** — show provider + exact base_url +
  api_key_env, operator confirms → the fingerprint arms **in process
  memory only** (never a file — a same-user file is agent-forgeable, §3)
  + the exact `export JIDOCLAW_ENDPOINT_TRUST=...` line prints for
  durable trust, and the re-derive proceeds armed; declined → the gap
  stands (`:gaps_remaining`), nothing armed; `:database` — print-only.
- **YAML writing**: promote `{:ymlr, "~> 5.1"}` to a direct dep (mix.lock
  already at 5.1.5 via reactor); `write_config/2` + new
  `write_config_merged/2` emit via `Ymlr.document!/1`, written atomically
  (tmp + rename + 0-leak cleanup — today's `write_config` :286-293 is a
  non-atomic wholesale `File.write!`); DELETE the hand-rolled
  `map_to_yaml/2` (:386-411). **Permission invariant** (rename replaces
  the inode; config can carry literal MCP headers and shell-profile env
  values): chmod the tmp BEFORE content; existing regular destination →
  preserve its mode; new file → `0600`; non-regular destination → refuse
  loudly (the persist_env_var lstat guard :311-314). Merged write:
  `read_user_config` → `deep_merge` → encode → atomic write; **refuses**
  unparseable existing files (the doctor never routes those here).
  **Accepted residual** (moduledoc + Status): parse→merge→re-emit loses
  operator comments/anchors/layout — semantic content preserved
  (test-pinned), source layout not.

## 7. `--check` plumbing + exits

- Mix task: the `run(["--setup" | args])` head (argv pattern dispatch,
  jidoclaw.ex:65) parses `--check` AND `--reconfigure`;
  `mix jidoclaw --setup --check` exits 0 iff `Doctor.healthy?/1`
  (disposition `:check_healthy`), else 1; plain `--setup`: 0 unless
  `:gaps_remaining` (→ 1); `--setup --reconfigure` runs the full wizard
  on a healthy install (same exit mapping). Flags are safe against
  project-dir resolution (startup.ex:330-338 skips `--`-prefixed args —
  verified).
- Escript twin in main.ex (arm :75-87); neither flag sets app-env state.
- REPL: `/setup check` + `/setup --check` and `/setup reconfigure` heads
  above `"/setup"` in commands.ex (never exits the REPL); `/config` alias
  unchanged (the doctor). In-REPL `/setup check` mutates nothing — the
  bridge runs only on repair/wizard/reconfigure lanes and at boot.
- Moduledocs document flags + exits (they ARE the help). Exit mapping
  pinned by testing the pure disposition→code function (0:
  wizard_completed/healthy/repaired/check_healthy; 1:
  gaps_remaining/check_unhealthy).

## 8. Tests

House patterns: mix-task output via `ExUnit.CaptureIO`; interaction
branching via the NEW injected prompt/IO + env-install seams; async modules
never touch VM-global state.

- `doctor_test.exs` (async: true; tmp dirs; injected probes — never live
  network): healthy → all `:ok`/`:unsupported`, `repairs == []`,
  `healthy?`; single-gap rows; reason/repairable rows — broken YAML →
  `:config` `:error` `:unparseable` `repairable?: false`, NOT in
  `repairs/1`, detail carries parse error + backup-and-replace guidance;
  `:unknown_provider` gap; **literal `ollama_cloud` normalizes** (validates
  as ollama, probe receives effective settings); malformed-subtree rows
  (`providers: "bad"`, non-map active entry, non-binary
  `api_key_env`/`base_url`, **and malformed env-var NAMES — `"A=B"`,
  NUL-bearing, blank, newline-embedded (`"GOOD\nINJECTED"`),
  whitespace-bearing, leading-digit, punctuation — proving no System env
  function and no dotenv write path is ever called**) →
  `:invalid_provider_config`, no raise; **missing-credential rows** —
  key-required provider with an absent credential → repairable
  `:provider_key` gap reason `:missing_credential`, probe fun NEVER
  invoked; local ollama keyless → no such gap;
  model-value problems land on `step: :model` (incl. multi-colon
  `ollama:foo:cloud` parsing, blank-native `"openai:"`, and
  component-less `"openrouter:/"` → `:invalid_model`); in ALL of these
  the probe fun is NEVER invoked; `endpoint: :divergent` → `:model` `:unavailable` reason
  `:endpoint_divergence`, both URLs in detail; `:migration_drift` fails
  `healthy?`; pending migrations → gap NOT in repairs; `:unavailable`
  fails `healthy?`; **durable?: false alone never fails `healthy?`**
  (operator decision #3 pin); **trust rows** — a non-default `base_url`
  or `api_key_env` without a matching `EndpointTrust` fingerprint →
  `:config` `:unconfirmed_override`, probe fun NEVER invoked, the
  custom-named var NEVER read (ambient seam proves no lookup), dependent
  checks `:unavailable`; a matching fingerprint → normal probing; a
  malformed/unparseable trust entries → fail-closed unconfirmed;
  **exploit row through the REAL `run_command` path** — an agent-written
  trust artifact (project config edit, dotenv line, shell-redirected host
  file) arms NOTHING (the ambient pre-dotenv snapshot is the only
  authority); **voyage opt-out
  row** — `:embeddings_strict_boot` disabled → `:voyage_key`
  `:unsupported`, absent from `repairs/1` AND `persist_offers/1`; derive
  performs zero mutations; **no-config
  check-only regression**: fresh tmp dir + check mode → `:config` gap,
  zero prompts consumed, directory bytes untouched.
- **DB probe tests** (async: false; FIRST-OF-KIND): test/support
  ScratchRepo (`use Ecto.Repo, otp_app: :jido_claw, adapter:
  Ecto.Adapters.Postgres`, zero Ash wiring), config derived from
  `JidoClaw.Repo.config()` via `Application.put_env`, `pool:
  DBConnection.ConnectionPool`, **`priv: "priv/repo"`** (else Ecto derives
  `priv/scratch_repo/migrations` and reports zero pending), scratch DB name
  embedding `MIX_TEST_PARTITION`; tolerate `{:error, :already_up}`;
  `storage_down` in on_exit. Rows (ALL on the scratch repo — deviation from
  the draft's `migration_status(JidoClaw.Repo)` wording; the sandbox pool
  is never touched): cold DB → all local pending AND `to_regclass` still
  null (no DDL); own-start claim → repo process ABSENT after success AND
  after an injected raise, caller survives both; already-started (manual
  start) → pid IDENTICAL before/after; **ACCESS EXCLUSIVE contention →
  timely `:unavailable`** (test holds the lock); **equivalence pin** vs
  real `Ecto.Migrator.migrations/3` incl. a hand-INSERTed bogus version →
  `:migration_drift`; a hand-INSERTed DUPLICATE version → `:unavailable`
  with the duplicate named; a **high-cardinality scratch table** (tens of
  thousands of hand-INSERTed rows) → `:unavailable` from the bounded
  count, client memory NOT scaling with table size; the **manifest ≡
  directory pin** (the compile-time inventory can never silently go
  stale).
- `env_resolver_test.exs` (async: true via injection; tmp `.env` files):
  persisted-only → `:persisted` + `durable?: true`; ambient WINS persisted;
  durability rows — ambient `A` + persisted `B` → false; blank
  first-precedence entry shadowing a real later one → false (`KEY=`
  defines); intra-file duplicate keys first-wins; full-boot simulation —
  ambient EQUAL file → `:ambient` AND `durable?: true`; four-path
  precedence; missing; **codec property rows** — serialize→parse
  round-trips value-equal for quote/backslash/space-bearing values, and
  serialize REFUSES newline/control-character values (the durability
  predicate can never be poisoned by a value the codec cannot represent;
  the persist flow surfaces the refusal as honest `:session_only`); the
  **dep-loader pin** — `:req_llm` and `:llm_db` `load_dotenv` app env are
  both `false` (compile-time config guard; the one-authority premise);
  **Dotenvy-construct fixtures** — `export ` prefix parses (supported),
  `${...}` interpolation / multiline quoted / unterminated quote /
  ambiguous inline comment each yield the TYPED `:unparseable` variant
  (bounded construct + path + line metadata), which **never falls through
  to a lower-precedence file** and maps to `:unavailable` at the doctor —
  never `:missing_credential`, never a silently different value;
  `durable?` on `:unparseable` is false; the **phantom-assignment
  fixture** — `KEY="first\nOTHER=value\n"` — consumes the block whole:
  `OTHER` appears in NO resolver output and the boot loader never puts it
  into System env.
- `provider_probe_test.exs` (async: true): per-provider request shapes
  (anthropic x-api-key + anthropic-version, google x-goog-api-key +
  `models/` normalization, Bearer for openai-compat); **google fixture
  rows** — real `INVALID_ARGUMENT`/`API_KEY_INVALID` 400 body →
  `auth: :invalid`; permission-reason 403 → `access: :denied` +
  `auth: :ok`; undecodable bodies total; **openrouter rows** — auth from
  `GET /api/v1/key` ONLY (model-lookup 200 with bad key ≠ `auth: :ok`), a
  valid-but-restricted key (`/key` 403) → `access: :denied` + `auth: :ok`
  — NEVER the key-repair gap, model from `/api/v1/model/{author}/{slug}`
  incl. alias + `:free` ids **with the bearer on the lookup request**
  (shape-pinned); **configured-override routing** — a provider with a
  `base_url` override sends its probe requests to that base (any
  provider, not just ollama), and the **generation-only gateway fixture**
  — override responding 404 on the retrieve route → non-repairable
  `model: :unknown` naming the route, never `:absent`/`pick_model`;
  ollama_cloud bearer + base_url via the shared derivation (explicit
  base_url preserved; same effective settings as full-boot `load/1`);
  **sentinel rows** — `OLLAMA_API_KEY=ollama` (ambient AND persisted)
  reads as no cloud credential through `load/1`, the derivation, and
  `apply_generation_env/1` (localhost stays the endpoint);
  canned-status table incl. 404→`:absent`, 405→`:unknown`; 401 vs 403
  split rows; **nil-credential short-circuit** — key-required provider →
  `auth: :invalid`, adapter never called; **path-encoding rows** — a groq
  slash-containing id's exact request URL, openrouter author/slug
  component encoding, a reserved-char hand-edited id; unknown-provider
  total fallback; canonical-id round-trips;
  explicit-credential arg (no System env reads); **endpoint rows** —
  `localhost:11434` ≡ `…/v1`; `gw.example/ollama` ≢ `gw.example/v1`;
  `gw.example/ollama` ≡ `gw.example/ollama/v1`; query/userinfo →
  `:divergent`; explicit `:443` ≡ implicit https; **guard-shape rows** —
  missing host (`https:/ollama.com`), opaque URI, whitespace/control
  characters, malformed port → refused/`:divergent`, never installed;
  resolver-raise → `:divergent`; **a model-level `base_url` fixture →
  `:divergent`** (the one-arm comparison catches what a shortcut would
  hide); **a NON-ollama override differing only by `/v1` → `:divergent`**
  (the translation-layer split — ollama's root≡`/v1` row stays `:equal`)
  — all via the INJECTED resolver (async-safe; the post-bridge
  `:equal` pin against ReqLLM's REAL resolver lives in the async: false
  live-pins module); **inventory rows** — tagged/untagged both
  directions, configured-but-past-truncation still `:present`, empty
  inventory, cap-exceeded → `:unknown`, **typed inventory +
  `inventory_truncated?` ride the result**; **default-adapter (Mint) glue
  rows** against a local `:gen_tcp` stub — normal `/api/tags` JSON decode,
  timeout → `{:error, :timeout}` → `reachable: false`, and
  **streaming-cap rows on status 200 AND 400 AND 500** (oversized/
  unbounded chunked bodies → the adapter closes at cap+1 bytes,
  `{:error, :response_too_large}` → `model: :unknown`, bounded memory in
  every case).
- `setup_test.exs` additions (existing persist_env_var rows :21-76 stay
  green): merged write preserves operator keys (verify_cmd list,
  mcp_servers list-of-maps, nested providers — semantic equality via
  YamlElixir); refuses on unparseable; ymlr round-trip table (`"true"`,
  `"001"`, `"2026-07-12"`, leading whitespace, quotes, backslashes,
  multiline, `:`/`#`, list-of-maps); atomicity (tmp cleaned on rename
  failure); mode invariants (existing 0600 kept, existing 0644 preserved,
  NEW file 0600, tmp chmod'd before content, non-regular refused); dotenv
  path-variant symlink/directory refusal rows (link AND target untouched).
- Repair-flow BRANCH tests (async: true via ALL the seams — prompt/IO,
  env-install, AND the generation-env installer, so no test here touches
  real `:req_llm`/System state): **validate-before-persist rows** — a
  MISTYPED key (probe rejects on the re-derive) triggers NO persistence
  offer and NO dotenv write, the gap stands after its one attempt; a
  probe-green candidate THEN gets the offer; **post-repair
  reconciliation** — the generation-env installer seam is invoked after a
  credential install and after a session-trust confirm (not only config
  writes); persistence ACCEPT
  → install called AND winning dotenv path upserted, `:persisted` only
  after re-resolve confirms `durable?`; the shadowing row
  (`project/.jido/.env` stale value → THAT file upserted); the
  external-winner row (cwd-fallback file untouched, `project/.env`
  written); DECLINE of a live-VALID key → install called +
  `repair_outcomes` `:session_only` + the warning, disposition
  `:repaired`, exit 0 (the decision-#3 alignment row);
  persist failure → rescued `:session_only` + loud message; voyage decline
  → `:voyage_key` gap ⇒ `:gaps_remaining`, flow RETURNS the tagged result
  (no halt fires); e2e malformed repair rows — each
  `:invalid_provider_config` fixture repairs then RE-DERIVES clean;
  wizard-then-derive row — wizard completion with pending migrations
  injected → `:database` gap + `:gaps_remaining`, never
  `:wizard_completed`; **single-invocation convergence rows** — an
  `:unknown_provider` fixture (`provider: typo` + `model: typo:model`)
  finishes `:repaired` in ONE run (provider + compatible model written
  together, final re-derive clean); a provider switch to a key-required
  provider collects the credential on the loop's next pass, same run; a
  stale ollama cloud `base_url` is replaced by the endpoint choice; a
  malformed previously-inactive subtree becoming active repairs in the
  same run; the loop's cycle protection — a repair that cannot clear its
  check exits `:gaps_remaining` after ONE attempt, never re-prompting;
  **persist-offer lane rows** — provider AND voyage: `:ok` +
  `durable?: false` → offer fires in interactive mode only (never check
  mode), accept → winning-path upsert + `:persisted` after the durable
  re-resolve, **decline → disposition still `:healthy`**; **inventory
  picker e2e** — the ollama `:absent` repair's choice list comes from the
  check's typed `data` inventory (NO probe call and NO detail parsing
  between the derive and the write), then the loop's post-write re-derive
  probes normally: an inventory pick lands `:repaired`, a free-form pick
  of an absent model stays a gap (both paths tested); **reconfigure row**
  — a HEALTHY install + `reconfigure: true` runs the full wizard (prompts
  consumed, config replaced, final derivation carried), while plain
  `run/2` on the same install stays a no-prompt doctor report; **persist
  once row** — a step declined inside a repair does NOT re-prompt in the
  persist-offer lane; **check-purity row** — `check_only` through
  `Setup.run/2` calls the generation-env installer seam ZERO times (and
  the live-pins module asserts real `:req_llm` env is byte-identical
  across an in-REPL check); **confirm-override rows** — the interactive
  confirm arms the fingerprint for the SESSION (in-process state, no file
  write) + prints the exact `export` line, and the re-derive proceeds
  armed; decline leaves the gap + nothing armed. (The seam-driven
  versions of the Cloud end-to-end rows live here; every REAL-resolver
  assertion lives in the serial module below.)
- **Live-environment pins in a separate async: false module** (the ONLY
  place real `:req_llm`/System/Application state is touched; full
  snapshot/restore in on_exit): default env-install lands in
  `System.get_env`; the `/setup` handler's `:jido_ai` model-aliases
  refresh lands in Application env; `apply_generation_env` installs BOTH
  `:req_llm` legs — **pinned through ReqLLM's REAL `Keys.get/2`**: a
  custom `api_key_env` credential resolves via the app-config leg,
  keyless local ollama resolves the `"ollama"` placeholder, **the
  blocking-empty regression** — custom name unset while the provider's
  FIXED env var is exported → `Keys.get/2` returns its found-but-empty
  error, NEVER the unprobed fixed var — and an inactive provider's
  previous install is cleared; the post-bridge endpoint pin — bridge
  applied → the verdict's one-arm comparison against ReqLLM's REAL
  `effective_base_url` returns `:equal` for a plain override and
  `:divergent` for a model-level `base_url` fixture; **sanitize-inert
  row** — with
  `:sanitize_external_env` enabled the bridge installs NOTHING (test-boot
  credential isolation holds even for custom-named exported vars);
  **refusal rows** — fresh invalid config → no endpoint installed + the
  loud log with `/setup --check` guidance; valid→invalid transition →
  bridge-owned ENDPOINT entries cleared while `Keys.get/2` STILL returns
  the blocking-empty error (the credential block survives refusal);
  **ownership rows** — seeded pre-existing `:req_llm` config: an
  INACTIVE provider's operator-supplied entry survives every
  apply/clear cycle byte-identical, the ACTIVE provider's entry is
  overwritten (documented bridge ownership), and clearing removes ONLY
  registry-recorded entries; **minimal-boot Cloud end-to-end rows
  (Branch A)** — wizard writes a Cloud config → final derivation
  endpoint-green (never `:endpoint_divergence`), and `--check` on an
  existing Cloud config → `:check_healthy`, both through `Setup.run/2`
  with injected HTTP adapter + the REAL ReqLLM resolver, on the mix and
  escript arm paths (escript via the seam machinery); **post-repair
  reconciliation live rows** — after a credential repair, ReqLLM's REAL
  `Keys.get/2` resolves the NEW key (never a prior blocking-empty); after
  a session-trust confirm, the REAL resolver reports the confirmed
  endpoint (never the refusal-cleared default). (No
  `ensure_all_started` boot pin — the test VM booted before test_helper,
  so it would be vacuous; the whole-boot path is the fresh-VM spot drive
  in Verification, and the `Application.start/2` owner runs post-load by
  OTP ordering.)
- Entry-point rows: pure disposition→code mapping; **update
  jido_exec_patch_test.exs:651-679's `["--setup"]` row** to the mirrored
  minimal-boot seam (boot failure → `halt(2)` pin preserved); prune
  `@cli_env_keys` (:616).
- Raw IO prompt wrappers stay untested (status quo); `migration_status` is
  exercised via the injected probe + the DB pins (sandbox constraint:
  migrations can't run under the SQL sandbox).

## 9. Docs + reconciliation

- **New `docs/system/setup-doctor.md`** (operator decision #2): sources =
  cli/setup.ex, cli/setup/doctor.ex, core/config/env_resolver.ex,
  core/config/provider_probe.ex, core/config.ex, the new test files;
  contracts: minimal boot, durability laws (display-only + the non-gap
  persist-offer lane — the rejected `:not_durable` recorded), per-provider
  probe table incl. the google decode / openrouter exception / endpoint
  law + canonicalizer / inventory membership / the Mint capped adapter,
  migration-probe bounds + drift, persistence/symlink policy,
  disposition→exit map, the Branch A bridge (BOTH legs — endpoint +
  credential; authoritative blocking-empty on absence, typed refusal
  clearing endpoint state + degraded-boot posture, sanitize-inert under
  test boots; mutating-lanes-only owners `JidoClaw.Application.start/2` +
  `Setup.run/2` repair/wizard/reconfigure, load-safe puts; check lane
  provably mutation-free via the pure opts-injection verdict), the
  `EndpointTrust` CB1-1 boundary (pre-dotenv ambient-env authority,
  fail-closed parsing, session-only interactive confirm + printed export
  line, the run_command-forgeability rationale, #15 cross-ref), the
  BootGuard-shared voyage policy, and the Dotenvy-construct detection
  contract;
  residuals: shell-profile durability nuance, per-request `base_url:`
  evasion, agent-writable-config trust note (tool-approval cross-ref),
  merged-write layout loss. **AGENTS.md Key Patterns bullet** pointing at
  it + the docs/system/README.md index entry — same commit
  (`system_docs.check` enforces the pairing both ways).
- **docs/SETUP.md refresh**: the doctor/`--check`/`reconfigure` operator
  surface. **Every surface describing today's `/setup`-replaces-config
  semantics updates in the same change**: README.md (~:443), the CLI help
  text (branding.ex:183), docs/ARCHITECTURE.md (~:594), and
  generated-config comment templates (build-time sweep for `/setup`
  mentions; `jido_md.check`/`system_prompt.check` catch the guarded
  copies).
- No `verified:` bumps for tool-approval/clustering/gateway-runtime-
  security/verify-authority (path-existence only; re-check main.ex vs
  gateway-runtime-security.md at build).
- Status lines (style: the PD1-2 precedents — FWB `**Status (date): ✅
  ADOPTED**`; FIRST-WAVE heading suffix + Done blockquote):
  - `docs/exploration/pms/pad/PD-FIRST-WAVE.md` item 3 (:122, done-when
    :134-138): dated Status + deviations (DB print-only + bounded
    drift-aware probe, minimal-boot doctor, halt removal from the Setup
    API, `:unsupported`/`:unavailable` split + `reason`/`repairable?`
    modeling, ymlr swap + mode-preserving atomic writes + layout residual,
    retrieve-by-id probes + openrouter two-request exception + 401/403
    split + google 400 decode + normalized deadline-bounded adapter,
    value-compared durability kept display-only, live-env install on both
    repair branches, wizard persist-offer + post-wizard final derivation,
    unlinked own-start claim wrapper, centralized total effective-provider
    derivation, the Branch A generation-env authority, `:force_setup`
    deletion, docs-scope overrule).
  - `docs/exploration/pms/pad/FEATURES-WORTH-BORROWING.md` PD3-1 (:577):
    dated ADOPTED Status.
  - `docs/plans/pre-argus-do-now/README.md` §17: dated DONE Status
    (matching the §16 style).
  - ades XA2-3
    (`docs/exploration/ades/Xantham-system-blueprint/FEATURES-WORTH-BORROWING.md:100`):
    cross-ref re-date — the manual provider-check surface landed; the
    scheduled canary (queue #6) stays separately tracked; note #6 should
    consume `ProviderProbe`.
  - crabbox CB1-1
    (`docs/exploration/sandboxes/crabbox/FEATURES-WORTH-BORROWING.md:129`)
    + pre-argus README §15(a): dated PARTIAL cross-ref — the
    `EndpointTrust` boundary closes the provider-endpoint/credential
    slice (probe + generation egress); the general provenance guard (SSH
    `ServerRegistry`, MCP `endpoint_config`) remains #15's scope, and #15
    should generalize from the `EndpointTrust` precedent.

---

## Build order (each phase ends compile-green + its tests)

1. **Deps + one dotenv authority**: ymlr + mint direct deps; the
   `load_dotenv: false` config for `:req_llm` + `:llm_db`; EnvResolver +
   the pure codec (parse + serialize); rewire `load_dotenv/0`. Verify:
   env_resolver_test + application_test + the dep-loader pin.
2. **Effective-provider derivation + `apply_generation_env/1` +
   `EndpointTrust`**: extract the pure total helper from `load/1`
   (sentinel preserved); `EndpointTrust` (pre-dotenv ambient-env
   authority, fail-closed parse, session-arm seam); guarded two-leg
   install (endpoint + credential —
   blocking-empty on absence, typed refusal clearing endpoint state,
   sanitize-inert, trust-gated, load-safe) + the `Application.start/2`
   owner. Verify: config_test byte-compat + guard/sentinel/trust rows +
   the ReqLLM `Keys.get/2` pins (serial module).
3. **ProviderProbe + `check_provider/2` + both callers** (banner + wizard
   test_connection in the same change). Verify: provider_probe_test.
4. **Migration probe + ScratchRepo**: the compile-time
   `MigrationManifest`; claim wrapper + bounded bidirectional listing
   (layout derived from repo config); the async:false DB module. Verify:
   file alone, then once under `scripts/test-partitioned.sh`.
5. **Doctor pure derivation** + doctor_test.
6. **setup.ex internals, shape-preserving**: ymlr writes +
   `write_config_merged/2`, delete `map_to_yaml/2`, path-taking upsert
   variant. Verify: setup_test (:21-76 green + new rows).
7. **Tagged result + ALL wiring (unsplittable)**: `Setup.run/2` + Branch A
   preamble + dispatch (check → reconfigure → wizard/doctor) + the repair
   loop + persist-offer lane + seams; voyage halt removal; repl unwrap;
   commands.ex heads (incl. `/setup reconfigure`) + alias refresh; mix
   arm; escript arm + jido_exec_patch_test row; `:force_setup` deletion;
   disposition→code fn; repair-flow branch tests; live-env pins module
   (Cloud e2e, bridge ownership/refusal/blocking rows). Verify: all new
   files + jido_exec_patch_test + repl/run_command/commands suites.
8. **Docs + reconciliation + gate**: setup-doctor.md + AGENTS.md bullet +
   index; docs/SETUP.md + the `/setup`-semantics sweep (README, branding
   help, ARCHITECTURE.md, generated-config comments); Status lines; then
   the full precommit.

## Verification

- Per-phase test runs as above; regression proofs: existing
  `setup_test.exs` + `config_test.exs` + `application_test.exs` (dotenv)
  green.
- Spot drives: `mise exec -- mix jidoclaw --setup --check` on this checkout
  (must not start the app tree; prints the derivation, exits honestly);
  corrupt `.jido/config.yaml` in a scratch dir → doctor reports `:config`
  `:error` without wizard-launching; **fresh-VM bridge drives** — in a
  scratch dir with a cloud config: (a) `mise exec -- mix run -e` (a
  one-liner that boots the app and prints ReqLLM's effective ollama URL +
  `Keys.get/2` source) proves the `Application.start/2` owner end-to-end
  in a cold VM; (b) `mise exec -- mix jidoclaw --setup --check` in the
  same dir proves the MINIMAL boot resolves endpoints cold (`:req_llm`
  registry populated tree-less); (c) a conflicting cwd-vs-project `.env`
  credential — full boot and `--check` agree on the effective value now
  that the dep dotenv loaders are disabled — the whole-boot pins the
  in-suite tests cannot express.
- **Escript smoke** (precommit never builds it and this build reworks its
  boot path): `mise exec -- mix escript.build`, then `./jidoclaw --setup
  --check` in a scratch directory — pin the printed derivation + exit
  status, confirm no app-tree side effects.
- **Final bar**: `mise exec -- mix precommit` bare in background; iterate
  to green. Known-flaky singleton suites (MCPServer, Prompt, PipelineStore,
  MultiSandbox) verified in isolation before blaming new code. Docs gates
  re-run as edited (`system_docs.check`, `jido_md.check`;
  `graphql.schema.check` expected no-op).

## Suggested commit slicing (operator commits; nothing staged by the agent)

1. `docs: pre-argus wave E #17 plan` — the materialized
   `docs/plans/pre-argus-wave-e-17/README.md`.
2. `feat: setup doctor with --check, provider probes, generation-env authority (PD3-1)` —
   everything else (EnvResolver, derivation + apply_generation_env,
   ProviderProbe, migration probe, Doctor, setup rework, entry points,
   tests, setup-doctor.md + AGENTS.md bullet, Status lines).
