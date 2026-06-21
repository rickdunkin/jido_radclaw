# AR-2 Composer Phase 2d — Code-review fixes

## Context

Phase 2d (crash recovery) landed and a code review surfaced one **[P2] bug** plus one
**open question**. A follow-up review of *this* plan added two refinements (a racy regression
assertion; a too-confident `put_start_catalog` claim) — both folded in below. **Done = `mix
precommit` green.**

### Finding 1 (P2) — VALIDATED, real bug

`WorkflowRecovery.recoverable_catalog?/1` (`workflow_recovery.ex:308`) decides a composer
parent is recoverable with `not is_nil(Catalog.from_map(run.config["catalog"]))`. But
`Stage.from_map/1` (`stage.ex:169`) is only **atom-safe**, not **structurally complete**:
every `with` clause accepts an absent key via its nil/default head, so `Stage.from_map(%{})`
returns a default `%Stage{name: nil, unit: nil, routes: []}` — **not `nil`**. Therefore
`Catalog.from_map(%{"bad" => %{}})` returns a **non-nil but structurally-invalid** catalog,
and the guard treats it as recoverable. `from_map`'s nil-on-failure contract only fires for
**atom-unsafe** input (an unknown closed enum tag); a structurally-degenerate map slips through —
exactly what `CatalogValidator` is designed to reject.

**Consequence (worse than the review's guess).** The inline comment at
`workflow_recovery.ex:293-295` claims a bad catalog "would crash/loop inside `compose_route`".
It does not. I traced it: `Router.compose_route/4` is total, the lone malformed stage subscribes
to nothing, so the composed route is **empty**; `dispatch_cohort` returns `nil`; `Loop.terminal`
classifies the first tick `:converged` (vacuously); `finish` appends `:route_converged` → the
parent flips to **`:completed`**. So recovery **silently false-converges a corrupt-config run to
`:completed`**, mutating the parent instead of leaving it `:running` as the comments promise.

### Finding 2 (Open question) — ANSWERED: test-only, no behavior gap

> Is `create_parent_run(tenant:, actor:)` followed later by `start_composer/2` with full opts
> a supported production path?

**No.** The only production launch entry is `run_sync/1` (`route_composer.ex:575`), which threads
the **full opts** (catalog/seed/bounds) into `create_parent_run` — so the catalog is durable in
`config["catalog"]` at genesis on every real path. The only production "later start" is crash
recovery, which reconstructs from `config` and **refuses to start** when it is absent/malformed.
No tool, CLI, cron, mix task, signal handler, or action creates a minimal parent and starts the
composer later — every minimal `create_parent_run(tenant:, actor:)` call lives in tests (H5b/H12).
**Resolution: no code change.** (The config-authoritative tightening in Step 2 below *also* hardens
the `start_composer`/`ensure_started` seams the reviewer flagged as "public-ish and future-facing".)

---

## Fix

The two findings share one root: code trusts a **non-nil `from_map` result** as "usable", when
`from_map` only guarantees atom-safety. Fix it once, in **one shared decode-and-validate helper**
used by both the recovery guard and the launch/recovery opts-builder, so the two can never drift.

Reuse the existing authority — `CatalogValidator.validate/1` (the same coherence gate the
built-in catalog passes at **compile time**, `catalog.ex:152-155`): a pure function, no
compile-time/template dependency, takes the exact `%{name => %Stage{}}` shape `from_map` returns,
`[]` = clean. This is the review's **Option 2** (validate the decoded catalog), not Option 1
(harden `Stage.from_map`): `from_map`'s single job stays atom-safe round-trip fidelity;
structural/semantic coherence is `CatalogValidator`'s job — no duplicated rules, no drift from the
compile-time gate.

### Step 1 — shared helper `RouteComposer.decode_config_catalog/1` — `lib/jido_claw/route_composer/route_composer.ex`

A public, total, three-way classifier (ensure `CatalogValidator` is aliased — add if absent):

```elixir
@doc """
Decode a serialized `config["catalog"]` for a composer launch/resume:

  * `{:ok, catalog}` — present and coherent (`CatalogValidator` clean). `config`
    is authoritative, so this wins over any opts catalog.
  * `:absent` — no serialized catalog (the minimal `create_parent_run` lifecycle
    path); the caller MAY fall back to an opts catalog.
  * `:invalid` — present but un-decodable (atom-unsafe tag) OR incoherent
    (structural/semantic). `config` is authoritative, so an invalid one is NOT
    overridden by a possibly-stale opts catalog — it behaves like "no start".
"""
@spec decode_config_catalog(term()) :: {:ok, %{String.t() => Stage.t()}} | :absent | :invalid
def decode_config_catalog(nil), do: :absent

def decode_config_catalog(serialized) do
  case Catalog.from_map(serialized) do
    nil ->
      :invalid

    catalog when map_size(catalog) == 0 ->
      # A zero-stage catalog decodes + validates vacuously clean but can only
      # false-converge (no stage to dispatch) — fail closed, same as malformed.
      :invalid

    catalog ->
      if CatalogValidator.validate(catalog) == [], do: {:ok, catalog}, else: :invalid
  end
end
```

(The empty-catalog guard closes the same false-convergence class for a degenerate `%{}` config
catalog. No production path emits one — `run_sync` callers pass real, non-empty catalogs — but it
costs one clause and keeps the gate fail-closed.)

### Step 2 — `put_start_catalog/2` fails closed on invalid config — same file (`:533-543`)

Replace `Catalog.from_map(serialized) || start_opts[:catalog]` (which *uses* a malformed-but-
non-nil catalog and falls back to opts on **any** nil decode) with the three-way switch — opts
fallback **only** on `:absent`, never on `:invalid` (config-authoritative fail-closed):

```elixir
defp put_start_catalog(start_opts, serialized) do
  case decode_config_catalog(serialized) do
    {:ok, catalog} -> Keyword.put(start_opts, :catalog, catalog)
    :absent -> put_opts_catalog(start_opts)          # minimal-launch lifecycle path
    :invalid -> start_opts                            # authoritative-but-corrupt → no fallback
  end
end

# A present-but-invalid config drops to `start_opts` with no :catalog key → init's
# `Keyword.fetch!(opts, :catalog)` raises → `{:start_failed, _}` rather than launching a
# composer on a corrupt catalog or a possibly-stale opts one.
defp put_opts_catalog(start_opts) do
  case start_opts[:catalog] do
    nil -> start_opts
    catalog -> Keyword.put(start_opts, :catalog, catalog)
  end
end
```

Update the `build_start_opts` comment (`:506-507`): config valid wins; **absent** → opts
fallback (minimal-launch); **invalid** → refuse (no stale-opts fallback). No existing test hits
`:invalid` — `recoverable_parent` tests use a valid config catalog (`{:ok, _}`), lifecycle tests
use absent config + opts (`:absent`) — so both stay green.

### Step 3 — recovery guard delegates to the shared helper — `lib/jido_claw/orchestration/workflow_recovery.ex`

```elixir
defp recoverable_catalog?(run) do
  match?({:ok, _}, RouteComposer.decode_config_catalog(run.config["catalog"]))
end
```

`RouteComposer` is already aliased (`:88`); the local `alias JidoClaw.RouteComposer.Catalog`
(`:89`) becomes unused (its only use was `recoverable_catalog?`) — **remove it** or
warnings-as-errors fails. (`run.config["catalog"]` is nil-safe via `Access`; a nil config →
`:absent` → not recoverable.)

### Step 4 — false-invariant doc sweep (per `feedback_false_invariant_codebase_sweep`)

The bug grew from a comment-level false invariant — "`from_map` returns nil for **any**
malformation, so a non-nil decode is usable." Correct every restatement; scope each edit tightly
(`from_map` owns atom-safety; `decode_config_catalog` adds the `CatalogValidator` coherence gate):

1. `workflow_recovery.ex` else-branch comment (`:292-296`) — drop the inaccurate "would
   crash/loop inside `compose_route`" (it false-converges to `:completed`); "decode-first" →
   "decode-**and-validate** (via `RouteComposer.decode_config_catalog`)".
2. `workflow_recovery.ex` moduledoc (`:50-51`) — "a nil decode — absent **or** malformed — is
   un-recoverable" → decoded **and validated**; absent, atom-unsafe, **or** structurally-
   incoherent → un-recoverable, leaves `:running`.
3. `workflow_recovery.ex` `recoverable_catalog?` comment (`:306-307`) — rewrite: delegates to
   `decode_config_catalog`, recoverable iff `{:ok, _}` (decodes **and** validates coherent).
4. `stage.ex` moduledoc (`:121-127`) — scope "recovery treats a malformed serialized catalog
   identically to an absent one" to atom-unsafe input; point at `CatalogValidator` for structural
   coherence.
5. `catalog.ex` `from_map/1` moduledoc (`:192-198`) — same scoping (atom-unsafe → nil here;
   structural coherence is the `decode_config_catalog`/`CatalogValidator` gate).

---

## Tests

### Unit — `test/jido_claw/route_composer/catalog_test.exs`

Add to the `describe "to_map/from_map serialization"` block (add `alias JidoClaw.RouteComposer`):

```elixir
test "a structurally-empty stage map decodes (atom-safe) but is NOT validator-clean" do
  # `from_map` rejects only atom-unsafe input (unknown closed tags); a structurally
  # empty stage map decodes to a default %Stage{}, so coherence needs CatalogValidator.
  catalog = Catalog.from_map(%{"bad" => %{}})
  assert %{"bad" => %Stage{name: nil, unit: nil, routes: []}} = catalog
  assert CatalogValidator.validate(catalog) != []
end

test "decode_config_catalog classifies absent / valid / invalid" do
  valid = TestFixtures.phase1_catalog()
  assert RouteComposer.decode_config_catalog(nil) == :absent
  assert RouteComposer.decode_config_catalog(Catalog.to_map(valid)) == {:ok, valid}
  assert RouteComposer.decode_config_catalog(%{"bad" => %{}}) == :invalid             # structural
  assert RouteComposer.decode_config_catalog(%{}) == :invalid                         # zero-stage
  bogus = %{"s" => %{"unit" => %{"tag" => "nope", "name" => "x"}}}
  assert RouteComposer.decode_config_catalog(bogus) == :invalid                       # atom-unsafe
end

test "phase1_catalog validates clean (recovery-guard invariant)" do
  assert CatalogValidator.validate(TestFixtures.phase1_catalog()) == []
end
```

The middle test pins the shared contract — including `:invalid` (config-authoritative, no opts
fallback). The third underwrites Step 3 not breaking recovery tests 1–8 (they ride this fixture).

### Recovery regression — `test/jido_claw/route_composer/composer_durable_test.exs`

Prove a malformed config catalog leaves the parent `:running` and starts no composer. **The
deterministic discriminator is the captured warning log, not `Registry.lookup`** — the empty
catalog false-converges on the *first tick*, so the started composer can converge and exit before
any Registry/status snapshot runs (the buggy path could read empty too). Only the fixed
un-recoverable branch logs `"no recoverable catalog"`; the buggy resume path never does.

Craft a `:running` composer parent with a malformed `config["catalog"]` directly (the
`recoverable_parent/2` helper always serializes a *valid* catalog), modeled on
`craft_child/4` + `drive_child/3` — `WorkflowRun.create(%{name:, workflow_type: "composer",
config: %{"catalog" => %{"bad" => %{}}}}, …)` then `append_event(parent, :run_started, %{}, ctx)`
to reach `:running`:

```elixir
test "a malformed config catalog leaves the parent :running and starts no composer", ctx do
  parent = malformed_catalog_parent(ctx, %{"bad" => %{}})

  log =
    ExUnit.CaptureLog.capture_log(fn ->
      assert :ok = WorkflowRecovery.reconcile_all()
    end)

  # Deterministic discriminator: ONLY the un-recoverable branch logs this (fails
  # without the fix, where recoverable_catalog? returns true → resume → no such log).
  assert log =~ "no recoverable catalog"

  # Corroborating second signal: a restarted composer would append route_converged
  # ASYNCHRONOUSLY, so an immediate read is racy — use a BOUNDED settle (reuse the
  # suite's poll cadence, ~500ms) so the buggy path has time to misbehave, then
  # assert it never converged and the parent stays :running.
  refute converged_within?(parent.id, ctx, 500)
  assert reload(parent.id, ctx).status == :running
end
```

(`converged_within?/3` is a small bounded poll — loop `kinds/2` until `:route_converged` appears
or the window elapses; returns `false` on timeout. The log assertion is the primary discriminator;
this is defense-in-depth against a future change that resumes despite the guard.)

**Prove it fails without the fix** (per `feedback_prove_race_test_fails_without_fix` /
`feedback_permanent_test_over_spot_check`): revert Step 3, run this test, confirm the `log =~ "no
recoverable catalog"` assertion fails (the buggy path resumes instead of logging it); re-apply,
confirm green.

---

## Verification

1. **Targeted:** `mix test test/jido_claw/route_composer/catalog_test.exs
   test/jido_claw/route_composer/composer_durable_test.exs
   test/jido_claw/orchestration/workflow_recovery_test.exs
   test/jido_claw/orchestration/workflow_run_parent_lineage_test.exs`. Recovery tests 1–8 and the
   minimal-launch lifecycle tests must stay green (valid config → `{:ok, _}`; absent config +
   opts → `:absent` → opts), proving the helper admits valid catalogs and preserves the
   lifecycle-test fallback.
2. **Fix-fails-without test:** the revert-and-rerun check above.
3. **`mix precommit` — the completion gate.** Small surface (one shared helper + a `put_start_catalog`
   rewrite + a delegating guard + doc edits + tests). Watch: `compile_check` warnings-as-errors
   (new `CatalogValidator` use in route_composer; **removed** unused `Catalog` alias in
   workflow_recovery; new public fn needs `@doc`/`@spec`); credo `--strict` (small clauses);
   dialyzer (`decode_config_catalog/1` three-way return + `match?({:ok, _}, …)`); reach `--strict`
   (no new `fixed_shape_map` in lib — the `%{"bad" => %{}}` literal is test-only). Per
   `project_precommit_zero_findings`, run the full gate, not just compile+test; do not pipe
   through tail.

## Scope / non-goals

- **Finding 2** needs no code: minimal parents are test-only; production durably records the
  catalog at genesis (`run_sync`) or refuses to start without it (recovery). Step 2's
  config-authoritative tightening additionally hardens the `start_composer`/`ensure_started` seams.
- No change to `Stage.from_map` semantics (atom-safety unchanged), `CatalogValidator`,
  `compose_route`, the projection, or the migration. The fix is one shared helper + its two call
  sites + a doc sweep + tests.
- Everything stays unstaged; do not commit (per session constraints).
