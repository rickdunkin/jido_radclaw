defmodule JidoClaw.Tools.GetAgentResult do
  # The agent-result payload maps are this tool's LLM-facing return contract,
  # assembled and returned here only.
  # reach:disable-for-this-file fixed_shape_map
  @moduledoc false
  use JidoClaw.Tools.Action,
    name: "get_agent_result",
    description:
      "Wait for a spawned child agent to finish its current task and return the result. Use this after spawn_agent (or send_to_agent for a follow-up) to collect the output.",
    category: "swarm",
    tags: ["swarm", "read"],
    output_schema: [
      agent_id: [type: :string, required: true],
      status: [type: :string, required: true],
      result: [type: {:or, [:string, :map]}],
      output_meta: [type: {:or, [:map, nil]}],
      message: [type: :string],
      error: [type: :string]
    ],
    schema: [
      agent_id: [type: :string, required: true, doc: "The agent ID returned by spawn_agent"],
      timeout: [type: :integer, required: false, doc: "Max wait time in ms (default: 60000)"]
    ]

  alias JidoClaw.AgentTracker
  alias JidoClaw.Error
  alias JidoClaw.Reasoning.Output
  alias JidoClaw.Tools.SwarmScope

  @impl Jido.Action
  def run(params, context) do
    agent_id = params.agent_id
    timeout = Map.get(params, :timeout, 60_000)

    with {:ok, scope_opts} <- SwarmScope.tracker_scope(context),
         {:ok, entry} <- SwarmScope.scoped_agent(agent_tracker(), agent_id, scope_opts) do
      case jido_runtime().whereis(agent_id) do
        nil ->
          {:error, Error.not_found(:agent, agent_id)}

        pid ->
          request_id = lookup_request_id(entry)
          await_and_handle(pid, agent_id, timeout, request_id)
      end
    end
  end

  defp await_and_handle(pid, agent_id, timeout, request_id) do
    result = await(pid, timeout, request_id)
    handle_result(result, agent_id, timeout, request_id)
    # Tool entry point: an Agent server fault must surface as a normalized
    # `{:error, ExecutionError}` to the LLM, not crash the calling tool.
  rescue
    # reach:disable-next-line bare_rescue
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

  defp await(pid, timeout, nil), do: await_module().completion(pid, timeout)

  defp await(pid, timeout, request_id) do
    await_module().completion(pid, timeout,
      status_path: [:requests, request_id, :status],
      result_path: [:requests, request_id],
      error_path: [:requests, request_id, :error]
    )
  end

  defp handle_result({:ok, %{status: :completed, result: request}}, agent_id, _t, request_id)
       when not is_nil(request_id) do
    typed = Output.typed_request_output(request)
    output_meta = Output.request_meta_output(request)

    response =
      maybe_put(
        %{
          agent_id: agent_id,
          status: "completed",
          result: typed || Output.extract_result(Output.request_result(request))
        },
        :output_meta,
        output_meta
      )

    {:ok, response}
  end

  defp handle_result({:ok, %{status: :failed, result: reason}}, agent_id, _t, request_id)
       when not is_nil(request_id) do
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

  defp handle_result({:ok, %{status: :completed} = result}, agent_id, _t, _request_id) do
    {:ok,
     %{
       agent_id: agent_id,
       status: "completed",
       result: Output.extract_result(result)
     }}
  end

  defp handle_result({:ok, %{status: :failed} = result}, agent_id, _t, _request_id) do
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
  end

  defp handle_result({:ok, result}, agent_id, _t, _request_id) do
    {:ok,
     %{
       agent_id: agent_id,
       status: "completed",
       result: Output.extract_result(result)
     }}
  end

  defp handle_result({:error, :timeout}, agent_id, timeout, _request_id) do
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
  end

  defp handle_result({:error, reason}, agent_id, _t, _request_id) do
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

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp lookup_request_id(%{request_id: request_id}) when is_binary(request_id), do: request_id
  defp lookup_request_id(_), do: nil

  defp failure_reason(%{error: error}) when is_binary(error), do: error
  defp failure_reason(%{error: error}), do: inspect(error)
  defp failure_reason(%{result: result}), do: Output.extract_result(result)
  defp failure_reason(result), do: inspect(result)

  defp jido_runtime do
    Application.get_env(:jido_claw, :jido_runtime, JidoClaw.Jido)
  end

  defp agent_tracker do
    Application.get_env(:jido_claw, :agent_tracker, AgentTracker)
  end

  defp await_module do
    Application.get_env(:jido_claw, :jido_await, Jido.Await)
  end
end
