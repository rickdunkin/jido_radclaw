defmodule JidoClaw.Tools.ListScheduledTasks do
  @moduledoc """
  Agent tool for listing all scheduled recurring tasks.
  """

  use JidoClaw.Tools.Action,
    name: "list_scheduled_tasks",
    description:
      "List all scheduled recurring tasks with their status, schedule, mode, target, last run time, and run count.",
    category: "scheduling",
    tags: ["scheduling", "read"],
    output_schema: [
      result: [type: :string, required: true]
    ],
    schema: []

  alias JidoClaw.Authorization.Actor
  alias JidoClaw.Cron.Job
  alias JidoClaw.Cron.Scheduler

  @impl Jido.Action
  def run(_params, context) do
    tenant_id = get_in(context, [:tool_context, :tenant_id]) || "default"
    actor = get_in(context, [:tool_context, :actor]) || Actor.system(tenant_id)

    # Read persisted rows (the source of truth), not node-local workers — on a
    # follower the worker set is empty, so a worker-backed list would report "no
    # tasks" right after scheduling one. `for_tenant_all` includes disabled rows
    # so a disabled job still shows (with its state) rather than vanishing.
    case Job.for_tenant_all(tenant: tenant_id, actor: actor) do
      {:ok, []} ->
        {:ok, %{result: "No scheduled tasks. Use schedule_task to create one."}}

      {:ok, jobs} ->
        {:ok, %{result: "Scheduled tasks (#{length(jobs)}):\n#{format_jobs(jobs)}"}}

      {:error, reason} ->
        {:error, "Failed to list scheduled tasks: #{inspect(reason)}"}
    end
  end

  defp format_jobs(jobs) do
    Enum.map_join(jobs, "\n", fn job ->
      schedule_str =
        format_schedule(Scheduler.hydrate_schedule(job.schedule_kind, job.schedule_value))

      status = if job.disabled_at, do: "disabled", else: "active"
      last_run = if job.last_run_at, do: DateTime.to_iso8601(job.last_run_at), else: "never"

      "- #{job.job_id} [#{status}]: \"#{job.task}\" | #{schedule_str} | mode: #{job.mode} | target: #{format_target(job)} | last_run: #{last_run} | runs: #{job.run_count}#{format_tz(job)}"
    end)
  end

  defp format_target(%{target: :workflow, workflow_name: name}), do: "workflow (#{name})"
  defp format_target(%{target: target}) when not is_nil(target), do: to_string(target)
  defp format_target(_), do: "agent"

  # Non-UTC only, mirroring the CLI /cron display — keeps default output clean.
  # Worker state carries :timezone, so jobs scheduled with one surface it here.
  defp format_tz(%{timezone: tz}) when is_binary(tz) and tz != "Etc/UTC", do: " | tz: #{tz}"
  defp format_tz(_), do: ""

  defp format_schedule({:cron, expr}), do: "cron: #{expr}"
  defp format_schedule({:every, ms}) when ms >= 86_400_000, do: "every #{div(ms, 86_400_000)}d"
  defp format_schedule({:every, ms}) when ms >= 3_600_000, do: "every #{div(ms, 3_600_000)}h"
  defp format_schedule({:every, ms}) when ms >= 60_000, do: "every #{div(ms, 60_000)}m"
  defp format_schedule({:every, ms}), do: "every #{div(ms, 1000)}s"
  defp format_schedule({:at, dt}), do: "at: #{DateTime.to_iso8601(dt)}"
end
