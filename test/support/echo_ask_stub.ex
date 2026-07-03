defmodule JidoClaw.Test.EchoAskStub do
  @moduledoc false

  # Variant of EchoStub used by AgentRunnerTest's async-path coverage.
  # Exports `ask/3` so that AgentRunner's `function_exported?(module, :ask, 3)`
  # check routes through the async branch (which awaits the request map via
  # Jido.AgentServer.await_completion). The returned id mirrors the request_id
  # supplied via opts so the AgentRunner `{:ok, %{id: ^request_id}}` match
  # succeeds. Mirrors EchoStub's send-to-target capture: the full received opts
  # are shipped to `:echo_ask_stub_target` (default `self()`, so untargeted
  # tests are unaffected) as `{:echo_ask_stub, :opts, opts}` — the AR-9 tests
  # bind on the tier key / `:request_transformer` opt AgentRunner adds.
  use Jido.Agent,
    name: "echo_ask_stub",
    description: "Test-only echo agent that exports ask/3 for async-path tests"

  @spec ask(pid(), term(), keyword()) :: {:ok, %{id: term()}}
  def ask(_pid, _query, opts) when is_list(opts) do
    request_id = Keyword.fetch!(opts, :request_id)
    target = Application.get_env(:jido_claw, :echo_ask_stub_target, self())
    send(target, {:echo_ask_stub, :opts, opts})
    {:ok, %{id: request_id}}
  end
end
