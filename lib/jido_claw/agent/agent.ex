defmodule JidoClaw.Agent do
  @moduledoc false
  use JidoClaw.Agent.Defaults,
    name: "jido_claw",
    description:
      "Terminal-based AI coding agent with swarm orchestration. Reads, writes, edits files, runs commands, manages git, and spawns child agents for parallel work.",
    tools: [
      # Core tools (10)
      JidoClaw.Tools.ReadFile,
      JidoClaw.Tools.WriteFile,
      JidoClaw.Tools.EditFile,
      JidoClaw.Tools.ListDirectory,
      JidoClaw.Tools.SearchCode,
      JidoClaw.Tools.RunCommand,
      JidoClaw.Tools.GitStatus,
      JidoClaw.Tools.GitDiff,
      JidoClaw.Tools.GitCommit,
      JidoClaw.Tools.ProjectInfo,
      # Swarm tools (5)
      JidoClaw.Tools.SpawnAgent,
      JidoClaw.Tools.ListAgents,
      JidoClaw.Tools.GetAgentResult,
      JidoClaw.Tools.SendToAgent,
      JidoClaw.Tools.KillAgent,
      # Skills tools (1)
      JidoClaw.Tools.RunSkill,
      # Memory tools (3)
      JidoClaw.Tools.Remember,
      JidoClaw.Tools.Recall,
      JidoClaw.Tools.Forget,
      # Solutions tools (4)
      JidoClaw.Tools.StoreSolution,
      JidoClaw.Tools.FindSolution,
      JidoClaw.Tools.NetworkShare,
      JidoClaw.Tools.NetworkStatus,
      # Browser tools (1)
      JidoClaw.Tools.BrowseWeb,
      # Reasoning tools (3)
      JidoClaw.Tools.Reason,
      JidoClaw.Tools.RunPipeline,
      JidoClaw.Tools.VerifyCertificate,
      # Scheduling tools (3)
      JidoClaw.Tools.ScheduleTask,
      JidoClaw.Tools.UnscheduleTask,
      JidoClaw.Tools.ListScheduledTasks,
      # Handoff (1)
      JidoClaw.Tools.Handoff
    ],
    model: :fast,
    max_iterations: 25,
    streaming: true,
    tool_timeout_ms: 30_000,
    llm_opts: [provider_options: [anthropic_prompt_cache: true]],
    compaction: [
      mode: :auto,
      max_messages: 60,
      recompact_delta_threshold: 30,
      keep_last_turns: 6,
      protect_first_n_turns: 2,
      max_summary_chars: 4_000,
      summarizer_timeout_ms: 15_000
    ]

  @doc "Canonical tool module list. Derived from the `tools:` option above via `strategy_opts/0`; REPL banner + branding call this for accurate counts."
  @spec tool_modules() :: [module()]
  def tool_modules do
    strategy_opts() |> Keyword.fetch!(:tools)
  end
end
