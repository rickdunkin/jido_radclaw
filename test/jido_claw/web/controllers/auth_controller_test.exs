defmodule JidoClaw.Web.AuthControllerTest do
  @moduledoc """
  Auth-event emission coverage for `JidoClaw.Web.AuthController`.

  The controller calls `JidoClaw.Audit.AsyncWriter.cast/1` from
  `emit_auth_event/3` on every sign_in / sign_out path. These tests
  exercise both surfaces and assert exactly one `:auth_event` audit
  row appears per call under the `"default"` tenant.

  We drive the controller actions directly (rather than via the
  `Phoenix.ConnTest` bypass into the live endpoint) because the live
  router goes through ash_authentication strategies that need a fully
  configured `Accounts.User` row. The targeted assertion is on the
  audit-event emission, not on the auth strategy outcome — driving the
  action directly keeps the test focused on the producer contract.
  """
  use JidoClaw.TenantCase, async: false

  import Phoenix.ConnTest, only: [redirected_to: 1]

  alias AshAuthentication.Plug.Helpers
  alias JidoClaw.Accounts.User
  alias JidoClaw.Audit.Event
  alias JidoClaw.Tenants.Access
  alias JidoClaw.Tenants.Tenant
  alias JidoClaw.Web.AuthController
  alias JidoClaw.Web.AuthRateLimiter

  defmodule RaisingAccess do
    @moduledoc false
    @spec active?(String.t()) :: no_return()
    def active?(_tenant_id), do: raise(DBConnection.ConnectionError, "pool down")
  end

  setup do
    :ok = AuthRateLimiter.reset_all()
    # The controller emits under the literal "default" tenant
    # (`tenant_for_auth/0`). Ensure the FK parent exists so the
    # async write doesn't drop with a missing-tenant log.
    {:ok, _} = Tenant.ensure("default")

    # Snapshot the existing audit-row count under "default" so the
    # per-test assertions can use a delta rather than an absolute.
    {:ok, baseline_rows} = Event.read(tenant: "default", authorize?: false)
    initial_count = Enum.count(baseline_rows, &(&1.event_kind == :auth_event))
    {:ok, baseline: initial_count}
  end

  describe "sign_in failure path" do
    test "emits exactly one :auth_event audit row under the default tenant", %{
      baseline: baseline
    } do
      conn = build_post_conn(%{"email" => "missing@example.com", "password" => "wrong"})

      _ = AuthController.sign_in(conn, conn.params)

      :ok =
        eventually(fn ->
          {:ok, rows} = Event.read(tenant: "default", authorize?: false)
          delta = Enum.count(rows, &(&1.event_kind == :auth_event)) - baseline
          delta == 1
        end)

      {:ok, rows} = Event.read(tenant: "default", authorize?: false)
      auth_rows = Enum.filter(rows, &(&1.event_kind == :auth_event))
      [latest | _] = Enum.sort_by(auth_rows, & &1.inserted_at, {:desc, DateTime})

      assert latest.target_kind == :auth
      assert latest.target_id == "sign_in_failure"
      # Failed sign_in has no actor — controller maps nil actor_id to actor_kind: :system.
      assert latest.actor_kind == :system
      assert is_nil(latest.actor_id)
    end

    test "rate-limits repeated failures before password verification" do
      previous = Application.fetch_env(:jido_claw, :auth_rate_limit)

      Application.put_env(:jido_claw, :auth_rate_limit,
        window_ms: 60_000,
        max_attempts: 2,
        ip_max_attempts: 10
      )

      on_exit(fn ->
        :ok = AuthRateLimiter.reset_all()

        case previous do
          {:ok, value} -> Application.put_env(:jido_claw, :auth_rate_limit, value)
          :error -> Application.delete_env(:jido_claw, :auth_rate_limit)
        end
      end)

      params = %{"email" => "limited@example.com", "password" => "wrong"}

      assert AuthController.sign_in(build_post_conn(params), params).status == 302
      assert AuthController.sign_in(build_post_conn(params), params).status == 302

      limited = AuthController.sign_in(build_post_conn(params), params)
      assert limited.status == 429
      assert Plug.Conn.get_resp_header(limited, "retry-after") != []
      assert limited.resp_body == "Too many sign-in attempts. Try again later."
    end

    test "malformed and over-72-byte ASCII/multibyte credentials fail safely" do
      missing = AuthController.sign_in(build_post_conn(%{}), %{})
      assert missing.status == 302
      assert Phoenix.Flash.get(missing.assigns.flash, :error) == "Invalid email or password"

      oversized_email = %{
        "email" => String.duplicate("e", 321),
        "password" => "valid-shape-password"
      }

      rejected = AuthController.sign_in(build_post_conn(oversized_email), oversized_email)
      assert rejected.status == 302
      assert Phoenix.Flash.get(rejected.assigns.flash, :error) == "Invalid email or password"

      for password <- [String.duplicate("p", 73), String.duplicate("é", 37)] do
        assert String.length(password) <= 73
        assert byte_size(password) > 72

        params = %{"email" => "oversized@example.com", "password" => password}
        rejected = AuthController.sign_in(build_post_conn(params), params)

        assert rejected.status == 302
        assert Phoenix.Flash.get(rejected.assigns.flash, :error) == "Invalid email or password"
      end

      # Shape rejection happens before the limiter and password provider.
      assert :sys.get_state(AuthRateLimiter).buckets == %{}
    end
  end

  describe "sign_out path" do
    test "with no session user emits one :auth_event audit row (actor_kind: :system)", %{
      baseline: baseline
    } do
      conn = build_delete_conn(%{})

      _ = AuthController.sign_out(conn, conn.params)

      :ok =
        eventually(fn ->
          {:ok, rows} = Event.read(tenant: "default", authorize?: false)
          delta = Enum.count(rows, &(&1.event_kind == :auth_event)) - baseline
          delta == 1
        end)

      {:ok, rows} = Event.read(tenant: "default", authorize?: false)
      auth_rows = Enum.filter(rows, &(&1.event_kind == :auth_event))
      [latest | _] = Enum.sort_by(auth_rows, & &1.inserted_at, {:desc, DateTime})

      assert latest.target_kind == :auth
      assert latest.target_id == "sign_out"
      assert latest.actor_kind == :system
      assert latest.payload["actor_valid"] == false
      assert is_nil(latest.payload["tenant_status_at_signout"])
    end

    test "resolves the actor from the SESSION and records server-derived fields", %{
      baseline: baseline
    } do
      # The /auth scope has no auth plug, so assigns never carry a user —
      # the actor must come from the session token itself.
      user = register_user!()
      :ok = Access.ensure_active(to_string(user.id))

      # A falsified reason against a demonstrably ACTIVE tenant: the client
      # claim is recorded verbatim as untrusted `requested_reason`, while the
      # authoritative state is derived server-side.
      conn = signed_in_delete_conn(user, %{"reason" => "account_unavailable"})

      result = AuthController.sign_out(conn, conn.params)

      assert redirected_to(result) == "/sign-in"
      assert Plug.Conn.get_session(result) == %{}

      :ok =
        eventually(fn ->
          {:ok, rows} = Event.read(tenant: "default", authorize?: false)
          delta = Enum.count(rows, &(&1.event_kind == :auth_event)) - baseline
          delta == 1
        end)

      {:ok, rows} = Event.read(tenant: "default", authorize?: false)
      auth_rows = Enum.filter(rows, &(&1.event_kind == :auth_event))
      [latest | _] = Enum.sort_by(auth_rows, & &1.inserted_at, {:desc, DateTime})

      assert latest.actor_kind == :user
      assert latest.actor_id == to_string(user.id)
      assert latest.target_id == "sign_out"
      assert latest.payload["requested_reason"] == "account_unavailable"
      assert latest.payload["tenant_status_at_signout"] == "active"
      assert latest.payload["actor_valid"] == true
    end

    test "an un-allowlisted reason is recorded as nil", %{baseline: baseline} do
      conn = build_delete_conn(%{"reason" => "made-up-injection"})

      _ = AuthController.sign_out(conn, conn.params)

      :ok =
        eventually(fn ->
          {:ok, rows} = Event.read(tenant: "default", authorize?: false)
          delta = Enum.count(rows, &(&1.event_kind == :auth_event)) - baseline
          delta == 1
        end)

      {:ok, rows} = Event.read(tenant: "default", authorize?: false)
      auth_rows = Enum.filter(rows, &(&1.event_kind == :auth_event))
      [latest | _] = Enum.sort_by(auth_rows, & &1.inserted_at, {:desc, DateTime})

      assert is_nil(latest.payload["requested_reason"])
      refute inspect(latest.payload) =~ "made-up-injection"
    end

    test "a tenant-lookup failure maps to \"unavailable\" and never blocks the clear", %{
      baseline: baseline
    } do
      user = register_user!()
      Application.put_env(:jido_claw, :tenant_access_module, RaisingAccess)
      on_exit(fn -> Application.delete_env(:jido_claw, :tenant_access_module) end)

      conn = signed_in_delete_conn(user, %{})
      result = AuthController.sign_out(conn, conn.params)

      # The DB failure degraded the audit field — the sign-out itself and the
      # session clear are untouched.
      assert redirected_to(result) == "/sign-in"
      assert Plug.Conn.get_session(result) == %{}

      :ok =
        eventually(fn ->
          {:ok, rows} = Event.read(tenant: "default", authorize?: false)
          delta = Enum.count(rows, &(&1.event_kind == :auth_event)) - baseline
          delta == 1
        end)

      {:ok, rows} = Event.read(tenant: "default", authorize?: false)
      auth_rows = Enum.filter(rows, &(&1.event_kind == :auth_event))
      [latest | _] = Enum.sort_by(auth_rows, & &1.inserted_at, {:desc, DateTime})

      assert latest.actor_id == to_string(user.id)
      assert latest.payload["tenant_status_at_signout"] == "unavailable"
    end
  end

  defp build_post_conn(params) do
    Phoenix.ConnTest.build_conn(:post, "/sign-in", params)
    |> Plug.Test.init_test_session(%{})
    |> Phoenix.Controller.fetch_flash()
  end

  defp build_delete_conn(params) do
    Plug.Test.init_test_session(Phoenix.ConnTest.build_conn(:delete, "/sign-out", params), %{})
  end

  defp signed_in_delete_conn(user, params) do
    params
    |> build_delete_conn()
    |> Helpers.store_in_session(user)
  end

  defp register_user! do
    password = "valid-password-123456"

    {:ok, user} =
      User.register_with_password(
        %{
          email: "auth-controller-#{System.unique_integer([:positive])}@example.com",
          password: password,
          password_confirmation: password
        },
        authorize?: false
      )

    user
  end

  defp eventually(fun, deadline_ms \\ 1_500) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    do_eventually(fun, deadline)
  end

  defp do_eventually(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        ExUnit.Assertions.flunk("eventually condition not met within timeout")

      true ->
        Process.sleep(20)
        do_eventually(fun, deadline)
    end
  end
end
