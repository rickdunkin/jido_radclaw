defmodule JidoClaw.CLI.Commands.Approvals do
  @moduledoc """
  REPL surface for human approval gates (`/gates`).

  Lists the tenant's pending `AgentCase` inbox and routes approve/reject
  decisions through `JidoClaw.Orchestration.Cases.decide/4` — the single
  decision point shared with the web dashboard. The REPL runs unauthenticated,
  so decisions are made under a tenant-bound system actor (no `decided_by_id`).
  """

  alias JidoClaw.Authorization.Actor
  alias JidoClaw.Orchestration.AgentCase
  alias JidoClaw.Orchestration.Cases

  @doc "List the tenant's pending approval gates."
  @spec list(map()) :: {:ok, map()}
  def list(state) do
    actor = Actor.system(state.tenant_id)

    IO.puts("")
    IO.puts("  \e[1mApproval Gates\e[0m")

    case AgentCase.pending_for_tenant(tenant: state.tenant_id, actor: actor) do
      {:ok, []} ->
        IO.puts("  \e[2mNo pending gates.\e[0m")

      {:ok, cases} ->
        Enum.each(cases, &print_case/1)

      {:error, reason} ->
        IO.puts("  \e[31m✗\e[0m  Could not list gates: #{inspect(reason)}")
    end

    IO.puts("")

    IO.puts(
      "  \e[2mDecide: /gates approve <id> [comment]  ·  /gates reject <id> [comment]" <>
        "  ·  /gates abandon <id> [reason]\e[0m"
    )

    IO.puts("")
    {:ok, state}
  end

  @doc "Approve or reject a gate by id, with an optional comment."
  @spec decide(map(), :approve | :reject, String.t(), String.t() | nil) :: {:ok, map()}
  def decide(state, decision, id, comment) do
    id = String.trim(id)
    actor = Actor.system(state.tenant_id)
    attrs = decision_attrs(comment)

    IO.puts("")

    case Cases.decide(id, decision, attrs, tenant: state.tenant_id, actor: actor) do
      {:ok, run} ->
        IO.puts(
          "  \e[32m✓\e[0m  Gate #{decision}d — run \e[1m#{run.name}\e[0m is now #{run.status}"
        )

      {:error, :not_yet_resumable} ->
        IO.puts("  \e[33m⚠\e[0m  Gate not ready yet (checkpoint still being written). Try again.")

      {:error, :not_found} ->
        IO.puts("  \e[31m✗\e[0m  No gate found with id '\e[1m#{id}\e[0m'")

      {:error, reason} ->
        IO.puts("  \e[31m✗\e[0m  Could not #{decision} gate: #{inspect(reason)}")
    end

    IO.puts("")
    {:ok, state}
  end

  @doc """
  Abandon the parked run behind a pending gate (AR-1) — only legal while the
  run is `:awaiting_approval`; a live run is refused.
  """
  @spec abandon(map(), String.t(), String.t() | nil) :: {:ok, map()}
  def abandon(state, id, reason) do
    id = String.trim(id)
    actor = Actor.system(state.tenant_id)
    attrs = abandon_attrs(reason)

    IO.puts("")

    case Cases.abandon(id, attrs, tenant: state.tenant_id, actor: actor) do
      {:ok, run} ->
        IO.puts("  \e[32m✓\e[0m  Run \e[1m#{run.name}\e[0m abandoned")

      {:error, :not_found} ->
        IO.puts("  \e[31m✗\e[0m  No gate found with id '\e[1m#{id}\e[0m'")

      {:error, :not_pending} ->
        IO.puts("  \e[33m⚠\e[0m  Gate already decided — abandon applies to pending gates only.")

      {:error, reason} ->
        IO.puts("  \e[31m✗\e[0m  Could not abandon run: #{inspect(reason)}")
    end

    IO.puts("")
    {:ok, state}
  end

  defp abandon_attrs(nil), do: %{}

  defp abandon_attrs(reason) when is_binary(reason),
    do: %{cancellation_reason: String.trim(reason)}

  defp decision_attrs(nil), do: %{}

  defp decision_attrs(comment) when is_binary(comment),
    do: %{decision_comment: String.trim(comment)}

  defp print_case(agent_case) do
    IO.puts(
      "  \e[33m▸\e[0m \e[1m#{agent_case.id}\e[0m  #{agent_case.step_name}  \e[2m#{agent_case.kind}\e[0m"
    )

    if map_size(agent_case.details || %{}) > 0 do
      IO.puts("    \e[2m#{inspect(agent_case.details)}\e[0m")
    end
  end
end
