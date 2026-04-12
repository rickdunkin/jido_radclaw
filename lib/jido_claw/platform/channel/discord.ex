defmodule JidoClaw.Channel.Discord do
  @moduledoc """
  Discord channel adapter using Nostrum.
  Config: %{bot_token: "...", guild_id: "...", channel_ids: [...]}
  """
  @behaviour JidoClaw.Channel.Behaviour
  require Logger

  @impl true
  def init(config) do
    state = %{
      bot_token: Map.fetch!(config, :bot_token),
      guild_id: Map.get(config, :guild_id),
      channel_ids: Map.get(config, :channel_ids, []),
      connected: false
    }

    {:ok, state}
  end

  @impl true
  def connect(state) do
    # Nostrum connects via its own supervision tree.
    # This adapter relies on Nostrum.Consumer for events.
    Logger.info("[Discord] Adapter initialized, Nostrum manages connection")
    {:ok, %{state | connected: true}}
  end

  @impl true
  def handle_inbound(message, state) do
    normalized = %{
      text: message.content,
      author_id: to_string(message.author.id),
      channel_id: to_string(message.channel_id),
      platform: :discord,
      metadata: %{
        guild_id: to_string(message.guild_id),
        message_id: to_string(message.id),
        timestamp: message.timestamp
      }
    }

    # Route to agent session
    session_id = "discord_#{normalized.channel_id}"

    case JidoClaw.chat("default", session_id, normalized.text) do
      {:ok, response} ->
        send_message(normalized.channel_id, response, state)
        {:reply, response, state}

      {:error, _reason} ->
        {:noreply, state}
    end
  end

  @impl true
  def send_message(channel_id, content, _state) do
    # Nostrum API call
    case Code.ensure_loaded(Nostrum.Api.Message) do
      {:module, _} ->
        Nostrum.Api.Message.create(String.to_integer(channel_id), content: content)
        :ok

      {:error, _} ->
        Logger.warning("[Discord] Nostrum not loaded, cannot send message")
        {:error, :nostrum_not_loaded}
    end
  end

  @impl true
  def disconnect(_state) do
    Logger.info("[Discord] Adapter disconnected")
    :ok
  end
end
