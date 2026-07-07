defmodule JidoClaw.GitHub.Agents.ResearchCoordinator do
  @moduledoc false
  require Logger

  @task_supervisor JidoClaw.TaskSupervisor
  @await_timeout_ms 60_000

  # `async_nolink` (not `Task.async`): any sub-task crash or hang must surface
  # as `{:error, :research_failed}` to the GitHub event pipeline rather than
  # escape and abort the issue handler — a linked task's crash reaches the
  # caller as an EXIT signal, which no `rescue`/`catch` can intercept.
  @spec research(map(), map()) :: {:ok, map()} | {:error, :research_failed}
  def research(event, triage) do
    outcomes =
      [
        fn -> code_search(event) end,
        fn -> reproduction_analysis(event) end,
        fn -> root_cause_analysis(event, triage) end,
        fn -> pr_search(event) end
      ]
      |> Enum.map(&Task.Supervisor.async_nolink(@task_supervisor, &1))
      |> Task.yield_many(@await_timeout_ms)
      |> Enum.map(&reap/1)

    case outcomes do
      [{:ok, code_search}, {:ok, reproduction}, {:ok, root_cause}, {:ok, related_prs}] ->
        {:ok,
         %{
           code_search: code_search,
           reproduction: reproduction,
           root_cause: root_cause,
           related_prs: related_prs
         }}

      _ ->
        failures = for {:error, reason} <- outcomes, do: reason
        Logger.error("[ResearchCoordinator] Failed: #{inspect(failures)}")
        {:error, :research_failed}
    end
  end

  # Reap one yielded slot: accept a reply, kill-and-drain a straggler
  # (`Task.shutdown` still returns `{:ok, result}` when the reply landed
  # between the yield deadline and the kill), normalize the rest to errors.
  defp reap({_task, {:ok, result}}), do: {:ok, result}
  defp reap({_task, {:exit, reason}}), do: {:error, {:exit, reason}}

  defp reap({task, nil}) do
    case Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> {:ok, result}
      {:exit, reason} -> {:error, {:exit, reason}}
      nil -> {:error, :timeout}
    end
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
