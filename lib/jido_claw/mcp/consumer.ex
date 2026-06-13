defmodule JidoClaw.MCP.Consumer do
  # Defensive-by-design: prep crashes and per-agent registration faults are
  # rescued/caught so a dead or slow agent never aborts a batch or the prep.
  # reach:disable-for-this-file bare_rescue
  @moduledoc """
  Boot-time prep + attach coordinator for external MCP tool consumption.

  ## Prep (off-process, crash-isolated)

  `init/1` returns immediately and `spawn_monitor`s a **separate** prep process
  so the GenServer mailbox stays free. Prep (best-effort, internally rescued —
  it always sends `{:prepared, …}` unless hard-killed): read config → register
  endpoints → await ready → discover tools → compile safe proxy modules. The
  Consumer then publishes the per-server approval policy to `:persistent_term`,
  caches the module list, and flips to `:ready`.

  ## Attach (two non-blocking paths)

    * `attach_to_agent/2` (via the facade) records the pid, replies instantly,
      and registers in a **fire-and-forget supervised task** — used at REPL boot
      and the `:prepared`/restart rehydrate fan-out. The Consumer never
      `Task.yield`s in a callback.
    * `ensure_attached/2` (via the facade) answers `:modules_when_ready`
      immediately when `:ready` (or `:already` for a confirmed pid), else
      **defers** the reply until `{:prepared}` — the *caller* waits, registers,
      and confirms; the Consumer stays free.

  Per-module registration is independent (`has_tool?`/`register_tool` wrapped in
  `try/catch :exit` + rescue), so one dead/slow agent call warn-logs and
  continues instead of silently partial-registering. A batch is `:ok` only when
  **all** expected modules are confirmed present, else `:partial` (left unmarked
  so the next turn retries).
  """

  use GenServer

  require Logger

  alias JidoClaw.MCP.EndpointConfig
  alias JidoClaw.MCP.ProxyGenerator

  @register_timeout 5_000

  # -- Child gating (pure, so the serve-mode/test gate is testable) --

  @doc """
  Whether the Consumer should be supervised, given the runtime flags.

  Absent in MCP serve mode (stdio is reserved for JSON-RPC) and when explicitly
  disabled (the test gate). Present otherwise (`:cli`/`:gateway`/`:both`).
  """
  @spec start?(atom() | nil, boolean()) :: boolean()
  def start?(serve_mode, consumer_enabled?) do
    serve_mode != :mcp and consumer_enabled? != false
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  # -- GenServer --

  @impl GenServer
  def init(opts) do
    parent = self()
    servers = Keyword.get(opts, :servers)
    {pid, ref} = spawn_monitor(fn -> run_prep(parent, servers) end)

    {:ok,
     %{
       status: :preparing,
       # Per-incarnation token (a fresh `make_ref/0`). Registration tasks carry
       # the generation that spawned them; a mark is honored only when the token
       # still matches, fencing out marks from a crashed prior incarnation.
       generation: make_ref(),
       modules: [],
       pending: %{},
       waiters: [],
       attached: MapSet.new(),
       monitors: %{},
       prep_ref: ref,
       prep_pid: pid
     }}
  end

  @impl GenServer
  def handle_call({:attach, pid, template}, _from, state) do
    state = ensure_monitored(state, pid)

    case state.status do
      :ready ->
        start_register_task(pid, state.modules, state.generation)
        {:reply, :ok, state}

      :preparing ->
        {:reply, :ok, %{state | pending: Map.put(state.pending, pid, template)}}

      :failed ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:modules_when_ready, pid}, from, state) do
    cond do
      # `:failed` first (defense-in-depth): a crashed Consumer reports
      # unavailable even if a stale `attached` entry ever slipped in.
      state.status == :failed ->
        {:reply, {:error, :mcp_unavailable}, state}

      MapSet.member?(state.attached, pid) ->
        {:reply, :already, state}

      state.status == :ready ->
        {:reply, {:ok, state.modules, state.generation}, ensure_monitored(state, pid)}

      true ->
        {:noreply, %{state | waiters: [{from, pid} | state.waiters]}}
    end
  end

  @impl GenServer
  # Honor the mark only while `:ready` AND only when the task's generation token
  # still matches this incarnation's (pin-by-repetition: the message `generation`
  # must equal the state's). A fire-and-forget registration task (under
  # `JidoClaw.TaskSupervisor`, which survives a Consumer crash) can finish and
  # cast `{:mark_attached, …}` *by registered name* into a **restarted**
  # Consumer: if that replacement is `:preparing`/`:failed` the status guard
  # drops it; if it already reached `:ready` with a *different* module set, the
  # generation mismatch drops it — pid stays unmarked and a later
  # `ensure_attached/2` idempotently re-registers + re-marks (self-healing).
  # Within one incarnation the token always matches, so nothing legitimate is
  # dropped.
  def handle_cast(
        {:mark_attached, pid, generation},
        %{status: :ready, generation: generation} = state
      ) do
    {:noreply, %{state | attached: MapSet.put(state.attached, pid)}}
  end

  def handle_cast({:mark_attached, _pid, _generation}, state) do
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:prepared, modules, policy}, state) do
    :persistent_term.put(JidoClaw.MCP.policy_key(), policy)

    replied =
      Enum.reduce(state.waiters, state, fn {from, pid}, acc ->
        GenServer.reply(from, {:ok, modules, state.generation})
        ensure_monitored(acc, pid)
      end)

    ready = %{
      replied
      | status: :ready,
        modules: modules,
        waiters: [],
        prep_ref: nil,
        prep_pid: nil
    }

    fanned =
      ready
      |> fan_out_to_pending(modules)
      |> fan_out_to_tracked(modules)

    {:noreply, fanned}
  end

  # A hard, untrappable prep kill is the only way prep dies without sending
  # `{:prepared}` (graceful failures are rescued into `{:prepared, [], %{}}`).
  # Transition to `:failed` — NOT `:ready` with empty modules, which is
  # indistinguishable from a successful zero-tool prep and would falsely
  # mark later callers attached and tool-less forever. Reply `:mcp_unavailable`
  # to current waiters, republish an empty (fail-closed: gated) policy so a
  # restart can't retain stale trust decisions, and go fully inert. Honest
  # semantics: tool-less until a Consumer/app restart re-preps; auto re-prep is
  # the deferred reconnect/re-discovery follow-up.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{prep_ref: ref} = state) do
    Logger.warning(
      "[MCP] prep process died before completing (#{inspect(reason)}); tool-less until restart"
    )

    :persistent_term.put(JidoClaw.MCP.policy_key(), %{})

    Enum.each(state.waiters, fn {from, _pid} ->
      GenServer.reply(from, {:error, :mcp_unavailable})
    end)

    {:noreply,
     %{
       state
       | status: :failed,
         modules: [],
         pending: %{},
         waiters: [],
         prep_ref: nil,
         prep_pid: nil
     }}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply,
     %{
       state
       | pending: Map.delete(state.pending, pid),
         attached: MapSet.delete(state.attached, pid),
         monitors: Map.delete(state.monitors, pid)
     }}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- Registration (public: shared by ensure_attached and the fan-out tasks) --

  @doc """
  Register every module in `modules` onto `pid`, independently and bounded.

  Returns `:ok` only when **all** expected modules are confirmed present
  (`has_tool?`), else `:partial`. Idempotent: already-present tools are skipped.
  """
  @spec register_modules(pid(), [module()], timeout()) :: :ok | :partial
  def register_modules(pid, modules, timeout \\ @register_timeout) do
    Enum.each(modules, &register_one(pid, &1, timeout))
    if all_registered?(pid, modules), do: :ok, else: :partial
  end

  defp register_and_mark(pid, modules, generation) do
    case register_modules(pid, modules) do
      :ok -> GenServer.cast(__MODULE__, {:mark_attached, pid, generation})
      :partial -> :ok
    end
  end

  defp register_one(pid, module, timeout) do
    case has_tool_safe(pid, module.name()) do
      {:ok, true} -> :ok
      _absent_or_error -> safe_register(pid, module, timeout)
    end
  end

  defp safe_register(pid, module, timeout) do
    case Jido.AI.register_tool(pid, module, timeout: timeout) do
      {:ok, _agent} -> :ok
      {:error, reason} -> warn_register(module, reason)
    end
  rescue
    exception -> warn_register(module, exception)
  catch
    :exit, reason -> warn_register(module, reason)
  end

  defp warn_register(module, reason) do
    Logger.warning("[MCP] failed to register #{inspect(module)}: #{inspect(reason)}")
    :error
  end

  defp all_registered?(pid, modules) do
    Enum.all?(modules, fn module -> match?({:ok, true}, has_tool_safe(pid, module.name())) end)
  end

  defp has_tool_safe(pid, name) do
    Jido.AI.has_tool?(pid, name)
  rescue
    _exception -> {:error, :rescue}
  catch
    :exit, _reason -> {:error, :exit}
  end

  # -- Fan-out --

  defp fan_out_to_pending(state, modules) do
    Enum.each(state.pending, fn {pid, _template} ->
      start_register_task(pid, modules, state.generation)
    end)

    %{state | pending: %{}}
  end

  defp fan_out_to_tracked(state, modules) do
    tracked_live_pids()
    |> Enum.reject(&MapSet.member?(state.attached, &1))
    |> Enum.reduce(state, fn pid, acc ->
      start_register_task(pid, modules, state.generation)
      ensure_monitored(acc, pid)
    end)
  end

  # AgentTracker retains terminal entries (it does not drop `:done`/`:error`),
  # so filter to live `:running` pids — and tolerate the tracker not being up
  # yet (the Consumer starts right after it, but a restart can race).
  defp tracked_live_pids do
    case Process.whereis(JidoClaw.AgentTracker) do
      nil ->
        []

      _tracker ->
        agents = Map.get(JidoClaw.AgentTracker.get_state(), :agents, %{})

        for {_id, entry} <- agents,
            entry.status == :running and is_pid(entry.pid) and Process.alive?(entry.pid),
            do: entry.pid
    end
  rescue
    _exception -> []
  catch
    :exit, _reason -> []
  end

  defp start_register_task(pid, modules, generation) do
    Task.Supervisor.start_child(JidoClaw.TaskSupervisor, fn ->
      register_and_mark(pid, modules, generation)
    end)
  end

  defp ensure_monitored(state, pid) do
    if Map.has_key?(state.monitors, pid) do
      state
    else
      ref = Process.monitor(pid)
      %{state | monitors: Map.put(state.monitors, pid, ref)}
    end
  end

  # -- Prep (off-process) --

  defp run_prep(parent, servers) do
    {modules, policy} = prepare(servers)
    send(parent, {:prepared, modules, policy})
  rescue
    exception ->
      Logger.warning("[MCP] prep failed: #{inspect(exception)}")
      send(parent, {:prepared, [], %{}})
  catch
    kind, reason ->
      Logger.warning("[MCP] prep crashed: #{inspect({kind, reason})}")
      send(parent, {:prepared, [], %{}})
  end

  defp prepare(servers) do
    {specs, warnings} = EndpointConfig.parse(servers || configured_servers())
    Enum.each(warnings, fn warning -> Logger.warning("[MCP] #{warning}") end)

    results =
      specs
      |> Task.async_stream(&prepare_server/1,
        max_concurrency: max(length(specs), 1),
        timeout: server_prep_timeout(),
        on_timeout: :kill_task
      )
      |> Enum.map(fn
        {:ok, result} -> result
        {:exit, _reason} -> {[], %{}}
      end)

    modules = Enum.flat_map(results, fn {mods, _policy} -> mods end)
    policy = Enum.reduce(results, %{}, fn {_mods, pol}, acc -> Map.merge(acc, pol) end)
    {modules, policy}
  end

  defp prepare_server(spec) do
    client = JidoClaw.MCP.client()

    with :ok <- client.register_endpoint(spec.endpoint),
         :ok <- client.await_endpoint_ready(spec.endpoint.id, ready_timeout()),
         {:ok, tools} <- client.list_tools(spec.endpoint.id, list_tools_timeout()) do
      modules = ProxyGenerator.build_modules(spec.name, spec.endpoint.id, tools)
      policy = Map.new(modules, fn module -> {module.name(), spec.require_approval} end)
      {modules, policy}
    else
      error ->
        Logger.warning("[MCP] server #{spec.name}: discovery failed: #{inspect(error)}")
        {[], %{}}
    end
  end

  defp configured_servers do
    case Application.get_env(:jido_claw, :mcp_servers) do
      list when is_list(list) -> list
      _other -> JidoClaw.Config.mcp_servers(JidoClaw.Config.load())
    end
  end

  defp ready_timeout, do: mcp_opt(:ready_timeout_ms, 10_000)
  defp list_tools_timeout, do: mcp_opt(:list_tools_timeout_ms, 10_000)
  defp server_prep_timeout, do: mcp_opt(:server_prep_timeout_ms, 30_000)

  defp mcp_opt(key, default) do
    Keyword.get(Application.get_env(:jido_claw, :mcp, []), key, default)
  end
end
