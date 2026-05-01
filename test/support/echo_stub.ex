defmodule JidoClaw.Test.EchoStub do
  @moduledoc false

  # Minimal Jido.Agent stub used by the workflow scope-propagation
  # integration test. AgentServer requires the agent module to implement
  # Jido.Agent's macros (so `start_agent/2` succeeds), but we override
  # `ask_sync/3` to bypass the LLM pipeline entirely — the returned
  # `tool_context` is shipped to the test process so it can assert on
  # parent-scope inheritance.
  use Jido.Agent,
    name: "echo_stub",
    description: "Test-only echo agent that captures the tool_context"

  @doc """
  Override of the default ask_sync interface. Captures the supplied
  `tool_context` opt and forwards it to the configured target process
  (`Application.get_env(:jido_claw, :echo_stub_target, self())`) so the
  test can `assert_receive` against it. The pid argument is ignored —
  the AgentServer it points to is harmless infrastructure for this stub.
  """
  def ask_sync(_pid, _query, opts) when is_list(opts) do
    target = Application.get_env(:jido_claw, :echo_stub_target, self())
    send(target, {:echo_stub, :tool_context, Keyword.get(opts, :tool_context)})
    {:ok, %{last_answer: "echoed"}}
  end
end
