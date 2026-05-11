defmodule JidoClaw.Web.UserSocket do
  use Phoenix.Socket

  channel("rpc:*", JidoClaw.Web.RpcChannel)

  @impl true
  def connect(_params, socket, connect_info) do
    session = connect_info[:session] || %{}

    case AshAuthentication.Plug.Helpers.authenticate_resource_from_session(
           JidoClaw.Accounts.User,
           session,
           :jido_claw,
           []
         ) do
      {:ok, user} ->
        actor = JidoClaw.Authorization.Actor.build(user)

        socket =
          socket
          |> assign(:current_user, user)
          |> assign(:current_actor, actor)

        {:ok, socket}

      :error ->
        {:error, :unauthorized}
    end
  end

  @impl true
  def id(socket), do: "user_socket:#{socket.assigns.current_user.id}"
end
