defmodule JidoClaw.Tenant.InstanceSupervisor do
  @moduledoc """
  Per-tenant supervisor. Each tenant gets isolated session, cron, and tool
  supervisors.
  """
  use Supervisor

  @typedoc "A `{:via, Registry, key}` process name routed through `JidoClaw.TenantRegistry`."
  @type via_name :: {:via, module(), term()}

  @spec start_instance(String.t()) :: DynamicSupervisor.on_start_child()
  def start_instance(tenant_id) do
    DynamicSupervisor.start_child(
      JidoClaw.Tenant.Supervisor,
      {__MODULE__, tenant_id: tenant_id}
    )
  end

  @spec stop_instance(String.t()) :: :ok | {:error, :not_found}
  def stop_instance(tenant_id) do
    name = via(tenant_id)

    case GenServer.whereis(name) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(JidoClaw.Tenant.Supervisor, pid)
    end
  end

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    tenant_id = Keyword.fetch!(opts, :tenant_id)
    Supervisor.start_link(__MODULE__, tenant_id, name: via(tenant_id))
  end

  @impl Supervisor
  def init(tenant_id) do
    children = [
      {DynamicSupervisor, name: session_sup(tenant_id), strategy: :one_for_one},
      {DynamicSupervisor, name: cron_sup(tenant_id), strategy: :one_for_one},
      {Task.Supervisor, name: tool_sup(tenant_id)}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  # -- Registry helpers --

  defp via(tenant_id), do: {:via, Registry, {JidoClaw.TenantRegistry, {:instance, tenant_id}}}

  @spec session_sup(String.t()) :: via_name()
  def session_sup(tenant_id),
    do: {:via, Registry, {JidoClaw.TenantRegistry, {:session_sup, tenant_id}}}

  @spec cron_sup(String.t()) :: via_name()
  def cron_sup(tenant_id), do: {:via, Registry, {JidoClaw.TenantRegistry, {:cron_sup, tenant_id}}}

  @spec tool_sup(String.t()) :: via_name()
  def tool_sup(tenant_id), do: {:via, Registry, {JidoClaw.TenantRegistry, {:tool_sup, tenant_id}}}
end
