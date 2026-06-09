defmodule Mix.Tasks.Jidoclaw.Migrate.Cron do
  @moduledoc """
  Migrate `.jido/cron.yaml` into the `cron_jobs` Postgres table.

  Idempotent — `(tenant_id, job_id)` is a composite identity, so re-runs
  upsert without duplicating. The YAML file is left on disk as a backup;
  Step 4's residual file-store sweep test bans new writes to it.

      mix jidoclaw.migrate.cron [--dry-run] [--project DIR] [--tenant TENANT]

  - `--project` defaults to `File.cwd!()`.
  - `--tenant` defaults to `"default"`.
  """
  use Mix.Task

  require Logger

  alias JidoClaw.Authorization.Actor
  alias JidoClaw.Cron.Job
  alias JidoClaw.Tenants.Tenant

  @shortdoc "Migrate .jido/cron.yaml into the cron_jobs table"

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("ash.setup", ["--quiet"])

    {opts, _, _} =
      OptionParser.parse(argv,
        switches: [dry_run: :boolean, project: :string, tenant: :string]
      )

    project_dir = Keyword.get(opts, :project) || File.cwd!()
    tenant = Keyword.get(opts, :tenant) || "default"
    dry_run? = Keyword.get(opts, :dry_run, false)

    yaml_path = Path.join([project_dir, ".jido", "cron.yaml"])

    case load_yaml(yaml_path) do
      {:ok, []} ->
        Mix.shell().info("cron.yaml: empty, nothing to migrate")

      {:ok, jobs} ->
        Mix.shell().info("cron.yaml: #{length(jobs)} jobs (tenant=#{tenant})")
        migrate_jobs(jobs, tenant, dry_run?)

      {:error, :enoent} ->
        Mix.shell().info("cron.yaml: not present at #{yaml_path}, skipping")

      {:error, reason} ->
        Mix.shell().error("cron.yaml: read error (#{inspect(reason)})")
    end
  end

  defp load_yaml(path) do
    if File.exists?(path) do
      case YamlElixir.read_from_file(path) do
        {:ok, %{"jobs" => jobs}} when is_list(jobs) -> {:ok, jobs}
        {:ok, _} -> {:ok, []}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :enoent}
    end
  end

  defp migrate_jobs(jobs, tenant, dry_run?) do
    prepared = Enum.map(jobs, fn job -> {job, legacy_to_attrs(job)} end)
    has_valid? = Enum.any?(prepared, fn {_job, attrs} -> attrs != :invalid end)

    if has_valid? and not dry_run? do
      case Tenant.ensure(tenant) do
        {:ok, _} ->
          :ok

        {:error, err} ->
          Mix.shell().error("tenant ensure failed: #{inspect(err)}")
          exit({:shutdown, 1})
      end
    end

    {inserted, failed} =
      Enum.reduce(prepared, {0, 0}, fn {job, attrs}, {ok_count, fail_count} ->
        cond do
          attrs == :invalid ->
            Mix.shell().error("  skip: invalid job entry #{inspect(job)}")
            {ok_count, fail_count + 1}

          dry_run? ->
            Mix.shell().info("  would upsert: job_id=#{attrs.job_id}")
            {ok_count + 1, fail_count}

          true ->
            case Job.upsert(attrs, tenant: tenant, actor: Actor.system(tenant)) do
              {:ok, _} ->
                {ok_count + 1, fail_count}

              {:error, err} ->
                Logger.warning("[migrate.cron] failed: #{inspect(err)}")
                {ok_count, fail_count + 1}
            end
        end
      end)

    label = if dry_run?, do: "would upsert", else: "upserted"
    Mix.shell().info("\nMigration complete: #{label}=#{inserted} failed=#{failed}")
  end

  defp legacy_to_attrs(job) do
    id = job["id"]
    task = job["task"]
    schedule_str = job["schedule"]
    mode_str = job["mode"] || "main"

    cond do
      not is_binary(id) ->
        :invalid

      not is_binary(schedule_str) ->
        :invalid

      # The cron_jobs :system_job invariant now requires MFA fields, which
      # legacy YAML never carried — such a row would fail the upsert
      # mid-batch. Legacy cron YAML only ever held agent-mode tasks, so a
      # clean skip is the correct semantics.
      mode_str == "system_job" ->
        :invalid

      true ->
        {kind, value} = parse_schedule(schedule_str)

        %{
          job_id: id,
          task: task,
          mode: parse_mode(mode_str),
          schedule_kind: kind,
          schedule_value: value,
          metadata: %{}
        }
    end
  end

  defp parse_schedule("every " <> rest) do
    {:every, normalize_every(String.trim(rest))}
  end

  defp parse_schedule(expr), do: {:cron, expr}

  defp normalize_every(str) do
    case Regex.run(~r/^(\d+)\s*(s|m|h|d)$/i, str) do
      [_, amount, unit] ->
        ms = String.to_integer(amount) * unit_to_ms(String.downcase(unit))
        Integer.to_string(ms)

      _ ->
        str
    end
  end

  defp unit_to_ms("s"), do: 1_000
  defp unit_to_ms("m"), do: 60_000
  defp unit_to_ms("h"), do: 3_600_000
  defp unit_to_ms("d"), do: 86_400_000
  defp unit_to_ms(_), do: 60_000

  defp parse_mode(:main), do: :main
  defp parse_mode(:isolated), do: :isolated
  defp parse_mode(:system_job), do: :system_job
  defp parse_mode("main"), do: :main
  defp parse_mode("isolated"), do: :isolated
  defp parse_mode("system_job"), do: :system_job
  defp parse_mode(_), do: :main
end
