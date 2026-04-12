defmodule JidoClaw.Orchestration.RunSummaryFeed do
  use GenServer
  require Logger

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def get_summary do
    GenServer.call(__MODULE__, :get_summary)
  end

  @impl true
  def init(_opts) do
    JidoClaw.Orchestration.RunPubSub.subscribe_all()
    {:ok, %{active_runs: %{}, recent_completions: []}}
  end

  @impl true
  def handle_call(:get_summary, _from, state) do
    summary = %{
      active_count: map_size(state.active_runs),
      active_runs: Map.values(state.active_runs),
      recent_completions: Enum.take(state.recent_completions, 10)
    }

    {:reply, summary, state}
  end

  @impl true
  def handle_info({:run_started, run_id, info}, state) do
    new_state =
      put_in(state, [:active_runs, run_id], Map.merge(info, %{started_at: DateTime.utc_now()}))

    {:noreply, new_state}
  end

  @impl true
  def handle_info({:run_completed, run_id, info}, state) do
    completed = Map.merge(Map.get(state.active_runs, run_id, %{}), info)

    new_state = %{
      state
      | active_runs: Map.delete(state.active_runs, run_id),
        recent_completions: [completed | Enum.take(state.recent_completions, 49)]
    }

    {:noreply, new_state}
  end

  @impl true
  def handle_info({:run_failed, run_id, info}, state) do
    completed =
      Map.merge(Map.get(state.active_runs, run_id, %{}), Map.put(info, :status, :failed))

    new_state = %{
      state
      | active_runs: Map.delete(state.active_runs, run_id),
        recent_completions: [completed | Enum.take(state.recent_completions, 49)]
    }

    {:noreply, new_state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}
end
