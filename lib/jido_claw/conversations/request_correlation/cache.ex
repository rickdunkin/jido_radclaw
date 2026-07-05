defmodule JidoClaw.Conversations.RequestCorrelation.Cache do
  @moduledoc """
  GenServer-owned ETS table mirroring active `RequestCorrelation` rows.

  The Recorder hits this on every `ai.tool.started` / `ai.tool.result`
  / `ai.llm.response` signal to resolve the dispatching scope from the
  signal's `request_id`. ETS lookups stay constant-time even at high
  signal volume.

  ## Pattern

  Mirrors `JidoClaw.Tenant.Manager`: this GenServer is the owner of the
  `:jido_claw_request_correlations` table; writes (`put`/`delete`/`clear`)
  go through `GenServer.call`, while `lookup/1` reads the ETS table
  directly client-side (no GenServer round-trip on the hot read path).

  If the GenServer crashes the supervisor restarts it and the table is
  re-created. The Recorder's lookup path falls back to a Postgres read
  on a cache miss, so a brief restart drop is invisible to callers.

  ## Stored shape

      :ets.insert(table, {request_id, %{
        session_id: <uuid>,
        tenant_id: <string>,
        workspace_id: <uuid> | nil,
        user_id: <uuid> | nil,
        # Durable compaction identity + sub-agent flag, mirrored from the
        # RequestCorrelation row so the Recorder can stamp messages.agent_id
        # / messages.subagent without a DB round-trip.
        agent_id: <string> | nil,
        subagent: <boolean>,
        # AR-2 Phase 2b: `true` for a composer subagent's marked turn, mirrored
        # from the row so the Recorder/Audit sink gates resolve it without a DB
        # round-trip.
        sanitize_sensitive_context: <boolean>,
        # Optional telemetry merged in by the Recorder when
        # `ai.llm.response` / `ai.request.completed` lands.
        run_id: <string> | nil,
        model: <string> | nil,
        input_tokens: <integer> | nil,
        output_tokens: <integer> | nil,
        latency_ms: <integer> | nil
      }})
  """

  use GenServer

  @table :jido_claw_request_correlations

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
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

  @impl GenServer
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

  @impl GenServer
  def handle_call({:put, request_id, scope}, _from, state) do
    :ets.insert(state.table, {request_id, scope})
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_call({:delete, request_id}, _from, state) do
    :ets.delete(state.table, request_id)
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(state.table)
    {:reply, :ok, state}
  end
end
