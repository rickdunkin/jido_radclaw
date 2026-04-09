defmodule JidoClaw.Web.AuthController do
  use JidoClaw.Web, :controller
  import AshAuthentication.Plug.Helpers

  def sign_in(conn, %{"email" => email, "password" => password}) do
    strategy = AshAuthentication.Info.strategy!(JidoClaw.Accounts.User, :password)

    case AshAuthentication.Strategy.action(strategy, :sign_in, %{
           "email" => email,
           "password" => password
         }) do
      {:ok, user} ->
        conn
        |> store_in_session(user)
        |> redirect(to: "/dashboard")

      {:error, _} ->
        conn
        |> put_flash(:error, "Invalid email or password")
        |> redirect(to: "/sign-in")
    end
  end

  def sign_out(conn, _params) do
    conn
    |> clear_session()
    |> redirect(to: "/sign-in")
  end
end
