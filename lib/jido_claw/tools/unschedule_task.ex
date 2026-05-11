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
    tenant_id = get_in(context, [:tool_context, :tenant_id]) || "default"

    actor =
      get_in(context, [:tool_context, :actor]) ||
        JidoClaw.Authorization.Actor.system(tenant_id)

    id = String.trim(params.id)

    sched_result = JidoClaw.Cron.Scheduler.unschedule(tenant_id, id)
    persist_result = remove_persistent(tenant_id, id, actor)

    case {sched_result, persist_result} do
      {:ok, :ok} ->
        {:ok, %{result: "Removed task '#{id}' from scheduler and persistent store."}}

      {:ok, {:error, :not_found}} ->
        {:ok, %{result: "Removed task '#{id}' from scheduler (was not in persistent store)."}}

      {{:error, :not_found}, :ok} ->
        {:ok, %{result: "Task '#{id}' was not running but removed from persistent store."}}

      {{:error, :not_found}, {:error, :not_found}} ->
        {:ok, %{result: "Task '#{id}' not found in scheduler or persistent store."}}

      {_, _} ->
        {:ok, %{result: "Cleaned up task '#{id}'."}}
    end
  end

  defp remove_persistent(tenant_id, id, actor) do
    case JidoClaw.Cron.Job.by_job_id(id, tenant: tenant_id, actor: actor) do
      {:ok, job} ->
        case JidoClaw.Cron.Job.remove(job, tenant: tenant_id, actor: actor) do
          :ok -> :ok
          {:ok, _} -> :ok
          err -> err
        end

      {:error, _} ->
        {:error, :not_found}
    end
  end
end
