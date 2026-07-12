defmodule JidoClaw.Web.ArgusSocket do
  @moduledoc """
  Key-only WebSocket entry for the argus SPA (`/argus/ws`).

  Deliberately separate from `JidoClaw.Web.UserSocket`: the SPA's baked
  API key must never unlock the mutable `rpc:*` surface
  (`sessions.create` / `sessions.sendMessage`), so this socket declares
  exactly one channel — the read-only `workflows:*` — and authenticates
  exclusively via the `authToken` header transport (`auth_token: true` on
  the endpoint mount; the key rides `Sec-WebSocket-Protocol`, never the
  URL, so no log-filtering change is needed). Session cookies never
  authenticate this socket; API keys never authenticate `UserSocket`.

  Connect mirrors the `/gql` pipeline: key auth via
  `JidoClaw.Web.Plugs.ApiKeyAuth.authenticate_api_key/1` (one audit event
  per attempt — a token-less connect emits its row via
  `ApiKeyAuth.missing_api_key_failure/0`) then the tenant activity gate
  through the
  `:tenant_access_module` app-env seam — inactive → refuse, infra failure
  → refuse, fail closed. `ensure_active/1` may provision the tenant row
  on first connect, same as `/gql`.

  `id/1` keys every socket on the tenant so `disconnect_tenant/1` can
  drop all of a tenant's argus sockets at once on suspension. Key
  revocation/expiry does NOT drop a live socket — the socket retains
  user/actor identity, re-validated on transport reconnect only
  (documented residual, `docs/system/channels-surface.md`).
  """
  use Phoenix.Socket

  alias JidoClaw.Authorization.Actor
  alias JidoClaw.Web.Plugs.ApiKeyAuth

  channel("workflows:*", JidoClaw.Web.WorkflowsChannel)

  @impl Phoenix.Socket
  def connect(_params, socket, connect_info) do
    case connect_info[:auth_token] do
      nil ->
        # No token ⇒ authenticate_api_key/1 is never reached, so emit the
        # missing-key audit row here — one row per refused attempt, same
        # as the HTTP plug's no-header branch.
        _ = ApiKeyAuth.missing_api_key_failure()
        {:error, :missing_api_key}

      token ->
        authenticate(token, socket)
    end
  end

  @impl Phoenix.Socket
  def id(socket), do: tenant_topic(socket.assigns.current_actor.tenant_id)

  @doc """
  Force-disconnect every live argus socket of `tenant_id`, cluster-wide.

  Broadcasts the exact `%Phoenix.Socket.Broadcast{event: "disconnect"}`
  message `Endpoint.broadcast/3` would construct, directly on
  `JidoClaw.PubSub` — endpoint-independent, so a suspension initiated on
  a CLI/MCP node (no local Endpoint) still drops gateway sockets on every
  node (PubSub is always in the Core supervision group).
  """
  @spec disconnect_tenant(String.t()) :: :ok | {:error, term()}
  def disconnect_tenant(tenant_id) when is_binary(tenant_id) do
    topic = tenant_topic(tenant_id)

    Phoenix.PubSub.broadcast(
      JidoClaw.PubSub,
      topic,
      %Phoenix.Socket.Broadcast{topic: topic, event: "disconnect", payload: %{}}
    )
  end

  defp authenticate(token, socket) do
    case ApiKeyAuth.authenticate_api_key(token) do
      {:ok, user} -> gate_on_activity(user, socket)
      {:error, _reason} -> {:error, :invalid_api_key}
    end
  end

  defp gate_on_activity(user, socket) do
    actor = Actor.build(user)

    case tenant_access().ensure_active(actor.tenant_id) do
      :ok ->
        {:ok,
         socket
         |> assign(:current_user, user)
         |> assign(:current_actor, actor)
         |> assign(:auth_method, :api_key)}

      {:error, {:tenant_inactive, _status}} ->
        {:error, :tenant_inactive}

      {:error, _reason} ->
        {:error, :tenant_unavailable}
    end
  end

  defp tenant_topic(tenant_id), do: "argus_socket:#{tenant_id}"

  defp tenant_access do
    Application.get_env(:jido_claw, :tenant_access_module, JidoClaw.Tenants.Access)
  end
end
