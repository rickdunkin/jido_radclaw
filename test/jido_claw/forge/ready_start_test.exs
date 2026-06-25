defmodule JidoClaw.Forge.ReadyStartTest do
  @moduledoc """
  AR-8b-2 F2 (1.2): `Forge.start_session_ready/3` — the race-safe
  subscribe→start→await→status-assert entrypoint. Driven against a
  `StubSandbox`-backed session (persistence disabled, in-memory GenServer only,
  like `HarnessBootstrapEnvTest`) with `expected_backend: StubSandbox` so the
  Docker-default status assertion accepts the stub.
  """
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias JidoClaw.Forge
  alias JidoClaw.Test.StubSandbox

  setup do
    prev = Application.get_env(:jido_claw, JidoClaw.Forge.Persistence, [])
    Application.put_env(:jido_claw, JidoClaw.Forge.Persistence, enabled: false)
    on_exit(fn -> Application.put_env(:jido_claw, JidoClaw.Forge.Persistence, prev) end)
    :ok
  end

  defp sid(label), do: "ready_start_#{label}_#{:erlang.unique_integer([:positive])}"

  defp stop_quietly(session_id) do
    Forge.stop_session(session_id)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  test "a ready, usable session returns {:ok, sid} and stays ALIVE" do
    sid = sid("ok")
    on_exit(fn -> stop_quietly(sid) end)

    spec = %{runner: :shell, sandbox: StubSandbox, env: %{"GOOD" => "1"}}

    assert {:ok, ^sid} = Forge.start_session_ready(sid, spec, expected_backend: StubSandbox)
    # Success leaves the session alive (the front door uses it).
    assert {:ok, _handle} = Forge.get_handle(sid)
  end

  test "a harness that dies during bootstrap returns {:error, _} and is torn down" do
    sid = sid("down")
    on_exit(fn -> stop_quietly(sid) end)

    # The failing-env magic key makes bootstrap fail → the harness self-stops.
    spec = %{
      runner: :shell,
      sandbox: StubSandbox,
      env: %{StubSandbox.fail_inject_env_key() => "1"}
    }

    assert {:error, _reason} = Forge.start_session_ready(sid, spec, expected_backend: StubSandbox)
    assert {:error, :not_found} = Forge.get_handle(sid)
  end

  test "a session that broadcasts :ready but has no :default sandbox fails the usability assert" do
    sid = sid("deferred")
    on_exit(fn -> stop_quietly(sid) end)

    # A deferred session reaches `:ready` with NO provisioned default sandbox — the
    # exact case the status-check (not the broadcast alone) must reject.
    spec = %{runner: :shell, sandbox: StubSandbox, deferred_provision: true}

    assert {:error, _reason} = Forge.start_session_ready(sid, spec, expected_backend: StubSandbox)
    # Torn down — never returns {:ok, _} on a not-yet-usable session.
    assert {:error, :not_found} = Forge.get_handle(sid)
  end

  test "orphan guard: an await-ready timeout issues an unconditional stop on the minted key" do
    sid = sid("timeout")
    on_exit(fn -> stop_quietly(sid) end)

    # The stub's create blocks 1_000ms, so a 100ms await times out with the session
    # still provisioning — the helper must stop it unconditionally.
    spec = %{
      runner: :shell,
      sandbox: StubSandbox,
      sandbox_spec: %{create_sleep_ms: 1_000}
    }

    assert {:error, _reason} =
             Forge.start_session_ready(sid, spec,
               expected_backend: StubSandbox,
               await_timeout_ms: 100
             )

    # The unconditional stop terminates the still-provisioning child (give the
    # async stop a moment to land, then confirm it's gone).
    Process.sleep(50)
    assert {:error, :not_found} = Forge.get_handle(sid)
  end
end
