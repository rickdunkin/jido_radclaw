defmodule JidoClaw.Channel.DiscordConsumer do
  @moduledoc """
  Nostrum consumer that receives Discord gateway events and routes
  messages through the JidoClaw channel adapter.
  """
  use Nostrum.Consumer
  require Logger

  alias JidoClaw.Channel.Discord

  @impl Nostrum.Consumer
  def handle_event({:MESSAGE_CREATE, message, _ws_state}) do
    # Ignore messages from bots (including ourselves)
    if message.author.bot do
      :noop
    else
      adapter_state = %{
        bot_token: nil,
        guild_id: nil,
        channel_ids: [],
        connected: true
      }

      Discord.handle_inbound(message, adapter_state)
    end
  end

  @impl Nostrum.Consumer
  def handle_event({:READY, _data, _ws_state}) do
    Logger.warning("[Discord] Bot connected and ready")
  end
end
