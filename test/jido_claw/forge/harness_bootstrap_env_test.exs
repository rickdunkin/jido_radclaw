defmodule JidoClaw.Forge.HarnessBootstrapEnvTest do
  @moduledoc """
  Spec-env injection failures must fail bootstrap, not be silently
  skipped. Drives the Harness through StubSandbox's magic-key failure
  seam (see `JidoClaw.Test.StubSandbox.fail_inject_env_key/0`) for the
  main `:bootstrap` flow, the lazy `bootstrap_sync` flow, and the
  attached-sandbox `bootstrap_client` flow. `recover_bootstrap` shares
  the same `inject_spec_env` helper and else-clause shape.
  """
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias JidoClaw.Forge
  alias JidoClaw.Forge.PubSub, as: ForgePubSub
  alias JidoClaw.Test.StubSandbox

  @timeout 10_000

  setup do
    # In-memory GenServer behavior only — same persistence opt-out as
    # MultiSandboxTest to avoid Ecto sandbox ownership issues.
    prev = Application.get_env(:jido_claw, JidoClaw.Forge.Persistence, [])
    Application.put_env(:jido_claw, JidoClaw.Forge.Persistence, enabled: false)

    on_exit(fn -> Application.put_env(:jido_claw, JidoClaw.Forge.Persistence, prev) end)

    :ok
  end

  defp failing_env, do: %{StubSandbox.fail_inject_env_key() => "1"}

  defp stop_quietly(session_id) do
    Forge.stop_session(session_id)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  test "benign spec env on a stub sandbox still reaches :ready" do
    sid = "harness_env_ok_#{:erlang.unique_integer([:positive])}"
    ForgePubSub.subscribe(sid)
    on_exit(fn -> stop_quietly(sid) end)

    spec = %{runner: :shell, sandbox: StubSandbox, env: %{"GOOD" => "1"}}

    {:ok, _} = Forge.start_session(sid, spec)
    assert_receive {:ready, ^sid}, @timeout
  end

  test ":bootstrap stops the session when spec env injection fails" do
    sid = "harness_env_boot_#{:erlang.unique_integer([:positive])}"
    ForgePubSub.subscribe(sid)
    on_exit(fn -> stop_quietly(sid) end)

    spec = %{runner: :shell, sandbox: StubSandbox, env: failing_env()}

    {:ok, _} = Forge.start_session(sid, spec)

    assert_receive {:stopped, {:bootstrap_failed, :inject_env_refused}}, @timeout
    refute_received {:ready, ^sid}
  end

  test "attach_sandbox surfaces a spec env injection failure as bootstrap failure" do
    sid = "harness_env_attach_#{:erlang.unique_integer([:positive])}"
    ForgePubSub.subscribe(sid)
    on_exit(fn -> stop_quietly(sid) end)

    # Main sandbox is HostShell (:fake) — its inject_env is an in-memory
    # update that always succeeds, so the session comes up despite the
    # poisoned env. The attached StubSandbox then refuses that same env
    # during bootstrap_client/2.
    spec = %{runner: :shell, sandbox: :fake, env: failing_env()}

    {:ok, _} = Forge.start_session(sid, spec)
    assert_receive {:ready, ^sid}, @timeout

    assert {:error, {:bootstrap_failed, :inject_env_refused}} =
             Forge.attach_sandbox(sid, :stub, %{sandbox: StubSandbox})

    {:ok, status} = Forge.status(sid)
    refute :stub in status.sandboxes
  end

  test "lazy provisioning (bootstrap_sync) surfaces a spec env injection failure" do
    sid = "harness_env_sync_#{:erlang.unique_integer([:positive])}"
    ForgePubSub.subscribe(sid)
    on_exit(fn -> stop_quietly(sid) end)

    spec = %{
      runner: :shell,
      sandbox: StubSandbox,
      env: failing_env(),
      deferred_provision: true
    }

    {:ok, _} = Forge.start_session(sid, spec)
    assert_receive {:ready, ^sid}, @timeout

    assert {:error, {:provision_failed, {:bootstrap_failed, :inject_env_refused}}} =
             Forge.exec(sid, "echo hi")
  end
end
