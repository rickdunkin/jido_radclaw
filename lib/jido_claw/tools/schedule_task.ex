defmodule JidoClaw.Tools.ScheduleTask do
  @moduledoc """
  Agent tool for scheduling recurring tasks.

  The agent should ask the user for task details and schedule before calling this.
  Persisted to Postgres (`cron_jobs`) so jobs survive restarts.

  `target: "agent"` (default) fires a chat turn; `target: "workflow"` runs a
  named skill as a tracked `JidoClaw.Orchestration.WorkflowRun`.
  """

  use JidoClaw.Tools.Action,
    name: "schedule_task",
    description: """
    Schedule a recurring task that the agent will execute on a schedule.
    Use cron expressions ('0 9 * * *' for daily at 9am, '*/30 * * * *' for every 30min)
    or interval strings ('every 1h', 'every 30m', 'every 1d').
    Ask the user for the task description and schedule before calling this tool.
    """,
    category: "scheduling",
    tags: ["scheduling", "write"],
    output_schema: [
      result: [type: :string, required: true]
    ],
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
      ],
      target: [
        type: :string,
        required: false,
        doc:
          "'agent' (default, runs a chat turn) or 'workflow' (runs a named skill as a tracked workflow run)"
      ],
      workflow: [
        type: :string,
        required: false,
        doc: "Skill name to run when target is 'workflow' (see /skills)"
      ]
    ]

  require Logger

  alias Crontab.CronExpression.Parser
  alias JidoClaw.Authorization.Actor
  alias JidoClaw.Cron.Job
  alias JidoClaw.Cron.Scheduler
  alias JidoClaw.Skills

  @impl true
  def run(params, context) do
    tenant_id = get_in(context, [:tool_context, :tenant_id]) || "default"
    actor = get_in(context, [:tool_context, :actor]) || Actor.system(tenant_id)
    project_dir = get_in(context, [:tool_context, :project_dir]) || File.cwd!()
    schedule_str = String.trim(params.schedule)

    with {:ok, target} <- parse_target(params[:target]),
         {:ok, target_attrs} <- build_target_attrs(target, params, project_dir),
         {:ok, schedule_tuple} <- parse_schedule_for(schedule_str) do
      schedule_and_persist(%{
        tenant_id: tenant_id,
        actor: actor,
        id: params[:id] || generate_id(params.task),
        task: params.task,
        mode: parse_mode(params[:mode]),
        schedule_str: schedule_str,
        schedule_tuple: schedule_tuple,
        target_attrs: target_attrs
      })
    end
  end

  defp schedule_and_persist(req) do
    opts =
      [id: req.id, task: req.task, schedule: req.schedule_tuple, mode: req.mode] ++
        Map.to_list(req.target_attrs)

    case Scheduler.schedule(req.tenant_id, opts) do
      {:ok, _id, _pid} -> persist(req)
      {:error, reason} -> {:error, "Failed to schedule task: #{inspect(reason)}"}
    end
  end

  defp persist(req) do
    {kind, value} = persistable_schedule(req.schedule_tuple)

    persist_attrs =
      %{
        job_id: req.id,
        task: req.task,
        mode: req.mode,
        schedule_kind: kind,
        schedule_value: value
      }
      |> Map.merge(req.target_attrs)

    case Job.upsert(persist_attrs, tenant: req.tenant_id, actor: req.actor) do
      {:ok, _job} -> {:ok, %{result: success_message(req)}}
      {:error, reason} -> {:error, "Failed to persist job: #{inspect(reason)}"}
    end
  end

  defp success_message(req) do
    "Scheduled task '#{req.id}': \"#{req.task}\"\n" <>
      "Schedule: #{format_schedule(req.schedule_str)}\n" <>
      "Mode: #{req.mode}\n" <>
      target_line(req.target_attrs) <>
      "Persisted — will reload on restart."
  end

  defp target_line(%{target: :workflow, workflow_name: name}), do: "Target: workflow (#{name})\n"
  defp target_line(_), do: "Target: agent\n"

  # Strict: agents may schedule only :agent or :workflow targets (never
  # :mfa / :system_job). Unlike parse_mode/1's silent fallback, an
  # unrecognised target errors so a typo can't quietly schedule an agent job.
  defp parse_target(nil), do: {:ok, :agent}
  defp parse_target("agent"), do: {:ok, :agent}
  defp parse_target("workflow"), do: {:ok, :workflow}

  defp parse_target(other),
    do: {:error, "Invalid target '#{other}'. Use 'agent' (default) or 'workflow'."}

  defp build_target_attrs(:agent, _params, _project_dir), do: {:ok, %{target: :agent}}

  defp build_target_attrs(:workflow, params, project_dir) do
    workflow = params[:workflow] |> to_string() |> String.trim()

    cond do
      workflow == "" ->
        {:error, "target 'workflow' requires a 'workflow' skill name. Use /skills to list them."}

      match?({:error, _}, Skills.get(workflow, project_dir)) ->
        {:error, "Skill '#{workflow}' not found. Use /skills to list available skills."}

      true ->
        {:ok,
         %{
           target: :workflow,
           workflow_name: workflow,
           workflow_input: %{"context" => params.task}
         }}
    end
  end

  defp parse_schedule_for(schedule_str) do
    case parse_schedule(schedule_str) do
      {:ok, tuple} ->
        {:ok, tuple}

      {:error, reason} ->
        {:error,
         "Invalid schedule '#{schedule_str}': #{reason}\n" <>
           "Use a cron expression (e.g., '0 9 * * *') or interval (e.g., 'every 1h', 'every 30m')."}
    end
  end

  defp persistable_schedule({:cron, expr}), do: {:cron, expr}
  defp persistable_schedule({:every, ms}), do: {:every, Integer.to_string(ms)}

  # -- Schedule Parsing --

  defp parse_schedule("every " <> interval) do
    parse_interval(String.trim(interval))
  end

  defp parse_schedule(expr) do
    # Try as cron expression (5 fields: min hour dom month dow)
    fields = String.split(expr)

    if length(fields) == 5 do
      case Parser.parse(expr) do
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
