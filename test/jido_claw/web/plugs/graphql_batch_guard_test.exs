defmodule JidoClaw.Web.Plugs.GraphqlBatchGuardTest do
  @moduledoc """
  Unit coverage for the transport-batch guard: every batch ingress vector
  Absinthe.Plug would parse (`_json` array body, binary `_json` query
  param, `operations` as query or body param) halts 400 on key PRESENCE
  alone, while single-request shapes — including an unfetched body — pass
  untouched.
  """
  use ExUnit.Case, async: true

  alias JidoClaw.Web.Plugs.GraphqlBatchGuard

  defp call(conn), do: GraphqlBatchGuard.call(conn, GraphqlBatchGuard.init([]))

  defp assert_halted_400(conn) do
    assert conn.halted
    assert conn.status == 400
    assert Jason.decode!(conn.resp_body) == %{"error" => "batching_not_supported"}
  end

  test "a plain POST with a single query in body params passes" do
    conn =
      :post
      |> Plug.Test.conn("/gql", %{"query" => "{ __typename }", "variables" => %{}})
      |> call()

    refute conn.halted
  end

  test "a GET ?query= single request passes" do
    conn =
      :get
      |> Plug.Test.conn("/gql?query={__typename}")
      |> call()

    refute conn.halted
  end

  test "an unfetched body passes (Unfetched counts as no keys)" do
    conn = Plug.Test.conn(:get, "/gql")

    assert %Plug.Conn.Unfetched{} = conn.body_params
    refute call(conn).halted
  end

  test "a _json list in body params halts (JSON array body vector)" do
    conn =
      :post
      |> Plug.Test.conn("/gql", %{"_json" => [%{"query" => "{ __typename }"}]})
      |> call()

    assert_halted_400(conn)
  end

  test "a binary _json query param halts (absinthe decodes it itself)" do
    encoded = URI.encode_www_form(~s|[{"query":"{__typename}"}]|)

    conn =
      :get
      |> Plug.Test.conn("/gql?_json=#{encoded}")
      |> call()

    assert_halted_400(conn)
  end

  test "an operations query param halts, value shape unchecked" do
    conn =
      :get
      |> Plug.Test.conn("/gql?operations=not-even-json")
      |> call()

    assert_halted_400(conn)
  end

  test "an operations body param halts (multipart field vector)" do
    conn =
      :post
      |> Plug.Test.conn("/gql", %{"operations" => ~s|[{"query":"{__typename}"}]|, "map" => "{}"})
      |> call()

    assert_halted_400(conn)
  end
end
