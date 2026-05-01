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
    user_id = socket.assigns.current_user.id
    project_dir = File.cwd!()

    # Resolve durable Workspace + Conversation rows BEFORE starting the
    # runtime Session.Worker. If we started the worker first and a
    # resolver failed, the client would see an error but a runtime
    # session would remain registered — and a retry with the same
    # session_id would then short-circuit on `start_session →
    # {:already_started, _}`, never reaching the resolvers. By doing
    # the resolvers first, a retry that hit an already-running worker
    # is treated as success (Decision: idempotent reuse is fine here
    # because the durable rows are already in place).
    with {:ok, workspace} <-
           JidoClaw.Workspaces.Resolver.ensure_workspace(tenant_id, project_dir, user_id: user_id),
         {:ok, session} <-
           JidoClaw.Conversations.Resolver.ensure_session(
             tenant_id,
             workspace.id,
             :web_rpc,
             session_id,
             user_id: user_id
           ),
         {:ok, _pid} <- ensure_runtime_session(tenant_id, session_id) do
      {:reply, {:ok, %{session_id: session_id, id: session.id}}, socket}
    else
      {:error, reason} -> {:reply, {:error, %{reason: inspect(reason)}}, socket}
    end
  end

  def handle_in(
        "sessions.sendMessage",
        %{"session_id" => session_id, "content" => content},
        socket
      ) do
    tenant_id = tenant_for(socket)
    user_id = socket.assigns.current_user.id

    case JidoClaw.chat(tenant_id, session_id, content,
           kind: :web_rpc,
           external_id: session_id,
           user_id: user_id
         ) do
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

  # `start_session/2` returns `{:error, {:already_started, pid}}` when a
  # runtime worker for this `(tenant_id, session_id)` already exists. For
  # `sessions.create` the durable rows have already been resolved by the
  # caller, so an already-running worker is the exact post-condition we
  # want — surface it as `{:ok, pid}` instead of bubbling the error.
  defp ensure_runtime_session(tenant_id, session_id) do
    case JidoClaw.Session.Supervisor.start_session(tenant_id, session_id) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, _} = err -> err
    end
  end
end
