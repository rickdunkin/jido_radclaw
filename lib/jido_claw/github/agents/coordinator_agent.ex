defmodule JidoClaw.GitHub.Agents.CoordinatorAgent do
  require Logger

  alias JidoClaw.GitHub.Agents.{TriageAgent, ResearchCoordinator, PullRequestCoordinator}

  def run(event) do
    Logger.info(
      "[CoordinatorAgent] Starting pipeline for #{event.repo.full_name}##{event.issue.number}"
    )

    with {:ok, triage} <- TriageAgent.classify(event.issue),
         {:ok, research} <- ResearchCoordinator.research(event, triage),
         {:ok, pr_result} <- PullRequestCoordinator.create_pr(event, triage, research) do
      {:ok, %{triage: triage, research: research, pr: pr_result}}
    else
      {:error, reason} ->
        Logger.error("[CoordinatorAgent] Pipeline failed: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
