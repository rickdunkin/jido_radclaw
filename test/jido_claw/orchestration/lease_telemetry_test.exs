defmodule JidoClaw.Orchestration.LeaseTelemetryTest.OkStep do
  @moduledoc false
  use Reactor.Step

  @impl Reactor.Step
  def run(_args, _context, _opts), do: {:ok, :done}
end

defmodule JidoClaw.Orchestration.LeaseTelemetryTest.OkReactor do
  @moduledoc false
  use Reactor

  step(:only, JidoClaw.Orchestration.LeaseTelemetryTest.OkStep)
  return(:only)
end

defmodule JidoClaw.Orchestration.LeaseTelemetryTest do
  @moduledoc """
  WS6 Phase 4 lease lifecycle telemetry: `claimed` (the CAS stamp won),
  `renewed` (heartbeat), and `fenced_out` (reasons `:stolen` and
  `:claim_lost`), plus the pure `WorkflowLease.fenced_reason/1` classifier.

  Same harness as `workflow_lease_test.exs`: `async: false` + the shared
  sandbox so executor tasks and lease sidecars share the sandbox connection;
  the production auto-renew timer is parked in test config, so renew/fence
  scenarios drive the sidecar through the `{:lease_tick, from}` seam. Every
  event assertion pins the run id, and no metadata may carry the lease token
  (fence credentials stay out of telemetry).
  """
  use JidoClaw.TenantCase, async: false

  import JidoClaw.Orchestration.LeaseHelpers

  alias JidoClaw.Orchestration.LeaseTelemetryTest.OkReactor
  alias JidoClaw.Orchestration.ReactorRunner
  alias JidoClaw.Orchestration.WorkflowLease
  alias JidoClaw.Orchestration.WorkflowLease.Middleware, as: LeaseMiddleware
  alias JidoClaw.Orchestration.WorkflowRun

  @lease_registry JidoClaw.Orchestration.LeaseRegistry

  setup do
    tenant = seed_tenant("lease-telemetry")

    # Backstop: kill any executor/sidecar leaked by an assertion failure before
    # a per-launch on_exit tracked it. Safe only because the file is async:
    # false (no other test's tasks are on these singletons).
    on_exit(fn ->
      for sup <- [
            JidoClaw.Orchestration.RunTaskSupervisor,
            JidoClaw.Orchestration.LeaseTaskSupervisor
          ],
          pid <- Task.Supervisor.children(sup) do
        Process.exit(pid, :kill)
      end
    end)

    {:ok, tenant: tenant, actor: actor_for(tenant)}
  end

  defp attach(event) do
    handler = "lease-telemetry-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler,
      event,
      fn _event, measurements, meta, _config ->
        send(test_pid, {:telemetry, measurements, meta})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  describe "claimed" do
    test "a won CAS emits claimed with run identity, type, and node", ctx do
      attach([:jido_claw, :orchestration, :claimed])

      # The real self-claim path: the runner stamps via Lease.Middleware.
      assert {:ok, :done, run} = ReactorRunner.run(OkReactor, %{}, scope(ctx))
      run_id = run.id

      assert_receive {:telemetry, %{count: 1}, %{run_id: ^run_id} = meta}, 1_000
      assert meta.tenant_id == ctx.tenant
      assert meta.workflow_type == "reactor"
      assert meta.node == WorkflowLease.node_identity()
      refute Map.has_key?(meta, :token)
    end
  end

  describe "renewed" do
    test "a successful heartbeat emits renewed", ctx do
      attach([:jido_claw, :orchestration, :renewed])
      {_launcher, run_id, _executor} = launch_blocking(ctx)

      assert [{sidecar, _meta}] = Registry.lookup(@lease_registry, run_id)
      send(sidecar, {:lease_tick, self()})
      assert_receive {:lease_ticked, {:ok, 1}}, 5_000

      assert_receive {:telemetry, %{count: 1}, %{run_id: ^run_id} = meta}, 1_000
      assert meta.tenant_id == ctx.tenant
      assert meta.node == WorkflowLease.node_identity()
      refute Map.has_key?(meta, :token)
    end
  end

  describe "fenced_out" do
    test "a rotated token fences the live executor with reason :stolen", ctx do
      attach([:jido_claw, :orchestration, :fenced_out])
      {launcher, run_id, _executor} = launch_blocking(ctx)

      # A reclaimer rotates the token out from under the live owner; the next
      # heartbeat renews 0 rows -> fence_decision :kill -> reason :stolen.
      rotate_token!(run_id, Ash.UUID.generate())
      assert [{sidecar, _meta}] = Registry.lookup(@lease_registry, run_id)
      send(sidecar, {:lease_tick, self()})
      assert_receive {:lease_ticked, {:ok, 0}}, 5_000

      assert_receive {:telemetry, %{count: 1}, %{run_id: ^run_id} = meta}, 1_000
      assert meta.reason == :stolen
      assert meta.tenant_id == ctx.tenant
      assert meta.node == WorkflowLease.node_identity()
      refute Map.has_key?(meta, :token)

      # The fence still surfaces as the clean fenced stop (no terminal).
      assert {:error, :fenced, %WorkflowRun{status: :running}} = Task.await(launcher, 5_000)
    end

    test "a refused claim emits fenced_out with reason :claim_lost, no sidecar", ctx do
      run = seed_run(ctx)
      run_id = run.id
      # Another owner rotated the DB token; the in-memory run still carries the
      # nil genesis token, so the middleware's CAS loses.
      rotate_token!(run_id, Ash.UUID.generate())
      attach([:jido_claw, :orchestration, :fenced_out])

      assert {:error, {:lease_lost, ^run_id}} =
               LeaseMiddleware.init(%{claim_token: Ash.UUID.generate(), workflow_run: run})

      assert_receive {:telemetry, %{count: 1}, %{run_id: ^run_id} = meta}, 1_000
      assert meta.reason == :claim_lost
      assert meta.tenant_id == ctx.tenant
      assert meta.node == WorkflowLease.node_identity()
      refute Map.has_key?(meta, :token)

      # The refused claim never armed a heartbeat.
      assert Registry.lookup(@lease_registry, run_id) == []
    end
  end

  describe "fenced_reason/1" do
    test "classifies the raw kill-branch renew result" do
      # The :lapsed emit path (an un-raised renew {:error, _} past the lease
      # window) is not reachable in the shared sandbox — forcing it would need
      # Mox, which the project lacks — so this pure clause IS its coverage.
      assert WorkflowLease.fenced_reason({:ok, 0}) == :stolen
      assert WorkflowLease.fenced_reason({:error, :db_down}) == :lapsed
    end
  end

  defp scope(%{tenant: tenant, actor: actor}), do: [tenant: tenant, actor: actor]
end
