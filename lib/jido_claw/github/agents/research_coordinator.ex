defmodule JidoClaw.GitHub.Agents.ResearchCoordinator do
  require Logger

  def research(event, triage) do
    tasks = [
      Task.async(fn -> code_search(event) end),
      Task.async(fn -> reproduction_analysis(event) end),
      Task.async(fn -> root_cause_analysis(event, triage) end),
      Task.async(fn -> pr_search(event) end)
    ]

    results = Task.await_many(tasks, 60_000)

    {:ok,
     %{
       code_search: Enum.at(results, 0),
       reproduction: Enum.at(results, 1),
       root_cause: Enum.at(results, 2),
       related_prs: Enum.at(results, 3)
     }}
  rescue
    e ->
      Logger.error("[ResearchCoordinator] Failed: #{inspect(e)}")
      {:error, :research_failed}
  end

  defp code_search(event) do
    %{repo: event.repo.full_name, query: event.issue.title, results: []}
  end

  defp reproduction_analysis(event) do
    %{reproducible: false, steps: [], environment: %{}, issue: event.issue.number}
  end

  defp root_cause_analysis(event, triage) do
    %{
      hypothesis: "Needs investigation",
      confidence: 0.3,
      classification: triage.classification,
      issue: event.issue.number
    }
  end

  defp pr_search(event) do
    %{related_prs: [], related_issues: [], repo: event.repo.full_name}
  end
end
