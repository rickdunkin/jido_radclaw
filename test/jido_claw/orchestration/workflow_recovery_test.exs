defmodule JidoClaw.Orchestration.WorkflowRecoveryTest do
  @moduledoc """
  Pins the boot recovery reconciler — the original stranding-bug fix.

  Boot recovery is disabled in test (`config :jido_claw, :workflow_recovery,
  enabled?: false`), so these drive `reconcile_all/0` directly inside the
  sandbox: a stranded non-terminal run folds to `:failed` with a
  `run_recovered` + `run_failed` audit pair; terminal runs are untouched; the
  scan is tenant-blind.
  """
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Orchestration.Cancellation
  alias JidoClaw.Orchestration.WorkflowEvent
  alias JidoClaw.Orchestration.WorkflowEvent.Projection
  alias JidoClaw.Orchestration.WorkflowLease
  alias JidoClaw.Orchestration.WorkflowLog
  alias JidoClaw.Orchestration.WorkflowRecovery
  alias JidoClaw.Orchestration.WorkflowRun

  # Strand a run mid-flight: created + run_started, no terminal event.
  defp strand_running(tenant) do
    {:ok, run} = WorkflowRun.create(%{name: "stranded"}, tenant: tenant, actor: actor_for(tenant))
    {:ok, _} = WorkflowLog.append(run, :run_started, %{})
    {:ok, running} = WorkflowRun.by_id(run.id, tenant: tenant, actor: actor_for(tenant))
    assert running.status == :running
    running
  end

  test "a stranded :running run reconciles to :failed with an audit pair" do
    tenant = seed_tenant("recovery")
    run = strand_running(tenant)

    assert :ok = WorkflowRecovery.reconcile_all()

    {:ok, recovered} = WorkflowRun.by_id(run.id, tenant: tenant, actor: actor_for(tenant))
    assert recovered.status == :failed

    {:ok, events} = WorkflowEvent.for_run(run.id, tenant: tenant, actor: actor_for(tenant))
    recovered_ev = Enum.find(events, &(&1.kind == :run_recovered))
    failed_ev = Enum.find(events, &(&1.kind == :run_failed))

    assert recovered_ev
    assert failed_ev
    # consecutive seq — the recovery pair committed together, in order
    assert failed_ev.seq == recovered_ev.seq + 1
    assert recovered_ev.payload["prior_status"] == "running"
    assert Projection.project_status(events) == :failed
  end

  test "a stale live reclaimer cannot terminalize a run after its token is rotated" do
    tenant = seed_tenant("recovery-live-fence")
    run = strand_running(tenant)
    stale_token = Ash.UUID.generate()
    successor_token = Ash.UUID.generate()

    assert {:ok, :claimed} = WorkflowLease.stamp(run.id, stale_token, nil)
    stale_claim = WorkflowRun.by_id_global!(run.id)
    assert stale_claim.claim_token == stale_token

    # Model the stale reconciler blocking after its claim while a successor
    # reclaims the expired lease and rotates the durable token.
    assert {:ok, :claimed} = WorkflowLease.stamp(run.id, successor_token, stale_token)

    assert :ok = WorkflowRecovery.reclaim(stale_claim)

    current = WorkflowRun.by_id_global!(run.id)
    assert current.status == :running
    assert current.claim_token == successor_token

    {:ok, events} = WorkflowEvent.for_run(run.id, tenant: tenant, actor: actor_for(tenant))
    refute Enum.any?(events, &(&1.kind == :run_recovered))
    refute Enum.any?(events, &(&1.kind == :run_failed))
  end

  test "a terminal (:completed) run is left untouched" do
    tenant = seed_tenant("recovery-terminal")
    {:ok, run} = WorkflowRun.create(%{name: "done"}, tenant: tenant, actor: actor_for(tenant))
    {:ok, _} = WorkflowLog.append(run, :run_started, %{})
    {:ok, running} = WorkflowRun.by_id(run.id, tenant: tenant, actor: actor_for(tenant))
    {:ok, _} = WorkflowLog.append(running, :run_completed, %{result: %{"ok" => true}})

    {:ok, before} = WorkflowEvent.for_run(run.id, tenant: tenant, actor: actor_for(tenant))

    assert :ok = WorkflowRecovery.reconcile_all()

    {:ok, still} = WorkflowRun.by_id(run.id, tenant: tenant, actor: actor_for(tenant))
    {:ok, after_events} = WorkflowEvent.for_run(run.id, tenant: tenant, actor: actor_for(tenant))

    assert still.status == :completed
    assert length(after_events) == length(before)
  end

  test "a cancelled run is terminal — reconcile_all leaves it untouched" do
    tenant = seed_tenant("recovery-cancelled")
    run = strand_running(tenant)

    assert {:ok, %WorkflowRun{status: :cancelled}} =
             Cancellation.cancel(run.id, tenant: tenant, actor: actor_for(tenant))

    assert :ok = WorkflowRecovery.reconcile_all()

    {:ok, still} = WorkflowRun.by_id(run.id, tenant: tenant, actor: actor_for(tenant))
    assert still.status == :cancelled

    {:ok, events} = WorkflowEvent.for_run(run.id, tenant: tenant, actor: actor_for(tenant))
    refute Enum.any?(events, &(&1.kind == :run_recovered))
  end

  test "reconciliation is tenant-blind — strands in two tenants both fail in one pass" do
    tenant_a = seed_tenant("recovery-a")
    tenant_b = seed_tenant("recovery-b")
    run_a = strand_running(tenant_a)
    run_b = strand_running(tenant_b)

    assert :ok = WorkflowRecovery.reconcile_all()

    {:ok, a} = WorkflowRun.by_id(run_a.id, tenant: tenant_a, actor: actor_for(tenant_a))
    {:ok, b} = WorkflowRun.by_id(run_b.id, tenant: tenant_b, actor: actor_for(tenant_b))

    assert a.status == :failed
    assert b.status == :failed
  end

  test "start_link is a startup barrier: reconciliation is complete before it returns" do
    tenant = seed_tenant("recovery-barrier")
    run = strand_running(tenant)

    previous = %{
      workflow_recovery: Application.get_env(:jido_claw, :workflow_recovery),
      serve_mode: Application.get_env(:jido_claw, :serve_mode),
      cluster_enabled: Application.get_env(:jido_claw, :cluster_enabled)
    }

    Application.put_env(:jido_claw, :workflow_recovery, enabled?: true)
    Application.put_env(:jido_claw, :serve_mode, :gateway)
    Application.put_env(:jido_claw, :cluster_enabled, false)

    try do
      assert {:ok, _pid} = WorkflowRecovery.start_link([])

      assert {:ok, %WorkflowRun{status: :failed}} =
               WorkflowRun.by_id(run.id, tenant: tenant, actor: actor_for(tenant))
    after
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:jido_claw, key)
        {key, value} -> Application.put_env(:jido_claw, key, value)
      end)
    end
  end

  test "a transient database raise keeps startup closed and retries until a nil-lease run is reconciled" do
    tenant = seed_tenant("recovery-retry-barrier")
    run = strand_running(tenant)
    assert is_nil(run.claim_token)
    assert is_nil(run.claim_expires_at)

    parent = self()
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    reconcile = fn ->
      attempt = Agent.get_and_update(attempts, fn count -> {count + 1, count + 1} end)
      send(parent, {:recovery_attempt, attempt})

      if attempt == 1 do
        raise %DBConnection.ConnectionError{message: "database warming"}
      else
        send(parent, {:run_recovery_scan, self()})

        receive do
          {:recovery_scan_result, result} -> result
        end
      end
    end

    previous = enable_owned_recovery()

    try do
      task =
        Task.async(fn ->
          WorkflowRecovery.start_link(
            reconcile: reconcile,
            retry_initial_ms: 3,
            retry_max_ms: 3,
            sleep: fn delay ->
              send(parent, {:recovery_backoff, delay})

              receive do
                :release_recovery_retry -> :ok
              end
            end
          )
        end)

      assert_receive {:recovery_attempt, 1}
      assert_receive {:recovery_backoff, 3}
      assert Task.yield(task, 0) == nil
      assert {:ok, %WorkflowRun{status: :running}} = WorkflowRun.by_id_global(run.id)

      send(task.pid, :release_recovery_retry)
      assert_receive {:recovery_attempt, 2}
      assert_receive {:run_recovery_scan, recovery_pid}
      assert Task.yield(task, 0) == nil
      result = WorkflowRecovery.reconcile_all()
      assert {:ok, %WorkflowRun{status: :failed}} = WorkflowRun.by_id_global(run.id)
      send(recovery_pid, {:recovery_scan_result, result})
      assert {:ok, _pid} = Task.await(task, 5_000)
    after
      restore_recovery_config(previous)
    end
  end

  test "unexpected programming exceptions remain loud instead of entering the retry loop" do
    previous = enable_owned_recovery()

    try do
      assert_raise ArgumentError, "programming defect", fn ->
        WorkflowRecovery.start_link(
          reconcile: fn -> raise ArgumentError, "programming defect" end
        )
      end
    after
      restore_recovery_config(previous)
    end
  end

  # The production DB-outage shape: the scan RETURNS (never raises)
  # `{:error, %Ash.Error.Unknown{}}` whose splode leaf carries the rescued
  # exception as a FORMATTED BANNER STRING (`Exception.format/2`), not the
  # struct. Hand-constructed rather than via `to_ash_error/1`, which can yield
  # a struct leaf where production yields the string leaf being pinned here.
  defp wrapped_string_leaf(banner) do
    %Ash.Error.Unknown{errors: [%Ash.Error.Unknown.UnknownError{error: banner}]}
  end

  defp assert_retryable_backoff(wrapped) do
    parent = self()
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    reconcile = fn ->
      attempt = Agent.get_and_update(attempts, fn count -> {count + 1, count + 1} end)
      if attempt == 1, do: {:error, wrapped}, else: :ok
    end

    previous = enable_owned_recovery()

    try do
      assert {:ok, _pid} =
               WorkflowRecovery.start_link(
                 reconcile: reconcile,
                 retry_initial_ms: 1,
                 retry_max_ms: 1,
                 sleep: fn delay ->
                   send(parent, {:recovery_backoff, delay})
                   :ok
                 end
               )

      assert_received {:recovery_backoff, 1}
      assert Agent.get(attempts, & &1) == 2
    after
      restore_recovery_config(previous)
    end
  end

  defp assert_non_retryable_raise(wrapped) do
    previous = enable_owned_recovery()

    try do
      assert_raise RuntimeError, ~r/non-retryable boot recovery failure/, fn ->
        WorkflowRecovery.start_link(reconcile: fn -> {:error, wrapped} end)
      end
    after
      restore_recovery_config(previous)
    end
  end

  test "an Ash-wrapped connection-error STRING leaf backs off instead of crash-looping" do
    assert_retryable_backoff(
      wrapped_string_leaf("** (DBConnection.ConnectionError) tcp recv (idle): closed")
    )
  end

  test "an Ash-wrapped connection-error STRUCT leaf backs off too" do
    assert_retryable_backoff(%Ash.Error.Unknown{
      errors: [
        %Ash.Error.Unknown.UnknownError{
          error: %DBConnection.ConnectionError{message: "tcp recv (idle): closed"}
        }
      ]
    })
  end

  test "a formatted Postgrex schema-error string stays non-retryable (loud crash path)" do
    assert_non_retryable_raise(
      wrapped_string_leaf(
        ~s{** (Postgrex.Error) ERROR 42703 (undefined_column) column "nope" does not exist}
      )
    )
  end

  test "a loose mid-string ConnectionError mention stays non-retryable" do
    assert_non_retryable_raise(
      wrapped_string_leaf("scan aborted; see DBConnection.ConnectionError in the logs")
    )
  end

  defp enable_owned_recovery do
    previous = %{
      workflow_recovery: Application.get_env(:jido_claw, :workflow_recovery),
      serve_mode: Application.get_env(:jido_claw, :serve_mode),
      cluster_enabled: Application.get_env(:jido_claw, :cluster_enabled)
    }

    Application.put_env(:jido_claw, :workflow_recovery, enabled?: true)
    Application.put_env(:jido_claw, :serve_mode, :gateway)
    Application.put_env(:jido_claw, :cluster_enabled, false)
    previous
  end

  defp restore_recovery_config(previous) do
    Enum.each(previous, fn
      {key, nil} -> Application.delete_env(:jido_claw, key)
      {key, value} -> Application.put_env(:jido_claw, key, value)
    end)
  end
end
