defmodule JidoClaw.Cron.WorkerTimezoneTest do
  @moduledoc """
  Boots a real `Cron.Worker` with a non-UTC timezone and asserts its computed
  `next_run` is the correct UTC instant — the load-bearing tz fix end to end
  (worker carries `:timezone` and routes the `:cron` branch through `NextRun`).
  """
  # async: false — setup writes through the `Tenant.Manager` singleton
  # (`ensure_tenant/1`), an out-of-chain GenServer that needs the shared
  # sandbox; under owner-mode it raises DBConnection.OwnershipError.
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Cron
  alias JidoClaw.Cron.Scheduler
  alias JidoClaw.Tenant.Manager

  setup do
    tenant = seed_tenant("cron-worker-tz")
    {:ok, _} = Manager.ensure_tenant(tenant)
    {:ok, tenant: tenant}
  end

  test "next_run for a NY 9am cron is the correct UTC instant (never 09:00Z)", %{tenant: tenant} do
    {:ok, "tz-worker", _pid} =
      Scheduler.schedule(tenant,
        id: "tz-worker",
        task: "noop",
        mode: :main,
        schedule: {:cron, "0 9 * * *"},
        timezone: "America/New_York"
      )

    on_exit(fn -> _ = Scheduler.unschedule(tenant, "tz-worker") end)

    state = Cron.Worker.get_state(tenant, "tz-worker")
    assert state.timezone == "America/New_York"
    assert %DateTime{time_zone: "Etc/UTC"} = state.next_run
    # 9am ET is 13:00Z (EDT) or 14:00Z (EST) — never 09:00Z (the old UTC bug).
    assert state.next_run.hour in [13, 14]
    assert state.next_run.minute == 0
  end

  test "a UTC worker's next_run is at 09:00Z (default tz, legacy behavior)", %{tenant: tenant} do
    {:ok, "utc-worker", _pid} =
      Scheduler.schedule(tenant,
        id: "utc-worker",
        task: "noop",
        mode: :main,
        schedule: {:cron, "0 9 * * *"}
      )

    on_exit(fn -> _ = Scheduler.unschedule(tenant, "utc-worker") end)

    state = Cron.Worker.get_state(tenant, "utc-worker")
    assert state.timezone == "Etc/UTC"
    assert state.next_run.hour == 9
    assert state.next_run.minute == 0
  end
end
