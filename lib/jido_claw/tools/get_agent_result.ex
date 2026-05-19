defmodule JidoClaw.Tools.GetAgentResult do
  @moduledoc false
  use JidoClaw.Tools.Action,
    name: "get_agent_result",
    description:
      "Wait for a spawned child agent to finish its task and return the result. Use this after spawn_agent to collect the output.",
    category: "swarm",
    tags: ["swarm", "read"],
    output_schema: [
      agent_id: [type: :string, required: true],
      status: [type: :string, required: true],
      result: [type: :string],
      message: [type: :string],
      error: [type: :string]
    ],
    schema: [
      agent_id: [type: :string, required: true, doc: "The agent ID returned by spawn_agent"],
      timeout: [type: :integer, required: false, doc: "Max wait time in ms (default: 60000)"]
    ]

  alias JidoClaw.Error
  alias JidoClaw.Reasoning.Output

  @impl true
  def run(params, _context) do
    agent_id = params.agent_id
    timeout = Map.get(params, :timeout, 60_000)

    case jido_runtime().whereis(agent_id) do
      nil ->
        {:error, Error.not_found(:agent, agent_id)}

      pid ->
        try do
          case await_module().completion(pid, timeout) do
            {:ok, %{status: :completed} = result} ->
              {:ok,
               %{
                 agent_id: agent_id,
                 status: "completed",
                 result: Output.extract_result(result)
               }}

            {:ok, %{status: :failed} = result} ->
              {:error,
               Error.execution_error("Agent failed.",
                 phase: :await,
                 details: %{
                   agent_id: agent_id,
                   status: "failed",
                   code: :failed,
                   error: failure_reason(result)
                 }
               )}

            {:ok, result} ->
              {:ok,
               %{
                 agent_id: agent_id,
                 status: "completed",
                 result: Output.extract_result(result)
               }}

            {:error, :timeout} ->
              {:error,
               Error.execution_error(
                 "Agent hasn't finished yet. Try again later or increase timeout.",
                 phase: :timeout,
                 details: %{
                   agent_id: agent_id,
                   status: "still_running",
                   code: :still_running,
                   timeout: timeout
                 }
               )}

            {:error, reason} ->
              {:error,
               Error.execution_error("Agent failed.",
                 phase: :await,
                 details: %{
                   agent_id: agent_id,
                   status: "failed",
                   code: :failed,
                   error: inspect(reason)
                 }
               )}
          end
        rescue
          e ->
            {:error,
             Error.execution_error(Exception.message(e),
               phase: :await,
               details: %{
                 agent_id: agent_id,
                 status: "error",
                 code: :error,
                 error: Exception.message(e)
               }
             )}
        end
    end
  end

  defp failure_reason(%{error: error}) when is_binary(error), do: error
  defp failure_reason(%{error: error}), do: inspect(error)
  defp failure_reason(%{result: result}), do: Output.extract_result(result)
  defp failure_reason(result), do: inspect(result)

  defp jido_runtime do
    Application.get_env(:jido_claw, :jido_runtime, JidoClaw.Jido)
  end

  defp await_module do
    Application.get_env(:jido_claw, :jido_await, Jido.Await)
  end
end
