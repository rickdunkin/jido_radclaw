defmodule JidoClaw.Web.Plugs.RequireAdminTest do
  @moduledoc """
  Drives `JidoClaw.Web.Plugs.RequireAdmin` directly (no router), using the
  `:admin_emails` Application env seam. Also covers the no-DB half of the
  `:live_admin_required` on_mount hook (empty session → sign-in redirect);
  the DB-backed halves live in `JidoClaw.Web.AdminRouteTest`.

  `async: false`: mutates the global `:admin_emails` Application env.
  """
  use ExUnit.Case, async: false

  import Plug.Conn

  alias JidoClaw.Web.LiveUserAuth
  alias JidoClaw.Web.Plugs.RequireAdmin

  setup do
    on_exit(fn -> Application.delete_env(:jido_claw, :admin_emails) end)
    Application.delete_env(:jido_claw, :admin_emails)
    :ok
  end

  defp conn_with_user(user) do
    :get
    |> Phoenix.ConnTest.build_conn("/admin", %{})
    |> assign(:current_user, user)
  end

  test "404s and halts when the allowlist is empty" do
    conn = RequireAdmin.call(conn_with_user(%{email: "a@b.com"}), RequireAdmin.init([]))

    assert conn.halted
    assert conn.status == 404
    assert conn.resp_body == "Not Found"
  end

  test "passes an allowlisted user through untouched" do
    Application.put_env(:jido_claw, :admin_emails, ["a@b.com"])
    conn = conn_with_user(%{email: "a@b.com"})

    assert RequireAdmin.call(conn, RequireAdmin.init([])) == conn
  end

  test "404s a non-allowlisted user" do
    Application.put_env(:jido_claw, :admin_emails, ["admin@b.com"])
    conn = RequireAdmin.call(conn_with_user(%{email: "other@b.com"}), RequireAdmin.init([]))

    assert conn.halted
    assert conn.status == 404
  end

  test "matches allowlist emails case-insensitively" do
    Application.put_env(:jido_claw, :admin_emails, [" Admin@Example.com "])
    conn = conn_with_user(%{email: "admin@EXAMPLE.com"})

    refute RequireAdmin.call(conn, RequireAdmin.init([])).halted
  end

  test "404s when there is no :current_user assign" do
    Application.put_env(:jido_claw, :admin_emails, ["a@b.com"])

    conn =
      :get
      |> Phoenix.ConnTest.build_conn("/admin", %{})
      |> RequireAdmin.call(RequireAdmin.init([]))

    assert conn.halted
    assert conn.status == 404
  end

  test ":live_admin_required halts an empty session with a redirect to sign-in" do
    assert {:halt, socket} =
             LiveUserAuth.on_mount(
               :live_admin_required,
               %{},
               %{},
               %Phoenix.LiveView.Socket{}
             )

    assert {:redirect, %{to: "/sign-in"}} = socket.redirected
  end
end
