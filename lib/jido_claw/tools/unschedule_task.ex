defmodule JidoClaw.Tools.UnscheduleTask do
  @moduledoc """
  Agent tool for removing a scheduled recurring task.
  """

  use Jido.Action,
    name: "unschedule_task",
    description:
      "Remove a scheduled recurring task by its ID. Use list_scheduled_tasks first to see available job IDs.",
    category: "scheduling",
    tags: ["scheduling", "write"],
    output_schema: [
      result: [type: :string, required: true]
    ],
    schema: [
      id: [type: :string, required: true, doc: "The job ID to remove"]
    ]

  @impl true
  def run(params, context) do
    project_dir = get_in(context, [:tool_context, :project_dir]) || File.cwd!()
    tenant_id = get_in(context, [:tool_context, :tenant_id]) || "default"
    id = String.trim(params.id)

    # Unschedule from in-memory scheduler
    sched_result = JidoClaw.Cron.Scheduler.unschedule(tenant_id, id)

    # Remove from persistent YAML regardless (cleanup)
    persist_result = JidoClaw.Cron.Persistence.remove_job(project_dir, id)

    case {sched_result, persist_result} do
      {:ok, :ok} ->
        {:ok, %{result: "Removed task '#{id}' from scheduler and .jido/cron.yaml."}}

      {:ok, {:error, :not_found}} ->
        {:ok, %{result: "Removed task '#{id}' from scheduler (was not in .jido/cron.yaml)."}}

      {{:error, :not_found}, :ok} ->
        {:ok, %{result: "Task '#{id}' was not running but removed from .jido/cron.yaml."}}

      {{:error, :not_found}, {:error, :not_found}} ->
        {:ok, %{result: "Task '#{id}' not found in scheduler or .jido/cron.yaml."}}

      {_, _} ->
        {:ok, %{result: "Cleaned up task '#{id}'."}}
    end
  end
end
