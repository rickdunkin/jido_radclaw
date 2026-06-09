defmodule JidoClaw.Orchestration.WorkflowRunner do
  @moduledoc """
  Thin cron adapter for `target: :workflow` jobs.

  Driven by `Cron.Dispatcher`. On a tick it resolves the named skill, compiles
  it to a `%Reactor{}` via `JidoClaw.Skills.Compiler`, and runs it through
  `JidoClaw.Orchestration.ReactorRunner` — the same durable envelope that drives
  developer-authored reactors. The `WorkflowRun` row, event timeline, status
  projection, and `RunPubSub` broadcasts are all owned by the envelope
  (`ReactorMiddleware`); this module just maps the envelope result to the
  dispatcher's `:ok | {:error, term()}` contract.

  ## Shared per-run scope

  Builds a deterministic `workspace_id = "cron:<job_id>:<n>"` and passes it via
  the runner's `:context`, so every step in the cron workflow shares
  shell/VFS state (without it each step would fall back to a unique per-step
  key). `project_dir` is the app's boot-time `File.cwd!()` (cron is a
  single-project concern today). Cron workflows produce no
  `Conversations.Session`/correlation rows — observability lives in the
  `WorkflowRun` + event log + cron telemetry.

  ## Never raises

  `run/1` is `:ok | {:error, term()}`. `ReactorRunner.run/3` is itself a
  never-raises seam; the body-level rescue covers a `Skills.get`/`Compiler`
  raise so a misconfigured job can't crash the dispatcher.
  """

  # `run/1` is contractually `:ok | {:error, term()}`; the body rescue
  # normalizes any pre-run raise (skill lookup / compile) into the error tuple.
  # reach:disable-for-this-file bare_rescue

  alias JidoClaw.Authorization.Actor
  alias JidoClaw.Orchestration.ReactorRunner
  alias JidoClaw.Skills
  alias JidoClaw.Skills.Compiler

  @spec run(map()) :: :ok | {:error, term()}
  def run(%{workflow_name: name} = state) do
    tenant_id = state.tenant_id

    with {:ok, skill} <- Skills.get(name, File.cwd!()),
         {:ok, reactor} <- Compiler.compile(skill) do
      reactor
      |> run_reactor(skill, state, tenant_id)
      |> finalize()
    else
      # Unknown skill / compile failure — no run created.
      {:error, reason} -> {:error, format_reason(reason)}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # Defensive: a state map with no :workflow_name can never reach here from the
  # dispatcher (Job invariant + reload guard + ScheduleTask validation all
  # require it), but honor the never-raises contract anyway.
  def run(_state), do: {:error, :missing_workflow_name}

  # -- Internal --

  defp run_reactor(reactor, skill, state, tenant_id) do
    workspace_id = "cron:#{state.id}:#{System.unique_integer([:positive])}"

    ReactorRunner.run(reactor, %{extra_context: extra_context(state)},
      tenant: tenant_id,
      actor: Actor.system(tenant_id),
      name: skill.name,
      async?: true,
      context: %{workspace_id: workspace_id, project_dir: File.cwd!()}
    )
  end

  defp finalize({:ok, _value, _run}), do: :ok
  defp finalize({:error, reason, _run}), do: {:error, format_reason(reason)}

  # The workflow input's "context" key is the extra instructions string appended
  # to every step's task; default to "" so ContextBuilder.build_task drops it.
  defp extra_context(state) do
    (Map.get(state, :workflow_input) || %{})
    |> Map.get("context", "")
  end

  defp format_reason(%{__exception__: true} = e), do: Exception.message(e)
  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)
end
