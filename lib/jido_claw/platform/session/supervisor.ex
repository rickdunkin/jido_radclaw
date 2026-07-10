defmodule JidoClaw.Session.Supervisor do
  @moduledoc "Manages session worker processes."

  alias JidoClaw.Session.Worker
  alias JidoClaw.Tenant.InstanceSupervisor

  @spec start_session(String.t(), String.t(), keyword()) :: DynamicSupervisor.on_start_child()
  def start_session(tenant_id, session_id, opts \\ []) do
    # Try tenant-specific supervisor first, fall back to global
    sup = InstanceSupervisor.session_sup(tenant_id)

    child_spec = {
      Worker,
      [tenant_id: tenant_id, session_id: session_id, actor: Keyword.get(opts, :actor)]
    }

    case GenServer.whereis(sup) do
      nil ->
        # Tenant supervisor not started, use global fallback
        DynamicSupervisor.start_child(JidoClaw.SessionSupervisor, child_spec)

      _pid ->
        DynamicSupervisor.start_child(sup, child_spec)
    end
  end

  @spec ensure_session(String.t(), String.t(), keyword()) ::
          DynamicSupervisor.on_start_child() | {:ok, pid()}
  def ensure_session(tenant_id, session_id, opts \\ []) do
    name = {:via, Registry, {JidoClaw.SessionRegistry, {tenant_id, session_id}}}

    case GenServer.whereis(name) do
      nil ->
        start_session(tenant_id, session_id, opts)

      pid ->
        case Keyword.get(opts, :actor) do
          nil -> {:ok, pid}
          actor -> set_actor_on_existing(tenant_id, session_id, actor, pid)
        end
    end
  end

  @doc """
  Stop and remove a live session worker. Idempotent when absent.

  A worker can start under the global fallback before its tenant runtime exists.
  If the tenant supervisor appears later, registry presence alone cannot identify
  which DynamicSupervisor owns that pid. Teardown therefore tries both possible
  owners and reports an error while the registered pid is still alive.
  """
  @spec stop_session(String.t(), String.t()) :: :ok | {:error, term()}
  def stop_session(tenant_id, session_id) do
    name = {:via, Registry, {JidoClaw.SessionRegistry, {tenant_id, session_id}}}

    case GenServer.whereis(name) do
      nil ->
        :ok

      pid ->
        tenant_sup = InstanceSupervisor.session_sup(tenant_id)

        [tenant_sup, JidoClaw.SessionSupervisor]
        |> Enum.uniq()
        |> terminate_from_owner(pid)
    end
  end

  defp terminate_from_owner(supervisors, pid) do
    errors =
      Enum.reduce_while(supervisors, [], fn supervisor, errors ->
        case terminate_child(supervisor, pid) do
          :ok -> {:halt, :stopped}
          {:error, :not_found} -> {:cont, errors}
          {:error, reason} -> {:cont, [{supervisor, reason} | errors]}
        end
      end)

    case errors do
      :stopped ->
        :ok

      errors ->
        if Process.alive?(pid) do
          {:error, {:session_owner_not_found, Enum.reverse(errors)}}
        else
          :ok
        end
    end
  end

  defp terminate_child(supervisor, pid) do
    case GenServer.whereis(supervisor) do
      nil -> {:error, :not_found}
      _pid -> DynamicSupervisor.terminate_child(supervisor, pid)
    end
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp set_actor_on_existing(tenant_id, session_id, actor, pid) do
    _ = Worker.set_actor(tenant_id, session_id, actor)
    {:ok, pid}
  end

  @spec list_sessions(String.t()) :: [{String.t(), pid()}]
  def list_sessions(tenant_id) do
    entries =
      Registry.select(JidoClaw.SessionRegistry, [
        {{{:"$1", :"$2"}, :"$3", :_}, [{:==, :"$1", tenant_id}], [{{:"$1", :"$2", :"$3"}}]}
      ])

    Enum.map(entries, fn {_tid, sid, pid} -> {sid, pid} end)
  end
end
