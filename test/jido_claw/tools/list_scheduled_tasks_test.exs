defmodule JidoClaw.Tools.ListScheduledTasksTest do
  @moduledoc """
  The list tool reads persisted `cron_jobs` rows (the source of truth) — WS4a —
  so a job shows even when no local worker is running (the follower case,
  simulated here by never scheduling a worker). It surfaces a `| tz: <zone>`
  segment for non-UTC jobs only; UTC jobs omit it.
  """
  # async: false — setup writes through the `Tenant.Manager` singleton
  # (`ensure_tenant/1`), an out-of-chain GenServer that needs the shared
  # sandbox; under owner-mode it raises DBConnection.OwnershipError.
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Cron.Job
  alias JidoClaw.Tenant.Manager
  alias JidoClaw.Tools.ListScheduledTasks

  setup do
    tenant = seed_tenant("list-tasks")
    {:ok, _} = Manager.ensure_tenant(tenant)
    {:ok, tenant: tenant, ctx: %{tool_context: %{tenant_id: tenant}}}
  end

  defp seed_row(tenant, id, extra) do
    attrs =
      Enum.into(extra, %{
        job_id: id,
        task: "t",
        mode: :main,
        schedule_kind: :every,
        schedule_value: "86400000"
      })

    {:ok, _} = Job.upsert(attrs, tenant: tenant, actor: actor_for(tenant))
  end

  test "lists rows (no worker needed); a non-UTC job renders its tz, a UTC job omits it",
       %{tenant: tenant, ctx: ctx} do
    seed_row(tenant, "ny", timezone: "America/New_York")
    seed_row(tenant, "utc", [])

    assert {:ok, %{result: result}} = ListScheduledTasks.run(%{}, ctx)

    lines = String.split(result, "\n")
    ny_line = Enum.find(lines, &String.contains?(&1, "- ny "))
    utc_line = Enum.find(lines, &String.contains?(&1, "- utc "))

    # Both rows show even though no worker was ever scheduled.
    assert ny_line
    assert utc_line
    assert ny_line =~ "tz: America/New_York"
    refute utc_line =~ "tz:"
  end

  test "a disabled row still shows, marked disabled", %{tenant: tenant, ctx: ctx} do
    seed_row(tenant, "off", [])
    {:ok, row} = Job.by_job_id("off", tenant: tenant, actor: actor_for(tenant))
    {:ok, _} = Job.disable(row, tenant: tenant, actor: actor_for(tenant))

    assert {:ok, %{result: result}} = ListScheduledTasks.run(%{}, ctx)
    assert result =~ "- off [disabled]"
  end

  test "no rows reports the empty message", %{ctx: ctx} do
    assert {:ok, %{result: "No scheduled tasks. Use schedule_task to create one."}} =
             ListScheduledTasks.run(%{}, ctx)
  end
end
