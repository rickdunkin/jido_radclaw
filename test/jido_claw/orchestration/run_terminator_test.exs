defmodule JidoClaw.Orchestration.RunTerminatorTest do
  @moduledoc """
  WS5 — the per-node remote-kill receiver, `RunTerminator`: a routed
  `{:kill, run_id, tenant_id}` cast becomes a local
  `RunExecution.kill_local/2` (kill on tenant match, refuse + warn on a
  tenant mismatch, no-op on a registry miss).

  Single-BEAM: the cast targets the already-running app singleton via
  `{RunTerminator, Node.self()}` — a single-node stand-in (the resolver returns
  `:local` for self, and a disconnected node atom cannot receive a cast on one
  BEAM). Real cross-BEAM cast *delivery* to a genuinely remote node is proven
  by WS6's `:peer` multi-node `JidoClaw.Cluster.CrossNodeCancelTest` — out of
  scope here. The terminator touches no DB, so a plain `ExUnit.Case` with no
  sandbox; unique run-id/tenant strings per test (the shared, global
  `RunRegistry`).
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias JidoClaw.Orchestration.RunRegistry
  alias JidoClaw.Orchestration.RunTerminator

  test "a tenant-matching kill cast terminates the local executor" do
    run_id = unique("wf")
    tenant = unique("tenant")
    dummy = spawn_registered_dummy(run_id, tenant)

    ref = Process.monitor(dummy)
    GenServer.cast({RunTerminator, Node.self()}, {:kill, run_id, tenant})

    assert_receive {:DOWN, ^ref, :process, ^dummy, :killed}, 1_000
  end

  test "a cross-tenant kill cast is refused: warns and leaves the executor alive" do
    run_id = unique("wf")
    tenant = unique("tenant")
    dummy = spawn_registered_dummy(run_id, tenant)
    # The dummy survives by design — don't leak a sleeping process into the
    # shared singleton registry.
    on_exit(fn -> Process.exit(dummy, :kill) end)

    log =
      capture_log(fn ->
        GenServer.cast({RunTerminator, Node.self()}, {:kill, run_id, unique("other")})
        # Sync barrier: the call queues behind the cast (mailbox FIFO), so by the
        # time it returns the cast has been handled and the warning logged.
        _ = :sys.get_state(RunTerminator)
      end)

    assert log =~ "tenant mismatch"
    assert Process.alive?(dummy)
  end

  test "a kill cast for an unknown run id is a no-op and the terminator survives" do
    GenServer.cast({RunTerminator, Node.self()}, {:kill, unique("no-such-run"), unique("tenant")})
    # Barrier: the cast is fully handled by the time this returns.
    assert :sys.get_state(RunTerminator) == %{}
    assert Process.alive?(Process.whereis(RunTerminator))
  end

  # -- Helpers --

  # `Registry.register/3` registers the CALLING process, so the dummy executor
  # must register itself (not the test process) and signal ready before the cast.
  defp spawn_registered_dummy(run_id, tenant) do
    test_pid = self()

    dummy =
      spawn(fn ->
        {:ok, _} = Registry.register(RunRegistry, run_id, tenant)
        send(test_pid, :ready)
        Process.sleep(:infinity)
      end)

    assert_receive :ready, 1_000
    dummy
  end

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
