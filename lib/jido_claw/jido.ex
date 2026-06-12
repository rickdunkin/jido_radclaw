defmodule JidoClaw.Jido do
  @moduledoc """
  Top-level Jido agent runtime entry for JidoClaw.

  Hooks the application into the Jido framework via `use Jido`, providing
  the agent supervision tree, signal routing, and skill plumbing that the
  rest of the system builds on. Started early in `JidoClaw.Application`'s
  core children list.
  """

  use Jido, otp_app: :jido_claw

  @doc """
  Start a short-lived sub-agent (spawned child, handoff worker, skill-step
  worker) with `restart: :temporary`.

  Mirrors `Jido.start_agent/3` (a child-spec build + `DynamicSupervisor.
  start_child` — keep in sync with the dep), except the restart strategy:
  `Jido.AgentServer.child_spec/1` hardcodes `restart: :permanent` and ignores
  an `opts[:restart]`, so a crashed-but-finished sub-agent would be
  resurrected by the supervisor as a new-pid orphan that nothing tracks or
  stops. `:temporary` makes a sub-agent death final — its lifecycle belongs
  to the tracker/caller, not the supervisor.

  Main/session agents (`JidoClaw.resolve_agent_pid/1`, the REPL) stay on
  `start_agent/2` (`:permanent`).
  """
  @spec start_subagent(module() | struct(), keyword()) :: DynamicSupervisor.on_start_child()
  def start_subagent(agent, opts \\ []) do
    child_spec =
      Supervisor.child_spec(
        {Jido.AgentServer, Keyword.merge(opts, agent: agent, jido: __MODULE__)},
        restart: :temporary
      )

    DynamicSupervisor.start_child(agent_supervisor_name(), child_spec)
  end
end
