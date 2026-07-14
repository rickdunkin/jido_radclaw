defmodule JidoClaw.Agent.LoopGuard.Store do
  @moduledoc """
  Singleton in-memory store for `JidoClaw.Agent.LoopGuard` key state.

  Holds `%{key => %KeyState{}}` and applies the pure core functions
  atomically inside `handle_call` — synchronous calls for backpressure
  (two per tool call is trivial at LLM pace). **Per node**: no durable or
  cluster-wide state; see the LoopGuard moduledoc for the honest budget
  statement.

  The periodic sweep evicts halted keys `halt_ttl_ms` after the halt was
  stamped (sticky-halt decay — the key then starts fresh on its next call)
  and unhalted keys `idle_ttl_ms` after their last recorded activity.
  Sweep/TTL config resolves start-opts first, then `:loop_guard` app
  config, then the in-module defaults (the ToolApproval `opt_or_config`
  idiom).

  Client functions accept `opts[:server]` to target a non-default instance:
  fail-open tests aim the facade at a nonexistent name; sweep tests start
  their own instance with tiny TTLs.
  """

  use GenServer

  alias JidoClaw.Agent.LoopGuard
  alias JidoClaw.Agent.LoopGuard.KeyState

  @config_defaults [
    halt_ttl_ms: 300_000,
    idle_ttl_ms: 1_800_000,
    sweep_interval_ms: 60_000
  ]

  # ── Client ──────────────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Judge + record one attempted call for `key` pre-execution. A pure-core
  halt verdict is rendered here into the wire `{message, details}` pair.
  """
  @spec check_attempt(term(), {String.t(), term()}, keyword()) ::
          :ok | :warn | {:halt, String.t(), map()}
  def check_attempt(key, call_key, opts \\ []) do
    GenServer.call(server(opts), {:check_attempt, key, call_key, opts})
  end

  @doc "Judge + record one observed result for `key`."
  @spec check_result(term(), {String.t(), boolean(), LoopGuard.failure_sig() | nil}, keyword()) ::
          :ok | {:nudge, String.t()} | {:halt, String.t(), map()}
  def check_result(key, observation, opts \\ []) do
    GenServer.call(server(opts), {:check_result, key, observation, opts})
  end

  @doc "Drop all key state. Synchronous — tests depend on it."
  @spec reset(keyword()) :: :ok
  def reset(opts \\ []) do
    GenServer.call(server(opts), :reset)
  end

  defp server(opts), do: Keyword.get(opts, :server, __MODULE__)

  # ── Server ──────────────────────────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    {:ok, %{keys: %{}, opts: opts}, {:continue, :setup}}
  end

  @impl GenServer
  def handle_continue(:setup, state) do
    schedule_sweep(state.opts)
    {:noreply, state}
  end

  @impl GenServer
  def handle_call({:check_attempt, key, call_key, opts}, _from, state) do
    key_state = Map.get(state.keys, key, %KeyState{})
    {verdict, updated} = LoopGuard.check_attempt(key_state, call_key, opts)
    {:reply, render_verdict(verdict, updated, opts), put_key(state, key, updated)}
  end

  def handle_call({:check_result, key, observation, opts}, _from, state) do
    key_state = Map.get(state.keys, key, %KeyState{})
    {verdict, updated} = LoopGuard.check_result(key_state, observation, opts)
    {:reply, render_verdict(verdict, updated, opts), put_key(state, key, updated)}
  end

  def handle_call(:reset, _from, state) do
    {:reply, :ok, %{state | keys: %{}}}
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    state = sweep(state)
    schedule_sweep(state.opts)
    {:noreply, state}
  end

  # ── Internals ───────────────────────────────────────────────────────────

  defp put_key(state, key, key_state) do
    %{state | keys: Map.put(state.keys, key, key_state)}
  end

  # Render a pure-core halt into `{:halt, message, details}`; pass every
  # other verdict (`:ok`, `:warn`, `{:nudge, directive}`) through unchanged.
  defp render_verdict({:halt, reason}, key_state, opts) do
    {:halt, LoopGuard.halt_message(reason, key_state, opts),
     LoopGuard.halt_details(reason, key_state, opts)}
  end

  defp render_verdict(verdict, _key_state, _opts), do: verdict

  defp sweep(state) do
    now = System.monotonic_time(:millisecond)
    halt_ttl = opt_or_config(state.opts, :halt_ttl_ms)
    idle_ttl = opt_or_config(state.opts, :idle_ttl_ms)

    keys =
      state.keys
      |> Enum.reject(fn {_key, key_state} -> expired?(key_state, now, halt_ttl, idle_ttl) end)
      |> Map.new()

    %{state | keys: keys}
  end

  # Halted keys decay `halt_ttl_ms` after the halt was stamped (blocked
  # attempts refresh neither stamp); unhalted keys expire `idle_ttl_ms`
  # after their last recorded call. A key with neither stamp never expires —
  # unreachable in practice, since every recorded write stamps one of them.
  defp expired?(%KeyState{halted: halted, halted_at: at}, now, halt_ttl, _idle_ttl)
       when not is_nil(halted) and is_integer(at),
       do: now - at >= halt_ttl

  defp expired?(%KeyState{last_activity: at}, now, _halt_ttl, idle_ttl) when is_integer(at),
    do: now - at >= idle_ttl

  defp expired?(_key_state, _now, _halt_ttl, _idle_ttl), do: false

  defp schedule_sweep(opts) do
    Process.send_after(self(), :sweep, opt_or_config(opts, :sweep_interval_ms))
  end

  defp opt_or_config(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} ->
        value

      :error ->
        :jido_claw
        |> Application.get_env(:loop_guard, [])
        |> Keyword.get(key, @config_defaults[key])
    end
  end
end
