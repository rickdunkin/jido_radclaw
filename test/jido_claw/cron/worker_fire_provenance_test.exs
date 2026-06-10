defmodule JidoClaw.Cron.WorkerFireProvenanceTest do
  @moduledoc """
  Pins the T2-3 firing-provenance seam in `Cron.Worker.execute_job/2`:

    * a timer tick carries its armed window (`{:tick, window}`) and dispatches
      with `fire: {:scheduled, window}` (the window `WorkflowRunner` derives
      the idempotency key from);
    * a duplicate tick for an already-consumed window is swallowed — exactly
      one dispatch per window, never a second run stamped with a freshly
      advanced window;
    * a stale tick (window ≠ current `next_run`) never executes or re-arms;
    * a manual `trigger/2` dispatches with `fire: :manual` (never a key —
      operator intent always runs);
    * provenance rides the LOCAL dispatch copy only — `get_state/2` after
      either firing still shows `fire: nil`, so a manual trigger can never
      inherit (and consume) the upcoming scheduled window's key.

  The window assertions round-trip the `%DateTime{}` through `get_state/2`,
  pinning the pattern-equality assumption the worker's tick clause relies on
  (the message carries the very struct stored in `next_run`).

  Uses the same `:cron_workflow_runner` app-env capture seam as
  `DispatcherTest`.
  """
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Cron
  alias JidoClaw.Cron.Scheduler
  alias JidoClaw.Tenant.Manager

  # First natural tick lands ~1 day out; ticks are driven explicitly.
  @far_future {:every, 86_400_000}

  defmodule CapturingRunner do
    @moduledoc false
    @spec run(term()) :: :ok
    def run(state) do
      send(Application.fetch_env!(:jido_claw, :fire_provenance_test_pid), {:runner_ran, state})
      :ok
    end
  end

  setup do
    tenant = seed_tenant("cron-fire")
    {:ok, _} = Manager.ensure_tenant(tenant)

    previous = Application.fetch_env(:jido_claw, :cron_workflow_runner)
    Application.put_env(:jido_claw, :cron_workflow_runner, CapturingRunner)
    Application.put_env(:jido_claw, :fire_provenance_test_pid, self())

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:jido_claw, :cron_workflow_runner, value)
        :error -> Application.delete_env(:jido_claw, :cron_workflow_runner)
      end

      Application.delete_env(:jido_claw, :fire_provenance_test_pid)
    end)

    job_id = "fire-#{System.unique_integer([:positive])}"

    {:ok, ^job_id, pid} =
      Scheduler.schedule(tenant,
        id: job_id,
        target: :workflow,
        workflow_name: "explore_codebase",
        schedule: @far_future
      )

    on_exit(fn -> _ = Scheduler.unschedule(tenant, job_id) end)

    {:ok, tenant: tenant, job_id: job_id, worker: pid}
  end

  test "a timer tick dispatches {:scheduled, window} and stores no provenance", ctx do
    %{tenant: tenant, job_id: job_id, worker: pid} = ctx

    %{next_run: %DateTime{} = window} = Cron.Worker.get_state(tenant, job_id)

    send(pid, {:tick, window})

    assert_receive {:runner_ran, %{fire: {:scheduled, dispatched_window}}}, 5_000
    assert dispatched_window == window

    # Provenance never persists into stored GenServer state.
    assert %{fire: nil} = Cron.Worker.get_state(tenant, job_id)
  end

  test "a duplicate tick for one window dispatches exactly once", ctx do
    %{tenant: tenant, job_id: job_id, worker: pid} = ctx

    %{next_run: %DateTime{} = window} = Cron.Worker.get_state(tenant, job_id)

    # The double-delivered tick: the first consumes the window (and advances
    # next_run), the second no longer matches and is swallowed — it must NOT
    # dispatch with a freshly advanced window.
    send(pid, {:tick, window})
    send(pid, {:tick, window})

    assert_receive {:runner_ran, %{fire: {:scheduled, ^window}}}, 5_000
    refute_receive {:runner_ran, _state}, 300

    assert Process.alive?(pid)

    # The matching tick re-armed: next_run advanced past the consumed window.
    %{next_run: %DateTime{} = next} = Cron.Worker.get_state(tenant, job_id)
    assert DateTime.compare(next, window) == :gt
  end

  test "a stale window neither executes nor re-arms", ctx do
    %{tenant: tenant, job_id: job_id, worker: pid} = ctx

    %{next_run: %DateTime{} = window} = Cron.Worker.get_state(tenant, job_id)

    send(pid, {:tick, DateTime.add(window, 3600)})

    refute_receive {:runner_ran, _state}, 300

    # Swallowed without re-arming: next_run is untouched.
    assert %{next_run: ^window} = Cron.Worker.get_state(tenant, job_id)
  end

  test "a manual trigger dispatches :manual and stores no provenance", ctx do
    %{tenant: tenant, job_id: job_id} = ctx

    Cron.Worker.trigger(tenant, job_id)

    assert_receive {:runner_ran, %{fire: :manual}}, 5_000
    assert %{fire: nil} = Cron.Worker.get_state(tenant, job_id)
  end
end
