defmodule JidoClaw.Forge.Runners.Fake do
  @moduledoc """
  Test substrate for the consolidator.

  Speaks MCP JSON-RPC against the consolidator's per-run HTTP/SSE
  endpoint, exercising the same path the real ClaudeCode CLI uses:
  Anubis's plug, the run-id assign propagation, the registry lookup
  in tool handlers, and the staging buffer end-to-end.

  Driven by `runner_config.fake_proposals` — a list of `{tool_name,
  args}` tuples. The runner sends one `tools/call` per proposal in
  order, then a final `commit_proposals` call, then closes the
  session.
  """

  @behaviour JidoClaw.Forge.Runner

  alias JidoClaw.Forge.Runner

  require Logger

  @impl true
  def init(_client, config) do
    proposals = Map.get(config, :fake_proposals, [])
    mcp_config_path = Map.get(config, :mcp_config_path)

    {:ok,
     %{
       fake_proposals: proposals,
       mcp_config_path: mcp_config_path,
       iteration: 0
     }}
  end

  @impl true
  def run_iteration(_client, state, _opts) do
    with {:ok, server_url} <- read_server_url(state.mcp_config_path),
         {:ok, _session_id} <- mcp_initialize(server_url),
         :ok <- send_proposals(server_url, state.fake_proposals),
         :ok <- commit(server_url) do
      {:ok, Runner.done("fake-completed")}
    else
      {:error, reason} ->
        {:ok, Runner.error("fake_runner_failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def apply_input(_client, _input, _state), do: :ok

  defp read_server_url(nil), do: {:error, :no_mcp_config_path}

  defp read_server_url(path) do
    with {:ok, body} <- File.read(path),
         {:ok, json} <- Jason.decode(body),
         %{"mcpServers" => %{"consolidator" => %{"url" => url}}} <- json do
      {:ok, url}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_mcp_config}
    end
  end

  # The MCP streamable-HTTP transport returns an `mcp-session-id`
  # header on successful `initialize` that subsequent calls must
  # echo back. We treat the response as best-effort: if the server
  # doesn't enforce a session id we still proceed.
  defp mcp_initialize(url) do
    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2024-11-05",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "fake-runner", "version" => "0.6.0"}
        }
      })

    case http_post(url, body, []) do
      {:ok, _status, headers, _body} ->
        session_id =
          headers
          |> Enum.find(fn {k, _} -> String.downcase(k) == "mcp-session-id" end)
          |> case do
            {_, v} -> v
            _ -> nil
          end

        {:ok, session_id}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp send_proposals(url, proposals) do
    Enum.reduce_while(proposals, :ok, fn {tool_name, args}, _acc ->
      case call_tool(url, tool_name, args) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:proposal_failed, tool_name, reason}}}
      end
    end)
  end

  defp commit(url), do: call_tool(url, "commit_proposals", %{})

  defp call_tool(url, tool_name, args) do
    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => :erlang.unique_integer([:positive]),
        "method" => "tools/call",
        "params" => %{"name" => tool_name, "arguments" => args}
      })

    case http_post(url, body, []) do
      {:ok, status, _headers, _resp_body} when status in 200..299 -> :ok
      {:ok, status, _headers, resp_body} -> {:error, {:http_error, status, resp_body}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Plain :httpc POST. Avoids dragging in a full MCP-client lib for
  # what's effectively a 100-line test substrate.
  defp http_post(url, body, extra_headers) do
    :inets.start()
    :ssl.start()

    headers = [
      {~c"content-type", ~c"application/json"},
      {~c"accept", ~c"application/json"}
    ]

    headers =
      Enum.map(extra_headers, fn {k, v} -> {to_charlist(k), to_charlist(v)} end) ++ headers

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
