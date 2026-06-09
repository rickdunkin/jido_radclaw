defmodule JidoClaw.Orchestration.WorkflowRunnerTest do
  @moduledoc """
  Pins the cron `WorkflowRunner` — now a thin adapter that compiles the named
  skill to a Reactor and runs it through the `ReactorRunner` envelope. Drives a
  real cached skill (`explore_codebase`) with its templates stubbed via
  `:agent_templates_override`, re-expressing the original behaviors:

    * success → `:completed`, `WorkflowRun.result` populated, the timeline now
      includes `step_*` events, the steps share a `cron:<job>:<n>` workspace_id,
      and `:run_started`/`:run_completed` broadcast;
    * a step error → `:failed` + `:run_failed`, the failing step running once
      (`max_retries: 0`), never stranded `:running`;
    * a step that *raises* → still `:failed` (AgentRunner's never-crash boundary);
    * unknown skill → `{:error, _}`, no run row, no broadcast.
  """
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Orchestration.RunPubSub
  alias JidoClaw.Orchestration.WorkflowEvent
  alias JidoClaw.Orchestration.WorkflowRun
  alias JidoClaw.Orchestration.WorkflowRunner
  alias JidoClaw.Test.{CrashStub, EchoStub, ErrorStub}

  defp event_kinds(run_id, tenant) do
    {:ok, events} = WorkflowEvent.for_run(run_id, tenant: tenant, actor: actor_for(tenant))
    Enum.map(events, & &1.kind)
  end

  defp template(module) do
    %{module: module, description: "stub", model: :fast, max_iterations: 1}
  end

  defp put_templates(map) do
    Application.put_env(:jido_claw, :agent_templates_override, map)
  end

  setup do
    tenant = seed_tenant("wfrunner")
    Application.put_env(:jido_claw, :echo_stub_target, self())

    on_exit(fn ->
      Application.delete_env(:jido_claw, :agent_templates_override)
      Application.delete_env(:jido_claw, :echo_stub_target)
    end)

    RunPubSub.subscribe_all()
    {:ok, tenant: tenant}
  end

  test "success drives the run to :completed with a result, step_* timeline, shared workspace_id",
       %{tenant: tenant} do
    # explore_codebase = explore(researcher) → document(docs_writer).
    put_templates(%{"researcher" => template(EchoStub), "docs_writer" => template(EchoStub)})

    unique_id = "wfrun-#{System.unique_integer([:positive])}"

    state = %{
      id: unique_id,
      tenant_id: tenant,
      workflow_name: "explore_codebase",
      workflow_input: %{"context" => "go"}
    }

    assert :ok = WorkflowRunner.run(state)

    assert_receive {:run_started, run_id, %{status: :running}}, 5_000
    assert_receive {:run_completed, ^run_id, %{status: :completed}}, 5_000

    {:ok, run} = WorkflowRun.by_id(run_id, tenant: tenant, actor: actor_for(tenant))
    assert run.status == :completed
    assert is_map(run.result)
    assert run.result["steps_completed"] == 2

    kinds = event_kinds(run_id, tenant)
    assert match?([:run_started | _], kinds)
    assert match?([:run_completed | _], Enum.reverse(kinds))
    assert :step_started in kinds
    assert :step_completed in kinds

    # Both steps share the deterministic cron workspace_id.
    workspace_ids = for tc <- collect_tool_contexts(2), do: tc.workspace_id
    assert Enum.uniq(workspace_ids) |> length() == 1
    assert [ws | _] = workspace_ids
    assert String.starts_with?(ws, "cron:#{unique_id}:")
  end

  test "a step error drives the run to :failed (and the step runs once)", %{tenant: tenant} do
    put_templates(%{"researcher" => template(ErrorStub), "docs_writer" => template(EchoStub)})

    unique_id = "wfrun-#{System.unique_integer([:positive])}"

    state = %{
      id: unique_id,
      tenant_id: tenant,
      workflow_name: "explore_codebase",
      workflow_input: %{}
    }

    assert {:error, _reason} = WorkflowRunner.run(state)

    assert_receive {:run_started, run_id, _info}, 5_000
    assert_receive {:run_failed, ^run_id, %{status: :failed}}, 5_000

    {:ok, run} = WorkflowRun.by_id(run_id, tenant: tenant, actor: actor_for(tenant))
    assert run.status == :failed

    kinds = event_kinds(run_id, tenant)
    assert :step_failed in kinds
    assert match?([:run_failed | _], Enum.reverse(kinds))

    # max_retries: 0 — the failing step ran exactly once, not 100×.
    assert_receive {:stub_invoked, :error}, 5_000
    refute_receive {:stub_invoked, :error}, 200
  end

  test "a step that raises still drives the run to :failed (never stranded :running)",
       %{tenant: tenant} do
    put_templates(%{"researcher" => template(CrashStub), "docs_writer" => template(EchoStub)})

    unique_id = "wfrun-#{System.unique_integer([:positive])}"

    state = %{
      id: unique_id,
      tenant_id: tenant,
      workflow_name: "explore_codebase",
      workflow_input: %{}
    }

    assert {:error, _reason} = WorkflowRunner.run(state)
    assert_receive {:stub_invoked, :crash}, 5_000

    assert_receive {:run_started, run_id, _info}, 5_000
    assert_receive {:run_failed, ^run_id, _info}, 5_000

    {:ok, run} = WorkflowRun.by_id(run_id, tenant: tenant, actor: actor_for(tenant))
    assert run.status == :failed
  end

  test "unknown skill returns an error and creates no run row", %{tenant: tenant} do
    unique_id = "wfrun-missing-#{System.unique_integer([:positive])}"

    state = %{
      id: unique_id,
      tenant_id: tenant,
      workflow_name: "does_not_exist_skill",
      workflow_input: %{}
    }

    assert {:error, _reason} = WorkflowRunner.run(state)

    refute_received {:run_started, _id, _info}

    {:ok, runs} = WorkflowRun.list(tenant: tenant, actor: actor_for(tenant))
    refute Enum.any?(runs, fn run -> run.name == "does_not_exist_skill" end)
  end

  test "a state without :workflow_name fails cleanly", %{tenant: _tenant} do
    assert {:error, :missing_workflow_name} = WorkflowRunner.run(%{})
  end

  defp collect_tool_contexts(n) do
    for _ <- 1..n do
      receive do
        {:echo_stub, :tool_context, tc} -> tc
      after
        5_000 -> flunk("did not receive #{n} tool_context messages")
      end
    end
  end
end
