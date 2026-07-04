defmodule JidoClaw.Tools.ReplayWorkflow do
  # The diagnosed-refusal error builds the `{code, details, message}` wire-error
  # contract (Error.t()) — the same explicit API shape error.ex/tool_approval.ex
  # produce; pragma'd here too so reach's drifting cross-file anchor never lands
  # on an unsuppressed participant.
  # reach:disable-for-this-file fixed_shape_map
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
      # `run_status`, NOT `status`: the shared `Tools.Error.normalize_result/1`
      # promotes `{:ok, %{status: "failed"}}` to an `{:error, _}`. A replay that
      # launched then failed is a normal, successful read of the run's terminal
      # status (callers read `run_status`/`error`), so it rides a non-colliding
      # key — the `inspect_workflow` precedent.
      run_status: [type: :string, required: true],
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
  alias JidoClaw.Orchestration.Replay.Diagnostics
  alias JidoClaw.Orchestration.Visibility

  @impl Jido.Action
  def run(params, context) do
    tool_context = Map.get(context, :tool_context, %{}) || %{}

    # Bind tenant/actor BEFORE attempting, so a refusal can reuse them to
    # attach preflight diagnostics without re-resolving scope.
    case resolve_tenant(tool_context) do
      {:ok, tenant} ->
        attempt(params.run_id, tenant, resolve_actor(tool_context, tenant))

      {:error, :missing_tenant} ->
        {:error, format_refusal(:missing_tenant)}
    end
  end

  defp attempt(run_id, tenant, actor) do
    case Replay.replay(run_id, tenant: tenant, actor: actor) do
      {:ok, run} -> {:ok, summarize(run)}
      {:error, reason} -> {:error, refusal_error(reason, run_id, tenant, actor)}
    end
  end

  # Replay-relevant refusals carry a preflight-diagnostics map at
  # `details.diagnostics` so the LLM sees WHY (all determinable blockers, run
  # health, the unverified-input residual), not just the first refusal. The
  # plain-English `format_refusal/1` string stays the `message`; the legacy
  # `Error.normalize/1` `%{code, message, details}` clause passes `details`
  # through verbatim. Other refusals (`:not_found`, `:launch_failed`, …) keep
  # the bare string.
  defp refusal_error({:definition_changed, _stored, _current} = reason, run_id, tenant, actor),
    do: diagnosed_error(reason, run_id, tenant, actor)

  defp refusal_error(:irreversible_steps_executed = reason, run_id, tenant, actor),
    do: diagnosed_error(reason, run_id, tenant, actor)

  defp refusal_error({:not_replayable, _detail} = reason, run_id, tenant, actor),
    do: diagnosed_error(reason, run_id, tenant, actor)

  defp refusal_error(reason, _run_id, _tenant, _actor), do: format_refusal(reason)

  defp diagnosed_error(reason, run_id, tenant, actor) do
    message = format_refusal(reason)

    case Replay.diagnose(run_id, tenant: tenant, actor: actor) do
      {:ok, diagnostics} ->
        %{
          code: :replay_refused,
          message: message,
          details: %{diagnostics: Diagnostics.to_mcp_map(diagnostics)}
        }

      # Degrade silently: diagnostics must never break a refusal.
      {:error, _reason} ->
        message
    end
  end

  # `{:ok, run}` means a replay run exists — surface its outcome; a run that
  # launched and then failed still reports success-with-status (callers read
  # `status`/`error`), mirroring Replay's uniform envelope. The error is
  # operator-scoped (T2-2): MCP surfaces never see unredacted payloads.
  defp summarize(run) do
    base = %{
      new_run_id: run.id,
      retry_of_id: run.retry_of_id,
      name: run.name,
      run_status: to_string(run.status),
      message: "Replay launched as run #{run.id} — status: #{run.status}."
    }

    if run.error do
      Map.put(base, :error, Visibility.redact_error(run.error, :operator))
    else
      base
    end
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
