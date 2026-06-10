defmodule JidoClaw.Memory.Consolidator.SystemJobsInitializer do
  @moduledoc """
  One-shot startup task that ensures the `"system"` tenant exists
  and registers platform-owned cron jobs (today: the memory
  consolidator tick).

  Mirrors `JidoClaw.MCPScope.Initializer`. Started as a transient
  Task in the application supervision tree so a failure here surfaces
  loudly without preventing the rest of the app from booting.
  """

  use Task

  require Logger

  alias JidoClaw.Cron.Scheduler
  alias JidoClaw.Tenant.Manager

  @spec start_link(term()) :: {:ok, pid()}
  def start_link(opts) do
    Task.start_link(__MODULE__, :run, [opts])
  end

  @spec run(term()) :: :ok
  def run(_opts) do
    case Manager.ensure_tenant("system", name: "System") do
      {:ok, _tenant} ->
        Scheduler.start_system_jobs()

      {:error, reason} ->
        Logger.warning("[Memory.Consolidator] failed to ensure system tenant: #{inspect(reason)}")
    end

    :ok
  end
end
