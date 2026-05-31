defmodule JidoClaw.Orchestration.WorkflowRunner do
  @moduledoc """
  First producer of the `JidoClaw.Orchestration.WorkflowRun` state machine.

  Driven by `Cron.Dispatcher` for `target: :workflow` cron jobs. On a tick
  it resolves the named skill, creates + starts a durable `WorkflowRun`
  row, runs the skill through the existing workflow drivers
  (Skill/Plan/Iterative), then completes or fails the run — broadcasting
  `:run_started` / `:run_completed` / `:run_failed` over `RunPubSub` for
  the dashboard's `RunSummaryFeed`.

  ## Shared per-run scope

  Builds a deterministic `workspace_id = "cron:<job_id>:<run_id>"` and
  passes it as both the `:workspace_id` driver opt and the
  `scope_context[:workspace_id]` key (exactly as `Tools.RunSkill` does).
  Without it every step would fall back to a unique per-step `"wf_<tag>"`
  key and steps in the same cron workflow would not share shell/VFS state.

  ## Minimal identity scope

  Beyond `workspace_id`, the runner uses
  `%{tenant_id, project_dir: File.cwd!(), actor: Actor.system(tenant_id)}`
  and does NOT resolve a `Conversations.Session` / `Workspaces.Workspace`.
  Trade-off: cron workflows produce no `Conversations.Message` /
  correlation rows — observability lives in the `WorkflowRun` row +
  `RunPubSub` + cron telemetry, matching the "drive WorkflowRun" intent.

  `project_dir` is the app's boot-time `File.cwd!()`, which makes cron
  workflow execution project-global. Acceptable for v1 (cron is a
  single-project concern today); persisting a per-job `project_dir` is a
  follow-up.

  ## Never raises

  `run/1` is `:ok | {:error, term()}`. The executor call is wrapped in
  `try/rescue`, and every error shape (tuple, map, exception, binary) is
  normalized through `format_reason/1` before `WorkflowRun.fail/2`.
  Terminal Ash transitions are validated against `status == :running`, so
  the runner threads the *started* (`:running`) record into finalization,
  and broadcasts a terminal event only after the Ash update returns
  `{:ok, _}` — never against a row still `:running`.
  """

  require Logger

  alias JidoClaw.Authorization.Actor
  alias JidoClaw.Orchestration.RunPubSub
  alias JidoClaw.Orchestration.WorkflowRun
  alias JidoClaw.Skills
  alias JidoClaw.Tools.RunSkill
  alias JidoClaw.Workflows.IterativeWorkflow
  alias JidoClaw.Workflows.PlanWorkflow
  alias JidoClaw.Workflows.SkillWorkflow

  @spec run(map()) :: :ok | {:error, term()}
  def run(%{workflow_name: name} = state) do
    input = Map.get(state, :workflow_input) || %{}

    with {:ok, skill} <- Skills.get(name, File.cwd!()),
         {:ok, started} <- create_and_start(name, skill, state, input) do
      execute_and_finalize(skill, input, state, started)
    else
      # Unknown skill / create / start failure — no orphan run created.
      {:error, reason} -> {:error, format_reason(reason)}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # Defensive: a state map with no :workflow_name can never reach here from
  # the dispatcher (the Job invariant + reload guard + ScheduleTask
  # validation all require it), but honor the never-raises contract anyway.
  def run(_state), do: {:error, :missing_workflow_name}

  @doc false
  @spec dispatch(Skills.t(), String.t(), String.t(), keyword()) ::
          {:ok, list()} | {:error, term()}
  def dispatch(skill, extra, project_dir, opts) do
    case Skills.execution_mode(skill) do
      :iterative -> IterativeWorkflow.run(skill, extra, project_dir, opts)
      :dag -> PlanWorkflow.run(skill, extra, project_dir, opts)
      :sequential -> SkillWorkflow.run(skill, extra, project_dir, opts)
    end
  end

  # -- Internal --

  defp create_and_start(name, skill, state, input) do
    config = %{
      trigger: "cron",
      cron_job_id: state.id,
      skill: name,
      input: input
    }

    attrs = %{
      name: name,
      workflow_type: to_string(Skills.execution_mode(skill)),
      config: config
    }

    with {:ok, created} <- WorkflowRun.create(attrs),
         {:ok, started} <- WorkflowRun.start(created) do
      broadcast(:run_started, started.id, %{
        name: started.name,
        workflow_type: started.workflow_type,
        status: :running,
        cron_job_id: state.id
      })

      {:ok, started}
    end
  end

  defp execute_and_finalize(skill, input, state, started) do
    cron_job_id = state.id

    try do
      do_execute_and_finalize(skill, input, state, started, cron_job_id)
    rescue
      e -> finalize_fail(started, e, cron_job_id)
    end
  end

  defp do_execute_and_finalize(skill, input, state, started, cron_job_id) do
    workspace_id = "cron:#{cron_job_id}:#{started.id}"
    extra = Map.get(input, "context", "")

    scope = %{
      tenant_id: state.tenant_id,
      workspace_id: workspace_id,
      project_dir: File.cwd!(),
      actor: Actor.system(state.tenant_id)
    }

    opts = [workspace_id: workspace_id, scope_context: scope]

    case run_executor(skill, extra, opts) do
      {:ok, steps} -> finalize_complete(started, RunSkill.build_result(skill, steps), cron_job_id)
      {:error, reason} -> finalize_fail(started, reason, cron_job_id)
    end
  end

  # The executor seam (default = this module's dispatch/4). Wrapped so a
  # raising driver becomes a fail-transition rather than an escaped error.
  defp run_executor(skill, extra, opts) do
    executor =
      Application.get_env(:jido_claw, :cron_workflow_executor, __MODULE__)

    case executor.dispatch(skill, extra, File.cwd!(), opts) do
      {:ok, steps} when is_list(steps) -> {:ok, steps}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_executor_return, other}}
    end
  rescue
    e -> {:error, e}
  end

  defp finalize_complete(started, result, cron_job_id) do
    case WorkflowRun.complete(started, %{result: result}) do
      {:ok, done} ->
        broadcast(:run_completed, done.id, %{
          name: done.name,
          workflow_type: done.workflow_type,
          status: :completed,
          result: result,
          completed_at: done.completed_at,
          cron_job_id: cron_job_id
        })

        :ok

      {:error, reason} ->
        {:error, {:terminal_persist_failed, reason}}
    end
  end

  defp finalize_fail(started, reason, cron_job_id) do
    formatted = format_reason(reason)

    case WorkflowRun.fail(started, %{error: formatted}) do
      {:ok, failed} ->
        broadcast(:run_failed, failed.id, %{
          name: failed.name,
          workflow_type: failed.workflow_type,
          error: formatted,
          completed_at: failed.completed_at,
          cron_job_id: cron_job_id
        })

      {:error, e} ->
        Logger.warning(
          "[WorkflowRunner] fail-state persist failed for run #{started.id}: #{inspect(e)}"
        )
    end

    {:error, formatted}
  end

  defp broadcast(event, run_id, info) do
    RunPubSub.broadcast(run_id, {event, run_id, info})
  end

  defp format_reason(%{__exception__: true} = e), do: Exception.message(e)
  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)
end
