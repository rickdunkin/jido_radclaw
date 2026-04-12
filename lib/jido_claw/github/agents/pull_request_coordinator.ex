defmodule JidoClaw.GitHub.Agents.PullRequestCoordinator do
  require Logger

  @max_attempts 3

  def create_pr(event, triage, research) do
    do_attempt(event, triage, research, 1, [])
  end

  defp do_attempt(_event, _triage, _research, attempt, history) when attempt > @max_attempts do
    Logger.warning("[PRCoordinator] Exhausted #{@max_attempts} attempts")
    {:error, {:max_attempts_reached, history}}
  end

  defp do_attempt(event, triage, research, attempt, history) do
    Logger.info(
      "[PRCoordinator] Attempt #{attempt}/#{@max_attempts} for #{event.repo.full_name}##{event.issue.number}"
    )

    with {:ok, patch} <- generate_patch(event, triage, research),
         {:ok, quality} <- validate_quality(patch),
         {:ok, pr} <- submit_pr(event, patch) do
      {:ok, %{patch: patch, quality: quality, pr: pr, attempts: attempt}}
    else
      {:error, {:quality_failed, reason}} ->
        Logger.info("[PRCoordinator] Quality check failed, retrying: #{inspect(reason)}")

        do_attempt(event, triage, research, attempt + 1, [
          %{attempt: attempt, error: reason} | history
        ])

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp generate_patch(event, _triage, _research) do
    {:ok,
     %{
       files: [],
       description: "Fix for ##{event.issue.number}",
       branch: "fix/issue-#{event.issue.number}"
     }}
  end

  defp validate_quality(_patch) do
    {:ok, %{passed: true, checks: []}}
  end

  defp submit_pr(event, patch) do
    {:ok,
     %{
       url: "https://github.com/#{event.repo.full_name}/pull/new",
       branch: patch.branch,
       status: :pending
     }}
  end
end
