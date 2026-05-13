defmodule JidoClaw.Orchestration.RunPubSub do
  @moduledoc false
  def run_topic(run_id), do: "orchestration:run:#{run_id}"
  def runs_topic, do: "orchestration:runs"

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
end
