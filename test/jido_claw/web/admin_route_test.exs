defmodule JidoClaw.Web.AdminRouteTest do
  @moduledoc """
  Route-level integration for the `/admin` gate — catches the wiring the
  plug unit tests can't: the `:require_admin` pipeline around
  `ash_admin("/admin")` and the `:live_admin_required` on_mount hook.

  Boots the real endpoint (`server: false`, see `config/test.exs`) and
  dispatches through the full router with a real signed-in session.
  """
  use JidoClaw.TenantCase, async: false

  import Phoenix.ConnTest

  alias AshAuthentication.Plug.Helpers
  alias JidoClaw.Accounts.User
  alias JidoClaw.Web.LiveUserAuth

  @endpoint JidoClaw.Web.Endpoint

  setup do
    start_supervised!(JidoClaw.Web.Endpoint)
    on_exit(fn -> Application.delete_env(:jido_claw, :admin_emails) end)
    Application.delete_env(:jido_claw, :admin_emails)
    :ok
  end

  test "unauthenticated GET /admin redirects to sign-in" do
    conn = get(build_conn(), "/admin")

    assert redirected_to(conn) == "/sign-in"
  end

  test "signed-in non-admin GET /admin gets a 404" do
    user = register_user!()

    conn =
      user
      |> signed_in_conn()
      |> get("/admin")

    assert response(conn, 404) == "Not Found"
  end

  test "allowlisted admin GET /admin renders AshAdmin" do
    user = register_user!()
    Application.put_env(:jido_claw, :admin_emails, [to_string(user.email)])

    conn =
      user
      |> signed_in_conn()
      |> get("/admin")

    assert html_response(conn, 200) =~ "phx-"
  end

  test ":live_admin_required halts a signed-in non-admin with a redirect to /dashboard" do
    user = register_user!()
    session = session_for(user)

    assert {:halt, socket} =
             LiveUserAuth.on_mount(
               :live_admin_required,
               %{},
               session,
               %Phoenix.LiveView.Socket{}
             )

    assert {:redirect, %{to: "/dashboard"}} = socket.redirected
  end

  test ":live_admin_required continues for an allowlisted admin" do
    user = register_user!()
    Application.put_env(:jido_claw, :admin_emails, [to_string(user.email)])
    session = session_for(user)

    assert {:cont, socket} =
             LiveUserAuth.on_mount(
               :live_admin_required,
               %{},
               session,
               %Phoenix.LiveView.Socket{}
             )

    assert to_string(socket.assigns.current_user.email) == to_string(user.email)
  end

  defp register_user! do
    password = "valid-password-123456"

    {:ok, user} =
      User.register_with_password(
        %{
          email: "admin-route-#{System.unique_integer([:positive])}@example.com",
          password: password,
          password_confirmation: password
        },
        authorize?: false
      )

    user
  end

  defp signed_in_conn(user) do
    build_conn()
    |> init_test_session(%{})
    |> Helpers.store_in_session(user)
  end

  defp session_for(user) do
    user
    |> signed_in_conn()
    |> Plug.Conn.get_session()
  end
end
