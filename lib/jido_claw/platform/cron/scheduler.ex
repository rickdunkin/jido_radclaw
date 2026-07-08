defmodule JidoClaw.Cron.Scheduler do
  @moduledoc "API for managing cron jobs within a tenant."
  require Logger

  alias JidoClaw.Authorization.Actor
  alias JidoClaw.Cron.Job
  alias JidoClaw.Cron.OutcomeSpec
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
    case Job.for_tenant(tenant: tenant_id, actor: Actor.system(tenant_id)) do
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

  # A persisted :workflow row with no skill name can only ever fail at
  # dispatch — skip it on reload (logged by try_schedule_job/2's
  # {:error, :build_opts, _} branch) rather than booting a doomed worker.
  defp build_persistent_opts(%Job{target: :workflow, workflow_name: nil}),
    do: {:error, :missing_workflow_name}

  defp build_persistent_opts(%Job{} = job) do
    base = [
      id: job.job_id,
      task: job.task,
      schedule: hydrate_schedule(job.schedule_kind, job.schedule_value),
      mode: job.mode,
      target: job.target,
      workflow_name: job.workflow_name,
      workflow_input: job.workflow_input,
      timezone: job.timezone,
      # Item 9 (OH1-3): the outcome contract is live at fire time — hydrated
      # through the single canonicalizer (junk/absent metadata ⇒ nil, no
      # contract) and carried in the fingerprint so a contract edit
      # reconciles the running worker.
      outcome_spec: OutcomeSpec.normalize(job_metadata_spec(job))
    ]

    case build_mfa(job) do
      {:ok, nil} -> {:ok, base}
      {:ok, mfa} -> {:ok, Keyword.put(base, :mfa, mfa)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp job_metadata_spec(%Job{metadata: %{} = metadata}), do: Map.get(metadata, "outcome_spec")
  defp job_metadata_spec(%Job{}), do: nil

  # Rows that dispatch via MFA — mode: :system_job OR target: :mfa — REQUIRE
  # an MFA. Any other combination doesn't, so resolve none.
  defp build_mfa(%Job{mode: mode, target: target})
       when mode != :system_job and target != :mfa,
       do: {:ok, nil}

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

  @doc """
  Hydrate a persisted `(schedule_kind, schedule_value)` pair into the runtime
  schedule tuple (`{:cron, expr}` | `{:every, ms}` | `{:at, dt}`).

  Shared by the worker build path (`build_persistent_opts/1`) and the
  row-backed list views (CLI `/cron`, the `list_scheduled_tasks` tool), so the
  display reads the same shape the worker runs. A malformed `:every`/`:at`
  value falls back to `{:cron, value}` — the worker rejects that as a config
  error rather than firing a silently-wrong schedule.
  """
  @spec hydrate_schedule(atom(), String.t() | nil) :: {atom(), term()}
  def hydrate_schedule(:cron, expr), do: {:cron, expr}

  def hydrate_schedule(:every, ms_str) do
    case Integer.parse(ms_str || "") do
      {ms, _} when ms > 0 -> {:every, ms}
      _ -> {:cron, ms_str || ""}
    end
  end

  def hydrate_schedule(:at, iso) do
    case DateTime.from_iso8601(iso || "") do
      {:ok, dt, _} -> {:at, dt}
      _ -> {:cron, ""}
    end
  end

  @spec schedule(String.t(), keyword()) :: {:ok, String.t(), pid()} | {:error, term()}
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

  @doc """
  Schedule one persisted `Cron.Job` row — the per-job form of the reload path,
  used by `JidoClaw.Cron.Owner`'s reconcile to bring a missing worker up.

  Reuses `build_persistent_opts/1` (so an unbuildable row — `:workflow` with no
  `workflow_name`, `:mfa`/`:system_job` with a bad module — is logged and
  skipped rather than booting a doomed worker). Idempotent: a benign
  `{:already_started, _}` race with a concurrent reconcile is treated as `:ok`
  — the fingerprint pass (`changed?/2`) owns *config changes*, not creation.
  """
  @spec schedule_persisted(String.t(), Job.t()) :: :ok | {:error, term()}
  def schedule_persisted(tenant_id, %Job{} = job) do
    case build_persistent_opts(job) do
      {:ok, opts} ->
        case schedule(tenant_id, opts) do
          {:ok, _id, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        Logger.warning("[Cron] Skipping invalid persisted job #{job.job_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Whether a persisted `Cron.Job` row's config differs from the running
  `Cron.Worker`'s state — the reconcile restart decision.

  Compares only the *config* fields (schedule, task, mode, target,
  workflow_name, workflow_input, mfa, timezone), never runtime
  status/failure_count/next_run/last_run. Returns `{:error, _}` for an
  unbuildable desired row so the caller can KEEP the working worker rather than
  unschedule it before a reschedule that would fail.
  """
  @spec changed?(Job.t(), Worker.t()) :: {:ok, boolean()} | {:error, term()}
  def changed?(%Job{} = job, %Worker{} = worker) do
    case desired_fingerprint(job) do
      {:ok, desired} -> {:ok, desired != worker_fingerprint(worker)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The comparable config fingerprint of a persisted `Cron.Job` row, or
  `{:error, _}` when the row cannot be built into worker opts.
  """
  @spec desired_fingerprint(Job.t()) :: {:ok, map()} | {:error, term()}
  def desired_fingerprint(%Job{} = job) do
    case build_persistent_opts(job) do
      {:ok, opts} -> {:ok, fingerprint_from_opts(opts)}
      {:error, reason} -> {:error, reason}
    end
  end

  # The config projection both sides reduce to. `build_persistent_opts/1`
  # already hydrates the schedule and omits :mfa when nil, so a nil-mfa row and
  # a nil-mfa worker compare equal.
  defp fingerprint_from_opts(opts) do
    %{
      schedule: Keyword.get(opts, :schedule),
      task: Keyword.get(opts, :task),
      mode: Keyword.get(opts, :mode),
      target: Keyword.get(opts, :target),
      workflow_name: Keyword.get(opts, :workflow_name),
      workflow_input: Keyword.get(opts, :workflow_input),
      mfa: Keyword.get(opts, :mfa),
      timezone: Keyword.get(opts, :timezone),
      outcome_spec: Keyword.get(opts, :outcome_spec)
    }
  end

  defp worker_fingerprint(%Worker{} = w) do
    %{
      schedule: w.schedule,
      task: w.task,
      mode: w.mode,
      target: w.target,
      workflow_name: w.workflow_name,
      workflow_input: w.workflow_input,
      mfa: w.mfa,
      timezone: w.timezone,
      outcome_spec: w.outcome_spec
    }
  end

  @spec unschedule(String.t(), String.t()) :: :ok | {:error, :not_found}
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

  @spec list_jobs(String.t()) :: [struct()]
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

  @doc """
  Every locally-running USER cron worker, as `{tenant_id, job_id}` pairs.

  A `Registry.select` over `JidoClaw.TenantRegistry` for `{:cron, t, id}` keys,
  rejecting the reserved `"system"` tenant (whose only worker is the WS4-managed
  `:system_job` consolidator tick). Pure local runtime state — **no Postgres** —
  so `JidoClaw.Cron.Owner`'s follower-drop path sheds workers even when the DB
  is unreachable.
  """
  @spec local_user_cron_workers() :: [{String.t(), String.t()}]
  def local_user_cron_workers do
    JidoClaw.TenantRegistry
    |> Registry.select([{{{:cron, :"$1", :"$2"}, :_, :_}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.reject(fn {tenant_id, _job_id} -> tenant_id == "system" end)
  end

  @doc """
  Fire a job's worker now. Returns `{:error, :not_found}` when no worker is
  registered (so `JidoClaw.Cron.Owner.trigger/2` reports an honest result),
  else delegates to the worker's manual-trigger cast.
  """
  @spec trigger(String.t(), String.t()) :: :ok | {:error, :not_found}
  def trigger(tenant_id, job_id) do
    name = {:via, Registry, {JidoClaw.TenantRegistry, {:cron, tenant_id, job_id}}}

    case GenServer.whereis(name) do
      nil -> {:error, :not_found}
      _pid -> Worker.trigger(tenant_id, job_id)
    end
  end

  @doc """
  Schedule platform-owned recurring jobs under the `"system"` tenant.

  Read at boot (after the `"system"` tenant has been ensured). Each
  job here is `mode: :system_job` and resolves via an `{m, f, a}`
  call so it bypasses the JidoClaw.chat path. Today the only job is
  the memory consolidator tick.

  Returns `:ok` regardless — failures Logger.warning out so a dead
  config can never block app boot.

  ## Clustering invariant (WS4)

  These `:system_job` rows are replicated on every node and would multi-fire
  under clustering. `Cron.Worker` leader-gates their ticks (`leader_gated?/1`),
  but the gate is first-line only — `:pg` leadership is eventually-consistent,
  so a brief two-leaders window can fire a tick on two nodes. **Every system
  job registered here must therefore stay idempotent / row-claimed / DB-leased
  independently of the gate.** The memory consolidator's `pg_try_advisory_lock`
  (`JidoClaw.Memory.Consolidator.LockOwner`) is the model; a `:workflow`-target
  system job would additionally carry the `cron:<job>:<window>` idempotency key.
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
