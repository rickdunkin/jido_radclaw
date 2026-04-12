defmodule JidoClaw.Tools.ListScheduledTasks do
  @moduledoc """
  Agent tool for listing all scheduled recurring tasks.
  """

  use Jido.Action,
    name: "list_scheduled_tasks",
    description:
      "List all scheduled recurring tasks with their status, schedule, next run time, and failure count.",
    schema: []

  @impl true
  def run(_params, context) do
    tenant_id = get_in(context, [:tool_context, :tenant_id]) || "default"

    jobs = JidoClaw.Cron.Scheduler.list_jobs(tenant_id)

    if jobs == [] do
      {:ok, %{result: "No scheduled tasks. Use schedule_task to create one."}}
    else
      formatted =
        Enum.map_join(jobs, "\n", fn job ->
          schedule_str = format_schedule(job.schedule)
          next_str = if job.next_run, do: DateTime.to_iso8601(job.next_run), else: "N/A"

          "- #{job.id} [#{job.status}]: \"#{job.task}\" | #{schedule_str} | mode: #{job.mode} | next: #{next_str} | failures: #{job.failure_count}"
        end)

      {:ok, %{result: "Scheduled tasks (#{length(jobs)}):\n#{formatted}"}}
    end
  end

  defp format_schedule({:cron, expr}), do: "cron: #{expr}"
  defp format_schedule({:every, ms}) when ms >= 86_400_000, do: "every #{div(ms, 86_400_000)}d"
  defp format_schedule({:every, ms}) when ms >= 3_600_000, do: "every #{div(ms, 3_600_000)}h"
  defp format_schedule({:every, ms}) when ms >= 60_000, do: "every #{div(ms, 60_000)}m"
  defp format_schedule({:every, ms}), do: "every #{div(ms, 1000)}s"
  defp format_schedule({:at, dt}), do: "at: #{DateTime.to_iso8601(dt)}"
  defp format_schedule(other), do: inspect(other)
end
