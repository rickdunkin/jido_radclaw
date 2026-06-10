defmodule JidoClaw.Tools.ReplayWorkflow do
  @moduledoc """
  MCP tool over `JidoClaw.Orchestration.Replay.replay/2`: re-run a terminal
  workflow run by id with its original (durably stored) inputs.

  Deliberately exposes `run_id` **only** — no `force` / `allow_irreversible`
  parameters. The replay safety gates (definition changed since the original
  run; original executed irreversible steps) refuse here with an explanatory
  error; overriding them is an operator decision that lives on the dashboard,
  not a lever handed to MCP clients. Published by `JidoClaw.MCPServer` only —
  intentionally absent from the in-REPL agent's tool list.
  """

  use JidoClaw.Tools.Action,
    name: "replay_workflow",
    description:
      "Replay a finished workflow run by id, re-running its definition with the original inputs as a new tracked run. Refuses if the definition changed since the run or if the run executed irreversible steps — those refusals can only be overridden from the dashboard.",
    category: "skills",
    tags: ["workflow", "exec"],
    output_schema: [
      new_run_id: [type: :string, required: true],
      retry_of_id: [type: :string, required: true],
      name: [type: :string, required: true],
      status: [type: :string, required: true],
      error: [type: :string],
      message: [type: :string, required: true]
    ],
    schema: [
      run_id: [
        type: :string,
        required: true,
        doc: "Id of the terminal workflow run to replay (see workflow_status)"
      ]
    ]

  alias JidoClaw.Authorization.Actor
  alias JidoClaw.Orchestration.Replay

  @impl true
  def run(params, context) do
    tool_context = Map.get(context, :tool_context, %{}) || %{}

    with {:ok, tenant} <- resolve_tenant(tool_context),
         actor = resolve_actor(tool_context, tenant),
         {:ok, run} <- Replay.replay(params.run_id, tenant: tenant, actor: actor) do
      {:ok, summarize(run)}
    else
      {:error, reason} -> {:error, format_refusal(reason)}
    end
  end

  # `{:ok, run}` means a replay run exists — surface its outcome; a run that
  # launched and then failed still reports success-with-status (callers read
  # `status`/`error`), mirroring Replay's uniform envelope.
  defp summarize(run) do
    base = %{
      new_run_id: run.id,
      retry_of_id: run.retry_of_id,
      name: run.name,
      status: to_string(run.status),
      message: "Replay launched as run #{run.id} — status: #{run.status}."
    }

    if run.error, do: Map.put(base, :error, run.error), else: base
  end

  defp format_refusal(:missing_tenant), do: "no tenant in tool context"

  defp format_refusal(:not_found), do: "workflow run not found"

  defp format_refusal({:definition_changed, _stored, _current}) do
    "the workflow definition changed since this run — replay refused; " <>
      "forcing past a definition change is dashboard-only"
  end

  defp format_refusal(:irreversible_steps_executed) do
    "the original run executed irreversible steps — replay refused; " <>
      "allowing an irreversible replay is dashboard-only"
  end

  defp format_refusal({:not_replayable, detail}), do: "run is not replayable: #{inspect(detail)}"

  defp format_refusal({:launch_failed, reason}), do: "replay launch failed: #{inspect(reason)}"

  defp format_refusal(other), do: "replay refused: #{inspect(other)}"

  # Tenant is required for the tenant-scoped Replay read/launch. `MCPScope`
  # (via the Tools.Action wrapper) injects the MCP default scope, which
  # carries tenant_id; if genuinely absent, fail cleanly rather than call
  # `Actor.system(nil)` (RunSkill precedent).
  defp resolve_tenant(tool_context) do
    case Map.get(tool_context, :tenant_id) do
      tenant when is_binary(tenant) and tenant != "" -> {:ok, tenant}
      _missing -> {:error, :missing_tenant}
    end
  end

  defp resolve_actor(tool_context, tenant) do
    Map.get(tool_context, :actor) || Actor.system(tenant)
  end
end
