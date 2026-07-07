defmodule JidoClaw.MCP.LoopbackClient do
  @moduledoc """
  Minimal MCP-JSON-RPC-over-`:httpc` client for the loopback scoped endpoints
  (`JidoClaw.MCP.ScopedEndpoint`). Session-aware: `initialize/1` captures the
  `mcp-session-id` response header the streamable-HTTP transport mints, and
  `call_tool/3` echoes it back — closer to a real MCP client than the old
  header-less posts, and not dependent on Anubis auto-initializing a session
  per request.

  Extracted from `JidoClaw.Forge.Runners.Fake` (executor-seam PR-2, decision
  5) so the consolidator's fake harness and the executor test doubles share
  one implementation. Plain `:httpc` deliberately — this is a ~100-line test
  substrate, not a transport worth a full MCP-client dependency.
  """

  @type t :: %{url: String.t(), session_id: String.t() | nil}

  @doc """
  Send the MCP `initialize` handshake to `url`, followed by the
  `notifications/initialized` notification the lifecycle requires. Returns
  `{:ok, client}` where the client carries the captured `mcp-session-id` (or
  `nil` — best-effort: a server that doesn't enforce session ids still works).
  """
  @spec initialize(String.t()) :: {:ok, t()} | {:error, term()}
  def initialize(url) when is_binary(url) do
    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2024-11-05",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "loopback-client", "version" => "1.0.0"}
        }
      })

    case http_post(url, body, []) do
      {:ok, _status, headers, _body} ->
        client = %{url: url, session_id: session_id_from(headers)}
        notify_initialized(client)
        {:ok, client}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A session-id-echoing client is held to the real MCP state machine: the
  # server refuses `tools/call` on a session that never confirmed
  # `notifications/initialized` (the old header-less posts rode Anubis's
  # lenient per-request auto-init instead, which never saw this). Best-effort
  # send — a server that doesn't enforce the lifecycle accepts calls anyway.
  defp notify_initialized(client) do
    body = Jason.encode!(%{"jsonrpc" => "2.0", "method" => "notifications/initialized"})
    _ = http_post(client.url, body, session_headers(client))
    :ok
  end

  @doc """
  Send one `tools/call`, echoing the session id captured at initialize.
  Returns `{:ok, decoded_body}` on a 2xx (the JSON-RPC envelope as a map when
  decodable, the raw body otherwise — a domain `isError` result is still a
  2xx `{:ok, _}` per MCP spec) or `{:error, term}` on transport/HTTP failure.
  """
  @spec call_tool(t(), String.t(), map()) :: {:ok, term()} | {:error, term()}
  def call_tool(%{url: url} = client, tool_name, args) when is_binary(tool_name) do
    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => :erlang.unique_integer([:positive]),
        "method" => "tools/call",
        "params" => %{"name" => tool_name, "arguments" => args}
      })

    case http_post(url, body, session_headers(client)) do
      {:ok, status, _headers, resp_body} when status in 200..299 ->
        {:ok, decode_body(resp_body)}

      {:ok, status, _headers, resp_body} ->
        {:error, {:http_error, status, resp_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp session_headers(%{session_id: sid}) when is_binary(sid) and sid != "",
    do: [{"mcp-session-id", sid}]

  defp session_headers(_client), do: []

  defp session_id_from(headers) do
    case Enum.find(headers, fn {k, _} -> String.downcase(k) == "mcp-session-id" end) do
      {_, v} -> v
      _ -> nil
    end
  end

  defp decode_body(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      _ -> body
    end
  end

  # Plain :httpc POST. Avoids dragging in a full MCP-client lib for
  # what's effectively a 100-line test substrate.
  defp http_post(url, body, extra_headers) do
    :inets.start()
    :ssl.start()

    base_headers = [
      {~c"content-type", ~c"application/json"},
      {~c"accept", ~c"application/json"}
    ]

    headers =
      Enum.map(extra_headers, fn {k, v} -> {to_charlist(k), to_charlist(v)} end) ++ base_headers

    request = {String.to_charlist(url), headers, ~c"application/json", body}

    case :httpc.request(:post, request, [{:timeout, 30_000}], []) do
      {:ok, {{_, status, _}, response_headers, response_body}} ->
        decoded_headers =
          Enum.map(response_headers, fn {k, v} -> {to_string(k), to_string(v)} end)

        {:ok, status, decoded_headers, to_string(response_body)}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
