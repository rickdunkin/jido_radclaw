defmodule JidoClaw.Orchestration.RunPubSub do
  @moduledoc false
  @spec run_topic(term()) :: String.t()
  def run_topic(run_id), do: "orchestration:run:#{run_id}"

  @spec runs_topic() :: String.t()
  def runs_topic, do: "orchestration:runs"

  @spec gates_topic() :: String.t()
  def gates_topic, do: "orchestration:gates"

  @spec subscribe(term()) :: :ok | {:error, term()}
  def subscribe(run_id) do
    Phoenix.PubSub.subscribe(JidoClaw.PubSub, run_topic(run_id))
  end

  @spec subscribe_all() :: :ok | {:error, term()}
  def subscribe_all do
    Phoenix.PubSub.subscribe(JidoClaw.PubSub, runs_topic())
  end

  @spec broadcast(term(), term()) :: :ok | {:error, term()}
  def broadcast(run_id, event) do
    Phoenix.PubSub.broadcast(JidoClaw.PubSub, run_topic(run_id), event)
    Phoenix.PubSub.broadcast(JidoClaw.PubSub, runs_topic(), event)
  end

  @doc """
  The human-gate inbox channel. `{:gate_requested, run_id, info}` is broadcast
  by `ReactorRunner` **after** a run's resume checkpoint persists (so the gate
  is never announced before it can be acted on); `{:gate_resolved, run_id,
  info}` by `Cases.decide/4` after a decision commits.
  """
  @spec subscribe_gates() :: :ok | {:error, term()}
  def subscribe_gates do
    Phoenix.PubSub.subscribe(JidoClaw.PubSub, gates_topic())
  end

  @spec broadcast_gate(term()) :: :ok | {:error, term()}
  def broadcast_gate(event) do
    Phoenix.PubSub.broadcast(JidoClaw.PubSub, gates_topic(), event)
  end
end
