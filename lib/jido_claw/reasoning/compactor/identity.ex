defmodule JidoClaw.Reasoning.Compactor.Identity do
  @moduledoc """
  Resolves the durable **compaction identity** for a message /
  `RequestCorrelation` row, kept deliberately separate from the
  runtime/trace `agent_id`.

  The runtime `agent_id` (`tool_context.agent_id`) is `"main"` for the REPL
  main, `"session:<uuid>"` for the chat main, `"handoff:<uuid>:<tpl>"` for a
  routed worker, and an opaque tag for a spawned sub-agent. Traces, the
  `AgentTracker`, and the Jido registry key on it unchanged.

  The compaction identity collapses *both* main surfaces onto `"main"` so a
  session's durable main-agent slice is keyed consistently, while keeping
  handoff workers and spawned sub-agents under their own ids:

      resolve(agent_template, agent_id, session_id) =
        cond do
          agent_template == "main" -> "main"   # REPL main
          true                     -> agent_id  # handoff worker / sub-agent
        end

  This is the single source of truth: every register site
  (`JidoClaw.register_correlation/6`, the REPL) stamps the resolved id onto
  the `RequestCorrelation` row, and `JidoClaw.Reasoning.Compactor` derives
  the same id from `tool_context` — so *stored == derived*.

  Main chat turns carry the explicit `"main"` template, so their opaque
  runtime id does not affect the durable compaction key. The equality clause
  remains for rows written by pre-v0.6.4 runtimes.
  """

  @main "main"

  @doc "The canonical compaction id for the main agent."
  @spec main() :: String.t()
  def main, do: @main

  @doc """
  Resolve the compaction identity from a routed template, runtime agent id,
  and runtime session id. See the module doc for the rule.
  """
  @spec resolve(String.t() | nil, String.t() | nil, String.t() | nil) :: String.t() | nil
  def resolve(@main, _agent_id, _session_id), do: @main

  def resolve(_agent_template, agent_id, session_id)
      when is_binary(agent_id) and is_binary(session_id) and agent_id == session_id,
      do: @main

  def resolve(_agent_template, agent_id, _session_id), do: agent_id
end
