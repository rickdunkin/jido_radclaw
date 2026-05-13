defmodule JidoClaw.Forge.PubSub do
  @moduledoc false
  alias JidoClaw.Security.Redaction.ChannelRedaction
  alias JidoClaw.Security.Redaction.Patterns
  require Logger

  @sessions_topic "forge:sessions"

  def sessions_topic, do: @sessions_topic
  def session_topic(session_id), do: "forge:session:#{session_id}"

  def subscribe_sessions do
    Phoenix.PubSub.subscribe(JidoClaw.PubSub, @sessions_topic)
  end

  def subscribe(session_id) do
    Phoenix.PubSub.subscribe(JidoClaw.PubSub, session_topic(session_id))
  end

  def broadcast_session_event(event) do
    safe_broadcast(@sessions_topic, event)
  end

  def broadcast(session_id, event) do
    safe_broadcast(session_topic(session_id), event)
  end

  defp safe_broadcast(topic, event) do
    redacted = redact_event(event)
    Phoenix.PubSub.broadcast(JidoClaw.PubSub, topic, redacted)
  end

  defp redact_event(event) when is_tuple(event) do
    event
    |> Tuple.to_list()
    |> Enum.map(fn
      val when is_map(val) -> ChannelRedaction.redact_payload(val)
      val when is_binary(val) -> Patterns.redact(val)
      val -> val
    end)
    |> List.to_tuple()
  end

  defp redact_event(event), do: event
end
