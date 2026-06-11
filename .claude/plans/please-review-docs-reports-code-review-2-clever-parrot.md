# Fix code-review findings H4 + H5 + H6 (network trust boundary)

## Context

[docs/reports/code-review-2026-06-10.md](../../docs/reports/code-review-2026-06-10.md) priority tier 5 — the three findings to close "before ever enabling clustering":

- **H4** — `Network.Node`'s `valid_or_unverifiable?/2` (`lib/jido_claw/network/node.ex:385-391`) is a stub that always returns `true`, so inbound `:solution_shared` messages are stored with no signature verification — and the `:solution_response` and `:solution_requested` paths have **no gate at all**. Outbound messages are already Ed25519-signed (`Protocol.encode/3`); `Protocol.verify_message/2` is correct, tested, and has zero production callers. There is no peer-key registry anywhere.
- **H5** — `JidoClaw.Cluster.topology/0` (`lib/jido_claw/core/cluster.ex:93-105`, fallback `135-149`) builds the libcluster Gossip topology with no `:secret`, so any host on the multicast segment is discovered and connect-attempted (libcluster 3.5.0: absent secret = plaintext heartbeats, accept-any). No distribution cookie is configured anywhere.
- **H6** — `NetworkFacade.store_inbound/2` strips scope/embedding keys but not `:trust_score`/`:verification` (`lib/jido_claw/solutions/network_facade.ex:22-37`), and the `:store` create action accepts both with no recompute (`lib/jido_claw/solutions/resources/solution.ex:114-130`) — a peer can self-assert `trust_score: 1.0, verification: %{"status" => "passed"}` and rank top in `find_solution` (trust_score is the primary sort in `:by_signature`, secondary in hybrid search).

Greenfield: no data/path-compat concerns. **Definition of done: `mix precommit` passes** (jidoclaw.compile_check, jidoclaw.system_prompt.check, deps.unlock --unused, format --check-formatted, reach.check --arch --smells --strict, credo --strict, dialyzer, test).

**User decisions (confirmed):** H5 missing-secret → **raise at boot**; H6 → **also delete** the caller-less `:update_trust`/`:update_verification` actions.

Implementation order: **H6 → H5 → H4** (ascending complexity; keeps the suite green incrementally).

---

## H6 — trust is derived server-side, never caller-asserted

### 1. Sanitize layer — `lib/jido_claw/solutions/network_facade.ex`
- Add `:trust_score` and `:verification` to `@forced_inbound_keys` (lines 22-37). Peer-supplied values are `Map.drop`'d before `Solution.store/1`; the rest of the solution (content, tags, language, `agent_id` — which node.ex already forces to the sender) is preserved, `sharing` stays forced `:shared`. Update the moduledoc/`store_inbound` doc to mention trust/verification stripping.
- Slim `to_wire/1` (lines 119-135): drop `"verification"` and `"trust_score"` from the wire map — receivers now force-drop them, so transmitting them is dead weight that invites a future receiver to trust them; trust is local-earned, never transmitted. Note this in the moduledoc. Grep `to_wire` in `test/` for any shape pins to update.

### 2. Contract layer — `lib/jido_claw/solutions/resources/solution.ex`
- Remove `:verification` and `:trust_score` from `:store`'s `accept` (lines 114-130). Any future caller passing them gets a loud `NoSuchInput` error instead of silent self-assertion.
- **Keep `:import_legacy` as-is** (lines 139-157) — the migrator intentionally imports v0.5.x trust.
- Do **not** add `RecomputeTrustScore` to `:store`: new rows keep the attribute defaults (`trust_score: 0.0`, `verification: %{}`) and earn trust via the existing `verify_certificate` → `:update_verification_and_trust` path (which recomputes server-side). Recomputing on create would lift fresh unverified rows to a ~0.5 baseline and change ranking semantics.
- **Delete** the caller-less self-assert vectors: `:update_trust` (lines 213-216), `:update_verification` (lines 218-221), and their `code_interface` defines (lines 86-87). Verified zero callers in `lib/` and `test/`.

### 3. Fix the shared fixture — `test/support/jido_claw/solutions_case.ex` (critical, biggest blast radius)
`solution_fixture/4` unconditionally puts `verification:`/`trust_score:` into the attrs handed to `Solution.store` (lines 138-139) — ~29 call sites across 5 test files would explode with `NoSuchInput` if only the action changed.
- Drop both keys from `base_attrs` (they were pure defaults for every caller except one).
- When `opts` carries a **non-default** `:trust_score` (≠ `0.0`) or `:verification` (≠ `%{}`) override, route the create through `Solution.import_legacy/2` instead of `Solution.store/2` (it still accepts both and runs the same Redact/FK/embedding-status changes; it skips `HintBackfillWorker` + the audit producer, which no fixture consumer relies on). Explicitly-passed default values keep the normal `:store` path and its side effects. This keeps `test/jido_claw/solutions/hybrid_search_sql_test.exs:92` (`trust_score: 0.95` ranking assertion) exact. Document the reroute in the fixture doc.
- `bulk_insert_solutions/4` uses raw `Repo.insert_all` — unaffected, leave alone.

### 4. Update direct `Solution.store` test call sites passing the (now-rejected) defaults
- `test/jido_claw/solutions/reputation_test.exs:76-77` — delete `verification: %{},` and `trust_score: 0.0` lines.
- `test/jido_claw/v064_cross_tenant_test.exs` (~lines 144-146, 161-163) — same.
- Grep `Solution.store(` across `lib/` and `test/` to confirm nothing else passes either key (StoreSolution tool and the network facade are the only lib callers; the tool passes neither).

### 5. New tests
- **`test/jido_claw/solutions/network_facade_store_inbound_test.exs`** (`use JidoClaw.SolutionsCase, async: false`): hostile payload with string keys `"trust_score" => 1.0`, `"verification" => %{"status" => "passed"}` plus legit content/tags/agent_id → `store_inbound/2` succeeds and the persisted row has `trust_score == 0.0`, `verification == %{}`, content/tags/`agent_id` preserved, `sharing == :shared`. Seed via `unique_tenant_id()` + `workspace_fixture/2` so the cross-tenant FK validation passes.
- **Contract pins in `test/jido_claw/solutions/solution_test.exs`**: `:store` with `trust_score:`/`verification:` in attrs → `{:error, %Ash.Error.Invalid{}}` (match the error class + field name via regex, not the exact inner struct); `:import_legacy` with `trust_score: 0.9` → row carries `0.9` (pins the intentional contrast).

---

## H5 — gossip secret required; refuse to boot without it

### 1. `lib/jido_claw/core/cluster.ex`
- DRY the duplicated gossip config (`:gossip` branch lines 93-105 + fallback lines 138-149) into one private `gossip_topology/0`. Unify the fallback's hardcoded port to the `:gossip_port` config read (same 45_892 default — behavior-preserving). The fallback keeps its unknown-strategy `Logger.warning` then calls the shared builder.
- New private `gossip_secret/0`: `Application.get_env(:jido_claw, :cluster_secret) || System.get_env("JIDOCLAW_CLUSTER_SECRET")`, trimmed, empty → missing. (App-env-then-System.get_env at call time mirrors `JidoClaw.Web.AdminAccess`; `.env` is loaded at `application.ex:39` before `cluster_children/0` builds the topology at line 65, so `.env` values work — `runtime.exs` is too early.)
- `gossip_topology/0` includes `secret: secret` in the strategy `config:`. **When missing → `raise`** with an actionable heredoc naming `JIDOCLAW_CLUSTER_SECRET` / `config :jido_claw, :cluster_secret` and the `cluster_enabled: false` escape hatch (style: `JidoClaw.Security.VaultConfig`'s raise-on-missing precedent). The raise lives in the gossip path only — `:kubernetes`/`:epmd`/`:none` need no secret, and `topology/0` is only invoked from `cluster_children/0` when `:cluster_enabled` is true (default false), so the default single-node config can never hit it.
- Do **not** add a `:cluster_secret` default to `config/config.exs` — a committed default secret is worse than none.

### 2. `lib/jido_claw/application.ex` — boot nudge
In `cluster_children/0` (lines 373-385), when cluster is enabled and `Node.self() == :nonode@nohost`, `Logger.warning` that Erlang distribution is not started (clustering needs `--name`/`--sname` + a non-default cookie; point at the README section). Warning only, independent of the secret check.

### 3. Docs
- **`README.md` Clustering section (~841-849)**: `JIDOCLAW_CLUSTER_SECRET` is required for `:gossip` (the app refuses to boot without it); distribution-cookie guidance (set via `RELEASE_COOKIE` for releases or `-setcookie`, never bake/share `~/.erlang.cookie` in images); one sentence on the layered model — the gossip secret **encrypts** discovery (libcluster uses AES-CBC with no MAC, so it is not authentication), the Erlang distribution cookie gates cluster *membership*, and the H4 peer signatures authenticate network *messages*; secret + cookie must both be set and non-default.
- **`.env.example`**: commented `JIDOCLAW_CLUSTER_SECRET=` entry (and the H4 `JIDOCLAW_NETWORK_PEERS=` entry — touch the file once).

### 4. New test — `test/jido_claw/core/cluster_test.exs` (`async: false`; every `put_env`/`delete_env` wrapped in `on_exit` restore)
- gossip topology includes `secret: "s3cret"` when `:cluster_secret` is set.
- missing secret (app env unset **and** `System.delete_env("JIDOCLAW_CLUSTER_SECRET")` to defeat runner-shell leakage) → `assert_raise RuntimeError, ~r/JIDOCLAW_CLUSTER_SECRET/, fn -> JidoClaw.Cluster.topology() end`.
- fallback branch (unknown strategy atom): returns gossip topology with `secret:` when configured; raises when not.
- `:none` → `[]`; `:epmd` → Epmd strategy with `hosts:`, no secret requirement.

---

## H4 — verify inbound network messages; drop unverifiable

### 1. New module — `lib/jido_claw/network/peer_directory.ex`
Allowlist of trusted peer Ed25519 public keys, patterned on `lib/jido_claw/web/admin_access.ex` (read at call time so `.env` works; app env is the test seam and takes precedence):
- Source: `Application.get_env(:jido_claw, :network_peer_keys)` (list of base64 strings) `||` `System.get_env("JIDOCLAW_NETWORK_PEERS")` (comma-separated base64).
- Parse: split/trim/reject blanks; `Base.decode64` each; require `byte_size(key) == 32` (Ed25519 pubkey); invalid entries → `Logger.warning` and skip (one bad key must not kill all inbound). Agent ids are always **derived** via `JidoClaw.Agent.Identity.derive_agent_id/1` — no id:key pair config, fewer operator mistakes.
- API: `@spec configured?() :: boolean()` — true iff **at least one valid key parsed**, not merely raw config non-empty (an invalid-only `JIDOCLAW_NETWORK_PEERS` must still trigger the connect-time "inbound will be dropped" warning); `@spec fetch(String.t()) :: {:ok, binary()} | :error`. Real `@moduledoc` (credo --strict). Per-message parse cost is negligible — inbound network messages are rare (same rationale AdminAccess documents).

### 2. `lib/jido_claw/network/node.ex` — the real gate
- Replace `valid_or_unverifiable?/2` (lines 385-391) with e.g. `verify_inbound(message, expected_type) :: :ok | {:error, :malformed | :type_mismatch | :unknown_peer | :bad_signature}`: assert `message["type"] == expected_type` for the handler (`"share"` / `"request"` / `"response"`), then `PeerDirectory.fetch(from)` → `Protocol.verify_message(message, pubkey)`. Tagged errors (not a bare boolean) let handlers log per-reason without re-parsing: `warning` on `:bad_signature`, `debug` on `:unknown_peer` (noise control on shared segments) and the rest. The envelope `"type"` is **unsigned**, so the assertion is consistency-checking, not crypto — but Node dispatches on the PubSub tuple tag, not the envelope, so without it a peer's validly signed `share` payload could be re-wrapped under a `{:solution_response, …}` tuple; with the type check plus each handler's payload-shape requirements, cross-type replay is closed (no two message types share a payload shape).
- Apply to **all three** inbound types — drop means: no store, no response broadcast, no `add_peer`, no `Reputation.record_share`:
  - `handle_solution_shared/2` (291-310): swap the stub in the `with`; on drop return `state` unchanged.
  - `handle_info({:solution_requested, …})` + `handle_solution_requested/2` (264-272, 312-346): currently completely ungated — respond and `add_peer` only when verified. **Also harden the peer-supplied `opts` end-to-end:** `String.to_existing_atom(k)` (line 316) crashes on non-binary keys (`FunctionClauseError`, which the `ArgumentError` rescue misses), and even with valid keys, bad *values* flow into `Matcher.find_solutions/2` (e.g. `"language" => :elixir` reaches `Fingerprint.signature/3` expecting a binary; `"limit" => "wat"` breaks result limiting). Replace the atomization with a `sanitize_request_opts/1` whitelist keeping only known options with valid value types — `language`/`framework`/`error_class` when binary, `limit` when integer (clamped to a sane bound; confirm against Matcher's defaults), `threshold` when number — dropping everything else. This also closes the report's **L18** (whitelist permitted request-option keys).
  - `handle_info({:solution_response, …})` + `handle_solution_response/2` (274-282, 348-371): currently completely ungated — gate before the store loop.
- `same_agent?/2` stays as the first filter (self-broadcast short-circuit).
- `handle_call(:connect)` (161-182): after successful `Identity.init`, when `PeerDirectory.configured?()` is false, `Logger.warning` ("no peer keys configured — all inbound network messages will be dropped; outbound sharing still works"). Still connect — outbound-only sharing is legitimate.
- Testability: `start_link/1` (line 47) → `name: Keyword.get(opts, :name, __MODULE__)` (default unchanged; client API still targets the singleton).
- **Residual risks — document in a code comment + the report, accepted:** the signature covers only `payload` (not `from`/`type`/`id`/`timestamp`). The key is looked up *by* `from`, so a cross-`from` spoof fails verification; the per-handler type assertion plus payload-shape mismatch closes cross-type replay in practice. Verbatim replay of a peer's old signed message remains possible (no nonce/timestamp window) — acceptable because PubSub injection requires BEAM cluster membership (closed by H5 + cookie), and a cluster member already has full RCE.

### 3. New tests
- **`test/jido_claw/network/peer_directory_test.exs`** (`async: false` — mutates app/System env; `on_exit` restores): `configured?` false on unset/empty **and when only invalid entries are configured**, true with a valid key; `fetch/1` round-trip (generate keypair → encode64 → configure → `fetch(derive_agent_id(pub))` returns the raw key); unknown id → `:error`; invalid entries (bad base64, 16-byte key) warn-and-skip while a valid sibling still resolves; app env takes precedence over `JIDOCLAW_NETWORK_PEERS`.
- **`test/jido_claw/network/node_test.exs`** (`use JidoClaw.SolutionsCase, async: false` — shared sandbox mode means the supervised Node transparently shares the test's DB connection; no `Sandbox.allow` needed). Per test: seed `unique_tenant_id()` + `workspace_fixture/2`; `start_supervised!({Network.Node, name: unique, project_dir: tmp_dir, tenant_id: …, workspace_id: ws.id})` — explicit tenant/workspace opts bypass `Resolver.ensure_workspace` (init already honors them, node.ex:139-148); a per-test tmp `project_dir` because `:connect` → `Identity.init` writes `.jido/identity.json`. Build peer identities exactly as `test/jido_claw/network/protocol_test.exs:16-24` does; configure via `Application.put_env(:jido_claw, :network_peer_keys, [b64])` + `on_exit`. Sync after `send/2` with `GenServer.call(pid, :status)` (mailbox ordering guarantees the info was processed). Cases:
  - trusted peer's signed `:solution_shared` → row exists under the test tenant/workspace with `sharing: :shared` **and `trust_score == 0.0`** (ties H4 to H6);
  - unknown peer, validly signed → no row, `peer_count == 0`;
  - trusted peer, tampered payload → no row, warning logged (`ExUnit.CaptureLog`);
  - cross-type replay: a trusted peer's validly signed `share` message delivered as `{:solution_response, …}` → dropped by the type assertion, no row;
  - request path: `GenServer.call(pid, :connect)`, subscribe the test to `"jido:network"`, seed a `:shared` solution — trusted signed `:solution_requested` → `assert_receive {:solution_response, _}`; unknown peer → `refute_receive`;
  - malformed opts (keys): trusted signed `:solution_requested` whose `opts` carry atom/garbage keys → Node survives (still alive via `:status`), no crash;
  - malformed opts (values): trusted signed request with known keys but hostile values (`"language" => :elixir`-style non-binary, `"limit" => "wat"`) → sanitized away, Node survives and still responds;
  - `:solution_response` from unknown peer carrying a hostile solution → no row.

> Why not reuse the app singleton: it booted with `project_dir()`-resolved tenant/workspace that don't exist in the per-test sandbox, so its writes couldn't be asserted against test-seeded scope — an isolated supervised instance with explicit opts is the clean path.

---

## Final step — annotate the report

`docs/reports/code-review-2026-06-10.md`, following the existing house convention (cf. H7/H8/H9):
- H4 (line 78), H5 (line 86), H6 (line 94) headers get ` — ✅ fixed <date>`; each gets a `**Fixed (<date>):**` paragraph describing what shipped (including the H4 residual-risk acceptance and the H6 fixture reroute + deleted dead actions).
- L18 (request-opts atomization): annotate as closed by the H4 `sanitize_request_opts/1` key+value whitelist.
- Priority list item 5 (line 291): strike through and append `✅ Done <date> — …` one-liner, matching items 1-4.

## Verification

```bash
# scoped, while iterating per finding:
mix test test/jido_claw/solutions/network_facade_store_inbound_test.exs \
         test/jido_claw/solutions/solution_test.exs \
         test/jido_claw/solutions/reputation_test.exs \
         test/jido_claw/v064_cross_tenant_test.exs \
         test/jido_claw/solutions/hybrid_search_sql_test.exs \
         test/jido_claw/solutions/matcher_test.exs \
         test/jido_claw/core/cluster_test.exs \
         test/jido_claw/network/

# definition of done:
mix precommit
```

## Gotchas

- **The fixture edit (H6 §3) must land in the same change as the accept-list edit** — otherwise ~5 test files fail at once with `NoSuchInput`.
- Ash error shape: assert on `Ash.Error.Invalid` + field-name regex, not the inner struct, to stay robust.
- Test env hygiene: runner shells may carry `JIDOCLAW_CLUSTER_SECRET`/`JIDOCLAW_NETWORK_PEERS` — missing-value tests must `System.delete_env` with `on_exit` restore; drive everything else through the app-env seam.
- `reach.check --smells --strict`: don't introduce a new cross-file fixed-shape map (the peer map stays internal to `PeerDirectory`).
- `jidoclaw.system_prompt.check`: unaffected — no new tools.
- Dialyzer: accurate `@spec`s on `PeerDirectory` and the new cluster helpers; the raise branch needs no special handling.
