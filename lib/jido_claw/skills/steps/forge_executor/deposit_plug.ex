defmodule JidoClaw.Skills.Steps.ForgeExecutor.DepositPlug do
  @moduledoc """
  Per-step HTTP front-door for the executor deposit MCP server.

  Routes `/deposit/:ref/*` through `JidoClaw.MCP.ScopedForward`, which stamps
  the deposit ref into `conn.assigns` and lazily initialises Anubis's
  streamable-HTTP plug at request time (the consolidator plug's shape and
  rationale — the server hasn't started when this module compiles).
  """

  use Plug.Router

  alias JidoClaw.MCP.ScopedForward

  plug(:match)
  plug(:dispatch)

  match "/deposit/:ref" do
    ScopedForward.call(conn,
      server: JidoClaw.Skills.Steps.ForgeExecutor.DepositServer,
      assign_key: :executor_deposit_ref,
      path_param: "ref"
    )
  end

  match "/deposit/:ref/*_rest" do
    ScopedForward.call(conn,
      server: JidoClaw.Skills.Steps.ForgeExecutor.DepositServer,
      assign_key: :executor_deposit_ref,
      path_param: "ref"
    )
  end

  match _ do
    send_resp(conn, 404, "not found")
  end
end
