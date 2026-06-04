defmodule JidoClaw.Cron.DispatcherTest do
  @moduledoc """
  Pins the `Cron.Dispatcher` routing matrix and its legacy-first
  precedence:

    * `mode: :system_job` → MFA (even when `target` says otherwise)
    * `target: :workflow` → the workflow runner seam
    * `target: :mfa`      → MFA
    * otherwise (`:agent`) → a chat turn — and a `:main` row carrying an
      `mfa` field still routes to the agent (there is no mfa-present
      fallback).

  The workflow runner is swapped via `:cron_workflow_runner`; MFA targets
  use a recording MFA; the agent route reuses the `:ask_runtime` capture
  seam so the chat turn resolves without a real LLM round-trip.
  """
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Cron.Dispatcher

  defmodule StubRunner do
    @moduledoc false
    def run(state) do
      send(Application.fetch_env!(:jido_claw, :dispatcher_test_pid), {:runner_ran, state})
      :ok
    end
  end

  defmodule RecordingMFA do
    @moduledoc false
    def run(pid, tag) do
      send(pid, {:mfa_ran, tag})
      {:ok, tag}
    end
  end

  setup do
    tenant = seed_tenant("dispatcher")

    previous = %{
      runner: Application.fetch_env(:jido_claw, :cron_workflow_runner),
      test_pid: Application.fetch_env(:jido_claw, :dispatcher_test_pid),
      ask_runtime: Application.fetch_env(:jido_claw, :ask_runtime),
      capture_target: Application.fetch_env(:jido_claw, :dispatch_capture_target),
      capture_response: Application.fetch_env(:jido_claw, :dispatch_capture_response),
      recorder_flush_timeout: Application.fetch_env(:jido_claw, :recorder_flush_timeout)
    }

    Application.put_env(:jido_claw, :cron_workflow_runner, StubRunner)
    Application.put_env(:jido_claw, :dispatcher_test_pid, self())
    Application.put_env(:jido_claw, :ask_runtime, JidoClaw.Test.HandoffDispatchCapture)
    Application.put_env(:jido_claw, :dispatch_capture_target, self())
    Application.put_env(:jido_claw, :dispatch_capture_response, {:ok, "captured"})
    Application.put_env(:jido_claw, :recorder_flush_timeout, 50)

    on_exit(fn ->
      restore_env(:cron_workflow_runner, previous.runner)
      restore_env(:dispatcher_test_pid, previous.test_pid)
      restore_env(:ask_runtime, previous.ask_runtime)
      restore_env(:dispatch_capture_target, previous.capture_target)
      restore_env(:dispatch_capture_response, previous.capture_response)
      restore_env(:recorder_flush_timeout, previous.recorder_flush_timeout)
    end)

    {:ok, tenant: tenant}
  end

  test "mode: :system_job routes to MFA", %{tenant: tenant} do
    state = %{
      id: "sysjob",
      tenant_id: tenant,
      mode: :system_job,
      target: :agent,
      mfa: {RecordingMFA, :run, [self(), :sysjob]}
    }

    assert {:ok, :sysjob} = Dispatcher.dispatch(state)
    assert_receive {:mfa_ran, :sysjob}
  end

  test "target: :workflow routes to the workflow runner", %{tenant: tenant} do
    state = %{
      id: "wf",
      tenant_id: tenant,
      mode: :main,
      target: :workflow,
      workflow_name: "explore_codebase"
    }

    assert :ok = Dispatcher.dispatch(state)
    assert_receive {:runner_ran, %{workflow_name: "explore_codebase"}}
  end

  test "target: :mfa routes to MFA", %{tenant: tenant} do
    state = %{
      id: "mfatgt",
      tenant_id: tenant,
      mode: :main,
      target: :mfa,
      mfa: {RecordingMFA, :run, [self(), :mfatgt]}
    }

    assert {:ok, :mfatgt} = Dispatcher.dispatch(state)
    assert_receive {:mfa_ran, :mfatgt}
  end

  test "legacy precedence: :system_job wins over target: :workflow", %{tenant: tenant} do
    state = %{
      id: "legacy",
      tenant_id: tenant,
      mode: :system_job,
      target: :workflow,
      workflow_name: "explore_codebase",
      mfa: {RecordingMFA, :run, [self(), :legacy]}
    }

    assert {:ok, :legacy} = Dispatcher.dispatch(state)
    assert_receive {:mfa_ran, :legacy}
    refute_received {:runner_ran, _}
  end

  test "no mfa-present fallback: a :main row with an mfa field routes to the agent", %{
    tenant: tenant
  } do
    state = %{
      id: "agent",
      tenant_id: tenant,
      agent_id: "cron-agent-#{System.unique_integer([:positive])}",
      task: "do the thing",
      mode: :main,
      target: :agent,
      mfa: {RecordingMFA, :run, [self(), :should_not_fire]}
    }

    Dispatcher.dispatch(state)

    # The agent route reached the chat turn (capture seam fired)...
    assert_receive {:dispatch_capture, _pid, _query, _opts}
    # ...and the mfa was never invoked.
    refute_received {:mfa_ran, _}
  end

  describe "dispatch_target/1 (effective path; single source of truth for routing + telemetry)" do
    test "mode: :system_job => :mfa regardless of target (legacy precedence)" do
      assert Dispatcher.dispatch_target(%{mode: :system_job, target: :agent}) == :mfa
      assert Dispatcher.dispatch_target(%{mode: :system_job, target: :workflow}) == :mfa
      assert Dispatcher.dispatch_target(%{mode: :system_job, target: :mfa}) == :mfa
    end

    test "target: :workflow => :workflow" do
      assert Dispatcher.dispatch_target(%{mode: :main, target: :workflow}) == :workflow
    end

    test "target: :mfa => :mfa" do
      assert Dispatcher.dispatch_target(%{mode: :main, target: :mfa}) == :mfa
    end

    test "otherwise => :agent" do
      assert Dispatcher.dispatch_target(%{mode: :main, target: :agent}) == :agent
      assert Dispatcher.dispatch_target(%{mode: :isolated, target: :agent}) == :agent
    end
  end

  defp restore_env(key, :error), do: Application.delete_env(:jido_claw, key)
  defp restore_env(key, {:ok, value}), do: Application.put_env(:jido_claw, key, value)
end
