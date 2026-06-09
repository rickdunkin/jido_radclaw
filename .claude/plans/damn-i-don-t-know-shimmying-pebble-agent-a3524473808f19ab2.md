# Gate Spark DSL design + Phases 0–3 sequencing review

This is a plan-mode design document. No code changes. Every Spark/Reactor/Ash
API below is grounded against the installed deps in this repo.

## Verified dependency versions (mix.lock)

- spark **2.7.0** (NOT 2.6.0 — the prompt understated it; docs surfaced as
  2.7.2 but the Entity/Section/Extension/InfoGenerator/Options APIs cited are
  identical and stable across 2.6–2.7).
- reactor **1.0.2**
- ash **3.27.7**
- ash_cloak **0.3.1**

Greenfield confirmed: the ONLY consumer of `use JidoClaw.Orchestration.Gates`
in the whole tree is `test/support/jido_claw/gates/test_irreversible_write.ex`.
No Spark DSL is *defined* anywhere; the only Spark *consumption* is
`use Ash.Resource` / `use Reactor.Step`, and a `Spark.Dsl.is?/2` probe at
`reactor_runner.ex:215`.

---

# TASK 1 — The gate Spark DSL (concrete, API-verified)

## 1a. The extension: `JidoClaw.Orchestration.Gate.Dsl`

Grounded in the canonical example in `Spark.Dsl.Extension` moduledoc
(`mix usage_rules.docs "Spark.Dsl.Extension"`): a `%Spark.Dsl.Section{}` with
`schema:` (scalar opts) + `entities:` (a list of `%Spark.Dsl.Entity{}`),
finalized by `use Spark.Dsl.Extension, sections: [...]`.

Field-`type` enum uses `{:one_of, choices}` — confirmed at
`deps/spark/lib/spark/options/options.ex:149` (`{:in, choices}` /
`{:one_of, choices}`). Option-list type is `{:list, subtype}` (options.ex:279).
`args:` makes positional builder args (Entity moduledoc); every `args` value
must also appear in the `schema`.

```elixir
# lib/jido_claw/orchestration/gate/field.ex
defmodule JidoClaw.Orchestration.Gate.Field do
  @moduledoc "One operator-facing typed field rendered for a gate decision."
  defstruct [:name, :type, :label, :options, required?: false]

  @type t :: %__MODULE__{
          name: atom(),
          type: :text | :select | :textarea | :number | :boolean,
          label: String.t() | nil,
          options: [String.t()] | nil,
          required?: boolean()
        }
end

# lib/jido_claw/orchestration/gate/dsl.ex
defmodule JidoClaw.Orchestration.Gate.Dsl do
  @moduledoc "Spark DSL extension for human approval gate modules."

  alias JidoClaw.Orchestration.Gate.Field

  @field %Spark.Dsl.Entity{
    name: :field,
    describe: "An operator-facing typed input for the decision form.",
    target: Field,
    args: [:name],                       # `field :reason, type: :textarea`
    identifier: :name,                   # unique-by-name, Spark-validated
    schema: [
      name: [type: :atom, required: true, doc: "Field key."],
      type: [
        type: {:one_of, [:text, :select, :textarea, :number, :boolean]},
        required: true,
        doc: "Input widget / value type."
      ],
      label: [type: :string, required: false, doc: "Human label."],
      required?: [type: :boolean, default: false, doc: "Operator must fill it."],
      options: [
        type: {:list, :string},
        required: false,
        doc: "Choices — only meaningful for `type: :select`."
      ]
    ]
  }

  @fields %Spark.Dsl.Section{
    name: :fields,
    describe: "The typed decision form the operator UI renders.",
    entities: [@field]
  }

  @gate %Spark.Dsl.Section{
    name: :gate,
    describe: "Declares a human approval gate kind + presentation.",
    schema: [
      kind: [
        type: {:one_of, [:tool_call, :plan, :irreversible_write]},
        required: true,
        doc: "Gate kind; mirrored onto AgentCase.kind."
      ],
      title: [type: :string, required: true, doc: "Inbox headline."],
      description: [type: :string, required: false, doc: "Longer operator text."],
      workflow: [type: :atom, required: false, doc: "Optional reactor/binding tag."]
    ],
    sections: [@fields]   # nested section — Section moduledoc, get by path
  }

  use Spark.Dsl.Extension,
    sections: [@gate],
    transformers: [],
    verifiers: [JidoClaw.Orchestration.Gate.Verifiers.ValidateSelectOptions]
end
```

Notes:
- `identifier: :name` on the field entity gives Spark-enforced uniqueness of
  field names for free (Entity moduledoc, "identifier expresses uniqueness").
- `kind`'s `{:one_of, ...}` enumerates all three kinds NOW even though only
  `:irreversible_write` has a live producer — that is the decision and it costs
  nothing at the DSL layer.

## 1b. How a gate module consumes it — `use JidoClaw.Orchestration.HumanGate`

Two clean approaches; recommend **the wrapper**.

### Recommended: a thin `Spark.Dsl` base module (wrapper macro)

`Spark.Dsl`'s base `__using__` (`deps/spark/lib/spark/dsl.ex:112`) accepts
`default_extensions:` (dsl.ex:36-44, flattened at dsl.ex:174-183) and exposes
`handle_opts/1` / `handle_before_compile/1` callbacks (dsl.ex:100-110). So a
wrapper both injects the extension AND keeps the arity-1 GateContext behaviour.

```elixir
# lib/jido_claw/orchestration/human_gate.ex
defmodule JidoClaw.Orchestration.HumanGate do
  @moduledoc "Base for human approval gate modules: Spark gate DSL + behaviour."

  use Spark.Dsl,
    default_extensions: [extensions: [JidoClaw.Orchestration.Gate.Dsl]]

  @impl Spark.Dsl
  def handle_before_compile(_opts) do
    quote do
      @behaviour JidoClaw.Orchestration.Gates

      # arity-1 GateContext hooks stay plain behaviour callbacks (code, not
      # data). Provide best-effort defaults so a gate that only declares data
      # still satisfies the behaviour.
      @impl JidoClaw.Orchestration.Gates
      def after_approved(%JidoClaw.Orchestration.GateContext{}), do: :ok
      @impl JidoClaw.Orchestration.Gates
      def after_rejected(%JidoClaw.Orchestration.GateContext{}), do: :ok

      defoverridable after_approved: 1, after_rejected: 1
    end
  end
end
```

Consumed:

```elixir
defmodule JidoClaw.Gates.IrreversibleWriteGate do
  use JidoClaw.Orchestration.HumanGate

  gate do
    kind :irreversible_write
    title "Confirm destructive write"
    description "This step writes data that cannot be undone."

    fields do
      field :reason, type: :textarea, label: "Why approve?", required?: true
    end
  end

  # arity-1 GateContext hooks remain ordinary functions — code, not data.
  @impl JidoClaw.Orchestration.Gates
  def after_approved(%GateContext{agent_case: c}), do: notify(c)
end
```

**Confirm the question in the brief:** YES — `after_approved/1` /
`after_rejected/1` stay plain behaviour callbacks **alongside** the DSL. They
carry executable side-effects (`Cases.bounded_hook` does
`apply(mod, fun, [ctx])`, cases.ex:198), which is logic, not declarative data.
The DSL declares *what the gate is* (kind/title/fields); the behaviour declares
*what it does on a decision*. The `kind/0` behaviour callback can be **dropped**
from gate modules — it becomes derivable from the DSL via the Info module
(below) — but keep the `Gates` behaviour itself for the two hook callbacks.

### Alternative (rejected): keep `use JidoClaw.Orchestration.Gates` and add `extensions:`

`Gates.__using__` is hand-rolled, not Spark — bolting a Spark extension onto a
non-Spark macro means manually replicating what `Spark.Dsl` already does
(register attrs, run transformers/verifiers, `@before_compile`). More code, more
fragile. The wrapper is strictly less work given `Spark.Dsl` exists.

## 1c. Accessors / introspection — generated `Info` module

Use `Spark.InfoGenerator` (confirmed via
`mix usage_rules.search_docs "InfoGenerator"`: `generate_entity_functions/2`,
`generate_options_functions/2`, `generate_config_functions/2`). The generator
takes the extension + section paths and emits typed accessors.

```elixir
# lib/jido_claw/orchestration/gate/info.ex
defmodule JidoClaw.Orchestration.Gate.Info do
  use Spark.InfoGenerator,
    extension: JidoClaw.Orchestration.Gate.Dsl,
    sections: [:gate]

  # Generated by the `:gate` section schema:
  #   gate_kind!/1, gate_kind/1
  #   gate_title!/1, gate_title/1
  #   gate_description/1, gate_workflow/1

  # Nested entities need an explicit get_entities call (path-based — Section
  # moduledoc: "getting entities is done by providing a path").
  @spec fields(module()) :: [JidoClaw.Orchestration.Gate.Field.t()]
  def fields(gate_module) do
    Spark.Dsl.Extension.get_entities(gate_module, [:gate, :fields])
  end
end
```

Used by:
- `gate_step.ex` to build `details` — replace `kind = gate_module.kind()` with
  `kind = Gate.Info.gate_kind!(gate_module)` and seed
  `details` from `Gate.Info.gate_title!/1` + `fields/1` so the inbox renders
  the declared form (today `details` is a hand-passed map; the DSL becomes its
  source).
- the operator UI (`web/live/approvals_live.ex`, currently flat at
  `{gate.kind}` line 58) to render typed inputs from `fields/1`.

`Spark.Dsl.Extension.get_opt/3-4` and `get_entities/2` (Extension moduledoc) are
the low-level fallbacks if you prefer not to generate the Info module.

## 1d. Transformer vs verifier — what is actually warranted

Order of compile hooks is Transformers → Persisters → Verifiers (Extension
moduledoc).

- **No transformer needed.** Transformers exist to *rewrite* DSL state or
  compute derived data into it. We have nothing to derive; the kind enum and
  field types are validated by the schema at compile time already
  (`{:one_of, ...}`). Do NOT add a transformer "to register the kind" — the
  kind is read on demand via Info, not registered in a global table.
- **One small verifier IS warranted:** `ValidateSelectOptions` — assert that
  every `field` whose `type == :select` has a non-empty `options:` list, and
  (optionally) that non-`:select` fields do NOT set `options:`. The schema
  alone cannot express this cross-field rule (`options` is independently
  optional). Verifiers are read-only and run after compile, so this is the
  correct hook (`Spark.Dsl.Verifier`, Extension moduledoc).

```elixir
# lib/jido_claw/orchestration/gate/verifiers/validate_select_options.ex
defmodule JidoClaw.Orchestration.Gate.Verifiers.ValidateSelectOptions do
  use Spark.Dsl.Verifier
  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl_state) do
    dsl_state
    |> Verifier.get_entities([:gate, :fields])
    |> Enum.reduce_while(:ok, fn field, :ok ->
      cond do
        field.type == :select and (field.options in [nil, []]) ->
          {:halt,
           {:error,
            Spark.Error.DslError.exception(
              module: Verifier.get_persisted(dsl_state, :module),
              path: [:gate, :fields, field.name],
              message: "select field #{inspect(field.name)} requires non-empty `options`"
            )}}

        field.type != :select and not is_nil(field.options) ->
          {:halt,
           {:error,
            Spark.Error.DslError.exception(
              module: Verifier.get_persisted(dsl_state, :module),
              path: [:gate, :fields, field.name],
              message: "`options` only valid for `type: :select`"
            )}}

        true ->
          {:cont, :ok}
      end
    end)
  end
end
```

## 1e. The three kinds + AgentCase.kind / gate_step wiring changes

Three modules, each `use JidoClaw.Orchestration.HumanGate` with a `gate do
kind :tool_call|:plan|:irreversible_write … end`. Only `:irreversible_write`
gets a live producer (a reactor wiring a `GateStep` before its write); the other
two are declared-but-unproduced — fine.

Two wiring changes:

1. **`AgentCase.kind` constraint** (agent_case.ex:154-158) currently
   `one_of: [:irreversible_write]`. Widen to
   `one_of: [:tool_call, :plan, :irreversible_write]`. This is a constraint
   change only (greenfield, no migration of existing rows needed). This is the
   single source of truth that must match the DSL's `kind` enum — keep them in
   lockstep (consider deriving both from one module attribute to avoid drift).

2. **`gate_step.ex` kind/details derivation** (gate_step.ex:41-42): replace
   `kind = Keyword.get(options, :kind, gate_module.kind())` with
   `Gate.Info.gate_kind!(gate_module)` (drop the `:kind` opt and the
   `gate_module.kind()` behaviour call). It is currently hardcoded only insofar
   as `gate_module.kind()` defaulted to `:irreversible_write` via the
   `Gates.__using__` macro; routing through Info makes the kind authoritatively
   the DSL value. No other wiring in `gate_step.ex` is kind-specific.

---

# TASK 2 — Risk + sequencing review (full Phases 0–3 plan)

## 2a. Correct build order (dependency-honoring)

The graph has three roughly independent spines plus two cross-cutting features.
Land in this order:

**Tier 0 — data-model migrations that everything else reads/writes.**
1. **WS2 — `WorkflowStep` → tenant-scoping** (mirror `WorkflowEvent`:
   `workflow_step.ex` currently has NO `tenant_id`, NO multitenancy, NO
   authorizers, NO policies — verified). MUST precede WS3 (the projector writes
   `WorkflowStep` rows tenant-scoped; an untenanted resource would force
   `authorize?: false`/global writes and re-work). Mirror exactly the
   `WorkflowEvent` shape (workflow_event.ex:19-54): plain `use Ash.Resource` +
   the two hand-written tenant policies (NOT `JidoClaw.Resource`, because that
   macro injects `bypass action(:by_id_global)` which won't compile without a
   `:by_id_global` action — workflow_event.ex:7-12 documents exactly this).
2. **WS1 — Claim/fencing columns on `WorkflowRun`** (`claimed_by`,
   `claim_expires_at`, `claim_token` + the two indexes). Pure additive data
   model, no behavior. Independent — can land anytime in Tier 0, but bundle it
   with WS9's WorkflowRun decision (see 2c) because BOTH touch WorkflowRun's
   resource definition and you want ONE decision about that file's macro.

**Tier 1 — the event-shape enrichment WS3/WS4/WS10 all depend on.**
3. **`reactor_middleware.ex` `step_payload/1` enrichment** (middleware.ex:230,
   currently `%{step: inspect(step.name)}`). This is the shared prerequisite for
   WS3 (projector needs the YAML name + result) AND it touches the same file as
   WS10 (Trace emit). The YAML name is ALREADY present: the compiler threads
   `step_name: Map.get(step, :name)` into the impl options
   (`compiler.ex:260`), and Reactor stores impl as `{module, options}` on the
   step struct (`deps/reactor/lib/reactor/step.ex:34`,
   `module_and_options_from_step` at step.ex:345). So `step_payload/1` can read
   `step.impl` → `{_mod, opts}` → `opts[:step_name]`. **Do WS3's middleware
   change and WS10's middleware change in one pass** — same file, same hooks.

**Tier 2 — the projector + step metadata (depend on Tier 0+1).**
4. **WS3 — Project `WorkflowStep` rows in `WorkflowEvent.Changes.Allocate`**
   (in-transaction, rides the per-run FOR UPDATE lock — allocate.ex:83). The
   `step_*` events now carry name+result (Tier 1), and `WorkflowStep` is
   tenant-scoped (Tier 0). Mirror the existing status-projection seam: an
   `after_action` branch keyed on the `step_*` kinds, threading
   `tenant: changeset.tenant` exactly as the status path does
   (allocate.ex:106-143). This is the **highest-coupling change** in the plan
   (see 2e).
5. **WS4 — per-step retry/compensate/irreversible YAML metadata.** Three
   sub-parts with DIFFERENT risk:
   - `StepNormalizer` allowlist: add `:retry`, `:compensate`, `:irreversible`
     to `@canonical_keys` (step_normalizer.ex:41-49) — trivial, but MUST land
     first or the keys are silently dropped (normalizer drops unknown keys,
     documented at step_normalizer.ex:38-39).
   - `retry → max_retries`: thread through `compiler.ex` `add_step/4`
     (hardcoded `max_retries: 0` at compiler.ex:277) and the iterative path
     (compiler.ex:166-175). `max_retries` type is
     `{:or, [:non_neg_integer, {:literal, :infinity}]}`
     (`deps/reactor/lib/reactor/builder/step.ex:25`) — straightforward.
   - `compensate:`/`irreversible:`: require `AgentStep` to export
     `compensate/4` and `undo/4`. **Verified callback shape (critical
     correction below in 2b).**

**Tier 3 — the gate Spark DSL (Task 1).** Land BEFORE AR-1.
6. **WS6 — gate Spark DSL + 3 kinds.** Independent of the projector spine.
   Must precede WS7 (AR-1) because AR-1's stale-approval / abandon hooks
   conceptually live on gate modules, and widening `AgentCase.kind` (1e) wants
   the DSL's kind enum as its lockstep source. Also the cleanest standalone unit
   (first Spark DSL in repo) — land it in isolation so a Spark misstep can't
   entangle the projector work.

**Tier 4 — lifecycle + recovery (depend on the event vocabulary + DSL).**
7. **WS5 — `AgentCaseEvent` append-only resource** (mirror `WorkflowEvent`'s
   per-key `seq` allocator). Append points are
   `WorkflowLog.gate_open/3` and `Cases.commit_approve`/`commit_reject` — all
   ALREADY single `Ash.transact([...])` blocks (cases.ex:124, 142;
   workflow_log.ex:104), so adding a third resource to the transact list is
   low-risk. Land before/with WS7 (abandon appends an AgentCaseEvent too).
8. **WS7 — AR-1 lifecycle (abandon + stale-approval retraction).** Depends on
   WS6 (gate modules) and WS5 (case events). Touches: `AgentCase.status` one_of
   (+`:abandoned`), the kind/projection vocabulary (see 2d), `Cases.abandon`,
   and BOTH operator surfaces — `web/live/approvals_live.ex` (136 lines,
   `phx-click` handlers at :74-75) + `cli/commands/approvals.ex` (83 lines,
   `Cases.decide` at :49).
9. **WS8 — recovery fixes.** Depends on WS7's terminal-kind decision (2d): the
   dangling-gate branch's `:failed` change (workflow_recovery.ex:152-162)
   shares the kind vocabulary with abandon. Re-keying the decision-recorded
   branch on `approval_resolved` (workflow_recovery.ex:114, currently keyed on
   `:running`+checkpoint) is a recovery-internal change. The new tests
   (forbidden `:running`+checkpoint+no-decision; non-gate-halt→run_failed;
   parked-gate negatives) gate this.

**Tier 5 — cross-cutting, last.**
10. **WS9 — encrypt `resume_checkpoint` via AshCloak.** Land LAST among
    WorkflowRun-touching work (see 2c for the macro decision). It restructures
    the very column (`resume_checkpoint`) that WS1, the projection
    (projection.ex:110-123 sets `resume_checkpoint: nil` on every terminal),
    `set_checkpoint` (workflow_run.ex:65-69), `set_status` (workflow_run.ex:56),
    recovery's `classify/1` (workflow_recovery.ex:107-120 reads
    `resume_checkpoint` presence), and `handle_gate_pause`
    (reactor_runner.ex:303-310) all touch. Doing it last means those callers are
    stable when you rename the column. **This is secretly bigger than it looks —
    see 2e.**
11. **WS10 — Trace emit in `reactor_middleware.ex`.** Pure addition to the
    run-lifecycle hooks (init/complete/error/halt, middleware.ex:93-199),
    mirroring `tools/handoff.ex:339-374`. The collector already attaches
    `[:jido_claw, :workflow, :event]`. Lowest-risk; can land anytime after Tier
    1's middleware pass — best folded INTO that pass (same file, same hooks) to
    avoid touching `reactor_middleware.ex` twice.

### Order summary
WS2 → WS1 → (middleware pass: WS3-prep + WS10) → WS3 → WS4 → WS6 →
WS5 → WS7 → WS8 → WS9.

## 2b. Hidden coupling / ordering hazards I found

1. **WS4 compensate/undo callback ARITY is NOT the behaviour signature
   (the brief's framing is subtly wrong).** Reactor's `Reactor.Step` behaviour
   declares `compensate(step, reason, arguments, context)` and
   `undo(step, value, arguments, context)` (deps/reactor/lib/reactor/step.ex:141,
   172). BUT the `use Reactor.Step` dispatcher invokes the *module's* callbacks
   as **`module.compensate(reason, arguments, context, options)`** and
   **`module.undo(value, arguments, context, options)`** — options LAST, 4-arg
   (step.ex:292-307). So `AgentStep` must implement
   `compensate(reason, arguments, context, options)` and
   `undo(value, arguments, context, options)`, reading the impl keyword list
   (`step_options/2`, compiler.ex:255-262) as the **4th** arg. The brief said
   "reading impl options from `step_options/2`" — correct in spirit, but the
   sketch must use the options-last 4-arg form, not the `(step, …)` behaviour
   form.
2. **WS4 — compensation won't fire unless `can?/4` reports it.** `use
   Reactor.Step` injects `can?(_step, capability) =>
   function_exported?(__MODULE__, capability, 4)` (step.ex:361). So merely
   *defining* `compensate/4`/`undo/4` is what flips Reactor to call them — good,
   it's automatic — but it means a typo'd arity silently disables compensation
   with no error. Add a test that asserts `AgentStep.can?(step, :compensate)`.
3. **WS3 ↔ WS4 retry coupling.** With `max_retries > 0` (WS4), a step that
   retries emits `:run_retry` → `step_retried` (middleware.ex:220-221). The WS3
   projector writes `WorkflowStep` rows from `step_*` events; a retried step
   produces multiple `step_started`/`step_failed` events for the SAME logical
   step. The projector must UPSERT `WorkflowStep` by `(workflow_run_id, name)`,
   not blind-insert, or retries create duplicate rows. This coupling only
   appears once WS4 enables retries — easy to miss if WS3 is tested only with
   `max_retries: 0`. **Test WS3 against a retrying step.**
4. **WS3 — positional vs YAML name during the gap.** `step_payload/1` today is
   `%{step: inspect(step.name)}` where `step.name` is the positional
   `:step_1`/`:step_2` (compiler.ex `step_id(idx)`). Until the Tier-1 middleware
   enrichment lands, the projector keying on `step.name` keys on `:step_1`, not
   the YAML name. WS3 is HARD-BLOCKED on the Tier-1 enrichment; do not start the
   projector before `step_payload/1` reads `step.impl`'s `step_name`.
5. **WS5/WS7 — transaction-resource list must include `AgentCaseEvent`.**
   `Ash.transact([AgentCase, WorkflowEvent], fn -> … end)` (cases.ex:124,142;
   workflow_log.ex:104) names the resources whose repos participate. Adding
   `AgentCaseEvent` appends inside those blocks requires adding it to the
   transact list — otherwise the append runs in a separate connection and the
   "commit together or not at all" invariant breaks silently (no compile error).
6. **WS7/WS8 — `next_status/2` is a total function with a catch-all
   `:illegal`.** projection.ex:82 ends with `next_status(_current, _kind) =>
   :illegal`. Any new terminal kind (e.g. `run_abandoned`) that is NOT added to
   `@status_authority_kinds` (projection.ex:32-40) AND given `next_status`
   clauses AND `status_attrs` clauses will either be ignored (non-authority) or
   roll back every append (illegal). All THREE must change together, plus
   `WorkflowEvent.kind`'s `one_of` (workflow_event.ex:100-118) and
   `WorkflowRun.status`'s `one_of` (workflow_run.ex:119-121). This is the
   "change five places or it silently breaks" hazard.
7. **WS9 ↔ projection/recovery — the column rename ripples.** AshCloak renames
   `resume_checkpoint` → `encrypted_resume_checkpoint` and adds a
   `resume_checkpoint` *calculation* (verified at
   `deps/ash_cloak/lib/ash_cloak.ex:26-31`: "the attribute will be renamed to
   `encrypted_{attribute}`, and a calculation with the same name will be
   added"). Consequences:
   - `projection.ex` sets `resume_checkpoint: nil` on terminals
     (projection.ex:110,119,123) — that attribute no longer exists as a writable
     attribute; it must write `encrypted_resume_checkpoint: nil` (or go through
     the encrypt change).
   - `set_checkpoint`/`set_status` accept lists (workflow_run.ex:56,68) name
     `resume_checkpoint` — must change to the encrypted attr.
   - recovery `classify/1` matches `resume_checkpoint: nil` / `not is_nil(cp)`
     in struct patterns (workflow_recovery.ex:107-120) — a calculation is NOT
     loaded by default, so the struct field will be `%Ash.NotLoaded{}` unless
     loaded. **Recovery must either load the calc or test
     `encrypted_resume_checkpoint` presence.** This is the single most likely
     place WS9 introduces a latent recovery bug.

## 2c. AshCloak blocker — forward `extensions:` vs hand-roll WorkflowRun

**Recommendation: hand-roll `use Ash.Resource` on `WorkflowRun`.** Lower risk.

Reasoning:
- `JidoClaw.Resource` (resource.ex:30-58) injects a `policies do … end` block
  whose first clause is `bypass action(:by_id_global)`. WorkflowRun DOES have a
  `:by_id_global` action (workflow_run.ex:82), so unlike WorkflowEvent it CAN
  use the macro today — but teaching the macro to forward `extensions:` means
  changing a base macro that ~every tenant-scoped resource uses. A subtle change
  there (option threading into `use Ash.Resource`) risks all of them.
- The repo ALREADY establishes "hand-roll when the resource is special" as the
  sanctioned pattern: `WorkflowEvent` (workflow_event.ex:7-12) and the
  `SecretRef` AshCloak precedent (secret_ref.ex:3-8) both hand-roll
  `use Ash.Resource, …, extensions: [AshCloak]`. Hand-rolling WorkflowRun keeps
  the macro untouched and follows precedent.
- The hand-roll cost is bounded and local: copy the 13-line policy block from
  resource.ex:44-56 inline (WorkflowRun keeps `by_id_global` so it KEEPS the
  bypass clause — unlike WorkflowEvent which dropped it), add
  `extensions: [AshCloak]`, add the `cloak do vault(JidoClaw.Security.Vault);
  attributes([:resume_checkpoint]) end` block (mirroring secret_ref.ex:15-18).
- Forwarding `extensions:` through the macro is the "DRY" choice but it is a
  blast-radius change for a one-resource need. If a SECOND resource later needs
  `extensions:`, revisit then — at that point teaching the macro is justified.

Caveat either way: the AshCloak column rename ripples (2b#7) are identical
regardless of which option you pick — they are a property of encrypting the
column, not of how WorkflowRun is declared.

## 2d. Dangling-gate `:failed` — distinct `run_abandoned` kind or reuse?

**Recommendation: REUSE `run_cancelled` for the recovery dangling-gate path;
add a DISTINCT `run_abandoned` kind ONLY for the operator-initiated AR-1
abandon.** They are semantically different events:

- The dangling-gate recovery branch (workflow_recovery.ex:152-162) today calls
  `terminate_cancelling_cases(:run_cancelled, …)`. The brief wants this to
  become `run_recovered` + `run_failed` (+ cancel case) in one txn — i.e. move
  it from the *cancelled* terminal to the *failed* terminal with recovery
  provenance. That is "the system gave up," and the existing
  `run_recovered`+`run_failed` pair (workflow_log.ex:69-79,
  `append_recovery/2`) already encodes exactly that semantics. **Reuse the
  existing recovery vocabulary** — extend `terminate_cancelling_cases` to take
  the `[{:run_recovered, …}, {:run_failed, …}]` pair (it already wraps an
  `Ash.transact` and an `append`, workflow_log.ex:129-139), or add a
  case-cancelling variant of `append_recovery`. No new kind needed for recovery.
- AR-1 operator **abandon** is a deliberate human terminal ("operator gave up on
  this run"), distinct from both reject (a gate decision) and recovery-failure.
  That one DOES merit a distinct `run_abandoned` kind so the audit log
  distinguishes "human abandoned" from "crashed and reaped." Add `run_abandoned`
  to: `WorkflowEvent.kind` one_of, `@status_authority_kinds`, `next_status`
  (from any `@non_terminal` → `:abandoned`), `status_attrs` (→ `:abandoned`,
  `completed_at`, `resume_checkpoint: nil`), AND `WorkflowRun.status` one_of
  (+`:abandoned`), AND `AgentCase.status` one_of (+`:abandoned`). (This is the
  "five places" hazard from 2b#6 — applied to the genuinely-new kind only.)

Net: do NOT spend a new kind on the recovery dangling-gate fix (reuse
recovered+failed); DO spend one on operator abandon.

## 2e. What is secretly bigger than it looks

1. **WS3 (projector) — the biggest hidden one.** It runs INSIDE the
   `WorkflowEvent.:append` transaction (allocate.ex), so every correctness
   property of the event log now also gates `WorkflowStep` writes: the FOR
   UPDATE lock, tenant threading (`tenant: changeset.tenant` — allocate.ex
   moduledoc warns `authorize?: false` drops policy but NOT the multitenancy
   filter), redaction, and rollback-on-illegal. Plus the retry-upsert coupling
   (2b#3) and the positional-name block (2b#4). It LOOKS like "write a row when a
   step event lands"; it is actually "extend the most concurrency-sensitive
   change in the system." Budget accordingly and test it under retries +
   concurrent appends.
2. **WS9 (AshCloak) — bigger than "add an extension."** The column rename
   ripples through projection, set_checkpoint, set_status, recovery's
   `classify/1` struct matching, and `handle_gate_pause` (2b#7). The recovery
   `classify/1` is the trap: it pattern-matches `resume_checkpoint` presence in
   function heads, and a `:resume_checkpoint` *calculation* is `%NotLoaded{}`
   unless explicitly loaded — so recovery could silently misclassify every run.
   Also: the checkpoint is a `:binary` `term_to_binary` blob, and
   `Cloak.Vault.encrypt!` works on binaries, so encryption itself is fine — but
   confirm the projection's terminal `resume_checkpoint: nil` path interacts
   cleanly with the encrypt change (writing `nil` through an attribute that now
   triggers encryption).
3. **WS7 (AR-1) — two UI surfaces + a vocabulary spread, not one feature.**
   Abandon touches `Cases` (new `abandon`), the projection/event/run/case
   vocabularies (the five-places spread, 2b#6), `web/live/approvals_live.ex`
   (new handler + button alongside :74-75), AND `cli/commands/approvals.ex` (new
   command alongside the `decide` at :49). Stale-approval retraction
   ("a re-plan retracts a recorded approval so a revised plan must re-earn it")
   is a NEW state transition the current model has no representation for:
   today `approval_resolved` (approve) is terminal-for-the-gate and goes
   straight to `:running` (projection.ex:79). Retracting it means a NEW legal
   transition (approved → back to awaiting/pending or a new `approval_retracted`
   event) that the projection's strict `next_status/2` (which treats anything
   unlisted as `:illegal`) must explicitly allow. This sub-feature is its own
   design spike — do not lump it into "AR-1 is small."
4. **WS2 (WorkflowStep tenant migration) — slightly bigger than "add
   tenant_id."** It is not just a column: it is authorizers + multitenancy block
   + two policies + every existing `WorkflowStep.create/start/complete/...`
   call site now needing a `tenant:`/`actor:` (the resource currently has NO
   authorizers at all — workflow_step.ex:3-6). Grep every caller before
   estimating. (It mirrors WorkflowEvent, which is the good news — the shape is
   known — but the call-site sweep is real.)

---

## Critical files for implementation

- /Users/rickdunkin/workspace/claws/jido_radclaw/lib/jido_claw/orchestration/gate_step.ex
- /Users/rickdunkin/workspace/claws/jido_radclaw/lib/jido_claw/orchestration/agent_case.ex
- /Users/rickdunkin/workspace/claws/jido_radclaw/lib/jido_claw/orchestration/workflow_event/changes/allocate.ex
- /Users/rickdunkin/workspace/claws/jido_radclaw/lib/jido_claw/orchestration/workflow_event/projection.ex
- /Users/rickdunkin/workspace/claws/jido_radclaw/lib/jido_claw/orchestration/reactor_middleware.ex
