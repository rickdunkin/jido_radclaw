defmodule JidoClaw.Conversations.RequestCorrelation.Cache do
  @moduledoc """
  GenServer-owned ETS table mirroring active `RequestCorrelation` rows.

  The Recorder hits this on every `ai.tool.started` / `ai.tool.result`
  / `ai.llm.response` signal to resolve the dispatching scope from the
  signal's `request_id`. ETS lookups stay constant-time even at high
  signal volume.

  ## Pattern

  Mirrors `JidoClaw.Tenant.Manager`: this GenServer is the owner of the
  `:jido_claw_request_correlations` table; the Recorder calls into the
  GenServer for `put`/`lookup`/`delete`/`clear` via `GenServer.call`,
  and the GenServer translates each call into the appropriate
  `:ets.{insert,lookup,delete,delete_all_objects}` operation.

  If the GenServer crashes the supervisor restarts it and the table is
  re-created. The Recorder's lookup path falls back to a Postgres read
  on a cache miss, so a brief restart drop is invisible to callers.

  ## Stored shape

      :ets.insert(table, {request_id, %{
        session_id: <uuid>,
        tenant_id: <string>,
        workspace_id: <uuid> | nil,
        user_id: <uuid> | nil
      }})
  """

  use GenServer
  require Logger

  @table :jido_claw_request_correlations

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec put(String.t(), map()) :: :ok
  def put(request_id, scope) when is_binary(request_id) and is_map(scope) do
    GenServer.call(__MODULE__, {:put, request_id, scope})
  end

  @spec lookup(String.t()) :: {:ok, map()} | :error
  def lookup(request_id) when is_binary(request_id) do
    case :ets.lookup(@table, request_id) do
      [{^request_id, scope}] -> {:ok, scope}
      [] -> :error
    end
  rescue
    ArgumentError -> :error
  end

  @spec delete(String.t()) :: :ok
  def delete(request_id) when is_binary(request_id) do
    GenServer.call(__MODULE__, {:delete, request_id})
  end

  @spec clear() :: :ok
  def clear do
    GenServer.call(__MODULE__, :clear)
  end

  # ---------------------------------------------------------------------------
  # Server
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    table =
      :ets.new(@table, [
        :set,
        :named_table,
        :public,
        read_concurrency: true,
        write_concurrency: true
      ])

    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:put, request_id, scope}, _from, state) do
    :ets.insert(state.table, {request_id, scope})
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:delete, request_id}, _from, state) do
    :ets.delete(state.table, request_id)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(state.table)
    {:reply, :ok, state}
  end
end
