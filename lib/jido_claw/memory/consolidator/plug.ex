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

  # Attempt-bound capability routes (docs/system/forge-session-resume.md):
  # each CLI invocation's client config names `/run/<run_id>/a/<attempt_token>`,
  # and the token is stamped into assigns so the shared tool dispatcher can
  # validate EVERY call against the run's single open attempt. The tokenless
  # routes below stay routable but carry no token — the RunServer's central
  # validation refuses them, so an old-shape client fails CLOSED.
  match "/run/:run_id/a/:attempt_token" do
    forward_with_attempt(conn, attempt_token)
  end

  match "/run/:run_id/a/:attempt_token/*_rest" do
    forward_with_attempt(conn, attempt_token)
  end

  match "/run/:run_id" do
    forward_run(conn)
  end

  match "/run/:run_id/*_rest" do
    forward_run(conn)
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  defp forward_with_attempt(conn, attempt_token) do
    conn
    |> Plug.Conn.assign(:consolidator_attempt_token, attempt_token)
    |> forward_run()
  end

  defp forward_run(conn) do
    ScopedForward.call(conn,
      server: JidoClaw.Memory.Consolidator.MCPServer,
      assign_key: :consolidator_run_id,
      path_param: "run_id"
    )
  end
end
