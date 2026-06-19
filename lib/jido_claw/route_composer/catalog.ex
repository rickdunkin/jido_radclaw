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

  Two guards run at **compile time** (fail fast, not just a test):

    * `JidoClaw.RouteComposer.CatalogValidator.validate/1` must return `[]`, so
      an incoherent catalog breaks the build,
    * every `{:worker_template, _}` stage must name a real
      `JidoClaw.Agent.Templates` template, so a typo is caught now rather than
      at execution time. (Existence is checked **only here**; the pure
      validator never resolves it.)

  Accessors mirror `JidoClaw.Reasoning.StrategyRegistry`.
  """

  alias JidoClaw.Agent.Templates
  alias JidoClaw.RouteComposer.CatalogValidator
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
        "code",
        "system",
        "plan-needed",
        "needs-tests",
        "significant-build",
        "auth-surface",
        "scope-shift"
      ]
    },
    "planner" => %Stage{
      name: "planner",
      unit: {:worker_template, "researcher"},
      task: "Draft an implementation plan from the confirmed intent; emit plan-ready.",
      routes: ["code", "system"],
      subscribes: ["plan-needed"],
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
      publishes: ["plan-approved", "scope-shift"]
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
end
