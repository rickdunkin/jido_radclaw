defmodule JidoClaw.Memory.Consolidator.Plug do
  @moduledoc """
  Per-run HTTP front-door for the consolidator's MCP server.

  Routes `/run/:run_id/*` through `JidoClaw.MCP.ScopedForward`, which stamps
  the run id into `conn.assigns` and lazily initialises Anubis's
  streamable-HTTP plug at request time. Eager init at compile time doesn't
  work because Anubis's plug looks up the server's session config via
  `:persistent_term`, and the server hasn't started yet when this module
  compiles.
  """

  use Plug.Router

  alias JidoClaw.MCP.ScopedForward

  plug(:match)
  plug(:dispatch)

  match "/run/:run_id" do
    ScopedForward.call(conn,
      server: JidoClaw.Memory.Consolidator.MCPServer,
      assign_key: :consolidator_run_id,
      path_param: "run_id"
    )
  end

  match "/run/:run_id/*_rest" do
    ScopedForward.call(conn,
      server: JidoClaw.Memory.Consolidator.MCPServer,
      assign_key: :consolidator_run_id,
      path_param: "run_id"
    )
  end

  match _ do
    send_resp(conn, 404, "not found")
  end
end
