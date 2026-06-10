defmodule JidoClaw.Web.LiveUserAuth do
  @moduledoc false
  import Phoenix.Component
  import Phoenix.LiveView

  alias AshAuthentication.Plug.Helpers
  alias JidoClaw.Authorization.Actor
  alias JidoClaw.Web.AdminAccess

  @spec on_mount(atom(), map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont | :halt, Phoenix.LiveView.Socket.t()}
  def on_mount(:live_user_optional, _params, session, socket) do
    socket = assign_current_user(socket, session)
    {:cont, socket}
  end

  def on_mount(:live_user_required, _params, session, socket) do
    socket = assign_current_user(socket, session)

    if socket.assigns.current_user do
      {:cont, socket}
    else
      {:halt, redirect(socket, to: "/sign-in")}
    end
  end

  def on_mount(:live_admin_required, _params, session, socket) do
    socket = assign_current_user(socket, session)

    cond do
      is_nil(socket.assigns.current_user) ->
        {:halt, redirect(socket, to: "/sign-in")}

      not AdminAccess.admin?(socket.assigns.current_user) ->
        {:halt, redirect(socket, to: "/dashboard")}

      true ->
        {:cont, socket}
    end
  end

  def on_mount(:live_no_user, _params, session, socket) do
    socket = assign_current_user(socket, session)

    if socket.assigns.current_user do
      {:halt, redirect(socket, to: "/dashboard")}
    else
      {:cont, socket}
    end
  end

  defp assign_current_user(socket, session) do
    case Helpers.authenticate_resource_from_session(
           JidoClaw.Accounts.User,
           session,
           :jido_claw,
           []
         ) do
      {:ok, user} ->
        socket
        |> assign(:current_user, user)
        |> assign(:current_actor, Actor.build(user))

      :error ->
        socket
        |> assign(:current_user, nil)
        |> assign(:current_actor, nil)
    end
  end
end
