defmodule JidoClaw.Cron.ConfigErrorDisableTest do
  @moduledoc """
  A `:cron` schedule that `NextRun` cannot resolve — unknown timezone or
  invalid expression — is a permanent config error. The worker disables itself
  AND persists `disabled_at` (via `Worker.persist_disabled/1`), so
  `Cron.Job.for_tenant` excludes the bad row on the next boot (converges in one
  cycle rather than re-disabling every restart).
  """
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Cron.Job
  alias JidoClaw.Cron.Scheduler
  alias JidoClaw.Tenant.Manager

  defp wait_until_disabled(job_id, tenant, attempts \\ 50) do
    result =
      Enum.reduce_while(1..attempts, nil, fn _, _ ->
        case Job.by_job_id(job_id, tenant: tenant, actor: actor_for(tenant)) do
          {:ok, %{disabled_at: %DateTime{}} = row} ->
            {:halt, row}

          _ ->
            Process.sleep(20)
            {:cont, nil}
        end
      end)

    result || flunk("disabled_at never set within #{attempts * 20}ms")
  end

  setup do
    tenant = seed_tenant("cron-config-error")
    {:ok, _} = Manager.ensure_tenant(tenant)
    {:ok, tenant: tenant}
  end

  test "an unknown timezone disables the worker and persists disabled_at", %{tenant: tenant} do
    {:ok, _} =
      Job.upsert(
        %{
          job_id: "bad-tz",
          schedule_kind: :cron,
          schedule_value: "0 9 * * *",
          timezone: "Not/AZone",
          mode: :main,
          task: "noop"
        },
        tenant: tenant,
        actor: actor_for(tenant)
      )

    {:ok, "bad-tz", _pid} =
      Scheduler.schedule(tenant,
        id: "bad-tz",
        task: "noop",
        mode: :main,
        schedule: {:cron, "0 9 * * *"},
        timezone: "Not/AZone"
      )

    on_exit(fn -> _ = Scheduler.unschedule(tenant, "bad-tz") end)

    row = wait_until_disabled("bad-tz", tenant)
    assert %DateTime{} = row.disabled_at
  end

  test "an invalid cron expression disables the worker and persists disabled_at",
       %{tenant: tenant} do
    {:ok, _} =
      Job.upsert(
        %{
          job_id: "bad-expr",
          schedule_kind: :cron,
          # Persisted value is irrelevant here — the worker is driven with the
          # bad schedule below; persist_disabled/1 looks the row up by job_id.
          schedule_value: "0 9 * * *",
          mode: :main,
          task: "noop"
        },
        tenant: tenant,
        actor: actor_for(tenant)
      )

    {:ok, "bad-expr", _pid} =
      Scheduler.schedule(tenant,
        id: "bad-expr",
        task: "noop",
        mode: :main,
        schedule: {:cron, "totally invalid"}
      )

    on_exit(fn -> _ = Scheduler.unschedule(tenant, "bad-expr") end)

    row = wait_until_disabled("bad-expr", tenant)
    assert %DateTime{} = row.disabled_at
  end
end
