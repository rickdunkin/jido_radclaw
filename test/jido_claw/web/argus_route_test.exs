defmodule JidoClaw.Web.ArgusRouteTest do
  @moduledoc """
  Route-level integration for the node-served argus SPA (argus P3): the
  `/argus` catch-all serves the built shell for the root and for deep links
  (client-side routes survive refresh), and a missing build gets an honest
  404 carrying the build hint — never a silent blank page.

  `async: false`: boots the shared Endpoint and mutates the
  `:argus_static_root` app env (the test seam — the real static root under
  `Application.app_dir/2` is shared state across the partitioned suite).
  """
  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  @endpoint JidoClaw.Web.Endpoint

  @shell ~s(<!doctype html><html><body><div id="root"></div></body></html>)

  setup do
    start_supervised!(JidoClaw.Web.Endpoint)
    previous = Application.fetch_env(:jido_claw, :argus_static_root)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:jido_claw, :argus_static_root, value)
        :error -> Application.delete_env(:jido_claw, :argus_static_root)
      end
    end)

    :ok
  end

  describe "with a build present" do
    @describetag :tmp_dir

    setup %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "index.html"), @shell)
      Application.put_env(:jido_claw, :argus_static_root, tmp_dir)
      :ok
    end

    test "GET /argus serves the shell, revalidated on every load" do
      conn = get(build_conn(), "/argus")

      assert conn.status == 200
      assert conn.resp_body == @shell
      assert [content_type] = Plug.Conn.get_resp_header(conn, "content-type")
      assert content_type =~ "text/html"
      # The shell references hashed assets a rebuild replaces (emptyOutDir),
      # so browsers must revalidate it — a cached stale shell would point at
      # deleted asset files.
      assert Plug.Conn.get_resp_header(conn, "cache-control") == ["no-cache"]
    end

    test "GET on a deep link serves the same shell (client-side routing)" do
      conn = get(build_conn(), "/argus/runs/0193d2b0-4d3e-7f10-b0d0-000000000000")

      assert conn.status == 200
      assert conn.resp_body == @shell
    end
  end

  describe "without a build" do
    @describetag :tmp_dir

    setup %{tmp_dir: tmp_dir} do
      Application.put_env(:jido_claw, :argus_static_root, tmp_dir)
      :ok
    end

    test "GET /argus is an honest 404 with the build hint" do
      conn = get(build_conn(), "/argus")

      assert conn.status == 404
      assert conn.resp_body =~ "mix ui.build"
    end
  end
end
