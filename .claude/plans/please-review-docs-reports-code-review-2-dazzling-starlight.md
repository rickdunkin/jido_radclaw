# Resolve code-review findings H3 + H12

## Context

From `docs/reports/code-review-2026-06-10.md`:

- **H3** — `RpcChannel "sessions.list"` (`lib/jido_claw/web/channels/rpc_channel.ex:26-39`) runs an **unscoped** `Registry.select` over `JidoClaw.SessionRegistry` and returns every tenant's `{tenant_id, session_id}` pairs to any authenticated socket. Every other handler derives tenant from `socket.assigns.current_user`. Also in scope (review-flagged + user-confirmed): the catch-all `join("rpc:" <> _topic)` admits any subtopic, and `gateway.status` does the same unscoped select for its session count.
- **H12** — In `lib/jido_claw/conversations/resources/session.ex`, `set_prompt_snapshot` (124-139) and `set_current_agent_template` (160-177) are `require_atomic?(false)` function changes that read the loaded record's `metadata`, mutate in memory, and `force_change_attribute(:metadata, full_map)` — replacing the whole jsonb column. A writer holding a stale struct silently clobbers the concurrently-written `metadata["compactions"]` snapshot (the atomic `Changes.SetCompactionSnapshot` at lines 316-366 is the in-file reference pattern to mirror).

Greenfield: no data/path migration compatibility concerns. **Done = `mix precommit` passes** (compile_check, system_prompt.check, deps.unlock --unused, format, reach.check --arch --smells --strict, credo --strict, dialyzer, full test suite — runs in `:test` env).

Design validated against dep source (ash 3.27.8, ash_postgres 2.9.1, phoenix): `change/3` is optional when a change module implements only `atomic/3`; the inner `{:atomic, expr}` wrapper bypasses `Ash.Type.Map.cast_atomic/3`; `get_argument` returns `nil` for the explicit-nil callers; and **deleting** the join catch-all would crash with `FunctionClauseError` (ERROR log + generic `"join crashed"`), so it must be kept as an explicit error clause instead.

---

## Part 1 — H12: atomic single-key metadata writers (do first; isolated)

**File: `lib/jido_claw/conversations/resources/session.ex`**

1. Add one parameterized inline change module beside `Changes.SetCompactionSnapshot` (in the "Inline change modules" section). Must have a `@moduledoc` (credo strict). Both target keys are **top-level**, so no nested-parent `||` dance is needed (that complexity in `SetCompactionSnapshot` exists only because `jsonb_set` won't auto-create the `compactions` parent):

```elixir
defmodule Changes.SetMetadataKey do
  @moduledoc """
  Atomically sets or deletes a single top-level `metadata[key]` slot via
  `jsonb_set` / `#-` in the UPDATE itself, so a writer holding a stale
  record can never clobber concurrently-written sibling keys
  (e.g. `metadata["compactions"]`).

  A nil argument deletes the key (Map.delete semantics). That branch is a
  real path only for actions whose argument is `allow_nil?: true`
  (`:set_current_agent_template`); for `:set_prompt_snapshot` the
  `allow_nil?: false` argument is rejected by action-input validation
  before the change runs, so its delete branch is generic-but-unreachable.
  """
  use Ash.Resource.Change

  import Ash.Expr

  @impl Ash.Resource.Change
  def init(opts) do
    # Parameterized change: fail fast on malformed opts instead of letting
    # a nil key/argument flow into get_argument or the SQL path. Uses
    # Keyword.fetch/2 + {:error, ...} (the callback's contract) rather than
    # a raising fetch!.
    with {:ok, key} when is_binary(key) <- Keyword.fetch(opts, :key),
         {:ok, argument} when is_atom(argument) <- Keyword.fetch(opts, :argument) do
      {:ok, opts}
    else
      _ ->
        {:error, "SetMetadataKey requires :key (string) and :argument (atom), got: #{inspect(opts)}"}
    end
  end

  @impl Ash.Resource.Change
  def atomic(changeset, opts, _context) do
    key = Keyword.fetch!(opts, :key)

    case Ash.Changeset.get_argument(changeset, Keyword.fetch!(opts, :argument)) do
      nil ->
        {:atomic,
         %{metadata: {:atomic, expr(fragment(
           "coalesce(?, '{}'::jsonb) #- array[?]::text[]", metadata, ^key))}}}

      value ->
        encoded = Jason.encode!(value)

        {:atomic,
         %{metadata: {:atomic, expr(fragment(
           "jsonb_set(coalesce(?, '{}'::jsonb), array[?]::text[], ?::text::jsonb, true)",
           metadata, ^key, ^encoded))}}}
    end
  end
end
```

   - Encode-then-`?::text::jsonb` matches the existing module's documented pattern (raw param to `::jsonb` double-encodes). `Jason.encode!("reviewer")` → JSON string scalar — same shape as today's `Map.put`.
   - nil-vs-absent argument are indistinguishable via `get_argument` and both mean delete — matches today's `Map.delete` semantics for `:template`; don't try to distinguish.

2. Rewire both actions — delete `require_atomic?(false)` and the inline `change(fn ... end)`; keep argument declarations and `code_interface` untouched:
   - `:set_prompt_snapshot` → `change({__MODULE__.Changes.SetMetadataKey, key: "prompt_snapshot", argument: :snapshot})`
   - `:set_current_agent_template` → `change({__MODULE__.Changes.SetMetadataKey, key: "current_agent_template", argument: :template})`

Caller safety (verified): all 5 call sites (`conversations/resolver.ex:100`, `tools/handoff.ex:243`, `agent/handoff/router.ex:336`, `platform/session/worker.ex:459`, `jido_claw.ex:551`) either discard the result or use the returned record, which an atomic update populates from `RETURNING` — strictly fresher than today's in-memory merge. The nil callers exercise the delete branch.

### H12 tests — extend `test/jido_claw/conversations/session_compaction_keying_test.exs`

Reuse its `seed/0` + `actor/1` helpers and `Session.by_id` reread pattern; widen the moduledoc (file now also proves cross-writer coherence). Note this file manages its own sandbox owner — keep that, don't convert to TenantCase.

1. **Stale-struct clobber regression (the H12 proof), one test per writer:** load `stale = Session.by_id(...)` *before* any compaction exists → `set_compaction_snapshot(fresh, "main::default", ...)` → `set_current_agent_template(stale, "reviewer", ...)` (resp. `set_prompt_snapshot(stale, "snap text", ...)`) → reread and assert **both** `metadata["compactions"]["main::default"]` survived **and** the new key is set. (Fails on the old code, passes on the new — verify red/green by running these tests once against a temporarily-reverted action.)
2. **Delete branch, ordered to prove delete + no-clobber together:** set template → load stale struct → write sibling keys (compaction snapshot + prompt_snapshot) → `set_current_agent_template(stale, nil, ...)` → assert template key gone **and** both siblings survive.
3. **Mixed concurrent writers (deterministic):** preload **all** stale structs up front (every task gets a struct loaded *before* any task runs, so each write provably starts from pre-write state), then spawn tasks mixing all three writers; assert every task returns `{:ok, _}`. All `current_agent_template`/`prompt_snapshot` writers in this test use **non-nil** values (nil/delete semantics live only in the dedicated delete test) so asserting key presence is valid. Assertions respect key semantics: **all** compaction subkeys survive simultaneously (distinct subkeys); `prompt_snapshot` and `current_agent_template` are single top-level keys where last-writer-wins — assert each is present and equal to one of the values written, not all of them.

---

## Part 2 — H3: tenant-scope the RPC channel

**File: `lib/jido_claw/web/channels/rpc_channel.ex`** — reuse the existing `tenant_for/1` (line 108) and `JidoClaw.Session.Supervisor.list_sessions/1` (`platform/session/supervisor.ex:49-57`, already correctly scoped; returns `[{session_id, pid}]` with tenant dropped, so re-attach the caller's tenant for the wire shape):

1. **`sessions.list`** — replace the raw `Registry.select` + key-shape `case`:

```elixir
def handle_in("sessions.list", _payload, socket) do
  tenant_id = tenant_for(socket)

  sessions =
    tenant_id
    |> JidoClaw.Session.Supervisor.list_sessions()
    |> Enum.map(fn {session_id, _pid} -> %{tenant_id: tenant_id, session_id: session_id} end)

  {:reply, {:ok, %{sessions: sessions}}, socket}
end
```

2. **`gateway.status`** — replace the unscoped count with `length(JidoClaw.Session.Supervisor.list_sessions(tenant_for(socket)))`.

3. **Join hardening — keep the catch-all clause, make it reject** (do NOT delete it; a missing clause means `FunctionClauseError` → ERROR-level stacktrace + opaque `"join crashed"` reply):

```elixir
def join("rpc:" <> _topic, _payload, socket) do
  {:error, %{reason: "unauthorized topic"}}
end
```

   Safe: README (`README.md:648-654`) documents `rpc:lobby` as the only join target; no other client exists in repo.

### H3 tests — new `test/jido_claw/web/rpc_channel_test.exs`

Follow the proven boot pattern from `test/jido_claw/web/admin_route_test.exs`:

- `use JidoClaw.TenantCase, async: false` (owns the sandbox in shared mode — do **not** add another `Sandbox.start_owner!`), `import Phoenix.ChannelTest`, `@endpoint JidoClaw.Web.Endpoint`, setup does `start_supervised!(JidoClaw.Web.Endpoint)` (test env is `server: false`, endpoint not in app tree; PubSub is in Core and always running).
- User via `User.register_with_password(%{email: unique, password:, password_confirmation:}, authorize?: false)` (copy `register_user!` helper).
- Socket bypasses `connect/3`: `socket(JidoClaw.Web.UserSocket, "user_socket:#{user.id}", %{current_user: user, current_actor: JidoClaw.Authorization.Actor.build(user)})` → `subscribe_and_join(RpcChannel, "rpc:lobby")`.
- Fake registry entries via spawned **unlinked** holder processes (`spawn/1`, not `spawn_link/1`) calling `Registry.register(JidoClaw.SessionRegistry, {tenant_id, session_id}, nil)` (matches `list_sessions/1`'s match spec; an entry unregisters when its holder dies). The helper **blocks on an explicit ack** — holder `send`s `{:registered, ref}` to the test pid after `Registry.register/3` returns, and the helper `assert_receive`s it before returning — so the channel push can't race the registration. **Cleanup is explicit, not implicit:** track holder pids and `on_exit(fn -> Enum.each(pids, &Process.exit(&1, :kill)) end)`; unlinked is required here because `:kill` through a link would take the test process down with it. Own-tenant entries must use exactly `to_string(user.id)`; foreign tenant + all session ids unique via `System.unique_integer` (the registry is global across tests).
- Tests (registry order is not contractual — compare as `MapSet`/sorted, never positionally):
  1. `sessions.list` returns exactly the own-tenant session set (foreign entries registered but absent from reply; reply shape `%{sessions: [%{tenant_id:, session_id:}]}`).
  2. `gateway.status` `sessions` count = own-tenant count only.
  3. `subscribe_and_join(socket, RpcChannel, "rpc:other")` → `{:error, %{reason: "unauthorized topic"}}`.

---

## Part 3 — Docs

1. **`docs/reports/code-review-2026-06-10.md`** — follow the established fixed-finding convention (see H10/H11): append `— ✅ fixed 2026-06-10` to the H3 and H12 headings, add a short **Fixed (2026-06-10):** paragraph to each (H3: tenant-scoped via `list_sessions/1`, gateway.status count scoped, join catch-all now rejects; H12: both writers converted to atomic `jsonb_set`/`#-` single-key changes via `Changes.SetMetadataKey`, cross-writer regression tests added), and update the priority-order section (item 2's "H12 remains open"; H3 sits in the threat-model "Deprioritize" list — annotate it fixed there too).
2. **`README.md`** (~line 648-654) — note that RPC sessions are scoped to the authenticated user's tenant, and **remove the `tenant_id` field from the `sessions.create` / `sessions.sendMessage` example payloads** (the server derives tenant from the authenticated user and ignores it; leaving it in the examples keeps suggesting client-controlled tenancy).

## Verification

1. `mix test test/jido_claw/conversations/session_compaction_keying_test.exs test/jido_claw/web/rpc_channel_test.exs` — new regressions green (and red/green sanity-check the stale-struct tests against the old action code once).
2. Existing behavior guards stay green: `mix test test/jido_claw/conversations test/jido_claw/agent test/jido_claw/web test/jido_claw/reasoning/compactor` (covers `public_api_handoff_test`, `worker_handoff_hydration_test`, `router_test`, compactor storage/coherence).
3. **`mix precommit` passes — the completion gate.** Known watch-items:
   - credo strict: `@moduledoc` on the new change module (included above).
   - reach `fixed_shape_map` smell: adding a second `%{metadata: {:atomic, ...}}` construction *might* fire; verify first, and only if it fires, extract a shared private helper (or, least preferred, add a scoped ignore with rationale in `.reach.exs`).
   - dialyzer: no new surface expected (`SetCompactionSnapshot` already type-checks under the same pattern).
