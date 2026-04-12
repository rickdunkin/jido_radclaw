defmodule JidoClaw.Workflows.IterativeWorkflowTest do
  use ExUnit.Case, async: true

  alias JidoClaw.Workflows.IterativeWorkflow

  describe "parse_verdict/1" do
    test "parses VERDICT: PASS" do
      assert IterativeWorkflow.parse_verdict("Everything looks good. VERDICT: PASS") == :pass
    end

    test "parses case-insensitive PASS" do
      assert IterativeWorkflow.parse_verdict("verdict: pass") == :pass
    end

    test "parses VERDICT: PASS with extra whitespace" do
      assert IterativeWorkflow.parse_verdict("VERDICT:   PASS") == :pass
    end

    test "parses VERDICT: FAIL" do
      assert IterativeWorkflow.parse_verdict("Found issues. VERDICT: FAIL") == :fail
    end

    test "parses case-insensitive FAIL" do
      assert IterativeWorkflow.parse_verdict("verdict: fail") == :fail
    end

    test "defaults to :fail when no verdict found" do
      assert IterativeWorkflow.parse_verdict("No verdict in this text") == :fail
    end

    test "defaults to :fail for empty string" do
      assert IterativeWorkflow.parse_verdict("") == :fail
    end

    test "defaults to :fail for nil" do
      assert IterativeWorkflow.parse_verdict(nil) == :fail
    end

    test "last verdict wins when both PASS and FAIL appear" do
      assert IterativeWorkflow.parse_verdict("VERDICT: FAIL\nActually VERDICT: PASS") == :pass
      assert IterativeWorkflow.parse_verdict("VERDICT: PASS\nActually VERDICT: FAIL") == :fail
    end

    test "ignores instructional mention of VERDICT: PASS before final FAIL" do
      text = "To get VERDICT: PASS, fix X. VERDICT: FAIL"
      assert IterativeWorkflow.parse_verdict(text) == :fail
    end
  end

  describe "extract_roles/1" do
    test "extracts generator and evaluator from skill" do
      skill = make_iterative_skill()
      assert {:ok, generator, evaluator} = IterativeWorkflow.extract_roles(skill)

      assert generator.name == "implement"
      assert generator.role == "generator"
      assert generator.template == "coder"

      assert evaluator.name == "verify"
      assert evaluator.role == "evaluator"
      assert evaluator.template == "verifier"
    end

    test "returns error when no generator" do
      skill = %JidoClaw.Skills{
        name: "bad",
        steps: [
          %{
            "name" => "verify",
            "role" => "evaluator",
            "template" => "verifier",
            "task" => "check"
          }
        ]
      }

      assert {:error, msg} = IterativeWorkflow.extract_roles(skill)
      assert msg =~ "no step with role: generator"
    end

    test "returns error when no evaluator" do
      skill = %JidoClaw.Skills{
        name: "bad",
        steps: [
          %{"name" => "impl", "role" => "generator", "template" => "coder", "task" => "build"}
        ]
      }

      assert {:error, msg} = IterativeWorkflow.extract_roles(skill)
      assert msg =~ "no step with role: evaluator"
    end

    test "returns error when generator has no name" do
      skill = %JidoClaw.Skills{
        name: "bad",
        steps: [
          %{"role" => "generator", "template" => "coder", "task" => "build"},
          %{
            "name" => "verify",
            "role" => "evaluator",
            "template" => "verifier",
            "task" => "check"
          }
        ]
      }

      assert {:error, msg} = IterativeWorkflow.extract_roles(skill)
      assert msg =~ "Generator step must have a name"
    end

    test "returns error when evaluator has no name" do
      skill = %JidoClaw.Skills{
        name: "bad",
        steps: [
          %{"name" => "impl", "role" => "generator", "template" => "coder", "task" => "build"},
          %{"role" => "evaluator", "template" => "verifier", "task" => "check"}
        ]
      }

      assert {:error, msg} = IterativeWorkflow.extract_roles(skill)
      assert msg =~ "Evaluator step must have a name"
    end

    test "handles atom keys in step maps" do
      skill = %JidoClaw.Skills{
        name: "atom_keys",
        steps: [
          %{name: "impl", role: "generator", template: "coder", task: "build"},
          %{name: "verify", role: "evaluator", template: "verifier", task: "check"}
        ]
      }

      assert {:ok, gen, eval} = IterativeWorkflow.extract_roles(skill)
      assert gen.name == "impl"
      assert eval.name == "verify"
    end
  end

  describe "cap_result/2 (max-iteration return payload)" do
    test "returns generator result in first slot, not evaluator feedback" do
      gen = %JidoClaw.Workflows.StepResult{
        name: "implement",
        template: "coder",
        result: "def hello, do: :world"
      }

      eval = %JidoClaw.Workflows.StepResult{
        name: "verify",
        template: "verifier",
        result: "Tests fail: undefined function hello/0. VERDICT: FAIL"
      }

      assert {:ok, [returned_gen, returned_eval]} = IterativeWorkflow.cap_result(gen, eval)

      # The generator result (implementation code) must be in the first slot
      assert returned_gen.name == "implement"
      assert returned_gen.result == "def hello, do: :world"

      # The evaluator result (feedback) must be in the second slot
      assert returned_eval.name == "verify"
      assert returned_eval.result =~ "VERDICT: FAIL"
    end

    test "returns exactly two StepResult entries" do
      gen = %JidoClaw.Workflows.StepResult{name: "gen", result: "code"}
      eval = %JidoClaw.Workflows.StepResult{name: "eval", result: "feedback"}

      assert {:ok, results} = IterativeWorkflow.cap_result(gen, eval)
      assert length(results) == 2
      assert Enum.all?(results, &match?(%JidoClaw.Workflows.StepResult{}, &1))
    end
  end

  describe "execution_mode integration" do
    test "skills with mode: iterative route to :iterative" do
      skill = %JidoClaw.Skills{name: "test", mode: "iterative", steps: []}
      assert JidoClaw.Skills.execution_mode(skill) == :iterative
    end

    test "skills with DAG steps route to :dag" do
      skill = %JidoClaw.Skills{
        name: "test",
        steps: [%{"name" => "a", "template" => "coder", "task" => "x", "depends_on" => ["b"]}]
      }

      assert JidoClaw.Skills.execution_mode(skill) == :dag
    end

    test "plain sequential skills route to :sequential" do
      skill = %JidoClaw.Skills{
        name: "test",
        steps: [%{"template" => "coder", "task" => "x"}]
      }

      assert JidoClaw.Skills.execution_mode(skill) == :sequential
    end
  end

  describe "RunSkill.build_result/2 label selection" do
    alias JidoClaw.Tools.RunSkill
    alias JidoClaw.Workflows.StepResult

    test "uses step name as primary label, not template name" do
      skill = %JidoClaw.Skills{name: "test_skill", synthesis: "summarize"}

      results = [
        %StepResult{name: "run_tests", template: "test_runner", result: "all pass"},
        %StepResult{name: "review_code", template: "reviewer", result: "looks good"}
      ]

      output = RunSkill.build_result(skill, results)

      assert output.results =~ "run_tests"
      assert output.results =~ "review_code"
      refute output.results =~ "## Step 1: test_runner"
      refute output.results =~ "## Step 2: reviewer"
    end

    test "falls back to template when name is nil" do
      skill = %JidoClaw.Skills{name: "test_skill", synthesis: "summarize"}

      results = [
        %StepResult{name: nil, template: "coder", result: "done"}
      ]

      output = RunSkill.build_result(skill, results)
      assert output.results =~ "## Step 1: coder"
    end

    test "two steps with the same template are distinguishable by name" do
      skill = %JidoClaw.Skills{name: "test_skill", synthesis: "summarize"}

      results = [
        %StepResult{name: "unit_tests", template: "test_runner", result: "unit pass"},
        %StepResult{
          name: "integration_tests",
          template: "test_runner",
          result: "integration pass"
        }
      ]

      output = RunSkill.build_result(skill, results)

      assert output.results =~ "## Step 1: unit_tests"
      assert output.results =~ "## Step 2: integration_tests"
    end

    test "handles legacy {label, text} tuples" do
      skill = %JidoClaw.Skills{name: "test_skill", synthesis: "summarize"}
      results = [{"old_step", "old output"}]

      output = RunSkill.build_result(skill, results)
      assert output.results =~ "old_step"
      assert output.steps_completed == 1
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp make_iterative_skill do
    %JidoClaw.Skills{
      name: "iterative_feature",
      mode: "iterative",
      max_iterations: 3,
      steps: [
        %{
          "name" => "implement",
          "role" => "generator",
          "template" => "coder",
          "task" => "Implement the feature",
          "produces" => %{"type" => "elixir_module"}
        },
        %{
          "name" => "verify",
          "role" => "evaluator",
          "template" => "verifier",
          "task" => "Verify and emit VERDICT: PASS or VERDICT: FAIL",
          "consumes" => ["implement"]
        }
      ],
      synthesis: "Present final implementation"
    }
  end
end
