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

  describe "run/3 — AR-6 composer-stage persona seam (real worker telemetry)" do
    setup do
      original_doctrine = Application.get_env(:jido_claw, :doctrine)
      original_psychology = Application.get_env(:jido_claw, :psychology)
      # Both flags on: :doctrine is the master injection gate, :psychology adds the section.
      Application.put_env(:jido_claw, :doctrine, enabled?: true)
      Application.put_env(:jido_claw, :psychology, enabled?: true)

      handler_id = "ar6-agentstep-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:jido_claw, :agent, :prompt_injected],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:injected, metadata})
        end,
        nil
      )

      on_exit(fn ->
        :telemetry.detach(handler_id)
        restore_env(:doctrine, original_doctrine)
        restore_env(:psychology, original_psychology)
      end)

      :ok
    end

    @tag :capture_log
    test "the dedicated catalog_stage_name rides through to telemetry metadata.stage" do
      # A real `reviewer` worker (not EchoStub — which only overrides ask_sync/3 and never
      # emits this telemetry). The injection fires before the LLM turn, so drive run/3 in a
      # Task and assert the early event, then stop the worker via metadata.pid.
      options =
        seam_options(step_name: "security-reviewer", catalog_stage_name: "security-reviewer")

      run_seam_step_async(options)

      assert_receive {:injected, metadata}, 10_000
      assert metadata.source == :doctrine
      assert metadata.template == "reviewer"
      # The stage value fully determines the persona: "security-reviewer" → Defender
      # (subagent_prompt_test proves the rendered text; persona_test proves resolve/2).
      assert metadata.stage == "security-reviewer"

      if is_pid(metadata.pid), do: JidoClaw.Jido.stop_agent(metadata.pid)
    end

    @tag :capture_log
    test "an arbitrary step_name colliding with a stage name does NOT leak as the stage (finding #1)" do
      # The bug guard: only the wave-builder sets catalog_stage_name. A skill step that merely
      # NAMES itself "security-reviewer" (via step_name) omits it → metadata.stage == nil →
      # the template persona (Skeptic), never the security-reviewer stage persona (Defender).
      options = seam_options(step_name: "security-reviewer")
      run_seam_step_async(options)

      assert_receive {:injected, metadata}, 10_000
      assert metadata.template == "reviewer"
      assert metadata.stage == nil

      if is_pid(metadata.pid), do: JidoClaw.Jido.stop_agent(metadata.pid)
    end
  end

  # A context with no session_uuid → AgentRunner does no DB writes.
  defp context, do: %{tenant: "t", actor: %{kind: :system}, workspace_id: "ws-step"}

  defp restore_env(key, nil), do: Application.delete_env(:jido_claw, key)
  defp restore_env(key, val), do: Application.put_env(:jido_claw, key, val)

  # Drive AgentStep.run/3 in an unlinked task. The injection telemetry fires BEFORE the
  # worker's LLM turn, so each test asserts the early event and then stops the worker — which
  # aborts THIS task's in-flight `await_completion` with a deliberate `:noproc` exit (the
  # GenServer.call to the now-dead worker; it propagates past run_registered_step's `rescue`,
  # which catches raises, not exits). Catch that expected exit here so the intentional
  # shutdown ends the task normally — no `[error] Task terminating` detached from ExUnit in
  # the CI log, while any UNEXPECTED failure before the abort still surfaces.
  defp run_seam_step_async(options) do
    Task.start(fn ->
      try do
        AgentStep.run(%{extra_context: ""}, %{}, options)
      catch
        :exit, _ -> :ok
      end
    end)
  end

  # Wave-builder-shaped options pointing at the real `reviewer` template (the EchoStub
  # override only covers "echo"; "reviewer" falls through to the static template map).
  defp seam_options(overrides) do
    Keyword.merge(
      [
        template: "reviewer",
        task: "review the diff",
        produces: nil,
        step_name: nil,
        context_format: :deps,
        upstream: [],
        consumes: []
      ],
      overrides
    )
  end

  defp base_options(overrides) do
    Keyword.merge(
      [
        template: "echo",
        task: "do the thing",
        produces: nil,
        step_name: nil,
        context_format: :deps,
        upstream: [],
        consumes: []
      ],
      overrides
    )
  end
end
