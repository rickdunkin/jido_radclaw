# AR-2 Composer — Phase 3: Triage seed (AR-8) — the talk/sketch/code/system front door

## Context

The AR-2 Composer (`docs/exploration/alp-river/AR-2-COMPOSER-PLAN.md`) is a deterministic,
signal-composed route composer. **Phases 0–2 are shipped** (pure router, single-run loop,
durable envelope + crash recovery — commits `92d63f2`…`6bf8e66`). The composer can run a route
end-to-end and survive a reboot, but **nothing starts it from a user turn** — its only non-test
caller today is boot recovery. There is no front door deciding *whether* a turn should compose.

**Phase 3 (§8, §14) is that front door — "AR-8 triage".** An always-on classifier reads each
user turn and picks exactly one *path*: `talk` (answer inline) / `sketch` (throwaway) / `code`
(a reviewed change) / `system` (a machine change), plus advisory early signals. `talk` (and
`sketch`, for now) stay inline — the current agent behavior, unchanged. `code`/`system` seed the
composer's live-signal set and start a durable composer run. It is sticky but re-evaluated every
turn, so a parked `talk` flips to `code` on "do it". The doc's acceptance: *"a `talk` turn never
enters the composer and 'do it' flips it to `code`; precommit green."*

This closes the gap between the static reasoning layer (which never revises) and the composer
(which can't be reached). After Phase 3, `talk` turns are identified and stay fast; `code`/`system`
turns enter the loop.

### Decisions locked in (from review)

1. **Triage is LLM-backed (faithful port of Alp River `agents/triage.md`), with a configurable
   model — via a direct `Jido.AI.generate_object/3` call, *not* a spawned worker/AgentServer.** It
   is *not* the existing heuristic `Reasoning.Classifier` (which picks a reasoning *algorithm*, not
   a conversation *type*). One structured-output call per turn, **fail-safe to `talk`** on any error.
   The model is a config knob — `config :jido_claw, :triage_model` (a direct model spec, default
   `:fast`), overridable to a cheap model — passed straight to `generate_object`'s `:model` opt
   (a literal spec bypasses `model_aliases`, so it's REPL-safe with no alias plumbing). **Tool-less**
   (classify, don't investigate), so no `tool_context`, no spawned process to leak, no recorder rows.
2. **`code`/`system` start the composer now** (matches doc §8/§14). On the *built-in* catalog a run
   gets as far as `planner`, then halts at the not-yet-built `plan-gate` (`{:gate,_}`, Phase 4) —
   full completion lands with Phase 4. End-to-end behavior is **tested on a gate-free fixture
   catalog**; production wiring is complete now.
3. **`sketch` routes inline (like talk); `system` shares the code planner/plan-gate.** The *full*
   sketch path (`.prototypes/` sandbox) and *full* system path (executor/verifier + safety gate +
   reverse-verify loop) are too large for this plan and become their own design docs —
   **`AR-8b-SKETCH-PATH.md`** and **`AR-8c-SYSTEM-PATH.md`**, authored as skeletons in this work
   (outlined in the appendices).

### Review feedback incorporated (plan-plus-code inspection)

- **P1 — composer launch failure must NOT fall through to the mutation-capable inline agent.** A
  `code`/`system` verdict whose composer fails to start returns a **bounded assistant error ack**, it
  is *not* handed to the inline main agent (which has write/run/git tools). Only `talk`/`sketch`
  (incl. triage-failure-degraded-to-`talk`, the status-quo-safe default) reach the inline path.
- **P1 — `context:` is now seeded** into `create_parent_run`/`ensure_started` (the composer threads
  it into every wave's `ReactorRunner.run`, `route_composer.ex:727,1029`), so wave workers/tools keep
  session/tenant/workspace/actor/request scope.
- **P1/P2 — no spawned triage process, no tools, no recorder rows.** Triage is a direct
  `Jido.AI.generate_object/3` call (decision 1), so there's nothing to leak, no `tool_context` to
  thread, and no tool/reasoning rows under the turn's `request_id` to flush-order on the divert branch.
- **P2 — `.jido/config.yaml` alias override is *not* claimed** (the loader doesn't read
  `model_aliases`); the knob is `config :jido_claw, :triage_model` (a direct spec). No `repl.ex:59`
  change is needed for triage.
- **P2 — handoff-preamble policy on divert is explicit** (Phase 3c): a successful divert marks the
  preamble consumed (the turn was handled), so stale handoff context never replays next turn.
- **P3 — `Verdict` drops `@enforce_keys`** (keeps the `path: :talk` default, coherent with
  fail-safe); enum outputs use **explicit string↔atom mappings** (the `reviewer.ex:28` form), never
  `String.to_atom/1`; `:set_triage_path` gets a **code-interface define** and stores path **strings**.

Second pass (after the Option-D pivot):

- **R2-P1 — `generate_object` returns a `%ReqLLM.Response{}`, not the object.** `Triage.LLM` now
  extracts via `ReqLLM.Response.unwrap_object/2` (`json_repair: true`, as `Jido.AI.Output.parse` does,
  `output.ex:109`) before `Verdict.from_map/1` — without this, every response lacked `:path` and
  silently degraded to `talk`.
- **R2-P1 — durable context for recovery.** 3b persists a JSON-safe context subset in parent config
  and restores it in `build_start_opts/2`, so a recovered composer's waves keep
  `project_dir`/workspace/session scope (it was launch-only before).
- **R2-P2 — non-empty `intent`.** The seed synthesizes `intent` from the message when the verdict's
  is blank (router availability is key-presence-based, so a `nil` intent would falsely satisfy
  `planner`).
- **R2-P2 — fail-safe moved to the façade** (`Triage.classify`), so `decide/2` can safely hard-match
  `{:ok, %Verdict{}}` and no impl (incl. a custom/test one returning `{:error,_}`) can crash a turn.
- **R2-P2 — `ensure_started/2` terminalizes its orphan on failure**, so a created-parent +
  failed-start returns a clean error ack with no lingering `:running` parent; the ack is a **short
  stable string** (the detail is logged, never `inspect(reason)` — that path bypasses redaction).
- **R2-P3 — wording fixed**: the front door is the only *user-turn* caller of `ensure_started`
  (boot recovery also calls it).

Third pass:

- **R3-P1 — don't break recovery's retry.** `ensure_started/2` orphan-terminalization is **opt-in**
  (`terminalize_on_failure?: true`, front-door only); boot recovery keeps its leave-`:running`-and-retry
  default.
- **R3-P1 — persisted context restored to atom keys.** `json_safe/1` stringifies keys, but
  `AgentRunner.resolve_scope/2` reads atoms — so `build_start_opts/2` re-atomizes a fixed whitelist
  (no `String.to_atom` on arbitrary input) before passing `:context`.
- **R3-P2 — persist `workspace_id` too** (not just `workspace_uuid`), else recovered waves get a
  `"wf_<tag>"` VFS/session key.
- **R3-P2 — ack shows a capped `preview/1`** of the intent, never the raw user message verbatim
  (the full intent still goes to the artifact).
- **R3-P3 — triage telemetry**: `[:jido_claw, :triage, :classified]` + a `jido_claw.triage.classified`
  signal (path / model / duration / fallback?), since the direct-`generate_object` route bypasses the
  recorder.

Fourth pass (compile-correctness + test tightening):

- **R4-P1 — `Verdict.@type t`** is defined (the `@callback` references `Verdict.t()`; without it the
  compile-check flags an undefined type).
- **R4-P2 — telemetry emitted by the façade, not the front door.** Only the façade both times the
  call and knows `fallback?` (whether it coerced an impl error/non-`Verdict`/crash). `Triage.classify/2`
  emits the event; the front door no longer does. `model` is the configured tier the façade reads.
- **R4-P2 — inverse recovery test** added: with **no** `:terminalize_on_failure?`, a forced
  supervised-start failure leaves the parent `:running` (boot-recovery retry preserved).
- **R3-P1/P2 test tightened**: the recovery test asserts the rebuilt `context` is **atom-keyed** and
  that **`workspace_id`** is preserved (not merely "a subset exists").

Fifth pass:

- **R5-P2 — accurate fail-safe telemetry.** `Triage.LLM` no longer self-swallows to `talk`; it
  returns `{:error, reason}` (and lets raises/exits propagate). The **façade is the sole fail-safe
  boundary** and coerces → `{:ok, talk}` while recording `fallback?: true`, so the telemetry now
  counts LLM failures instead of hiding them as a normal `talk`.
- **R5-P3 — `reasons` typed string-keyed** (`%{optional(String.t()) => String.t()}`); the keys are
  model-generated and are never atomized.
- **R5-P3 — telemetry-ownership wording** is consistent (façade, not front door) throughout §3a/§3c
  (verified — the earlier front-door phrasing was already replaced in pass 4).

Sixth pass (final hardening):

- **R6-P2 — malformed output is counted.** `Verdict.from_map/1` now returns `{:ok, verdict} |
  {:error, :invalid_verdict}`, so a valid LLM *response* carrying a **bad/absent path** surfaces as
  `{:error, :invalid_verdict}` from `Triage.LLM` and is coerced+counted (`fallback?: true`) by the
  façade — not silently emitted as a real `talk`. A genuine `"talk"` stays `fallback?: false`.
- **R6-P3 — façade catches `throw` too** (`catch _kind, _` after `rescue`), so a thrown value from
  any impl can't crash the turn.
- **R6-P3 — logs use a summarized/redacted reason** (`summarize/1`) in both `Triage.LLM` and the
  front-door launch-failure path — the error tag, not a raw provider/composer payload that could echo
  prompt/artifact text; route any detail through `JidoClaw.Security.Redaction`.

### The reconciliation that makes it clean (the one subtle part)

The built-in catalog already declares a `triage` stage as a `{:seed,"triage"}` unit
(`catalog.ex:31-47`) — but `{:seed,_}` is **not executable** (`WaveBuilder.validate_units/1`
rejects everything that isn't `{:worker_template,_}`). Triage runs **at the front door, not as a
wave**. So the front door runs triage *once*, then starts the composer **seeded as-if-triage-ran**:
the path signal + early signals + the `intent` artifact are seeded into `live`/`artifacts`, and
`triage` is seeded into **`ran`** so the composer's trigger step skips it and never asks
`WaveBuilder` to build a seed stage. The `triage` stage stays in the catalog purely so the static
producer graph is coherent (`planner` requires `intent` and subscribes `plan-needed`, both
triage's declared outputs); at runtime `triage ∈ ran` makes it inert. This is **Option (A)** from
review — faithful (the durable log honestly records triage ran + what it emitted) and cheap (~10
lines of composer code, all symmetric with the existing genesis-seed machinery).

> Rejected alternatives: (B) omit `request-received` from the seed so triage never triggers — works
> by accident, breaks if any future seed stage subscribes a path signal, and corrupts the durable
> record / projection-equivalence invariant; (C2) make the seed stage executable and run triage as
> wave 0 — would build the triage classifier *twice* and pay composer-start before knowing the turn
> is `talk`, contradicting "talk never enters the composer".

---

## Architecture (one diagram)

```
user turn
  │  run_chat_turn/8 (lib/jido_claw.ex)  OR  repl.ex handle_message/2
  │  …register_correlation → add_message(:user) →
  ▼
JidoClaw.FrontDoor.decide(message, ctx)            ← the single shared front door
  │  verdict = Triage.classify(message, history:…)  (Jido.AI.generate_object, fail-safe → talk)
  │  persist Session.metadata["last_triage_path"]   (observability)
  ├── talk | sketch ──────────────► dispatch_inline/…  (today's path, byte-for-byte unchanged)
  └── code | system ──────────────► seed + start composer
                                       live      = ["request-received", path, "plan-needed", …mapped signals]
                                       artifacts = %{"request"=>%{"seed"=>msg}, "intent"=>%{"triage"=>intent}}
                                       ran       = ["triage"]               ← Option (A)
                                       context   = scope map (tenant/session/workspace/actor/…)  ← P1
                                       RouteComposer.create_parent_run/1 → ensure_started/2 (durable, supervised)
                                       ├─ {:ok, parent} ─► assistant ack "Starting a <path> run (run …)"
                                       └─ {:error, _}  ─► bounded error ack (NEVER inline; P1 safety)
```

---

## Phase 3a — The triage classifier (LLM-backed, configurable model, no AgentServer)

Self-contained and testable without the composer or a real LLM. New files under `lib/jido_claw/triage/`.
**Triage is a direct `Jido.AI.generate_object/3` call — no spawned worker, no tools, no `tool_context`,
no recorder rows** (resolves the leak / scoped-context / recorder findings at the root).

**`lib/jido_claw/triage/verdict.ex`** — the result struct + normalizer (pure). No `@enforce_keys`
(the `path: :talk` default is the fail-safe shape). `from_map/1` tolerates **string- or atom-keyed**
maps, validates the path against a fixed whitelist (never `String.to_atom/1`), and returns **`{:ok,
verdict} | {:error, :invalid_verdict}`** — so a *malformed* model output (bad/absent path) is a
distinguishable error the façade can **count as a fallback**, not silently a `talk` (R6-P2). A model
that genuinely said `"talk"` is `{:ok, talk-verdict}` (correctly *not* a fallback).
```elixir
defmodule JidoClaw.Triage.Verdict do
  @type path :: :talk | :sketch | :code | :system
  @type t :: %__MODULE__{path: path(), signals: [atom()], est_size: atom() | nil,
                         intent: String.t() | nil, intent_confirmed?: boolean(),
                         reasons: %{optional(String.t()) => String.t()}}   # R4-P1 type; R5-P3: reasons
                         #   keys are model-generated/dynamic → stay STRING-keyed (never atomized)
  defstruct path: :talk, signals: [], est_size: nil, intent: nil, intent_confirmed?: false, reasons: %{}

  def talk(intent \\ nil), do: %__MODULE__{path: :talk, intent: intent}
  def composer?(%__MODULE__{path: p}), do: p in [:code, :system]

  @paths %{"talk" => :talk, "sketch" => :sketch, "code" => :code, "system" => :system}
  # generate_object returns string-keyed JSON; normalize at the boundary with an explicit
  # whitelist (no String.to_atom). A bad/absent path → {:error, :invalid_verdict} (counted, R6-P2).
  @spec from_map(term()) :: {:ok, t()} | {:error, :invalid_verdict}
  def from_map(%{} = out) do
    case @paths[to_string(get(out, :path) || get(out, "path"))] do
      nil -> {:error, :invalid_verdict}
      p   -> {:ok, %__MODULE__{path: p, signals: norm_signals(get2(out, :signals)),
                  est_size: norm_size(get2(out, :est_size)), intent: get2(out, :intent),
                  intent_confirmed?: get2(out, :intent_confirmed) == true, reasons: get2(out, :reasons) || %{}}}
    end
  end
  def from_map(_), do: {:error, :invalid_verdict}
  # norm_signals/norm_size map known strings → atoms via fixed whitelists; unknown values dropped.
end
```

**`lib/jido_claw/triage.ex`** — behaviour + façade. **The façade is the single fail-safe boundary**
(R2-P2) **and the single telemetry point** (R4-P2): it coerces *any* impl's `{:error,_}`,
non-`Verdict`, raise, or exit to `{:ok, talk}`, so `FrontDoor.decide/2` can hard-match `{:ok,
%Verdict{}}` and no impl can crash a turn — and, because it's the only layer that both times the call
*and* knows whether it had to coerce, it (not the front door) emits the telemetry. Test-injection
seam mirrors `:ask_runtime` (`lib/jido_claw.ex:154`).
```elixir
defmodule JidoClaw.Triage do
  @callback classify(String.t(), keyword()) :: {:ok, JidoClaw.Triage.Verdict.t()} | {:error, term()}
  def classify(message, opts \\ []) when is_binary(message) do
    start = System.monotonic_time()
    {verdict, fallback?} =
      try do
        case impl().classify(message, opts) do
          {:ok, %Verdict{} = v} -> {v, false}
          _ -> {Verdict.talk(), true}
        end
      rescue _ -> {Verdict.talk(), true}
      catch _kind, _ -> {Verdict.talk(), true}   # R6-P3: covers :throw and :exit (not just :exit)
      end
    :telemetry.execute([:jido_claw, :triage, :classified],
      %{duration_ms: ms_since(start)},
      %{path: verdict.path, fallback?: fallback?, model: triage_model()})   # also SignalBus.emit("jido_claw.triage.classified", …)
    {:ok, verdict}
  end
  defp impl, do: Application.get_env(:jido_claw, :triage_impl, JidoClaw.Triage.LLM)
  defp triage_model, do: Application.get_env(:jido_claw, :triage_model, :fast)  # the configured tier, shared with Triage.LLM
end
```
(`fallback?` counts **any** non-`{:ok, %Verdict{}}` from the impl — an `{:error,_}`, a non-`Verdict`,
or a raise/exit — so it accurately measures the fail-safe rate, *including* `Triage.LLM` failures
(R5-P2). `model` is the configured tier, useful even when a stub impl is active in tests.)

**`lib/jido_claw/triage/llm.ex`** — the default impl: one `Jido.AI.generate_object/3` call
(`jido_ai.ex:290`), **no process spawned**. **`generate_object` returns `{:ok, %ReqLLM.Response{}}`,
not the object** — extract it with `ReqLLM.Response.unwrap_object/2` (`response.ex:556`,
`json_repair: true`, exactly as `Jido.AI.Output.parse` does at `output.ex:109`), which yields a
**string-keyed** map for `Verdict.from_map/1` (R2-P1 — without this every response would lack `:path`
and degrade to `talk`). **The impl does NOT self-swallow to `talk` (R5-P2)** — it returns
`{:error, reason}` on failure and lets raises/exits propagate; the **façade is the sole fail-safe
boundary** and is what coerces → `{:ok, talk}` *and* records `fallback?: true`. (A self-swallowing
impl would hide its own failures as `fallback?: false` and undercount the fail-safe rate.)
```elixir
def classify(message, opts) do
  with {:ok, resp} <- gen().(Prompt.user(message, opts[:history] || []), Schema.zoi(),
                        model: resolve_model(), system_prompt: Prompt.system(),
                        max_tokens: 700, temperature: 0.0, timeout: triage_timeout()),
       {:ok, obj}  <- ReqLLM.Response.unwrap_object(resp, json_repair: true),
       {:ok, v}    <- Verdict.from_map(obj) do    # malformed/absent path → {:error, :invalid_verdict} (R6-P2)
    {:ok, v}
  else
    {:error, reason} = err -> Logger.debug("[Triage.LLM] degraded: #{summarize(reason)}"); err
    other -> {:error, {:unexpected, other}}   # never self-coerce to talk — the façade does that + counts it
  end
  # NOTE: no rescue/catch here — a raise/exit propagates to the façade, which coerces + counts it.
  # summarize/1 (R6-P3): a short, redacted reason — the error tag/type, NOT a raw provider payload
  # that may echo prompt/artifact text; route any detail through JidoClaw.Security.Redaction.
end

# Configurable model — a DIRECT model spec (default :fast). A literal like
# "anthropic:claude-haiku-4-5" bypasses model_aliases entirely, so it's REPL-safe with no alias
# plumbing (mirrors LLMBackend.resolve_model/1, llm_backend.ex:51).
defp resolve_model, do: Application.get_env(:jido_claw, :triage_model, :fast)
# Seam so a test can inject a failing/canned generate without a real LLM (mirrors :ask_runtime).
defp gen, do: Application.get_env(:jido_claw, :triage_generate, &Jido.AI.generate_object/3)
```

**`lib/jido_claw/triage/schema.ex`** — `zoi/0`, the structured-output contract, with **explicit
string↔atom enum mappings** (the `reviewer.ex:28` form), so the validated object is atom-safe by
construction:
```elixir
def zoi do
  Zoi.object(%{
    "path" => Zoi.enum(talk: "talk", sketch: "sketch", code: "code", system: "system"),
    "signals" => Zoi.array(Zoi.enum(ambiguous: "ambiguous", bug: "bug", novel_domain: "novel-domain",
                   multi_file: "multi-file", auth_surface: "auth-surface", secrets: "secrets",
                   perms_change: "perms-change", destructive_op: "destructive-op", irreversible: "irreversible",
                   needs_tests: "needs-tests", significant_build: "significant-build", scope_shift: "scope-shift")),
    "est_size" => Zoi.enum(xs: "XS", s: "S", m: "M", l: "L", xl: "XL", xxl: "XXL"),
    "intent" => Zoi.string(), "intent_confirmed" => Zoi.boolean(),
    "reasons" => Zoi.map(Zoi.string(), Zoi.string())
  })
end
```
(`Verdict.from_map/1` re-normalizes regardless, so atom/string drift from the provider can't break it.)

**`lib/jido_claw/triage/prompt.ex`** — `system/0` (static, cache-friendly) carries the faithful port
of Alp River's `agents/triage.md`: paths defined by *what they leave behind*; `bug` is a signal not
a path; the early-signal list with one-line "why"; `intent_confirmed` + a crisp `intent` only on a
clear ask; advisory `est_size`; the **stickiness instruction** ("you are re-run every turn; a parked
`talk` + 'do it'/'go ahead' re-reads as `code`/`system` against the prior proposal"); and the
**prefer-`talk`-when-uncertain** rule. `user(message, history)` renders a bounded, truncated
recent-history window (≤6 turns) then the latest turn. History comes from
`JidoClaw.Session.Worker.get_messages/2` (`platform/session/worker.ex:105`). **Tool-less** — triage
classifies from the message + history, it does not read the codebase (deeper sensing is a future
refinement; keeps it cheap and avoids needing a scoped `tool_context`).

### Configurable model (the Q1 refinement)

`config :jido_claw, :triage_model` — a **direct model spec**, default `:fast` (so it works out of the
box, resolving to the user's model), overridable to a cheap model (e.g.
`config :jido_claw, :triage_model, "anthropic:claude-haiku-4-5"`). Passed straight to
`generate_object`'s `:model`. A literal spec bypasses `model_aliases`, so **no `repl.ex:59` change is
needed** and the `.jido/config.yaml` loader (which doesn't read `model_aliases`,
`core/config.ex:58`) is not relied on. Precedent: `LLMBackend.resolve_model/1` (`llm_backend.ex:51`).

**`test/support/triage_stub.ex`** — `JidoClaw.Test.TriageStub` implementing the `Triage` behaviour:
returns a canned `%Verdict{}` from `Application.get_env(:jido_claw, :triage_canned_verdict, …)`,
supporting a `fun/1` value for per-message verdicts (so a stickiness test can return `talk` for
turn 1 and `code` for `"do it"`), and optionally messages a capture target. This makes the **entire
front door deterministically testable without a real LLM** — exactly Alp River's philosophy (the
LLM judgment is untestable; the *contract* and the *routing decision* are what we assert).

---

## Phase 3b — Composer pre-run seeding + durable-context support

Small, symmetric changes in **`route_composer.ex`**, mostly mirroring the existing genesis-seed /
config-restore machinery. `Projection` and `WaveBuilder` stay **unchanged** (the projection already
folds `ran` from `wave_completed`; keeping `WaveBuilder` strict is what surfaces the Phase-4 gate
boundary loudly).

**`lib/jido_claw/route_composer/route_composer.ex`**
- **Pre-run `ran` (Option A).** `init/1` (line ~719): `ran: MapSet.new()` →
  `ran: MapSet.new(Keyword.get(opts, :ran, []))`. `append_genesis_seed/4` (line ~354): add a third
  leg `append_genesis_ran/4` that, when `:ran` is non-empty, appends a **genesis `wave_completed`**
  via the existing `append_genesis_event/5`: `%{wave_index: -1, stages: Enum.sort(ran)}`. The
  projection's `wave_completed` fold (`projection.ex:75-83`) unions the stages into `ran` and
  `advance_wave_index(-1) = max(0,0) = 0`, so the first real wave is still wave 0. `wave_completed`
  is non-status-authority (`commit.ex:14-24`), appended after `run_started` flips `:running`, so
  it's transaction-legal. At **recovery**, opts carry no `:ran` — the genesis event rebuilds
  `ran=["triage"]` (identical to launch), preserving projection-equivalence. `:ran` rides
  `run_sync`/`ensure_started`/`start_composer` opts untouched.
- **Durable context (R2-P1 — recovery must keep scope), restored to ATOM keys (R3-P1).** Today
  `context:` is launch-only; `workflow_recovery.ex:376` restarts a composer with just `tenant`/`actor`,
  and `build_start_opts/2` (`:552`) restores catalog/premises/bounds but **not** context — so after a
  BEAM restart, wave workers lose scope. Fix, symmetric with premises/catalog: `parent_config/3`
  (`:316`) stores a **JSON-safe context subset** through the same `json_safe/1` boundary premises use
  (which **stringifies atom keys**, `route_composer.ex:1193`), and `build_start_opts/2` restores it.
  **Crucially, the restore must re-atomize a fixed whitelist of known keys** — `AgentRunner.resolve_scope/2`
  reads **atom** keys (`context[:session_uuid]`, `[:workspace_id]`, `[:project_dir]`, …,
  `agent_runner.ex:305-315`); a string-keyed restored context would silently hit the
  `workspace_id → "wf_<tag>"` / `project_dir → File.cwd!()` fallbacks. So add a `restore_context/1`
  that maps **only** the known string keys → atoms (no `String.to_atom` on arbitrary input) and use it
  in `build_start_opts/2`; running it on both launch and recovery (config is authoritative) keeps the
  composer's context atom-keyed and identical across a reboot.
  - **Whitelist (R3-P2 — include `workspace_id`):** `project_dir, tenant_id, session_id,
    session_uuid, workspace_id, workspace_uuid, user_id, agent_id, agent_template`. Both
    `workspace_id` **and** `workspace_uuid` are persisted — the inline turn sets `workspace_id` to the
    session_id string (`lib/jido_claw.ex:246`) and `AgentRunner` falls back to `"wf_<tag>"` without it
    (`agent_runner.ex:310`), so omitting it would give recovered waves a different VFS/session key.
    The live `actor`/pids are **not** persisted — recovery supplies its own (the established
    system-actor pattern); `seed_wave_context` re-wraps the restored base with the recovered
    deadline/marker.
- **`ensure_started/2` — opt-in orphan terminalization (R3-P1; preserves recovery retry).**
  `start_composer/2` terminalizes the parent on a start failure (`:452`), but supervised
  `ensure_started/2` (`:474`) does **not** — and that's **intentional for boot recovery**, which calls
  `ensure_started/2` and leaves the parent `:running` on a transient blip so the next boot retries
  (`workflow_recovery.ex:376`). So terminalization is **opt-in**, not unconditional: `ensure_started/2`
  honors `opts[:terminalize_on_failure?]` (default `false` ⇒ recovery's retry behavior unchanged); the
  **front door passes `true`** so a `create_parent_run` success + failed start yields a clean terminal
  parent behind the "couldn't start" ack. (Reuses the private `terminalize_parent` the unlinked path
  already calls.)
- Doc the `:ran` opt, the persisted+atomized context, and the `:terminalize_on_failure?` opt in the
  `@doc`s.

**`lib/jido_claw/route_composer/catalog.ex`** — expand the `triage` stage's `publishes` to the full
early-signal vocabulary the Verdict can carry (`needs-tests, significant-build, auth-surface,
secrets, perms-change, multi-file, novel-domain, bug, ambiguous, destructive-op, irreversible,
scope-shift` + the path topics). Publishes need no consumer (only *consumed* signals need a
producer), so this stays validator-clean and makes the seeded "triage emission" coherent with its
declared contract. Compile-time `CatalogValidator.validate/1` still returns `[]` (it runs over the
static graph; runtime seeds don't affect it).

**`test/support/jido_claw/route_composer/fixtures.ex`** — add a **gate-free**
`triage_seeded_fixture_catalog/0` (modeled on `phase1_catalog/0` but with a `{:seed,"triage"}` stage
and `planner` subscribing `plan-needed`/requiring `intent`), plus `triage_seed_live/0` /
`triage_seed_artifacts/0` and the `ran: ["triage"]` helper. This is the catalog the end-to-end
seeding/reconciliation tests run on (the built-in catalog can't converge until Phase 4).

---

## Phase 3c — The front door + wire both turn seams

**`lib/jido_claw/front_door.ex`** — the single shared decision point, and the only **user-turn**
caller of `create_parent_run`/`ensure_started` (boot recovery, `workflow_recovery.ex:376`, also calls
`ensure_started` — R2-P3).
`decide/2` returns one of three tags — `{:inline, verdict}` (talk/sketch, incl. triage-failure→talk),
`{:composer, {:ok, resp}}` (launched), or `{:composer, {:error, resp}}` (a **bounded error ack** —
*not* a fall-through to the inline agent):
```elixir
def decide(message, ctx) do
  history = recent_history(ctx, message)                 # Session.Worker.get_messages, drop trailing dup, take last 6
  {:ok, %Verdict{} = verdict} = Triage.classify(message, history: history)  # classify/2 is fail-safe → {:ok, talk}
  persist_path(ctx, verdict.path)                        # Session.metadata["last_triage_path"] (best-effort)
  if Verdict.composer?(verdict), do: {:composer, start_composer(message, verdict, ctx)},
                                 else: {:inline, verdict}
end
```
`start_composer/3` builds the **Option (A) seed** (including the load-bearing **`context:`** scope
map the composer threads into every wave, `route_composer.ex:727,1029`) and launches supervised:
```elixir
intent = present(verdict.intent) || message    # R2-P2: never a blank/nil intent (see below)
opts = [tenant: ctx.tenant_id, actor: actor(ctx), name: "composer", catalog: Catalog.all(),
        live:      ["request-received", path_topic(verdict), "plan-needed"] ++ mapped_signals(verdict),
        artifacts: %{"request" => %{"seed" => message}, "intent" => %{"triage" => intent}},   # FULL intent stored
        ran:       ["triage"],
        context:   composer_context(ctx),                # P1: project_dir/tenant/session_id/workspace_id+uuid/user (atom keys)
        terminalize_on_failure?: true,                   # R3-P1: front-door launch cleans its orphan; recovery does not
        premises:  %{"path" => to_string(verdict.path), "est_size" => to_string(verdict.est_size)}]
with {:ok, parent} <- RouteComposer.create_parent_run(opts),
     {:ok, _pid}   <- RouteComposer.ensure_started(opts, parent) do
  {:ok, %{path: verdict.path, parent_run_id: parent.id,
          message: "Starting a #{verdict.path} run for: #{preview(intent)} (run #{parent.id})."}}  # R3-P2: capped preview, not raw msg
else
  {:error, reason} ->
    # P1 SAFETY: a confident code/system verdict whose run won't start does NOT fall through to the
    # mutation-capable inline main agent. R2-P2: return a SHORT stable string (this path bypasses the
    # tool redaction/shaping pipeline, so never inspect(reason) into the ack). R6-P3: log a SUMMARIZED
    # reason (the error tag) — a composer-start reason can carry artifact/payload data; route any
    # detail through JidoClaw.Security.Redaction rather than a raw inspect.
    Logger.warning("[FrontDoor] composer launch failed: #{summarize(reason)}")
    {:error, %{path: verdict.path,
               message: "I classified this as a #{verdict.path} change but couldn't start the run (it's been logged). It was not run through the chat agent — please retry."}}
end
```
- **`context:` (P1)** — `composer_context(ctx)` is the **atom-keyed** scope subset (project_dir,
  tenant_id, session_id, session_uuid, **workspace_id**, workspace_uuid, user_id, agent_id/template)
  the inline turn's `ToolContext.build` assembles; without it the composer's wave workers/tools lose
  scope. 3b persists this subset in parent config and **re-atomizes it on restore** so recovery keeps
  scope too (R2-P1/R3-P1); `workspace_id` is included because `AgentRunner` otherwise falls back to
  `"wf_<tag>"` (R3-P2).
- **`intent` is load-bearing AND must be non-empty (R2-P2).** `planner` requires the `intent`
  artifact, and the router's availability is **key-presence based** (`fold.ex:38`) — so a seeded
  `%{"intent" => %{"triage" => nil}}` would *satisfy* the requirement while carrying nothing, and
  `planner` would run blind. The front door synthesizes a non-empty intent — the verdict's crisp
  `intent` when present, else the raw user `message` (`present/1` treats `nil`/`""`/whitespace as
  absent). The **full** intent is stored in the artifact; the assistant **ack shows a capped
  `preview/1`** (≤~120 chars), never the raw message verbatim (R3-P2). If missing, drop-unsatisfiable
  would silently drop `planner` → empty route → false `:converged`; the seeding test asserts wave 0
  == `["planner"]` and a non-empty stored `intent`.
- **Signal mapping** (`mapped_signals/1`): Verdict signal atom → composer topic string
  (`:needs_tests→"needs-tests"`, `:auth_surface→"auth-surface"`, …), intersected with the `triage`
  stage's declared `publishes` for coherence. `"plan-needed"` is always seeded for code/system (it's
  triage's catalog publish that `planner` subscribes — without it the route is empty and falsely
  converges).
- **`ensure_started` failure is clean (R2/R3):** the front door passes `terminalize_on_failure?: true`,
  so a `create_parent_run` success + failed start terminalizes the orphan parent — no lingering
  `:running` run behind the "couldn't start" ack. (Boot recovery omits the opt and keeps its retry
  behavior — 3b.) A test asserts the parent ends terminal (not `:running`) on a forced failure.
- **Telemetry (R3-P3 / R4-P2):** since triage bypasses the AgentServer/tool/recorder pipeline, the
  **`Triage` façade** (not the front door — it's the only layer that times the call *and* knows
  `fallback?`) emits one event per classification: `[:jido_claw, :triage, :classified]` with
  `%{duration_ms: …}` and `%{path:, model:, fallback?:}` (plus a parallel
  `JidoClaw.SignalBus.emit("jido_claw.triage.classified", …)`, mirroring the existing
  `jido_claw.reasoning.classified`, `cli/commands.ex:809`) so verdict path / latency / fail-safe rate
  / model are observable.

**Stickiness** = per-turn re-classification + recent history (faithful to Alp River). The prior path
is **not** read to decide — the fresh verdict is; `metadata["last_triage_path"]` is observability /
cold-start only. "do it" flips `talk`→`code` because the classifier sees the prior assistant
proposal + "do it" in the same prompt. A new `:set_triage_path` update action on the Session resource
reuses the existing `Changes.SetMetadataKey` (`conversations/resources/session.ex:296`, already
backing `:set_current_agent_template`/`:set_prompt_snapshot`) with key `"last_triage_path"` — **no new
change module**, **stores the path as a string** (`to_string(path)`, never an atom at the JSON
boundary), and **adds a code-interface line** (`define(:set_triage_path, action: :set_triage_path,
args: [:path])`, beside `:set_current_agent_template` at `session.ex:54`) so callers use
`Session.set_triage_path/3`.

**Wiring (keep the inline path byte-for-byte unchanged).** At each seam, insert exactly one branch
after `add_message(:user)` / before dispatch; extract today's dispatch into a private
`dispatch_inline/…` and gate it. **Only `{:inline, _}` reaches `dispatch_inline`**; both
`{:composer, {:ok, _}}` and `{:composer, {:error, _}}` render their `resp.message` as the assistant
response and **never** hit the inline mutation-capable agent (P1).
- **`lib/jido_claw.ex` `run_chat_turn/8`** (after line 238, before line 261): on either composer tag,
  write the assistant `resp.message` row and return `{:ok, resp.message}` — **no caller signature
  change** (web/discord/cron/api via `chat/4` already handle `{:ok, String.t()}`). On a post-handoff
  turn, **mark the preamble consumed** (`HandoffRouter.mark_preamble_consumed_on_success/5` with the
  ack as the success result) so stale handoff context doesn't replay next turn (P2). **Recorder
  ordering (P2):** the divert branch creates no tool/reasoning rows under the turn's `request_id`
  (triage is a direct `generate_object` call, not an agent), so the ack row has nothing to order
  against — no `Recorder.flush` needed (the barrier stays inside `dispatch_inline`, which holds
  today's body from `ask_sync` line 261 → `handle_response/4` line 284, moved verbatim).
- **`lib/jido_claw/cli/repl.ex` `handle_message/2`** (after line 389, before line 413): on either
  composer tag, `Display.stop_thinking()` + `Formatter.print_answer(resp.message)` + assistant row +
  mark-preamble-consumed + return `state`. `dispatch_inline/…` is today's body from
  `prepare_user_message` (391) through the `Agent.ask` case (413-455), moved verbatim (so the
  strategy-hint prepend stays inline-only).

> Phase-3 UX reality (honest): a `code`/`system` turn returns an ack and the composer runs durably in
> the **background**. Live composer→REPL/chat progress streaming is **Phase 5 (Observe over MCP)**.
> On the **built-in** catalog the run executes `planner` then halts at the unbuilt `plan-gate`
> (Phase 4). This is the correct incremental milestone; the front door is fully wired now and
> completes when Phase 4 lands.

### Explicitly out of scope for Phase 3 (stated, not hidden)

These are *not* deferrals-within-the-unit (Phase 3 is complete for what it covers) — they are
separate concerns with clear future homes, named so the boundary isn't implicit:

- **Live composer→surface streaming** — the ack is the Phase-3 response; rendering wave/route
  progress back into the REPL/chat is **Phase 5 (Observe over MCP, §10.2)**.
- **Follow-up turns while a run is active / mid-run path switch** — each `code`/`system` turn
  triages and starts its **own** run (the `RouteComposer.Registry` is keyed per `parent_run_id`, so
  this is safe, not a crash). Coordinating multiple runs per session, or re-triaging into an
  *already-running* composer and switching its path (Alp River's full cross-turn stickiness), needs
  the subtractive path-switch semantics (`signals_retracted`) and is a future **"AR-8d — sticky path
  re-evaluation across turns"** doc. Phase 3 stickiness is the per-turn *pre-launch* re-classification
  the §14 acceptance requires ("do it" flips a parked `talk` to `code`).
- **`est-size` as a gate** — triage emits `est_size` and it's captured in `premises`, but it is
  **advisory only** in Phase 3. Its one load-bearing use (trivial-code plan auto-approval, Alp River
  `WORKFLOW.md`) belongs to **Phase 4 (gates)**.

---

## Phase 3d — Tests, sub-docs, precommit green

All front-door tests inject `:triage_impl = TriageStub` (no real LLM). Mirror Alp River: assert the
**routing decision + seeding contract**, never the LLM's judgment.

- **`test/jido_claw/front_door_test.exs`** — `talk`→`{:inline,_}`, no `composer` `WorkflowRun` row;
  `code`/`system`→`{:composer, {:ok, %{parent_run_id: id}}}` + a `:running` `composer` run exists
  with the seeded `context`/`ran`/`live`; `sketch`→inline; triage sees the history window (excludes
  the current turn). **P1 safety:** a `code` verdict whose `create_parent_run` is forced to
  `{:error,_}` returns `{:composer, {:error, _}}` (a bounded ack) and the **inline agent is never
  invoked** (assert via the `:ask_runtime` echo stub receiving nothing); the ack string contains **no
  `inspect(reason)`** (R2-P2). **R2-P2 intent:** a `code` verdict with a blank `intent` seeds the
  stored `intent` artifact = the user message (non-empty), wave 0 == `["planner"]`, and the success
  ack shows a **capped preview** (a long message is truncated in the ack, R3-P2). **R3-P1 orphan:** a
  forced `ensure_started` failure (after a created parent) leaves the parent **terminal, not
  `:running`** (front door passes `terminalize_on_failure?: true`).
- **`test/jido_claw/front_door_stickiness_test.exs`** — **the §14 acceptance**: a `fun/1` stub
  returns `talk` for turn 1, `:code` for `"do it"`; turn 1 → no composer, turn 2 → composer started.
  Plus: path persisted to `metadata["last_triage_path"]` (as the string `"code"`).
- **`test/jido_claw/triage_test.exs`** — `Verdict.from_map/1` returns `{:ok, %Verdict{}}` for a
  **string-keyed** object and an atom-keyed one, and **`{:error, :invalid_verdict}`** for a
  malformed/absent path; `reasons` stays **string-keyed** (R5-P3). **R2-P1:** `Triage.LLM` with a
  `:triage_generate` returning `{:ok, %ReqLLM.Response{object: %{"path"=>"code", …}}}` unwraps +
  normalizes to `%Verdict{path: :code}` (proves the response isn't mistaken for the object). **R5-P2:**
  `Triage.LLM` does **not** self-coerce — a `:triage_generate` returning `{:error,:timeout}` makes
  `Triage.LLM.classify` return `{:error, :timeout}`, and the **façade** `Triage.classify` turns *that*
  (and a non-`Verdict`, a raising impl, **and a throwing impl** — R6-P3) into `{:ok, %Verdict{path:
  :talk}}`. **R6-P2:** a response whose object has a **bad/absent path** makes `Triage.LLM.classify`
  return `{:error, :invalid_verdict}` (malformed output isn't a silent `talk`), while a genuine
  `"path"=>"talk"` object is `{:ok, talk}`. **R3-P3/R4-P2 telemetry:** attach a `:telemetry` handler
  and assert the façade emits one `[:jido_claw, :triage, :classified]` event per call with
  `path`/`model`/`fallback?` — `fallback? == false` on a genuine `{:ok, verdict}` (incl. a real
  `talk`) and `fallback? == true` on `{:error,_}`/raising/throwing/**malformed-output** impls.
- **`test/jido_claw/route_composer/composer_loop_test.exs`** (extend) — drive `run_sync/1` on
  `triage_seeded_fixture_catalog/0` with the Option-(A) seed: assert `:converged`, `"triage" ∈ ran`
  **and** `triage` never appears in any history wave's `stages` (pre-run, never dispatched), wave 0
  == `["planner"]` (proves `intent`/`plan-needed` seeded correctly), and the parent log carries the
  genesis `wave_completed(wave_index: -1, stages: ["triage"])`.
- **Built-in-catalog boundary test** — drive `run_sync/1` on `Catalog.all()` with the seed: assert
  it does **not** fail with a triage/`{:seed,_}` error (reconciliation works on the real catalog),
  and **does** fail with `{:unsupported_unit, "plan-gate", {:gate,"plan"}}` after `planner` — pinning
  the exact Phase-3/Phase-4 boundary.
- **Recovery faithfulness** (extend the durable suite) — kill mid-route, restart; rebuilt state has
  `triage ∈ ran` from the genesis event (no `:ran` opt at recovery), so triage never re-triggers; and
  (R2-P1/R3-P1/R3-P2) the rebuilt `context` is **atom-keyed** and carries the persisted scope —
  explicitly assert `context[:project_dir]`, `context[:session_uuid]`, and **`context[:workspace_id]`**
  match the launch values (atom keys, not string keys; `workspace_id` present), proving a recovered
  `code` run keeps the *same* VFS/session scope rather than the `"wf_<tag>"` fallback.
- **`ensure_started/2` recovery default (R4-P2)** — the *inverse* of the front-door orphan test: with
  **no** `:terminalize_on_failure?` opt, a forced supervised-start failure (after a created parent)
  leaves the parent **`:running`** (so boot recovery's next-boot retry is preserved). Guards against a
  regression where the opt-in cleanup silently becomes unconditional.
- **Inline-path-unchanged regression** — `talk` stub + the existing echo `:ask_runtime` stub ⇒ the
  echo answer still returns through `chat/4` (proves the extraction didn't alter the inline path).

**Sub-docs** (per Q3 — author the skeletons): create
`docs/exploration/alp-river/AR-8b-SKETCH-PATH.md` and `docs/exploration/alp-river/AR-8c-SYSTEM-PATH.md`
with the content in the appendices below.

**Precommit** (the bar; toolchain `mise exec -- mix`): `mix precommit` runs `jidoclaw.compile_check`
(allowlist empty ⇒ warnings-as-errors) → `system_prompt.check` → `deps.unlock --unused` → `format
--check-formatted` → `reach.check --arch --smells --strict` → `credo --strict` → `dialyzer` →
`test`. Watch: `reach` `fixed_shape_map` on the new opts/response maps (scope `JidoClaw.FrontDoor`
in `.reach.exs` ignore list — the established escape hatch, used for `JidoClaw`/`Session.Worker` —
or use a struct); dialyzer on `generate_object`'s `{:ok, term()}` (the `Verdict.from_map/1` catch-all
makes it total); any AshCredo finding on the new `:set_triage_path` action (it reuses an existing
change, so unlikely).

---

## Verification (end to end)

1. **Baseline green** before edits: `mise exec -- mix precommit` (run bare in the background; read
   the tail — never pipe through `tail`, which masks the exit code).
2. **Unit/inner loop** as each phase lands: `mise exec -- mix test test/jido_claw/triage_test.exs
   test/jido_claw/front_door_test.exs test/jido_claw/front_door_stickiness_test.exs
   test/jido_claw/route_composer/composer_loop_test.exs`.
3. **Manual REPL smoke** (the live acceptance): `mise exec -- mix jidoclaw`, then
   - a `talk` turn ("how does the composer seed live signals?") → answered inline, fast, no run
     created (`SELECT count(*) FROM workflow_runs WHERE workflow_type='composer'` unchanged — via
     Tidewave `execute_sql_query`).
   - "implement a foo/0 that returns :ok" → an ack "Starting a code run … (run …)"; a `:running`
     `composer` `WorkflowRun` exists; it runs `planner` then halts at the `plan-gate` (expected,
     Phase 4). Inspect via `mcp__tidewave__execute_sql_query` / the existing `workflow_status` tool.
   - a `talk` turn then "do it" → the second turn flips to `code` and starts a run (stickiness).
   `:triage_impl` is **not** set here — this exercises the real classifier; set
   `config :jido_claw, :triage_model` to a cheap model first.
4. **Full gate (the bar):** `mise exec -- mix precommit` ends green. If a flake appears in the full
   suite, re-verify the suspect file **in isolation** (not `--seed 0`) before blaming these changes
   (known flaky set: async singletons — MCPServer/Prompt/PipelineStore/MultiSandbox — none touched).

---

## Critical files

| Concern | File | Change |
| --- | --- | --- |
| Triage result + normalizer | `lib/jido_claw/triage/verdict.ex` | new (no `@enforce_keys`; string/atom-tolerant `from_map/1`) |
| Triage behaviour + seam | `lib/jido_claw/triage.ex` | new (`@callback`; fail-safe boundary; emits `[:jido_claw,:triage,:classified]` telemetry) |
| Default impl (`generate_object`, fail-safe) | `lib/jido_claw/triage/llm.ex` | new (no AgentServer, no tools) |
| Structured-output schema | `lib/jido_claw/triage/schema.ex` | new (explicit enum string↔atom mappings) |
| Ported prompt | `lib/jido_claw/triage/prompt.ex` | new (`system/0` + `user/2`) |
| Configurable model | `config/config.exs` (or `config/runtime.exs`) | `config :jido_claw, :triage_model` (direct spec; default `:fast`) — no `repl.ex`/alias change |
| Front door | `lib/jido_claw/front_door.ex` | new (seeds atom-keyed `context:` + `terminalize_on_failure?`; launch-failure → capped error ack, never inline) |
| Wire programmatic seam | `lib/jido_claw.ex:179-292` | extract `dispatch_inline`, gate divert + mark-preamble-consumed |
| Wire REPL seam | `lib/jido_claw/cli/repl.ex:350-456` | extract `dispatch_inline`, gate divert + mark-preamble-consumed |
| Pre-run seeding + durable context + clean orphan | `lib/jido_claw/route_composer/route_composer.ex` (`init/1` ~719, `append_genesis_seed/4` ~354, `parent_config/3` ~316, `build_start_opts/2` ~552, `ensure_started/2` ~474) | `:ran` opt + genesis `wave_completed(-1)`; persist + **re-atomize-on-restore** `context` subset incl. `workspace_id` (R2-P1/R3-P1/R3-P2); **opt-in** `terminalize_on_failure?` orphan cleanup (R3-P1) |
| Triage publishes vocab | `lib/jido_claw/route_composer/catalog.ex:38-46` | expand `publishes` |
| Stickiness store | `lib/jido_claw/conversations/resources/session.ex` (`:54`, `:296`) | add `:set_triage_path` action + code-interface define (reuse `Changes.SetMetadataKey`; store string) |
| Fixtures | `test/support/jido_claw/route_composer/fixtures.ex` | gate-free triage-seeded catalog + seeds |
| Test stub | `test/support/triage_stub.ex` | new |
| Tests | `test/jido_claw/{triage,front_door,front_door_stickiness}_test.exs`, `…/route_composer/composer_loop_test.exs` | new/extend |
| Sub-docs | `docs/exploration/alp-river/AR-8b-SKETCH-PATH.md`, `AR-8c-SYSTEM-PATH.md` | new (appendices below) |

### Reuse (don't reinvent)
- Direct structured generation — `Jido.AI.generate_object/3` (`deps/jido_ai/lib/jido_ai.ex:290`;
  `:model` accepts a direct spec, `:system_prompt`/`:max_tokens`/`:temperature`/`:timeout` pass-through).
  **Returns `{:ok, %ReqLLM.Response{}}`** — unwrap with `ReqLLM.Response.unwrap_object/2`
  (`deps/req_llm/lib/req_llm/response.ex:556`, `json_repair: true`), per `Jido.AI.Output.parse`
  (`output.ex:109`).
- Structured-output enum shape — `lib/jido_claw/agent/workers/reviewer.ex:28` (explicit `Zoi.enum`
  string mapping).
- Test-impl seam idiom — `:ask_runtime` (`lib/jido_claw.ex:154`), `:agent_templates_override`
  (`templates.ex:97`).
- Configurable model precedent — `Reasoning.Compactor.Summarizer.LLMBackend.resolve_model/1`
  (`llm_backend.ex:51`).
- Metadata-key change + code interface — `Changes.SetMetadataKey` (`session.ex:296`),
  `define(:set_current_agent_template, …)` (`session.ex:54`).
- Composer launch + genesis seed + `:context` threading — `RouteComposer.create_parent_run/1`
  (`route_composer.ex:255`), `append_genesis_signals/artifacts` (`:360-385`), `ensure_started/2`
  (`:475`), wave `context:` (`:727`, `:1029`).
- History window — `JidoClaw.Session.Worker.get_messages/2` (`platform/session/worker.ex:105`).

---

## Commit guidance (per project policy — do NOT commit; leave unstaged)

Land the four sub-phases as separate commits once each is green, e.g.:
`AR-2 Composer — Phase 3a: LLM triage classifier (configurable model)`,
`Phase 3b: composer pre-run seeding (Option A)`, `Phase 3c: triage front door + turn-seam wiring`,
`Phase 3d: tests + AR-8b/AR-8c sub-docs`. The user stages and commits.

---

## Appendix A — `AR-8b-SKETCH-PATH.md` skeleton (to be created in 3d)

> # AR-8b — The Sketch Path (throwaway sandbox prototyping)
> *Architecture direction — extends AR-2 §8 / AR-8. Not a commitment.*
>
> **Context.** AR-8 triage (Phase 3) classifies a turn as `sketch` — "throwaway exploration: a code
> tracer-bullet, a diagram, a UI mockup, an idea sketch … graduates to `code`/`system` when a result
> is worth keeping" (Alp River `agents/triage.md`, `WORKFLOW.md`). Phase 3 routes `sketch` **inline**
> (like `talk`) as a stopgap, because the sandbox machinery does not exist. This doc designs it.
>
> **Why separate.** It needs a sandbox executor + workspace isolation + a cross-run graduation flow —
> none of which the triage front door needs. Independent of Phase 4 (gates).
>
> **Phases.**
> - **A — Sandbox workspace.** A `.prototypes/`-rooted, isolated workspace (reuse `JidoClaw.VFS.Workspace`)
>   so sketch artifacts never touch the real working tree.
> - **B — `sketch-build` worker + catalog stages.** A new worker template + built-in-catalog
>   `sketch`-route stages (`sketch-build` → optional `sketch-review`), validator-clean, `routes`
>   including `"sketch"`. Flip the front door to start a composer for `sketch`.
> - **C — Graduation.** A `sketch → code`/`system` promotion that re-seeds a fresh composer run with
>   the prototype as `request` context (the "throwaway becomes real" transition), oscillation-guarded.
> - **D — Sketch convergence.** A prototype "converges" differently from a reviewed change
>   (correctness + security still apply; the code-only ceremony band is filtered off by `routes`).
>
> **Open questions.** Sandbox FS backend; retention/cleanup of `.prototypes/`; how graduation carries
> provenance.

## Appendix B — `AR-8c-SYSTEM-PATH.md` skeleton (to be created in 3d)

> # AR-8c — The System Path (verified machine change)
> *Architecture direction — extends AR-2 §8 / AR-8. Not a commitment.*
>
> **Context.** AR-8 triage classifies OS-level work as `system` — "update configs, troubleshoot, run
> CLI tooling, change the environment" (Alp River `agents/triage.md`); a path defined by leaving "a
> verified change to the machine." Phase 3 routes `system` through the **shared** `planner`/`plan-gate`
> (catalog `routes: ["code","system"]`), so a system turn behaves exactly like `code` up to the gate.
> The system-specific stages do not exist. This doc designs them.
>
> **Why separate.** It needs new safety-critical worker templates, a **safety gate** (a Phase-4
> gate-producer), and the **reverse-verify loop** (the first real use of the `stages_invalidated`
> rerun primitive, §4). Depends on Phase 4 (gates) landing first.
>
> **Phases.**
> - **A — `system-executor` + `system-verifier` workers + catalog stages.** `planner → safety-gate →
>   system-executor → system-verifier`, validator-clean, `routes: ["system"]`.
> - **B — `Reactors.SafetyGate` gate-producer** (`unit: {:gate, "safety"}`), gating `destructive-op`/
>   `irreversible` (the system-flavored risk signals triage already emits). **Depends on Phase 4.**
> - **C — Reverse-verify loop.** `system-verifier` re-fires on a `verify-failed` signal by removing
>   `system-executor` from `ran` via a durable `stages_invalidated` event (AR-2 §4/§6), bounded by the
>   per-stage rerun cap.
> - **D — System terminal semantics.** A machine change that won't verify is a distinct failure from
>   `:not_converged`.
>
> **Open questions.** What "verified" means per system op (idempotent re-check vs state assertion);
> safety-gate UX for irreversible ops; reconciling environmental artifacts (a `diff` of machine state)
> with the artifact store.
