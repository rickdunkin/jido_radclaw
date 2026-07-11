defmodule JidoClaw.Tenant.Manager do
  @moduledoc "Manages tenant lifecycle: create, suspend, destroy, list."
  # Tenant Manager GenServer: best-effort Postgres row sync must never
  # crash the cluster-wide manager — a transient DB raise becomes a log.
  # reach:disable-for-this-file bare_rescue
  use GenServer
  require Logger

  alias JidoClaw.Tenant.InstanceSupervisor
  alias JidoClaw.Tenants.Tenant, as: TenantRow

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # Client API

  @spec create_tenant(keyword()) :: {:ok, JidoClaw.Tenant.t()} | {:error, term()}
  def create_tenant(attrs \\ []) do
    GenServer.call(__MODULE__, {:create, attrs})
  end

  @spec get_tenant(String.t()) :: {:ok, JidoClaw.Tenant.t()} | {:error, :not_found}
  def get_tenant(id) do
    GenServer.call(__MODULE__, {:get, id})
  end

  @spec list_tenants() :: [JidoClaw.Tenant.t()]
  def list_tenants do
    GenServer.call(__MODULE__, :list)
  end

  @doc """
  Idempotently ensure a tenant with the given id exists and is
  supervised. Used during boot for the `"system"` tenant that owns
  platform-level cron jobs (e.g. the memory consolidator tick).
  """
  @spec ensure_tenant(String.t(), keyword()) :: {:ok, JidoClaw.Tenant.t()} | {:error, term()}
  def ensure_tenant(id, attrs \\ []) when is_binary(id) do
    GenServer.call(__MODULE__, {:ensure, id, attrs})
  end

  @spec suspend_tenant(String.t()) :: {:ok, TenantRow.t()} | {:error, term()}
  def suspend_tenant(id) do
    with {:ok, row} <- TenantRow.by_id(id), do: TenantRow.suspend(row)
  end

  @spec resume_tenant(String.t()) :: {:ok, TenantRow.t()} | {:error, term()}
  def resume_tenant(id) do
    with {:ok, row} <- TenantRow.by_id(id), do: TenantRow.resume(row)
  end

  @doc false
  @spec sync_from_resource(String.t(), JidoClaw.Tenant.status()) :: :ok
  def sync_from_resource(id, status) do
    GenServer.call(__MODULE__, {:sync_from_resource, id, status})
  end

  @spec destroy_tenant(String.t()) :: :ok | {:error, :not_found}
  def destroy_tenant(id) do
    GenServer.call(__MODULE__, {:destroy, id})
  end

  @spec count() :: non_neg_integer()
  def count do
    GenServer.call(__MODULE__, :count)
  end

  # Server

  @impl GenServer
  def init(_opts) do
    tenants = :ets.new(:jido_claw_tenants, [:set, :named_table, :public, read_concurrency: true])
    # Schedule default tenant creation after init completes (no race condition)
    send(self(), :create_default_tenant)
    {:ok, %{table: tenants}}
  end

  @impl GenServer
  def handle_info(:create_default_tenant, state) do
    case :ets.lookup(state.table, "default") do
      [] ->
        case register_durable(id: "default", name: "Default") do
          {:ok, tenant} ->
            :ok = reconcile_runtime(tenant)
            :ets.insert(state.table, {tenant.id, tenant})
            JidoClaw.Telemetry.emit_tenant_create(%{tenant_id: tenant.id})
            Logger.info("[Tenant] Default tenant loaded (#{tenant.status})")

          {:error, reason} ->
            Logger.warning("[Tenant] Failed to load default tenant: #{inspect(reason)}")
        end

      _ ->
        :ok
    end

    {:noreply, state}
  end

  @impl GenServer
  def handle_call({:ensure, id, attrs}, _from, state) do
    case :ets.lookup(state.table, id) do
      [{^id, existing}] ->
        # PostgreSQL remains authoritative even if a DB reset or a lifecycle
        # change happened after this ETS entry was created.
        case register_durable(
               id: existing.id,
               name: existing.name,
               status: existing.status,
               config: existing.config
             ) do
          {:ok, tenant} ->
            :ok = reconcile_runtime(tenant)
            :ets.insert(state.table, {id, tenant})
            {:reply, {:ok, tenant}, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      [] ->
        attrs = Keyword.merge([id: id, name: id], attrs)

        case register_durable(attrs) do
          {:ok, tenant} ->
            :ok = reconcile_runtime(tenant)
            :ets.insert(state.table, {tenant.id, tenant})
            JidoClaw.Telemetry.emit_tenant_create(%{tenant_id: tenant.id})
            Logger.info("[Tenant] Ensured tenant #{tenant.id} (#{tenant.status})")
            {:reply, {:ok, tenant}, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:create, attrs}, _from, state) do
    attrs = Keyword.put_new_lazy(attrs, :id, &JidoClaw.Tenant.generate_id/0)

    case register_durable(attrs) do
      {:ok, tenant} ->
        :ok = reconcile_runtime(tenant)
        :ets.insert(state.table, {tenant.id, tenant})
        JidoClaw.Telemetry.emit_tenant_create(%{tenant_id: tenant.id})
        Logger.info("[Tenant] Created tenant #{tenant.id} (#{tenant.name})")
        {:reply, {:ok, tenant}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:get, id}, _from, state) do
    case :ets.lookup(state.table, id) do
      [{^id, tenant}] -> {:reply, {:ok, tenant}, state}
      [] -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:list, _from, state) do
    tenants = Enum.map(:ets.tab2list(state.table), fn {_id, t} -> t end)
    {:reply, tenants, state}
  end

  def handle_call({:sync_from_resource, id, status}, _from, state) do
    cached? = match?([{^id, _}], :ets.lookup(state.table, id))

    case :ets.lookup(state.table, id) do
      [{^id, tenant}] -> :ets.insert(state.table, {id, %{tenant | status: status}})
      [] -> :ok
    end

    sync_runtime_supervisor(id, status, cached?)
    {:reply, :ok, state}
  end

  def handle_call({:destroy, id}, _from, state) do
    case :ets.lookup(state.table, id) do
      [{^id, _tenant}] ->
        InstanceSupervisor.stop_instance(id)
        :ets.delete(state.table, id)
        JidoClaw.Telemetry.emit_tenant_destroy(%{tenant_id: id})
        Logger.info("[Tenant] Destroyed tenant #{id}")
        {:reply, :ok, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:count, _from, state) do
    {:reply, :ets.info(state.table, :size), state}
  end

  defp register_durable(attrs) when is_list(attrs) do
    attrs = Map.new(attrs)

    case TenantRow.register(%{
           id: Map.fetch!(attrs, :id),
           name: Map.get(attrs, :name, Map.fetch!(attrs, :id)),
           status: Map.get(attrs, :status, :active),
           config: Map.get(attrs, :config, %{})
         }) do
      {:ok, row} -> {:ok, legacy_from_row(row)}
      {:error, _} = error -> error
    end
  rescue
    error -> {:error, error}
  catch
    # DBConnection failures can arrive as exits, not raises (e.g.
    # Holder.checkout exiting `{:shutdown, "owner exited"}` when an Ecto
    # sandbox owner dies mid-checkout). The never-crash contract covers
    # those the same way: the write failed, the manager survives.
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp legacy_from_row(row) do
    %JidoClaw.Tenant{
      id: row.id,
      name: row.name,
      status: row.status,
      config: row.config,
      created_at: row.inserted_at
    }
  end

  defp reconcile_runtime(%{id: id, status: :active}) do
    start_runtime(id, "start")
  end

  defp reconcile_runtime(%{id: id, status: status}) when status in [:suspended, :terminating] do
    InstanceSupervisor.stop_instance(id)
  end

  defp start_runtime(id, operation) do
    case InstanceSupervisor.start_instance(id) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        :ok

      {:error, reason} ->
        Logger.warning("[Tenant] Failed to #{operation} runtime #{id}: #{inspect(reason)}")
        :ok
    end
  end

  defp sync_runtime_supervisor(id, status, _cached?) when status in [:suspended, :terminating] do
    InstanceSupervisor.stop_instance(id)
  end

  defp sync_runtime_supervisor(id, :active, true) do
    start_runtime(id, "resume")
  end

  defp sync_runtime_supervisor(_id, :active, false), do: :ok
end
