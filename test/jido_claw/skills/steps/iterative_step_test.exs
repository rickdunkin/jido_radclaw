defmodule JidoClaw.Skills.Steps.IterativeStepTest do
  @moduledoc """
  Tests the generator/evaluator loop ported from the retired
  `IterativeWorkflow`: the pure `extract_roles/1` and `cap_result/2`, plus the
  live loop driven by stub agents (a FAIL-verdict evaluator runs to
  `max_iterations`, a passing one stops early, and a garbled/tokenless one is
  an INFRA input — retried in place on the `infra_retries` budget, never a
  burned iteration; camus C1-3). Verdict parsing itself lives in
  `JidoClaw.Orchestration.Verdict.IterativeEval` (see `verdict_test.exs`).

  The loop tests pass a Reactor context **without** `session_uuid`, so
  `AgentRunner` performs no durable writes — no sandbox needed.
  """
  use ExUnit.Case, async: false

  alias JidoClaw.Skills.Steps.IterativeStep
  alias JidoClaw.Test.{EchoStub, FailStub, PassStub}
  alias JidoClaw.Workflows.StepResult

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
        # A REAL failing verdict (VERDICT: FAIL) — EchoStub's tokenless
        # "echoed" is an *infra* input under the camus C1-3 contract.
        "eval_fail" => template(FailStub),
        "eval_infra" => template(EchoStub),
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

    test "produces verification_criteria render into BOTH the generator and evaluator tasks (item 9)" do
      produces = %{
        "type" => "elixir_module",
        "verification_criteria" => ["All tests pass", "No compiler warnings"]
      }

      options = [
        generator: %{
          name: "implement",
          template: "gen",
          task: "do implement",
          role: "generator",
          produces: produces,
          consumes: []
        },
        # EchoStub evaluator (tokenless ⇒ infra) with a zero budget: the loop
        # errors fast and BOTH sides' tasks were captured.
        evaluator: role("verify", "eval_infra", "evaluator"),
        max_iterations: 1,
        infra_retries: 0
      ]

      assert {:error, _message} =
               IterativeStep.run(%{extra_context: ""}, no_db_context(), options)

      # Generator spawned first: the previously-inert skill knob now shapes
      # its instruction…
      assert_receive {:echo_stub, :task, generator_task}
      assert generator_task =~ "Your output must satisfy these verification criteria"
      assert generator_task =~ "- All tests pass"
      assert generator_task =~ "- No compiler warnings"

      # …and the evaluator judges against the SAME declared criteria.
      assert_receive {:echo_stub, :task, evaluator_task}
      assert evaluator_task =~ "Verify the output against these declared criteria"
      assert evaluator_task =~ "- All tests pass"
    end

    test "a produces block WITHOUT criteria leaves both tasks criteria-free" do
      options = [
        generator: %{
          name: "implement",
          template: "gen",
          task: "do implement",
          role: "generator",
          produces: %{"type" => "elixir_module"},
          consumes: []
        },
        evaluator: role("verify", "eval_infra", "evaluator"),
        max_iterations: 1,
        infra_retries: 0
      ]

      assert {:error, _message} =
               IterativeStep.run(%{extra_context: ""}, no_db_context(), options)

      assert_receive {:echo_stub, :task, generator_task}
      # The ARTIFACTS instruction still renders (produces is non-empty)…
      assert generator_task =~ "ARTIFACTS:"
      # …but no criteria section appears on either side.
      refute generator_task =~ "verification criteria"

      assert_receive {:echo_stub, :task, evaluator_task}
      refute evaluator_task =~ "declared criteria"
    end

    # Camus C1-3 — the named live bug: an evaluator that emits NO verdict token
    # used to parse as `:fail` and burn an iteration exactly like a real fail
    # (the "#1 cause of runaway loops"). Under the normalizer it is INFRA:
    # re-run the EVALUATOR ONLY (same iteration, same generator output) on the
    # separate `infra_retries` budget, then a terminal error — never `{:ok, _}`,
    # never a second generator turn.
    test "an evaluator with no verdict token is infra — retried in place, never iterated" do
      options = [
        generator: role("implement", "gen", "generator"),
        evaluator: role("verify", "eval_infra", "evaluator"),
        max_iterations: 5,
        infra_retries: 2
      ]

      assert {:error, message} =
               IterativeStep.run(%{extra_context: ""}, no_db_context(), options)

      assert message =~ "Evaluator infra failure after 2 retries"
      assert message =~ "no_verdict_token"

      # Generator ran ONCE; evaluator ran 1 + infra_retries = 3 times → exactly
      # 4 spawns (an iterated loop would have re-run the generator too).
      assert capture_count(4) == 4
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
