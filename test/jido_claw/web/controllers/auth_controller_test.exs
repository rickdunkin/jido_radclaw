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

  alias JidoClaw.Audit.Event
  alias JidoClaw.Web.AuthController

  setup do
    # The controller emits under the literal "default" tenant
    # (`tenant_for_auth/0`). Ensure the FK parent exists so the
    # async write doesn't drop with a missing-tenant log.
    {:ok, _} = JidoClaw.Tenants.Tenant.ensure("default")

    # Snapshot the existing audit-row count under "default" so the
    # per-test assertions can use a delta rather than an absolute.
    {:ok, baseline_rows} = Event.read(tenant: "default")
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
          {:ok, rows} = Event.read(tenant: "default")
          delta = Enum.count(rows, &(&1.event_kind == :auth_event)) - baseline
          delta == 1
        end)

      {:ok, rows} = Event.read(tenant: "default")
      auth_rows = Enum.filter(rows, &(&1.event_kind == :auth_event))
      [latest | _] = Enum.sort_by(auth_rows, & &1.inserted_at, {:desc, DateTime})

      assert latest.target_kind == :auth
      assert latest.target_id == "sign_in_failure"
      # Failed sign_in has no actor — controller maps nil actor_id to actor_kind: :system.
      assert latest.actor_kind == :system
      assert is_nil(latest.actor_id)
    end
  end

  describe "sign_out path" do
    test "with no current_user emits one :auth_event audit row (actor_kind: :system)", %{
      baseline: baseline
    } do
      conn =
        build_delete_conn(%{})
        |> Plug.Conn.assign(:current_user, nil)

      _ = AuthController.sign_out(conn, conn.params)

      :ok =
        eventually(fn ->
          {:ok, rows} = Event.read(tenant: "default")
          delta = Enum.count(rows, &(&1.event_kind == :auth_event)) - baseline
          delta == 1
        end)

      {:ok, rows} = Event.read(tenant: "default")
      auth_rows = Enum.filter(rows, &(&1.event_kind == :auth_event))
      [latest | _] = Enum.sort_by(auth_rows, & &1.inserted_at, {:desc, DateTime})

      assert latest.target_kind == :auth
      assert latest.target_id == "sign_out"
      assert latest.actor_kind == :system
    end

    test "with a current_user emits one :auth_event with actor_kind: :user", %{
      baseline: baseline
    } do
      user_id = Ecto.UUID.generate()

      conn =
        build_delete_conn(%{})
        |> Plug.Conn.assign(:current_user, %{id: user_id})

      _ = AuthController.sign_out(conn, conn.params)

      :ok =
        eventually(fn ->
          {:ok, rows} = Event.read(tenant: "default")
          delta = Enum.count(rows, &(&1.event_kind == :auth_event)) - baseline
          delta == 1
        end)

      {:ok, rows} = Event.read(tenant: "default")
      auth_rows = Enum.filter(rows, &(&1.event_kind == :auth_event))
      [latest | _] = Enum.sort_by(auth_rows, & &1.inserted_at, {:desc, DateTime})

      assert latest.actor_kind == :user
      assert latest.actor_id == user_id
      assert latest.target_id == "sign_out"
    end
  end

  defp build_post_conn(params) do
    Phoenix.ConnTest.build_conn(:post, "/sign-in", params)
    |> Plug.Test.init_test_session(%{})
    |> Phoenix.Controller.fetch_flash()
  end

  defp build_delete_conn(params) do
    Phoenix.ConnTest.build_conn(:delete, "/sign-out", params)
    |> Plug.Test.init_test_session(%{})
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
