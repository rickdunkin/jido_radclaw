defmodule JidoClaw.Web.ChatController do
  # The {id, object, created, choices} map is the OpenAI-compatible response
  # shape — an external API contract, fixed by the spec.
  # reach:disable-for-this-file fixed_shape_map
  use Phoenix.Controller, formats: [:json]
  require Logger

  @doc """
  OpenAI-compatible chat completions endpoint.
  Accepts POST with {model, messages, stream, ...}.
  """
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"messages" => messages} = params) do
    stream = Map.get(params, "stream", false)
    model = Map.get(params, "model", "default")
    # Derive tenant from the authenticated user to preserve per-user isolation
    # without trusting client-supplied headers. A real user-to-tenant model is
    # a follow-up; until then the user's ID acts as the tenant namespace.
    user_id = conn.assigns.current_user.id
    tenant_id = to_string(user_id)
    actor = conn.assigns[:current_actor]

    # The OpenAI request `messages` array is positional and bounded; the last
    # entry is the current turn. reach prefers List.last to Enum.at(-1), and
    # ExSlop's O(n)-last advisory doesn't apply to a short request body.
    # credo:disable-for-next-line ExSlop.Check.Refactor.ListLast
    last_message = List.last(messages)

    content =
      case last_message do
        %{} = msg -> Map.get(msg, "content", "")
        _ -> ""
      end

    if stream do
      stream_response(conn, tenant_id, user_id, actor, model, content)
    else
      sync_response(conn, tenant_id, user_id, actor, model, content)
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(400)
    |> json(%{error: %{message: "messages field is required", type: "invalid_request_error"}})
  end

  defp sync_response(conn, tenant_id, user_id, actor, _model, content) do
    session_id = "api_#{:erlang.unique_integer([:positive])}"

    # `clarify: :one_shot` — every call mints a fresh `api_*` session, so a
    # parked question round could never be answered (queue item 8).
    case JidoClaw.chat(tenant_id, session_id, content,
           kind: :api,
           external_id: session_id,
           user_id: user_id,
           actor: actor,
           clarify: :one_shot
         ) do
      {:ok, response} ->
        json(conn, %{
          id: "chatcmpl-#{:erlang.unique_integer([:positive])}",
          object: "chat.completion",
          created: System.system_time(:second),
          choices: [
            %{
              index: 0,
              message: %{role: "assistant", content: response},
              finish_reason: "stop"
            }
          ]
        })

      {:error, reason} ->
        conn
        |> put_status(500)
        |> json(%{error: %{message: inspect(reason), type: "server_error"}})
    end
  end

  defp stream_response(conn, tenant_id, user_id, actor, _model, content) do
    session_id = "api_stream_#{:erlang.unique_integer([:positive])}"

    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "keep-alive")
      |> send_chunked(200)

    # `clarify: :one_shot` — same per-call session reasoning as the sync arm.
    case JidoClaw.chat(tenant_id, session_id, content,
           kind: :api,
           external_id: session_id,
           user_id: user_id,
           actor: actor,
           clarify: :one_shot
         ) do
      {:ok, response} ->
        chunk_id = "chatcmpl-#{:erlang.unique_integer([:positive])}"

        data =
          Jason.encode!(%{
            id: chunk_id,
            object: "chat.completion.chunk",
            created: System.system_time(:second),
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
            choices: [%{index: 0, delta: %{}, finish_reason: "stop"}]
          })

        chunk(conn, "data: #{done}\n\n")
        chunk(conn, "data: [DONE]\n\n")
        conn

      {:error, reason} ->
        error = Jason.encode!(%{error: %{message: inspect(reason)}})
        chunk(conn, "data: #{error}\n\n")
        conn
    end
  end
end
