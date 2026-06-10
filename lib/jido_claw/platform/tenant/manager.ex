defmodule JidoClaw.Tenant.Manager do
  @moduledoc "Manages tenant lifecycle: create, suspend, destroy, list."
  # Tenant Manager GenServer: best-effort Postgres row sync must never
  # crash the cluster-wide manager — a transient DB raise becomes a log.
  # reach:disable-for-this-file bare_rescue
  use GenServer
  require Logger

  alias JidoClaw.Tenant.InstanceSupervisor

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

  @spec suspend_tenant(String.t()) :: {:ok, JidoClaw.Tenant.t()} | {:error, :not_found}
  def suspend_tenant(id) do
    GenServer.call(__MODULE__, {:update_status, id, :suspended})
  end

  @spec resume_tenant(String.t()) :: {:ok, JidoClaw.Tenant.t()} | {:error, :not_found}
  def resume_tenant(id) do
    GenServer.call(__MODULE__, {:update_status, id, :active})
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
        tenant = JidoClaw.Tenant.new(id: "default", name: "Default")
        ensure_postgres_row(tenant)

        case InstanceSupervisor.start_instance(tenant.id) do
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

  @impl GenServer
  def handle_call({:ensure, id, attrs}, _from, state) do
    case :ets.lookup(state.table, id) do
      [{^id, existing}] ->
        # Best-effort sync the Postgres row in case the cache survived
        # a DB reset.
        ensure_postgres_row(existing)
        {:reply, {:ok, existing}, state}

      [] ->
        attrs = Keyword.merge([id: id, name: id], attrs)
        tenant = JidoClaw.Tenant.new(attrs)
        ensure_postgres_row(tenant)

        case InstanceSupervisor.start_instance(tenant.id) do
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
    ensure_postgres_row(tenant)

    case InstanceSupervisor.start_instance(tenant.id) do
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
    tenants = Enum.map(:ets.tab2list(state.table), fn {_id, t} -> t end)
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

  defp ensure_postgres_row(%{id: id} = _tenant) when is_binary(id) do
    case JidoClaw.Tenants.Tenant.ensure(id) do
      {:ok, _row} -> :ok
      {:error, reason} -> Logger.warning("[Tenant] Postgres row sync failed: #{inspect(reason)}")
    end
  rescue
    e ->
      Logger.warning("[Tenant] Postgres row sync raised: #{Exception.message(e)}")
  end

  defp ensure_postgres_row(_), do: :ok
end
