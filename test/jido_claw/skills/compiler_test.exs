defmodule JidoClaw.Skills.CompilerTest do
  @moduledoc """
  Pure compiler tests — they construct `%Reactor{}` structs and inspect them
  (and plan them), but never *run* them, so no sandbox is needed.

  Pins the C-NAMES / C-RETRIES / C-MIDDLEWARE corrections: positional atom ids
  (no YAML atomization), `max_retries: 0`, no middleware added, `:__collect__`
  depends on every agent step, and clean `{:error, _}` for
  duplicate-name/missing-dep/cycle skills. Also compiles every committed
  `.jido/skills/*.yaml` and asserts each yields a plannable reactor.
  """
  use ExUnit.Case, async: true

  alias JidoClaw.Skills
  alias JidoClaw.Skills.Compiler
  alias JidoClaw.Skills.Steps.AgentStep
  alias JidoClaw.Skills.Steps.CollectStep
  alias JidoClaw.Skills.Steps.IterativeStep
  alias Reactor.Planner

  describe "structure" do
    test "declares :extra_context as the only input" do
      {:ok, reactor} = Compiler.compile(sequential_skill())
      assert Enum.map(reactor.inputs, & &1.name) == [:extra_context]
    end

    test "generates positional atom ids, never atomizes YAML names" do
      {:ok, reactor} = Compiler.compile(dag_skill())
      names = step_names(reactor)

      # The internal Reactor ids are positional atoms + the terminal collector.
      assert Enum.sort(names) == [:__collect__, :step_1, :step_2, :step_3]

      # YAML step names ("run_tests", …) are NOT turned into atoms.
      refute :run_tests in names
      refute :review_code in names
      refute :synthesize in names
    end

    test "sets max_retries: 0 on every step (C-RETRIES)" do
      {:ok, reactor} = Compiler.compile(dag_skill())
      assert Enum.all?(reactor.steps, &(&1.max_retries == 0))
    end

    test "does not add ReactorMiddleware (C-MIDDLEWARE — runner is sole wirer)" do
      {:ok, reactor} = Compiler.compile(dag_skill())
      assert reactor.middleware == []
    end

    test "returns the terminal collect step" do
      {:ok, reactor} = Compiler.compile(dag_skill())
      assert reactor.return == :__collect__
    end

    test ":__collect__ depends on EVERY agent step, not only leaves" do
      {:ok, reactor} = Compiler.compile(dag_skill())
      collect = step_by_name(reactor, :__collect__)

      depended = collect |> result_arg_sources() |> Enum.sort()
      assert depended == [:step_1, :step_2, :step_3]
    end

    test "sequential: step N depends on every prior step (linear order + full history)" do
      {:ok, reactor} = Compiler.compile(sequential_skill())

      assert result_arg_sources(step_by_name(reactor, :step_1)) == []
      assert result_arg_sources(step_by_name(reactor, :step_2)) == [:step_1]
      assert Enum.sort(result_arg_sources(step_by_name(reactor, :step_3))) == [:step_1, :step_2]
    end

    test "dag: a step wires from_result for depends_on ∪ consumes" do
      {:ok, reactor} = Compiler.compile(dag_consumes_skill())
      # synthesize depends_on [run_tests] and consumes [build] → both wired.
      synth = step_by_name(reactor, :step_3)
      assert Enum.sort(result_arg_sources(synth)) == [:step_1, :step_2]
    end

    test "every agent step uses the AgentStep impl, collect uses CollectStep" do
      {:ok, reactor} = Compiler.compile(dag_skill())

      for id <- [:step_1, :step_2, :step_3] do
        assert {AgentStep, _opts} = step_by_name(reactor, id).impl
      end

      assert {CollectStep, _opts} = step_by_name(reactor, :__collect__).impl
    end

    test "iterative: single IterativeStep + collect, generator/evaluator in options" do
      {:ok, reactor} = Compiler.compile(iterative_skill())
      names = Enum.sort(step_names(reactor))
      assert names == [:__collect__, :step_1]

      assert {IterativeStep, opts} = step_by_name(reactor, :step_1).impl
      assert opts[:generator].name == "implement"
      assert opts[:evaluator].name == "verify"
      assert opts[:max_iterations] == 3
    end

    test "all compiled skills plan cleanly" do
      for skill <- [sequential_skill(), dag_skill(), dag_consumes_skill(), iterative_skill()] do
        {:ok, reactor} = Compiler.compile(skill)
        assert {:ok, _planned} = Planner.plan(reactor)
      end
    end
  end

  describe "validation" do
    test "rejects an empty skill" do
      assert {:error, msg} = Compiler.compile(%Skills{name: "empty", steps: []})
      assert msg =~ "no steps"
    end

    test "rejects duplicate non-nil step names" do
      skill = %Skills{
        name: "dup",
        steps: [
          %{"name" => "a", "template" => "coder", "task" => "x"},
          %{"name" => "a", "template" => "reviewer", "task" => "y", "depends_on" => ["a"]}
        ]
      }

      assert {:error, msg} = Compiler.compile(skill)
      assert msg =~ "Duplicate step names"
    end

    test "unnamed sequential steps never collide (nil names are not duplicates)" do
      skill = %Skills{
        name: "seq",
        steps: [
          %{"template" => "coder", "task" => "x"},
          %{"template" => "reviewer", "task" => "y"}
        ]
      }

      assert {:ok, _reactor} = Compiler.compile(skill)
    end

    test "rejects a missing depends_on target" do
      skill = %Skills{
        name: "missing_dep",
        steps: [
          %{"name" => "a", "template" => "coder", "task" => "x"},
          %{"name" => "b", "template" => "reviewer", "task" => "y", "depends_on" => ["ghost"]}
        ]
      }

      assert {:error, msg} = Compiler.compile(skill)
      assert msg =~ "Undefined dependencies"
      assert msg =~ "ghost"
    end

    test "rejects a missing consumes target" do
      skill = %Skills{
        name: "missing_consumes",
        steps: [
          %{"name" => "a", "template" => "coder", "task" => "x"},
          %{"name" => "b", "template" => "reviewer", "task" => "y", "consumes" => ["ghost"]}
        ]
      }

      assert {:error, msg} = Compiler.compile(skill)
      assert msg =~ "Undefined dependencies"
      assert msg =~ "ghost"
    end

    test "rejects a dependency cycle" do
      skill = %Skills{
        name: "cyclic",
        steps: [
          %{"name" => "a", "template" => "coder", "task" => "x", "depends_on" => ["b"]},
          %{"name" => "b", "template" => "reviewer", "task" => "y", "depends_on" => ["a"]}
        ]
      }

      assert {:error, msg} = Compiler.compile(skill)
      assert msg =~ "Cyclic"
    end

    test "rejects a consumes-only cycle (consumes is an ordering edge)" do
      skill = %Skills{
        name: "consumes_cycle",
        steps: [
          %{"name" => "a", "template" => "coder", "task" => "x", "consumes" => ["b"]},
          %{"name" => "b", "template" => "reviewer", "task" => "y", "consumes" => ["a"]}
        ]
      }

      assert {:error, msg} = Compiler.compile(skill)
      assert msg =~ "Cyclic"
    end

    test "iterative skill without a generator is rejected" do
      skill = %Skills{
        name: "no_gen",
        mode: "iterative",
        steps: [%{"name" => "v", "role" => "evaluator", "template" => "verifier", "task" => "c"}]
      }

      assert {:error, msg} = Compiler.compile(skill)
      assert msg =~ "generator"
    end
  end

  describe "every committed skill compiles to a plannable reactor" do
    test "all .jido/skills/*.yaml compile and plan" do
      skills = Skills.all()
      assert skills != [], "expected the Skills cache to have loaded committed skills"

      for skill <- skills do
        assert {:ok, reactor} = Compiler.compile(skill), "compile failed for #{skill.name}"
        assert {:ok, _planned} = Planner.plan(reactor), "plan failed for #{skill.name}"
        assert Enum.map(reactor.inputs, & &1.name) == [:extra_context]
        assert reactor.middleware == []
        assert reactor.return == :__collect__
      end
    end

    test "the on-disk unnamed-sequential refactor_safe compiles" do
      {:ok, skill} = Skills.get("refactor_safe")
      assert {:ok, reactor} = Compiler.compile(skill)
      # 3 unnamed steps → step_1..step_3 + collect; each step_name option nil.
      assert Enum.sort(step_names(reactor)) == [:__collect__, :step_1, :step_2, :step_3]

      for id <- [:step_1, :step_2, :step_3] do
        {AgentStep, opts} = step_by_name(reactor, id).impl
        assert opts[:step_name] == nil
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp step_names(reactor), do: Enum.map(reactor.steps, & &1.name)

  defp step_by_name(reactor, name), do: Enum.find(reactor.steps, &(&1.name == name))

  # The step_ids this step depends on via from_result arguments.
  defp result_arg_sources(step) do
    step.arguments
    |> Enum.filter(&match?(%Reactor.Template.Result{}, &1.source))
    |> Enum.map(& &1.source.name)
  end

  defp sequential_skill do
    %Skills{
      name: "seq",
      synthesis: "summarize",
      steps: [
        %{"template" => "coder", "task" => "a"},
        %{"template" => "reviewer", "task" => "b"},
        %{"template" => "test_runner", "task" => "c"}
      ]
    }
  end

  defp dag_skill do
    %Skills{
      name: "full_review",
      synthesis: "present",
      steps: [
        %{"name" => "run_tests", "template" => "test_runner", "task" => "test"},
        %{"name" => "review_code", "template" => "reviewer", "task" => "review"},
        %{
          "name" => "synthesize",
          "template" => "docs_writer",
          "task" => "combine",
          "depends_on" => ["run_tests", "review_code"]
        }
      ]
    }
  end

  defp dag_consumes_skill do
    %Skills{
      name: "consumes_dag",
      synthesis: "present",
      steps: [
        %{
          "name" => "build",
          "template" => "coder",
          "task" => "build",
          "produces" => %{"type" => "mod"}
        },
        %{"name" => "run_tests", "template" => "test_runner", "task" => "test"},
        %{
          "name" => "synthesize",
          "template" => "docs_writer",
          "task" => "combine",
          "depends_on" => ["run_tests"],
          "consumes" => ["build"]
        }
      ]
    }
  end

  defp iterative_skill do
    %Skills{
      name: "iterative_feature",
      mode: "iterative",
      max_iterations: 3,
      synthesis: "present",
      steps: [
        %{"name" => "implement", "role" => "generator", "template" => "coder", "task" => "build"},
        %{
          "name" => "verify",
          "role" => "evaluator",
          "template" => "verifier",
          "task" => "check",
          "consumes" => ["implement"]
        }
      ]
    }
  end
end
