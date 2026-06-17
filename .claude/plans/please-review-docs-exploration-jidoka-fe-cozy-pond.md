# Plan: V2-3 — Trace policy/sink split (`Trace.Policy` + `Trace.Sink`)

## Context

`docs/exploration/jidoka/FEATURES-WORTH-BORROWING-V2.md` records that the active Jidoka-V2 borrowing program is **complete** — V2-1 (approval gate), V2-2 (MCP consumption), V2-4 (replay diagnostics), and V2-6 (web search) all shipped. The remaining items are deliberate deferrals: **V2-7** (Lua DAGs) and **V2-5** (eval harness) are explicit "watch / don't build," and **V2-1's** input-length control is "not load-bearing for this threat model." That leaves **V2-3 (Trace policy/sink split)** as the one remaining item that is a concrete, bounded, buildable improvement — the user picked it.

**The problem it addresses.** The trace subsystem fuses two concerns the borrow separates:

1. **Redaction policy is hardcoded.** `JidoClaw.Trace.Sanitize` (`lib/jido_claw/trace/sanitize.ex`) carries its own `@large_keys` / `@sensitive_exact` / `@sensitive_contains` / `@sensitive_suffixes` module attributes. It is the **only** redactor in the codebase that does *not* reuse the central `JidoClaw.Security.Redaction.{Env,Patterns}` stack (every other redactor — `OutputRedaction`, `LogRedactor` — delegates to it). It also only redacts by **key name**, so a secret embedded in a non-omitted string *value* (e.g. `note: "Bearer sk-ant-api03-…"`) leaks into trace rows — and `Sanitize.preview/2`'s binary fast path (`sanitize.ex:108`) slices raw strings, leaking the same way.
2. **Persistence is hardwired.** `JidoClaw.Trace.Persistence` is the single durable writer; there is no sink abstraction (can't redirect writes to an in-memory target for assertions), and no sampling knob at all.

**Intended outcome.** Extract redaction + sampling into a config-visible `Trace.Policy` (data), make the durable-write target a swappable `Trace.Sink` behaviour (Postgres default + InMemory for tests), and reuse the central redaction stack where it is a clean win (`Patterns.redact/1` for value-scrubbing, `Env.sensitive_key?/1` as additional key coverage).

**Behavior posture (precise — not "unchanged"):** *Sampling and sink defaults preserve current behavior* (keep-all sampling; Postgres sink delegating to today's `Persistence`). *Redaction is an **intentional stricter default***: it newly redacts `Env`-only key names (`authorization`, `credential`, …) and embedded secret *values*, including in `preview/2` and inside invalid/non-UTF-8 binaries. This is the right tradeoff for a leakage-hygiene threat model; the plan treats it as a deliberate change, not a no-op.

**Completion bar:** `mix precommit` passes (compile-check with zero warnings, system-prompt check, `deps.unlock --unused`, format, `reach.check --arch --smells --strict`, `credo --strict`, `dialyzer`, full test suite). Nothing committed — all changes left unstaged.

---

## Design decisions (resolved)

### D1. Redaction: curated lists as policy data (floor) + central-stack reuse (additive)

A pure "delegate to `Env`" rewrite would **regress** redaction. `Security.Redaction.Env.sensitive_key?/1` matches bare-exact `password` / `secret` / `token` / `authorization` / `credential` and `_`-suffixed names (`_KEY`, `_TOKEN`, `_SECRET`, `_PASSWORD`, `_PASS`, `_PAT`, `_CREDENTIAL(S)`), but **not** the 7 unseparated compound forms the trace currently redacts and `sanitize_test.exs:8-26` asserts: `apikey`, `authtoken`, `privatekey`, `accesskey`, `bearer`, `apisecret`, `clientsecret` (neither bare-exact nor suffix-matchable). So:

- `Trace.Policy` carries the four redaction lists **as data**, defaulting to the current values verbatim → **zero redaction regression for existing keys**, `sanitize_test.exs` passes unchanged.
- Key classification is the **union** of (policy's curated lists) **OR** `Env.sensitive_key?/1` — curated lists are the floor (cover those 7 + the suffix/substring rules); `Env` adds evolving coverage. Verified safe: no test asserts non-redaction of any `Env`-caught key.
- **New:** binary leaf *values* not omitted or key-redacted are **redacted first** via `Patterns.redact/1` (identity on benign strings; catches embedded secrets the key-only approach misses), **then** made serialization-safe — if the redacted result is still invalid UTF-8 it is `inspect/1`'d. No `String.valid?` *pre*-guard (which would let an ASCII secret inside an invalid binary pass unredacted); the validity check runs *after* redaction, so secrets are scrubbed *and* the stored value is JSON-safe.
- Precedence preserved (matches the current `cond`): **omit** > **redact** > value-scrub. Policy list checks downcase the key (as today); `Env` handles its own case.
- Operator-tunable, additive, matching the `extra_allowed_env_vars` convention: config keys `extra_omit_keys` / `extra_redact_keys` (default `[]`) are normalized (`to_string |> String.downcase`, so atoms or mixed-case in config Just Work) and `MapSet.union`-ed onto the built-in defaults. Additive-only — can't accidentally un-redact a built-in.

### D2. `Trace.Sink` behaviour — one callback, thin Postgres adapter, bounded InMemory

```elixir
@callback write(JidoClaw.Trace.Event.t(), JidoClaw.Trace.t()) :: :ok
```

Mirrors exactly the pair the Collector holds at its persist point, so no new shape and **no rewrite of the careful `Persistence` logic** (sync/async, out-of-order `last_seq` UPSERT guard, atom→string boundary, crash-proof rescue, two-write):

- **`Trace.Sink.Postgres`** (default): `write(e, t) -> JidoClaw.Trace.Persistence.append(e, t)`. No process; rides the already-supervised `Persistence`. **Default path unchanged.**
- **`Trace.Sink.InMemory`** (tests): tiny singleton GenServer recording `{event, trace}` in a **bounded** flat list — `Enum.take([entry | entries], max)`, newest-first (a different shape from the Collector's double-reverse bounded-take, so no Reach clone smell), with a generous default cap (`max_entries`, default e.g. `10_000`, overridable via `start_link` opt). It is unconditionally supervised and config-selectable, so the cap prevents unbounded growth if it is ever selected in a long-running process. `written/1` filters by `trace_id`; `all/0` returns insertion order; `reset/1` clears state and resets the cap — default-restoring, or `reset(max_entries: n)` to shrink it for a bounded-eviction test directly on the supervised singleton (avoids racing the named process with a second `start_link`); plus a `:__sync__` call barrier. Crash-proof `handle_cast` (`# reach:disable-next-line bare_rescue`, mirroring `Persistence`).

### D3. Sampling: per-trace, deterministic, recomputed (no cache), keep-all by default

- Decision is **per-trace** (hash `trace_key/1`, not per-event) so a trace is wholly kept or dropped: `:erlang.phash2(key, 100) < round(sample_rate * 100)`. `sample_rate: 1.0` ⇒ always keep ⇒ sampling is a no-op vs today. `0.0` ⇒ never keep. (`:erlang.phash2` is already used in `clusterer.ex`, `proxy_generator.ex`.)
- **No drop-cache.** Because `keep_trace?` is a pure deterministic function of `trace_key`, it is simply **recomputed** in `record_event/4` each event — same key always yields the same answer, so a kept trace's later events still ingest and a dropped trace's events are dropped consistently, with **no `MapSet` of dropped keys to grow unbounded** (an earlier draft's `dropped` set was unprunable — dropped keys never enter `state.order`, so it was removed). Dropped ⇒ bump `seq` (keeps `seq` monotonic for the UPSERT/UUID contracts) and return — no ring append, no sink write.

### D4. Policy + sink snapshotted at init; `persist?` stays live

`init/1` builds `%Trace.Policy{}` (MapSet construction — too costly per-event), resolves+validates the sink module once, and stores both in Collector state. The `policy` struct field carries a compile-time `Policy.default()` so it is never `nil` for Dialyzer (see Step 6). Sampling/sink tests change `:trace` config and call the existing file-local `restart_collector/0` — the **same pattern** `collector_test.exs:33-41` uses for `max_traces`. `persist?()` **stays a live per-event read** (`collector.ex:740`): `trace_test.exs:26-30` flips `persist?: false` via `put_env` without restarting, and snapshotting it would reintroduce sandbox-leak writes.

### D5. Structs + bad-config: deliberate, fail-safe

- **Structs / tuples / exotic leaves in measurements/metadata** are handled explicitly in `Policy.scrub`: `is_struct(v) -> scrub(Map.from_struct(v))` key-redacts struct fields (chosen over `inspect/1`, which would render a `%Foo{token: "secret"}` field raw — a leak); the **tuple clause** converts tuples to scrubbed **lists**; and the leaf clause `inspect/1`s pids/functions **and refs/ports**. Together these (a) close the value-redaction gap for secrets nested in tuples (`outcome: {:error, "Bearer sk-ant-…"}`), and (b) keep the payload serialization-safe before it reaches `persistence.ex:157`'s `measurements`/`metadata` jsonb columns — the tuple→list conversion normalizes the stored shape (away from a surprising tuple encoding) while closing the tuple-nested secret leak. `Map.from_struct/1` alone doesn't guarantee serialization-safety; the expanded tuple/binary/leaf clauses do.
- **Sink config validation**: `resolve_sink/1` accepts the module only if `is_atom(sink) and Code.ensure_loaded?(sink) and function_exported?(sink, :write, 2)` — the `is_atom` guard is first, so a non-module value like `sink: "oops"` can't crash `Code.ensure_loaded?/1`. Otherwise it logs a warning and falls back to `Trace.Sink.Postgres`, so a bad `:sink` config never crashes the Collector (at resolution or first event).

---

## Implementation steps

### 1. New: `lib/jido_claw/trace/policy.ex` — `JidoClaw.Trace.Policy`

Struct + redaction engine + sampling math; the recursion lives here **once** (the old `Sanitize.payload/1` body, parameterized).

```elixir
defstruct sample_rate: 1.0,
          omit_keys: @default_omit_keys,        # MapSet — current 22 @large_keys (lowercased)
          redact_exact: @default_redact_exact,  # MapSet — current 16 @sensitive_exact
          redact_contains: ["secret_"],
          redact_suffixes: ["_secret", "_key", "_token", "_password"]

@spec default() :: t()
@spec from_config(keyword() | map()) :: t()       # sample_rate (int|float, clamped) + extra_{omit,redact}_keys (normalized, additive)
@spec scrub(t(), term()) :: term()
@spec keep_trace?(t(), term()) :: boolean()       # :erlang.phash2(key, 100) < round(rate*100)
```

`scrub/2` clauses (order matters — struct guard before the `%{}` clause):

```elixir
def scrub(p, v) when is_struct(v), do: scrub(p, Map.from_struct(v))
def scrub(p, %{} = m), do: Map.new(m, &scrub_pair(p, &1))     # scrub_pair: omit | redact | recurse value
def scrub(p, l) when is_list(l), do: Enum.map(l, &scrub(p, &1))
def scrub(p, t) when is_tuple(t), do: Enum.map(Tuple.to_list(t), &scrub(p, &1))  # -> scrubbed LIST (jsonb-safe)

def scrub(_p, v) when is_binary(v) do
  redacted = Patterns.redact(v)                                   # redact FIRST (catch ASCII secrets in invalid binaries)
  if String.valid?(redacted), do: redacted, else: inspect(redacted)   # then make JSON-safe
end

def scrub(_p, v) when is_pid(v) or is_function(v) or is_reference(v) or is_port(v), do: inspect(v)
def scrub(_p, v), do: v
```

- `scrub_pair/2`: `omit_key?` → `"[OMITTED]"`; `redact_key?` (curated lists **or** `Env.sensitive_key?/1`) → `"[REDACTED]"`; else `{key, scrub(p, value)}`. Each `defp` ≤ 11 cyclomatic (Credo).
- `from_config/1` reuses the keyword/map dual-dispatch shape from `Collector.config_value/3`; `normalize_sample_rate/1` coerces integers to float and clamps to `[0.0, 1.0]` (garbage ⇒ `1.0`); `normalize_keys/1` does `to_string |> String.downcase` then `MapSet.new`, unioned onto the defaults.
- Moduledoc: document the hybrid (curated floor + `Env`/`Patterns`), the **stricter** value-scrub (and its per-string regex cost — acceptable on a bounded personal deployment), the deliberate struct/tuple/ref/port handling (tuples → JSON-safe scrubbed lists), and the deterministic per-trace sampling.

Reuse: `Security.Redaction.Env.sensitive_key?/1`, `Security.Redaction.Patterns.redact/1` (model: `lib/jido_claw/tools/output_redaction.ex`).

### 2. Rewrite `lib/jido_claw/trace/sanitize.ex` as a thin facade

Delete the four `@...` key attributes and `defp large_key?/sensitive_key?`. `payload/1 = Policy.scrub(Policy.default(), value)`; add `payload/2 = Policy.scrub(policy, value)`. **Fix `preview/2`**: the binary fast path now redacts the full string before slicing, normalizing if still invalid UTF-8 — `redacted = Patterns.redact(value); safe = if String.valid?(redacted), do: redacted, else: inspect(redacted); String.slice(safe, 0, bytes)` (redact-before-truncate + serialization-safe); the non-binary path already routes through `payload/1` → `scrub` so it inherits redaction. Update moduledoc to point at `Trace.Policy` + `Security.Redaction`. Existing `sanitize_test.exs` passes unchanged (the two `preview` cases still hold).

### 3. New: `lib/jido_claw/trace/sink.ex` — `@callback write/2` (behaviour, D2)

### 4. New: `lib/jido_claw/trace/sink/postgres.ex` — `@behaviour`, delegates to `Persistence.append/2`

### 5. New: `lib/jido_claw/trace/sink/in_memory.ex` — bounded GenServer test sink (D2; `max_entries` cap, flat newest-first list, `reset/1` cap hook)

### 6. Modify `lib/jido_claw/trace/collector.ex`

- `require Logger`; aliases for `Trace.Policy`, `Trace.Sink`. After the alias add `@default_policy Policy.default()`; `defstruct` field `policy: @default_policy` typed `policy: Policy.t()` in `@type t` — **non-nil**: `init/1` always overwrites it, and the compile-time default stops Dialyzer inferring `| nil` at the `keep_trace?`/`payload` call sites. Also add `sink: JidoClaw.Trace.Sink.Postgres` (`module()`). **No `dropped` field** (D3).
- `init/1`: `policy = Policy.from_config(config)`, `sink = resolve_sink(config)`, merged into the struct alongside the existing `trace_config()` map.
- `record_event/4`: after `normalize_event` yields `%Event{}`, compute `key = trace_key(event)`; `if Policy.keep_trace?(state.policy, key)` → call an extracted `ingest_event(state, event, seq)` (the existing trace build / put / order / prune / rebuild / sink-write body); `else` → `%{state | seq: seq}`. Extraction keeps `record_event` ≤ 11 cyclomatic.
- `normalize_event`: thread the policy — the two `TraceSanitize.payload(x)` calls (lines 318-319) become `TraceSanitize.payload(state.policy, x)` (pass `policy` in; bump arity).
- Rename `maybe_persist/3` → `maybe_write_sink/3`: keep the live `persist?()` guard, replace `TracePersistence.append(event, trace)` with `state.sink.write(event, trace)`.
- Add `defp resolve_sink/1` with the `is_atom(sink) and Code.ensure_loaded?(sink) and function_exported?(sink, :write, 2)` validation + Postgres fallback (D5).

### 7. Modify `lib/jido_claw/application.ex`

Insert `JidoClaw.Trace.Sink.InMemory` into `infra_children` **between** `Trace.Persistence` and `Trace.Collector` (unconditionally — an idle bounded GenServer when unused; avoids conditional child specs and a sink-swap-races-missing-process bug). Update the inline ordering comment: order is now `Persistence → Sink.InMemory → Collector`, preserving "anything the Collector may write to on first event is already started" for **both** sinks.

### 8. Config — `config/config.exs:332` `:jido_claw, :trace` block

Add (existing keys untouched):

```elixir
sample_rate: 1.0,                          # keep-all (deterministic per-trace via :erlang.phash2); accepts 1
sink: JidoClaw.Trace.Sink.Postgres,        # default delegates to Trace.Persistence
extra_omit_keys: [],                       # additive "[OMITTED]" key names (atoms/strings, case-insensitive)
extra_redact_keys: []                      # additive "[REDACTED]" key names (baseline = Env + curated)
```

`config/test.exs:40` stays `persist?: false`. No `:trace` block exists in `runtime.exs`/`dev.exs`/`prod.exs` — no change.

---

## Test plan (`test/jido_claw/trace/`, singleton-touching files `async: false`)

- **New `policy_test.exs`** (`async: true`, pure): `keep_trace?/2` determinism (same key+rate ⇒ same boolean across many calls; `1.0` total-keep, `0.0` total-drop); `scrub/2` — omit → `[OMITTED]`; curated + 7 unseparated + an `Env`-only key (`authorization`) → `[REDACTED]`; **embedded-value scrub** `%{note: "Bearer sk-ant-api03-AAAAAAAAAAAAAAAAAAAAAAAA"}` → value scrubbed (use a 20+ char suffix so `Patterns` matches); an **invalid/non-UTF-8 binary with an embedded ASCII secret** → redacted without crashing; **struct** `scrub(default, %TStruct{token: "x", name: "ok"})` (file-local `defstruct [:token, :name]`) → `%{token: "[REDACTED]", name: "ok"}`; **tuple** `%{outcome: {:error, "Bearer sk-ant-api03-AAAAAAAAAAAAAAAAAAAAAAAA"}}` → secret scrubbed and the tuple becomes a list; refs/ports/pids/funs stringified via `inspect`; nested maps/lists; benign passthrough; `from_config/1` extra-list layering + `sample_rate` accepts integer `1` and clamps out-of-range.
- **New `sink/in_memory_test.exs`** (`async: false`): `write/2` → `written/1`/`all/0` round-trip; **bounded at `max_entries`** (`reset(max_entries: 3)`, write 5, assert only the 3 newest are retained; `on_exit(&Sink.InMemory.reset/0)` restores the default cap so later tests aren't affected); `reset/0`; `:__sync__` barrier; both sinks export `write/2`.
- **New `sink/postgres_test.exs`** (`async: false`, **SQL Sandbox owner like `persistence_test.exs`**, `persist_sync?: true`): `write/2` produces a `trace_runs` + `trace_events` row (thin — heavy cases stay in `persistence_test.exs`). This is the only file asserting the Postgres path.
- **Update `sanitize_test.exs`**: keep all current assertions (back-compat proof); add a `payload/2`-with-custom-policy case, an embedded-secret-in-value case, and a **`preview/2` redaction** case (`preview("Bearer sk-ant-api03-AAAAAAAAAAAAAAAAAAAAAAAA", 500) =~ "[REDACTED]"`).
- **Update `collector_test.exs`**: add a **sampling** describe (`sample_rate: 1.0` baseline retained; `0.0` ⇒ `Trace.for_request ⇒ {:error, :not_found}`; mid-rate ⇒ a request's events all-present-or-all-absent, cross-checked against `Policy.keep_trace?` on the same key) and a **sink-selection** describe using **`sink: Trace.Sink.InMemory, persist?: true` only** (InMemory is pure-memory — no sandbox needed). Drain with **`H.sync_collector()` then `H.sync_sink()`** before asserting `Sink.InMemory.all/0`/`written/1` — the InMemory `write/2` is an async cast, so the collector barrier alone isn't enough. **Do not exercise the Postgres sink here** — `collector_test.exs` has no sandbox owner, so flipping `persist?: true` with the default sink would leak async DB writes; that path is `sink/postgres_test.exs`'s job.
- **Update `trace_test.exs`**: existing `query → [OMITTED]` / `api_key → [REDACTED]` / `params → [OMITTED]` assertions are regression guards (stay green); add one assertion that a metadata string value carrying an embedded long `sk-ant-…` key is value-scrubbed even when its key isn't omitted/redacted.
- **Update `test/support/jido_claw/trace_test_helpers.ex`**: add `sync_sink/0 = GenServer.call(JidoClaw.Trace.Sink.InMemory, :__sync__)`.
- **Must pass unchanged** (default-path proof): `persistence_test.exs` (sets `persist_sync?: true`, no `:sink` ⇒ exercises the default Postgres sink via `write/2 → append/2`), `retention_sweeper_test.exs`.

---

## Risk / precommit checklist

- **Redaction regression on the 7 unseparated keys** — highest-risk; mitigated by keeping the curated `redact_exact` list as the `Policy.default()` floor (D1). The `policy_test.exs` exact-key case is the guard.
- **Stricter-default honesty** — `authorization`/`credential` keys and embedded secret values (incl. via `preview/2`, inside invalid binaries, and inside tuples) now redact. Intentional; documented in moduledocs and this plan, not sold as "unchanged."
- **No unbounded state** — sampling `keep_trace?` is recomputed not cached (D3); the InMemory sink is `max_entries`-bounded (D2). Nothing accumulates without a cap.
- **Supervision order** — strictly extended to `Persistence → Sink.InMemory → Collector`; the "writer started before producer" invariant holds for both sinks. Telemetry attach/detach lifecycle (`attach_handlers/0`, `@handler_id`, `terminate/1`) untouched.
- **`persist?` stays live** (not snapshotted) — D4; required by `trace_test.exs`/`collector_test.exs` setup.
- **Test sandbox isolation** — Postgres assertions only in the sandboxed `sink/postgres_test.exs` / `persistence_test.exs`; collector sink tests are InMemory-only (D5/P3).
- **Bad-config safety** — `resolve_sink/1` guards `is_atom` then validates `write/2`, falling back to Postgres (D5); the `policy` field is non-nil by construction (D4).
- **Reach `--smells --strict`**: InMemory uses single-take-on-prepend (distinct from the Collector's double-reverse bounded-take) and the scrub recursion is single-sourced in `Policy.scrub`, so no new clone ≥ min_mass ~30 (cf. ExSlop clone-seam memory). If `reach.check` flags `Trace.Sink.InMemory` as a `behaviour_candidate` GenServer false-positive, add it to the existing `behaviour_candidate: ignore: modules:` list in `.reach.exs` (precedent: `Trace.RetentionSweeper`). Do **not** force-unify `Policy.scrub` with `OutputRedaction.redact` (different domains).
- **Dialyzer**: `state.sink.write/2` is dynamic `module()` dispatch — type `sink :: module()`; `@callback write/2 :: :ok` + `@impl true` on both impls keeps it checkable. `policy: Policy.t()` (non-nil via `@default_policy`) so `keep_trace?`/`payload` see no `nil`. Annotate `keep_trace?/2 :: boolean()`; `from_config/1` normalizes keyword|map to one return type.
- **Credo `--strict`**: new `defp`s ≤ 11 cyclomatic; alias `Trace.Sink.{Postgres,InMemory}`; moduledoc lines ≤ 120; no `TODO`/`FIXME` tags.
- Per memory: run the **full** `mix precommit` (not just compile+test); **never pipe it through `tail`**; prefer `IO.iodata_to_binary`/iodata over `<>`-in-`Enum.join` for any added string assembly.

---

## Verification

1. `mix compile --warnings-as-errors` — clean.
2. `mix test test/jido_claw/trace/ test/jido_claw/trace_test.exs` — targeted suite green (fast inner loop).
3. `mix format` then `mix precommit` — the completion bar; fully green, zero credo/reach/dialyzer findings.
4. Live smoke via Tidewave `project_eval` (no DB row needed):
   - Redaction + value-scrub + struct: `Trace.Policy.scrub(Trace.Policy.default(), %{api_key: "x", authorization: "Basic y", note: "Bearer sk-ant-api03-AAAAAAAAAAAAAAAAAAAAAAAA", params: %{a: 1}})` ⇒ `api_key`/`authorization`/`note` scrubbed, `params` `[OMITTED]`.
   - `Trace.Sanitize.preview("Bearer sk-ant-api03-AAAAAAAAAAAAAAAAAAAAAAAA", 500)` ⇒ contains `[REDACTED]`.
   - Sampling determinism: `Trace.Policy.keep_trace?(%{Trace.Policy.default() | sample_rate: 0.0}, {:request, "r1"})` ⇒ `false`; `1.0` ⇒ `true`.
   - Sink swap: `Application.put_env(:jido_claw, :trace, [persist?: true, sink: Trace.Sink.InMemory]); restart Collector`; emit a `[:jido, :ai, :request, :start]` telemetry event; `Trace.Sink.InMemory.all/0` shows the write while Postgres is untouched.

---

## Critical files

- New: `lib/jido_claw/trace/policy.ex`, `lib/jido_claw/trace/sink.ex`, `lib/jido_claw/trace/sink/postgres.ex`, `lib/jido_claw/trace/sink/in_memory.ex`
- Modify: `lib/jido_claw/trace/sanitize.ex`, `lib/jido_claw/trace/collector.ex`, `lib/jido_claw/application.ex`, `config/config.exs`
- Tests: new `test/jido_claw/trace/policy_test.exs`, `…/sink/in_memory_test.exs`, `…/sink/postgres_test.exs`; update `…/sanitize_test.exs`, `…/collector_test.exs`, `test/jido_claw/trace_test.exs`, `test/support/jido_claw/trace_test_helpers.ex`
- Reuse (do not reinvent): `lib/jido_claw/security/redaction/env.ex` (`sensitive_key?/1`), `lib/jido_claw/security/redaction/patterns.ex` (`redact/1`), `lib/jido_claw/reasoning/compactor/summarizer.ex` (`resolve_backend/0` idiom), `lib/jido_claw/trace/persistence.ex` (wrapped by the Postgres sink)
