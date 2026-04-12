defmodule JidoClaw.Channel.Telegram do
  @moduledoc """
  Telegram channel adapter using the Bot API via HTTP.
  Config: %{bot_token: "...", allowed_chat_ids: [...]}
  """
  @behaviour JidoClaw.Channel.Behaviour
  require Logger

  @base_url "https://api.telegram.org/bot"

  @impl true
  def init(config) do
    state = %{
      bot_token: Map.fetch!(config, :bot_token),
      allowed_chat_ids: Map.get(config, :allowed_chat_ids, []),
      offset: 0,
      poll_interval: Map.get(config, :poll_interval, 1_000),
      connected: false
    }

    {:ok, state}
  end

  @impl true
  def connect(state) do
    # Start long-polling loop
    send(self(), :poll)
    Logger.info("[Telegram] Adapter connected, polling started")
    {:ok, %{state | connected: true}}
  end

  @impl true
  def handle_inbound(%{"message" => message}, state) do
    chat_id = get_in(message, ["chat", "id"])
    text = Map.get(message, "text", "")
    _from_id = get_in(message, ["from", "id"])
    update_id = Map.get(message, "update_id", 0)

    # Check if chat is allowed (empty list = allow all)
    allowed = state.allowed_chat_ids == [] or chat_id in state.allowed_chat_ids

    if allowed and text != "" do
      session_id = "telegram_#{chat_id}"

      case JidoClaw.chat("default", session_id, text) do
        {:ok, response} ->
          send_message(to_string(chat_id), response, state)
          {:reply, response, %{state | offset: update_id + 1}}

        {:error, _reason} ->
          {:noreply, %{state | offset: update_id + 1}}
      end
    else
      {:noreply, %{state | offset: update_id + 1}}
    end
  end

  def handle_inbound(_update, state) do
    {:noreply, state}
  end

  @impl true
  def send_message(chat_id, content, state) do
    url = "#{@base_url}#{state.bot_token}/sendMessage"

    body =
      Jason.encode!(%{
        chat_id: chat_id,
        text: content,
        parse_mode: "Markdown"
      })

    headers = [{~c"content-type", ~c"application/json"}]

    case :httpc.request(
           :post,
           {String.to_charlist(url), headers, ~c"application/json", String.to_charlist(body)},
           [{:timeout, 10_000}],
           []
         ) do
      {:ok, {{_, 200, _}, _, _}} ->
        :ok

      {:ok, {{_, code, _}, _, resp}} ->
        Logger.warning("[Telegram] Send failed (#{code}): #{resp}")
        {:error, {:http, code}}

      {:error, reason} ->
        Logger.warning("[Telegram] Send failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @impl true
  def disconnect(_state) do
    Logger.info("[Telegram] Adapter disconnected")
    :ok
  end

  # -- Long Polling (called via handle_info in Worker) --

  def poll(state) do
    url = "#{@base_url}#{state.bot_token}/getUpdates?offset=#{state.offset}&timeout=30"

    case :httpc.request(:get, {String.to_charlist(url), []}, [{:timeout, 35_000}], []) do
      {:ok, {{_, 200, _}, _, body}} ->
        case Jason.decode(List.to_string(body)) do
          {:ok, %{"ok" => true, "result" => updates}} ->
            {:ok, updates, state}

          _ ->
            {:ok, [], state}
        end

      _ ->
        {:ok, [], state}
    end
  end
end
