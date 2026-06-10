defmodule JidoClaw.Orchestration.CancellationTest.OkStep do
  @moduledoc false
  use Reactor.Step

  @impl Reactor.Step
  def run(_args, _context, _opts), do: {:ok, :done}
end

defmodule JidoClaw.Orchestration.CancellationTest.QuickReactor do
  @moduledoc false
  use Reactor

  step(:only, JidoClaw.Orchestration.CancellationTest.OkStep)
  return(:only)
end

defmodule JidoClaw.Orchestration.CancellationTest do
  @moduledoc """
  Live-run cancellation: `Cancellation.cancel/2` routing (live kill, parked
  abandon delegation, terminal refusal, stranded-run durability) plus the
  `RunExecution` registration-conflict guard. `async: false` — the singleton
  RunRegistry/RunTaskSupervisor plus the shared sandbox.
  """
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Gates.TestIrreversibleWrite
  alias JidoClaw.Orchestration.AgentCase
  alias JidoClaw.Orchestration.Cancellation
  alias JidoClaw.Orchestration.CancellationTest.QuickReactor
  alias JidoClaw.Orchestration.ReactorRunner
  alias JidoClaw.Orchestration.Reactors.BlockingTestReactor
  alias JidoClaw.Orchestration.Reactors.GatedTestReactor
  alias JidoClaw.Orchestration.RunExecution
  alias JidoClaw.Orchestration.RunPubSub
  alias JidoClaw.Orchestration.WorkflowEvent
  alias JidoClaw.Orchestration.WorkflowLog
  alias JidoClaw.Orchestration.WorkflowRun

  setup do
    TestIrreversibleWrite.reset()
    tenant = seed_tenant("cancel")

    # Backstop sweep for executors leaked by an assertion failure BEFORE the
    # narrow per-launch on_exit below tracked them. Registered in setup so it
    # runs AFTER the narrow cleanups (LIFO); sweeping the singleton supervisor
    # is safe only because this file is async: false — no other test's tasks
    # can be on it while this one runs.
    on_exit(fn ->
      JidoClaw.Orchestration.RunTaskSupervisor
      |> Task.Supervisor.children()
      |> Enum.each(&Process.exit(&1, :kill))
    end)

    {:ok, tenant: tenant, actor: actor_for(tenant)}
  end

  describe "cancel of a live :running run" do
    test "kills the executor, lands run_cancelled, and unblocks the caller", ctx do
      {launcher, run_id, executor} = launch_blocking(ctx)
      RunPubSub.subscribe(run_id)

      assert {:ok, %WorkflowRun{status: :cancelled} = cancelled} =
               Cancellation.cancel(run_id, scope(ctx))

      assert %DateTime{} = cancelled.completed_at
      assert :run_cancelled in kinds(run_id, ctx)
      assert_receive {:run_cancelled, ^run_id, %{status: :cancelled}}

      # The launcher's envelope is the clean cancellation, not a crash.
      assert {:error, :cancelled, %WorkflowRun{status: :cancelled}} =
               Task.await(launcher, 5_000)

      refute Process.alive?(executor)
      await_unregistered(run_id)
    end

    test "a custom :reason lands in the run_cancelled payload", ctx do
      {launcher, run_id, _executor} = launch_blocking(ctx)

      assert {:ok, _} =
               Cancellation.cancel(run_id, Keyword.put(scope(ctx), :reason, "operator says stop"))

      assert {:error, :cancelled, _} = Task.await(launcher, 5_000)

      {:ok, events} = WorkflowEvent.for_run(run_id, scope(ctx))
      cancelled_ev = Enum.find(events, &(&1.kind == :run_cancelled))
      assert cancelled_ev.payload["reason"] == "operator says stop"
    end
  end

  describe "cancel of a parked (:awaiting_approval) run" do
    test "delegates to abandon — the run ends :abandoned, not :cancelled", ctx do
      {result, inputs} = run_gated(ctx)
      assert {:ok, {:paused, case_id}, run} = result
      run_id = run.id
      RunPubSub.subscribe(run_id)

      # A web-shape actor (the ApprovalsLive convention — a uuid user_id):
      # the delegation must thread it into the abandon audit field.
      web_actor = %{user_id: Ecto.UUID.generate(), tenant_id: ctx.tenant}

      assert {:ok, abandoned} =
               Cancellation.cancel(run_id,
                 tenant: ctx.tenant,
                 actor: web_actor,
                 reason: "operator cancel"
               )

      assert abandoned.status == :abandoned
      assert :run_abandoned in kinds(run_id, ctx)
      refute :run_cancelled in kinds(run_id, ctx)

      # The run-lifecycle terminal lands on the runs topic — the dashboard
      # refresh for the parked-run Cancel path.
      assert_receive {:run_abandoned, ^run_id, %{status: :abandoned}}

      assert {:ok,
              %AgentCase{
                status: :abandoned,
                cancellation_reason: "operator cancel",
                decided_by_id: decided_by_id
              }} = AgentCase.by_id(case_id, scope(ctx))

      # Audit parity with ApprovalsLive's abandon: the operator round-trips.
      assert decided_by_id == web_actor.user_id

      # The downstream irreversible write never ran.
      refute workspace_exists?(inputs.workspace_path, ctx)
    end
  end

  describe "terminal refusals" do
    test "a completed run refuses with :already_terminal and appends nothing", ctx do
      assert {:ok, :done, run} = ReactorRunner.run(QuickReactor, %{}, scope(ctx))
      assert run.status == :completed

      events_before = kinds(run.id, ctx)
      assert {:error, :already_terminal} = Cancellation.cancel(run.id, scope(ctx))
      assert kinds(run.id, ctx) == events_before
    end

    test "double-cancel: the second cancel refuses with :already_terminal", ctx do
      {launcher, run_id, _executor} = launch_blocking(ctx)

      assert {:ok, %WorkflowRun{status: :cancelled}} = Cancellation.cancel(run_id, scope(ctx))
      assert {:error, :cancelled, _run} = Task.await(launcher, 5_000)

      assert {:error, :already_terminal} = Cancellation.cancel(run_id, scope(ctx))
    end
  end

  describe "stranded and late-append cases" do
    test "a stranded :running run with no live executor still cancels durably", ctx do
      run = strand_running(ctx)

      assert RunExecution.lookup(run.id) == :error
      assert {:ok, %WorkflowRun{status: :cancelled}} = Cancellation.cancel(run.id, scope(ctx))
      assert :run_cancelled in kinds(run.id, ctx)
    end

    test "a late terminal append on a cancelled run fails cleanly, status stays", ctx do
      {launcher, run_id, _executor} = launch_blocking(ctx)
      assert {:ok, cancelled} = Cancellation.cancel(run_id, scope(ctx))
      assert {:error, :cancelled, _run} = Task.await(launcher, 5_000)

      assert {:error, %Ash.Error.Invalid{}} =
               WorkflowLog.append(cancelled, :run_completed, %{result: %{}}, scope(ctx))

      assert reload(run_id, ctx).status == :cancelled
    end
  end

  describe "RunExecution registration conflict" do
    test "a second executor for a registered run id returns {:duplicate, pid} without running",
         ctx do
      {:ok, run} = WorkflowRun.create(%{name: "conflict"}, scope(ctx))

      # Simulate a live executor by registering the run id from the test
      # process — the registry value is the tenant, as run_killable writes it.
      {:ok, _} = Registry.register(JidoClaw.Orchestration.RunRegistry, run.id, ctx.tenant)
      test_pid = self()

      assert {:duplicate, ^test_pid} =
               RunExecution.run_killable(BlockingTestReactor, %{}, %{test_pid: test_pid},
                 run_id: run.id,
                 tenant_id: ctx.tenant,
                 async?: false,
                 timeout: :infinity,
                 max_iterations: :infinity
               )

      # The reactor never ran and the run's status is untouched — the loser
      # must not fail a run that has a live, healthy executor.
      refute_receive {:blocking_step_started, _pid, _run_id}, 100
      assert reload(run.id, ctx).status == :pending
      assert kinds(run.id, ctx) == []
    end
  end

  # -- Helpers --

  # Launch BlockingTestReactor on a linked launcher task and block until the
  # executor is provably inside the blocking step (assert_receive — no timer
  # sleeps). Tracks the launcher AND the executor pid for narrow-first
  # cleanup; the setup-level sweep only backstops failures landing before
  # this on_exit registers.
  defp launch_blocking(ctx) do
    test_pid = self()
    scope = scope(ctx)

    launcher =
      Task.async(fn ->
        ReactorRunner.run(
          BlockingTestReactor,
          %{},
          Keyword.put(scope, :context, %{test_pid: test_pid})
        )
      end)

    assert_receive {:blocking_step_started, _step_pid, run_id}, 5_000
    assert {:ok, executor, _tenant} = RunExecution.lookup(run_id)

    # Raw pid kills (not Task.shutdown — on_exit runs off the owner process,
    # where Task.shutdown raises); killing an already-dead pid is a no-op.
    launcher_pid = launcher.pid

    on_exit(fn ->
      Process.exit(executor, :kill)
      Process.exit(launcher_pid, :kill)
    end)

    {launcher, run_id, executor}
  end

  # Strand a run mid-flight (recovery-test pattern): created + run_started,
  # no live process behind it.
  defp strand_running(ctx) do
    {:ok, run} = WorkflowRun.create(%{name: "stranded"}, scope(ctx))
    {:ok, _} = WorkflowLog.append(run, :run_started, %{})
    reload(run.id, ctx)
  end

  defp run_gated(ctx) do
    uniq = System.unique_integer([:positive])
    inputs = %{workspace_name: "cancel-ws-#{uniq}", workspace_path: "/tmp/cancel-ws-#{uniq}"}
    {ReactorRunner.run(GatedTestReactor, inputs, scope(ctx)), inputs}
  end

  defp scope(%{tenant: tenant, actor: actor}), do: [tenant: tenant, actor: actor]

  defp reload(run_id, ctx) do
    {:ok, run} = WorkflowRun.by_id(run_id, scope(ctx))
    run
  end

  defp kinds(run_id, ctx) do
    {:ok, events} = WorkflowEvent.for_run(run_id, scope(ctx))
    Enum.map(events, & &1.kind)
  end

  defp workspace_exists?(path, ctx) do
    case Workspace.by_path(nil, path, scope(ctx)) do
      {:ok, %Workspace{}} -> true
      _ -> false
    end
  end

  # Registry entries clean up asynchronously after the executor dies — poll
  # (bounded) rather than asserting on DOWN-processing timing.
  defp await_unregistered(run_id, attempts \\ 200) do
    case RunExecution.lookup(run_id) do
      :error ->
        :ok

      {:ok, _pid, _tenant} when attempts == 0 ->
        flunk("registry entry for #{run_id} never cleaned up")

      {:ok, _pid, _tenant} ->
        Process.sleep(5)
        await_unregistered(run_id, attempts - 1)
    end
  end
end
