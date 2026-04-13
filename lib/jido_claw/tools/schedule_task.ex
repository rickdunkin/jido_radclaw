defmodule JidoClaw.Tools.ScheduleTask do
  @moduledoc """
  Agent tool for scheduling recurring tasks.

  The agent should ask the user for task details and schedule before calling this.
  Persists to `.jido/cron.yaml` so jobs survive restarts.
  """

  use Jido.Action,
    name: "schedule_task",
    description: """
    Schedule a recurring task that the agent will execute on a schedule.
    Use cron expressions ('0 9 * * *' for daily at 9am, '*/30 * * * *' for every 30min)
    or interval strings ('every 1h', 'every 30m', 'every 1d').
    Ask the user for the task description and schedule before calling this tool.
    """,
    schema: [
      id: [
        type: :string,
        required: false,
        doc: "Unique job ID. Auto-generated from task if omitted."
      ],
      task: [
        type: :string,
        required: true,
        doc: "What the agent should do when the job fires (natural language instruction)"
      ],
      schedule: [
        type: :string,
        required: true,
        doc: "Cron expression (e.g., '0 9 * * *') or interval (e.g., 'every 1h')"
      ],
      mode: [
        type: :string,
        required: false,
        doc:
          "Execution mode: 'main' (shared session, default) or 'isolated' (separate session per run)"
      ]
    ]

  require Logger

  @impl true
  def run(params, context) do
    project_dir = get_in(context, [:tool_context, :project_dir]) || File.cwd!()
    tenant_id = get_in(context, [:tool_context, :tenant_id]) || "default"

    id = params[:id] || generate_id(params.task)
    mode = parse_mode(params[:mode])
    schedule_str = String.trim(params.schedule)

    case parse_schedule(schedule_str) do
      {:ok, schedule_tuple} ->
        opts = [
          id: id,
          task: params.task,
          schedule: schedule_tuple,
          mode: mode
        ]

        case JidoClaw.Cron.Scheduler.schedule(tenant_id, opts) do
          {:ok, ^id, _pid} ->
            # Persist to YAML
            job_map = %{
              id: id,
              task: params.task,
              schedule: schedule_str,
              mode: to_string(mode)
            }

            JidoClaw.Cron.Persistence.add_job(project_dir, job_map)

            schedule_desc = format_schedule(schedule_str)

            {:ok,
             %{
               result:
                 "Scheduled task '#{id}': \"#{params.task}\"\n" <>
                   "Schedule: #{schedule_desc}\n" <>
                   "Mode: #{mode}\n" <>
                   "Persisted to .jido/cron.yaml — will reload on restart."
             }}

          {:error, reason} ->
            {:error, "Failed to schedule task: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:error,
         "Invalid schedule '#{schedule_str}': #{reason}\n" <>
           "Use a cron expression (e.g., '0 9 * * *') or interval (e.g., 'every 1h', 'every 30m')."}
    end
  end

  # -- Schedule Parsing --

  defp parse_schedule("every " <> interval) do
    parse_interval(String.trim(interval))
  end

  defp parse_schedule(expr) do
    # Try as cron expression (5 fields: min hour dom month dow)
    fields = String.split(expr)

    if length(fields) == 5 do
      case Crontab.CronExpression.Parser.parse(expr) do
        {:ok, _} -> {:ok, {:cron, expr}}
        {:error, _} -> {:error, "invalid cron expression"}
      end
    else
      {:error, "expected a cron expression (5 fields) or 'every <interval>'"}
    end
  end

  defp parse_interval(str) do
    case Regex.run(~r/^(\d+)\s*(s|m|h|d|min|sec|hour|hours|mins|secs|days?)$/i, str) do
      [_, amount_str, unit] ->
        case Integer.parse(amount_str) do
          {amount, _} ->
            ms = amount * unit_to_ms(String.downcase(unit))

            if ms > 0 do
              {:ok, {:every, ms}}
            else
              {:error, "interval must be positive"}
            end

          :error ->
            {:error, "invalid interval amount"}
        end

      nil ->
        {:error, "invalid interval format, use e.g. '30m', '2h', '1d'"}
    end
  end

  defp unit_to_ms("s"), do: 1_000
  defp unit_to_ms("sec"), do: 1_000
  defp unit_to_ms("secs"), do: 1_000
  defp unit_to_ms("m"), do: 60_000
  defp unit_to_ms("min"), do: 60_000
  defp unit_to_ms("mins"), do: 60_000
  defp unit_to_ms("h"), do: 3_600_000
  defp unit_to_ms("hour"), do: 3_600_000
  defp unit_to_ms("hours"), do: 3_600_000
  defp unit_to_ms("d"), do: 86_400_000
  defp unit_to_ms("day"), do: 86_400_000
  defp unit_to_ms("days"), do: 86_400_000
  defp unit_to_ms(_), do: 0

  defp parse_mode("isolated"), do: :isolated
  defp parse_mode(_), do: :main

  defp generate_id(task) do
    task
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> String.slice(0, 30)
  end

  defp format_schedule("every " <> _ = s), do: s
  defp format_schedule(cron), do: "cron: #{cron}"
end
