defmodule JidoClaw.Web.ChatController do
  # The {id, object, created, choices} map is the OpenAI-compatible response
  # shape — an external API contract, fixed by the spec.
  # reach:disable-for-this-file fixed_shape_map
  use Phoenix.Controller, formats: [:json]
  require Logger

  alias Ecto.UUID
  alias JidoClaw.Config

  @max_messages 100
  @max_message_bytes 65_536
  @max_transcript_bytes 262_144
  @supported_roles ~w(system developer user assistant tool)

  @doc """
  OpenAI-compatible chat completions endpoint.
  Accepts POST with {model, messages, stream, ...}.
  """
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, params) when is_map(params) do
    # Derive tenant from the authenticated user to preserve per-user isolation
    # without trusting client-supplied headers. A real user-to-tenant model is
    # a follow-up; until then the user's ID acts as the tenant namespace.
    user_id = conn.assigns.current_user.id
    tenant_id = to_string(user_id)
    actor = conn.assigns[:current_actor]

    with {:ok, transcript_json} <- validate_messages(Map.get(params, "messages")),
         {:ok, stream?} <- validate_stream(Map.get(params, "stream", false)),
         {:ok, model} <- resolve_model(Map.get(params, "model", "default")) do
      prompt = encode_transcript(transcript_json)

      if stream? do
        stream_response(conn, tenant_id, user_id, actor, model, prompt)
      else
        sync_response(conn, tenant_id, user_id, actor, model, prompt)
      end
    else
      {:error, message} -> invalid_request(conn, message)
    end
  end

  defp sync_response(conn, tenant_id, user_id, actor, model, content) do
    session_id = "api_#{UUID.generate()}"

    # `clarify: :one_shot` — every call mints a fresh `api_*` session, so a
    # parked question round could never be answered (queue item 8).
    case chat_facade().chat(
           tenant_id,
           session_id,
           content,
           stateless_chat_opts(session_id, user_id, actor, model)
         ) do
      {:ok, response} ->
        json(conn, %{
          id: "chatcmpl-#{UUID.generate()}",
          object: "chat.completion",
          created: System.system_time(:second),
          model: model,
          choices: [
            %{
              index: 0,
              message: %{role: "assistant", content: response},
              finish_reason: "stop"
            }
          ]
        })

      {:error, reason} ->
        request_id = UUID.generate()
        Logger.error("chat completion failed request_id=#{request_id}: #{inspect(reason)}")

        conn
        |> put_status(500)
        |> json(%{
          error: %{
            message: "The completion could not be generated",
            type: "server_error",
            request_id: request_id
          }
        })
    end
  end

  defp stream_response(conn, tenant_id, user_id, actor, model, content) do
    session_id = "api_stream_#{UUID.generate()}"

    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "keep-alive")
      |> put_resp_header("x-jidoclaw-stream-mode", "buffered")
      |> send_chunked(200)

    # `clarify: :one_shot` — same per-call session reasoning as the sync arm.
    case chat_facade().chat(
           tenant_id,
           session_id,
           content,
           stateless_chat_opts(session_id, user_id, actor, model)
         ) do
      {:ok, response} ->
        chunk_id = "chatcmpl-#{UUID.generate()}"

        data =
          Jason.encode!(%{
            id: chunk_id,
            object: "chat.completion.chunk",
            created: System.system_time(:second),
            model: model,
            choices: [
              %{index: 0, delta: %{role: "assistant", content: response}, finish_reason: nil}
            ]
          })

        chunk(conn, "data: #{data}\n\n")

        done =
          Jason.encode!(%{
            id: chunk_id,
            object: "chat.completion.chunk",
            created: System.system_time(:second),
            model: model,
            choices: [%{index: 0, delta: %{}, finish_reason: "stop"}]
          })

        chunk(conn, "data: #{done}\n\n")
        chunk(conn, "data: [DONE]\n\n")
        conn

      {:error, reason} ->
        request_id = UUID.generate()
        Logger.error("streaming completion failed request_id=#{request_id}: #{inspect(reason)}")

        error =
          Jason.encode!(%{
            error: %{
              message: "The completion could not be generated",
              type: "server_error",
              request_id: request_id
            }
          })

        chunk(conn, "data: #{error}\n\n")
        chunk(conn, "data: [DONE]\n\n")
        conn
    end
  end

  defp validate_messages(messages) when is_list(messages) do
    cond do
      messages == [] ->
        {:error, "messages must contain at least one message"}

      length(messages) > @max_messages ->
        {:error, "messages exceeds the maximum of #{@max_messages} entries"}

      true ->
        validate_message_entries(messages)
    end
  end

  defp validate_messages(_), do: {:error, "messages must be a non-empty array"}

  defp validate_message_entries(messages) do
    case Enum.reduce_while(messages, {:ok, [], 0}, &normalize_message/2) do
      {:ok, normalized, _content_bytes} ->
        normalized = Enum.reverse(normalized)
        encoded = Jason.encode!(normalized)

        # The running-sum halt below is only a sound pre-check (encoded bytes
        # ≥ summed raw content bytes, so nothing under the cap is rejected
        # early); this final encoded-size check stays AUTHORITATIVE — JSON
        # escaping can push an under-cap raw sum over the encoded cap.
        if byte_size(encoded) <= @max_transcript_bytes do
          {:ok, encoded}
        else
          {:error, "messages content exceeds the maximum encoded transcript size"}
        end

      {:error, _} = err ->
        err
    end
  end

  # Only role/content cross the prompt boundary. OpenAI-compatible clients may
  # send ancillary fields, but retaining arbitrary maps here both expands the
  # prompt-injection surface and lets uncounted fields bypass transcript caps.
  defp normalize_message(%{"role" => role, "content" => content}, {:ok, acc, content_bytes})
       when role in @supported_roles and is_binary(content) do
    content_bytes = content_bytes + byte_size(content)

    cond do
      byte_size(content) > @max_message_bytes ->
        {:halt, {:error, "a message exceeds the maximum content size"}}

      content_bytes > @max_transcript_bytes ->
        # Halt as soon as the raw prefix crosses the transcript cap instead of
        # materializing all 100×64KB messages plus their encoded copy first.
        # Deliberate precedence change: an oversized transcript PREFIX now
        # wins over a malformed LATER message (that message is never visited).
        {:halt, {:error, "messages content exceeds the maximum encoded transcript size"}}

      true ->
        {:cont, {:ok, [%{"role" => role, "content" => content} | acc], content_bytes}}
    end
  end

  defp normalize_message(%{"role" => role}, {:ok, _acc, _bytes})
       when role not in @supported_roles,
       do: {:halt, {:error, "unsupported message role"}}

  defp normalize_message(_message, {:ok, _acc, _bytes}),
    do: {:halt, {:error, "each message must have a supported role and string content"}}

  defp validate_stream(stream?) when is_boolean(stream?), do: {:ok, stream?}
  defp validate_stream(_), do: {:error, "stream must be a boolean"}

  defp resolve_model(requested) when is_binary(requested) and requested != "" do
    configured = Config.model(Config.load())

    if requested in ["default", configured] do
      {:ok, configured}
    else
      {:error, "requested model is not configured on this server"}
    end
  end

  defp resolve_model(_), do: {:error, "model must be a non-empty string"}

  defp encode_transcript(transcript_json) do
    """
    Continue the ordered conversation below. Roles and content are encoded as JSON; preserve their order and answer the final message.

    #{transcript_json}
    """
  end

  defp invalid_request(conn, message) do
    conn
    |> put_status(400)
    |> json(%{error: %{message: message, type: "invalid_request_error"}})
  end

  defp stateless_chat_opts(session_id, user_id, actor, model) do
    [
      kind: :api,
      external_id: session_id,
      user_id: user_id,
      actor: actor,
      clarify: :one_shot,
      ephemeral_runtime: true,
      stateless_completion: true,
      stateless_completion_model: model,
      metadata: %{"api_stateless" => true}
    ]
  end

  defp chat_facade, do: Application.get_env(:jido_claw, :chat_facade, JidoClaw)
end
