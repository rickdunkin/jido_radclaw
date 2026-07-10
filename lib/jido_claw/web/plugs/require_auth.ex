defmodule JidoClaw.Web.Plugs.RequireAuth do
  @moduledoc false
  import Plug.Conn

  require Logger

  alias JidoClaw.Authorization.Actor

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    # Result-preserving resolution (JidoClaw.Web.SessionUser): a genuinely
    # unauthenticated session redirects to sign-in, but an infrastructure
    # failure answers 503 with the session untouched — "cannot determine
    # auth state" must never read as signed-out.
    case session_user_resolver().resolve(get_session(conn)) do
      {:ok, user} ->
        actor = Actor.build(user)

        conn
        |> assign(:current_user, user)
        |> assign(:current_actor, actor)
        |> Ash.PlugHelpers.set_actor(actor)

      :unauthenticated ->
        conn
        |> Phoenix.Controller.redirect(to: "/sign-in")
        |> halt()

      {:error, reason} ->
        Logger.warning("[RequireAuth] session resolution unavailable: #{inspect(reason)}")

        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(503, "JidoClaw is temporarily unavailable. Retry shortly.")
        |> halt()
    end
  end

  defp session_user_resolver do
    Application.get_env(:jido_claw, :session_user_resolver, JidoClaw.Web.SessionUser)
  end
end
