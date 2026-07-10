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
  alias JidoClaw.Tenants.Access
  alias JidoClaw.Tenants.Tenant
  alias JidoClaw.Web.LiveUserAuth
  alias JidoClaw.Web.SetupStatusCache

  @endpoint JidoClaw.Web.Endpoint

  defmodule SetupWizardStub do
    @moduledoc false

    @spec run() :: map()
    def run do
      %{
        prerequisites: %{},
        credentials: %{},
        database: %{ok?: true, status: "connected"},
        ready?: true,
        has_ai_provider?: true
      }
    end
  end

  setup do
    start_supervised!(JidoClaw.Web.Endpoint)
    previous_wizard = Application.fetch_env(:jido_claw, :setup_wizard_impl)

    on_exit(fn ->
      Application.delete_env(:jido_claw, :admin_emails)

      case previous_wizard do
        {:ok, value} -> Application.put_env(:jido_claw, :setup_wizard_impl, value)
        :error -> Application.delete_env(:jido_claw, :setup_wizard_impl)
      end

      SetupStatusCache.reset()
    end)

    Application.delete_env(:jido_claw, :admin_emails)
    Application.put_env(:jido_claw, :setup_wizard_impl, SetupWizardStub)
    :ok = SetupStatusCache.reset()
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

  test "unauthenticated GET /setup redirects to sign-in" do
    conn = get(build_conn(), "/setup")
    assert redirected_to(conn) == "/sign-in"
  end

  test "signed-in non-admin GET /setup gets a 404" do
    user = register_user!()

    conn =
      user
      |> signed_in_conn()
      |> get("/setup")

    assert response(conn, 404) == "Not Found"
  end

  test "allowlisted admin GET /setup renders the diagnostic wizard" do
    user = register_user!()
    Application.put_env(:jido_claw, :admin_emails, [to_string(user.email)])

    conn =
      user
      |> signed_in_conn()
      |> get("/setup")

    assert html_response(conn, 200) =~ "JidoClaw Setup"
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

  test ":live_user_required halts a signed-in user whose tenant is suspended" do
    user = register_user!()
    tenant_id = to_string(user.id)
    :ok = Access.ensure_active(tenant_id)
    {:ok, tenant} = Tenant.by_id(tenant_id)
    {:ok, _suspended} = Tenant.suspend(tenant)

    assert {:halt, socket} =
             LiveUserAuth.on_mount(
               :live_user_required,
               %{},
               session_for(user),
               %Phoenix.LiveView.Socket{}
             )

    # Forced sign-out landing, NOT /sign-in: on_mount cannot clear the Plug
    # session, so a /sign-in redirect looped forever for suspended tenants.
    assert {:redirect, %{to: "/auth/account-unavailable?reason=account_unavailable"}} =
             socket.redirected
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
