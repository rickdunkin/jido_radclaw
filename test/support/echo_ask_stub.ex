defmodule JidoClaw.Test.EchoAskStub do
  @moduledoc false

  # Variant of EchoStub used by StepActionTest's async-path coverage.
  # Exports `ask/3` so that StepAction's `function_exported?(module, :ask, 3)`
  # check at run_step/7 routes through the async branch (which awaits the
  # request map via Jido.AgentServer.await_completion). The returned id
  # mirrors the request_id supplied via opts so the StepAction
  # `{:ok, %{id: ^request_id}}` match succeeds.
  use Jido.Agent,
    name: "echo_ask_stub",
    description: "Test-only echo agent that exports ask/3 for async-path tests"

  def ask(_pid, _query, opts) when is_list(opts) do
    request_id = Keyword.fetch!(opts, :request_id)
    {:ok, %{id: request_id}}
  end
end
