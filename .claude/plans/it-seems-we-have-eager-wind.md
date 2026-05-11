# v0.6.4 Phase 4 — Final Gap Closure

## Context

Three remaining gaps from the v0.6.4 phase 4 cleanup tracked at the
bottom of `.claude/plans/you-were-working-on-sparkling-ullman.md`
(lines 508–522). The original plan flagged five items as "deferred to
v0.7+." This plan closes three of them; the other two stay deferred.

- The **Cron Scheduler reload path silently drops `:mfa`** on Job rows.
  `Worker.execute_job/1` at `worker.ex:111-142` rescues the resulting
  `MatchError` and converts it to `{:error, _}`, so today the failure
  presents as "system job always fails after reload" — three "ticks"
  later `disabled_at` is persisted and the job is gone. Latent
  data-loss bug, no crash to alert on.
- **`ApiKeyAuth` emits no `:auth_event` audit rows** for API-key
  sign-ins. `AuthController` already emits these for password
  sign-in/out, so we have an audit-trail asymmetry that bites
  compliance posture and incident response. (Correction to the prior
  plan note: `RequireAuth` doesn't emit either — `AuthController` is
  the producer to mirror, not `RequireAuth`.)
- **`RequestCorrelation` sweeper relies on a permissive `always()`
  policy** rather than an explicit bypass. The prior plan claimed the
  sweeper uses `authorize?: false`; it does not. Future policy
  tightening would silently break the 60s sweep loop.

### Out of scope

- Full `agent_id` introduction on RequestCorrelation (v0.7+ — needs a
  cohesive agent-identity story; `agent_id` already has 5+ overloaded
  meanings in the codebase).
- `Tenants.Tenant` admin scoping for `:archive`/`:suspend`/`:resume`
  (zero production callers today; reopen when an admin role exists).
- Untenanted resources (Reasoning.Outcome, Embeddings, Forge.*) — per
  the original plan.

---

## Slice A — Explicit sweeper bypass

**File:** `lib/jido_claw/conversations/resources/request_correlation.ex:247-262`

`sweep_expired/0` today calls `Ash.read!/1` and `Ash.bulk_destroy!/3`
with no options. It works only because the resource carries
`authorize_if always()` (lines 74–78). Add `authorize?: false` to both
calls so the bypass is explicit at the call site.

```elixir
def sweep_expired do
  expired =
    __MODULE__
    |> Ash.Query.for_read(:expired)
    |> Ash.Query.limit(@sweep_batch)
    |> Ash.read!(authorize?: false)

  case expired do
    [] -> {:ok, 0}
    records ->
      Ash.bulk_destroy!(records, :complete, %{}, authorize?: false)
      {:ok, length(records)}
  end
end
```

Replace the policy-block comment (lines 70–73) with a version that's
accurate about the bypass surface:

```elixir
# RequestCorrelation has internal callers with no actor in scope
# (Recorder telemetry callbacks, Session.Worker durable lookups, and
# JidoClaw.chat's correlation registration). The 60s sweeper bypasses
# explicitly via `authorize?: false` in `sweep_expired/0`; the others
# rely on this permissive policy. Closing the broader gap requires
# the v0.7+ agent-identity work.
```

No behavior change today. No test change needed.

---

## Slice B — ApiKeyAuth `:auth_event` emission

**Files modified:** `lib/jido_claw/web/plugs/api_key_auth.ex`
**Files added:** `test/jido_claw/web/plugs/api_key_auth_test.exs`
(directory is net-new)

Mirror `AuthController.emit_auth_event/3` at
`lib/jido_claw/web/controllers/auth_controller.ex:42-52` — same
`AsyncWriter.cast/1` shape, same `tenant_id: "default"` (users are
untenanted by design), same `target_kind: :auth`, same `payload` field
name (not `metadata`).

### Plug change

Add `alias JidoClaw.Audit.AsyncWriter` at the top of the plug (the
file currently has no audit imports). Then add the helper:

```elixir
defp emit_auth_event(kind, actor_id, payload) do
  AsyncWriter.cast(%{
    tenant_id: "default",
    event_kind: :auth_event,
    actor_kind: if(actor_id, do: :user, else: :system),
    actor_id: actor_id,
    target_kind: :auth,
    target_id: Atom.to_string(kind),
    payload: payload
  })
end
```

Wire into both branches of `call/2`:

- Success branch (after `{:ok, user} = authenticate(...)`):
  `emit_auth_event(:api_key_sign_in_success, to_string(user.id), %{})`
- Failure branch (in the `else` clause, before the `send_resp`):
  `emit_auth_event(:api_key_sign_in_failure, nil, %{reason: reason})`

`target_id` strings get an `api_key_` prefix to disambiguate from
password-auth flows. Single `_failure` event covers both
`"missing_api_key"` and `"invalid_api_key"` — the cause goes in
`payload.reason`. Use `to_string(user.id)` (UUID → string) to match
the safe shape `AuthController.sign_out` uses; the audit `actor_id`
attribute is `:string`.

`api_key_id` could go in the payload via `user.__metadata__`
(AshAuthentication attaches the matched key after `sign_in/3`), but
the metadata key isn't verified, ApiKey has no `last_used_at`, and a
minimal payload is easy to extend later. Defer.

### New test file

`test/jido_claw/web/plugs/api_key_auth_test.exs` — net-new file in a
net-new directory. Mirror
`test/jido_claw/web/controllers/auth_controller_test.exs` (full read
at lines 1–145):

- `use JidoClaw.TenantCase, async: false`
- `setup`: `JidoClaw.Tenants.Tenant.ensure("default")`; snapshot
  baseline `:auth_event` row count under tenant `"default"`
- Drive `ApiKeyAuth.call/2` directly with
  `Phoenix.ConnTest.build_conn(:get, "/v1/...", %{})` +
  `Plug.Conn.put_req_header/3` — no router involved
- Copy the `eventually/1` helper from `auth_controller_test.exs`
  (lines 127–143) verbatim

**Payload keys are JSONB-encoded — assertions must tolerate both
atom and string keys.** The existing audit tests at
`test/jido_claw/audit/event_test.exs:70` already use this pattern.
Helper:

```elixir
defp payload_get(payload, key) do
  Map.get(payload, key) || Map.get(payload, to_string(key))
end
```

**Valid-API-key fixture.** No existing helper covers this; create
inline. AshAuthentication's `GenerateApiKey` change attaches the
plaintext to the created `ApiKey` as Ash metadata under the key
`:plaintext_api_key`. Read it with `Ash.Resource.get_metadata/2`:

```elixir
defp create_user_with_api_key do
  password = "valid-password-123456"

  user_attrs = %{
    email: "apikey-test-#{System.unique_integer([:positive])}@example.com",
    password: password,
    password_confirmation: password
  }

  {:ok, user} =
    JidoClaw.Accounts.User
    |> Ash.Changeset.for_create(:register_with_password, user_attrs)
    |> Ash.create(authorize?: false)

  {:ok, api_key} =
    JidoClaw.Accounts.ApiKey
    |> Ash.Changeset.for_create(:create, %{user_id: user.id})
    |> Ash.create(authorize?: false)

  plaintext = Ash.Resource.get_metadata(api_key, :plaintext_api_key)
  {user, plaintext}
end
```

`:register_with_password` requires `:password` and
`:password_confirmation` (AshAuthentication's password strategy). If
the action name differs, verify against the strategy config in
`accounts/user.ex` during implementation. `:create` on ApiKey may
need to be a strategy-specific action — verify against
`accounts/api_key.ex` during implementation.

Test cases:

1. **Valid API key** → success row, `target_id == "api_key_sign_in_success"`,
   `actor_kind == :user`, `actor_id == to_string(user.id)`.
2. **Invalid API key** → failure row, `target_id == "api_key_sign_in_failure"`,
   `actor_kind == :system`, `actor_id == nil`,
   `payload_get(latest.payload, :reason) == "invalid_api_key"`.
3. **Missing API key header** → same failure row with
   `payload_get(latest.payload, :reason) == "missing_api_key"`.

---

## Slice C — Cron Scheduler MFA reload

**Files modified:**
- `lib/jido_claw/platform/cron/scheduler.ex` — `load_persistent_jobs/2`
  (lines 15–38) and `build_persistent_opts/1` (lines 40–47), plus new
  private helpers
- `test/jido_claw/cron/persistent_disable_test.exs` — add a third
  contract test; update the moduledoc (lines 13–17) once the bug is
  fixed

### The fix

`build_persistent_opts/1` currently emits only `[id, task, schedule, mode]`.
The Worker's `init/1` (`worker.ex:50-65`) reads `:mfa` from opts. For
`:system_job` mode, `Worker.execute_job/1` at `worker.ex:134-136` does
`{m, f, a} = state.mfa; apply(m, f, a)` — inside a `try/rescue`. When
`state.mfa == nil`, the `MatchError` is rescued at line 138 and
converted to `{:error, exception_message}`. So the Worker doesn't
crash — it just fails forever until `persist_disabled/1` (3 ticks
later) writes `disabled_at` and the row is filtered out on next
reload. **The bug is silent data loss, not a crash.**

Job row already carries `mfa_module: string`, `mfa_function: string`,
`mfa_args: map` (`lib/jido_claw/cron/resources/job.ex:170-188`). The
`:upsert` action accepts and round-trips them (`job.ex:71-99`). No
schema change.

Rewrite `build_persistent_opts/1` to return `{:ok, opts} | {:error,
reason}`, and update `load_persistent_jobs/2` to skip
`{:error, _}` rows with a `Logger.warning` rather than scheduling a
broken Worker.

```elixir
@spec load_persistent_jobs(String.t(), String.t()) :: {:ok, non_neg_integer()}
def load_persistent_jobs(tenant_id \\ "default", _project_dir) do
  case Job.for_tenant(tenant: tenant_id, authorize?: false) do
    {:ok, jobs} ->
      count =
        Enum.reduce(jobs, 0, fn job, acc ->
          case build_persistent_opts(job) do
            {:ok, opts} ->
              case schedule(tenant_id, opts) do
                {:ok, _, _} ->
                  acc + 1

                {:error, reason} ->
                  Logger.warning(
                    "[Cron] Failed to schedule job #{job.job_id}: #{inspect(reason)}"
                  )
                  acc
              end

            {:error, reason} ->
              Logger.warning(
                "[Cron] Skipping invalid persisted job #{job.job_id}: #{inspect(reason)}"
              )
              acc
          end
        end)

      {:ok, count}

    {:error, reason} ->
      Logger.warning("[Cron] Failed to load persistent jobs: #{inspect(reason)}")
      {:ok, 0}
  end
end

defp build_persistent_opts(%Job{} = job) do
  base = [
    id: job.job_id,
    task: job.task,
    schedule: hydrate_schedule(job.schedule_kind, job.schedule_value),
    mode: job.mode
  ]

  case build_mfa(job) do
    {:ok, nil} -> {:ok, base}
    {:ok, mfa} -> {:ok, Keyword.put(base, :mfa, mfa)}
    {:error, reason} -> {:error, reason}
  end
end

# Non-system_job rows don't need an MFA.
defp build_mfa(%Job{mode: mode}) when mode != :system_job, do: {:ok, nil}

# system_job rows REQUIRE an MFA. Missing it on reload = data corruption,
# don't schedule.
defp build_mfa(%Job{mfa_module: nil}), do: {:error, :missing_mfa_module}

defp build_mfa(%Job{mfa_module: mod_str, mfa_function: fun_str, mfa_args: args}) do
  with {:ok, module} <- resolve_module(mod_str),
       {:ok, function} <- resolve_atom(fun_str),
       {:ok, arg_list} <- mfa_args_to_list(args),
       :ok <- ensure_exported(module, function, length(arg_list)) do
    {:ok, {module, function, arg_list}}
  end
end

# Writers may persist either "JidoClaw.Cron.TestSupport" or
# "Elixir.JidoClaw.Cron.TestSupport". The existing Contract 1 test at
# persistent_disable_test.exs:53 uses the unprefixed form. Normalize.
defp resolve_module(str) when is_binary(str) do
  normalized =
    if String.starts_with?(str, "Elixir."), do: str, else: "Elixir." <> str

  try do
    {:ok, String.to_existing_atom(normalized)}
  rescue
    ArgumentError -> {:error, {:unknown_module, str}}
  end
end

defp resolve_module(other), do: {:error, {:invalid_module, other}}

defp resolve_atom(str) when is_binary(str) do
  try do
    {:ok, String.to_existing_atom(str)}
  rescue
    ArgumentError -> {:error, {:unknown_function, str}}
  end
end

defp resolve_atom(other), do: {:error, {:invalid_atom, other}}

# mfa_args is :map (jsonb) so it round-trips through Postgres, but MFA
# args are positional. Today every system job uses []; richer encoding
# (positional keys, %{"args" => [...]}) is deferred until a system job
# actually needs non-empty args. Empty map → empty list; non-empty
# returns an explicit error rather than calling apply/3 with
# arbitrarily-ordered Map.values.
defp mfa_args_to_list(args) when args == %{} or is_nil(args), do: {:ok, []}
defp mfa_args_to_list(args), do: {:error, {:unsupported_args_shape, args}}

defp ensure_exported(module, function, arity) do
  with {:module, ^module} <- Code.ensure_loaded(module),
       true <- function_exported?(module, function, arity) do
    :ok
  else
    _ -> {:error, {:not_exported, module, function, arity}}
  end
end
```

Notes:
- `String.to_existing_atom/1` (not `to_atom/1`) per project Elixir
  rules — unknown atoms rescue rather than leak.
- `resolve_atom/1` is binary-guarded so a stray `mfa_function: nil`
  (or anything non-binary) returns a clean `{:invalid_atom, value}`
  rather than escaping the `ArgumentError` rescue with a
  `FunctionClauseError`.
- `Code.ensure_loaded/1` runs before `function_exported?/3` so a
  valid persisted module isn't skipped just because its module atom
  exists but the code module hasn't been loaded yet. Cheap and
  idempotent. Tradeoff: `Code.ensure_loaded/1` operates on the atom,
  not the string — `String.to_existing_atom/1` must succeed first.
  A module whose atom hasn't been created in this VM run (very rare
  in releases; all modules are eagerly loaded) won't reload. This is
  the intended tradeoff against `String.to_atom/1`'s atom-leak risk.
- Secondary miss (`:agent_id`) is intentionally left alone — no Job
  column for it; Worker defaults to `"main"`.

### The test

Add Contract 3 to `persistent_disable_test.exs` mirroring the
existing two contracts' style (seed_tenant + ensure_tenant + on_exit
unschedule + 60s schedule + manual `Cron.Worker.trigger/2`). The two
existing contracts both **sidestep** the reload path — Contract 1
explicitly passes `mfa:` to `Scheduler.schedule/2`, Contract 2 only
verifies disabled rows are filtered out.

A reload-and-execute contract must positively prove:
1. After reload, the Worker's `:mfa` is the right tuple, AND
2. Triggering a tick under the reloaded Worker actually invokes the
   reloaded MFA (`last_result == {:error, :forced}` from
   `always_fail/0` is the signature).

Correction from the previous draft: `always_fail/0` **returns**
`{:error, :forced}` (not raises). The Worker's nil-MFA `MatchError` is
what raises; that path also ends in `{:error, _}` via rescue. So
asserting only `disabled_at != nil` would pass even with broken MFA.
The fix is the dual assertion above.

Shape:

```elixir
describe "Contract 3: reload restores MFA from Postgres" do
  test "system_job reloaded from Postgres ticks under its persisted MFA" do
    tenant = seed_tenant("reload_mfa")
    {:ok, _} = JidoClaw.Tenant.Manager.ensure_tenant(tenant)

    {:ok, _job} =
      Job.upsert(
        %{
          job_id: "reload-mfa-test",
          schedule_kind: :every,
          schedule_value: "60000",
          mode: :system_job,
          mfa_module: "JidoClaw.Cron.TestSupport",
          mfa_function: "always_fail",
          mfa_args: %{}
        },
        tenant: tenant,
        actor: actor_for(tenant)
      )

    # The reload path is the ONLY way the Worker gets MFA here.
    # No explicit mfa: in Scheduler.schedule/2.
    assert {:ok, 1} = Scheduler.load_persistent_jobs(tenant, ".")

    on_exit(fn -> _ = Scheduler.unschedule(tenant, "reload-mfa-test") end)

    # (1) Worker state carries the reloaded MFA.
    state = Cron.Worker.get_state(tenant, "reload-mfa-test")
    assert state.mfa == {JidoClaw.Cron.TestSupport, :always_fail, []}

    # (2) Triggering a tick actually invokes always_fail/0 (not a
    # rescued MatchError from nil MFA). Both shapes produce
    # {:error, _} so we check the exact reason.
    Cron.Worker.trigger(tenant, "reload-mfa-test")

    eventually(fn ->
      state = Cron.Worker.get_state(tenant, "reload-mfa-test")
      state.last_result == {:error, :forced}
    end)
  end
end
```

`eventually/1` doesn't exist in this test file today — copy it from
`auth_controller_test.exs:127-143` (it's a 17-line helper) or pull
into a shared test helper if you'd rather not duplicate. Mirroring
the in-file approach is fine.

Once Contract 3 passes, update the moduledoc (lines 13–17) — remove
the "These contracts are split because…" paragraph since the bug it
sidesteps is fixed.

---

## Verification

Per-slice:
- **Slice A:** `mix test test/jido_claw/conversations/` — no behavior
  change, expect existing-green. If a request_correlation test exists,
  run it specifically.
- **Slice B:** `mix test test/jido_claw/web/plugs/api_key_auth_test.exs`
  (new file). Manual smoke: `mix phx.server`; curl an
  ApiKeyAuth-protected route with a valid key, then without; query via
  `mcp__tidewave__execute_sql_query`:
  `SELECT actor_kind, actor_id, target_id, payload FROM audit_events
  WHERE event_kind = 'auth_event' ORDER BY inserted_at DESC LIMIT 5;`
  Confirm two new rows (success + missing-key failure).
- **Slice C:** `mix test test/jido_claw/cron/persistent_disable_test.exs`
  — all three contracts green. Contract 3 specifically validates both
  the MFA tuple in worker state AND that triggering invokes the
  reloaded MFA (not a rescued MatchError).

End-to-end:
- `mix format --check-formatted`
- `mix compile --warnings-as-errors`
- `mix test` (full suite)
- `mix ash.codegen --check` — no migrations expected (no schema changes)

---

## Critical files modified

- `lib/jido_claw/conversations/resources/request_correlation.ex`
  (`sweep_expired/0` + policy-block comment) — Slice A
- `lib/jido_claw/web/plugs/api_key_auth.ex`
  (alias, success/failure branches, new `emit_auth_event/3`) — Slice B
- `lib/jido_claw/platform/cron/scheduler.ex`
  (`load_persistent_jobs/2`, `build_persistent_opts/1`, new
  `build_mfa/1`, `resolve_module/1`, `resolve_atom/1`,
  `mfa_args_to_list/1`, `ensure_exported/3`) — Slice C
- `test/jido_claw/web/plugs/api_key_auth_test.exs`
  (new file, net-new directory) — Slice B
- `test/jido_claw/cron/persistent_disable_test.exs`
  (Contract 3; moduledoc cleanup) — Slice C

---

## Existing utilities to reuse

- `JidoClaw.Audit.AsyncWriter.cast/1` —
  `lib/jido_claw/audit/async_writer.ex:24`
- `AuthController.emit_auth_event/3` (pattern to mirror) —
  `lib/jido_claw/web/controllers/auth_controller.ex:42-52`
- `eventually/1` poll loop (copy) —
  `test/jido_claw/web/controllers/auth_controller_test.exs:127-143`
- `JidoClaw.TenantCase`, `seed_tenant/1`, `actor_for/1` —
  `test/support/jido_claw/tenant_case.ex`
- `JidoClaw.Tenant.Manager.ensure_tenant/1` (used by existing cron
  contracts at `persistent_disable_test.exs:44, :81`)
- `JidoClaw.Cron.TestSupport.always_fail/0` returning `{:error, :forced}`
  — `test/support/jido_claw/cron_test_support.ex:13`
- `JidoClaw.Cron.Worker.get_state/2`, `Cron.Worker.trigger/2` —
  `worker.ex:35, :45`
- `JidoClaw.Cron.Job.upsert/2` (accepts `:mfa_module`, `:mfa_function`,
  `:mfa_args`) — `lib/jido_claw/cron/resources/job.ex:71-99`
- `Ash.Resource.get_metadata/2` for reading the AshAuthentication
  `:plaintext_api_key` metadata from a freshly-created ApiKey row

---

## Slicing for execution

CLAUDE.md memory says no commits without an explicit request — the
slice list doubles as commit-boundary suggestions if/when asked.
Slices are independent and can land in any order:

1. **Slice A** — sweeper bypass (smallest, one function + comment).
2. **Slice C** — MFA reload fix + Contract 3 (self-contained, all in
   cron land).
3. **Slice B** — ApiKeyAuth audit + test (touches plug + new test
   directory).

---

## Known remaining gaps (still deferred to v0.7+)

- RequestCorrelation permissive policy — Slice A only makes the
  sweeper's bypass explicit; the underlying read/write policy is
  still `always()` for all other internal callers. Closing requires a
  coherent agent-identity model.
- `Tenants.Tenant` `:archive`/`:suspend`/`:resume` permissive — needs
  an admin-role attribute on User + Actor first.
- AshAdmin and Phoenix LiveDashboard routes gated only by
  `RequireAuth` — same admin-role blocker.
- Reasoning.Outcome, Embeddings, Forge.* untenanted — out of scope.
- `Scheduler.build_persistent_opts/1` also drops `:agent_id` — minor;
  no Job column, Worker defaults to `"main"`.
- `mfa_args` jsonb encoding for non-empty arg lists — explicit
  `{:error, {:unsupported_args_shape, args}}` after Slice C. Reopen
  when a system job needs persisting with real args (positional keys
  or `%{"args" => [...]}` are the two candidate encodings).
