# AR-8b-2 F2 Phase 2 — Code-review follow-ups (recovered runner/sandbox fail-closed + egress gate)

## Context

The AR-8b-2 F2 Phase 2 exec-tier activation shipped, and a code review (plus a plan review) surfaced
two issues. Both were verified against the current tree and are **valid**. This plan resolves both.
**Done = `mix precommit` green.**

- **[P2] `recovered_spec.ex` runner does not fail closed — and a naive fix is still unsafe.**
  `normalize_runner/1` (`lib/jido_claw/forge/recovered_spec.ex:105-108`) returns an unknown runner
  binary *unchanged* (`Map.get(@runner_atoms, value, value)`) and is applied inline at `:66` (outside
  the `with`), so it can never produce `{:error, _}`. A recovered `%{"runner" => "bad"}` normalizes to
  `%{runner: "bad"}`, `normalize/1` returns `{:ok, …}`, and the spec flows to `Manager.start_session/2`
  → `Harness.resolve_runner/1` (`harness.ex:1330-1336`), whose clauses match only atoms/modules — a
  binary matches none → a late `FunctionClauseError`. **A blind `String.to_existing_atom/1` fallback is
  not enough:** `resolve_runner/1` ends in `resolve_runner(module) when is_atom(module)` (and
  `resolve_client/1` likewise, `harness.ex:1338-1343`), so an *existing but wrong-kind* atom string like
  `"ok"` or `"Elixir.Enum"` normalizes to `:ok`/`Enum` and **still** crashes later at
  `runner_module.init/2` / `:ok.create/1`. The fallback must **validate the atom is a real runner (resp.
  sandbox) module**, not merely an existing atom. The **sandbox path has the identical twin hole**
  (`resolve_client(:ok) → :ok → :ok.create/1`), so the fix validates **both** kinds. `wake/2`
  (`forge.ex:59-70`) already maps any `{:error, _}` from `normalize` to `{:unrecoverable_spec, reason}`,
  so the fix is contained entirely in `recovered_spec.ex`.

- **[P3] egress integration test can falsely pass — two ways.** (1) The behavioral probe in
  `docker_exec_tier_integration_test.exs:62-69` prints `BLOCKED` for curl-missing / timeout-missing /
  any failure alike, and asserts only `refute out =~ "REACHED"`, so missing probe tooling or empty
  output passes silently. (2) Even a present-curl probe of `https://1.1.1.1 -sf` conflates **TLS/CA**
  and **HTTP-status** failures with network denial — especially relevant because the exec tier runs
  `isolate_global_config: true` (the CA-cert mount is deliberately skipped, 1.6), so an HTTPS probe
  could false-`BLOCKED` even with an open network. Since this test is the **true production-isolation
  gate**, a false pass is exactly the failure mode that must not exist. (The structural proof above it —
  `ls /sys/class/net` shows `lo`, not `eth0` — is solid and stays.)

---

## Part 1 — Fail closed, validating the recovered atom's *kind* (P2)

**Edit** `lib/jido_claw/forge/recovered_spec.ex`.

Both runner and sandbox must: whitelist known wire strings → fall back to an *existing module of the
right kind* → otherwise fail closed. Two adjacent fail-closed `normalize_*` families (and two adjacent
validators) would risk the ExSlop clone gate (min_mass 30, cf. the documented clone-seam friction), so
**unify the shared shape** and pass a **per-kind validator** into the fallback (the plan reviewer's
suggested shape) rather than sharing a blind existing-atom fallback.

1. **Validated existing-atom fallback** (replaces `safe_existing_atom/1`) — accepts the atom only if it
   passes the per-kind validator:
   ```elixir
   defp safe_existing_atom(value, tag, valid?) do
     atom = String.to_existing_atom(value)
     if valid?.(atom), do: {:ok, atom}, else: {:error, {tag, value}}
   rescue
     ArgumentError -> {:error, {tag, value}}
   end
   ```

2. **One parametrized `normalize_atom/4`** (whitelist → validated fallback → fail closed) with thin,
   clone-safe one-line named callers; the `is_atom`/`nil` clauses pass a trusted live-launch spec
   through unchanged (only the binary *recovered* path is validated):
   ```elixir
   defp normalize_atom(nil, _map, _tag, _valid?), do: {:ok, nil}
   defp normalize_atom(value, _map, _tag, _valid?) when is_atom(value), do: {:ok, value}

   defp normalize_atom(value, map, tag, valid?) when is_binary(value) do
     case Map.get(map, value) do
       nil -> safe_existing_atom(value, tag, valid?)
       atom -> {:ok, atom}
     end
   end

   defp normalize_atom(other, _map, tag, _valid?), do: {:error, {tag, other}}

   defp normalize_sandbox(value),
     do: normalize_atom(value, @sandbox_atoms, :unrecognized_sandbox, &sandbox_module?/1)

   defp normalize_runner(value),
     do: normalize_atom(value, @runner_atoms, :unrecognized_runner, &runner_module?/1)
   ```

3. **Per-kind module validators that check the behaviour's *full non-optional callback set*** (not just
   a 1–2 callback subset — a coincidental module exporting every required callback at the exact arity is
   effectively impossible, and a real backend exports them all). The "required" set is precisely
   `behaviour callbacks − @optional_callbacks`, so the lists are principled, not arbitrary. They share
   one export-checking helper (so the two predicates stay one-liners — no clone), use the subsystem's
   established `function_exported?/3` idiom (`sandbox.ex:30`), and `Code.ensure_loaded?/1` first to avoid
   a false-negative on a not-yet-loaded backend during recovery:
   ```elixir
   defp module_with_exports?(mod, exports) do
     Code.ensure_loaded?(mod) and Enum.all?(exports, fn {f, a} -> function_exported?(mod, f, a) end)
   end

   # Runner required callbacks (runner.ex; @optional_callbacks :33 excludes
   # handle_output/3, terminate/2, serialize_state/1, restore_state/2). Harness
   # calls these three UNGUARDED (:346 init, :472 run_iteration, :541 apply_input).
   defp runner_module?(mod),
     do: module_with_exports?(mod, [{:init, 2}, {:run_iteration, 3}, {:apply_input, 3}])

   # Sandbox.Behaviour required callbacks (behaviour.ex; @optional_callbacks :28
   # excludes impl_module/0, run/4). Docker + StubSandbox export all of these.
   defp sandbox_module?(mod),
     do:
       module_with_exports?(mod, [
         {:create, 1},
         {:exec, 3},
         {:exec_argv, 4},
         {:spawn, 4},
         {:write_file, 3},
         {:read_file, 2},
         {:inject_env, 2},
         {:destroy, 2}
       ])
   ```

4. **Thread runner through the `with`** in `normalize/1` (so a runner error short-circuits to
   `{:error, _}` exactly like sandbox), dropping the inline `normalize_runner` application:
   ```elixir
   with {:ok, sandbox} <- normalize_sandbox(get(spec, :sandbox)),
        {:ok, sandbox_spec} <- normalize_sandbox_spec(get(spec, :sandbox_spec)),
        {:ok, runner} <- normalize_runner(get(spec, :runner)) do
     normalized =
       spec
       |> drop_keys(["sandbox", "sandbox_spec", "runner", :sandbox, :sandbox_spec, :runner])
       |> put_present(:sandbox, sandbox)
       |> put_present(:sandbox_spec, sandbox_spec)
       |> put_present(:runner, runner)

     {:ok, normalized}
   end
   ```

5. **Reconcile the docs** (no now-false claims): the moduledoc comment (`:26-29`) and the `@doc` for
   `normalize/1` (`:47-56`) must state that **both** `sandbox` and `runner` fall back to an existing
   atom **that is validated as a real backend/runner module**, failing closed otherwise (an existing
   but wrong-kind atom is rejected, not passed through).

**Why this is safe / no caller ripple:** `RecoveredSpec.normalize` has a single caller (`forge.ex:59`),
which already handles `{:error, _}`. The whitelist covers every known runner/sandbox wire value; a
persisted *module* atom recovers only when it is genuinely the right kind (validator), so Docker /
`StubSandbox` / `Runners.Shell` module-atom strings still recover while `:ok`/`Enum` fail closed. No
existing test feeds a wrong-kind atom expecting pass-through (the only recovered strings in tests are
whitelisted `"shell"`/`"claude_code"`/`"docker_sandbox"`; the existing fail-closed sandbox test uses a
non-existent atom string, still rejected via the rescue branch).

## Part 2 — Make the egress probe conclusive *and* confounder-free (P3)

**Edit** `test/jido_claw/forge/sandbox/docker_exec_tier_integration_test.exs`
(`:docker_sandbox`-tagged; keep the structural proof at `:56-59` unchanged; update its `curl/timeout`
comments to `curl`).

Replace the behavioral probe + lone `refute` with a probe that (a) requires only `curl` (using curl's
own connect/transfer timeouts, no external `timeout`), (b) uses **`http://` not `https://`** and drops
**`-f`** so neither TLS/CA nor HTTP status can masquerade as a network denial, and (c) is **tri-state**
so a missing tool is reported inconclusive rather than as a pass:

```elixir
# Behavioral proof: a raw outbound TCP/HTTP connection cannot be established.
# http:// (not https) + no -f so TLS/CA or HTTP-status failures don't masquerade
# as a network denial (the exec tier skips the CA-cert mount, 1.6). curl's own
# timeouts drop the external `timeout` dep. Tri-state: a missing probe tool fails
# loudly (inconclusive ≠ pass) — only a genuine BLOCKED passes the gate.
probe =
  "if command -v curl >/dev/null 2>&1; then " <>
    "curl -s --connect-timeout 5 --max-time 5 http://1.1.1.1 -o /dev/null " <>
    "&& echo REACHED || echo BLOCKED; " <>
    "else echo PROBE_UNAVAILABLE; fi"

{out, _code} = Docker.exec(client, probe, timeout: 15_000)

cond do
  out =~ "REACHED" ->
    flunk("egress REACHED the internet — `--network none` is NOT enforced (fail-OPEN)")

  out =~ "PROBE_UNAVAILABLE" ->
    flunk("egress probe tool (curl) missing in the sandbox image — the check is inconclusive; " <>
            "cannot trust the isolation gate")

  out =~ "BLOCKED" ->
    :ok

  true ->
    flunk("unexpected egress probe output: #{inspect(out)}")
end
```

`=~` substring matching (REACHED checked first) is robust to incidental stderr/whitespace; `-s`
suppresses curl's own error text. Single-line `;`-separated shell is the proven exec style here (the
existing `echo … > out.txt` redirection test confirms `sbx exec` runs through a shell). `flunk/1` is
auto-imported via `use ExUnit.Case`.

## Part 3 — Tests

**`test/jido_claw/forge/recovered_spec_test.exs`** — extend the existing describes (the committed P2
regressions; existing happy-path/fail-closed cases stay as regression guards):

- Under `"normalize/1 — fail closed"`:
  ```elixir
  test "an existing non-runner atom string is rejected (validates a real runner module)" do
    # `Enum` is a loaded atom but not a runner — a blind existing-atom fallback would
    # admit it and crash later at runner_module.init/2; the validator fails closed.
    assert {:error, {:unrecognized_runner, _}} =
             RecoveredSpec.normalize(%{"runner" => "Elixir.Enum"})
  end

  test "an unknown (never-created) runner atom string is rejected" do
    assert {:error, {:unrecognized_runner, _}} =
             RecoveredSpec.normalize(%{"runner" => "f2_nonexistent_runner_qwxz"})
  end

  test "an existing non-sandbox atom string is rejected (validates a real sandbox module)" do
    assert {:error, {:unrecognized_sandbox, _}} =
             RecoveredSpec.normalize(%{"sandbox" => "Elixir.Enum"})
  end
  ```
- A new describe `"normalize/1 — persisted module-atom recovery"` proving the validator does **not**
  over-reject real backends/runners (the positive side of the validator):
  ```elixir
  test "a persisted runner module atom recovers" do
    assert {:ok, n} = RecoveredSpec.normalize(%{"runner" => "Elixir.JidoClaw.Forge.Runners.Shell"})
    assert n.runner == JidoClaw.Forge.Runners.Shell
  end

  test "a persisted sandbox backend module atom recovers" do
    assert {:ok, n} = RecoveredSpec.normalize(%{"sandbox" => "Elixir.JidoClaw.Forge.Sandbox.Docker"})
    assert n.sandbox == JidoClaw.Forge.Sandbox.Docker
  end
  ```

**Part 2's edit is itself the P3 regression** (the gate now fails on a false pass). It is
`:docker_sandbox`-tagged, so precommit **compiles** it but only **executes** it under
`mix test --include docker_sandbox` with real Docker/`sbx` — same as before.

---

## Verification

1. **`mix precommit`** — the definition of done. Runs `jidoclaw.compile_check`,
   `jidoclaw.system_prompt.check`, `deps.unlock --unused`, `format --check-formatted`,
   `reach.check --arch --smells --strict`, `credo --strict`, `dialyzer --format short`, then full
   `test`. Points of attention:
   - **reach/clone must stay zero** — Part 1 unifies the two normalizers into `normalize_atom/4` and
     the two validators into `module_with_exports?/2`, so neither the families nor the predicates
     duplicate.
   - **dialyzer** — `normalize_atom/4` returns `{:ok, atom | nil} | {:error, {atom, term}}`; the
     validators are `(atom -> boolean)` captures; `@spec normalize/1 :: {:ok, map} | {:error, term}`
     stays accurate. No new error channel escapes a transaction.
   - **test** — the new `recovered_spec_test` cases prove P2 fixed (wrong-kind atoms rejected; real
     module atoms recover); existing recovered-spec/wake/harness suites guard regressions.
   - Never pipe precommit through `tail`; build strings via `IO.iodata_to_binary` if needed.
2. **Targeted while iterating:**
   `mix test test/jido_claw/forge/recovered_spec_test.exs test/jido_claw/forge/`.
3. **Manual production-isolation gate (P3 behavioral validation — cannot run in precommit):**
   `mix test --include docker_sandbox test/jido_claw/forge/sandbox/docker_exec_tier_integration_test.exs`
   where Docker/`sbx` is available. Confirm the egress test reports a genuine `BLOCKED`; if curl is
   absent it now **fails loudly** with `PROBE_UNAVAILABLE` (inconclusive ≠ pass).

---

## Critical files

| Concern | File |
| --- | --- |
| P2 fail-closed + kind validation | `lib/jido_claw/forge/recovered_spec.ex` (`normalize/1` `with`, `normalize_atom/4`, `safe_existing_atom/3`, `module_with_exports?/2`, `runner_module?/1`, `sandbox_module?/1`, doc reconcile) |
| P2 regression tests | `test/jido_claw/forge/recovered_spec_test.exs` (wrong-kind rejected; module-atom recovery) |
| P3 egress gate | `test/jido_claw/forge/sandbox/docker_exec_tier_integration_test.exs` (http + no `-f` + curl timeouts, tri-state) |
| Downstream (read-only, unchanged) | `lib/jido_claw/forge.ex:59-70` (`wake/2` maps `{:error,_}`→`:unrecoverable_spec`); `lib/jido_claw/forge/harness.ex:1330-1343` (`resolve_runner/1`/`resolve_client/1` blind catch-alls — the very reason kind-validation is required) |
