defmodule JidoClaw.Forge.Runners.Fake do
  @moduledoc """
  Test substrate for the consolidator.

  Speaks MCP JSON-RPC against the consolidator's per-run HTTP/SSE
  endpoint via `JidoClaw.MCP.LoopbackClient`, exercising the same path
  the real ClaudeCode CLI uses: Anubis's plug, the run-id assign
  propagation, the registry lookup in tool handlers, and the staging
  buffer end-to-end. Session-aware since executor-seam PR-2: the
  client echoes the `mcp-session-id` captured at initialize (still
  best-effort — a server that doesn't enforce session ids works too).

  Driven by `runner_config.fake_proposals` — a list of `{tool_name,
  args}` tuples. The runner sends one `tools/call` per proposal in
  order, then a final `commit_proposals` call, then closes the
  session.

  Tests can pin a specific `harness_turns` value by supplying
  `runner_config.fake_turns` (default 0). The value is emitted in the
  result metadata so the consolidator's `harness_turns` derivation
  exercises the same code path as the real runners.
  """

  @behaviour JidoClaw.Forge.Runner

  alias JidoClaw.Forge.Runner
  alias JidoClaw.MCP.LoopbackClient

  @impl JidoClaw.Forge.Runner
  def init(_client, config) do
    proposals = Map.get(config, :fake_proposals, [])
    mcp_config_path = Map.get(config, :mcp_config_path)
    turns = Map.get(config, :fake_turns, 0)

    {:ok,
     %{
       fake_proposals: proposals,
       mcp_config_path: mcp_config_path,
       fake_turns: turns,
       iteration: 0
     }}
  end

  @impl JidoClaw.Forge.Runner
  def run_iteration(_client, state, opts) do
    # The attempt-scoped config path (tokenized per-attempt capability)
    # rides opts; the init-time value is the legacy fallback.
    config_path = Keyword.get(opts, :mcp_config_path, state.mcp_config_path)

    base =
      with {:ok, server_url} <- read_server_url(config_path),
           {:ok, mcp} <- LoopbackClient.initialize(server_url),
           :ok <- send_proposals(mcp, state.fake_proposals),
           {:ok, _} <- LoopbackClient.call_tool(mcp, "commit_proposals", %{}) do
        Runner.done("fake-completed")
      else
        {:error, reason} ->
          Runner.error("fake_runner_failed: #{inspect(reason)}")
      end

    metadata = Map.merge(base.metadata, %{turns: state.fake_turns})
    {:ok, %{base | metadata: metadata}}
  end

  @impl JidoClaw.Forge.Runner
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

  defp send_proposals(mcp, proposals) do
    Enum.reduce_while(proposals, :ok, fn {tool_name, args}, _acc ->
      case LoopbackClient.call_tool(mcp, tool_name, args) do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:proposal_failed, tool_name, reason}}}
      end
    end)
  end
end
