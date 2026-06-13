defmodule JidoClaw.MCP.Client.Live do
  @moduledoc """
  Production `JidoClaw.MCP.Client` — delegates to the `jido_mcp` dependency.

  Two jobs beyond plain delegation:

    * **Shape normalization.** `Jido.MCP.list_tools/2` and `call_tool/4` return
      a `%{status: :ok, data: ..., raw: ...}` envelope; this module unwraps it
      so callers see `{:ok, [tool_map]}` / `{:ok, data}`.
    * **Explicit discovery timeouts.** Boot prep passes its own bounds rather
      than inheriting the endpoint's 30s `request_ms`, and a redundant
      `:ready_timeout` keeps `await_ready` inside the same envelope.

  `register_endpoint/1` folds `{:error, {:endpoint_already_registered, _}}`
  into `:ok`: a Consumer restart re-runs prep against a `ClientPool` that
  outlived it, and re-discovery + proxy rebuild must still happen.
  """

  @behaviour JidoClaw.MCP.Client

  @impl JidoClaw.MCP.Client
  def register_endpoint(endpoint) do
    case Jido.MCP.register_endpoint(endpoint) do
      {:ok, _endpoint} -> :ok
      {:error, {:endpoint_already_registered, _id}} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @impl JidoClaw.MCP.Client
  def await_endpoint_ready(endpoint_id, timeout) do
    Jido.MCP.await_endpoint_ready(endpoint_id, timeout: timeout)
  end

  @impl JidoClaw.MCP.Client
  def list_tools(endpoint_id, timeout) do
    endpoint_id
    |> Jido.MCP.list_tools(timeout: timeout, ready_timeout: timeout)
    |> normalize_tools()
  end

  @impl JidoClaw.MCP.Client
  def call_tool(endpoint_id, tool_name, arguments) do
    endpoint_id
    |> Jido.MCP.call_tool(tool_name, arguments)
    |> normalize_call()
  end

  # `Jido.MCP.list_tools/2` always returns the `%{status:, data:, raw:}`
  # envelope on success (or `{:error, _}`); `data` for `tools/list` is
  # `%{"tools" => [...]}`. Anything else ⇒ no tools.
  defp normalize_tools({:ok, %{data: %{"tools" => tools}}}) when is_list(tools), do: {:ok, tools}
  defp normalize_tools({:ok, _other}), do: {:ok, []}
  defp normalize_tools({:error, _reason} = error), do: error

  # `Jido.MCP.call_tool/4`'s success is the same envelope; `data` is the
  # unwrapped tool result.
  defp normalize_call({:ok, %{data: data}}), do: {:ok, data}
  defp normalize_call({:error, _reason} = error), do: error
end
