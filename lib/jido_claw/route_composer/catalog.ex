defmodule JidoClaw.RouteComposer.Catalog do
  @moduledoc """
  The built-in, representative starter catalog — a coherent code/system
  pipeline authored directly as compile-time `%Stage{}` data (the
  `StrategyRegistry` map layer without the deferred user-overlay store).

  Every consumed signal, required artifact, and lock `while` / `until` has a
  declared producer, so the catalog validates clean. Seeds are
  `request-received` (signal) and `request` (artifact). The data graph is a DAG:
  `triage → planner → {plan-gate, test-author, implementer}` and `implementer →
  {reviewers, fixer}`. The review → fix → re-review loop is **dynamic** (a later
  phase, via the `findings` / `code-written` signal edges), never a data cycle.

  Three guards run at **compile time** (fail fast, not just a test):

    * `JidoClaw.RouteComposer.CatalogValidator.validate/1` must return `[]`, so
      an incoherent catalog breaks the build,
    * every `{:worker_template, _}` stage must name a real
      `JidoClaw.Agent.Templates` template, so a typo is caught now rather than
      at execution time. (Existence is checked **only here**; the pure
      validator never resolves it.)
    * every `{:gate, _}` stage must name a known
      `JidoClaw.RouteComposer.GateReactors` gate (the parallel guard — a typo'd
      gate would otherwise fail only when the wave dispatches).

  Accessors mirror `JidoClaw.Reasoning.StrategyRegistry`.
  """

  alias JidoClaw.Agent.Templates
  alias JidoClaw.RouteComposer.CatalogValidator
  alias JidoClaw.RouteComposer.GateReactors
  alias JidoClaw.RouteComposer.Stage

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
    "planner" => %Stage{
      name: "planner",
      unit: {:worker_template, "researcher"},
      task: "Draft an implementation plan from the confirmed intent; emit plan-ready.",
      routes: ["code", "system"],
      # `plan-rejected` is the Phase-4e re-plan opt-in: a rejected plan re-fires
      # the planner (its publisher is `plan-gate`'s extended `publishes`).
      subscribes: ["plan-needed", "plan-rejected"],
      input: %{required: ["intent"], optional: []},
      output: ["plan"],
      publishes: ["plan-ready", "scope-shift"]
    },
    "plan-gate" => %Stage{
      name: "plan-gate",
      unit: {:gate, "plan"},
      routes: ["code", "system"],
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
          "flag findings, else emit clean:security.",
      routes: ["code"],
      subscribes: ["auth-surface"],
      input: %{required: ["diff"], optional: []},
      output: ["findings"],
      publishes: ["findings:security", "clean:security", "scope-shift"]
    },
    "quality-reviewer" => %Stage{
      name: "quality-reviewer",
      unit: {:worker_template, "reviewer"},
      lens: "quality",
      task:
        "Review the diff for style, clarity, and duplication; flag findings, else emit clean:quality.",
      routes: ["code"],
      subscribes: ["code-written"],
      input: %{required: ["diff"], optional: []},
      output: ["findings"],
      publishes: ["findings:quality", "clean:quality", "scope-shift"]
    },
    "correctness-reviewer" => %Stage{
      name: "correctness-reviewer",
      unit: {:worker_template, "reviewer"},
      lens: "correctness",
      task:
        "Review the diff for logic and edge-case correctness; flag findings, else emit clean:correctness.",
      routes: ["code"],
      subscribes: ["code-written"],
      input: %{required: ["diff"], optional: []},
      output: ["findings"],
      publishes: ["findings:correctness", "clean:correctness", "scope-shift"]
    },
    "architecture-reviewer" => %Stage{
      name: "architecture-reviewer",
      unit: {:worker_template, "reviewer"},
      lens: "architecture",
      task:
        "Review the diff against the system's architecture; flag findings, else emit clean:architecture.",
      routes: ["code"],
      subscribes: ["significant-build"],
      input: %{required: ["diff"], optional: []},
      output: ["findings"],
      publishes: ["findings:architecture", "clean:architecture", "scope-shift"]
    },
    "fixer" => %Stage{
      name: "fixer",
      unit: {:worker_template, "coder"},
      task: "Resolve the open review findings against the diff; emit code-written for re-review.",
      routes: ["code"],
      subscribes: ["findings"],
      input: %{required: ["diff"], optional: []},
      output: ["fix"],
      publishes: ["code-written", "scope-shift"]
    },
    # AR-8b sketch path. The ONLY clean trigger is the seed signal
    # `request-received` (no stage publishes `"sketch"`); the route-filter then
    # drops this stage on every non-sketch run (its `routes: ["sketch"]` is
    # disjoint from the live path). Publishes only the mandatory `scope-shift`
    # — its worker emits no signals (no `signals` output field), so the route
    # converges the moment it finishes.
    "sketch-build" => %Stage{
      name: "sketch-build",
      unit: {:worker_template, "sketch_build"},
      task:
        "Build a throwaway prototype for the request in the sandbox: a tracer-bullet, scaffold, " <>
          "diagram, or idea sketch. Write files only — do not run commands or touch git.",
      routes: ["sketch"],
      subscribes: ["request-received"],
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
