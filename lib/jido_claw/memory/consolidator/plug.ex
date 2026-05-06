defmodule JidoClaw.Memory.Consolidator.Plug do
  @moduledoc """
  Per-run HTTP front-door for the consolidator's MCP server.

  Routes `/run/:run_id/*` through `RunForward`, which stamps the run
  id into `conn.assigns` and lazily initialises Anubis's
  streamable-HTTP plug at request time. Eager init at compile time
  doesn't work because Anubis's plug looks up the server's session
  config via `:persistent_term`, and the server hasn't started yet
  when this module compiles.
  """

  use Plug.Router

  plug(:match)
  plug(:dispatch)

  match "/run/:run_id" do
    JidoClaw.Memory.Consolidator.Plug.RunForward.call(conn,
      server: JidoClaw.Memory.Consolidator.MCPServer
    )
  end

  match "/run/:run_id/*_rest" do
    JidoClaw.Memory.Consolidator.Plug.RunForward.call(conn,
      server: JidoClaw.Memory.Consolidator.MCPServer
    )
  end

  match _ do
    send_resp(conn, 404, "not found")
  end
end
