defmodule JidoClaw.Tools.UnscheduleTaskTest do
  @moduledoc """
  Coverage for the `unschedule_task` tool's outcomes (WS4a code-review Finding 3):
  a genuine removal and a genuine not-found (classified from whichever shape
  `Job.by_job_id`'s get? read surfaces — bare `Ash.Error.Query.NotFound` or one
  wrapped in `Ash.Error.Invalid`).

  The two real-failure branches (`{:read_failed, _}` / `{:remove_failed, _}`) are
  not deterministically forceable in a unit test: the Job policy ties read and
  destroy to the same actor-tenant match, so a mismatch fails the *read* first as
  not-found, and the tool re-reads a fresh row so a stale-record destroy error is
  unreachable mid-call. They are correct-by-construction (same shape as
  `verify_certificate.ex` / `list_scheduled_tasks.ex`) and covered by the type
  contract.

  `async: false` mirrors `schedule_task_test.exs` (it owns tenant-scoped cron
  state). The `cluster_leader_module` stub is intentionally *not* installed: the
  Owner is disabled in test, so `notify_changed/1` no-ops to `:ok` exactly as it
  does for the passing `schedule_task` tool.
  """
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Cron.Job
  alias JidoClaw.Tenant.Manager
  alias JidoClaw.Tools.UnscheduleTask

  @day_ms "86400000"

  setup do
    tenant = seed_tenant("unschedule-task")
    {:ok, _} = Manager.ensure_tenant(tenant)

    ctx = %{tool_context: %{tenant_id: tenant, actor: actor_for(tenant)}}

    {:ok, tenant: tenant, ctx: ctx}
  end

  test "removes a persisted job", %{tenant: tenant, ctx: ctx} do
    id = "rm-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Job.upsert(
        %{
          job_id: id,
          task: "t",
          mode: :main,
          target: :agent,
          schedule_kind: :every,
          schedule_value: @day_ms
        },
        tenant: tenant,
        actor: actor_for(tenant)
      )

    assert {:ok, %{result: result}} = UnscheduleTask.run(%{id: id}, ctx)
    assert result =~ "Removed"

    # Row is gone (Owner is disabled in test, so notify_changed no-ops to :ok).
    assert {:error, _} = Job.by_job_id(id, tenant: tenant, actor: actor_for(tenant))
  end

  test "a genuine not-found returns the friendly message", %{ctx: ctx} do
    assert {:ok, %{result: result}} = UnscheduleTask.run(%{id: "ghost"}, ctx)
    assert result =~ "not found"
  end
end
