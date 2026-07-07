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
  alias JidoClaw.Orchestration.WorkflowRun

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

  @doc """
  Approve or reject a gate by id, with an optional comment.

  A review-stall approve records **waive-all**: one derived waive record per
  key in the case's `details["finding_keys"]` (severity joined from the
  displayed findings where present) — the REPL's coarse equivalent of the
  web's per-finding controls; the per-finding records still land on the
  case's `:approved` timeline event (the BO2-6 ledger rows).
  """
  @spec decide(map(), :approve | :reject, String.t(), String.t() | nil) :: {:ok, map()}
  def decide(state, decision, id, comment) do
    id = String.trim(id)
    actor = Actor.system(state.tenant_id)

    attrs =
      comment
      |> decision_attrs()
      |> maybe_waive_all(decision, id, state.tenant_id, actor)

    IO.puts("")

    id
    |> Cases.decide(decision, attrs, tenant: state.tenant_id, actor: actor)
    |> print_decide_result(decision, id)

    IO.puts("")
    {:ok, state}
  end

  # One clause per outcome (pattern heads keep each body's complexity flat).
  defp print_decide_result({:ok, %WorkflowRun{} = run}, decision, _id) do
    IO.puts("  \e[32m✓\e[0m  Gate #{decision}d — run \e[1m#{run.name}\e[0m is now #{run.status}")
  end

  defp print_decide_result({:ok, %AgentCase{kind: :review_stall}}, decision, _id) do
    IO.puts("  \e[32m✓\e[0m  #{review_stall_decided_message(decision)}")
  end

  defp print_decide_result({:ok, %AgentCase{kind: :needs_input} = decided}, decision, _id) do
    IO.puts("  \e[32m✓\e[0m  #{needs_input_decided_message(decision, decided)}")
  end

  defp print_decide_result({:ok, %AgentCase{}}, decision, _id) do
    IO.puts("  \e[32m✓\e[0m  #{tool_call_decided_message(decision)}")
  end

  defp print_decide_result({:error, :answer_required}, _decision, _id) do
    IO.puts(
      "  \e[33m⚠\e[0m  This gate needs an answer — the comment IS the answer: " <>
        "/gates approve <id> <answer>"
    )
  end

  defp print_decide_result({:error, :incomplete_waiver}, _decision, _id) do
    IO.puts(
      "  \e[33m⚠\e[0m  Approve requires every surviving finding waived — " <>
        "this should not happen from /gates (waive-all is derived); re-run /gates."
    )
  end

  defp print_decide_result({:error, :not_yet_resumable}, _decision, _id) do
    IO.puts("  \e[33m⚠\e[0m  Gate not ready yet (checkpoint still being written). Try again.")
  end

  defp print_decide_result({:error, :parent_terminal}, _decision, _id) do
    IO.puts(
      "  \e[33m⚠\e[0m  The parent route has already ended — this gate can no longer be " <>
        "approved (reject or abandon to close it)."
    )
  end

  defp print_decide_result({:error, :parent_state_unknown}, _decision, _id) do
    IO.puts("  \e[33m⚠\e[0m  Could not verify the parent route's state — try again.")
  end

  defp print_decide_result({:error, :not_found}, _decision, id) do
    IO.puts("  \e[31m✗\e[0m  No gate found with id '\e[1m#{id}\e[0m'")
  end

  defp print_decide_result({:error, reason}, decision, _id) do
    IO.puts("  \e[31m✗\e[0m  Could not #{decision} gate: #{inspect(reason)}")
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
      {:ok, %WorkflowRun{} = run} ->
        IO.puts("  \e[32m✓\e[0m  Run \e[1m#{run.name}\e[0m abandoned")

      # Review-stall abandon returns the case — the run stays :running until
      # the parked composer wakes and terminalizes it :abandoned itself.
      {:ok, %AgentCase{}} ->
        IO.puts("  \e[32m✓\e[0m  Review-stall gate abandoned — the composer will end the run")

      {:error, :not_found} ->
        IO.puts("  \e[31m✗\e[0m  No gate found with id '\e[1m#{id}\e[0m'")

      {:error, :not_abandonable} ->
        IO.puts(
          "  \e[33m⚠\e[0m  A needs-input gate cannot be abandoned — reject it instead " <>
            "(there is no parked run behind it)."
        )

      {:error, :not_workflow_case} ->
        IO.puts(
          "  \e[33m⚠\e[0m  This is a tool-call approval — approve or reject it; there is no run to abandon."
        )

      {:error, :not_pending} ->
        IO.puts("  \e[33m⚠\e[0m  Gate already decided — abandon applies to pending gates only.")

      {:error, reason} ->
        IO.puts("  \e[31m✗\e[0m  Could not abandon run: #{inspect(reason)}")
    end

    IO.puts("")
    {:ok, state}
  end

  defp tool_call_decided_message(:approve), do: "Tool call approved — the agent may retry it now"

  defp tool_call_decided_message(:reject),
    do: "Tool call rejected — the agent will not retry it automatically"

  # Keyed on details["injectable"]: only a session-keyed VENDOR stage can
  # receive an injected answer — the copy must not promise injection elsewhere.
  defp needs_input_decided_message(:approve, %AgentCase{details: details}) do
    if is_map(details) and details["injectable"] == true do
      "Answer recorded — the next attempt of this stage injects it (single-use, expires in 24h)"
    else
      "Answer recorded for the operator record — this executor cannot receive injected answers"
    end
  end

  defp needs_input_decided_message(:reject, _decided), do: "Declined — no answer injected"

  # Review-stall decisions land on the case; the RUN terminal is written by
  # the parked composer when it wakes — never read off decide's return.
  defp review_stall_decided_message(:approve),
    do: "Waivers recorded — the run completes as done_with_findings when the composer resumes"

  defp review_stall_decided_message(:reject),
    do: "Findings rejected — the run fails as fix_failed when the composer resumes"

  # /gates approve on a review-stall case is waive-all: derive one record per
  # required key. Derived from `finding_keys` (the complete waive-required
  # list), NOT the displayed `findings` (capped at raise time) — severity is
  # joined from a displayed entry when present. Any load failure leaves attrs
  # unchanged; `Cases.decide/4` then surfaces the real error.
  defp maybe_waive_all(attrs, :approve, id, tenant_id, actor) do
    case AgentCase.by_id(id, tenant: tenant_id, actor: actor) do
      {:ok, %AgentCase{kind: :review_stall, details: details}} when is_map(details) ->
        Map.put(attrs, :waive_records, waive_all_records(details))

      _other ->
        attrs
    end
  end

  defp maybe_waive_all(attrs, _decision, _id, _tenant_id, _actor), do: attrs

  defp waive_all_records(details) do
    findings = List.wrap(details["findings"])

    for key <- List.wrap(details["finding_keys"]), is_binary(key) do
      shown = Enum.find(findings, &(is_map(&1) and &1["key"] == key))
      %{key: key, severity: shown && shown["severity"], note: nil}
    end
  end

  defp abandon_attrs(nil), do: %{}

  defp abandon_attrs(reason) when is_binary(reason),
    do: %{cancellation_reason: String.trim(reason)}

  defp decision_attrs(nil), do: %{}

  defp decision_attrs(comment) when is_binary(comment),
    do: %{decision_comment: String.trim(comment)}

  # Review-stall cases get a legible finding-list render (the raw
  # `inspect(details)` fallback below would bury the decision evidence).
  defp print_case(%AgentCase{kind: :review_stall} = agent_case) do
    IO.puts(
      "  \e[33m▸\e[0m \e[1m#{agent_case.id}\e[0m  #{agent_case.step_name}  \e[2m#{agent_case.kind}\e[0m"
    )

    details = agent_case.details || %{}

    Enum.each(List.wrap(details["findings"]), fn finding ->
      IO.puts(
        "    • [#{finding["severity"]}] #{finding["title"]}  \e[2m#{finding["location"]}\e[0m"
      )
    end)

    overflow = details["findings_overflow_count"] || 0

    if is_integer(overflow) and overflow > 0 do
      IO.puts("    \e[2m… and #{overflow} more (still waived by key on approve)\e[0m")
    end

    if is_binary(details["resume_hint"]) do
      IO.puts("    \e[2m#{details["resume_hint"]}\e[0m")
    end
  end

  # Needs-input cases get a legible question render (the answer rides the
  # approve comment; the raw inspect fallback below would bury the question).
  defp print_case(%AgentCase{kind: :needs_input} = agent_case) do
    IO.puts(
      "  \e[33m▸\e[0m \e[1m#{agent_case.id}\e[0m  #{agent_case.step_name}  \e[2m#{agent_case.kind}\e[0m"
    )

    details = agent_case.details || %{}

    if is_binary(details["question"]) do
      IO.puts("    \e[2mQ:\e[0m #{details["question"]}")
    end

    if is_binary(details["resume_hint"]) do
      IO.puts("    \e[2m#{details["resume_hint"]}\e[0m")
    end
  end

  defp print_case(agent_case) do
    IO.puts(
      "  \e[33m▸\e[0m \e[1m#{agent_case.id}\e[0m  #{agent_case.step_name}  \e[2m#{agent_case.kind}\e[0m"
    )

    if map_size(agent_case.details || %{}) > 0 do
      IO.puts("    \e[2m#{inspect(agent_case.details)}\e[0m")
    end
  end
end
