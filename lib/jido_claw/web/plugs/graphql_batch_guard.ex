defmodule JidoClaw.Web.Plugs.GraphqlBatchGuard do
  @moduledoc """
  Rejects GraphQL **transport batching** on `/gql` before anything executes.

  `Absinthe.Plug` natively parses three batch ingress vectors: a JSON
  **array body** (Plug.Parsers stores it as `body_params["_json"]`), an
  **`operations` param** (query string or multipart field — absinthe
  converts it to `_json` and JSON-decodes it), and a **binary `_json`
  query param** it JSON-decodes itself. The `/gql` forward's
  complexity/token limits are threaded into each batch element's OWN
  pipeline, so N individually-cheap queries ride one request with
  unbounded aggregate cost. No legitimate consumer batches (GraphiQL and
  the argus client post single objects), so the surface rejects batching
  outright rather than growing an aggregate-cap knob.

  Detection is **presence-based and value-type-blind**: a `"_json"` or
  `"operations"` key anywhere in `conn.params` or `conn.body_params`
  halts 400 `{"error": "batching_not_supported"}` (flat JSON, the
  tenant-gate shape) no matter the value — a list, a binary absinthe
  would later decode, or junk all halt, so the guard never replicates
  absinthe's decode and fails closed. Legitimate single requests
  (`query`/`variables`/`operationName` bodies, or GET `?query=`) never
  carry either key. Unfetched param sets count as no-keys.
  """

  import Plug.Conn

  @behaviour Plug

  @batch_keys ["_json", "operations"]

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    conn = fetch_query_params(conn)

    if batch_key?(conn.params) or batch_key?(conn.body_params) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(400, Jason.encode!(%{error: "batching_not_supported"}))
      |> halt()
    else
      conn
    end
  end

  defp batch_key?(%Plug.Conn.Unfetched{}), do: false

  defp batch_key?(params) when is_map(params) do
    Enum.any?(@batch_keys, &Map.has_key?(params, &1))
  end
end
