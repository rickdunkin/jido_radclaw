defmodule JidoClaw.Tools.UnscheduleTask do
  @moduledoc """
  Agent tool for removing a scheduled recurring task.
  """

  use JidoClaw.Tools.Action,
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

  alias JidoClaw.Authorization.Actor
  alias JidoClaw.Cron.Job
  alias JidoClaw.Cron.Owner, as: CronOwner

  @impl Jido.Action
  def run(params, context) do
    tenant_id = get_in(context, [:tool_context, :tenant_id]) || "default"

    actor =
      get_in(context, [:tool_context, :actor]) ||
        Actor.system(tenant_id)

    id = String.trim(params.id)

    # The row is the source of truth: remove it, then hand off to the leader's
    # Cron.Owner to prune the worker (which lives on the leader, never a follower).
    case remove_persistent(tenant_id, id, actor) do
      :ok ->
        CronOwner.notify_changed(tenant_id)
        {:ok, %{result: "Removed task '#{id}' from the persistent store."}}

      {:error, :not_found} ->
        {:ok, %{result: "Task '#{id}' not found in the persistent store."}}

      {:error, {_stage, reason}} ->
        {:error, "Failed to remove task '#{id}': #{inspect(reason)}"}
    end
  end

  defp remove_persistent(tenant_id, id, actor) do
    case Job.by_job_id(id, tenant: tenant_id, actor: actor) do
      {:ok, job} -> do_remove(job, tenant_id, actor)
      {:error, reason} -> read_error(reason)
    end
  end

  defp do_remove(job, tenant_id, actor) do
    case Job.remove(job, tenant: tenant_id, actor: actor) do
      :ok -> :ok
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:remove_failed, reason}}
    end
  end

  # A get? read surfaces not-found either bare or wrapped in Ash.Error.Invalid;
  # both mean "gone", anything else is a real read failure worth surfacing.
  defp read_error(reason) do
    if not_found_error?(reason),
      do: {:error, :not_found},
      else: {:error, {:read_failed, reason}}
  end

  defp not_found_error?(%Ash.Error.Query.NotFound{}), do: true

  defp not_found_error?(%Ash.Error.Invalid{errors: errors}) when is_list(errors),
    do: Enum.any?(errors, &not_found_error?/1)

  defp not_found_error?(_), do: false
end
