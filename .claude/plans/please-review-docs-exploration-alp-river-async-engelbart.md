# AR-8b-2 — Sketch Graduation (Phase C: C1 + C2 + C3)

## Context

AR-8b shipped the **sketch path** as a real composer route: a `sketch` turn launches a hard-isolated,
file-tools-only worker in a per-prototype `<project>/.prototypes/<uuid>/` sandbox, and the run converges
trivially. The deferred half (AR-8b-2, `docs/exploration/alp-river/AR-8b-2-GRADUATION.md`) covers the
**cross-run** concerns the in-run path doesn't need. This plan implements the full **cross-run "Phase C" band**:

- **C1 — Provenance**: when a later turn becomes a `code`/`system` build after the session sketched, carry the
  prior prototype into the fresh composer seed so "throwaway becomes real" doesn't start from a blank slate.
- **C2 — Oscillation guard**: stop a `sketch ⇄ code` flip-flop from thrashing brand-new composer runs.
- **C3 — Retention sweep**: an **opt-in** TTL garbage-collector for stale `.prototypes/<id>/` dirs (default off).

**Outcome.** A user who sketches a throwaway, then says "ok, build it for real," gets a `code`/`system` run
seeded with a fresh LLM summary of what the prototype established (the prototype *informs*, it does **not**
auto-merge — that would defeat AR-8b's isolation boundary). Rapid path-flipping is debounced with a one-shot
confirm prompt. Disk growth from accumulated prototypes is bounded by an opt-in sweeper that never deletes a
prototype an in-flight run still needs.

**Decisions locked with the user:** scope **C1 + C2 + C3**; C1 carries a **fresh LLM summary** (not files, not a
stored summary); C3 sweeps a **single project root**.

**Greenfield**: no data migration / back-compat work. **Definition of done**: `mix precommit` passes (format,
`credo --strict`, `reach.check --strict` at zero, `jidoclaw.compile_check` no-warnings, full test suite). Leave
everything unstaged; do not commit.

> **This revision incorporates review feedback** — see *Review fixes incorporated* at the end. The biggest change:
> C1 graduation is now keyed off a **durable "pending prototype" candidate** in session metadata (not the fragile
> adjacent `last_triage_path`), which fixes the debounce-erases-graduation and adjacency bugs and restores
> `last_triage_path` to observability-only.

---

## Shared substrate

### `JidoClaw.ProjectDir` — public single-rooted project dir (`lib/jido_claw/project_dir.ex`)

`Application.project_dir/0` **does not exist** — only a *private* `project_dir/0` in `application.ex:379`. Add a
tiny public module so C3 (and anything else) can reach the node's project root without duplicating the env read:

```elixir
defmodule JidoClaw.ProjectDir do
  @moduledoc "The single project root this node operates against (boot, skills, sweeps all key on it)."
  @spec current() :: String.t()
  def current, do: Application.get_env(:jido_claw, :project_dir, File.cwd!())
end
```

Optionally have `application.ex`'s private `project_dir/0` delegate to it (single-source) — not required.

### `WorkflowRun` reference query — C3 only (`lib/jido_claw/orchestration/workflow_run.ex`)

C3's sweep guard needs "is this prototype still referenced by a live run?" Filtered on `config` JSONB (no session
FK; provenance lives at `config["premises"]["prototype_id"]`). **No existing read filters on `config`**, so this is
new ground; Ash 3.29 bracket access (`config["premises"]["prototype_id"]`) compiles to native JSONB (`->>`/`#>>`)
— a self-verifying test guards it. `config` being `public?(false)` does not block in-resource action filters
(precedent: `set_status` accepts private attrs).

```elixir
# actions:
read :referencing_prototype_global do
  description("Cross-tenant non-terminal runs whose premises reference a prototype_id (C3 sweep guard).")
  multitenancy(:bypass)
  argument(:prototype_id, :string, allow_nil?: false)
  prepare(build(limit: 1))                         # reference_state/1 only needs existence
  filter(
    expr(
      status in [:pending, :running, :awaiting_approval] and
        config["premises"]["prototype_id"] == ^arg(:prototype_id)
    )
  )
end
# code_interface: define(:list_referencing_prototype_global, action: :referencing_prototype_global, args: [:prototype_id])
# policies: add :referencing_prototype_global to the existing bypass action([...]) list (workflow_run.ex:24)
```

No GIN index needed: `multitenancy(:bypass)` means there is **no** tenant predicate, so `[:tenant_id, :status]`
wouldn't apply — but the existing **`[:status, :claim_expires_at]` index (`all_tenants?: true`, leading `status` —
workflow_run.ex:73)** serves the cross-tenant status filter, and `limit: 1` stops at the first hit. C1 needs **no**
WorkflowRun query at all (it uses the durable candidate below).

### Session loaded once, threaded (`lib/jido_claw/front_door.ex`)

`decide/2` loads the session **once** (best-effort; `nil` ⇒ everything fails open) and threads the struct to every
reader and writer. Readers use the snapshot; **all metadata writes are atomic `jsonb_set` on the row** (via
`Changes.SetMetadataKey`), so snapshot staleness across sequential writes in one turn is irrelevant. This replaces
the current per-helper re-loads (today `persist_path/2` loads its own) with a single load per turn.

---

## Phase C1 — Prototype provenance via a durable candidate

### Mechanism: a "pending prototype" candidate in session metadata

Keying graduation off `last_triage_path` is fragile (an intervening `talk` turn or a debounced turn erases the
signal — the two P2 review findings). Instead, persist a **durable candidate** under
`metadata["pending_prototype"]` and consume it on the launching turn:

- **Written** on a successful **non-sensitive** sketch launch:
  `%{"prototype_id", "prototype_dir", "run_id", "sketch_tokens", "at" => <ISO8601 UTC>}`. **A `:secrets`-flagged
  sketch writes NO candidate AND clears any stale one** (`set_pending_prototype` nil — see *Sensitive sketches*
  below), so a sensitive sketch's topic/provenance never enters public metadata and no older prototype can survive
  into a sensitive context. `sketch_tokens` is a **JSON-safe sorted-unique *list*** of redacted significant
  tokens — **never a `MapSet`/struct** (`Changes.SetMetadataKey` runs `Jason.encode!/1` on the value, session.ex:359,
  which can't encode a set). It is computed via `significant_tokens/1`:
  `JidoClaw.Security.Redaction.Patterns.redact/1` → **strip the `[REDACTED:…]` placeholder spans** → downcase →
  split → drop length < 4 / stopwords / a marker denylist (`bearer`, `redacted`, `secret`, …) → `Enum.uniq |>
  Enum.sort`. (`Session.metadata` is *public* JSONB, session.ex:273; these are non-secret topical tokens of an
  already-non-sensitive sketch — acceptable in tenant-scoped metadata. The secret-bearing case is excluded up front
  by writing no candidate.)
- **Read** (cheap, **no LLM**) when a `code`/`system` turn is launching, gated by: not expired (bounded TTL
  `@graduation_candidate_ttl_ms`, **default 2 hours**) **and** topically **relevant** to the graduating turn.
- **Hydrated** (the LLM summary) **only after the oscillation guard returns `:proceed`** — so a debounced turn
  never summarizes and never sends prototype contents to the LLM before the user confirms.
- **Consumed** on a successful, relevant `code`/`system` launch; **replaced** by a newer sketch; **survives**
  debounce, `talk` turns, and unrelated/intervening turns (TTL-bounded).

**Relevance gate (prevents unrelated bleed).** A pending "rate limiter" prototype must not graduate into a later
"build auth" run. `relevant?/2` converts the candidate's stored `sketch_tokens` list and the graduating turn's
`intent_tokens` to `MapSet`s and intersects them — `intent_tokens = significant_tokens(present(verdict.intent) ||
message)`, the **same redact-then-normalize path** (triage produces `verdict.intent` *with* recent history, so a
genuine "build it for real" restatement carries the topic; the `present(...) || message` fallback mirrors
`front_door.ex:101`). A non-empty intersection ⇒ relevant. The gate is **deliberately conservative — it biases
toward NOT graduating**: a false negative degrades to a normal (correct) `code` run (graduation is best-effort
enrichment), whereas a false positive would seed a run with a misleading summary; an empty/`nil` intent ⇒ no tokens
⇒ not relevant (safe). The 2-hour TTL is a backstop; relevance is the primary guard.

This makes graduation robust to non-adjacent `sketch → … → code` and the debounce confirm round-trip **without**
bleeding into unrelated later work, and means `last_triage_path` is **no longer read to decide** (observability-only
again, per the module-doc invariant).

### New module — `lib/jido_claw/front_door/prototype_summary.ex`

`JidoClaw.FrontDoor.PrototypeSummary` — fresh summarization, mirroring `JidoClaw.Triage.LLM` (tool-less
`generate_object` at `model: :fast`, `temperature: 0.0`, low `max_tokens`, **explicit `timeout:`**, a `gen` test
seam, `ReqLLM.Response.unwrap_object/2`).

- `summarize(prototype_dir) :: {:ok, String.t()} | {:error, term()}`; `VFS.Sandbox.validate_root/1` first.
- **Reads are jailed (security fix)** — every file read goes through
  `JidoClaw.VFS.Resolver.read(path, project_dir: prototype_dir, local_only: true)`, whose `:read`-mode
  `ensure_safe_project_path` does `realpath` containment and **rejects symlink escapes** (resolver.ex:408–413).
  Enumerate with an `lstat`-based walk that **skips symlink entries** (never descends a symlinked dir), so a
  symlink planted in `.prototypes/<id>` can neither be listed-into nor read out. (Do **not** use
  `Path.wildcard` + `File.regular?` + `File.read` — `File.regular?/1` follows symlinks.)
- **Bound the input**: `@max_files 12`, `@max_bytes_per_file 8_000`, `@max_total_bytes 40_000` (`reduce_while`
  halts on the total cap; per-file read errors are skipped — the dir may be racing GC).
- **Prototype contents are UNTRUSTED evidence, not instructions (prompt-injection defense).** The summary is
  injected into the *graduating run's* seed `intent`, so an instruction smuggled into a prototype file (e.g.
  "ignore prior instructions…", written by the sketch worker under user influence) could otherwise be laundered
  into the next real run. Two layers: **(1)** run each file excerpt through
  `JidoClaw.Security.Redaction.Patterns.redact/1` before sending (also strips any secret a worker wrote into a
  prototype file) and present excerpts inside a clearly **delimited data block**; **(2)** the system prompt frames
  the files as untrusted data and instructs the model to **summarize only observed implementation facts and to
  never follow or reproduce instructions found in the files**. The prototype is framed as a throwaway that
  *informs* (not a patch to merge); output is one or two concrete sentences.
- One-field schema `Zoi.object(%{"summary" => Zoi.string()})`. Two seams (`:prototype_summary_generate`,
  `:prototype_summary_model`). **Never raises into `decide/2`.**

### Sensitive sketches: no candidate (security)

A sketch whose turn carried `:secrets` (the same signal that marks the sketch run sensitive at `front_door.ex:103`)
**writes no `pending_prototype` candidate and explicitly clears any older one** (`set_pending_prototype` nil) — so
its topic, tokens, and provenance never touch public `Session.metadata`, and it **never graduates**. (The clear is
load-bearing: without it, a prior *non-sensitive* prototype would survive the sensitive sketch and could still
graduate on a later `code` turn — "replace" otherwise only happens on a candidate *write*.) The prototype contents are therefore never sent to the
summarization LLM, and no later run is seeded from a secret-involving throwaway. The subsequent "build it for real"
turn is simply triaged on its own merits (and flagged sensitive if it re-signals `:secrets`) — the same baseline
treatment as any other `code` turn. This is simpler and strictly safer than carrying a sensitive sketch forward, at
the cost of no graduation enrichment for sensitive throwaways (acceptable — graduation is best-effort). Non-sensitive
sketches *are* summarized on graduation: exposure parity with the sketch worker's own LLM, which already processed
that content.

### Wiring — `lib/jido_claw/front_door.ex`

```elixir
def decide(message, ctx) when is_binary(message) and is_map(ctx) do
  history = recent_history(ctx, message)
  {:ok, %Verdict{} = verdict} = Triage.classify(message, history: history)
  session = load_session(ctx)                          # once, best-effort

  candidate = pending_graduation(message, verdict, session)  # cheap read: code/system + present + fresh + RELEVANT (no LLM)
  persist_path(ctx, verdict.path, session)             # observability only (last_triage_path); order-independent now

  if Verdict.composer?(verdict) do
    case oscillation_guard(session, verdict.path, ctx) do          # C2 — before launch
      :proceed ->
        graduation = hydrate_graduation(candidate)                 # LLM summary HERE — only on a real launch
        result = start_composer(message, verdict, ctx, graduation, session)  # writes candidate on sketch launch
        after_launch(result, verdict, ctx, session, graduation)              # transition log; consume candidate on code/system
        {:composer, result}

      {:debounce, ack} ->
        {:composer, {:error, ack}}                     # no launch, NO summary ⇒ candidate + transition log untouched
    end
  else
    maybe_clear_marker(session)                        # C2/B1 — talk turn clears the speed-bump
    {:inline, verdict}
  end
end
```

- `pending_graduation/3` (cheap, **no LLM**): `pending_graduation(message, verdict, session)` returns `nil` unless
  `verdict.path in [:code, :system]`, a non-expired `pending_prototype` candidate is present, **and** `relevant?/2`
  holds; else the raw candidate map. Wrapped `rescue`/`catch → nil` (`# reach:disable-next-line bare_rescue`).
- `hydrate_graduation/1`: `nil → nil`; otherwise summarizes (`PrototypeSummary.summarize/1` or `nil`) →
  `%{prototype_id, prototype_dir, run_id, summary}` (**`run_id` preserved through hydration** so `start_composer`
  can stash it in `graduated_from`; the candidate is always non-sensitive, so there is no sensitive branch). Called
  **only in the `:proceed` branch**, so a debounced turn never summarizes.
- `start_composer/3 → /5`: threads the summary into the seed `intent` (`graduated_intent/2` prepends
  `"\n\nPrior exploration (a throwaway sketch, NOT to be merged) found: …"` when present; the verdict intent stays
  load-bearing), folds `"graduated_from"` (string-keyed `prototype_id`/`dir`/`run_id`) into the `premises`
  `Map.merge` (lines 132–136), and on a successful **sketch** launch sets the candidate state: a **non-sensitive**
  sketch writes the candidate (`set_pending_prototype` with the redacted `sketch_tokens` list); a **sensitive**
  sketch **clears** it (`set_pending_prototype` nil) so no stale prototype survives. Uses `premises_extra` + the
  computed `intent` + `session`. (The current turn's own `sensitive?` is unchanged — `:secrets in verdict.signals`;
  nothing is propagated from a graduation, since sensitive sketches don't graduate.)
- `after_launch/5`: records the C2 transition (any path) and, on a successful `code`/`system` launch **with** a
  graduation, consumes the candidate (`set_pending_prototype` nil). An unrelated `code` turn (no graduation) leaves
  the candidate for a later relevant turn (TTL-bounded).
- **Summary↔provenance independent**: `graduated_from` is stashed even when `summary == nil` (e.g. a GC'd/empty dir
  or an LLM failure).
- **Fail-open**: no/expired/irrelevant candidate, session unloadable, GC'd/unreadable/empty dir, LLM error/timeout,
  or any raise ⇒ normal launch. Non-graduating turns produce a **byte-identical** seed.

---

## Phase C2 — Oscillation guard (cross-run)

### Session metadata writes (`lib/jido_claw/conversations/resources/session.ex`)

Three new argument-only update actions, all reusing the existing atomic `Changes.SetMetadataKey` (no new change
module — avoids an ExSlop clone sibling; consistent with the existing `:set_triage_path`/`:set_*` family). Each
declares `accept([])` to match the resource's argument-only action style.

```elixir
update :set_path_transitions do
  accept([]); argument(:transitions, {:array, :map}, allow_nil?: false)
  change({Changes.SetMetadataKey, key: "path_transitions", argument: :transitions})
end
update :set_oscillation_marker do                 # set when :at present; CLEAR when nil
  accept([]); argument(:at, :string, allow_nil?: true)
  change({Changes.SetMetadataKey, key: "oscillation_prompted_at", argument: :at})
end
update :set_pending_prototype do                  # C1: set (map) / consume (nil)
  accept([]); argument(:candidate, :map, allow_nil?: true)
  change({Changes.SetMetadataKey, key: "pending_prototype", argument: :candidate})
end
# + code_interface defines. (Verify SetMetadataKey's nil-arg delete branch when wiring the clear paths.)
```

### Guard + transition log (`lib/jido_claw/front_door.ex`)

- **Transition log**: bounded newest-first list under `metadata["path_transitions"]` (cap = reuse `@history_window`
  6) of `%{"path", "at"}` — **no `run_id`** (the flip-count guard needs only path + time, and omitting the run id
  keeps a sensitive sketch launch's run id out of public metadata). Appended in `after_launch`
  (read-compute-then-`set_path_transitions` overwrite of the capped list off the snapshot — acceptable: a session's
  turns are serialized and the guard fails open). Composer launches only.
- **`oscillation_guard/3` → `:proceed | {:debounce, error_ack}`**, fail-open to `:proceed` on any read failure:
  - `thrash?/3` (pure, unit-testable): build the in-window path sequence `[current_path | recent_in_window_paths]`
    (newest first) and **count adjacent path-flips** (a `sketch ↔ code`/`system` boundary); debounce when the flip
    count ≥ `@osc_flip_threshold` (2). Counting *flips* (not occurrences of the target path) matches the doc's "2
    transitions in 60s": `sketch → code` is 1 flip (a normal graduation — never debounced); `sketch → code →
    sketch` is 2 (the first flip-back trips it). Keep `flips/1`, `within_window?/2`, `last_composer_path/1`
    extracted so the guard body stays flat (credo nesting ≤ 3).
  - **"Ask once, then proceed" (B1)**: a debounce sets `oscillation_prompted_at`; the next in-window turn sees it
    (`recently_prompted?`) and proceeds (the re-send is the confirmation), consuming the marker. `maybe_clear_marker`
    only writes when the marker is present. A `talk` turn also clears it. **The candidate survives the debounce**
    (consumption is tied to launch), so the confirming re-send still graduates.
  - **Return**: reuse `{:composer, {:error, %{path:, message:}}}` — both callers (`lib/jido_claw.ex:281`,
    `cli/repl.ex:418`) already render `resp.message`, so **zero caller changes**. Short, stable message (bypasses
    redaction — never `inspect`): *"You've flipped between sketch and {path} a couple of times just now. Re-send to
    start the {path} run, or say 'just sketch it' to stay in the sandbox."*
- **Telemetry (no silent suppression)** — mirror `triage.classified`:
  `:telemetry.execute([:jido_claw, :triage, :oscillation_guard], %{count: 1}, %{path:, prior:, reason:})` +
  `JidoClaw.SignalBus.emit("jido_claw.triage.oscillation_guard", …)`, on every intervention.
- **Clock seam** (deterministic tests; none exists today): `now/0 = clock().utc_now()`,
  `clock/0 = Application.get_env(:jido_claw, :front_door_clock, DateTime)`.
- New attrs: `@osc_window_ms 60_000`, `@osc_flip_threshold 2`, `@graduation_candidate_ttl_ms` (default 2 hours).

---

## Phase C3 — Retention TTL sweep (opt-in, default off)

### Shared reference check — `lib/jido_claw/orchestration/prototype_reference.ex`

```elixir
@spec reference_state(String.t()) :: :referenced | :unreferenced | :unknown
def reference_state(id) when is_binary(id) do
  case WorkflowRun.list_referencing_prototype_global(id) do
    {:ok, [_ | _]} -> :referenced
    {:ok, []}      -> :unreferenced
    _              -> :unknown            # DB error ⇒ sweeper MUST NOT delete (fail safe)
  end
end
```

**Why `premises["prototype_id"]` is the right (and sufficient) reference:** under fresh summarization the
graduating run reads the prototype dir only **synchronously at the front door**, before the new run exists — the
summary is baked into its seed and the run never touches `.prototypes/` (that's F3, out of scope). The only process
needing the dir live is an **in-flight sketch run**, whose parent carries `premises["prototype_id"]` and stays
non-terminal for the worker's lifetime. So the check protects exactly that window; `graduated_from` is pure
provenance and needs no sweep protection. (A dangling un-consumed candidate isn't protected either — it degrades
gracefully.)

### Sweeper — `lib/jido_claw/vfs/prototype_retention_sweeper.ex`

`JidoClaw.VFS.PrototypeRetentionSweeper`, modeled on `JidoClaw.Trace.RetentionSweeper` (hourly self-rescheduling
singleton; config read at tick time; `nil`/non-positive **disables**; bare-rescue + catch reschedules cleanly).
**No drain loop** (the prototype set is small) — also keeps `handle_info(:sweep, _)` structurally distinct from the
trace sweeper (avoids a clone finding).

```elixir
defp sweep do
  case max_age_days() do
    days when is_integer(days) and days > 0 ->
      cutoff = DateTime.add(DateTime.utc_now(), -days, :day)
      Enum.each(prototype_roots(), &sweep_root(&1, cutoff))
    _ -> :ok                                                # disabled (default)
  end
rescue ... catch ...                                         # reach:disable-next-line bare_rescue
end

defp maybe_delete(dir, id, cutoff) do
  with :ok <- Sandbox.validate_root(dir),                   # only ever a REAL .prototypes/<uuid>/ dir
       {:ok, newest} <- effective_mtime(dir),               # newest mtime across the dir AND its files (recursive)
       true <- DateTime.compare(newest, cutoff) == :lt,     # stale
       :unreferenced <- PrototypeReference.reference_state(id) do   # fail safe: skip on :referenced or :unknown
    File.rm_rf(dir)
  else
    _ -> :ok                                                # keep on any non-definitive result
  end
end

defp prototype_roots, do: [ProjectDir.current()]            # A1: single root (P1 fix — no Application.project_dir/0)
defp max_age_days, do: Keyword.get(Application.get_env(:jido_claw, :prototype_retention, []), :max_age_days)
```

- `effective_mtime/1` (P3 fix): directory mtime alone changes only on entry add/remove, so an *edited* prototype
  could look stale. Use the **newest mtime across the dir and all contained files** (a bounded recursive walk;
  `:universal` mtime tuples → `DateTime`), **skipping symlink entries via `lstat`** (no symlink loops, no
  outside-tree mtime influencing retention — the same lstat-skip discipline as the summary enumeration). An
  actively-edited prototype therefore stays fresh.
- `sweep_root/2`: `File.ls(Path.join(root, ".prototypes"))`, keep UUID-named children via a new
  `Sandbox.uuid_child?/1` predicate (single-sources the `@uuid` regex — no clone with `VFS.Sandbox`), then
  `maybe_delete/3`. Missing `.prototypes` ⇒ no-op.

### Config + wiring + reach

- `config/config.exs`: `prototype_retention: [max_age_days: nil]` — **disabled by default**, documented like the
  `:trace` `retention_days` note (durability over tidiness; set a positive `max_age_days` to enable).
- `lib/jido_claw/application.ex`: add the sweeper to `infra_children` after `Trace.RetentionSweeper` (always
  started, inert when disabled).
- `.reach.exs`: add the sweeper to the `behaviour_candidate` ignore list (its GenServer callbacks would otherwise
  trip a false-positive shared-behaviour suggestion).

---

## Files changed

| File | Change |
| --- | --- |
| `lib/jido_claw/project_dir.ex` | **New** — public `current/0` (fixes the nonexistent `Application.project_dir/0`) |
| `lib/jido_claw/orchestration/workflow_run.ex` | C3 `:referencing_prototype_global` JSONB read action + code-interface define + add to the policy bypass list |
| `lib/jido_claw/front_door/prototype_summary.ex` | **New** — jailed (`Resolver.read` + lstat-skip), bounded, cheap `generate_object` summary, two seams, explicit timeout, fail-open |
| `lib/jido_claw/front_door.ex` | Load-session-once + thread; `pending_graduation/3` + `hydrate_graduation/1` (candidate-based, relevance-gated) + `relevant?/2` + `significant_tokens/1` (redact→strip placeholders→tokenize→sorted-unique list); `start_composer/5` (intent + `graduated_from` + **non-sensitive** candidate write); `after_launch/5` (transition log + candidate consume); C2 `oscillation_guard/3` + pure `flips/1` helpers + marker + telemetry + clock seam; new attrs |
| `lib/jido_claw/conversations/resources/session.ex` | Three argument-only update actions (`:set_path_transitions`, `:set_oscillation_marker`, `:set_pending_prototype`) reusing `Changes.SetMetadataKey`, each `accept([])` + code-interface defines |
| `lib/jido_claw/orchestration/prototype_reference.ex` | **New** — `reference_state/1` (3-state, fail-safe) over the C3 action |
| `lib/jido_claw/vfs/prototype_retention_sweeper.ex` | **New** — opt-in TTL sweeper (single root, effective-mtime, reference-guarded) |
| `lib/jido_claw/vfs/sandbox.ex` | Add `uuid_child?/1` (single-source the UUID regex) |
| `lib/jido_claw/application.ex` | Wire the sweeper into `infra_children` (optionally delegate private `project_dir/0` to `ProjectDir`) |
| `config/config.exs` | `:prototype_retention` block (disabled default) |
| `.reach.exs` | Add the sweeper to `behaviour_candidate` ignore list |
| `test/jido_claw/front_door/prototype_summary_test.exs` | **New** — summary unit; **symlink-escape rejected**; **file excerpts redacted (`Patterns.redact`) + delimited before the LLM call** (assert via the captured seam input: a planted secret and an injected "ignore instructions" line are scrubbed/contained); fail-open; LLM seam |
| `test/jido_claw/front_door_test.exs` (or new `_graduation_test.exs`) | C1 candidate flow: sketch→code carries summary + `graduated_from` (incl. `run_id`); **non-adjacent** sketch→talk→code still graduates; **unrelated later code turn does NOT graduate** (relevance gate); **sensitive sketch ⇒ NO candidate + clears any stale one** (assert a prior non-sensitive prototype does NOT graduate after a sensitive sketch); **`sketch_tokens` is a JSON-safe redacted token list** (assert it survives `Jason.encode!` and that a secret + marker words like `bearer`/`redacted` are absent from `session.metadata`); **`path_transitions` entries carry no `run_id`**; fail-open on GC'd dir |
| `test/jido_claw/front_door_oscillation_test.exs` | **New** — debounce on the **second flip** (sketch→code→sketch) / ask-once-then-proceed / **debounce preserves the candidate AND skips summarization** / fail-open / marker-clear / telemetry + pure `flips/1` unit tests (clock seam) |
| `test/jido_claw/orchestration/prototype_reference_test.exs` | **New** — `reference_state/1` `:referenced`/`:unreferenced`/terminal-doesn't-protect (self-verifies the JSONB filter SQL) |
| `test/jido_claw/vfs/prototype_retention_sweeper_test.exs` | **New** — disabled-by-default; stale+unreferenced swept; reference-protected kept; fresh-by-edit kept (effective-mtime); non-prototype untouched |

---

## Verification

1. **Targeted tests**, each new/changed area (commands per file above). Key cases the reviews surfaced: symlink
   escape rejected in `PrototypeSummary`; non-adjacent graduation; **unrelated turn does NOT graduate** (relevance);
   **sensitive sketch writes no candidate** (no graduation, no topic in metadata); **debounce skips summarization
   and preserves the candidate**;
   **debounce trips on the second flip**; effective-mtime keeps an edited prototype; reference-protected dir kept.
   For sweeper tests use `VFS.Sandbox.create_prototype_dir/1` for shape-valid dirs, `File.touch/2` to backdate, and
   drive the tick with `send(pid, :sweep)` + a `:sys.get_state` barrier (per `retention_sweeper_test.exs`).
2. **Manual end-to-end** (Tidewave `project_eval`): with the summary seam stubbed, `FrontDoor.decide("sketch a
   rate limiter", ctx)` then a `talk` turn then `FrontDoor.decide("ok build it for real", ctx)`; assert the code
   run's `premises["graduated_from"]` and the seeded `intent` carry the summary. Flip sketch⇄code twice in 60s
   (injected clock) → assert the `{:composer, {:error, _}}` confirm ack and **no run created**, then a re-send
   proceeds **and still graduates**.
3. **`mix precommit`** — the completion gate. Watch points: `reach.check --strict` (sweeper in
   `behaviour_candidate` ignore list; regex single-sourced via `Sandbox.uuid_child?/1`; reference query in one
   module; the two sweepers' `handle_info` kept distinct); `credo --strict` (keep `oscillation_guard`/
   `pending_graduation` flat via extracted predicates); `jidoclaw.compile_check` (no dead `else` branches). No
   migration (rides existing JSONB columns + the existing `[:status, :claim_expires_at]` index).

## Sequencing

C1 and C2 share `decide/2` + the single session load — implement together (the doc's "ship together" note; C2
fails open). C3 is independent and default-off. Land the shared bits (`ProjectDir`, the `WorkflowRun` reference
action, `PrototypeReference`) first.

## Review fixes incorporated

**Round 1**
- **P1 `Application.project_dir/0` (compile blocker)** → new public `JidoClaw.ProjectDir.current/0`; sweeper uses it.
- **P1 `PrototypeSummary` symlink escape** → reads jailed through `Resolver.read(.., project_dir: prototype_dir,
  local_only: true)` (verified `:read`-mode realpath containment, resolver.ex:408–413) + lstat-skip enumeration.
- **P1 sensitive sketches** → candidate carries `sensitive`; sensitive ⇒ skip summarization (no content to LLM) +
  propagate `sanitize_sensitive_context` to the graduating run. *(Superseded in R4: sensitive sketches now write no
  candidate at all.)*
- **P2 debounce erases graduation** → candidate consumed only on launch, so it survives a debounced turn for the
  confirming re-send.
- **P2 adjacency-only** → durable candidate survives intervening `talk`/other turns until consumed, expired
  (bounded TTL), or replaced by a newer sketch; `last_triage_path` is no longer read to decide.
- **P3 mtime brittleness** → `effective_mtime/1` = newest mtime across the dir and its files (recursive).
- **Idiomatic notes** → `accept([])` on the new `Session` actions; explicit `timeout:` on `PrototypeSummary`.

**Round 2**
- **P2 summarization-before-confirm** → split the cheap candidate read (`pending_graduation/3`, pre-guard) from the
  LLM `hydrate_graduation/1` (post-`:proceed`); a debounced turn never summarizes.
- **P2 unrelated-bleed** → conservative `relevant?/2` token-overlap gate (biases toward NOT graduating) so a stale
  prototype can't bleed into unrelated later work; TTL cut from 7 days to **2 hours** as a backstop.
- **P3 C3 index rationale** → cite the real index: `[:status, :claim_expires_at]` (`all_tenants?: true`, leading
  `status`); add `limit: 1` (existence-only).
- **P3 oscillation threshold** → count **adjacent flips**, not target-path occurrences; debounce on the 2nd flip
  (`sketch → code → sketch`); tests/verification reworded.
- **P3 `effective_mtime/1` symlinks** → lstat-skip symlink entries in the recursive mtime walk (no loops / no
  outside-tree mtimes).

**Round 3**
- **P1 `sketch_intent` leak into public metadata** → store `sketch_tokens` (redacted, normalized) instead of raw
  intent. *(Refined in R4: a JSON-safe sorted-unique **list** (not a set); concrete redactor named; sensitive
  sketches write no candidate.)*
- **P2 `hydrate_graduation/1` dropped `run_id`** → hydrated map preserves `run_id` (→ `graduated_from`).
- **P3 relevance on normalized stored tokens** → intersect the candidate's stored `sketch_tokens` with
  `intent_tokens(present(verdict.intent) || message)`; no repeated raw-text tokenization; `nil` intent handled
  consistently with `front_door.ex:101`.

**Round 4**
- **P2 JSON-safe storage** → `sketch_tokens` is a **sorted-unique list** (not a `MapSet` — `SetMetadataKey` runs
  `Jason.encode!/1`, session.ex:359); `relevant?/2` builds `MapSet`s in memory.
- **P2 topic text in public metadata** → **supersedes the round-1/round-3 sensitive handling**: a `:secrets` sketch
  now writes **no candidate at all** (no topic/provenance/summary, no graduation), so the only persisted tokens are
  non-secret topical words of an already-non-sensitive sketch (acceptable in tenant-scoped metadata). This also
  deletes the skip-summary + sensitivity-propagation branches (dead once sensitive sketches don't graduate).
- **P3 exact redactor** → `JidoClaw.Security.Redaction.Patterns.redact/1` (patterns.ex:45), not the namespace.
- **P3 drop all markers** → strip the `[REDACTED:…]` placeholder spans pre-tokenization + a marker denylist
  (`bearer`, `redacted`, `secret`, …); tests assert marker words never become relevance anchors.

**Round 5**
- **P2 sensitive sketch clears a stale candidate** → a sensitive sketch launch calls `set_pending_prototype(nil)`
  (not just "writes nothing"), so an older non-sensitive prototype can't graduate after the user enters a sensitive
  sketch (replace otherwise only happens on a write).
- **P3 `run_id` out of `path_transitions`** → the transition log stores `%{"path", "at"}` only (the flip-count guard
  needs nothing more), keeping a sensitive launch's run id out of public metadata.

**Round 6**
- **P3 prototype-content prompt injection** → `PrototypeSummary` treats file contents as untrusted evidence: redact
  excerpts via `Patterns.redact/1` + wrap in a delimited data block, and a system prompt that summarizes observed
  facts only and never follows/reproduces in-file instructions — so a malicious "ignore prior instructions…" in a
  prototype file can't launder into the graduating run's seed.

## Documented decisions (no open questions)

- **JSONB filter form**: bracket access (a self-verifying test guards it).
- **C1 detection**: durable `pending_prototype` candidate (not `last_triage_path`); **relevance-gated via a redacted
  `sketch_tokens` *list*** (sensitive sketches write **no** candidate, so no secret topic reaches public metadata)
  and **summary hydrated only on a real launch**; `graduated_from` stashed even when summary is `nil`.
- **C2 debounce**: count adjacent flips (2nd flip trips); **marker-clear B1** — cleared on any proceed (incl. the
  confirming re-send) or a talk turn; set only on a trip.
- **C3 root**: single `JidoClaw.ProjectDir.current/0`, behind `prototype_roots/0` for a one-function future broadening.
- **Candidate TTL**: 2 hours (configurable) backstop; `relevant?/2` is the primary guard against unrelated graduation.
