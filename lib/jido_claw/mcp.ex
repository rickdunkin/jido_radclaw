defmodule JidoClaw.MCP do
  @moduledoc """
  Facade for **consuming** external MCP servers (distinct from `JidoClaw.MCPServer`,
  which *serves* JidoClaw's own tools over MCP).

  Operators declare external servers in `.jido/config.yaml` under `mcp_servers:`;
  `JidoClaw.MCP.Consumer` discovers their tools at boot, wraps each in a safe
  proxy `Jido.Action` (`JidoClaw.MCP.ProxyGenerator`), and this facade attaches
  those proxies onto running agents.

  Two attach entry points, both keeping the Consumer non-blocking:

    * `attach_to_agent/2` — fire-and-forget (REPL boot, restart rehydrate).
    * `ensure_attached/3` — bounded, for the per-turn paths (chat / spawn /
      follow-up / skill-step): the turn must already carry its tools. The
      `template` arg scopes which external tools register (the reach-allowlist).

  Plus two reads used by the safety pipeline and proxies:

    * `client/0` — the `JidoClaw.MCP.Client` impl (swappable for tests).
    * `approval_policy/0` — the published per-tool approval posture map,
      consulted by `JidoClaw.Security.ToolApproval`.
  """

  alias JidoClaw.MCP.Consumer

  @policy_key {:jido_claw, :mcp_approval_policy}

  @typedoc "Result of an attach attempt (best-effort; callers may ignore)."
  @type attach_result :: :ok | :already | :partial | :mcp_unavailable | :timeout | :skipped

  @doc "The active `JidoClaw.MCP.Client` implementation (`Live` in production)."
  @spec client() :: module()
  def client, do: Application.get_env(:jido_claw, :mcp_client, JidoClaw.MCP.Client.Live)

  @doc """
  The published `%{tool_name => true | false | nil}` approval posture map.

  Defaults to `%{}` when prep never ran — `ToolApproval` reads that as
  "fall back to the global default" for any `mcp_`-prefixed name, so a lost or
  unset policy fails **closed** (gated), never open to native.
  """
  @spec approval_policy() :: %{optional(String.t()) => boolean() | nil}
  def approval_policy, do: :persistent_term.get(@policy_key, %{})

  @doc false
  @spec policy_key() :: {atom(), atom()}
  def policy_key, do: @policy_key

  @doc """
  Record `pid` and register MCP proxies onto it, fire-and-forget.

  Replies once the Consumer has recorded the pid; the actual `register_tool`
  work runs in a supervised task off the Consumer process. Best-effort: returns
  `:skipped` when no Consumer is running (e.g. MCP serve mode, or test).
  """
  @spec attach_to_agent(pid(), String.t()) :: :ok | :skipped
  def attach_to_agent(pid, template) when is_pid(pid) and is_binary(template) do
    case Process.whereis(Consumer) do
      nil -> :skipped
      _consumer -> safe_attach(pid, template)
    end
  end

  @doc """
  Ensure `pid` has its `template`-allowlisted MCP proxies registered before its
  turn runs (bounded).

  Only the modules `template` may reach (the per-server reach-allowlist) are
  registered; an un-allowlisted worker confirms `:ok` having attached an empty
  subset. Returns immediately with `:already` for a pid the Consumer has
  confirmed attached (the steady-state fast path), so only a pid's first turn
  does registration work. While prep is still running, the *caller* waits
  (bounded by `timeout`) — the Consumer defers the reply rather than blocking
  itself. On `:timeout` (prep still running) the agent proceeds tool-less and a
  later turn genuinely retries; on a prep crash returns `:mcp_unavailable`
  (tool-less for that turn); with no Consumer, `:skipped`.

  Strictly 3-arity (no defaulted timeout): callers pass the bound explicitly so
  a stale 2-arity call fails loudly instead of silently binding the timeout as
  the template. `template` is typed `term()` — any non-binary resolves to
  unrestricted-only downstream (the binary check lives in the Consumer).

  `:mcp_unavailable` is no longer terminal: a hard prep crash now triggers
  bounded backoff re-prep in the Consumer, so a later turn's `ensure_attached`
  recovers once a retry succeeds. Only after the Consumer exhausts every retry
  (then genuinely `:failed`) does `:mcp_unavailable` persist until a restart.
  Steady-state tool-set drift is reconciled by the Consumer's periodic
  re-discovery, independent of this call.
  """
  @spec ensure_attached(pid(), term(), timeout()) :: attach_result()
  def ensure_attached(pid, template, timeout) when is_pid(pid) do
    case Process.whereis(Consumer) do
      nil -> :skipped
      _consumer -> do_ensure_attached(pid, template, timeout)
    end
  end

  defp safe_attach(pid, template) do
    GenServer.call(Consumer, {:attach, pid, template})
  catch
    :exit, _reason -> :skipped
  end

  defp do_ensure_attached(pid, template, timeout) do
    case GenServer.call(Consumer, {:modules_when_ready, pid, template}, timeout) do
      :already ->
        :already

      {:ok, modules, generation} ->
        result = Consumer.register_modules(pid, modules)

        if result == :ok,
          do: GenServer.cast(Consumer, {:mark_attached, pid, generation, template})

        result

      {:error, :mcp_unavailable} ->
        :mcp_unavailable
    end
  catch
    :exit, _reason -> :timeout
  end
end
