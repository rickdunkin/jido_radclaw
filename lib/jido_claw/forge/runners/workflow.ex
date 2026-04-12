defmodule JidoClaw.Forge.Runners.Workflow do
  @behaviour JidoClaw.Forge.Runner
  alias JidoClaw.Forge.{Runner, Sandbox}
  require Logger

  @impl true
  def init(_client, config) do
    steps = Map.get(config, :steps, [])
    {:ok, %{current_step: 0, step_results: %{}, workflow: %{steps: steps}}}
  end

  @impl true
  def run_iteration(client, state, _opts) do
    steps = state.workflow.steps
    index = state.current_step

    if index >= length(steps) do
      {:ok, Runner.done(state.step_results)}
    else
      step = Enum.at(steps, index)
      execute_step(client, step, state)
    end
  end

  @impl true
  def apply_input(_client, input, state) do
    step = Enum.at(state.workflow.steps, state.current_step)
    step_id = Map.get(step, "id", "step_#{state.current_step}")

    new_results = Map.put(state.step_results, step_id, %{input: input})
    {:ok, %{state | current_step: state.current_step + 1, step_results: new_results}}
  end

  defp execute_step(client, %{"type" => "exec"} = step, state) do
    command = interpolate(Map.get(step, "command", ""), state.step_results)
    step_id = Map.get(step, "id", "step_#{state.current_step}")

    case Sandbox.exec(client, command, []) do
      {output, 0} ->
        new_results = Map.put(state.step_results, step_id, %{output: output, exit_code: 0})
        new_state = %{state | current_step: state.current_step + 1, step_results: new_results}
        {:ok, Map.merge(Runner.continue(output), %{metadata: %{state: new_state}})}

      {output, code} ->
        {:ok, Runner.error("step #{step_id} failed with exit #{code}", output)}
    end
  end

  defp execute_step(_client, %{"type" => "prompt"} = step, _state) do
    question = Map.get(step, "prompt", "Input needed")
    {:ok, Runner.needs_input(question)}
  end

  defp execute_step(client, %{"type" => "condition"} = step, state) do
    check = Map.get(step, "check", %{})
    then_target = Map.get(step, "then")
    else_target = Map.get(step, "else")

    matched =
      Enum.all?(check, fn {step_id, expected} ->
        result = Map.get(state.step_results, step_id, %{})
        to_string(Map.get(result, :output, "")) =~ to_string(expected)
      end)

    target = if matched, do: then_target, else: else_target

    if target do
      target_index = find_step_index(state.workflow.steps, target)
      new_state = %{state | current_step: target_index}
      run_iteration(client, new_state, [])
    else
      new_state = %{state | current_step: state.current_step + 1}
      {:ok, Map.merge(Runner.continue(nil), %{metadata: %{state: new_state}})}
    end
  end

  defp execute_step(client, %{"type" => "call", "handler" => handler_mod} = step, state) do
    args = interpolate_map(Map.get(step, "args", %{}), state.step_results)
    step_id = Map.get(step, "id", "step_#{state.current_step}")
    handler = Module.concat([handler_mod])

    case handler.execute(client, args, []) do
      {:ok, result} ->
        new_results = Map.put(state.step_results, step_id, result)
        new_state = %{state | current_step: state.current_step + 1, step_results: new_results}
        {:ok, Map.merge(Runner.continue(result), %{metadata: %{state: new_state}})}

      {:needs_input, question} ->
        {:ok, Runner.needs_input(question)}

      {:error, reason} ->
        {:ok, Runner.error(reason)}
    end
  end

  defp execute_step(_client, %{"type" => "noop"}, state) do
    new_state = %{state | current_step: state.current_step + 1}
    {:ok, Map.merge(Runner.continue(nil), %{metadata: %{state: new_state}})}
  end

  defp execute_step(_client, step, _state) do
    {:ok, Runner.error({:unknown_step_type, step})}
  end

  defp find_step_index(steps, target_id) do
    Enum.find_index(steps, fn s -> Map.get(s, "id") == target_id end) || 0
  end

  defp interpolate(text, results) when is_binary(text) do
    Regex.replace(~r/\{\{(\w+)\.(\w+)\}\}/, text, fn _, step_id, field ->
      result = Map.get(results, step_id, %{})
      to_string(Map.get(result, String.to_existing_atom(field), Map.get(result, field, "")))
    end)
  end

  defp interpolate(other, _results), do: other

  defp interpolate_map(map, results) when is_map(map) do
    Map.new(map, fn {k, v} -> {k, interpolate(v, results)} end)
  end
end
