defmodule JidoClaw.Web.Plugs.RequireAuth do
  @moduledoc false
  import Plug.Conn

  alias AshAuthentication.Plug.Helpers
  alias JidoClaw.Authorization.Actor

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    session = get_session(conn)

    case Helpers.authenticate_resource_from_session(
           JidoClaw.Accounts.User,
           session,
           :jido_claw,
           []
         ) do
      {:ok, user} ->
        actor = Actor.build(user)

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
