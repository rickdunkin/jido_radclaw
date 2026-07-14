# SD6 — Repair & reconfiguration workflow

*Builds: the interactive doctor — bounded repairs, persistence offers,
merged YAML writes, `/setup reconfigure`, the tagged `Setup.run/2` result,
and the default-lane switch from wizard-replaces-config to
doctor-repairs-gaps. Depends on: SD4 (the derivation + check surface) and
SD5 (repairs must republish the authority so `:repaired` is honest —
INV-13). Contracts owned: INV-13 (Setup half), INV-16, INV-19, INV-20,
INV-26 (write-time), INV-27, INV-28, ST-3, ST-5, OD-3. **Completes PD3-1**
(PD-FIRST-WAVE item 3's done-when).*

> **What this owns.** Everything that MUTATES: the repair loop, credential
> installation + dotenv persistence, config writes, the wizard's
> integration into the doctor flow, and the operator-facing dispositions +
> exit codes. After SD6, re-running `/setup` never replaces a healthy
> config — it derives, repairs only the gaps, offers persistence, and
> reports honestly; `/setup reconfigure` is the intentional full-wizard
> path (INV-19).

## Design

### 1. `Setup.run/2` — tagged result + seams

`run/1` → `run(project_dir, opts \\ [])` returning
`{:ok, %{config: map(), checks: [Doctor.check()], disposition:
:wizard_completed | :healthy | :repaired | :gaps_remaining |
:check_healthy | :check_unhealthy, repair_outcomes: %{Doctor.step() =>
:persisted | :session_only | :declined}}}` — the typed home for repair
state a re-derive cannot honestly recompute. `opts` carries injectable
**prompt/IO, env-install, and authority-publish seams** (defaults: raw IO
prompts, `System.put_env`, SD5's publish) so repair branching tests never
touch real global state. **`Setup` never calls `System.halt`** — exits are
owned by the mix/escript entrypoints via the pure disposition→code mapping
(0: `wizard_completed`/`healthy`/`repaired`/`check_healthy`; 1:
`gaps_remaining`/`check_unhealthy`); the REPL never exits. All four callers
updated + tested: `repl.ex` `ensure_config` (:94-100), `commands.ex`
`/setup` (:496-500) + `/config` (:502) — unwrap → `Config.model/1` **and
refresh `Application.put_env(:jido_ai, :model_aliases, …)` mirroring
`repl.ex:70`** (adjacent fix: an in-session `/setup` leaves aliases stale
today) — the mix arm, the escript arm. `run_command.ex`'s
`ensure_configured` refusal (:229-235) untouched. Both setup arms move onto
SD4's minimal boot (nothing downstream of `Setup.run` needs the app tree —
verified; the wizard's probes get `:inets`/`:ssl`).

### 2. Dispatch — check first, then reconfigure, then wizard/doctor

1. **check_only** routes FIRST and mutates NOTHING (SD4's lane — zero
   prompts, zero file/System/Application mutations, zero authority
   publishes).
2. **reconfigure** (`reconfigure: true`; REPL `/setup reconfigure`, CLI
   `--setup --reconfigure`): the full wizard regardless of health (INV-19),
   followed by the same final derivation.
3. Config ABSENT → today's full wizard, **then a final derivation**
   (republishing the authority after the write): clean → `:wizard_completed`;
   remaining gaps → `:gaps_remaining` (the summary says config was written
   AND names the gaps — exiting 0 with pending migrations is exactly the
   failure the doctor exists to expose).
4. Config present → doctor: derive → print → the **bounded
   re-derive-and-repair loop** (INV-27: each step at most ONE attempt per
   invocation, cycle-protected; a repair that exposes the next gap — a
   provider switch needing a credential — still converges in one run) → the
   **persist-offer lane** (INV-28, INV-20: interactive mode only, never
   check mode, skipping steps already in `repair_outcomes`) → closing
   summary carrying the final derivation.

### 3. Credential repairs — validate before persist (OD-3 alignment)

Prompt for the key, install into the live process (env-install seam — an
in-REPL repair must update the running VM), **republish the authority**
(INV-13 — a repaired key must not stay shadowed by a prior blocking
resolution), re-derive so the real probe judges it, and offer persistence
ONLY once `:provider_key` reads `:ok` — a probe-rejected candidate is NEVER
written to dotenv. Accepted persistence goes via the 0600 atomic upsert
(`persist_env_var`, `setup.ex:305-337`) **to the winning PROJECT-OWNED
path**: `persisted_path` ∈ the two project paths → upsert in place (fixes
the shadow; the path-taking upsert variant is missing-or-regular by lstat —
ST-5); a cwd fallback outside project_dir → never mutate the external file —
write `project/.env` (outranks both cwd paths) and name the external
definition; defined nowhere → default `project/.env`. The upsert
re-validates the var name (INV-26) at write time. Accept → re-resolve and
mark `:persisted` only when `durable?/1` confirms, else honest
`:session_only` + loud message. **Declined or failed persistence of a VALID
key never gates health** (INV-16): outcome `:session_only`, loud
won't-survive-restart warning, disposition from the final checks alone.
The first-run wizard's `configure_api_key` (:161-196) reuses this flow; its
already-set detection (:169-173) reads the resolver. Voyage keeps
prompt+persist — the `System.halt(1)` on decline (:121) is REMOVED: an
EMPTY voyage prompt (genuinely missing credential, distinct from declined
persistence) = `:voyage_key` gap ⇒ `:gaps_remaining`; mix/escript exit 1
from the mapping, REPL first-run warns and continues.

### 4. Other repairs (per-step dispatch; reason rides the check)

- `:model` — non-ollama `:absent`/`:invalid_model`/`:provider_model_mismatch`
  → `pick_model` + merged write; **ollama `:absent` → the inventory-driven
  picker** (ST-3: from the check's typed `data`, never detail parsing,
  never a second probe; empty inventory → non-repairable + `ollama pull`
  guidance; truncation noted, free-form fallback). The selection is proven
  by the loop's post-write re-derive; an absent free-form pick stays a gap
  after its one attempt.
- `:config` `:missing_provider`/`:unknown_provider` — a provider-subset
  interview building the COMPLETE selected-provider state in one merged
  atomic write (INV-27): sanitized active subtree, the ollama local/cloud
  endpoint choice (a stale `providers.ollama.base_url` is replaced, not
  inherited), a compatible model in the SAME interview; a missing credential
  for the new provider surfaces on the loop's next pass, same invocation.
- `:config` `:invalid_provider_config` — additionally SANITIZES before
  merging (`deep_merge` preserves what the interview doesn't overwrite, so
  the repair explicitly replaces/drops the malformed active-subtree
  fields).
- `:config` `:unconfirmed_override` — show provider + exact base_url +
  api_key_env; operator confirms → the `EndpointTrust` fingerprint arms
  **in process memory only** (never a file — same-user files are
  agent-forgeable, INV-7) + the exact `export JIDOCLAW_ENDPOINT_TRUST=...`
  line prints for durable trust; the re-derive proceeds armed and the
  authority republishes (INV-13). Declined → the gap stands, nothing armed.
- `:database` — print-only, always.

### 5. YAML writing — ymlr, atomic, mode-preserving

Promote `{:ymlr, "~> 5.1"}` to a direct dep (already in lock via reactor);
`write_config/2` + new `write_config_merged/2` emit via `Ymlr.document!/1`,
written atomically (tmp + rename + 0-leak cleanup — today's non-atomic
wholesale `File.write!` :286-293 goes); DELETE the hand-rolled
`map_to_yaml/2` (:386-411). Permission invariant (rename replaces the
inode; config can carry literal MCP headers): chmod the tmp BEFORE content;
existing regular destination → preserve its mode; new file → `0600`;
non-regular → refuse loudly. Merged write: `read_user_config` →
`deep_merge` → encode → atomic write; refuses unparseable existing files
(the doctor never routes those here). **Accepted residual** (moduledoc +
Status): parse→merge→re-emit loses operator comments/anchors/layout —
semantic content preserved (test-pinned), source layout not.

## Decisions

- **D1 — default-lane flip messaging.** SD6 changes what plain `/setup`
  does on a present config (wizard → doctor). One release note + the
  INV-19 doc sweep should land together; confirm at interview whether the
  REPL first-run flow needs any additional affordance beyond the doctor
  report.
- **D2 — wizard internals reuse.** The wizard keeps its interview functions
  but returns through the tagged result; confirm no second entry path into
  `persist_env_var` remains outside the codec-validated upsert.

## Test plan

`setup_test.exs` additions (existing persist_env_var rows :21-76 stay
green): merged-write semantic preservation (verify_cmd list, mcp_servers
list-of-maps, nested providers); refuses unparseable; ymlr round-trip table
(`"true"`, `"001"`, dates, whitespace, quotes, backslashes, multiline,
`:`/`#`, list-of-maps); atomicity (tmp cleaned on rename failure); mode
invariants; symlink/directory refusal rows (link AND target untouched).
Repair-flow BRANCH tests (async: true via ALL the seams):
validate-before-persist (mistyped key → no offer, no write, gap stands;
probe-green candidate → offer); post-repair reconciliation — the
authority-publish seam invoked after credential installs AND session-trust
confirms, not only config writes (INV-13); winning-path rows (shadow fixed
in place; external cwd winner untouched, `project/.env` written); decline
of a live-valid key → `:session_only` + `:repaired`, exit 0 (INV-16 pin);
persist failure → rescued `:session_only`; voyage decline → gap +
`:gaps_remaining`, tagged return, no halt; single-invocation convergence
rows (INV-27 — typo provider + model repairs in ONE run; provider switch
collects the credential same-run; stale ollama base_url replaced; cycle
protection exits `:gaps_remaining` after one attempt); persist-offer lane
rows (interactive only; decline stays `:healthy`; offered at most once —
INV-20); inventory-picker e2e (ST-3 both paths); reconfigure row (healthy
install + `reconfigure: true` runs the wizard; plain run stays a no-prompt
report); check-purity row (check_only invokes the publish seam ZERO times);
confirm-override rows (session arm + export line; decline arms nothing).
Live-pins additions (the SD5 async: false module): after a credential
repair, ReqLLM's REAL `Keys.get/2` resolves the NEW key (never a prior
blocking resolution); after a session-trust confirm, the real resolver
reports the confirmed endpoint; minimal-boot Cloud end-to-end (wizard
writes a Cloud config → final derivation endpoint-green; `--check` on it →
`:check_healthy`) on the mix and escript arm paths. Entry-point rows: full
disposition→code mapping; the escript arm keeps the HD-3 pin.

## Docs & reconciliation (lands with this WS — the completion sweep)

- `docs/system/setup-doctor.md`: extend with the repair loop, persistence
  policy, dispositions, the layout-loss residual; bump `verified:`.
- **Every surface describing `/setup`-replaces-config updates in the same
  change** (INV-19): README.md (~:443), `branding.ex:183` help text,
  docs/ARCHITECTURE.md (~:594), generated-config comment templates
  (build-time sweep; `jido_md.check`/`system_prompt.check` catch guarded
  copies). docs/SETUP.md gets the full doctor/reconfigure surface.
- Status lines (PD1-2 precedent style): PD-FIRST-WAVE item 3 → dated DONE +
  deviations; pad FEATURES-WORTH-BORROWING PD3-1 (:577) → dated ADOPTED;
  pre-argus queue §17 → dated DONE (matching the §16 style).
- `## Deviations` maintained in this doc as built.

## Cross-references

- [CONTRACTS.md](CONTRACTS.md) — INV-13, INV-16, INV-19, INV-20, INV-26,
  INV-27, INV-28, ST-3, ST-5, OD-3, HD-1/3/7.
- [SD4](SD4-read-only-doctor.md) — the derivation + `repairs/1`/
  `persist_offers/1` this consumes. [SD5](SD5-runtime-provider-authority.md)
  — the authority every repair republishes through.
