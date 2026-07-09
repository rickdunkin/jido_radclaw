defmodule JidoClaw.RouteComposer.Catalog do
  @moduledoc """
  The built-in, representative starter catalog — a coherent code/system
  pipeline authored directly as compile-time `%Stage{}` data (the
  `StrategyRegistry` map layer without the deferred user-overlay store).

  Every consumed signal, required artifact, and lock `while` / `until` has a
  declared producer, so the catalog validates clean. Seeds are
  `request-received` (signal) and `request` (artifact). The data graph is a DAG:
  `triage → planner → {plan-gate, test-author, implementer}`, `implementer →
  {reviewers, fixer}`, and `fixer → reviewers` (the reviewers optional-input the
  `fix`). On an **armed** run (AR-9: the front door seeds `multi-plan` instead
  of `plan-needed`) the planner is preceded by the judge panel — `[3 lens
  planners] → [3 challengers] → [plan-arbiter] → planner` — sequenced purely by
  the `plan:<lens>` / `critique:<lens>` / `decision-memo` artifacts (no advisory
  signals); the planner remains the sole `plan` producer and the plan-gate is
  untouched. The AR-4 review → fix → re-review loop is **dynamic**: the composer
  drops the touched reviewers from `ran` (`stages_invalidated`) and feeds the
  fixer the open findings OUT-OF-BAND (the producerless `review-feedback` /
  `review-action` inputs) — so the loop runs WITHOUT a data cycle. Declaring
  `findings` as a real fixer input would cycle (`fixer → reviewers` via `fix` +
  `reviewers → fixer` via `findings`); `CatalogValidator` invariant 10 rejects it.

  Three guards run at **compile time** (fail fast, not just a test):

    * `JidoClaw.RouteComposer.CatalogValidator.validate/1` must return `[]`, so
      an incoherent catalog breaks the build,
    * every `{:worker_template, _}` stage must name a real
      `JidoClaw.Agent.Templates` template, so a typo is caught now rather than
      at execution time. (Existence is checked **only here**; the pure
      validator never resolves it.)
    * every `{:gate, _}` stage must name a known
      `JidoClaw.RouteComposer.GateReactors` gate (the parallel guard — a typo'd
      gate would otherwise fail only when the wave dispatches),
    * every `{:verify, _}` stage must name a known
      `JidoClaw.RouteComposer.VerifyReactors` reactor (item 5 — the same
      typo-fails-the-build posture).

  Accessors mirror `JidoClaw.Reasoning.StrategyRegistry`.
  """

  alias JidoClaw.Agent.Templates
  alias JidoClaw.RouteComposer.CatalogValidator
  alias JidoClaw.RouteComposer.GateReactors
  alias JidoClaw.RouteComposer.Stage
  alias JidoClaw.RouteComposer.VerifyReactors

  @catalog %{
    "triage" => %Stage{
      name: "triage",
      unit: {:seed, "triage"},
      routes: ["talk", "sketch", "code", "system"],
      subscribes: ["request-received"],
      input: %{required: ["request"], optional: []},
      output: ["intent"],
      publishes: [
        # Path + planning topics the front-door seed maps onto `live`.
        "code",
        "system",
        "plan-needed",
        # AR-9: the multi-plan arming topic. The front door seeds it INSTEAD OF
        # `plan-needed` when the triage verdict arms (`multi_plan?` ∧
        # `significant-build` — enforced in `FrontDoor.armed?/1`, never mapped
        # from the signals list). Declared here so the seven judge-panel stages'
        # subscriptions satisfy `CatalogValidator` invariant 3; NOT in the front
        # door's `@signal_topics`, so `mapped_signals/1` never auto-injects it.
        "multi-plan",
        # AR-8b-2 F2 (D4-B): the two sketch-builder discriminators. The front door
        # seeds EXACTLY ONE (the launch decision, §2.4), making `sketch-build` and
        # `sketch-build-exec` mutually exclusive by construction. Declared here so
        # their subscriptions satisfy `CatalogValidator` invariant 3; neither is in
        # `@signal_topics`, so `mapped_signals/1` never auto-injects them. Publishes
        # need no consumer.
        "must-execute",
        "sketch-plain",
        # The full early-signal vocabulary a `Triage.Verdict` can carry (AR-8),
        # so the seeded "triage emission" is coherent with its declared contract.
        # Publishes need no consumer (only consumed signals need a producer), so
        # this stays `CatalogValidator`-clean.
        "needs-tests",
        "significant-build",
        "auth-surface",
        "secrets",
        "perms-change",
        "multi-file",
        "novel-domain",
        "bug",
        "ambiguous",
        "destructive-op",
        "irreversible",
        "scope-shift"
      ]
    },
    # AR-9: the planner stays the SOLE producer of `plan` in BOTH modes (armed
    # human-reject rerun set = {planner} only — `gate_input_producers` is
    # provenance-derived). Armed, it subscribes `multi-plan` (appended LAST so
    # the unarmed `triggered_by` stays `plan-needed` and armed-reject still
    # matches `plan-rejected` first) and optional-inputs the decision memo, the
    # competing plans, AND the critiques (so "redraft per the critiques" is
    # honest — `ArtifactContext` forwards only named inputs). Absent optional
    # producers create no edge, so the unarmed route is byte-identical.
    "planner" => %Stage{
      name: "planner",
      unit: {:worker_template, "researcher"},
      task:
        "Draft an implementation plan from the confirmed intent; emit plan-ready. With a " <>
          "decision-memo present, reproduce the adopted plan faithfully, graft per a hybrid " <>
          "memo, or redraft per the critiques on revise_first.",
      routes: ["code", "system"],
      # `plan-rejected` is the Phase-4e re-plan opt-in: a rejected plan re-fires
      # the planner (its publisher is `plan-gate`'s extended `publishes`).
      subscribes: ["plan-needed", "plan-rejected", "multi-plan"],
      input: %{
        required: ["intent"],
        optional: [
          "decision-memo",
          "plan:smallest-shippable",
          "plan:risk-first",
          "plan:reuse-first",
          "critique:smallest-shippable",
          "critique:risk-first",
          "critique:reuse-first"
        ]
      },
      output: ["plan"],
      # `plan-ready` is loop-GUARANTEED: `RouteComposer.enforce_completion_signals/2`
      # injects it into the planner's emission even if the model omits it (a no-lens
      # producer whose omission would SILENTLY `:converge`) — at Kahn level 4 of an
      # armed route exactly as at level 1 unarmed. The `task` still nudges the emit
      # (belt-and-suspenders); `scope-shift` stays self-reported.
      publishes: ["plan-ready", "scope-shift"]
    },
    # =========================================================================
    # AR-9 (PR-3): the multi-plan judge panel — [lens×3] → [challengers×3] →
    # [plan-arbiter] → [planner]. All seven stages are lens-nil (invisible to
    # `lenses_clean?` and validator invariant 8) and publish ONLY the mandatory
    # `scope-shift`: sequencing is ARTIFACT-driven (`plan:<lens>` →
    # `critique:<lens>` → `decision-memo` → the planner's optional inputs) —
    # no advisory signals exist (deviation c: `plan-drafted:<lens>` was
    # dropped). The `critique:<lens>` family deliberately avoids `findings:`
    # (the fixer subscribes bare `findings`). The arbiter is a pure adjudicator
    # (decision 1): its memo carries the verdict INSIDE the artifact — no
    # verdict-driven routing; the planner finalizes on all three verdicts.
    # =========================================================================
    "planner-smallest-shippable" => %Stage{
      name: "planner-smallest-shippable",
      unit: {:worker_template, "plan_drafter"},
      task:
        "Draft the smallest-shippable implementation plan for the confirmed intent — the " <>
          "least code that ships real value. Yours is one of several competing plans; an " <>
          "arbiter selects.",
      routes: ["code", "system"],
      subscribes: ["multi-plan"],
      input: %{required: ["intent"], optional: []},
      output: ["plan:smallest-shippable"],
      publishes: ["scope-shift"]
    },
    "planner-risk-first" => %Stage{
      name: "planner-risk-first",
      unit: {:worker_template, "plan_drafter"},
      task:
        "Draft the risk-first implementation plan for the confirmed intent — attack the " <>
          "hardest unknowns before the easy work. Yours is one of several competing plans; " <>
          "an arbiter selects.",
      routes: ["code", "system"],
      subscribes: ["multi-plan"],
      input: %{required: ["intent"], optional: []},
      output: ["plan:risk-first"],
      publishes: ["scope-shift"]
    },
    "planner-reuse-first" => %Stage{
      name: "planner-reuse-first",
      unit: {:worker_template, "plan_drafter"},
      task:
        "Draft the reuse-first implementation plan for the confirmed intent — lean on " <>
          "existing modules and patterns over new code. Yours is one of several competing " <>
          "plans; an arbiter selects.",
      routes: ["code", "system"],
      subscribes: ["multi-plan"],
      input: %{required: ["intent"], optional: []},
      output: ["plan:reuse-first"],
      publishes: ["scope-shift"]
    },
    "challenger-smallest-shippable" => %Stage{
      name: "challenger-smallest-shippable",
      unit: {:worker_template, "plan_challenger"},
      task:
        "Critique ONLY the smallest-shippable plan — surface blockers, concerns, and " <>
          "strengths for the arbiter; never approve or select.",
      routes: ["code", "system"],
      subscribes: ["multi-plan"],
      input: %{required: ["plan:smallest-shippable"], optional: []},
      output: ["critique:smallest-shippable"],
      publishes: ["scope-shift"]
    },
    "challenger-risk-first" => %Stage{
      name: "challenger-risk-first",
      unit: {:worker_template, "plan_challenger"},
      task:
        "Critique ONLY the risk-first plan — surface blockers, concerns, and strengths " <>
          "for the arbiter; never approve or select.",
      routes: ["code", "system"],
      subscribes: ["multi-plan"],
      input: %{required: ["plan:risk-first"], optional: []},
      output: ["critique:risk-first"],
      publishes: ["scope-shift"]
    },
    "challenger-reuse-first" => %Stage{
      name: "challenger-reuse-first",
      unit: {:worker_template, "plan_challenger"},
      task:
        "Critique ONLY the reuse-first plan — surface blockers, concerns, and strengths " <>
          "for the arbiter; never approve or select.",
      routes: ["code", "system"],
      subscribes: ["multi-plan"],
      input: %{required: ["plan:reuse-first"], optional: []},
      output: ["critique:reuse-first"],
      publishes: ["scope-shift"]
    },
    # PR-4: the tiering seam's designed FIRST DECLARER — the adjudication is the
    # one stage worth a capable model at high effort (`WaveBuilder` carries the
    # tier into the step options; the composed `RequestTransformer` applies it
    # per LLM turn). Everything else in the panel stays on the session default.
    "plan-arbiter" => %Stage{
      name: "plan-arbiter",
      unit: {:worker_template, "plan_arbiter"},
      task:
        "Select or graft the best plan across the three plans and their critiques — steelman " <>
          "each; tie-break correctness > grounding > simpler-first > validation-rollback > " <>
          "cost; write a decision memo naming one verdict (adopt|hybrid|revise_first), the " <>
          "selection, and the deciding rung.",
      model: :capable,
      effort: :high,
      routes: ["code", "system"],
      subscribes: ["multi-plan"],
      input: %{
        required: [
          "plan:smallest-shippable",
          "plan:risk-first",
          "plan:reuse-first",
          "critique:smallest-shippable",
          "critique:risk-first",
          "critique:reuse-first"
        ],
        optional: []
      },
      output: ["decision-memo"],
      publishes: ["scope-shift"]
    },
    # AR-8c (decision 1): the plan-gate is dropped from the SYSTEM path — system
    # ops run through the always-on `safety-gate` instead, so `plan-approved` is
    # never live on `system` and the composer's `stale_approval?` guard is provably
    # false there (no `implementer_ran?` change needed). The `planner` still serves
    # both `code` + `system`.
    "plan-gate" => %Stage{
      name: "plan-gate",
      unit: {:gate, "plan"},
      routes: ["code"],
      subscribes: ["plan-ready"],
      input: %{required: ["plan"], optional: []},
      output: ["approved-plan"],
      # `plan-approved` is the gate reactor's own emission; `plan-rejected` /
      # `plan-abandoned` are composer-SYNTHESIZED from the gate child's terminal
      # status (the reactor emits only `plan-approved`; reject cancels before the
      # emit step — §9 step 5/6). Declaring them here keeps the catalog coherent
      # once a stage opts into `subscribes: ["plan-rejected"]` (Phase 4e —
      # `CatalogValidator` rejects a subscription with no declared publisher) and
      # lets the composer fold a synthesized signal as-if-from `plan-gate` past
      # the emission ⊆ `publishes` coherence check. Publishes need no consumer.
      publishes: ["plan-approved", "plan-rejected", "plan-abandoned", "scope-shift"]
    },
    "test-author" => %Stage{
      name: "test-author",
      unit: {:worker_template, "coder"},
      task: "Write the failing tests the plan calls for; emit tests-ready when red.",
      routes: ["code"],
      subscribes: ["needs-tests"],
      input: %{required: ["plan"], optional: []},
      output: ["tests"],
      publishes: ["tests-ready", "scope-shift"]
    },
    "implementer" => %Stage{
      name: "implementer",
      unit: {:worker_template, "coder"},
      task: "Implement the approved plan against the authored tests; emit code-written.",
      routes: ["code"],
      subscribes: ["plan-ready"],
      input: %{required: ["plan"], optional: []},
      output: ["diff"],
      # `code-written` is loop-GUARANTEED (`enforce_completion_signals/2` injects it
      # if the model omits it — the silent-converge fix; it triggers the quality +
      # correctness lenses). `scope-shift` stays self-reported (conditional).
      publishes: ["code-written", "scope-shift"],
      lock: [
        %{while: "needs-tests", until: "tests-ready"},
        %{while: "plan-ready", until: "plan-approved"}
      ]
    },
    "security-reviewer" => %Stage{
      name: "security-reviewer",
      unit: {:worker_template, "reviewer"},
      lens: "security",
      task:
        "Review the diff for auth-surface, secrets, and permission changes; " <>
          "flag findings, else emit clean:security. When the run premises carry " <>
          "acceptance criteria, verify each against the diff and cite the AC id " <>
          "(AC1, AC2, …) in any related finding. An evidence-report input, when " <>
          "present, is engine-verified (claims cross-checked against the tool " <>
          "transcript) — treat it as ground truth and diagnose the cause.",
      routes: ["code"],
      subscribes: ["auth-surface"],
      input: %{required: ["diff"], optional: ["fix", "evidence-report"]},
      output: ["findings", "action_needed"],
      publishes: ["findings:security", "clean:security", "scope-shift"]
    },
    "quality-reviewer" => %Stage{
      name: "quality-reviewer",
      unit: {:worker_template, "reviewer"},
      lens: "quality",
      task:
        "Review the diff for style, clarity, and duplication; flag findings, " <>
          "else emit clean:quality. When the run premises carry acceptance " <>
          "criteria, verify each against the diff and cite the AC id " <>
          "(AC1, AC2, …) in any related finding. An evidence-report input, when " <>
          "present, is engine-verified (claims cross-checked against the tool " <>
          "transcript) — treat it as ground truth and diagnose the cause.",
      routes: ["code"],
      subscribes: ["code-written"],
      input: %{required: ["diff"], optional: ["fix", "evidence-report"]},
      output: ["findings", "action_needed"],
      publishes: ["findings:quality", "clean:quality", "scope-shift"]
    },
    "correctness-reviewer" => %Stage{
      name: "correctness-reviewer",
      unit: {:worker_template, "reviewer"},
      lens: "correctness",
      task:
        "Review the diff for logic and edge-case correctness; flag findings, " <>
          "else emit clean:correctness. When the run premises carry acceptance " <>
          "criteria, verify each against the diff and cite the AC id " <>
          "(AC1, AC2, …) in any related finding. An evidence-report input, when " <>
          "present, is engine-verified (claims cross-checked against the tool " <>
          "transcript) — treat it as ground truth and diagnose the cause.",
      routes: ["code"],
      subscribes: ["code-written"],
      input: %{required: ["diff"], optional: ["fix", "evidence-report"]},
      output: ["findings", "action_needed"],
      publishes: ["findings:correctness", "clean:correctness", "scope-shift"]
    },
    "architecture-reviewer" => %Stage{
      name: "architecture-reviewer",
      unit: {:worker_template, "reviewer"},
      lens: "architecture",
      task:
        "Review the diff against the system's architecture; flag findings, " <>
          "else emit clean:architecture. When the run premises carry acceptance " <>
          "criteria, verify each against the diff and cite the AC id " <>
          "(AC1, AC2, …) in any related finding. An evidence-report input, when " <>
          "present, is engine-verified (claims cross-checked against the tool " <>
          "transcript) — treat it as ground truth and diagnose the cause.",
      routes: ["code"],
      subscribes: ["significant-build"],
      input: %{required: ["diff"], optional: ["fix", "evidence-report"]},
      output: ["findings", "action_needed"],
      publishes: ["findings:architecture", "clean:architecture", "scope-shift"]
    },
    # AR-4 self-heal fixer. A first-class `fixer` template (not `coder`) so it can
    # emit the domain signals it self-reports (`code-written` always; `auth-surface`
    # / `significant-build` for any domain it touched) — those drive the loop's
    # re-review set. `findings` rides the `subscribes` SIGNAL (the reviewers'
    # `findings:<lens>`), not a data input; the open findings reach it OUT-OF-BAND
    # via the two producerless optional inputs `review-feedback` / `review-action`
    # (loop-injected at invalidation time). Declaring `findings` as a real input
    # would add reviewer→fixer edges that, with the `fixer→reviewer` edge (the
    # reviewers optional-input `fix`), form a 2-cycle `CatalogValidator` invariant
    # 10 rejects — so the feed is producerless (no edge, `graph.ex`), keeping the
    # static data DAG acyclic.
    "fixer" => %Stage{
      name: "fixer",
      unit: {:worker_template, "fixer"},
      task:
        "Resolve the open review findings against the diff; always emit code-written, and ALSO " <>
          "emit the domain signal for any domain you touched (auth-surface for auth/permissions/" <>
          "secrets, significant-build for architectural changes) so the right lenses re-review. " <>
          "Feedback from the evidence lens means the engine contradicted a worker's claims " <>
          "against the tool transcript — redo that work honestly (run tests cleanly, no " <>
          "exit-masking plumbing); the engine re-checks every round.",
      routes: ["code"],
      subscribes: ["findings"],
      input: %{
        required: ["diff"],
        optional: ["review-feedback", "review-action", "evidence-report"]
      },
      output: ["fix"],
      publishes: ["code-written", "scope-shift", "auth-surface", "significant-build"]
    },
    # AR-8b sketch path (file-only). AR-8b-2 F2 (D4-B) retargets its trigger off
    # the seed `request-received` onto the `sketch-plain` discriminator — so it is
    # mutually exclusive with `sketch-build-exec` (← `must-execute`) by
    # construction: the front door seeds exactly one. Publishes only the mandatory
    # `scope-shift` — its worker emits no signals (no `signals` output field), so
    # the route converges the moment it finishes.
    "sketch-build" => %Stage{
      name: "sketch-build",
      unit: {:worker_template, "sketch_build"},
      task:
        "Build a throwaway prototype for the request in the sandbox: a tracer-bullet, scaffold, " <>
          "diagram, or idea sketch. Write files only — do not run commands or touch git.",
      routes: ["sketch"],
      subscribes: ["sketch-plain"],
      input: %{required: ["request"], optional: []},
      output: ["prototype"],
      publishes: ["scope-shift"]
    },
    # AR-8b-2 F2: the exec sketch builder. Subscribes the `must-execute`
    # discriminator (D4-B), so it runs INSTEAD OF `sketch-build` on a
    # must-execute sketch. Its `sketch_build_exec` worker runs `RunCommand` in a
    # no-egress Forge Docker microVM (`sandbox: :docker`), so the tracer-bullet
    # actually executes. Produces `prototype` (the same artifact `sketch-build`
    # does — `sketch-review` orders after either via the data graph). Publishes
    # only the mandatory `scope-shift` (no `signals` output field → converges the
    # moment it finishes + the reviewer clears).
    "sketch-build-exec" => %Stage{
      name: "sketch-build-exec",
      unit: {:worker_template, "sketch_build_exec"},
      task: "Build a tracer-bullet prototype AND run it in the sandbox to validate it executes.",
      routes: ["sketch"],
      subscribes: ["must-execute"],
      input: %{required: ["request"], optional: []},
      output: ["prototype"],
      publishes: ["scope-shift"]
    },
    # AR-8b-2 F1: the light-lens correctness reviewer on the sketch path. It
    # subscribes the SEED signal `request-received` (no stage publishes
    # `prototype`, which is an artifact, not a signal — `CatalogValidator`
    # invariant 3 would reject a literal `subscribes: ["prototype"]`) and depends
    # on the `prototype` artifact via `input.required` (invariant 4: `prototype`
    # is in the output union, produced by `sketch-build`). The data graph orders
    # it producer→consumer after `sketch-build` (wave 2). Its `lens` flips the
    # sketch path from trivially-clean to gated: approve + no findings →
    # `clean:correctness` → `:converged`; request_changes → `findings:correctness`
    # → `:not_converged` (report-only — there is no fixer on the sketch path).
    "sketch-review" => %Stage{
      name: "sketch-review",
      unit: {:worker_template, "sketch_reviewer"},
      lens: "correctness",
      task:
        "Review the sandbox prototype for logic and edge-case correctness; " <>
          "flag findings, else emit clean:correctness.",
      routes: ["sketch"],
      subscribes: ["request-received"],
      input: %{required: ["prototype"], optional: []},
      output: ["findings"],
      publishes: ["findings:correctness", "clean:correctness", "scope-shift"]
    },
    # Item 5 (camus C1-2): the deterministic verify authority on the `code`
    # path — a `{:verify, "default"}` unit (the engine runs the repo's verify
    # command and reads the exit code itself; `VerifyReactors` resolves it to
    # `Reactors.VerifyStage`, never a worker). Triggered by `code-written`
    # (so every fixer run re-touches it — Hook F auto-invalidates a stale
    # green); the optional `diff`/`fix` inputs are ORDERING edges only
    # (implementer/fixer → verify; the reactor reads the working tree, not
    # the store — `run_verify_wave` skips artifact resolution). Kahn leveling
    # still co-locates it with the reviewers, so `Loop.defer_solo_verify/2`
    # peels it to run LAST. Lens `verify` ⇒ `clean:verify`/`findings:verify`
    # (invariant 8); a red's `findings`/`action_needed` artifacts ride the
    # existing Hook R fixer re-fire unchanged.
    "verify" => %Stage{
      name: "verify",
      unit: {:verify, "default"},
      lens: "verify",
      routes: ["code"],
      subscribes: ["code-written"],
      input: %{required: [], optional: ["diff", "fix"]},
      output: ["findings", "action_needed"],
      publishes: ["clean:verify", "findings:verify", "scope-shift"]
    },
    # AR-8c system path: `triage → planner → safety-gate → system-executor →
    # system-verifier`. The always-on `safety-gate` (decision 1) gates every
    # machine change; the executor is held until the human approves; the verifier
    # (`reverse_verify: true`) re-fires the executor on an open `findings:system`.
    "safety-gate" => %Stage{
      name: "safety-gate",
      unit: {:gate, "safety"},
      routes: ["system"],
      subscribes: ["plan-ready"],
      input: %{required: ["plan"], optional: []},
      output: ["approved-change"],
      publishes: ["safety-approved", "scope-shift"]
    },
    "system-executor" => %Stage{
      name: "system-executor",
      unit: {:worker_template, "system_executor"},
      task: "Apply the approved change to the machine/environment; report what changed.",
      routes: ["system"],
      subscribes: ["plan-ready"],
      # `verify-feedback` is an OPTIONAL input with NO catalog producer (the
      # composer writes it out-of-band on re-fire). Optional ⇒ not producer-checked
      # (invariant 4) and adds NO precedence edge (`graph.ex` — absent producer →
      # no edge), so the executor⇄verifier cycle the naive design would create is
      # avoided. `ArtifactContext.wanted_names/1` (required ∪ optional) still
      # surfaces the prior findings in the executor's task on re-fire.
      input: %{required: ["plan"], optional: ["verify-feedback"]},
      output: ["system-change"],
      publishes: ["scope-shift"],
      # Held until the human approves at the safety gate; never re-gated on retry
      # (`safety-approved` is never retracted).
      lock: [%{while: "plan-ready", until: "safety-approved"}]
    },
    "system-verifier" => %Stage{
      name: "system-verifier",
      unit: {:worker_template, "system_verifier"},
      lens: "system",
      reverse_verify: true,
      task:
        "Verify the change actually took on the machine (idempotent re-check / " <>
          "state assertion / exit code); emit clean:system, else findings:system " <>
          "with what to fix.",
      routes: ["system"],
      # The `system` path signal (always live) triggers it; the `system-change`
      # data edge orders it AFTER the executor (the `sketch-review` pattern — no
      # stage publishes `system-change` as a signal).
      subscribes: ["system"],
      input: %{required: ["system-change"], optional: []},
      output: ["findings"],
      publishes: ["findings:system", "clean:system", "scope-shift"]
    }
  }

  case CatalogValidator.validate(@catalog) do
    [] -> :ok
    problems -> raise "RouteComposer starter catalog is incoherent: " <> inspect(problems)
  end

  for {name, %Stage{unit: {:worker_template, template}}} <- @catalog,
      not Templates.exists?(template) do
    raise "RouteComposer stage #{name} references unknown worker template #{inspect(template)}"
  end

  for {name, %Stage{unit: {:gate, gate_name}}} <- @catalog,
      not GateReactors.known?(gate_name) do
    raise "RouteComposer stage #{name} references unknown gate #{inspect(gate_name)}"
  end

  for {name, %Stage{unit: {:verify, verify_name}}} <- @catalog,
      not VerifyReactors.known?(verify_name) do
    raise "RouteComposer stage #{name} references unknown verify reactor #{inspect(verify_name)}"
  end

  @doc "Returns the whole starter catalog as a `%{name => %Stage{}}` map."
  @spec all() :: %{String.t() => Stage.t()}
  def all, do: @catalog

  @doc "Returns the stage for `name`, or `nil` when absent."
  @spec get(String.t()) :: Stage.t() | nil
  def get(name) when is_binary(name), do: Map.get(@catalog, name)

  @doc "Returns every stage name in the catalog."
  @spec names() :: [String.t()]
  def names, do: Map.keys(@catalog)

  @doc "Returns true when `name` is a stage in the catalog."
  @spec valid?(String.t()) :: boolean()
  def valid?(name) when is_binary(name), do: Map.has_key?(@catalog, name)

  # ---------------------------------------------------------------------------
  # JSONB (de)serialization (AR-2 Phase 2d — durable catalog in the parent config)
  # ---------------------------------------------------------------------------

  @doc """
  Serialize a `%{name => %Stage{}}` catalog to a JSON-safe, string-keyed map
  (each stage via `Stage.to_map/1`) — the form stored in the composer parent's
  `WorkflowRun.config["catalog"]` so the launch catalog survives a node reboot.
  """
  @spec to_map(%{String.t() => Stage.t()}) :: %{String.t() => map()}
  def to_map(catalog) when is_map(catalog) do
    Map.new(catalog, fn {name, stage} -> {name, Stage.to_map(stage)} end)
  end

  @doc """
  Rebuild a catalog from a `to_map/1` (or JSONB-reloaded) map. **Total +
  nil-on-failure** (never `{:error, _}`): `from_map(nil)` is `nil`, and if **any**
  stage fails to decode (`Stage.from_map/1` returns `nil` for an atom-unsafe
  unknown closed tag) the whole catalog decode returns `nil`. This guarantees
  **atom-safety only** — a structurally-degenerate-but-atom-safe stage map
  decodes to a default `%Stage{}`, so STRUCTURAL/semantic coherence is a separate
  `JidoClaw.RouteComposer.CatalogValidator` check; the launch/recovery gate
  `RouteComposer.decode_config_catalog/1` composes both (decode here + validate
  there).
  """
  @spec from_map(map() | nil) :: %{String.t() => Stage.t()} | nil
  def from_map(nil), do: nil

  def from_map(map) when is_map(map) do
    reduced =
      Enum.reduce_while(map, {:ok, %{}}, fn {name, stage_map}, {:ok, acc} ->
        case Stage.from_map(stage_map) do
          %Stage{} = stage -> {:cont, {:ok, Map.put(acc, name, stage)}}
          nil -> {:halt, :error}
        end
      end)

    case reduced do
      {:ok, catalog} -> catalog
      :error -> nil
    end
  end

  def from_map(_other), do: nil
end
