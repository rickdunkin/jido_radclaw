defmodule Mix.Tasks.Jidoclaw.MigrateCronTest do
  use ExUnit.Case, async: false

  import JidoClaw.ExportTestHelper

  alias JidoClaw.Cron.Job
  alias JidoClaw.Tenants.Tenant

  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(JidoClaw.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end

  describe "tenant FK ensure" do
    test "non-dry run with a brand-new tenant creates the tenants row before upsert" do
      tenant_a = "migrate-cron-test-#{System.unique_integer([:positive])}"
      project_dir = unique_project_dir("migrate-cron")
      write_cron_yaml(project_dir, "job_a", "every 5m")

      reenable!("jidoclaw.migrate.cron")
      Mix.Task.run("jidoclaw.migrate.cron", ["--project", project_dir, "--tenant", tenant_a])

      assert {:ok, %Tenant{id: ^tenant_a}} = Tenant.by_id(tenant_a)
      {:ok, jobs} = Job.for_tenant(tenant: tenant_a)
      assert length(jobs) == 1
      assert hd(jobs).job_id == "job_a"
    end

    test "--dry-run does not create the tenant row or any cron rows" do
      tenant_b = "migrate-cron-dry-#{System.unique_integer([:positive])}"
      project_dir = unique_project_dir("migrate-cron-dry")
      write_cron_yaml(project_dir, "job_b", "every 5m")

      reenable!("jidoclaw.migrate.cron")

      Mix.Task.run("jidoclaw.migrate.cron", [
        "--project",
        project_dir,
        "--tenant",
        tenant_b,
        "--dry-run"
      ])

      assert match?({:error, _}, Tenant.by_id(tenant_b))
      {:ok, jobs} = Job.for_tenant(tenant: tenant_b)
      assert jobs == []
    end

    test "all-invalid YAML does not create the tenant row" do
      tenant_c = "migrate-cron-invalid-#{System.unique_integer([:positive])}"
      project_dir = unique_project_dir("migrate-cron-invalid")
      write_invalid_cron_yaml(project_dir)

      reenable!("jidoclaw.migrate.cron")
      Mix.Task.run("jidoclaw.migrate.cron", ["--project", project_dir, "--tenant", tenant_c])

      assert match?({:error, _}, Tenant.by_id(tenant_c))
      {:ok, jobs} = Job.for_tenant(tenant: tenant_c)
      assert jobs == []
    end
  end

  defp write_cron_yaml(project_dir, job_id, schedule) do
    yaml_dir = Path.join(project_dir, ".jido")
    File.mkdir_p!(yaml_dir)

    yaml = """
    jobs:
      - id: #{job_id}
        task: noop
        schedule: #{schedule}
        mode: main
    """

    File.write!(Path.join(yaml_dir, "cron.yaml"), yaml)
  end

  # Two entries that fail `legacy_to_attrs/1` (missing id; missing schedule).
  defp write_invalid_cron_yaml(project_dir) do
    yaml_dir = Path.join(project_dir, ".jido")
    File.mkdir_p!(yaml_dir)

    yaml = """
    jobs:
      - task: noop
        schedule: every 5m
        mode: main
      - id: incomplete
        task: noop
        mode: main
    """

    File.write!(Path.join(yaml_dir, "cron.yaml"), yaml)
  end
end
