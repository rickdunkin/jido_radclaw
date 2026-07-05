# Audit §4 batch PR — duplication single-sourcing + wasted-work no-ops + hygiene/help

## Context

`docs/reports/codebase-audit-2026-07-04.md` §4 lists small "easy improvement" items. §1 bugs
are already fixed (batch bugfix PR 8699af6a); this plan is the next unit of work: one
migration-free batch PR covering the §4 items that are verified-easy, thematically unified
(remove duplication and wasted work), and safe under the repo's zero-finding gates. Every
item below was re-verified against current source by exploration agents + hand spot-checks;
line numbers were verified at `main` @ 6ea82938 and survived a user re-review at 9f97ad54 —
treat them as hints and match on content at implementation time.

**In scope (18 items):** all §4 Duplication items except the `~w(talk sketch code system)`
pair, all Wasted-work/no-ops, the test-hygiene item, and the CLI-help item.

**Explicitly excluded (with reasons):**
- `router.ex:37`/`catalog_validator.ex:60` `~w(talk sketch code system)` — both files are
  deliberate 1:1 ports of *separate* Alp River upstream files (`route.py`, `check_catalog.py`);
  de-duping couples the two ports. The audit itself noted the port-fidelity caveat. Skip.
- `eventually`-helper (19 test files, not 15) + `kinds/2` (13 test files) dedups — a 30+ file
  test-only churn; belongs in its own follow-up PR (census captured below).
- JIDO.md drift guard — belongs with the §3 doc-sweep PR.
- Full help-box realignment — the box is *pre-existingly* ragged (interior widths 50-53 by
  line class); realigning every line is a separate cosmetic PR (18 is split, see Phase F).

## Changes, in implementation order

Run `mix jidoclaw.compile_check && mix format` after each phase (repo-native strict compile —
raw `compile --warnings-as-errors` bypasses the documented allowlist mechanism); targeted tests as noted.

### Phase A — trivial local simplifications (no signature changes)

1. **`lib/jido_claw/export/canonical.ex:43`** — delete `|> Enum.sort_by(fn {k, _} -> k end)`
   (fed straight into `Map.new/1`, order discarded; `sorted_encode!/1:67` re-sorts).
   **New pinning test** (in the existing canonical/export test file if one exists, else a minimal
   new one): `encode!(%{a: 1}) == encode!(%{"a" => 1})` plus identical bytes across input key
   orderings — the encoder may feed fingerprints, so pin the atom/string-key equivalence and
   deterministic-output contract the removed sort could be mistaken for providing.
2. **`lib/jido_claw/embeddings/rate_pacer.ex:365-369`** — replace the `if source == :configured`
   whose branches are semantically identical with plain `{window, source}`.
3. **`lib/jido_claw/reasoning/auto_select.ex:173`** — `alternatives = ranked` (identity `Enum.map`).
4. **`lib/jido_claw/reasoning/telemetry.ex:288-289`** — `metadata: caller_metadata`
   (drop the no-op `Map.merge(%{}, …)` and the now-vacuous comment).
5. **`lib/jido_claw/forge/manager.ex:221,225`** — in `try_start_session/4`'s `{:ok, pid}` branch,
   bind `scope = event_scope(spec)` once and reuse (pure private fn; its own def at :276-290 untouched).
6. **`lib/jido_claw/security/redaction/memory.ex:22-23`** — remove `auth_token` and `credentials`
   from `@sensitive_keys`; both are subsumed by `token`/`credential` under the module's own
   `String.contains?` matcher (:65-68). **New test** (no memory-redaction test exists today):
   `test/jido_claw/security/redaction/memory_test.exs` asserting keys `auth_token`,
   `credentials`, `token` all still redact — pins the subsumption so a future removal of the
   short forms can't silently un-redact the long ones.

### Phase B — dead-code + param cleanups (arity/with-chain changes → dialyzer-sensitive)

7. **`lib/jido_claw/shell/session_manager.ex`** — delete the discarded-result gate
   `{:ok, _secrets} <- resolve_server_secrets(entry)` (:781) from `build_ssh_session/4`;
   `ServerRegistry.build_ssh_config/3` re-resolves internally (:215) and returns the same
   `{:error, {:missing_env, _}}` the existing `else` (:803) handles. Then delete the now-dead
   `resolve_server_secrets/1` (:824-829) — once uncalled it is exactly reach's
   forwarding-delegate smell shape.
8. **`lib/jido_claw/forge/sandbox/docker.ex`** — remove the dead `sandbox_id` thread:
   `resolve_agent_token(_sandbox_id, config)` (:575) → arity-1; `onecli_env(sandbox_id)` (:539)
   → arity-0; `inject_onecli_env(client, sandbox_id, sandbox_name)` (:102) → drop the middle
   param; `maybe_inject_onecli_env/4` (:91, public, used by `docker_args_test.exs`) keeps
   arity 4 with the param underscored. All call-site updates are inside docker.ex.

### Phase C — same-file extractions / promotions

9. **`lib/jido_claw/forge/harness.ex`** — extract the byte-identical ~17-line provision seam
   (250-266 / 858-874 / 1124-1140) into one same-module helper:
   `defp create_default_sandbox(state) :: {:ok, new_state, sandbox_id} | {:error, reason}`.
   **Boundary rule:** the helper ends right after `new_state` is built — it must NOT emit the
   `"sandbox.provisioned"` log (callers keep their divergent tails; `recover_provision/1`
   deliberately does not log it). `handle_info(:provision, …)` keeps log+record+dispatch+
   `{:stop, …}` error tail; `recover_provision/1` keeps record-only + `{:error, {:provision_failed, _}}`;
   `provision_sandbox_sync/1` keeps log+record + `{:error, {:sandbox_creation_failed, _}}`.
10. **`lib/jido_claw/vfs/resolver.ex` + `lib/jido_claw/vfs/sandbox.ex`** — promote
    `Resolver.under_path?/2` (:472-477) to public with `@spec` and a doc following the existing
    `realpath/1` precedent ("Exposed for `JidoClaw.VFS.Sandbox`", :479-488). In sandbox.ex,
    call it at :87 (sole call site; Resolver already aliased) and delete `under?/2` + its
    "Mirror of Resolver.under_path?/2" comment (:200-207). Byte-identical semantics — pure code motion.
11. **`lib/jido_claw/memory/scope.ex` + `lib/jido_claw/cli/commands.ex`** — add the total
    variant at the canonical source, then delete BOTH commands.ex locals:
    - `Memory.Scope.primary_fk_or_nil/1` (`@doc` + `@spec … :: Ecto.UUID.t() | nil`): the four
      `primary_fk/1` clause heads plus a `_ -> nil` catch-all, as **explicit clauses**. A
      guard-on-`scope_kind` + delegate would NOT be nil-total — `primary_fk/1` also
      pattern-matches the FK field, so `%{scope_kind: :session}` without `session_id` would
      raise instead of returning nil.
    - commands.ex: delete `primary_fk/1` (:993-996) AND `block_primary_fk/1` (:1494-1498);
      `:1491` becomes `MemoryScope.primary_fk(scope) == MemoryScope.primary_fk_or_nil(block)`;
      `:1568` calls `MemoryScope.primary_fk/1` (alias exists :22, already used :330).
    No local defp remains, so there is no reach trivial-forwarder exposure at all.
    **New test cases** in `test/jido_claw/memory/scope_test.exs`: the four kinds return the
    matching FK; unknown kind → nil; known kind with missing FK field → nil.

### Phase D — new shared modules + cross-module migrations

12. **NEW `lib/jido_claw/tools/projection.ex`** (`JidoClaw.Tools.Projection`, naming matches
    `Tools.OutputRef`/`Tools.MCPScope`) — public `stringify_nilable/1` (nil→nil, else `to_string/1`);
    moduledoc carries the shared rationale (bare `to_string(nil)` emits `"nil"` at the MCP
    boundary). Migrate call sites `inspect_agent.ex:114,126`, `inspect_workflow.ex:92`,
    `workflow_events.ex:91`; delete the three local copies + their "Mirror" comment chains
    (inspect_agent :134-137, inspect_workflow :112-115, workflow_events :100-103).
13. **NEW `lib/jido_claw/forge/runners/file_sync.ex`** (`JidoClaw.Forge.Runners.FileSync`) —
    `sync_file(client, source, dest, auth_file, label)`; body = current claude_code impl with
    `@auth_file`→param and `"[ClaudeCode]"`→`"[#{label}]"`. Give it an explicit
    `@spec sync_file(term(), Path.t(), String.t(), String.t(), String.t()) :: :ok` and normalize
    both branches to return `:ok` (callers ignore the return today; a shared public helper
    deserves a stable shape). Home rationale: `Forge.Sandbox` is a
    pure transport facade (`@moduledoc false`, everything forwards to `impl()`); host-side
    `File.read` + skip-policy + chmod-posture belongs with the runners. Migrate 3 call sites
    (claude_code.ex :172, :208; codex.ex :169), delete both local `sync_file/3` **and both
    `# ex_dna:disable-for-next-line` pragmas** (:182/:311) that were suppressing this exact dup.
14. **`lib/jido_claw/platform/tenant.ex` + `lib/jido_claw/tenants/resources/tenant.ex`** —
    make `JidoClaw.Tenant.generate_id/0` public (`@doc false` + `@spec`); the Ash resource's
    DSL default (:108) becomes `default(&JidoClaw.Tenant.generate_id/0)` and its own copy
    (:150-154) is deleted. Direction checked: `.reach.exs` arch layers constrain neither module;
    the resource already documents itself as "Mirrors the legacy `JidoClaw.Tenant` struct".
    No other callers repo-wide.
15. **`lib/jido_claw/shell/util.ex` + `profile_manager.ex` + `server_registry.ex`** — add to
    `JidoClaw.Shell.Util` (needs `require Logger`): `config_path/1` (byte-identical copies at
    profile_manager :502 / server_registry :315 deleted; call sites :252/:266 migrated) and
    `coerce_env_entry(acc, context, key, value)` with unified lowercase log wording
    (`"#{context}: non-string key (got: hint) — skipping entry"` / `"#{context}: non-string
    value for KEY (got: hint) — skipping entry"`). Callers pass context labels
    `"[ProfileManager] profile '#{name}'"` / `"[ServerRegistry] server '#{name}'"`; delete
    `coerce_entry/4` (:551-573) and `coerce_env_entry/4` (:466-488).
    **Required test edits** (wording is pinned): `test/jido_claw/shell/profile_manager_test.exs:384`
    (`"Non-string key"` → new wording) and `:426` (`"Non-string value for staging.DATABASE_PASSWORD"`
    → assert `"profile 'staging'"` + `"non-string value for DATABASE_PASSWORD"`).
    `server_registry_test.exs:225` asserts the result map only — no edit.

### Phase E — the one behavior-invariant refactor

16. **`lib/jido_claw/agent_view.ex`** — cold snapshots run the *unlimited*
    `ConversationsMessage.for_session_primary` read twice (:348-349 → `cold_messages` :490 and
    `total_message_count` cold clause :528). Replace the two calls at :348-349 with one
    dispatcher so warm/mixed paths are byte-identical and only the cold path changes:
    ```elixir
    {messages, message_count} = messages_and_count(base, worker_info, opts)

    defp messages_and_count(base, {:ok, _} = wi, opts),
      do: {fetch_messages(base, wi, opts), total_message_count(wi, base)}

    defp messages_and_count(base, :no_worker, opts) do
      rows = cold_messages(base)
      {cap_messages(rows, Keyword.get(opts, :messages_limit, @default_messages_limit)), length(rows)}
    end
    ```
    **Invariant:** count comes from the PRE-cap filtered rows (`cold_messages` already filters
    to chat roles), never `length` of the capped list. Delete the now-unreachable cold clauses
    `raw_messages(base, :no_worker)` (:483) and `total_message_count(:no_worker, …)` (:519-536);
    keep the warm clause (:516) and helpers untouched.
    **New test** in `test/jido_claw/agent_view_test.exs` (cold path currently uncovered beyond
    the empty case; existing cap tests start a worker): seed 60 user messages via
    `ConversationsMessage.append(%{session_id: session.id, role: :user, content: "m#{i}"}, tenant: tenant_id, actor: actor)`
    — the `tenant:`/`actor:` opts are load-bearing (omitting them turns this into a
    policy/multitenancy failure, not a cold-count test) — then snapshot with no worker and
    assert `length(view.messages) == 50` and `view.message_count == 60`.

### Phase F — test hygiene + CLI help

17. **`test/jido_claw/mcp/stdio_env_scrub_test.exs:36-58`** — replace the
    `case System.find_executable("printenv")` (whose `nil` branch is a bare `assert true`) with
    a direct spawn of POSIX-guaranteed `/bin/sh` (test is already `@tag :unix`):
    `Port.open({:spawn_executable, "/bin/sh"}, [:binary, :exit_status, {:args, ["-c", "env"]}, {:env, Env.scrubbed_port_env([])}])`.
    `env` emits `KEY=VALUE`, so the existing assertions (`refute output =~ "#{@sentinel}=leakme"`,
    `assert output =~ "PATH="`) hold unchanged; delete the nil branch. Extend `collect_port_output/2` to also return the
    exit status and `assert status == 0` — a sharper failure signal than the `PATH=` presence
    check alone.
18. **`lib/jido_claw/cli/branding.ex` `help_text/0`** — add the three routed-but-undocumented
    commands, one entry each, padded to match their section's existing command-line width
    (the box is pre-existingly ragged; match neighbors, don't realign):
    - `/gates` → **Platform** section (approve/reject/abandon pending tool approvals; routed
      commands.ex :611-623)
    - `/profile` → **Servers** section (show/list/switch shell profiles; :787-796)
    - `/workspace` → **Memory** section (embedding/consolidation policies; :798-811)
    `/exit` and `/config` stay omitted (pure aliases of listed `/quit`/`/setup`).
    **New test** in `test/jido_claw/cli/branding_test.exs` (no help_text test exists): assert
    `help_text()` contains `"/gates"`, `"/profile"`, `"/workspace"`, and that each new line's
    ANSI-stripped visible width equals a sampled existing sibling command line (light drift
    guard; the strict all-lines-equal-width invariant is impossible until the follow-up realignment).

## New tests summary

| Test | Guards |
|---|---|
| `security/redaction/memory_test.exs` (new file) | subsumption: `auth_token`/`credentials`/`token` keys all redact |
| `memory/scope_test.exs` additions | `primary_fk_or_nil/1` nil-totality: unknown kind → nil, missing FK field → nil |
| canonical/export encode test | atom/string key equivalence + deterministic bytes (fingerprint-safe) |
| `agent_view_test.exs` cold cap/count test | count = pre-cap total, messages = capped tail |
| `mcp/stdio_env_scrub_test.exs` rewrite | real subprocess assertion + exit status 0 on every unix host (was silent pass) |
| `cli/branding_test.exs` help entries | three commands present + width parity with siblings |

Everything else rides the existing suite — all remaining items are behavior-preserving
(existing coverage: harness provision tests, runner sync tests, resolver/sandbox path-safety,
`/memory blocks` scope tests, session-manager `missing_env` tests, `docker_args_test`).

## Files touched (27 lib + 7 test — small hunks each; broad but shallow)

lib: `export/canonical.ex`, `embeddings/rate_pacer.ex`, `reasoning/auto_select.ex`,
`reasoning/telemetry.ex`, `forge/manager.ex`, `security/redaction/memory.ex`,
`shell/session_manager.ex`, `forge/sandbox/docker.ex`, `forge/harness.ex`, `vfs/resolver.ex`,
`vfs/sandbox.ex`, `memory/scope.ex`, `cli/commands.ex`, `tools/projection.ex` (new),
`tools/inspect_agent.ex`, `tools/inspect_workflow.ex`, `tools/workflow_events.ex`,
`forge/runners/file_sync.ex` (new), `forge/runners/claude_code.ex`, `forge/runners/codex.ex`,
`platform/tenant.ex`, `tenants/resources/tenant.ex`, `shell/util.ex`,
`shell/profile_manager.ex`, `shell/server_registry.ex`, `cli/branding.ex`, `agent_view.ex`

test: `security/redaction/memory_test.exs` (new), `memory/scope_test.exs`,
canonical/export encode test (new file if none exists), `agent_view_test.exs`,
`shell/profile_manager_test.exs` (2 assertion edits), `mcp/stdio_env_scrub_test.exs`,
`cli/branding_test.exs`

## Verification

1. Per-phase: `mix jidoclaw.compile_check && mix format` + the phase's targeted test files.
2. After Phase C: `mix reach.check --smells --strict` (extraction hygiene — item 11 now leaves
   no local defp at all, and the extractions in 9/12/13 should *reduce* findings, never add).
3. Final gate: full `mix precommit`, run bare (never piped through tail/head/grep), exact exit
   code + test counts reported verbatim. Known rotating full-suite flakes (MemoryExport /
   collector crash-recovery / clustering `:pg`): one unrelated timing flake → re-run, not a
   regression — unless it reproduces or sits in a touched file.
4. Optional live check: `mix jidoclaw` → `/help` renders the three new entries aligned with
   their section neighbors.

Commit only when asked; stage only the files above. Suggested message:
`refactor: audit §4 batch — single-source duplicated helpers, drop wasted work, fix silent test + help gaps`.

## Follow-ups spawned by this plan (not in this PR)

- Test-support dedup PR: shared `eventually/2` polling helper (19 files found, audit said 15)
  + route the 13 `defp kinds/2` copies through the existing `LeaseHelpers.kinds/2`
  (accept run-or-id first arg; `composer_durable_test.exs` imports LeaseHelpers yet redefines it).
- Help-box full realignment to one interior width + strict width-invariant test.
- `~w(talk sketch code system)` single-sourcing — only if the team decides port-fidelity to
  Alp River no longer binds; otherwise leave as documented duplication.

Session housekeeping (first action after plan approval, before code edits): persist the review
lesson to auto-memory — "guard-on-discriminator + delegate to a partial matcher is NOT nil-total
when the matcher's clauses also require payload fields; keep explicit clauses or add a total
variant at the canonical source".
