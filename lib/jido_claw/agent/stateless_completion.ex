defmodule JidoClaw.Agent.StatelessCompletion do
  @moduledoc """
  Capability-minimal agent for stateless OpenAI-compatible completions.

  The gateway supplies the complete transcript on every request, so this agent
  is deliberately short-lived and has no native or external tools. Code- and
  system-shaped prompts stay synchronous prose completions; they cannot launch
  a durable composer or mutate the workspace that request teardown removes.
  """

  use JidoClaw.Agent.Defaults,
    name: "jido_claw_stateless_completion",
    description:
      "Answer the supplied ordered conversation directly. You have no tools and must not claim " <>
        "to have changed files, run commands, or started background work.",
    tools: [],
    model: :fast,
    max_iterations: 1,
    streaming: false,
    compaction: [mode: :auto]

  @doc "The structural capability surface for the stateless completion agent."
  @spec tool_modules() :: [module()]
  def tool_modules, do: Keyword.fetch!(strategy_opts(), :tools)
end
