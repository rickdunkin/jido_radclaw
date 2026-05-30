defmodule JidoClaw.StartupTest do
  use ExUnit.Case, async: true

  alias JidoClaw.Startup

  # Captures the system prompt the injection path sets, mirroring the real
  # call chain used in production: `Jido.AI.set_system_prompt/2` →
  # `Jido.AgentServer.call/2` → `GenServer.call(pid, {:signal, signal})`,
  # replying `{:ok, _}`. A plain GenServer is sufficient — the injection
  # path only does a signal call, it does not require a real Jido agent.
  defmodule CapturingAgent do
    use GenServer

    def start_link(test_pid), do: GenServer.start_link(__MODULE__, test_pid)

    @impl true
    def init(test_pid), do: {:ok, test_pid}

    @impl true
    def handle_call(
          {:signal, %{type: "ai.react.set_system_prompt", data: %{system_prompt: prompt}}},
          _from,
          test_pid
        ) do
      send(test_pid, {:injected_prompt, prompt})
      {:reply, {:ok, %{}}, test_pid}
    end

    def handle_call({:signal, _signal}, _from, state), do: {:reply, {:ok, %{}}, state}
  end

  describe "inject_handoff_prompt/4" do
    test "renders a message-only handoff context above the base prompt" do
      {:ok, pid} = CapturingAgent.start_link(self())
      # A prompt_snapshot makes the resolved base prompt deterministic, so
      # "the base is appended-to, not replaced" is a clean assertion.
      session = %{metadata: %{"prompt_snapshot" => "BASE_PROMPT_MARKER"}}

      assert :ok =
               Startup.inject_handoff_prompt(pid, File.cwd!(), session, %{
                 message: "MESSAGE_MARKER"
               })

      assert_receive {:injected_prompt, prompt}, 2_000
      # The handoff message survives into the always-kept system prompt...
      assert prompt =~ "MESSAGE_MARKER"
      assert prompt =~ "HANDOFF CONTEXT"
      assert prompt =~ "Message: MESSAGE_MARKER"
      # ...and the base prompt is appended-to, not replaced.
      assert prompt =~ "BASE_PROMPT_MARKER"
    end
  end
end
