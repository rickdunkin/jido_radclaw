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
    Every job REQUIRES an outcome contract at creation — end_state (what success
    is), check (how each run verifies it), stop_bound (when to stop trying) —
    which is injected into every fired run.
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
      ],
      timezone: [
        type: :string,
        required: false,
        doc:
          "IANA timezone for interpreting a cron expression (e.g. 'America/New_York'). " <>
            "ONLY affects cron-expression schedules — it is inert for 'every <interval>' " <>
            "and absolute schedules. Defaults to 'Etc/UTC'."
      ],
      end_state: [
        type: :string,
        required: true,
        doc:
          "Outcome contract: the state a successful run leaves behind (e.g. 'the daily " <>
            "digest email is sent'). Must differ from 'check'. Max 500 chars."
      ],
      check: [
        type: :string,
        required: true,
        doc:
          "Outcome contract: HOW a run verifies the end state was reached (e.g. 'the " <>
            "send API returned 200 and the message id was logged'). Must differ from " <>
            "'end_state'. Max 500 chars."
      ],
      stop_bound: [
        type: :string,
        required: true,
        doc:
          "Outcome contract: when a run must stop trying (e.g. 'after 2 failed send " <>
            "attempts or 5 minutes, report the failure and stop'). Max 500 chars."
      ]
    ]

  alias JidoClaw.Authorization.Actor
  alias JidoClaw.Cron.Job
  alias JidoClaw.Cron.NextRun
  alias JidoClaw.Cron.OutcomeSpec
  alias JidoClaw.Cron.Owner, as: CronOwner
  alias JidoClaw.Skills

  @impl Jido.Action
  def run(params, context) do
    tenant_id = get_in(context, [:tool_context, :tenant_id]) || "default"
    actor = get_in(context, [:tool_context, :actor]) || Actor.system(tenant_id)
    project_dir = get_in(context, [:tool_context, :project_dir]) || File.cwd!()
    schedule_str = String.trim(params.schedule)

    with {:ok, target} <- parse_target(params[:target]),
         {:ok, target_attrs} <- build_target_attrs(target, params, project_dir),
         {:ok, timezone} <- parse_timezone(params[:timezone]),
         {:ok, schedule_tuple} <- parse_schedule_for(schedule_str),
         # Item 9 (OH1-3): the outcome contract is REQUIRED at creation for
         # agent-created jobs — validated + normalized here, persisted on the
         # row, and picked up live at fire time through owner reconcile.
         {:ok, outcome_spec} <-
           OutcomeSpec.validate(Map.take(params, [:end_state, :check, :stop_bound])) do
      schedule_and_persist(%{
        tenant_id: tenant_id,
        actor: actor,
        id: params[:id] || generate_id(params.task),
        task: params.task,
        mode: parse_mode(params[:mode]),
        schedule_str: schedule_str,
        schedule_tuple: schedule_tuple,
        target_attrs: target_attrs,
        timezone: timezone,
        outcome_spec: outcome_spec
      })
    end
  end

  # Persist first (the row is the source of truth), then hand off to the leader's
  # Cron.Owner. Validation already ran in run/2's `with`, so an invalid schedule
  # never reaches here. On a single node / leader notify_changed schedules the
  # worker synchronously; on a follower it casts to the leader (the durable row +
  # reconcile backstop is the guarantee). Re-using a job_id updates the row — and
  # because :upsert clears disabled_at, re-scheduling a disabled id re-enables it.
  defp schedule_and_persist(req) do
    {kind, value} = persistable_schedule(req.schedule_tuple)

    persist_attrs =
      Map.merge(
        %{
          job_id: req.id,
          task: req.task,
          mode: req.mode,
          schedule_kind: kind,
          schedule_value: value,
          timezone: req.timezone,
          # String-keyed wire form — the scheduler hydrates it back through
          # `OutcomeSpec.normalize/1` on reload/reconcile.
          metadata: %{"outcome_spec" => req.outcome_spec}
        },
        req.target_attrs
      )

    case Job.upsert(persist_attrs, tenant: req.tenant_id, actor: req.actor) do
      {:ok, _job} ->
        CronOwner.notify_changed(req.tenant_id)
        {:ok, %{result: success_message(req)}}

      {:error, reason} ->
        {:error, "Failed to persist job: #{inspect(reason)}"}
    end
  end

  defp success_message(req) do
    "Scheduled task '#{req.id}': \"#{req.task}\"\n" <>
      "Schedule: #{format_schedule(req.schedule_str)}\n" <>
      "Mode: #{req.mode}\n" <>
      target_line(req.target_attrs) <>
      timezone_line(req) <>
      "Outcome contract recorded (injected into every fired run).\n" <>
      "Persisted — will reload on restart."
  end

  defp target_line(%{target: :workflow, workflow_name: name}), do: "Target: workflow (#{name})\n"
  defp target_line(_), do: "Target: agent\n"

  # A non-default timezone only shifts :cron firing — state that plainly so the
  # agent never expects it to move an `every`/`:at` schedule. UTC stays silent.
  defp timezone_line(%{timezone: "Etc/UTC"}), do: ""

  defp timezone_line(%{schedule_tuple: {:cron, _}, timezone: tz}),
    do: "Timezone: #{tz} (applies to cron firing)\n"

  defp timezone_line(%{timezone: tz}),
    do: "Timezone: #{tz} (ignored — only cron schedules use a timezone)\n"

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
    workflow =
      params[:workflow]
      |> to_string()
      |> String.trim()

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

  # Strict, in the style of parse_target/1: an unrecognised zone errors rather
  # than silently falling back to UTC, so a typo can't quietly schedule in the
  # wrong zone. Validated against the configured tz database via DateTime.now/1.
  # Note: timezone only affects :cron schedules (see timezone_line/1).
  defp parse_timezone(nil), do: {:ok, "Etc/UTC"}

  defp parse_timezone(tz) when is_binary(tz) do
    trimmed = String.trim(tz)

    cond do
      trimmed == "" ->
        {:ok, "Etc/UTC"}

      match?({:ok, _}, DateTime.now(trimmed)) ->
        {:ok, trimmed}

      true ->
        {:error,
         "Invalid timezone '#{trimmed}'. Use an IANA name like 'America/New_York', " <>
           "or omit it for UTC."}
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
    # Try as cron expression (5 fields: min hour dom month dow). The 5-field
    # guard already rejects @reboot (1 field); routing the inner check through
    # NextRun.compute_next_cron_utc/2 additionally rejects uncomputable crons and
    # never lets a Parser raise escape. No timezone input here, so validate UTC.
    fields = String.split(expr)

    if match?([_, _, _, _, _], fields) do
      case NextRun.compute_next_cron_utc(expr, "Etc/UTC") do
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
