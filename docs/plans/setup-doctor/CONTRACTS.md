# Setup Doctor — Contract Inventory

*The binding decisions and verified invariants preserved from the superseded
2026-07-14 #17 draft. This is the review rubric for every workstream in this
group: a WS is not done while an entry it owns is violated. Each entry is
tagged with its owning workstream(s). File:line references were verified
against HEAD `4cf076dc` on 2026-07-14 — re-verify at build time.*

Provenance: 2026-07-12 operator interview + three same-day review rounds;
2026-07-14 operator interview (three new decisions); 2026-07-14 three-reader
HEAD sweep + dedicated integration stress-test; two architecture-review
rounds on the resulting draft. The draft itself
(`.claude/plans/please-review-docs-plans-pre-argus-do-n-generic-scone.md`,
local, untracked) is superseded as an executable plan by this group.

---

## OD — Binding operator decisions

- **OD-1 — Generation consumes the validated config (Branch A: wire it).**
  [SD5] The *outcome* binds: a configured provider `base_url` and the
  `api_key_env`-resolved credential must actually drive generation, for every
  active provider — never probe-only. Accepted, named behavior change: a
  cloud key alongside a local ollama daemon flips generation from
  localhost-proxied to ollama.com direct, and previously-ignored provider
  `base_url` overrides become live. The draft's *mechanism*
  (`Application.put_env(:req_llm, …)` bridge) was rejected in architecture
  review — mutable app env is not the runtime control plane; SD5 owns the
  redesigned mechanism (atomic snapshot + consumption seam).
- **OD-2 — Docs scope: system page + AGENTS.md bullet.** [SD4, extended by
  SD5/SD6] Overrules the 2026-07-12 draft's "no docs/system page" line. New
  `docs/system/setup-doctor.md` + a Key Patterns bullet, machine-guarded by
  `system_docs.check` both ways. Created at SD4 (first shipped surface);
  SD5/SD6 extend it (or SD5 adds its own page — SD5 D4) bumping `verified:`.
- **OD-3 — Durability is display-only, never a health gate.** [SD1, SD4,
  SD6] The stress-test's `:not_durable` gap proposal is REJECTED: only
  `auth: :invalid` yields the key-repairable gap, and a
  shell-profile-exported key is restart-safe yet reads non-durable — a
  permanent false red. Durability shows in the report (shell-profile caveat
  named in the detail) and drives the interactive persist-offer only; it
  never feeds `healthy?/1`. Supersedes the 2026-07-12 draft's "decline
  persistence ⇒ `:gaps_remaining`, exit 1" line (see INV-16).

## INV — Review-hardened invariants

### Configuration foundation

- **INV-8 — One dotenv authority: the dependency loaders stand down.** [SD1]
  ReqLLM and LLMDB each load cwd `.env` into System env at THEIR app start,
  before `JidoClaw.Application.start/2` — with `project_dir ≠ cwd` and
  conflicting keys, the cwd value wins as "ambient" while minimal `--check`
  resolves the project-owned value. `config.exs` sets
  `config :req_llm, load_dotenv: false` and `config :llm_db, load_dotenv:
  false` (compile-time; app-env pin test guards both). The lost dep-side cwd
  auto-load is covered by our chain's cwd fallback paths (documented
  compatibility note).
- **INV-15 — Disabling the dep loaders is a PARSER change, detected loudly
  and TYPED.** [SD1] Dotenvy accepts `export ` prefixes, `${...}`
  interpolation, inline comments, and multiline quoted values our line codec
  does not. The shared parse SUPPORTS `export ` (trivial strip) and DETECTS
  the rest as a first-class `:unparseable` variant (bounded construct + path
  + line metadata) — never a nil. `:unparseable` never falls through to
  lower-precedence files (that would resolve a value Dotenvy never produced)
  and maps to `:unavailable` naming the construct — never the repairable
  `:missing_credential` lane. Detection is a FILE-LEVEL scan: an unsupported
  quoted block is consumed whole to its closing quote (or EOF), so
  assignment-looking continuation lines (`KEY="first\nOTHER=value\n"`) never
  mint phantom credentials. Boot logs a loud warning naming
  file+line+construct; parity fixtures document each construct's disposition.
- **INV-12 — The dotenv parser and serializer are ONE codec.** [SD1] Today's
  serializer escapes quotes (`setup.ex:373`) but the loader only strips outer
  quotes and never unescapes — round-trip inequality would poison the
  value-compared `durable?/1` forever. The codec pair lives in EnvResolver
  (the loader gains the matching unescape — greenfield, no compat shim), is
  property-tested as inverses, and persistence REJECTS values dotenv cannot
  represent (embedded newlines/control chars → honest `:session_only` +
  message, never a mangled file line).
- **INV-26 — Env-var NAME validation before any System call or dotenv
  write.** [SD1 rule; SD4 validation; SD6 write-time] `api_key_env` must
  match `^[A-Za-z_][A-Za-z0-9_]*$` — `"A=B"`/NUL raise ArgumentError in
  System calls, and a whitespace/newline-bearing name would INJECT a second
  dotenv line through the upsert's line assembly (`setup.ex:341`). Malformed
  → `:invalid_provider_config`; the upsert re-validates at write time
  (defense in depth).
- **INV-23 — The ollama local sentinel is preserved.** [SD1 derivation; SD5
  authority] `normalize_api_key/2` (`config.ex:285-288`) treats
  `OLLAMA_API_KEY=ollama` as NO cloud credential — the derivation applies it
  (no auto-cloud reroute) while the authority still supplies the placeholder
  to generation (keyless local ollama must pass `Provider.Defaults`'
  always-require-a-key rule). Sentinel pins ride `load/1`, the doctor, and
  the authority.

### Trust boundary (crabbox CB1-1)

- **INV-7 — Endpoint/credential overrides need OPERATOR TRUST from authority
  the agent tier cannot write.** [SD1 read-side; SD2/SD4 gating; SD5
  enforcement; SD6 interactive confirm] Agent-writable `.jido/config.yaml`
  choosing both the destination `base_url` and the credential source
  `api_key_env` is the recorded crabbox credential-redirection shape; local
  config edits bypass tool approval, and a `~/.jido` FILE store is no better
  (`run_command` shell redirection writes host paths unchanged;
  absolute-write approval covers `write_file`/`edit_file` only; 0600 cannot
  distinguish same-user processes). Trust therefore rides the **pre-dotenv
  AMBIENT host environment**: `JIDOCLAW_ENDPOINT_TRUST` (fingerprint entries
  `{provider, exact normalized base_url | :default, api_key_env |
  :default}`), read from the ambient snapshot captured BEFORE any dotenv
  load. A non-default `base_url` or `api_key_env` is honored — probed,
  installed into the authority, or its credential var READ — only when
  attested there, or when the operator confirms interactively in `/setup`
  (session-only arm; the exact `export` line is printed for durable trust —
  the trust var is not persistable by us, by design). Unconfirmed → nothing
  installed, NO request to the override, NO read of the custom var, a
  `:config` gap reason `:unconfirmed_override`; `--check` reports it
  honestly red. Malformed trust entries fail CLOSED. Defaults (official
  provider bases, localhost ollama, the constant ollama.com auto-cloud,
  default env names) need no confirmation. An exploit test through the real
  `run_command` path pins that agent-written artifacts arm nothing. Closes
  the #17-created slice of CB1-1; the general provenance guard (SSH
  `ServerRegistry` etc.) stays queue #15 — cross-ref recorded both ways.

### Provider diagnostics

- **INV-6 — The endpoint verdict has ONE arm — the real resolver, PURE.**
  [SD2] No analytical `:equal` shortcut and no by-constant arm — either
  blinds the verdict to a model-level `base_url`, which outranks app config
  in ReqLLM's `effective_base_url` order. The comparison needs NO installed
  state: `effective_base_url(provider_mod, model, base_url: desired)`
  injects the candidate via the opts leg; result ≡ desired (canonicalized) ⇔
  `:equal`; anything else — including a model-level `base_url`, including a
  resolver raise — → `:divergent`, fail-closed. Check mode therefore mutates
  nothing, not even Application env.
- **INV-17 — The `/v1` equivalence is OLLAMA'S translation, not URI
  identity.** [SD2; SD5 install rule] The canonicalizer splits into (1)
  generic URI validation + identity normalization for ALL providers —
  absolute hierarchical URI, scheme ∈ {http, https}, nonblank host, valid
  port, no userinfo/query/fragment, no whitespace/control chars
  (`https:/ollama.com` parses with a nil host and must refuse);
  default-port + trailing-slash normalization; compare
  scheme/host/port/FULL path — and (2) provider-specific endpoint
  TRANSLATION — root ↔ `/v1` equivalence + `/v1` suffix insertion for ollama
  ONLY (its OpenAI-compat mount). For every other provider `/v1` is a
  semantic path segment: overrides differing only by `/v1` are `:divergent`,
  and fingerprints/installs carry the full normalized path verbatim.
- **INV-21 — OpenRouter's auth verdict comes exclusively from
  `GET /api/v1/key`; the model lookup still sends the bearer.** [SD2] Its
  model lookup returns 200 without valid auth (operator-verified), so it can
  never prove a key; and its documented endpoint contract requires auth on
  the lookup (the observed anonymous 200 is behavior, not contract). 403
  from `/key` = `access: :denied` + `auth: :ok` — a restricted-but-valid key
  must never trigger the key-replacement repair.
- **INV-22 — Override-route 404s are never repairable absence.** [SD2; SD4
  routing] On a configured `base_url`, a 404 proves only that the gateway
  lacks the metadata route → non-repairable `model: :unknown` naming the
  route (a generation-capable proxy without model retrieval must not loop
  `pick_model` on a healthy install). `:absent` requires a provider-OWNED
  endpoint.
- **INV-25 — Response caps hold on EVERY status and EVERY response part.**
  [SD2] `:httpc` streams only 200/206 (error bodies arrive fully buffered),
  and body-chunk counting misses unbounded status lines/headers/trailers
  Mint buffers before emitting events. The default adapter is Mint-based
  with a **total raw-response byte budget counted on transport messages
  BEFORE they feed Mint's parser**; exceed → close +
  `{:error, :response_too_large}`. Mint promoted to a direct dep (1.9.1 in
  lock via finch). Oversized rows cover bodies on 200/400/500 AND
  never-terminated status/header/trailer streams.
- **INV-30 — Native ids percent-encode as path segments.** [SD2] groq ids
  carry `/` (`meta-llama/…`); openrouter splits author/slug FIRST and
  encodes each component. Per-provider request-shape tests pin exact URLs
  for slash-containing ids; a provider verified at build to require RAW
  slashes gets a per-provider rule + deviation log. A mis-encoded id may
  only yield `:unknown`/`:absent`-with-detail, never a crash.
- **INV-29 — Structured inventory crosses the boundary typed.** [SD2 → SD4 →
  SD6] The ollama probe result carries typed `inventory` +
  `inventory_truncated?`; `Doctor.check` carries a typed `data` map; the
  repair picker consumes it — never detail-parsing, never a second probe.

### Migration diagnostics

- **INV-11 — Local migration inventory is a compile-time manifest.** [SD3]
  The escript bundles no `priv/` (`main.ex:42-44`) — a directory listing
  would report a cold DB fully migrated. A generated `MigrationManifest`
  module (`@external_resource` over `priv/repo/migrations`,
  `{version, name}` pairs) is the ONE local inventory for mix, REPL, and
  escript alike; a test pins manifest ≡ the live directory. Duplicate
  versions/names (local or DB) → `:unavailable`, never silently collapsed.
  The probe derives the migration table name/prefix from repo config
  (`:migration_source`, prefix) and documents `:migration_repo` + dynamic
  repos as out of scope.
- **INV-18 — Migration reads are cardinality-bounded, not just
  time-bounded.** [SD3] A corrupted/replaced migration table can return
  arbitrarily many rows within 5s — the probe runs a bounded `count(*)`
  first (implausible count vs the manifest → `:unavailable`), then a
  `LIMIT`-ed ordered select sized from the manifest, and duplicate detection
  via a bounded `GROUP BY … HAVING … LIMIT 1`. Client memory never scales
  with table size (high-cardinality scratch-table row pins it).

### Doctor semantics

- **INV-9 — Minimal boot starts the resolver runtime, never the app tree.**
  [SD4] The check lane's boot is `ensure_all_started([:inets, :ssl,
  :req_llm])` — req_llm ensures llm_db and populates the provider registry +
  model catalog the endpoint verdict needs (string model resolution falls
  through to an EMPTY registry otherwise). With the dotenv loaders disabled
  (INV-8) this start mutates nothing; the JidoClaw supervision tree never
  starts on doctor arms. A fresh-VM minimal `--setup --check` drive
  exercises endpoint resolution cold.
- **INV-24 — Missing credentials classify BEFORE probing.** [SD4] EnvResolver
  is authoritative without a network: a key-required provider whose
  credential is locally absent → deterministic repairable `:provider_key`
  gap reason `:missing_credential`, `:model` `:unavailable`, probe fun NEVER
  invoked. Ollama is key-optional and exempt (the nil-key short-circuit at
  `config.ex:364-365` is the precedent).
- **INV-14 — The voyage check shares BootGuard's policy.** [SD4] With
  `:embeddings_strict_boot` disabled, BootGuard accepts a missing
  `VOYAGE_API_KEY` — the doctor reports `:voyage_key` as `:unsupported`
  (healthy) and excludes it from repairs AND persist offers. The
  required-policy predicate is extracted so the two consumers cannot drift.

### Runtime provider authority

- **INV-2 — The authority carries the CREDENTIAL too, authoritatively.**
  [SD5] Our configurable `api_key_env` is invisible to ReqLLM's `Keys.get/2`
  (per-request opt → app config → the provider's FIXED env var), and
  `Provider.Defaults` always requires a key. The authority supplies the
  doctor's effective resolution: present → the value (including the local
  ollama placeholder); **absent → a BLOCKING explicit-empty resolution** —
  never a bare pass-through, which would let `Keys.get/2` fall to a fixed
  env var the doctor never probed (custom-name-missing/default-name-present
  is the regression row). Pinned through ReqLLM's REAL `Keys.get/2`.
- **INV-4 — Refusal is typed and fail-closed on state — but the credential
  block SURVIVES refusal.** [SD5] A guard-refused endpoint value is never
  installed (a valid→invalid config transition never leaves a stale endpoint
  live) while the active provider's credential rule stays in force (value or
  blocking-empty — clearing it would reopen the fixed-var fallthrough;
  `Keys.get/2` asserted AFTER refusal). Full boot does NOT fail — it logs
  the refused value loudly with `/setup --check` guidance and generation
  endpoints degrade to provider defaults (the doctor is the repair path;
  killing boot would remove it).
- **INV-3 — The authority is INERT under test-boot sanitization.** [SD5]
  When `:sanitize_external_env` is enabled (config/test.exs — the test-boot
  credential-isolation guarantee), the authority installs/serves nothing
  live; real ReqLLM state is exercised only by explicit async: false
  live-pin rows with snapshot/restore.
- **INV-5 — The endpoint authority covers EVERY provider with a configured
  `base_url`, not just ollama.** [SD5; SD2 probe-what-you-use] Config
  already advertises e.g. OpenRouter's `base_url` as an override
  (`jido_md.ex:329-334`); the authority applies the guard-passing override
  for the ACTIVE provider generally, and probe requests target the confirmed
  configured endpoint when present.
- **INV-10 — Installed state has an ownership story; inactive providers are
  never touched.** [SD5] The draft's app-env ownership registry dissolves
  under a snapshot design (the snapshot IS the owned state), but the
  requirement survives: pre-existing operator-supplied `:req_llm` config for
  INACTIVE providers is never clobbered, and the ACTIVE provider's
  resolution is authoritative by declaration. Tests seed pre-existing
  `:req_llm` config.
- **INV-13 — The authority applies on MUTATING lanes only — but after EVERY
  desired-state change there.** [SD5, SD6] Boot, plus one reconciliation
  point in `Setup.run/2` invoked after every successful config write, every
  credential installation, AND every session-trust confirmation — a repaired
  key must not stay shadowed by a prior blocking-empty resolution, and a
  session-confirmed endpoint must not stay cleared from an earlier refusal.
  `:repaired` may never be reported while generation still resolves old
  state (live rows through ReqLLM's REAL resolvers pin key + endpoint after
  each repair kind). The CHECK lane — standalone `--check` AND in-REPL
  `/setup check` — performs ZERO mutations of any kind (INV-6's pure verdict
  makes this free); no self-heal, no VM-local exception.
- **INV-1 — Load-safety (conditional).** [SD5] Bound only if the mechanism
  writes `:req_llm` app env: `Application.load/1` does not load
  dependencies, and a put on an UNLOADED app is clobbered when
  `ensure_all_started` later loads it (`run_command.ex:265-292` records the
  hazard + the `load_app_spec!/1` fix). Under the snapshot redesign this
  dissolves — record its resolution in SD5's Deviations either way.

### Repair & reconfigure

- **INV-16 — Valid session-only credentials stay healthy.** [SD6] A repair
  that installs a VALID key whose persistence is then declined (or fails)
  yields `:repaired` with `repair_outcomes[step] = :session_only` and a loud
  won't-survive-restart warning — never `:gaps_remaining`/exit 1.
  Dispositions derive from the final checks alone (OD-3).
- **INV-27 — Repairs converge in ONE invocation.** [SD6] The provider
  interview builds the COMPLETE selected-provider state (sanitized subtree,
  local/cloud endpoint choice, compatible model, credential collection) in
  one merged atomic write, and the repair pass is a bounded
  re-derive-and-repair loop — each step at most one attempt per run,
  cycle-protected — so a repair that exposes the next gap still finishes
  without a second `/setup` run. A step whose attempt didn't clear its check
  is `:gaps_remaining`, never a silent success and never a re-prompt loop.
- **INV-28 — Persistence offers are a separate NON-GAP lane.** [SD6] An
  `:ok` credential with `durable?: false` gets an interactive persist-offer
  (`Doctor.persist_offers/1`); declining stays healthy (OD-3).
- **INV-20 — Each credential is persist-offered at most once per
  invocation.** [SD6] The persist-offer lane excludes steps already present
  in `repair_outcomes` — a persistence declined or failed inside a repair is
  not re-prompted seconds later.
- **INV-19 — Intentional reconfiguration survives the doctor.** [SD6]
  `/setup reconfigure` (REPL) and `--setup --reconfigure` (mix/escript) run
  the full wizard on a HEALTHY install. Every doc surface describing
  `/setup`-replaces-config updates in the same change (README.md ~:443,
  `branding.ex:183` help text, docs/ARCHITECTURE.md ~:594, generated-config
  comment templates).

## HD — HEAD-drift facts (verified 2026-07-14 @ `4cf076dc`)

- **HD-1** — `cli/main.ex` was rewritten by the #16 commit: the escript
  `--setup` arm is `main.ex:75-87` — `persistent: true` app-env puts
  (comment :77-79: `app: nil` + `Application.load` clobbers non-persistent
  env) and boot via checked `start_app_or_halt!()` (:83, injectable
  `cli_app_starter` seam, exit 2 on failure). The arm exits after
  `Setup.run` (the REPL is a separate `main/1` clause :89-102). [SD4, SD6]
- **HD-2** — `:force_setup` is dead code: writer `main.ex:82`, sole reader
  `Setup.needed?/1` (`setup.ex:22`) — never consulted on the escript arm,
  never set on the mix arm. Delete the write, the `needed?/1` cond head, and
  the `@cli_env_keys` snapshot entry (`jido_exec_patch_test.exs:616`).
  `repl.ex:95` / `run_command.ex:230` keep identical `needed?/1` behavior.
  [SD4]
- **HD-3** — `jido_exec_patch_test.exs:651-679` pins the `["--setup"]` argv
  through the checked-boot fall-through (injected starter error →
  `halt(2)`). Any arm rework must keep an equivalent pin: mirror the
  injectable-seam shape and update the row in the same change (decided:
  mirror the seam, don't drop the row). [SD4, SD6]
- **HD-4** — `check_ollama` (`config.ex:348-360`) is status-only today — it
  never parses the `/api/tags` body; tags-membership model checking is NEW
  behavior. [SD2]
- **HD-5** — `ollama_cloud` is a wizard **pseudo-provider**
  (`config.ex:385-397`; `setup.ex:247-254` + `build_config` :238 map it to
  provider `"ollama"` + `base_url`); a hand-edited
  `provider: "ollama_cloud"` would pass a literal membership test —
  normalize ollama_cloud→ollama during `:config` validation. [SD1, SD4]
- **HD-6** — Model ids are `provider:model` strings with possibly more
  colons (`"ollama:nemotron-3-super:cloud"`); split `parts: 2` (the
  `repl.ex:988` / `setup.ex:211` precedent). [SD1, SD2, SD4]
- **HD-7** — House mix-task test style is `ExUnit.CaptureIO`
  (`Mix.Shell.Process` has zero precedent); prompt/IO seams are injected
  opts (no seam exists today; prompts are raw `IO.gets`,
  `setup.ex:418/:440`). [SD4, SD6]
- **HD-8** — No scratch-repo/`storage_up` precedent exists — the cold-DB
  probe test is first-of-kind and must be partition-safe
  (`MIX_TEST_PARTITION`). [SD3]
- **HD-9** — `Ecto.Migrator`'s listing cannot be bounded:
  `skip_table_creation` works, but the versions SELECT runs
  `timeout: :infinity` (`schema_migration.ex` `@default_opts`) — the probe
  uses bounded direct queries instead. [SD3]
- **HD-10** — Docs-page bumps: `core/config.ex` is in tool-approval.md
  sources and `application.ex` in
  clustering/gateway-runtime-security/verify-authority sources —
  path-existence only, no semantic overlap expected, so no `verified:`
  bumps; `cli/main.ex` is in gateway-runtime-security.md sources — re-check
  at build that arm rework stays outside that page's claims. [SD1, SD4, SD6]
- **HD-11** — HTTP adapter decision: the draft's `:httpc` choice is
  superseded — Mint with the raw-byte budget is the decided adapter
  (INV-25); `check_api_key`'s 5s timeout precedent is `config.ex:370`. [SD2]

## ST — Stress-test resolutions (taken as recommended, deviation-logged)

- **ST-1** — Google's invalid-key responses arrive as **400
  `API_KEY_INVALID`**, not 401 → bounded, total JSON error-body decode:
  `API_KEY_INVALID` → `auth: :invalid` (repairable); permission/restriction
  reasons or an undecodable 403 → `access: :denied` + `auth: :ok`;
  other/undecodable 400 → `auth: :unknown`. [SD2]
- **ST-2** — Ollama membership computes over the FULL decoded inventory
  before any display bound, with `:latest`-tag canonicalization in both
  directions (never rewriting config); cap-exceeded body → `model:
  :unknown`, never false-absent. [SD2]
- **ST-3** — Ollama `:absent` repair is inventory-driven (picker over
  installed models from the check's typed `data`; empty inventory →
  non-repairable + `ollama pull` guidance); non-ollama `:absent` keeps the
  `pick_model` catalog repair. The selection is verified by the loop's
  post-write re-derive. [SD6]
- **ST-4** — The check disposition splits into `:check_healthy |
  :check_unhealthy` so the disposition→exit mapper stays pure. [SD4]
- **ST-5** — The path-taking dotenv upsert requires missing-or-regular by
  lstat (symlink/dir → refuse loudly, rescued to `:session_only`). [SD6]
- **ST-6** — All DB probe test rows run on the scratch repo — never
  `JidoClaw.Repo`, whose sandbox pool the probe must not touch. [SD3]

## Hard gates (carried from the draft, apply to every WS)

- No PORT map (posture/contract lift — `docs/exploration/README.md` rule).
- Queue discipline: dated Status lines on every source entry, falsified
  claims corrected, cross-refs updated the same session — **per WS, not in a
  final sweep**.
- Run mix via `mise exec -- mix`; gates bare (never piped), in background,
  read the tail; known-flaky singleton suites verified in ISOLATION before
  blaming new code.
- Nothing committed by the agent; work lands unstaged, ending with
  files-to-stage + suggested slicing. Completion bar per WS:
  `mise exec -- mix precommit` green.
- New public functions need `@moduledoc`/`@spec` (credo strict); `reach
  --arch` direction — core modules never reference CLI modules (the shared
  dotenv parse lives in core; `application.ex` consumes it).
- No silent deferrals inside a WS: if a unit balloons mid-build, pause and
  surface it.
