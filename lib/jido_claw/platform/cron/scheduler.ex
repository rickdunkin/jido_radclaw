defmodule JidoClaw.Cron.Scheduler do
  @moduledoc "API for managing cron jobs within a tenant."
  require Logger

  alias JidoClaw.Cron.Persistence

  @doc "Load persisted jobs from .jido/cron.yaml and schedule them."
  @spec load_persistent_jobs(String.t(), String.t()) :: {:ok, non_neg_integer()}
  def load_persistent_jobs(tenant_id \\ "default", project_dir) do
    case Persistence.load(project_dir) do
      {:ok, jobs} ->
        count =
          Enum.reduce(jobs, 0, fn job, acc ->
            opts = build_persistent_opts(job)

            case schedule(tenant_id, opts) do
              {:ok, _, _} ->
                acc + 1

              {:error, reason} ->
                Logger.warning("[Cron] Failed to load job #{job["id"]}: #{inspect(reason)}")
                acc
            end
          end)

        {:ok, count}

      {:error, reason} ->
        Logger.warning("[Cron] Failed to load persistent jobs: #{inspect(reason)}")
        {:ok, 0}
    end
  end

  defp build_persistent_opts(job) do
    id = job["id"] || job[:id]
    task = job["task"] || job[:task]
    schedule_str = job["schedule"] || job[:schedule]
    mode = parse_mode(job["mode"] || job[:mode])

    [
      id: id,
      task: task,
      schedule: parse_schedule(schedule_str),
      mode: mode
    ]
  end

  defp parse_schedule("every " <> interval) do
    case Regex.run(~r/^(\d+)\s*(s|m|h|d)$/i, String.trim(interval)) do
      [_, amount, unit] ->
        ms = String.to_integer(amount) * unit_ms(String.downcase(unit))
        {:every, ms}

      nil ->
        {:cron, interval}
    end
  end

  defp parse_schedule(expr), do: {:cron, expr}

  defp unit_ms("s"), do: 1_000
  defp unit_ms("m"), do: 60_000
  defp unit_ms("h"), do: 3_600_000
  defp unit_ms("d"), do: 86_400_000
  defp unit_ms(_), do: 60_000

  defp parse_mode("isolated"), do: :isolated
  defp parse_mode(_), do: :main

  def schedule(tenant_id, opts) do
    id = Keyword.get(opts, :id, "job_#{:erlang.unique_integer([:positive])}")
    sup = JidoClaw.Tenant.InstanceSupervisor.cron_sup(tenant_id)

    child_spec = {
      JidoClaw.Cron.Worker,
      Keyword.merge(opts, id: id, tenant_id: tenant_id)
    }

    case DynamicSupervisor.start_child(sup, child_spec) do
      {:ok, pid} ->
        Logger.info("[Cron] Scheduled job #{id} for tenant #{tenant_id}")
        {:ok, id, pid}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def unschedule(tenant_id, job_id) do
    name = {:via, Registry, {JidoClaw.TenantRegistry, {:cron, tenant_id, job_id}}}

    case GenServer.whereis(name) do
      nil ->
        {:error, :not_found}

      pid ->
        sup = JidoClaw.Tenant.InstanceSupervisor.cron_sup(tenant_id)
        DynamicSupervisor.terminate_child(sup, pid)
    end
  end

  def list_jobs(tenant_id) do
    sup = JidoClaw.Tenant.InstanceSupervisor.cron_sup(tenant_id)

    case GenServer.whereis(sup) do
      nil ->
        []

      _pid ->
        DynamicSupervisor.which_children(sup)
        |> Enum.map(fn {_, pid, _, _} ->
          try do
            GenServer.call(pid, :get_state, 5000)
          catch
            _, _ -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)
    end
  end

  def trigger(tenant_id, job_id) do
    JidoClaw.Cron.Worker.trigger(tenant_id, job_id)
  end
end
