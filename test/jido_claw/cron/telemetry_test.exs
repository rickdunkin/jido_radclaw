defmodule JidoClaw.Cron.TelemetryTest do
  @moduledoc """
  Every cron telemetry event of a tick carries the enriched, shared metadata:
  `job_id`, `tenant_id`, `mode`, `target`, and the *effective* `dispatch_target`.

  Locks the consolidator-style fix — a `mode: :system_job` row whose `target`
  defaults to `:agent` must still report `dispatch_target: :mfa` — and that the
  exception event carries `tenant_id` (the old `emit_cron_exception` dropped it).
  """
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Cron
  alias JidoClaw.Cron.Scheduler
  alias JidoClaw.Tenant.Manager

  # A 1-day interval so its first (and only) tick lands ~1 day after the worker
  # starts — never during this millisecond-scale test, regardless of wall-clock
  # time. We drive ticks explicitly with Cron.Worker.trigger/2.
  @far_future {:every, 86_400_000}

  defmodule OkMFA do
    @moduledoc false
    @spec ok() :: :ok
    def ok, do: :ok
  end

  defmodule RaiseMFA do
    @moduledoc false
    @spec boom() :: no_return()
    def boom, do: raise("boom")
  end

  setup do
    tenant = seed_tenant("cron-telemetry")
    {:ok, _} = Manager.ensure_tenant(tenant)
    {:ok, tenant: tenant}
  end

  defp attach(event) do
    handler = "cron-telemetry-#{System.unique_integer([:positive])}"
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

  test "start/stop carry mode/target/dispatch_target/tenant_id; system_job reports :mfa",
       %{tenant: tenant} do
    attach([:jido_claw, :cron, :job, :start])
    attach([:jido_claw, :cron, :job, :stop])

    {:ok, "tele-ok", _pid} =
      Scheduler.schedule(tenant,
        id: "tele-ok",
        mode: :system_job,
        schedule: @far_future,
        mfa: {OkMFA, :ok, []}
      )

    on_exit(fn -> _ = Scheduler.unschedule(tenant, "tele-ok") end)

    Cron.Worker.trigger(tenant, "tele-ok")

    assert_receive {:telemetry, %{system_time: _}, start_meta}
    assert start_meta.job_id == "tele-ok"
    assert start_meta.tenant_id == tenant
    assert start_meta.mode == :system_job
    # target defaults to :agent, but the effective dispatch is :mfa.
    assert start_meta.target == :agent
    assert start_meta.dispatch_target == :mfa

    assert_receive {:telemetry, %{duration: _}, stop_meta}
    assert stop_meta.tenant_id == tenant
    assert stop_meta.dispatch_target == :mfa
  end

  test "exception event carries tenant_id, mode, and dispatch_target", %{tenant: tenant} do
    attach([:jido_claw, :cron, :job, :exception])

    {:ok, "tele-boom", _pid} =
      Scheduler.schedule(tenant,
        id: "tele-boom",
        mode: :system_job,
        schedule: @far_future,
        mfa: {RaiseMFA, :boom, []}
      )

    on_exit(fn -> _ = Scheduler.unschedule(tenant, "tele-boom") end)

    Cron.Worker.trigger(tenant, "tele-boom")

    assert_receive {:telemetry, %{count: 1}, meta}
    assert meta.tenant_id == tenant
    assert meta.mode == :system_job
    assert meta.dispatch_target == :mfa
    assert meta.kind == :error
  end
end
