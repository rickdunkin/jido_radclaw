defmodule JidoClaw.Skills.Steps.IterativeStepTest do
  @moduledoc """
  Tests the generator/evaluator loop ported from the retired
  `IterativeWorkflow`: the pure `parse_verdict/1`, `extract_roles/1`, and
  `cap_result/2`, plus the live loop driven by EchoStub/PassStub agents (a
  failing evaluator runs to `max_iterations`, a passing one stops early).

  The loop tests pass a Reactor context **without** `session_uuid`, so
  `AgentRunner` performs no durable writes — no sandbox needed.
  """
  use ExUnit.Case, async: false

  alias JidoClaw.Skills.Steps.IterativeStep
  alias JidoClaw.Test.{EchoStub, PassStub}
  alias JidoClaw.Workflows.StepResult

  describe "parse_verdict/1" do
    test "parses VERDICT: PASS / FAIL (case-insensitive, last wins)" do
      assert IterativeStep.parse_verdict("All good. VERDICT: PASS") == :pass
      assert IterativeStep.parse_verdict("verdict: pass") == :pass
      assert IterativeStep.parse_verdict("Found issues. VERDICT: FAIL") == :fail
      assert IterativeStep.parse_verdict("VERDICT: FAIL\nActually VERDICT: PASS") == :pass
      assert IterativeStep.parse_verdict("To get VERDICT: PASS, fix X. VERDICT: FAIL") == :fail
    end

    test "defaults to :fail for no verdict / empty / nil" do
      assert IterativeStep.parse_verdict("nothing here") == :fail
      assert IterativeStep.parse_verdict("") == :fail
      assert IterativeStep.parse_verdict(nil) == :fail
    end

    test "accepts typed verdict maps (atom and string keyed)" do
      assert IterativeStep.parse_verdict(%{verdict: :pass}) == :pass
      assert IterativeStep.parse_verdict(%{verdict: :fail}) == :fail
      assert IterativeStep.parse_verdict(%{"verdict" => "pass"}) == :pass
      assert IterativeStep.parse_verdict(%{"verdict" => "fail"}) == :fail
      assert IterativeStep.parse_verdict(%{verdict: :unknown}) == :fail
    end
  end

  describe "extract_roles/1" do
    test "extracts generator and evaluator by role" do
      assert {:ok, gen, eval} = IterativeStep.extract_roles(iterative_skill())
      assert gen.name == "implement"
      assert gen.template == "coder"
      assert eval.name == "verify"
      assert eval.template == "verifier"
    end

    test "role maps preserve saga metadata: retry raw, irreversible strict boolean" do
      # The generator is string-keyed to show StepNormalizer canonicalization
      # feeds through to the preserved fields.
      skill = %JidoClaw.Skills{
        name: "meta",
        steps: [
          %{
            "name" => "implement",
            "role" => "generator",
            "template" => "coder",
            "task" => "build",
            "retry" => 2
          },
          %{
            name: "verify",
            role: "evaluator",
            template: "verifier",
            task: "check",
            irreversible: true
          }
        ]
      }

      assert {:ok, gen, eval} = IterativeStep.extract_roles(skill)
      assert gen.retry == 2
      assert eval.irreversible == true

      # Absent metadata: retry stays nil (the compiler normalizes), and
      # irreversible normalizes to a strict false.
      assert eval.retry == nil
      assert gen.irreversible == false
    end

    test "errors when a role is missing or a named step lacks a name" do
      no_gen = %JidoClaw.Skills{
        name: "x",
        steps: [%{"name" => "v", "role" => "evaluator", "template" => "verifier", "task" => "c"}]
      }

      assert {:error, msg} = IterativeStep.extract_roles(no_gen)
      assert msg =~ "no step with role: generator"

      gen_no_name = %JidoClaw.Skills{
        name: "x",
        steps: [
          %{"role" => "generator", "template" => "coder", "task" => "b"},
          %{"name" => "v", "role" => "evaluator", "template" => "verifier", "task" => "c"}
        ]
      }

      assert {:error, msg} = IterativeStep.extract_roles(gen_no_name)
      assert msg =~ "Generator step must have a name"
    end
  end

  describe "cap_result/2" do
    test "returns generator result first, evaluator feedback second" do
      gen = %StepResult{name: "implement", template: "coder", result: "def hello, do: :world"}
      eval = %StepResult{name: "verify", template: "verifier", result: "VERDICT: FAIL"}

      assert {:ok, [returned_gen, returned_eval]} = IterativeStep.cap_result(gen, eval)
      assert returned_gen.result == "def hello, do: :world"
      assert returned_eval.result =~ "VERDICT: FAIL"
    end
  end

  describe "run/3 — live loop" do
    setup do
      Application.put_env(:jido_claw, :echo_stub_target, self())

      Application.put_env(:jido_claw, :agent_templates_override, %{
        "gen" => template(EchoStub),
        "eval_fail" => template(EchoStub),
        "eval_pass" => template(PassStub)
      })

      on_exit(fn ->
        Application.delete_env(:jido_claw, :agent_templates_override)
        Application.delete_env(:jido_claw, :echo_stub_target)
      end)

      :ok
    end

    test "a failing evaluator runs to max_iterations and caps with [gen, eval]" do
      options = [
        generator: role("implement", "gen", "generator"),
        evaluator: role("verify", "eval_fail", "evaluator"),
        max_iterations: 2
      ]

      assert {:ok, [%StepResult{} = gen, %StepResult{} = eval]} =
               IterativeStep.run(%{extra_context: ""}, no_db_context(), options)

      assert gen.template == "gen"
      assert eval.template == "eval_fail"

      # max_iterations: 2 with a never-passing evaluator → gen+eval × 2 = 4 spawns.
      assert capture_count(4) == 4
    end

    test "a passing evaluator stops after the first iteration" do
      options = [
        generator: role("implement", "gen", "generator"),
        evaluator: role("verify", "eval_pass", "evaluator"),
        max_iterations: 5
      ]

      assert {:ok, [_gen, eval]} =
               IterativeStep.run(%{extra_context: ""}, no_db_context(), options)

      assert eval.result =~ "VERDICT: PASS"
      # One iteration only: gen + eval = 2 spawns.
      assert capture_count(2) == 2
      refute_received {:echo_stub, :tool_context, _}
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # A Reactor context with no session_uuid → AgentRunner does no DB writes.
  defp no_db_context, do: %{tenant: "t", actor: %{kind: :system}, workspace_id: "ws-iter"}

  defp role(name, template, role) do
    %{name: name, template: template, task: "do #{name}", role: role, produces: nil, consumes: []}
  end

  defp template(module) do
    %{module: module, description: "stub", model: :fast, max_iterations: 1}
  end

  # Drain exactly `n` captures (and confirm at least n arrived).
  defp capture_count(n) do
    Enum.count(1..n, fn _ ->
      receive do
        {:echo_stub, :tool_context, _tc} -> true
      after
        5_000 -> false
      end
    end)
  end

  defp iterative_skill do
    %JidoClaw.Skills{
      name: "iterative_feature",
      mode: "iterative",
      max_iterations: 3,
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
