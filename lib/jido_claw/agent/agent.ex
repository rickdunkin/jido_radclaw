defmodule JidoClaw.Agent do
  use Jido.AI.Agent,
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
      # Memory tools (2)
      JidoClaw.Tools.Remember,
      JidoClaw.Tools.Recall,
      # Solutions tools (4)
      JidoClaw.Tools.StoreSolution,
      JidoClaw.Tools.FindSolution,
      JidoClaw.Tools.NetworkShare,
      JidoClaw.Tools.NetworkStatus,
      # Browser tools (1)
      JidoClaw.Tools.BrowseWeb,
      # Reasoning tools (1)
      JidoClaw.Tools.Reason,
      # Scheduling tools (3)
      JidoClaw.Tools.ScheduleTask,
      JidoClaw.Tools.UnscheduleTask,
      JidoClaw.Tools.ListScheduledTasks
    ],
    model: :fast,
    max_iterations: 25,
    streaming: true,
    tool_timeout_ms: 30_000
end
