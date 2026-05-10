defmodule JidoClaw.Web.AuthController do
  use JidoClaw.Web, :controller
  import AshAuthentication.Plug.Helpers

  alias JidoClaw.Audit.AsyncWriter

  def sign_in(conn, %{"email" => email, "password" => password}) do
    strategy = AshAuthentication.Info.strategy!(JidoClaw.Accounts.User, :password)

    case AshAuthentication.Strategy.action(strategy, :sign_in, %{
           "email" => email,
           "password" => password
         }) do
      {:ok, user} ->
        emit_auth_event(:sign_in_success, user.id, %{email: email})

        conn
        |> store_in_session(user)
        |> redirect(to: "/dashboard")

      {:error, _} ->
        emit_auth_event(:sign_in_failure, nil, %{email: email})

        conn
        |> put_flash(:error, "Invalid email or password")
        |> redirect(to: "/sign-in")
    end
  end

  def sign_out(conn, _params) do
    # Read current_user BEFORE clear_session/1 — otherwise actor_id is nil.
    user = conn.assigns[:current_user]
    actor_id = user && user.id && to_string(user.id)

    emit_auth_event(:sign_out, actor_id, %{})

    conn
    |> clear_session()
    |> redirect(to: "/sign-in")
  end

  defp emit_auth_event(kind, actor_id, payload) do
    AsyncWriter.cast(%{
      tenant_id: tenant_for_auth(),
      event_kind: :auth_event,
      actor_kind: if(actor_id, do: :user, else: :system),
      actor_id: actor_id,
      target_kind: :auth,
      target_id: Atom.to_string(kind),
      payload: payload
    })
  end

  # Auth events are emitted under the "default" tenant since users are
  # untenanted by design (matches Solutions). When a multi-tenant
  # auth boundary lands, this can be lifted from the user record.
  defp tenant_for_auth, do: "default"
end
