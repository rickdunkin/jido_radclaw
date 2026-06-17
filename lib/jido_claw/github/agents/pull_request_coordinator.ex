defmodule JidoClaw.GitHub.Agents.PullRequestCoordinator do
  @moduledoc false
  require Logger

  alias JidoClaw.GitHub.PatchQuality

  @max_attempts 3

  @spec create_pr(map(), map(), map()) :: {:ok, map()} | {:error, term()}
  def create_pr(event, triage, research) do
    do_attempt(event, triage, research, 1, [])
  end

  defp do_attempt(_event, _triage, _research, attempt, history) when attempt > @max_attempts do
    Logger.warning("[PRCoordinator] Exhausted #{@max_attempts} attempts")
    {:error, {:max_attempts_reached, history}}
  end

  defp do_attempt(event, triage, research, attempt, history) do
    Logger.info("[PRCoordinator] Attempt #{attempt}/#{@max_attempts} for #{event_label(event)}")

    with {:ok, patch} <- generate_patch(event, triage, research),
         {:ok, quality} <- PatchQuality.validate(patch),
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

  # Safe log label — raised under the old `event.repo.full_name` interpolation
  # on malformed events; the `with` chain below handles those structurally.
  defp event_label(%{repo: %{full_name: repo}, issue: %{number: number}})
       when is_binary(repo) and is_integer(number),
       do: "#{repo}##{number}"

  defp event_label(_), do: "unknown issue"

  defp generate_patch(event, _triage, research) do
    # passes {:error, {:generation_failed, _}} through → terminal abort branch
    with {:ok, %{issue_number: n}} <- issue_context(event) do
      {:ok,
       %{
         files: derive_files(research),
         description: "Fix for ##{n}",
         branch: "fix/issue-#{n}"
       }}
    end
  end

  defp issue_context(%{issue: %{number: number}, repo: %{full_name: repo}})
       when is_integer(number) and number > 0 and is_binary(repo) and repo != "" do
    {:ok, %{issue_number: number, repo: repo}}
  end

  defp issue_context(_), do: {:error, {:generation_failed, :missing_issue_context}}

  # Files derive from research findings; empty/pathless/wrong-shaped research →
  # empty patch, which PatchQuality.validate/1 rejects, driving the retry loop.
  # Only real, non-blank binary paths count (no faked defaults). Matched by shape
  # (not get_in/2) so `%{code_search: "bad"}` yields [] instead of raising.
  defp derive_files(%{code_search: %{results: results}}) do
    results
    |> List.wrap()
    |> Enum.flat_map(fn
      %{path: p} when is_binary(p) -> path_entry(p)
      _ -> []
    end)
  end

  defp derive_files(_), do: []

  # A research result yields a file only if its path is non-blank (String.trim/1
  # is not guard-legal); aligns with PatchQuality's :files_present check.
  defp path_entry(path) do
    if String.trim(path) == "", do: [], else: [%{path: path}]
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
