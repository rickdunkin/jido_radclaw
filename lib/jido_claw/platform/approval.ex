defmodule JidoClaw.Platform.Approval do
  @moduledoc """
  Configurable tool approval workflow.
  Modes: :off (no approval), :on_miss (check allowlist), :always (always require).
  """
  use GenServer
  require Logger

  @approval_timeout 120_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Check if a tool call is approved."
  @spec check(String.t(), String.t(), map()) :: :approved | :denied | {:pending, reference()}
  def check(session_id, tool_name, _args) do
    mode = Application.get_env(:jido_claw, :tool_approval_mode, :off)

    case mode do
      :off ->
        :approved

      :always ->
        request_approval(session_id, tool_name)

      :on_miss ->
        if allowed?(session_id, tool_name) do
          :approved
        else
          request_approval(session_id, tool_name)
        end
    end
  end

  @doc "Register a tool as pre-approved for a session."
  def allow(session_id, tool_name) do
    GenServer.cast(__MODULE__, {:allow, session_id, tool_name})
  end

  @doc "Respond to a pending approval request."
  def respond(request_id, decision) when decision in [:approved, :denied] do
    GenServer.call(__MODULE__, {:respond, request_id, decision})
  end

  @doc "List all pending approval requests."
  def pending do
    GenServer.call(__MODULE__, :pending)
  end

  # -- Server --

  @impl true
  def init(_opts) do
    table = :ets.new(:jido_claw_tool_approvals, [:set, :private])
    {:ok, %{table: table, pending: %{}}}
  end

  @impl true
  def handle_cast({:allow, session_id, tool_name}, state) do
    :ets.insert(state.table, {{session_id, tool_name}, true})
    {:noreply, state}
  end

  @impl true
  def handle_call({:respond, request_id, decision}, _from, state) do
    case Map.pop(state.pending, request_id) do
      {nil, _} ->
        {:reply, {:error, :not_found}, state}

      {%{from: from, timer: timer}, new_pending} ->
        Process.cancel_timer(timer)
        GenServer.reply(from, decision)
        {:reply, :ok, %{state | pending: new_pending}}
    end
  end

  def handle_call(:pending, _from, state) do
    pending =
      state.pending
      |> Enum.map(fn {id, %{session_id: sid, tool_name: tool}} ->
        %{id: id, session_id: sid, tool_name: tool}
      end)

    {:reply, pending, state}
  end

  def handle_call({:request, session_id, tool_name}, from, state) do
    request_id = :erlang.unique_integer([:positive])
    timer = Process.send_after(self(), {:timeout, request_id}, @approval_timeout)

    pending =
      Map.put(state.pending, request_id, %{
        session_id: session_id,
        tool_name: tool_name,
        from: from,
        timer: timer,
        requested_at: System.system_time(:second)
      })

    Logger.info("[Approval] Pending: #{tool_name} for session #{session_id} (id: #{request_id})")

    Phoenix.PubSub.broadcast(
      JidoClaw.PubSub,
      "approvals",
      {:approval_requested, request_id, session_id, tool_name}
    )

    {:noreply, %{state | pending: pending}}
  end

  @impl true
  def handle_info({:timeout, request_id}, state) do
    case Map.pop(state.pending, request_id) do
      {nil, _} ->
        {:noreply, state}

      {%{from: from}, new_pending} ->
        GenServer.reply(from, :denied)
        Logger.warning("[Approval] Request #{request_id} timed out, auto-denied")
        {:noreply, %{state | pending: new_pending}}
    end
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.pending, fn {_id, %{from: from, timer: timer}} ->
      Process.cancel_timer(timer)
      GenServer.reply(from, {:error, :shutting_down})
    end)

    :ok
  end

  # -- Private --

  defp allowed?(session_id, tool_name) do
    case :ets.lookup(:jido_claw_tool_approvals, {session_id, tool_name}) do
      [{_, true}] -> true
      _ -> false
    end
  catch
    :error, :badarg -> false
  end

  defp request_approval(session_id, tool_name) do
    GenServer.call(__MODULE__, {:request, session_id, tool_name}, @approval_timeout + 5_000)
  end
end
