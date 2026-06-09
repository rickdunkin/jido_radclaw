defmodule JidoClaw.Skills.Steps.AgentStepTest do
  @moduledoc """
  Tests the sequential/dag leaf step's context reconstruction: it rebuilds the
  dependency/preceding results (from `:upstream`) and the producer/artifact
  results (from `:consumes`) out of its wired `arguments`, formats them via
  `ContextBuilder`, injects produces, and hands the assembled task to
  `AgentRunner`.

  Drives a real EchoStub agent (which echoes back the task it received), with a
  context lacking `session_uuid` so no durable writes occur — no sandbox.
  """
  use ExUnit.Case, async: false

  alias JidoClaw.Skills.Steps.AgentStep
  alias JidoClaw.Test.EchoStub
  alias JidoClaw.Workflows.StepResult

  setup do
    Application.put_env(:jido_claw, :echo_stub_target, self())

    Application.put_env(:jido_claw, :agent_templates_override, %{
      "echo" => %{module: EchoStub, description: "d", model: :fast, max_iterations: 1}
    })

    on_exit(fn ->
      Application.delete_env(:jido_claw, :agent_templates_override)
      Application.delete_env(:jido_claw, :echo_stub_target)
    end)

    :ok
  end

  test "passes step_name through to StepResult.name" do
    options = base_options(step_name: "review_code")

    assert {:ok, %StepResult{name: "review_code", template: "echo"}} =
             AgentStep.run(%{extra_context: ""}, context(), options)
  end

  test "an unnamed step yields StepResult.name == nil (label falls back to template)" do
    options = base_options(step_name: nil)

    assert {:ok, %StepResult{name: nil, template: "echo"}} =
             AgentStep.run(%{extra_context: ""}, context(), options)
  end

  test "extra_context flows into the assembled task" do
    options = base_options(step_name: "s")

    assert {:ok, _} = AgentStep.run(%{extra_context: "PLEASE FOCUS ON SPEED"}, context(), options)
    assert_receive {:echo_stub, :task, task}, 5_000
    assert task =~ "do the thing"
    assert task =~ "PLEASE FOCUS ON SPEED"
  end

  test "deps mode includes dependency results in the task" do
    dep = %StepResult{name: "run_tests", template: "test_runner", result: "ALL TESTS GREEN"}
    arguments = %{extra_context: "", step_1: dep}

    options =
      base_options(
        step_name: "synthesize",
        context_format: :deps,
        upstream: [{:step_1, "run_tests"}]
      )

    assert {:ok, _} = AgentStep.run(arguments, context(), options)
    assert_receive {:echo_stub, :task, task}, 5_000
    assert task =~ "ALL TESTS GREEN"
    assert task =~ "run_tests"
  end

  test "preceding mode includes full prior history oldest-first" do
    s1 = %StepResult{name: "a", template: "coder", result: "FIRST OUTPUT"}
    s2 = %StepResult{name: "b", template: "reviewer", result: "SECOND OUTPUT"}
    arguments = %{extra_context: "", step_1: s1, step_2: s2}

    options =
      base_options(
        step_name: nil,
        context_format: :preceding,
        upstream: [{:step_1, nil}, {:step_2, nil}]
      )

    assert {:ok, _} = AgentStep.run(arguments, context(), options)
    assert_receive {:echo_stub, :task, task}, 5_000
    assert task =~ "FIRST OUTPUT"
    assert task =~ "SECOND OUTPUT"
    # oldest-first: FIRST precedes SECOND.
    assert task =~ ~r/FIRST OUTPUT.*SECOND OUTPUT/s
  end

  test "consumes wires artifact context (static produces + dynamic artifacts)" do
    producer = %StepResult{
      name: "build",
      template: "coder",
      result: "built it",
      artifacts: %{"url" => "http://localhost:4000"}
    }

    arguments = %{extra_context: "", step_1: producer}

    options =
      base_options(
        step_name: "deploy",
        context_format: :deps,
        consumes: [{:step_1, "build", %{"type" => "elixir_module"}}]
      )

    assert {:ok, _} = AgentStep.run(arguments, context(), options)
    assert_receive {:echo_stub, :task, task}, 5_000
    assert task =~ "Artifact Context"
    assert task =~ "build"
    assert task =~ "http://localhost:4000"
    assert task =~ "elixir_module"
  end

  # A context with no session_uuid → AgentRunner does no DB writes.
  defp context, do: %{tenant: "t", actor: %{kind: :system}, workspace_id: "ws-step"}

  defp base_options(overrides) do
    [
      template: "echo",
      task: "do the thing",
      produces: nil,
      step_name: nil,
      context_format: :deps,
      upstream: [],
      consumes: []
    ]
    |> Keyword.merge(overrides)
  end
end
