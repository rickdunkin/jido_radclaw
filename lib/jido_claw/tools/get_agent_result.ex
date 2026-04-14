defmodule JidoClaw.Tools.GetAgentResult do
  use Jido.Action,
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

  @impl true
  def run(params, _context) do
    agent_id = params.agent_id
    timeout = Map.get(params, :timeout, 60_000)

    case JidoClaw.Jido.whereis(agent_id) do
      nil ->
        {:error, "Agent '#{agent_id}' not found. It may have already completed and stopped."}

      pid ->
        try do
          case Jido.Await.completion(pid, timeout) do
            {:ok, result} ->
              {:ok, %{agent_id: agent_id, status: "completed", result: extract_result(result)}}

            {:error, :timeout} ->
              {:ok,
               %{
                 agent_id: agent_id,
                 status: "still_running",
                 message: "Agent hasn't finished yet. Try again later or increase timeout."
               }}

            {:error, reason} ->
              {:ok, %{agent_id: agent_id, status: "failed", error: inspect(reason)}}
          end
        rescue
          e -> {:ok, %{agent_id: agent_id, status: "error", error: Exception.message(e)}}
        end
    end
  end

  defp extract_result(%{last_answer: answer}) when is_binary(answer), do: answer
  defp extract_result(%{answer: answer}) when is_binary(answer), do: answer
  defp extract_result(%{text: text}) when is_binary(text), do: text
  defp extract_result(result) when is_binary(result), do: result
  defp extract_result(result), do: inspect(result, limit: :infinity, pretty: true)
end
