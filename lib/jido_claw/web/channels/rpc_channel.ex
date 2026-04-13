defmodule JidoClaw.Web.RpcChannel do
  use Phoenix.Channel
  require Logger

  @impl true
  def join("rpc:lobby", _payload, socket) do
    {:ok, %{status: "connected"}, socket}
  end

  def join("rpc:" <> _topic, _payload, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_in("gateway.status", _payload, socket) do
    uptime =
      System.monotonic_time(:second) -
        Application.get_env(:jido_claw, :started_at, System.monotonic_time(:second))

    sessions =
      Registry.select(JidoClaw.SessionRegistry, [{{:"$1", :"$2", :"$3"}, [], [true]}]) |> length()

    {:reply, {:ok, %{uptime: uptime, sessions: sessions, node: to_string(Node.self())}}, socket}
  end

  def handle_in("sessions.list", _payload, socket) do
    sessions =
      Registry.select(JidoClaw.SessionRegistry, [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2"}}]}])
      |> Enum.map(fn {key, _pid} ->
        case key do
          {tenant_id, session_id} -> %{tenant_id: tenant_id, session_id: session_id}
          _ -> %{id: inspect(key)}
        end
      end)

    {:reply, {:ok, %{sessions: sessions}}, socket}
  end

  def handle_in(
        "sessions.create",
        %{"session_id" => session_id},
        socket
      ) do
    tenant_id = tenant_for(socket)

    case JidoClaw.Session.Supervisor.start_session(tenant_id, session_id) do
      {:ok, _pid} -> {:reply, {:ok, %{session_id: session_id}}, socket}
      {:error, reason} -> {:reply, {:error, %{reason: inspect(reason)}}, socket}
    end
  end

  def handle_in(
        "sessions.sendMessage",
        %{"session_id" => session_id, "content" => content},
        socket
      ) do
    tenant_id = tenant_for(socket)

    case JidoClaw.chat(tenant_id, session_id, content) do
      {:ok, response} ->
        push(socket, "session.response", %{session_id: session_id, content: response})
        {:reply, {:ok, %{status: "sent"}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: inspect(reason)}}, socket}
    end
  end

  def handle_in(method, _payload, socket) do
    {:reply, {:error, %{reason: "unknown method: #{method}"}}, socket}
  end

  # Derive tenant from the authenticated user to preserve per-user isolation
  # without trusting client-supplied params. A real user-to-tenant model is
  # a follow-up; until then the user's ID acts as the tenant namespace.
  defp tenant_for(socket), do: to_string(socket.assigns.current_user.id)
end
