defmodule JidoClaw.Web.Plugs.RequireAuth do
  @moduledoc false
  import Plug.Conn

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    session = get_session(conn)

    case AshAuthentication.Plug.Helpers.authenticate_resource_from_session(
           JidoClaw.Accounts.User,
           session,
           :jido_claw,
           []
         ) do
      {:ok, user} ->
        actor = JidoClaw.Authorization.Actor.build(user)

        conn
        |> assign(:current_user, user)
        |> assign(:current_actor, actor)
        |> Ash.PlugHelpers.set_actor(actor)

      :error ->
        conn
        |> Phoenix.Controller.redirect(to: "/sign-in")
        |> halt()
    end
  end
end
