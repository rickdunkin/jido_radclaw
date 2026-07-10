defmodule JidoClaw.Web.Plugs.RequireAuthTest do
  @moduledoc """
  Route-level coverage for the `RequireAuth` HTTP plug's outcome split: an
  unauthenticated browser still redirects to `/sign-in`, but an
  auth-lookup infrastructure failure answers a direct 503 with the session
  untouched — the plug must never guess "signed out" on a DB outage.
  """
  use JidoClaw.TenantCase, async: false

  import Phoenix.ConnTest

  alias AshAuthentication.Plug.Helpers
  alias JidoClaw.Accounts.User
  alias JidoClaw.Tenants.Access

  @endpoint JidoClaw.Web.Endpoint

  defmodule ResolverError do
    @moduledoc false
    @spec resolve(map()) :: {:error, DBConnection.ConnectionError.t()}
    def resolve(_session), do: {:error, %DBConnection.ConnectionError{message: "tcp closed"}}
  end

  setup do
    start_supervised!(JidoClaw.Web.Endpoint)
    :ok
  end

  test "unauthenticated requests still redirect to /sign-in" do
    conn = get(build_conn(), "/admin")
    assert redirected_to(conn) == "/sign-in"
  end

  test "an auth-lookup infrastructure failure answers 503 and preserves the session" do
    user = register_user!()
    :ok = Access.ensure_active(to_string(user.id))
    signed_in = signed_in_conn(user)

    Application.put_env(:jido_claw, :session_user_resolver, ResolverError)
    on_exit(fn -> Application.delete_env(:jido_claw, :session_user_resolver) end)

    unavailable = get(signed_in, "/admin")
    assert response(unavailable, 503) =~ "temporarily unavailable"

    # Restore the resolver: the untouched session still authenticates.
    Application.delete_env(:jido_claw, :session_user_resolver)
    dashboard = get(recycle(unavailable), "/dashboard")
    assert html_response(dashboard, 200)
  end

  defp register_user! do
    password = "valid-password-123456"

    {:ok, user} =
      User.register_with_password(
        %{
          email: "require-auth-#{System.unique_integer([:positive])}@example.com",
          password: password,
          password_confirmation: password
        },
        authorize?: false
      )

    user
  end

  defp signed_in_conn(user) do
    build_conn()
    |> Plug.Test.init_test_session(%{})
    |> Helpers.store_in_session(user)
  end
end
