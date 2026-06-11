# Network Review Fix Plan — P1 (agent_id spoof) + P2 (malformed-message crash)

## Context

Post-review of the network hardening changes (currently uncommitted on `main`) surfaced two findings. **Both verified against source** during planning:

- **P1 — VALID, severity confirmed.** `store_received_solution/3` (`lib/jido_claw/network/node.ex:493`) and `handle_solution_response/2` (`node.ex:397`) force attribution via `Map.put(payload, "agent_id", from)` — string key only. `NetworkFacade.store_inbound/2` then runs `MapKeys.normalize_keys(:atom_existing, drop_unknown: true)`, whose **documented collision precedence keeps the atom-keyed value** (`map_keys.ex:114-120`; `ordered_entries/2` at 153-156 processes strings first so atoms overwrite). `:agent_id` is not in `@forced_inbound_keys` (`network_facade.ex:28-45`), and the signature is Ed25519 over `Jason.encode!(payload)` (`protocol.ex:38,91`) — Jason encodes atom keys fine, and the inbound path never goes through `Protocol.decode/1`. So a trusted peer signing `%{agent_id: "victim", ...}` stores a solution attributed to the victim. Blast radius beyond provenance: `Changes.RecordReputationOutcome` (`solution.ex:691-704`) records verification outcomes against `solution.agent_id`, and `Reputation.get(record.agent_id)` feeds `Trust.compute` (`solution.ex:672-684`) — i.e. reputation poisoning of a victim id and trust-score inheritance from a high-reputation id.
- **P2 — VALID, with one nuance.** `verify_inbound/2`'s fallback returns `{:error, :malformed}` for any non-map term, then `log_drop/3` (`node.ex:321-326`) interpolates `message["from"]`; for atoms/tuples/binaries/numbers `Access.fetch/2` raises `FunctionClauseError`, for non-keyword lists `ArgumentError` — crashing the Node GenServer (which restarts disconnected: `init/1` does not resubscribe). Nuance: the crash sits inside `Logger.debug` interpolation and every env pins `logger level: :warning` (`config.exs:177`, `test.exs:41`), so it's dormant at default config — it detonates exactly when an operator enables debug logging to investigate network traffic. Fix unconditionally; the regression test must raise the module log level to reproduce pre-fix.

No report file carries these findings (in-chat review); no doc annotations needed beyond moduledocs touched by the fixes.

**Done-criterion: `mix precommit` passes** (jidoclaw.compile_check → system_prompt.check → deps.unlock --unused → format --check-formatted → reach.check --arch --smells --strict → credo --strict → dialyzer → full test).

---

## P1 — force attribution at the facade

Fix at `NetworkFacade.store_inbound` (not the call sites): the facade's documented job is already "force `sharing`, strip sender-supplied scope/embedding/trust keys" — attribution joins that contract, making spoofing structurally impossible for every caller. Only two production callers exist (both node.ex) plus one test file.

**`lib/jido_claw/solutions/network_facade.ex`:**
1. Change to `store_inbound(payload, from, node_state)` with `is_binary(from)` guard; update `@spec` to 3-arity.
2. Add `:agent_id` to `@forced_inbound_keys` (comment: attribution is forced to the verified sender, never payload-asserted). Dropping post-normalization kills both key shapes — `"agent_id"` normalizes to the (compile-time-existing) atom first.
3. After the existing `Map.put(:workspace_id, ...)`, add `|> Map.put(:agent_id, from)`.
4. Update moduledoc Inbound bullet + `@doc` to state `agent_id` is forced to the verified sender.

**`lib/jido_claw/network/node.ex`:** delete both `Map.put(..., "agent_id", from)` lines; call `NetworkFacade.store_inbound(payload, from, node_state)` directly at 397-399 (response path) and 493-495 (`store_received_solution/3`).

**Post-change sweep:** run `rg "store_inbound\("` across the repo (lib, test, docs) and fix every stale arity reference — known: the facade moduledoc bullet (`network_facade.ex:9` says "`store_inbound/2`") and the test describe heading; the sweep guards against any others.

**Tests:**
- `test/jido_claw/solutions/network_facade_store_inbound_test.exs`: update the existing call to `/3` (describe heading too). The existing `solution.agent_id == "jido_attacker"` assertion **intentionally flips** to assert the `from` argument (the describe's intent — trust stripping — is preserved; attribution now comes from the verified-sender arg). Add spoof cases: payload carrying atom `:agent_id` and payload carrying string `"agent_id"` → both stored with `agent_id == from`.
- `test/jido_claw/network/node_test.exs` (existing harness: `deliver/2`, `trust_peer/1`, `hostile_share_payload/0`): end-to-end spoof regression — trusted peer signs `hostile_share_payload() |> Map.put(:agent_id, "agent-someone-else")` via `Protocol.share_message/2`, deliver as `{:solution_shared, msg}`, assert the stored solution's `agent_id == ctx.peer.agent_id` (pre-fix: the spoof wins). Same shape once more through `Protocol.response_message/3` + `{:solution_response, msg}` to pin the node.ex:397 path. (Signing works: the payload carries only the atom key, so no Jason duplicate-key issue.)

## P2 — safe `from` extraction in `log_drop`

**`lib/jido_claw/network/node.ex`:** add a `message_from/1` helper (comment: `:malformed` drops can carry any term — Access syntax on non-maps raises):

```elixir
defp message_from(message) when is_map(message), do: Map.get(message, "from")
defp message_from(_), do: nil
```

Use it in **both** `log_drop/3` clauses (the `:bad_signature` clause is map-guaranteed today, but the helper costs nothing and survives refactors).

**Test (`node_test.exs`, new describe "malformed message handling"):** raise the drop-path log level surgically — `Logger.put_module_level(JidoClaw.Network.Node, :all)` with `on_exit(fn -> Logger.delete_module_level(JidoClaw.Network.Node) end)` (file is `async: false`; global level stays `:warning`). Connect the node first (`:ok = GenServer.call(ctx.node, :connect)`) so `{:solution_requested, _}` reaches `verified_dispatch` instead of short-circuiting on `status != :connected` — the gating claim covers all three inbound paths, so the regression pins all three. Then inside `capture_log([level: :debug], fn -> ... end)` deliver `[:not_a_map, [1, 2, 3], "binary", 42, {:nested, :tuple}]` under each of `{:solution_shared, _}`, `{:solution_response, _}`, and `{:solution_requested, _}`, asserting `%{status: :connected} = deliver(...)` each time (the call barrier proves survival; pre-fix the GenServer dies and the call exits). Assert the log contains `"(:malformed) from nil"`.

---

## Sequencing

1. **P1** — facade + node.ex + both test files → `mix test test/jido_claw/solutions/network_facade_store_inbound_test.exs test/jido_claw/network/node_test.exs`
2. **P2** — `log_drop` + node_test.exs → `mix test test/jido_claw/network/node_test.exs`
3. Re-run the review's focused area (~96 tests): `mix test test/jido_claw/network test/jido_claw/core/cluster_test.exs test/jido_claw/solutions`
4. `mix format`, then **`mix precommit`** — the done-criterion.

No commits unless asked (working tree already carries the uncommitted network changes these findings apply to).

## Risks / gotchas

- **Facade test assertion flip** is intentional, not a regression — call it out in the diff.
- **Arity change ripple** is fully enumerated: two node.ex call sites + one test file; `@spec` update keeps dialyzer green.
- **Module log-level mutation** in the P2 test: `async: false` file, `on_exit` restores; `capture_log` keeps output clean. Without the level raise the pre-fix crash wouldn't reproduce (debug interpolation never evaluates at `:warning`).
- **Attribution semantics unchanged** on the response path: node.ex already overwrote relayed solutions' `agent_id` with the responder's id; the fix enforces the same semantics robustly. `Reputation.record_share(tenant, from)` stays keyed by the verified sender — consistent.
