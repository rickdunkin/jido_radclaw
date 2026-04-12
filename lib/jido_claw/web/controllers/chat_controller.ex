defmodule JidoClaw.Web.ChatController do
  use Phoenix.Controller, formats: [:json]
  require Logger

  @doc """
  OpenAI-compatible chat completions endpoint.
  Accepts POST with {model, messages, stream, ...}.
  """
  def create(conn, %{"messages" => messages} = params) do
    stream = Map.get(params, "stream", false)
    model = Map.get(params, "model", "default")
    tenant_id = get_req_header(conn, "x-tenant-id") |> List.first() || "default"

    if stream do
      stream_response(conn, tenant_id, model, messages)
    else
      sync_response(conn, tenant_id, model, messages)
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(400)
    |> json(%{error: %{message: "messages field is required", type: "invalid_request_error"}})
  end

  defp sync_response(conn, tenant_id, _model, messages) do
    last_message = List.last(messages)
    content = Map.get(last_message, "content", "")

    # Route through the default agent session
    case JidoClaw.chat(tenant_id, "api_#{:erlang.unique_integer([:positive])}", content) do
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

  defp stream_response(conn, tenant_id, _model, messages) do
    last_message = List.last(messages)
    content = Map.get(last_message, "content", "")

    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "keep-alive")
      |> send_chunked(200)

    case JidoClaw.chat(tenant_id, "api_stream_#{:erlang.unique_integer([:positive])}", content) do
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
