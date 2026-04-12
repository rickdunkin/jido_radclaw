defmodule JidoClaw.GitHub.IssueCommentClient do
  require Logger

  @github_api "https://api.github.com"

  def post_comment(repo_full_name, issue_number, body) do
    token = get_token()
    url = "#{@github_api}/repos/#{repo_full_name}/issues/#{issue_number}/comments"

    case Req.post(url,
           json: %{body: body},
           headers: [
             {"authorization", "Bearer #{token}"},
             {"accept", "application/vnd.github+json"},
             {"x-github-api-version", "2022-11-28"}
           ]
         ) do
      {:ok, %{status: 201}} ->
        Logger.info("[GitHub] Posted comment on #{repo_full_name}##{issue_number}")
        :ok

      {:ok, %{status: status, body: resp_body}} ->
        Logger.warning("[GitHub] Comment failed: #{status} #{inspect(resp_body)}")
        {:error, {:api_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp get_token do
    Application.get_env(:jido_claw, :github_token, System.get_env("GITHUB_TOKEN") || "")
  end
end
