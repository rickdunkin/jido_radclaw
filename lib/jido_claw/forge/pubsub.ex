defmodule JidoClaw.Forge.PubSub do
  @moduledoc false
  alias JidoClaw.Security.Redaction.ChannelRedaction
  alias JidoClaw.Security.Redaction.Patterns

  @sessions_topic "forge:sessions"

  @spec sessions_topic() :: String.t()
  def sessions_topic, do: @sessions_topic

  @spec session_topic(String.t()) :: String.t()
  def session_topic(session_id), do: "forge:session:#{session_id}"

  @spec subscribe_sessions() :: :ok | {:error, term()}
  def subscribe_sessions do
    Phoenix.PubSub.subscribe(JidoClaw.PubSub, @sessions_topic)
  end

  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(session_id) do
    Phoenix.PubSub.subscribe(JidoClaw.PubSub, session_topic(session_id))
  end

  # AR-8b-2 F2 (1.1): the mirror of `subscribe/1`. A short-lived subscriber
  # (e.g. `run_server`'s `async_nolink` task) has its subscription auto-evicted
  # on death, but a LONG-LIVED caller (the front door driving
  # `Forge.start_session_ready/3`) must drop the `forge:session:<id>` topic
  # explicitly or it accumulates every later session broadcast in its mailbox.
  @spec unsubscribe(String.t()) :: :ok
  def unsubscribe(session_id) do
    Phoenix.PubSub.unsubscribe(JidoClaw.PubSub, session_topic(session_id))
  end

  @spec broadcast_session_event(term()) :: :ok | {:error, term()}
  def broadcast_session_event(event) do
    safe_broadcast(@sessions_topic, event)
  end

  @spec broadcast(String.t(), term()) :: :ok | {:error, term()}
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
