defmodule JidoClaw.GitHub.WebhookPipeline do
  require Logger

  alias JidoClaw.GitHub.WebhookSignature

  @supported_events ["issues.opened", "issues.edited", "issue_comment.created"]

  def process(conn, raw_body) do
    signature = List.first(Plug.Conn.get_req_header(conn, "x-hub-signature-256"))
    event = List.first(Plug.Conn.get_req_header(conn, "x-github-event"))
    delivery_id = List.first(Plug.Conn.get_req_header(conn, "x-github-delivery"))

    with :ok <- WebhookSignature.verify(raw_body, signature),
         {:ok, payload} <- Jason.decode(raw_body),
         action <- Map.get(payload, "action"),
         full_event <- "#{event}.#{action}",
         true <- full_event in @supported_events do
      Logger.info("[GitHub.WebhookPipeline] Processing #{full_event} delivery=#{delivery_id}")
      route_event(full_event, payload, delivery_id)
    else
      false ->
        Logger.debug("[GitHub.WebhookPipeline] Ignoring unsupported event")
        {:ok, :ignored}

      {:error, reason} ->
        Logger.warning("[GitHub.WebhookPipeline] Rejected: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp route_event(event, payload, delivery_id) do
    issue = extract_issue(payload)
    repo = extract_repo(payload)

    Phoenix.PubSub.broadcast(JidoClaw.PubSub, "github:webhooks", {
      :github_event,
      %{
        event: event,
        delivery_id: delivery_id,
        issue: issue,
        repo: repo,
        payload: payload
      }
    })

    {:ok, :processed}
  end

  defp extract_issue(payload) do
    issue = Map.get(payload, "issue", %{})

    %{
      number: Map.get(issue, "number"),
      title: Map.get(issue, "title"),
      body: Map.get(issue, "body"),
      labels: Enum.map(Map.get(issue, "labels", []), &Map.get(&1, "name")),
      user: get_in(issue, ["user", "login"])
    }
  end

  defp extract_repo(payload) do
    repo = Map.get(payload, "repository", %{})

    %{
      full_name: Map.get(repo, "full_name"),
      default_branch: Map.get(repo, "default_branch", "main")
    }
  end
end
