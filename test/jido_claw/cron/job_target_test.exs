defmodule JidoClaw.Cron.JobTargetTest do
  @moduledoc """
  Coverage for the T2-5 execution-target dimension on `Cron.Job`: the
  `target` enum + workflow fields, the `run_count`/`last_run_at`
  durability counters stamped inside the fenced `record_success` /
  `record_failure` outcome writes, and the `:upsert` invariants that stop
  a bad row from silently always-failing at dispatch.
  """
  use JidoClaw.TenantCase, async: true

  alias JidoClaw.Cron.Job

  defp base_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        job_id: "job-#{System.unique_integer([:positive])}",
        task: "say hello",
        mode: :main,
        schedule_kind: :cron,
        schedule_value: "0 9 * * *"
      },
      overrides
    )
  end

  describe "target attribute" do
    test "defaults to :agent with zeroed counters" do
      tenant = seed_tenant("tgt-default")
      {:ok, row} = Job.upsert(base_attrs(), tenant: tenant, actor: actor_for(tenant))

      assert row.target == :agent
      assert row.run_count == 0
      assert is_nil(row.last_run_at)
    end

    test "accepts :workflow and round-trips workflow_name + workflow_input" do
      tenant = seed_tenant("tgt-wf")

      attrs =
        base_attrs(%{
          target: :workflow,
          workflow_name: "explore_codebase",
          workflow_input: %{"context" => "do it"}
        })

      {:ok, row} = Job.upsert(attrs, tenant: tenant, actor: actor_for(tenant))

      assert row.target == :workflow
      assert row.workflow_name == "explore_codebase"
      assert row.workflow_input == %{"context" => "do it"}
    end

    test "accepts :mfa when MFA fields are present" do
      tenant = seed_tenant("tgt-mfa")

      attrs =
        base_attrs(%{
          target: :mfa,
          mfa_module: "JidoClaw.Cron.TestSupport",
          mfa_function: "always_fail"
        })

      {:ok, row} = Job.upsert(attrs, tenant: tenant, actor: actor_for(tenant))
      assert row.target == :mfa
    end
  end

  describe "durability counters (fenced outcome writes)" do
    test "record_success and record_failure increment run_count and stamp last_run_at" do
      tenant = seed_tenant("record-run")
      {:ok, row} = Job.upsert(base_attrs(), tenant: tenant, actor: actor_for(tenant))
      assert row.run_count == 0
      assert is_nil(row.last_run_at)

      {:ok, after1} =
        Job.record_success(row, row.definition_token, tenant: tenant, actor: actor_for(tenant))

      assert after1.run_count == 1

      # Assert the DURABLE stamp on a reload (the manual action's raw
      # RETURNING carries an uncast NaiveDateTime in the in-memory struct).
      {:ok, reloaded} = Job.by_job_id(row.job_id, tenant: tenant, actor: actor_for(tenant))
      assert %DateTime{} = reloaded.last_run_at

      {:ok, after2} =
        Job.record_failure(after1, row.definition_token,
          tenant: tenant,
          actor: actor_for(tenant)
        )

      assert after2.run_count == 2
      assert after2.failure_count == 1
    end
  end

  describe ":upsert invariants" do
    test "rejects target: :workflow with no workflow_name" do
      tenant = seed_tenant("inv-wf")
      attrs = base_attrs(%{target: :workflow})

      assert {:error, %Ash.Error.Invalid{}} =
               Job.upsert(attrs, tenant: tenant, actor: actor_for(tenant))
    end

    test "rejects target: :mfa with no mfa_module/mfa_function" do
      tenant = seed_tenant("inv-mfa")
      attrs = base_attrs(%{target: :mfa})

      assert {:error, %Ash.Error.Invalid{}} =
               Job.upsert(attrs, tenant: tenant, actor: actor_for(tenant))
    end
  end
end
