defmodule JidoClaw.Web.LiveUserAuth do
  import Phoenix.Component
  import Phoenix.LiveView

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

  def on_mount(:live_no_user, _params, session, socket) do
    socket = assign_current_user(socket, session)

    if socket.assigns.current_user do
      {:halt, redirect(socket, to: "/dashboard")}
    else
      {:cont, socket}
    end
  end

  defp assign_current_user(socket, session) do
    case AshAuthentication.Plug.Helpers.authenticate_resource_from_session(
           JidoClaw.Accounts.User,
           session,
           :jido_claw,
           []
         ) do
      {:ok, user} -> assign(socket, :current_user, user)
      :error -> assign(socket, :current_user, nil)
    end
  end
end
