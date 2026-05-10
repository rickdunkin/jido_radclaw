defmodule JidoClaw.Cron.JobTest do
  @moduledoc """
  Coverage for the v0.6.4 `JidoClaw.Cron.Job` resource.

  Locks in:

    * `:upsert` on `(tenant_id, job_id)` identity — second call with
      same id updates rather than inserts.
    * `:upsert` accept list excludes `tenant_id` (threaded via opt).
    * `:disable` sets `disabled_at`; `:enable` clears it.
    * `:remove` (destroy) removes the row.
    * `:by_id_global` bypasses tenancy; `:by_id` requires it.
    * `:by_job_id` and `:for_tenant` return correct subsets;
      `:for_tenant` excludes disabled rows.
    * All three `schedule_kind` values round-trip correctly.
  """
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Cron.Job

  defp upsert_attrs(opts \\ []) do
    %{
      job_id: Keyword.get(opts, :job_id, "job-#{System.unique_integer([:positive])}"),
      task: Keyword.get(opts, :task, "say hello"),
      mode: Keyword.get(opts, :mode, :main),
      schedule_kind: Keyword.get(opts, :schedule_kind, :cron),
      schedule_value: Keyword.get(opts, :schedule_value, "0 9 * * *"),
      mfa_module: Keyword.get(opts, :mfa_module),
      mfa_function: Keyword.get(opts, :mfa_function),
      mfa_args: Keyword.get(opts, :mfa_args, %{}),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  describe ":upsert" do
    test "first call inserts; second call with same (tenant_id, job_id) updates rather than insert" do
      tenant_id = seed_tenant("cron-upsert")
      attrs = upsert_attrs(job_id: "daily-report", task: "v1")

      {:ok, first} = Job.upsert(attrs, tenant: tenant_id)
      assert first.task == "v1"

      Process.sleep(2)

      updated = Map.put(attrs, :task, "v2")
      {:ok, second} = Job.upsert(updated, tenant: tenant_id)

      assert second.id == first.id
      assert second.task == "v2"
      assert DateTime.compare(second.updated_at, first.updated_at) == :gt
    end

    test "different tenants with the same job_id produce distinct rows" do
      tenant_a = seed_tenant("cron-tenant-a")
      tenant_b = seed_tenant("cron-tenant-b")

      attrs = upsert_attrs(job_id: "shared-id")

      {:ok, a_row} = Job.upsert(attrs, tenant: tenant_a)
      {:ok, b_row} = Job.upsert(attrs, tenant: tenant_b)

      refute a_row.id == b_row.id
      assert a_row.tenant_id == tenant_a
      assert b_row.tenant_id == tenant_b
    end

    test "rejects writes that try to set tenant_id via attrs (not in accept list)" do
      tenant_id = seed_tenant("cron-reject-attr")

      attrs =
        upsert_attrs()
        |> Map.put(:tenant_id, "wrong-tenant")

      assert {:error, %Ash.Error.Invalid{} = err} = Job.upsert(attrs, tenant: tenant_id)
      assert inspect(err) =~ "NoSuchInput" or inspect(err) =~ "tenant_id"
    end
  end

  describe ":disable / :enable" do
    test ":disable stamps disabled_at; :enable clears it" do
      tenant_id = seed_tenant("cron-disable")
      {:ok, row} = Job.upsert(upsert_attrs(), tenant: tenant_id)
      assert is_nil(row.disabled_at)

      {:ok, disabled} = Job.disable(row, %{}, tenant: tenant_id)
      assert %DateTime{} = disabled.disabled_at

      {:ok, enabled} = Job.enable(disabled, %{}, tenant: tenant_id)
      assert is_nil(enabled.disabled_at)
    end
  end

  describe ":remove" do
    test "destroys the row" do
      tenant_id = seed_tenant("cron-remove")
      {:ok, row} = Job.upsert(upsert_attrs(), tenant: tenant_id)

      :ok = Job.remove(row, tenant: tenant_id)

      assert {:error, _} = Job.by_id(row.id, tenant: tenant_id)
    end
  end

  describe ":by_id / :by_id_global" do
    test ":by_id requires the supplied tenant" do
      tenant_id = seed_tenant("cron-by-id")
      other_tenant = seed_tenant("cron-by-id-other")

      {:ok, row} = Job.upsert(upsert_attrs(), tenant: tenant_id)

      assert {:ok, _} = Job.by_id(row.id, tenant: tenant_id)
      assert {:error, _} = Job.by_id(row.id, tenant: other_tenant)
    end

    test ":by_id_global bypasses tenancy" do
      tenant_id = seed_tenant("cron-by-id-global")
      {:ok, row} = Job.upsert(upsert_attrs(), tenant: tenant_id)

      assert {:ok, fetched} = Job.by_id_global(row.id)
      assert fetched.id == row.id
      assert fetched.tenant_id == tenant_id
    end
  end

  describe ":by_job_id / :for_tenant" do
    test ":by_job_id returns the matching row under the active tenant" do
      tenant_id = seed_tenant("cron-by-job-id")
      {:ok, _} = Job.upsert(upsert_attrs(job_id: "want-me"), tenant: tenant_id)
      {:ok, _} = Job.upsert(upsert_attrs(job_id: "skip-me"), tenant: tenant_id)

      assert {:ok, row} = Job.by_job_id("want-me", tenant: tenant_id)
      assert row.job_id == "want-me"
    end

    test ":for_tenant excludes rows with disabled_at set" do
      tenant_id = seed_tenant("cron-for-tenant")

      {:ok, active} = Job.upsert(upsert_attrs(job_id: "active"), tenant: tenant_id)
      {:ok, will_disable} = Job.upsert(upsert_attrs(job_id: "to-disable"), tenant: tenant_id)
      {:ok, _disabled} = Job.disable(will_disable, %{}, tenant: tenant_id)

      {:ok, rows} = Job.for_tenant(tenant: tenant_id)

      job_ids = Enum.map(rows, & &1.job_id)
      assert "active" in job_ids
      refute "to-disable" in job_ids
      _ = active
    end
  end

  describe "schedule_kind round-trip" do
    test "accepts :cron / :every / :at" do
      tenant_id = seed_tenant("cron-kinds")

      schedules = [
        {:cron, "0 9 * * *"},
        {:every, "60000"},
        {:at, "2030-01-01T00:00:00Z"}
      ]

      for {kind, value} <- schedules do
        attrs = upsert_attrs(schedule_kind: kind, schedule_value: value, job_id: "kind-#{kind}")
        assert {:ok, row} = Job.upsert(attrs, tenant: tenant_id)
        assert row.schedule_kind == kind
        assert row.schedule_value == value
      end
    end
  end
end
