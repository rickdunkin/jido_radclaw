defmodule JidoClaw.Conversations.HandoffDispatcherIntegrationTest do
  @moduledoc """
  End-to-end test of the handoff dispatcher seam in `JidoClaw.chat/4`:

    * the routed pid (handoff worker) is the one that receives the turn,
    * the preamble is prepended on the first post-handoff turn and
      dropped on subsequent turns,
    * a failed dispatch leaves `preamble_consumed?` false so the next
      user turn re-prepends the preamble.

  The `JidoClaw.Agent.ask_sync/3` call inside `run_chat_turn/8` is
  swapped out for a capture module via the `:ask_runtime` app env seam,
  so the test asserts on the dispatched `(pid, query, opts)` triple
  without needing a real LLM round-trip.
  """

  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Agent.Handoff.Registry, as: HandoffRegistry
  alias JidoClaw.Session.Supervisor, as: SessionSupervisor
  alias JidoClaw.Session.Worker, as: SessionWorker
  alias JidoClaw.Test.HandoffDispatchCapture
  alias JidoClaw.Tools.Handoff, as: HandoffTool

  setup do
    tmp = Path.join(System.tmp_dir!(), "dispatcher-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    %{tenant_id: tenant_id, session: session} =
      seed_full(tenant_label: "dispatcher", workspace: [path: tmp])

    runtime_session_id = session.external_id
    actor = actor_for(tenant_id)

    {:ok, _pid} = SessionSupervisor.ensure_session(tenant_id, runtime_session_id, actor: actor)
    :ok = SessionWorker.set_session_uuid(tenant_id, runtime_session_id, session.id)

    previous = %{
      ask_runtime: Application.fetch_env(:jido_claw, :ask_runtime),
      target: Application.fetch_env(:jido_claw, :dispatch_capture_target),
      response: Application.fetch_env(:jido_claw, :dispatch_capture_response),
      recorder_flush_timeout: Application.fetch_env(:jido_claw, :recorder_flush_timeout)
    }

    Application.put_env(:jido_claw, :ask_runtime, HandoffDispatchCapture)
    Application.put_env(:jido_claw, :dispatch_capture_target, self())
    Application.put_env(:jido_claw, :dispatch_capture_response, {:ok, "captured"})
    # The capture stub does not emit a Recorder completion signal, so
    # the default 30s flush wait would time out for every chat() call
    # under test. 50 ms is long enough for a real completion signal to
    # arrive in this test process but short enough to keep the suite snappy.
    Application.put_env(:jido_claw, :recorder_flush_timeout, 50)

    on_exit(fn ->
      restore_env(:ask_runtime, previous.ask_runtime)
      restore_env(:dispatch_capture_target, previous.target)
      restore_env(:dispatch_capture_response, previous.response)
      restore_env(:recorder_flush_timeout, previous.recorder_flush_timeout)
      HandoffRegistry.clear(tenant_id, runtime_session_id)
      File.rm_rf!(tmp)
    end)

    {:ok,
     tenant_id: tenant_id,
     session: session,
     runtime_session_id: runtime_session_id,
     actor: actor,
     tmp: tmp}
  end

  defp restore_env(key, :error), do: Application.delete_env(:jido_claw, key)
  defp restore_env(key, {:ok, value}), do: Application.put_env(:jido_claw, key, value)

  defp install_handoff(tenant_id, runtime_session_id, session_uuid, actor) do
    ctx = %{
      tool_context: %{
        tenant_id: tenant_id,
        session_id: runtime_session_id,
        session_uuid: session_uuid,
        agent_id: "main",
        agent_template: "main",
        actor: actor
      },
      request_id: Ecto.UUID.generate()
    }

    assert {:ok, _} =
             HandoffTool.run(
               %{
                 to_template: "reviewer",
                 message: "Please review the recent diff",
                 summary: "User asked for a review"
               },
               ctx
             )
  end

  test "first post-handoff turn carries the preamble and routes to the handoff worker",
       %{
         tenant_id: t,
         session: session,
         runtime_session_id: rsid,
         actor: actor,
         tmp: tmp
       } do
    install_handoff(t, rsid, session.id, actor)

    {:ok, _} =
      JidoClaw.chat(t, rsid, "Anything to fix?",
        kind: :api,
        workspace_id: tmp,
        external_id: rsid,
        actor: actor
      )

    assert_receive {:dispatch_capture, pid, message, opts}, 5_000

    routed_pid = Jido.whereis(JidoClaw.Jido, "handoff:#{session.id}:reviewer")
    main_pid = Jido.whereis(JidoClaw.Jido, rsid)

    assert is_pid(routed_pid)
    assert pid == routed_pid
    refute pid == main_pid

    assert String.starts_with?(message, "[HANDOFF CONTEXT")
    assert message =~ "Please review the recent diff"
    assert String.ends_with?(message, "Anything to fix?")

    tool_context = Keyword.fetch!(opts, :tool_context)
    assert tool_context.agent_id == "handoff:#{session.id}:reviewer"
    assert tool_context.agent_template == "reviewer"

    request_id = Keyword.fetch!(opts, :request_id)
    assert is_binary(request_id)
    assert {:ok, _} = Ecto.UUID.cast(request_id)
  end

  test "second turn after the handoff drops the preamble",
       %{
         tenant_id: t,
         session: session,
         runtime_session_id: rsid,
         actor: actor,
         tmp: tmp
       } do
    install_handoff(t, rsid, session.id, actor)

    {:ok, _} =
      JidoClaw.chat(t, rsid, "First turn",
        kind: :api,
        workspace_id: tmp,
        external_id: rsid,
        actor: actor
      )

    assert_receive {:dispatch_capture, first_pid, first_message, _}, 5_000
    assert String.starts_with?(first_message, "[HANDOFF CONTEXT")

    {:ok, _} =
      JidoClaw.chat(t, rsid, "Second turn",
        kind: :api,
        workspace_id: tmp,
        external_id: rsid,
        actor: actor
      )

    assert_receive {:dispatch_capture, second_pid, second_message, _}, 5_000
    refute second_message =~ "HANDOFF CONTEXT"
    assert second_pid == first_pid
  end

  test "failed dispatch leaves preamble_consumed? false so the next turn re-prepends",
       %{
         tenant_id: t,
         session: session,
         runtime_session_id: rsid,
         actor: actor,
         tmp: tmp
       } do
    # Reset registry + metadata in case a prior step seeded ownership.
    :ok = JidoClaw.reset_handoff(t, rsid, session.id, actor)

    install_handoff(t, rsid, session.id, actor)

    Application.put_env(:jido_claw, :dispatch_capture_response, {:error, :timeout})

    assert {:error, _} =
             JidoClaw.chat(t, rsid, "Will fail",
               kind: :api,
               workspace_id: tmp,
               external_id: rsid,
               actor: actor
             )

    assert_receive {:dispatch_capture, _, _, _}, 5_000

    owner = HandoffRegistry.owner(t, rsid)
    assert owner, "expected handoff owner to still be installed after failed dispatch"
    refute owner.preamble_consumed?

    Application.put_env(:jido_claw, :dispatch_capture_response, {:ok, "captured"})

    {:ok, _} =
      JidoClaw.chat(t, rsid, "Retry",
        kind: :api,
        workspace_id: tmp,
        external_id: rsid,
        actor: actor
      )

    assert_receive {:dispatch_capture, _, retry_message, _}, 5_000
    assert String.starts_with?(retry_message, "[HANDOFF CONTEXT")
  end
end
