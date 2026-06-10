defmodule JidoClaw.Web.Plugs.RequireAdmin do
  @moduledoc """
  Gate plug for the `/admin` surface. Must run after
  `JidoClaw.Web.Plugs.RequireAuth`, which sets `:current_user`.

  Non-admin (or missing) users get a bare 404 rather than a 403 or a
  redirect so the admin surface is not advertised to authenticated
  non-admin users.
  """
  import Plug.Conn

  alias JidoClaw.Web.AdminAccess

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    if AdminAccess.admin?(conn.assigns[:current_user]) do
      conn
    else
      conn
      |> send_resp(404, "Not Found")
      |> halt()
    end
  end
end
