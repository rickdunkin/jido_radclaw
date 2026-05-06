defmodule JidoClaw.Memory.Consolidator.Plug.RunForward do
  @moduledoc """
  Plug shim that stamps the run id into `conn.assigns` before
  delegating to Anubis's streamable-HTTP plug. Anubis copies
  `conn.assigns` onto the MCP frame, where tool handlers read
  `consolidator_run_id` from `frame.assigns`.

  Init is lazy — Anubis's plug looks up the server's session config
  via `:persistent_term` at init time, which only works after the
  server has started. We defer the init to request time.
  """

  @behaviour Plug

  alias Anubis.Server.Transport.StreamableHTTP.Plug, as: AnubisPlug

  def init(opts), do: opts

  def call(conn, opts) do
    run_id = conn.path_params["run_id"]
    conn = Plug.Conn.assign(conn, :consolidator_run_id, run_id)
    AnubisPlug.call(conn, AnubisPlug.init(opts))
  end
end
