defmodule JidoClaw.Orchestration.DefinitionFingerprintTest do
  @moduledoc """
  Pins the canonical-semantic-term hashing contract: equal semantics ⇒ equal
  hash (keying style, docs, omitted-vs-default fields are NOT semantics);
  different semantics ⇒ different hash (tasks, step count, execution mode,
  irreversibility, and `depends_on`/`consumes` ORDER — the compiler wires
  edges and renders prompt sections in YAML order, so order is semantic).
  """
  use ExUnit.Case, async: true

  alias JidoClaw.Orchestration.DefinitionFingerprint
  alias JidoClaw.Skills

  defp dag_skill(overrides \\ []) do
    struct!(
      %Skills{
        name: "fixture",
        description: "original docs",
        steps: [
          %{name: "one", template: "t1", task: "do one"},
          %{name: "two", template: "t2", task: "do two", depends_on: ["one"]}
        ],
        synthesis: "combine",
        mode: nil,
        max_iterations: nil
      },
      overrides
    )
  end

  defp iterative_skill(overrides) do
    struct!(
      %Skills{
        name: "iter-fixture",
        description: "iterate",
        steps: iterative_steps(),
        synthesis: "present",
        mode: "iterative",
        max_iterations: nil
      },
      overrides
    )
  end

  # The fixture's gen/eval pair with per-role extras merged in.
  defp iterative_steps(gen_extra \\ %{}, eval_extra \\ %{}) do
    [
      Map.merge(%{name: "gen", role: "generator", template: "coder", task: "make"}, gen_extra),
      Map.merge(
        %{name: "eval", role: "evaluator", template: "verifier", task: "check"},
        eval_extra
      )
    ]
  end

  describe "for_skill/1 shape + determinism" do
    test "produces 64-char lowercase sha256 hex" do
      assert DefinitionFingerprint.for_skill(dag_skill()) =~ ~r/^[0-9a-f]{64}$/
    end

    test "is deterministic for the same skill" do
      assert DefinitionFingerprint.for_skill(dag_skill()) ==
               DefinitionFingerprint.for_skill(dag_skill())
    end
  end

  describe "non-semantic differences hash identically" do
    test "string-keyed and atom-keyed steps are equivalent" do
      string_keyed =
        dag_skill(
          steps: [
            %{"name" => "one", "template" => "t1", "task" => "do one"},
            %{"name" => "two", "template" => "t2", "task" => "do two", "depends_on" => ["one"]}
          ]
        )

      assert DefinitionFingerprint.for_skill(string_keyed) ==
               DefinitionFingerprint.for_skill(dag_skill())
    end

    test "description is excluded (docs, not semantics)" do
      assert DefinitionFingerprint.for_skill(dag_skill(description: "rewritten docs")) ==
               DefinitionFingerprint.for_skill(dag_skill())
    end

    test "irreversible: false is equivalent to omitted" do
      explicit =
        dag_skill(
          steps: [
            %{name: "one", template: "t1", task: "do one", irreversible: false},
            %{name: "two", template: "t2", task: "do two", depends_on: ["one"]}
          ]
        )

      assert DefinitionFingerprint.for_skill(explicit) ==
               DefinitionFingerprint.for_skill(dag_skill())
    end

    test "deadlines are excluded: a deadline-only edit never trips the replay gate (T2-1)" do
      # Top-level run policy AND a per-step policy added/changed — the hash
      # must not move (deadlines are observability, not execution semantics).
      with_deadlines =
        dag_skill(
          deadline: %{within: 3600},
          steps: [
            %{
              name: "one",
              template: "t1",
              task: "do one",
              deadline: %{within: 300, due_soon: 60}
            },
            %{name: "two", template: "t2", task: "do two", depends_on: ["one"]}
          ]
        )

      assert DefinitionFingerprint.for_skill(with_deadlines) ==
               DefinitionFingerprint.for_skill(dag_skill())
    end

    test "retry: 0 is equivalent to omitted" do
      explicit =
        dag_skill(
          steps: [
            %{name: "one", template: "t1", task: "do one", retry: 0},
            %{name: "two", template: "t2", task: "do two", depends_on: ["one"]}
          ]
        )

      assert DefinitionFingerprint.for_skill(explicit) ==
               DefinitionFingerprint.for_skill(dag_skill())
    end

    test "iterative max_iterations: nil is equivalent to the runtime default 3" do
      assert DefinitionFingerprint.for_skill(iterative_skill(max_iterations: nil)) ==
               DefinitionFingerprint.for_skill(iterative_skill(max_iterations: 3))
    end

    test "max_iterations is inert for non-iterative skills" do
      assert DefinitionFingerprint.for_skill(dag_skill(max_iterations: 5)) ==
               DefinitionFingerprint.for_skill(dag_skill(max_iterations: nil))
    end

    test "produces keying style (atom vs string, incl. nested) is not semantic" do
      atom_keyed = %{type: "elixir_module", meta: %{level: 1}, verification_criteria: ["a", "b"]}

      string_keyed = %{
        "verification_criteria" => ["a", "b"],
        "meta" => %{"level" => 1},
        "type" => "elixir_module"
      }

      with_produces = fn produces ->
        dag_skill(
          steps: [
            %{name: "one", template: "t1", task: "do one", produces: produces},
            %{name: "two", template: "t2", task: "do two", depends_on: ["one"]}
          ]
        )
      end

      assert DefinitionFingerprint.for_skill(with_produces.(atom_keyed)) ==
               DefinitionFingerprint.for_skill(with_produces.(string_keyed))
    end
  end

  describe "semantic differences hash differently" do
    test "a task edit changes the hash" do
      changed =
        dag_skill(
          steps: [
            %{name: "one", template: "t1", task: "do one DIFFERENTLY"},
            %{name: "two", template: "t2", task: "do two", depends_on: ["one"]}
          ]
        )

      refute DefinitionFingerprint.for_skill(changed) ==
               DefinitionFingerprint.for_skill(dag_skill())
    end

    test "adding a step changes the hash" do
      grown =
        dag_skill(
          steps: [
            %{name: "one", template: "t1", task: "do one"},
            %{name: "two", template: "t2", task: "do two", depends_on: ["one"]},
            %{name: "three", template: "t3", task: "more", depends_on: []}
          ]
        )

      refute DefinitionFingerprint.for_skill(grown) ==
               DefinitionFingerprint.for_skill(dag_skill())
    end

    test "an execution-mode change changes the hash" do
      # Same steps, mode flips the compiler construction (:dag → :iterative).
      refute DefinitionFingerprint.for_skill(dag_skill(mode: "iterative")) ==
               DefinitionFingerprint.for_skill(dag_skill())
    end

    test "declaring a step irreversible changes the hash" do
      marked =
        dag_skill(
          steps: [
            %{name: "one", template: "t1", task: "do one", irreversible: true},
            %{name: "two", template: "t2", task: "do two", depends_on: ["one"]}
          ]
        )

      refute DefinitionFingerprint.for_skill(marked) ==
               DefinitionFingerprint.for_skill(dag_skill())
    end

    test "iterative max_iterations value changes the hash" do
      refute DefinitionFingerprint.for_skill(iterative_skill(max_iterations: 5)) ==
               DefinitionFingerprint.for_skill(iterative_skill(max_iterations: 3))
    end

    test "depends_on order changes the hash (order is prompt-semantic)" do
      with_deps = fn deps ->
        dag_skill(
          steps: [
            %{name: "a", template: "t", task: "ta"},
            %{name: "b", template: "t", task: "tb"},
            %{name: "c", template: "t", task: "tc", depends_on: deps}
          ]
        )
      end

      refute DefinitionFingerprint.for_skill(with_deps.(["a", "b"])) ==
               DefinitionFingerprint.for_skill(with_deps.(["b", "a"]))
    end

    test "consumes order changes the hash (order is prompt-semantic)" do
      with_consumes = fn consumes ->
        dag_skill(
          steps: [
            %{name: "a", template: "t", task: "ta"},
            %{name: "b", template: "t", task: "tb"},
            %{name: "c", template: "t", task: "tc", consumes: consumes}
          ]
        )
      end

      refute DefinitionFingerprint.for_skill(with_consumes.(["a", "b"])) ==
               DefinitionFingerprint.for_skill(with_consumes.(["b", "a"]))
    end
  end

  # The iterative term mirrors the compiler's loop semantics: only the
  # resolved generator/evaluator run, the generator's retry budget governs the
  # loop, and irreversible is OR'd onto the single loop step — everything the
  # iterative runtime ignores must be fingerprint-inert.
  describe "iterative loop semantics" do
    test "generator retry changes the hash (it is the loop's budget)" do
      with_retry = iterative_skill(steps: iterative_steps(%{retry: 2}))

      refute DefinitionFingerprint.for_skill(with_retry) ==
               DefinitionFingerprint.for_skill(iterative_skill([]))
    end

    test "evaluator retry is inert (the generator's budget governs the loop)" do
      with_eval_retry = iterative_skill(steps: iterative_steps(%{}, %{retry: 5}))

      assert DefinitionFingerprint.for_skill(with_eval_retry) ==
               DefinitionFingerprint.for_skill(iterative_skill([]))
    end

    test "compensate is inert on either role (the loop has no undo)" do
      with_compensate =
        iterative_skill(steps: iterative_steps(%{compensate: "undo"}, %{compensate: "undo"}))

      assert DefinitionFingerprint.for_skill(with_compensate) ==
               DefinitionFingerprint.for_skill(iterative_skill([]))
    end

    test "compensate on a dag step DOES change the hash (graph mode runs it)" do
      with_compensate =
        dag_skill(
          steps: [
            %{name: "one", template: "t1", task: "do one", compensate: "clean up"},
            %{name: "two", template: "t2", task: "do two", depends_on: ["one"]}
          ]
        )

      refute DefinitionFingerprint.for_skill(with_compensate) ==
               DefinitionFingerprint.for_skill(dag_skill())
    end

    test "irreversible on either role changes the hash; both OR to the same loop flag" do
      plain = DefinitionFingerprint.for_skill(iterative_skill([]))

      gen_marked =
        DefinitionFingerprint.for_skill(
          iterative_skill(steps: iterative_steps(%{irreversible: true}))
        )

      eval_marked =
        DefinitionFingerprint.for_skill(
          iterative_skill(steps: iterative_steps(%{}, %{irreversible: true}))
        )

      refute gen_marked == plain
      refute eval_marked == plain
      assert gen_marked == eval_marked
    end

    test "role YAML order, depends_on, and extra roleless steps are all inert" do
      [gen, eval] = iterative_steps(%{}, %{depends_on: ["gen"]})

      reshuffled =
        iterative_skill(
          steps: [eval, gen, %{name: "bystander", template: "t", task: "never runs"}]
        )

      assert DefinitionFingerprint.for_skill(reshuffled) ==
               DefinitionFingerprint.for_skill(iterative_skill([]))
    end
  end

  describe "for_module/1" do
    test "produces deterministic lowercase hex (the BEAM code md5)" do
      hash = DefinitionFingerprint.for_module(JidoClaw.Orchestration.Reactors.GatedTestReactor)

      assert hash =~ ~r/^[0-9a-f]{32}$/

      assert hash ==
               DefinitionFingerprint.for_module(JidoClaw.Orchestration.Reactors.GatedTestReactor)
    end

    test "different modules produce different fingerprints" do
      refute DefinitionFingerprint.for_module(Enum) == DefinitionFingerprint.for_module(Map)
    end
  end
end
