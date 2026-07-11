defmodule JidoClaw.Web.Plugs.GraphiqlGuard do
  @moduledoc """
  Interface-only guard in front of `Absinthe.Plug.GraphiQL` (dev/test).

  GraphiQL is not render-only: it executes GraphQL documents itself on BOTH
  non-HTML requests (it falls through to `Absinthe.Plug.call/2`) AND HTML
  GETs carrying a document (`?query=...` — only document-less HTML requests
  render the interface). An unauthenticated `/graphiql` mount without this
  guard is therefore a full query-execution hole beside the authenticated
  `/gql` surface.

  The guard passes ONLY a request that can do nothing but render the
  interface: `GET` ∧ first Accept header contains `text/html` (mirroring
  GraphiQL's own `html?/1`, which reads only the first header) ∧ empty query
  string ∧ **literally empty body**. The body is proven empty via a bounded
  `Plug.Conn.read_body/2` — Content-Length absence proves nothing (chunked
  requests omit it), and `Plug.Parsers` never consumes GET bodies, so a raw
  body could otherwise smuggle a document. Everything else halts 404 before
  GraphiQL can parse anything.
  """

  import Plug.Conn

  @behaviour Plug

  # Any body content at all fails the guard; 8 bytes is plenty to prove
  # non-emptiness without buffering a real payload.
  @body_probe_bytes 8

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    if conn.method == "GET" and html_accept?(conn) and conn.query_string == "" do
      probe_body(conn)
    else
      halt_not_found(conn)
    end
  end

  defp probe_body(conn) do
    case read_body(conn, length: @body_probe_bytes) do
      # Pass the RETURNED conn onward — its adapter has consumed the (empty)
      # body; reusing the pre-read conn would hand GraphiQL stale state.
      {:ok, "", conn} -> conn
      {:ok, _nonempty, conn} -> halt_not_found(conn)
      {:more, _partial, conn} -> halt_not_found(conn)
      {:error, _reason} -> halt_not_found(conn)
    end
  end

  defp html_accept?(conn) do
    case get_req_header(conn, "accept") do
      [first | _] -> String.contains?(first, "text/html")
      [] -> false
    end
  end

  defp halt_not_found(conn) do
    conn
    |> send_resp(404, "Not Found")
    |> halt()
  end
end
