defmodule JidoClaw.Workflows.StepAction do
  @moduledoc """
  A Jido.Action that executes a single skill step by spawning an agent
  from a template, running a task via ask_sync, and returning the result.

  Used as a node in jido_composer Workflows to replace the hand-rolled
  sequential agent spawning in RunSkill.
  """

  use Jido.Action,
    name: "skill_step",
    description: "Execute a skill step by spawning a templated agent and running a task",
    schema: [
      template: [type: :string, required: true, doc: "Agent template name (e.g. coder, reviewer)"],
      task: [type: :string, required: true, doc: "Task prompt for the agent"],
      project_dir: [type: :string, required: false, doc: "Project directory for tool context"],
      workspace_id: [
        type: :string,
        required: false,
        doc: "Workspace ID for shared VFS/shell state across steps"
      ]
    ]

  require Logger

  @impl true
  def run(params, context) do
    template_name = params.template
    task = params.task
    project_dir = Map.get(params, :project_dir, File.cwd!())
    step_name = Map.get(params, :name, template_name)

    with {:ok, template} <- JidoClaw.Agent.Templates.get(template_name),
         tag = "wf_#{template_name}_#{:erlang.unique_integer([:positive])}",
         workspace_id = resolve_workspace_id(params, context, tag),
         {:ok, pid} <- JidoClaw.Jido.start_agent(template.module, id: tag) do
      try do
        case template.module.ask_sync(pid, task,
               timeout: 180_000,
               tool_context: %{
                 project_dir: project_dir,
                 workspace_id: workspace_id,
                 agent_id: tag
               }
             ) do
          {:ok, result} ->
            text = extract_result(result)

            {:ok,
             %JidoClaw.Workflows.StepResult{
               name: step_name,
               template: template_name,
               result: text,
               artifacts: extract_artifacts(text)
             }}

          {:error, reason} ->
            {:error, "Step #{template_name} failed: #{inspect(reason)}"}

          other ->
            {:ok,
             %JidoClaw.Workflows.StepResult{
               name: step_name,
               template: template_name,
               result: inspect(other)
             }}
        end
      rescue
        e -> {:error, "Step #{template_name} crashed: #{Exception.message(e)}"}
      after
        if Process.alive?(pid), do: Process.exit(pid, :normal)
      end
    else
      {:error, reason} -> {:error, "Step #{template_name} setup failed: #{inspect(reason)}"}
    end
  end

  @doc """
  Append an ARTIFACTS output contract to the task prompt when the step
  has a `produces` block. Without this instruction, agents won't emit
  the fenced block that `extract_artifacts/1` looks for.
  """
  @spec inject_produces_instruction(String.t(), map() | nil) :: String.t()
  def inject_produces_instruction(task, nil), do: task
  def inject_produces_instruction(task, produces) when map_size(produces) == 0, do: task

  def inject_produces_instruction(task, _produces) do
    task <>
      "\n\n" <>
      """
      If you discover runtime details (URLs, ports, generated file paths) that differ from the
      expected configuration, report them using this format at the end of your response:

      ARTIFACTS:
      url: <actual URL>
      port: <actual port>
      files: <comma-separated file paths>
      """
  end

  @doc """
  Extract key-value pairs from a fenced ARTIFACTS: block in agent output.

  Returns an empty map if no block is found.
  """
  @spec extract_artifacts(String.t()) :: map()
  def extract_artifacts(text) when is_binary(text) do
    case Regex.run(~r/ARTIFACTS:\n((?:.+\n?)+)/i, text) do
      [_, block] ->
        block
        |> String.split("\n", trim: true)
        |> Enum.reduce(%{}, fn line, acc ->
          case String.split(line, ":", parts: 2) do
            [key, value] -> Map.put(acc, String.trim(key), String.trim(value))
            _ -> acc
          end
        end)

      nil ->
        %{}
    end
  end

  def extract_artifacts(_), do: %{}

  # Prefer the workspace_id passed in by the caller (workflow driver or parent
  # agent) so every step in a skill/plan shares one VFS + shell session. Fall
  # back to a per-step ID only when the caller didn't thread one through —
  # existing tests and ad-hoc StepAction.run/2 callers rely on that path.
  defp resolve_workspace_id(params, context, tag) do
    Map.get(params, :workspace_id) ||
      Map.get(context, :workspace_id) ||
      get_in(context, [:tool_context, :workspace_id]) ||
      "wf_#{tag}"
  end

  defp extract_result(%{last_answer: answer}) when is_binary(answer), do: answer
  defp extract_result(%{answer: answer}) when is_binary(answer), do: answer
  defp extract_result(%{text: text}) when is_binary(text), do: text
  defp extract_result(result) when is_binary(result), do: result
  defp extract_result(result), do: inspect(result, limit: :infinity, pretty: true)
end
