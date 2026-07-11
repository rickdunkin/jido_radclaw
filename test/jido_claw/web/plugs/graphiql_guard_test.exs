defmodule JidoClaw.Web.Plugs.GraphiqlGuardTest do
  @moduledoc """
  Unit coverage for the GraphiQL interface-only guard: only a bodyless,
  query-less HTML GET passes — every shape GraphiQL would EXECUTE (non-HTML
  requests, HTML GETs with `?query=`, requests carrying a body) halts 404
  before the forward.
  """
  use ExUnit.Case, async: true

  alias JidoClaw.Web.Plugs.GraphiqlGuard

  @html_accept "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"

  defp call(conn), do: GraphiqlGuard.call(conn, GraphiqlGuard.init([]))

  test "a plain HTML GET passes" do
    conn =
      :get
      |> Plug.Test.conn("/graphiql")
      |> Plug.Conn.put_req_header("accept", @html_accept)
      |> call()

    refute conn.halted
  end

  test "an HTML GET carrying ?query= halts (GraphiQL would execute it)" do
    conn =
      :get
      |> Plug.Test.conn("/graphiql?query={__schema{queryType{name}}}")
      |> Plug.Conn.put_req_header("accept", @html_accept)
      |> call()

    assert conn.halted
    assert conn.status == 404
  end

  test "any non-empty query string halts, document-shaped or not" do
    conn =
      :get
      |> Plug.Test.conn("/graphiql?foo=bar")
      |> Plug.Conn.put_req_header("accept", @html_accept)
      |> call()

    assert conn.halted
    assert conn.status == 404
  end

  test "a JSON-accept GET halts (GraphiQL falls through to Absinthe.Plug)" do
    conn =
      :get
      |> Plug.Test.conn("/graphiql")
      |> Plug.Conn.put_req_header("accept", "application/json")
      |> call()

    assert conn.halted
    assert conn.status == 404
  end

  test "an accept-less GET halts" do
    conn =
      :get
      |> Plug.Test.conn("/graphiql")
      |> call()

    assert conn.halted
    assert conn.status == 404
  end

  test "a POST halts even with an HTML accept" do
    conn =
      :post
      |> Plug.Test.conn("/graphiql", "")
      |> Plug.Conn.put_req_header("accept", @html_accept)
      |> call()

    assert conn.halted
    assert conn.status == 404
  end

  test "an HTML GET with a body halts — including without Content-Length" do
    # Plug.Test carries the raw body on the adapter; the guard proves
    # emptiness via read_body, never via a Content-Length header (which this
    # request never gets).
    conn =
      :get
      |> Plug.Test.conn("/graphiql", ~s|{"query":"{__typename}"}|)
      |> Plug.Conn.put_req_header("accept", @html_accept)
      |> call()

    assert [] = Plug.Conn.get_req_header(conn, "content-length")
    assert conn.halted
    assert conn.status == 404
  end
end
