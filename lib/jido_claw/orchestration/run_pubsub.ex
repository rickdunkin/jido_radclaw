defmodule JidoClaw.Orchestration.RunPubSub do
  @moduledoc false
  def run_topic(run_id), do: "orchestration:run:#{run_id}"
  def runs_topic, do: "orchestration:runs"
  def gates_topic, do: "orchestration:gates"

  def subscribe(run_id) do
    Phoenix.PubSub.subscribe(JidoClaw.PubSub, run_topic(run_id))
  end

  def subscribe_all do
    Phoenix.PubSub.subscribe(JidoClaw.PubSub, runs_topic())
  end

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
  def subscribe_gates do
    Phoenix.PubSub.subscribe(JidoClaw.PubSub, gates_topic())
  end

  def broadcast_gate(event) do
    Phoenix.PubSub.broadcast(JidoClaw.PubSub, gates_topic(), event)
  end
end
