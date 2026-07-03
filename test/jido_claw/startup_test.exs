defmodule JidoClaw.StartupTest do
  use ExUnit.Case, async: true

  alias JidoClaw.Startup
  alias JidoClaw.Test.CapturingAgent

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
