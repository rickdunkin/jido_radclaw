defmodule JidoClaw.Channel.Behaviour do
  @moduledoc """
  Behaviour for platform channel adapters (Discord, Telegram, Slack, IRC, etc.).
  Each adapter normalizes inbound messages and dispatches outbound responses.
  """

  @type config :: map()
  @type state :: map()
  @type message :: %{
          text: String.t(),
          author_id: String.t(),
          channel_id: String.t(),
          platform: atom(),
          metadata: map()
        }

  @callback init(config()) :: {:ok, state()} | {:error, term()}
  @callback connect(state()) :: {:ok, state()} | {:error, term()}
  @callback handle_inbound(term(), state()) :: {:reply, String.t(), state()} | {:noreply, state()}
  @callback send_message(String.t(), String.t(), state()) :: :ok | {:error, term()}
  @callback disconnect(state()) :: :ok
end
