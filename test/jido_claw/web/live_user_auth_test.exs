defmodule JidoClaw.Web.LiveUserAuthTest do
  @moduledoc """
  Mount-hook outcome split + the two landing pages.

  Hook-level tests drive `on_mount/4` directly with the two app-env seams
  (`:session_user_resolver`, `:tenant_access_module` — the
  `:cluster_leader_module` precedent), so infrastructure branches never need
  a broken PostgreSQL under the SQL sandbox. Route-level tests boot the real
  endpoint and pin the landing pages' security properties: the forced
  sign-out is an explicit-click CSRF DELETE form (never auto-submitted),
  and the 503 page preserves the session.
  """
  use JidoClaw.TenantCase, async: false

  import Phoenix.ConnTest

  alias AshAuthentication.Plug.Helpers
  alias JidoClaw.Accounts.User
  alias JidoClaw.Tenants.Access
  alias JidoClaw.Tenants.Tenant
  alias JidoClaw.Web.LiveUserAuth

  @endpoint JidoClaw.Web.Endpoint

  @hooks [:live_user_optional, :live_user_required, :live_admin_required, :live_no_user]

  defmodule ResolverError do
    @moduledoc false
    @spec resolve(map()) :: {:error, DBConnection.ConnectionError.t()}
    def resolve(_session), do: {:error, %DBConnection.ConnectionError{message: "tcp closed"}}
  end

  defmodule ResolverOkNil do
    @moduledoc false
    # A broken-resolver shape that authenticates without an actor shape —
    # drives the defensive `_invalid_actor` branch (unreachable through the
    # real `Actor.build/1`, which always derives a tenant for a real user).
    @spec resolve(map()) :: {:ok, nil}
    def resolve(_session), do: {:ok, nil}
  end

  defmodule AccessError do
    @moduledoc false
    @spec ensure_active(String.t()) :: {:error, DBConnection.ConnectionError.t()}
    def ensure_active(_tenant_id), do: {:error, %DBConnection.ConnectionError{message: "down"}}
  end

  describe "auth-lookup infrastructure errors are a 503 on every hook" do
    setup do
      Application.put_env(:jido_claw, :session_user_resolver, ResolverError)
      on_exit(fn -> Application.delete_env(:jido_claw, :session_user_resolver) end)
      :ok
    end

    for hook <- @hooks do
      test "#{hook} halts to /service-unavailable" do
        assert {:halt, socket} =
                 LiveUserAuth.on_mount(unquote(hook), %{}, %{}, %Phoenix.LiveView.Socket{})

        assert {:redirect, %{to: "/service-unavailable"}} = socket.redirected
      end
    end
  end

  describe "activity-check outcomes" do
    test "an activity-check infrastructure error halts to /service-unavailable" do
      user = register_user!()
      Application.put_env(:jido_claw, :tenant_access_module, AccessError)
      on_exit(fn -> Application.delete_env(:jido_claw, :tenant_access_module) end)

      assert {:halt, socket} =
               LiveUserAuth.on_mount(
                 :live_user_required,
                 %{},
                 session_for(user),
                 %Phoenix.LiveView.Socket{}
               )

      assert {:redirect, %{to: "/service-unavailable"}} = socket.redirected
    end

    test "first mount provisions the tenant row and continues" do
      user = register_user!()
      tenant_id = to_string(user.id)
      assert {:ok, nil} = Tenant.by_id(tenant_id, not_found_error?: false)

      assert {:cont, socket} =
               LiveUserAuth.on_mount(
                 :live_user_required,
                 %{},
                 session_for(user),
                 %Phoenix.LiveView.Socket{}
               )

      assert socket.assigns.current_user.id == user.id
      assert {:ok, %Tenant{status: :active}} = Tenant.by_id(tenant_id)
    end

    test "an authenticated resolution without an actor shape forces the sign-out landing" do
      Application.put_env(:jido_claw, :session_user_resolver, ResolverOkNil)
      on_exit(fn -> Application.delete_env(:jido_claw, :session_user_resolver) end)

      assert {:halt, socket} =
               LiveUserAuth.on_mount(:live_user_required, %{}, %{}, %Phoenix.LiveView.Socket{})

      assert {:redirect, %{to: "/auth/account-unavailable?reason=invalid_actor"}} =
               socket.redirected
    end

    test "an unauthenticated session still redirects to /sign-in" do
      assert {:halt, socket} =
               LiveUserAuth.on_mount(:live_user_required, %{}, %{}, %Phoenix.LiveView.Socket{})

      assert {:redirect, %{to: "/sign-in"}} = socket.redirected
    end
  end

  describe "landing pages (real endpoint)" do
    setup do
      start_supervised!(JidoClaw.Web.Endpoint)
      :ok
    end

    test "GET /auth/account-unavailable renders an explicit-click CSRF DELETE form" do
      conn = get(build_conn(), "/auth/account-unavailable?reason=account_unavailable")
      body = html_response(conn, 200)

      assert body =~ ~s(action="/auth/sign-out")
      assert body =~ "_csrf_token"
      assert body =~ ~r/name="_method"[^>]*value="delete"/
      assert body =~ ~r/<button type="submit"[^>]*>\s*Sign out\s*<\/button>/
      assert body =~ ~s(name="reason" value="account_unavailable")

      # Explicit click ONLY — an auto-submitting page would mint its own valid
      # CSRF token and fire the protected DELETE on mere navigation.
      refute body =~ "submit()"
      refute body =~ "requestSubmit"
      refute body =~ ~r/<script[^>]*>[^<]*submit/i
    end

    test "an un-allowlisted reason is never echoed into the form" do
      conn = get(build_conn(), "/auth/account-unavailable?reason=evil-injected-value")
      body = html_response(conn, 200)

      refute body =~ "evil-injected-value"
      refute body =~ ~s(name="reason")
    end

    test "submitting the sign-out form clears the session (redirect-loop regression)" do
      user = register_user!()
      :ok = Access.ensure_active(to_string(user.id))

      # Signed in: /sign-in bounces to the dashboard (live_no_user).
      signed_in = get(signed_in_conn(user), "/sign-in")
      assert redirected_to(signed_in) == "/dashboard"

      # Real form flow: render the landing page, lift its CSRF token, submit.
      landing = get(recycle(signed_in), "/auth/account-unavailable?reason=account_unavailable")
      body = html_response(landing, 200)
      [_, csrf_token] = Regex.run(~r/name="_csrf_token"[^>]*value="([^"]+)"/, body)

      signed_out =
        landing
        |> recycle()
        |> delete("/auth/sign-out", %{
          "_csrf_token" => csrf_token,
          "reason" => "account_unavailable"
        })

      assert redirected_to(signed_out) == "/sign-in"

      # The loop regression: a signed-out browser can now REACH /sign-in.
      after_sign_out = get(recycle(signed_out), "/sign-in")
      assert html_response(after_sign_out, 200)
    end

    test "GET /service-unavailable answers 503 and preserves the session" do
      user = register_user!()
      :ok = Access.ensure_active(to_string(user.id))

      unavailable = get(signed_in_conn(user), "/service-unavailable")
      assert response(unavailable, 503) =~ "Temporarily unavailable"

      # Still authenticated afterwards — no mass-logout on a DB blip.
      dashboard = get(recycle(unavailable), "/dashboard")
      assert html_response(dashboard, 200)
    end
  end

  defp register_user! do
    password = "valid-password-123456"

    {:ok, user} =
      User.register_with_password(
        %{
          email: "live-user-auth-#{System.unique_integer([:positive])}@example.com",
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

  defp session_for(user) do
    user
    |> signed_in_conn()
    |> Plug.Conn.get_session()
  end
end
