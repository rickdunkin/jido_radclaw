defmodule JidoClaw.Skills.StepRetryTest do
  @moduledoc """
  WS4: the per-step `retry:` / `compensate:` / `irreversible:` metadata.

  The end-to-end retry proof drives a real compiled skill through
  `ReactorRunner` with `FlakyStub` (fails once, then succeeds) — asserting the
  `compensate/4 -> :retry` policy actually re-executes the step (a
  `step_retried` event followed by success), not just that `max_retries` was
  plumbed. Compile-time validation and the `can?/2` capability matrix are
  pure.
  """
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Orchestration.ReactorRunner
  alias JidoClaw.Orchestration.WorkflowEvent
  alias JidoClaw.Orchestration.WorkflowStep
  alias JidoClaw.Skills.Compiler
  alias JidoClaw.Skills.Steps.AgentStep
  alias JidoClaw.Test.EchoStub
  alias JidoClaw.Test.ErrorStub
  alias JidoClaw.Test.FlakyStub

  setup do
    Application.put_env(:jido_claw, :agent_templates_override, %{
      "echo_test" => %{
        module: EchoStub,
        description: "test-only echo template",
        model: :fast,
        max_iterations: 1
      },
      "flaky_test" => %{
        module: FlakyStub,
        description: "test-only flaky template",
        model: :fast,
        max_iterations: 1
      },
      "error_test" => %{
        module: ErrorStub,
        description: "test-only error template",
        model: :fast,
        max_iterations: 1
      }
    })

    Application.put_env(:jido_claw, :echo_stub_target, self())

    on_exit(fn ->
      Application.delete_env(:jido_claw, :agent_templates_override)
      Application.delete_env(:jido_claw, :echo_stub_target)
      Application.delete_env(:jido_claw, :flaky_stub_failures_remaining)
    end)

    %{tenant_id: tenant, workspace: workspace, session: session} = seed_full(tenant_label: "rty")
    {:ok, tenant: tenant, workspace: workspace, session: session}
  end

  describe "end-to-end retry policy" do
    test "retry: 2 re-executes a failed step to success (compensate -> :retry)", ctx do
      # First invocation fails, second succeeds — inside the retry budget.
      Application.put_env(:jido_claw, :flaky_stub_failures_remaining, 1)

      skill = %JidoClaw.Skills{
        name: "retry_smoke",
        synthesis: "s",
        steps: [
          %{"name" => "flaky_step", "template" => "flaky_test", "task" => "do it", "retry" => 2}
        ]
      }

      assert {:ok, _value, run} = run_skill(skill, ctx)
      assert run.status == :completed

      # Both attempts actually hit the agent.
      assert_received {:stub_invoked, :flaky_fail}
      assert_received {:stub_invoked, :flaky_ok}

      kinds = kinds(run, ctx)
      assert :step_failed in kinds
      assert :step_retried in kinds
      assert :step_completed in kinds

      # The retried step UPSERTS into ONE row (identity-keyed), final state
      # completed with the prior attempt's error cleared.
      {:ok, steps} = WorkflowStep.for_run(run.id, scope(ctx))
      flaky_rows = Enum.filter(steps, &(&1.name == "flaky_step"))
      assert [row] = flaky_rows
      assert row.status == :completed
      assert is_nil(row.error)
    end

    test "retry: 0 / absent fails terminally on the first error (no retry)", ctx do
      skill = %JidoClaw.Skills{
        name: "no_retry",
        synthesis: "s",
        steps: [%{"name" => "boom", "template" => "error_test", "task" => "x"}]
      }

      assert {:error, _reason, run} = run_skill(skill, ctx)
      assert run.status == :failed

      # Exactly one attempt — the stub ran once and nothing retried it.
      assert_received {:stub_invoked, :error}
      refute_received {:stub_invoked, :error}

      kinds = kinds(run, ctx)
      assert :step_failed in kinds
      refute :step_retried in kinds

      {:ok, steps} = WorkflowStep.for_run(run.id, scope(ctx))
      assert [row] = Enum.filter(steps, &(&1.name == "boom"))
      assert row.status == :failed
      assert is_binary(row.error)
    end

    test "irreversible: true rides into step_* event payloads", ctx do
      skill = %JidoClaw.Skills{
        name: "irrev",
        synthesis: "s",
        steps: [
          %{
            "name" => "writey",
            "template" => "echo_test",
            "task" => "x",
            "compensate" => "clean up the write",
            "irreversible" => true
          }
        ]
      }

      assert {:ok, _value, run} = run_skill(skill, ctx)
      assert run.status == :completed

      {:ok, events} = WorkflowEvent.for_run(run.id, scope(ctx))

      step_events =
        Enum.filter(
          events,
          &(&1.kind in [:step_started, :step_completed] and
              &1.payload["name"] == "writey")
        )

      assert step_events != []
      assert Enum.all?(step_events, &(&1.payload["irreversible"] == true))
    end
  end

  describe "compile-time validation" do
    test ~S(retry: "infinity" is rejected) do
      assert {:error, message} = Compiler.compile(skill_with(%{"retry" => "infinity"}))
      assert message =~ "retry must be a non-negative integer"
    end

    test "negative retry is rejected" do
      assert {:error, message} = Compiler.compile(skill_with(%{"retry" => -1}))
      assert message =~ "retry must be a non-negative integer"
    end

    test "non-integer retry is rejected" do
      assert {:error, message} = Compiler.compile(skill_with(%{"retry" => 1.5}))
      assert message =~ "retry must be a non-negative integer"
    end

    test "empty compensate task is rejected" do
      assert {:error, message} = Compiler.compile(skill_with(%{"compensate" => "  "}))
      assert message =~ "compensate must be a non-empty task string"
    end

    test "non-boolean irreversible is rejected" do
      assert {:error, message} = Compiler.compile(skill_with(%{"irreversible" => "yes"}))
      assert message =~ "irreversible must be a boolean"
    end

    test "retry threads into the Reactor step's max_retries" do
      {:ok, reactor} = Compiler.compile(skill_with(%{"retry" => 3}))
      step = find_agent_step(reactor)
      assert step.max_retries == 3
    end
  end

  describe "can?/2 capability matrix" do
    test "no flags -> NO capability (not a no-op)" do
      step = compiled_step(%{})
      refute AgentStep.can?(step, :compensate)
      refute AgentStep.can?(step, :undo)
    end

    test "retry > 0 -> compensate-capable, not undo-capable" do
      step = compiled_step(%{"retry" => 2})
      assert AgentStep.can?(step, :compensate)
      refute AgentStep.can?(step, :undo)
    end

    test "compensate declared -> compensate- and undo-capable" do
      step = compiled_step(%{"compensate" => "clean up"})
      assert AgentStep.can?(step, :compensate)
      assert AgentStep.can?(step, :undo)
    end

    test "compensate + irreversible -> undo capability is withdrawn" do
      step = compiled_step(%{"compensate" => "clean up", "irreversible" => true})
      assert AgentStep.can?(step, :compensate)
      refute AgentStep.can?(step, :undo)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp skill_with(extra) do
    %JidoClaw.Skills{
      name: "cap_matrix",
      synthesis: "s",
      steps: [Map.merge(%{"name" => "one", "template" => "echo_test", "task" => "x"}, extra)]
    }
  end

  defp compiled_step(extra) do
    {:ok, reactor} = Compiler.compile(skill_with(extra))
    find_agent_step(reactor)
  end

  defp find_agent_step(reactor) do
    Enum.find(reactor.steps, &match?({AgentStep, _opts}, &1.impl))
  end

  defp run_skill(skill, ctx) do
    {:ok, reactor} = Compiler.compile(skill)

    scope = %{
      tenant_id: ctx.tenant,
      session_id: "rty-sess",
      session_uuid: ctx.session.id,
      workspace_id: "shared-ws",
      workspace_uuid: ctx.workspace.id,
      project_dir: File.cwd!()
    }

    ReactorRunner.run(reactor, %{extra_context: ""},
      tenant: ctx.tenant,
      actor: actor_for(ctx.tenant),
      name: skill.name,
      async?: true,
      context: scope
    )
  end

  defp kinds(run, ctx) do
    {:ok, events} = WorkflowEvent.for_run(run.id, scope(ctx))
    Enum.map(events, & &1.kind)
  end

  defp scope(%{tenant: tenant}), do: [tenant: tenant, actor: actor_for(tenant)]
end
