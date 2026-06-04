defmodule JidoClaw.Tools.ListScheduledTasksTest do
  @moduledoc """
  The list tool surfaces a `| tz: <zone>` segment for non-UTC jobs only; UTC
  jobs omit it (keeps default output clean, mirrors the CLI /cron display).
  """
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Cron.Scheduler
  alias JidoClaw.Tenant.Manager
  alias JidoClaw.Tools.ListScheduledTasks

  # A 1-day interval so the scheduled workers never tick during the test (first
  # tick is ~1 day out, independent of wall-clock time). The tz: segment is gated
  # on tz, not schedule kind, so an interval still exercises this assertion.
  @far_future {:every, 86_400_000}

  setup do
    tenant = seed_tenant("list-tasks")
    {:ok, _} = Manager.ensure_tenant(tenant)
    {:ok, tenant: tenant, ctx: %{tool_context: %{tenant_id: tenant}}}
  end

  test "a non-UTC job renders its tz; a UTC job omits it", %{tenant: tenant, ctx: ctx} do
    {:ok, "ny", _} =
      Scheduler.schedule(tenant,
        id: "ny",
        task: "t",
        mode: :main,
        schedule: @far_future,
        timezone: "America/New_York"
      )

    {:ok, "utc", _} =
      Scheduler.schedule(tenant, id: "utc", task: "t", mode: :main, schedule: @far_future)

    on_exit(fn ->
      _ = Scheduler.unschedule(tenant, "ny")
      _ = Scheduler.unschedule(tenant, "utc")
    end)

    assert {:ok, %{result: result}} = ListScheduledTasks.run(%{}, ctx)

    lines = String.split(result, "\n")
    ny_line = Enum.find(lines, &String.contains?(&1, "- ny "))
    utc_line = Enum.find(lines, &String.contains?(&1, "- utc "))

    assert ny_line =~ "tz: America/New_York"
    refute utc_line =~ "tz:"
  end
end
