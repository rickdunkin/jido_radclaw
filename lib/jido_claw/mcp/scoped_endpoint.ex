defmodule JidoClaw.MCP.ScopedEndpoint do
  @moduledoc """
  Per-scope Bandit endpoint fronting a static MCP server on a loopback port.

  Each `start_link/1` call spawns a fresh listener bound to `127.0.0.1:0`
  (kernel-assigned port). The caller's harness gets the URL
  `http://127.0.0.1:<port><path_prefix>/<scope_id>` and speaks MCP JSON-RPC
  through it; the supplied `plug` (a `Plug.Router` routing through
  `JidoClaw.MCP.ScopedForward`) stamps the scope id into `conn.assigns` on the
  way in. `stop/1` tears the listener down at scope cleanup.

  Two consumers share it (executor-seam PR-2, decision 5 — generalized from the
  consolidator's per-run `MCPEndpoint`, which this module replaces): the memory
  consolidator (`Consolidator.Plug`, `/run/<run_id>`) and the vendor-executor
  deposit lane (`ForgeExecutor.DepositPlug`, `/deposit/<ref>`).
  """

  @doc """
  Start a Bandit listener for one scope. Options (all required):

    * `:plug` — the `Plug.Router` module fronting the MCP server
    * `:scope_id` — the per-scope URL segment (run id / deposit ref)
    * `:path_prefix` — the route prefix the plug matches (e.g. `"/run"`)

  Returns `{:ok, %{pid:, port:, url:}}` or `{:error, term}` — the error tuple
  is surfaced (never crash-matched) so a caller's resource-acquisition unwind
  can handle it. If Bandit starts but the port read fails, the listener is
  stopped here before returning the error — the caller never received the pid,
  so no outer unwind could stop it.
  """
  @spec start_link(keyword()) ::
          {:ok, %{pid: pid(), port: pos_integer(), url: String.t()}} | {:error, term()}
  def start_link(opts) do
    plug = Keyword.fetch!(opts, :plug)
    scope_id = Keyword.fetch!(opts, :scope_id)
    path_prefix = Keyword.fetch!(opts, :path_prefix)

    case Bandit.start_link(plug: {plug, []}, port: 0, ip: {127, 0, 0, 1}) do
      {:ok, pid} ->
        case bound_port(pid) do
          {:ok, port} ->
            {:ok,
             %{pid: pid, port: port, url: "http://127.0.0.1:#{port}#{path_prefix}/#{scope_id}"}}

          {:error, reason} ->
            stop(%{pid: pid})
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Stop a Bandit endpoint started with `start_link/1`."
  @spec stop(map()) :: :ok
  def stop(%{pid: pid}) when is_pid(pid) do
    Supervisor.stop(pid, :normal, 5_000)
    :ok
  catch
    _, _ -> :ok
  end

  def stop(_), do: :ok

  @doc """
  Render the MCP client-config JSON body a CLI harness reads
  (`{"mcpServers": {<server_name>: {"type": "http", "url": <url>}}}`). The
  explicit `"type": "http"` is load-bearing: claude ≥2.x reads a bare `url`
  entry as the legacy SSE transport and never forms the streamable-HTTP
  connection our endpoints speak (found by the PR-2 live smoke; the old
  consolidator config carried the bare shape). Shared by
  `write_client_config/3` (the host-tmp file the local executor path and the
  consolidator write) and the executor's docker path (which carries this body
  as `mcp_config_json` for an in-VM write at runner init).
  """
  @spec client_config_json(String.t(), String.t()) :: String.t()
  def client_config_json(server_name, url)
      when is_binary(server_name) and is_binary(url) do
    Jason.encode!(%{"mcpServers" => %{server_name => %{"type" => "http", "url" => url}}})
  end

  @doc """
  Write the host-side MCP client-config JSON (`client_config_json/2`) to
  `System.tmp_dir!()/<basename>`. Host-side deliberately: HostShell's
  `Sandbox.write_file` jails absolute paths, so client-config files can never
  ride that transport. Non-bang `File.write/2` — the caller chooses whether a
  write failure crashes (`{:ok, path} =`) or unwinds.
  """
  @spec write_client_config(String.t(), String.t(), String.t()) ::
          {:ok, Path.t()} | {:error, term()}
  def write_client_config(server_name, url, basename)
      when is_binary(server_name) and is_binary(url) and is_binary(basename) do
    path = Path.join(System.tmp_dir!(), basename)

    case File.write(path, client_config_json(server_name, url)) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, reason}
    end
  end

  defp bound_port(pid) do
    case ThousandIsland.listener_info(pid) do
      {:ok, {_addr, port}} -> {:ok, port}
      other -> {:error, {:listener_info_failed, other}}
    end
  end
end
