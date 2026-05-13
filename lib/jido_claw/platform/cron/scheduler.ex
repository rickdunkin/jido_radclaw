defmodule JidoClaw.Cron.Scheduler do
  @moduledoc "API for managing cron jobs within a tenant."
  require Logger

  alias JidoClaw.Cron.Job
  alias JidoClaw.Cron.Worker
  alias JidoClaw.Tenant.InstanceSupervisor

  @doc """
  Load persisted jobs from `cron_jobs` (Postgres) and schedule them.

  Replaces the v0.5.x `.jido/cron.yaml` file-store. The action's
  `:for_tenant` filter excludes `disabled_at IS NOT NULL` rows so a
  worker-side auto-disable survives restart.
  """
  @spec load_persistent_jobs(String.t(), String.t()) :: {:ok, non_neg_integer()}
  def load_persistent_jobs(tenant_id \\ "default", _project_dir) do
    case Job.for_tenant(tenant: tenant_id, authorize?: false) do
      {:ok, jobs} ->
        count =
          Enum.reduce(jobs, 0, fn job, acc ->
            case try_schedule_job(tenant_id, job) do
              :ok ->
                acc + 1

              {:error, :schedule, reason} ->
                Logger.warning("[Cron] Failed to schedule job #{job.job_id}: #{inspect(reason)}")
                acc

              {:error, :build_opts, reason} ->
                Logger.warning(
                  "[Cron] Skipping invalid persisted job #{job.job_id}: #{inspect(reason)}"
                )

                acc
            end
          end)

        {:ok, count}

      {:error, reason} ->
        Logger.warning("[Cron] Failed to load persistent jobs: #{inspect(reason)}")
        {:ok, 0}
    end
  end

  defp try_schedule_job(tenant_id, job) do
    case build_persistent_opts(job) do
      {:ok, opts} ->
        case schedule(tenant_id, opts) do
          {:ok, _, _} -> :ok
          {:error, reason} -> {:error, :schedule, reason}
        end

      {:error, reason} ->
        {:error, :build_opts, reason}
    end
  end

  defp build_persistent_opts(%Job{} = job) do
    base = [
      id: job.job_id,
      task: job.task,
      schedule: hydrate_schedule(job.schedule_kind, job.schedule_value),
      mode: job.mode
    ]

    case build_mfa(job) do
      {:ok, nil} -> {:ok, base}
      {:ok, mfa} -> {:ok, Keyword.put(base, :mfa, mfa)}
      {:error, reason} -> {:error, reason}
    end
  end

  # Non-system_job rows don't need an MFA.
  defp build_mfa(%Job{mode: mode}) when mode != :system_job, do: {:ok, nil}

  # system_job rows REQUIRE an MFA. Missing it on reload = data corruption,
  # don't schedule.
  defp build_mfa(%Job{mfa_module: nil}), do: {:error, :missing_mfa_module}

  defp build_mfa(%Job{mfa_module: mod_str, mfa_function: fun_str, mfa_args: args}) do
    with {:ok, module} <- resolve_module(mod_str),
         {:ok, function} <- resolve_atom(fun_str),
         {:ok, arg_list} <- mfa_args_to_list(args),
         :ok <- ensure_exported(module, function, length(arg_list)) do
      {:ok, {module, function, arg_list}}
    end
  end

  # Writers may persist either "JidoClaw.Cron.TestSupport" or
  # "Elixir.JidoClaw.Cron.TestSupport". Normalize before lookup.
  defp resolve_module(str) when is_binary(str) do
    normalized =
      if String.starts_with?(str, "Elixir."), do: str, else: "Elixir." <> str

    try do
      {:ok, String.to_existing_atom(normalized)}
    rescue
      ArgumentError -> {:error, {:unknown_module, str}}
    end
  end

  defp resolve_module(other), do: {:error, {:invalid_module, other}}

  defp resolve_atom(str) when is_binary(str) do
    {:ok, String.to_existing_atom(str)}
  rescue
    ArgumentError -> {:error, {:unknown_function, str}}
  end

  defp resolve_atom(other), do: {:error, {:invalid_atom, other}}

  # mfa_args is :map (jsonb) so it round-trips through Postgres, but MFA
  # args are positional. Today every system job uses []; non-empty maps
  # return an explicit error rather than reordering Map.values.
  defp mfa_args_to_list(args) when args == %{} or is_nil(args), do: {:ok, []}
  defp mfa_args_to_list(args), do: {:error, {:unsupported_args_shape, args}}

  defp ensure_exported(module, function, arity) do
    with {:module, ^module} <- Code.ensure_loaded(module),
         true <- function_exported?(module, function, arity) do
      :ok
    else
      _ -> {:error, {:not_exported, module, function, arity}}
    end
  end

  defp hydrate_schedule(:cron, expr), do: {:cron, expr}

  defp hydrate_schedule(:every, ms_str) do
    case Integer.parse(ms_str || "") do
      {ms, _} when ms > 0 -> {:every, ms}
      _ -> {:cron, ms_str || ""}
    end
  end

  defp hydrate_schedule(:at, iso) do
    case DateTime.from_iso8601(iso || "") do
      {:ok, dt, _} -> {:at, dt}
      _ -> {:cron, ""}
    end
  end

  def schedule(tenant_id, opts) do
    id = Keyword.get(opts, :id, "job_#{:erlang.unique_integer([:positive])}")
    sup = InstanceSupervisor.cron_sup(tenant_id)

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
        sup = InstanceSupervisor.cron_sup(tenant_id)
        DynamicSupervisor.terminate_child(sup, pid)
    end
  end

  def list_jobs(tenant_id) do
    sup = InstanceSupervisor.cron_sup(tenant_id)

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
    Worker.trigger(tenant_id, job_id)
  end

  @doc """
  Schedule platform-owned recurring jobs under the `"system"` tenant.

  Read at boot (after the `"system"` tenant has been ensured). Each
  job here is `mode: :system_job` and resolves via an `{m, f, a}`
  call so it bypasses the JidoClaw.chat path. Today the only job is
  the memory consolidator tick.

  Returns `:ok` regardless — failures Logger.warning out so a dead
  config can never block app boot.
  """
  @spec start_system_jobs() :: :ok
  def start_system_jobs do
    config = Application.get_env(:jido_claw, JidoClaw.Memory.Consolidator, [])

    if Keyword.get(config, :enabled, false) do
      cadence = Keyword.get(config, :cadence, "0 */6 * * *")

      result =
        schedule("system",
          id: "memory_consolidator",
          task: "consolidate",
          schedule: parse_schedule(cadence),
          mode: :system_job,
          mfa: {JidoClaw.Memory.Consolidator, :tick, []}
        )

      case result do
        {:ok, _, _} ->
          Logger.info("[Cron] Scheduled system job memory_consolidator (#{cadence})")
          :ok

        {:error, reason} ->
          Logger.warning("[Cron] Failed to schedule memory_consolidator: #{inspect(reason)}")
          :ok
      end
    else
      :ok
    end
  end

  # Used by start_system_jobs/0 to parse the cadence config string.
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
end
