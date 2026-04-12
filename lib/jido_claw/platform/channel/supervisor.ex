defmodule JidoClaw.Channel.Supervisor do
  @moduledoc "Manages channel adapter processes per tenant."

  def start_channel(tenant_id, adapter_module, config) do
    sup = JidoClaw.Tenant.InstanceSupervisor.channel_sup(tenant_id)

    child_spec = {
      JidoClaw.Channel.Worker,
      tenant_id: tenant_id, adapter: adapter_module, config: config
    }

    DynamicSupervisor.start_child(sup, child_spec)
  end

  def stop_channel(tenant_id, pid) do
    sup = JidoClaw.Tenant.InstanceSupervisor.channel_sup(tenant_id)
    DynamicSupervisor.terminate_child(sup, pid)
  end

  def list_channels(tenant_id) do
    sup = JidoClaw.Tenant.InstanceSupervisor.channel_sup(tenant_id)

    case GenServer.whereis(sup) do
      nil ->
        []

      _pid ->
        DynamicSupervisor.which_children(sup)
        |> Enum.map(fn {_, pid, _, _} ->
          try do
            GenServer.call(pid, :get_info, 5000)
          catch
            _, _ -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)
    end
  end
end
