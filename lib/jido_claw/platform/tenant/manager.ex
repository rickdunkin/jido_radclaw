defmodule JidoClaw.Tenant.Manager do
  @moduledoc "Manages tenant lifecycle: create, suspend, destroy, list."
  use GenServer
  require Logger

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # Client API

  def create_tenant(attrs \\ []) do
    GenServer.call(__MODULE__, {:create, attrs})
  end

  def get_tenant(id) do
    GenServer.call(__MODULE__, {:get, id})
  end

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

  def suspend_tenant(id) do
    GenServer.call(__MODULE__, {:update_status, id, :suspended})
  end

  def resume_tenant(id) do
    GenServer.call(__MODULE__, {:update_status, id, :active})
  end

  def destroy_tenant(id) do
    GenServer.call(__MODULE__, {:destroy, id})
  end

  def count do
    GenServer.call(__MODULE__, :count)
  end

  # Server

  @impl true
  def init(_opts) do
    tenants = :ets.new(:jido_claw_tenants, [:set, :named_table, :public, read_concurrency: true])
    # Schedule default tenant creation after init completes (no race condition)
    send(self(), :create_default_tenant)
    {:ok, %{table: tenants}}
  end

  @impl true
  def handle_info(:create_default_tenant, state) do
    case :ets.lookup(state.table, "default") do
      [] ->
        tenant = JidoClaw.Tenant.new(id: "default", name: "Default")

        case JidoClaw.Tenant.InstanceSupervisor.start_instance(tenant.id) do
          {:ok, _pid} ->
            :ets.insert(state.table, {tenant.id, tenant})
            JidoClaw.Telemetry.emit_tenant_create(%{tenant_id: tenant.id})
            Logger.info("[Tenant] Default tenant created")

          {:error, reason} ->
            Logger.warning("[Tenant] Failed to create default tenant: #{inspect(reason)}")
        end

      _ ->
        :ok
    end

    {:noreply, state}
  end

  @impl true
  def handle_call({:ensure, id, attrs}, _from, state) do
    case :ets.lookup(state.table, id) do
      [{^id, existing}] ->
        {:reply, {:ok, existing}, state}

      [] ->
        attrs = Keyword.merge([id: id, name: id], attrs)
        tenant = JidoClaw.Tenant.new(attrs)

        case JidoClaw.Tenant.InstanceSupervisor.start_instance(tenant.id) do
          {:ok, _pid} ->
            :ets.insert(state.table, {tenant.id, tenant})
            JidoClaw.Telemetry.emit_tenant_create(%{tenant_id: tenant.id})
            Logger.info("[Tenant] Ensured tenant #{tenant.id}")
            {:reply, {:ok, tenant}, state}

          {:error, {:already_started, _}} ->
            :ets.insert(state.table, {tenant.id, tenant})
            {:reply, {:ok, tenant}, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:create, attrs}, _from, state) do
    tenant = JidoClaw.Tenant.new(attrs)

    case JidoClaw.Tenant.InstanceSupervisor.start_instance(tenant.id) do
      {:ok, _pid} ->
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
    tenants = :ets.tab2list(state.table) |> Enum.map(fn {_id, t} -> t end)
    {:reply, tenants, state}
  end

  def handle_call({:update_status, id, new_status}, _from, state) do
    case :ets.lookup(state.table, id) do
      [{^id, tenant}] ->
        updated = %{tenant | status: new_status}
        :ets.insert(state.table, {id, updated})
        {:reply, {:ok, updated}, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:destroy, id}, _from, state) do
    case :ets.lookup(state.table, id) do
      [{^id, _tenant}] ->
        JidoClaw.Tenant.InstanceSupervisor.stop_instance(id)
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
end
