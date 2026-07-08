defmodule JidoClaw.Forge.HarnessTeardownTest do
  @moduledoc """
  Docker write build: `Forge.stop_session/2` must actually reach
  `Sandbox.destroy/2`. `Manager.stop_session` terminates the harness child
  with a `:shutdown` exit — without `trap_exit` the harness dies WITHOUT
  running `terminate/2`, so `Sandbox.destroy` never fires and every
  externally-stateful sandbox (a docker microVM + its `.forge_env` workspace)
  leaks until the next boot's orphan reaper (found live by the write-build
  smoke: the microVM survived `stop_session` across a 90s drain). Latent for
  HostShell (its sandbox Agents are linked and die with the harness); load-
  bearing for docker.
  """
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias JidoClaw.Forge

  setup do
    prev = Application.get_env(:jido_claw, JidoClaw.Forge.Persistence, [])
    Application.put_env(:jido_claw, JidoClaw.Forge.Persistence, enabled: false)
    Application.put_env(:jido_claw, :stub_sandbox_destroy_notify, self())

    on_exit(fn ->
      Application.put_env(:jido_claw, JidoClaw.Forge.Persistence, prev)
      Application.delete_env(:jido_claw, :stub_sandbox_destroy_notify)
    end)

    :ok
  end

  test "stop_session runs Sandbox.destroy on the session's backend" do
    session_id = "teardown_#{:erlang.unique_integer([:positive])}"

    spec = %{
      runner: :shell,
      sandbox: JidoClaw.Test.StubSandbox,
      claim: false
    }

    {:ok, _} = Forge.start_session(session_id, spec)

    :ok = Forge.stop_session(session_id, :normal)

    # The destroy must fire as part of the stop — terminate/2's cleanup, not
    # a next-boot orphan reap.
    assert_receive {:stub_sandbox_destroy, _sandbox_id}, 5_000
  end
end
