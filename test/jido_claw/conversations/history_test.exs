defmodule JidoClaw.Conversations.HistoryTest do
  @moduledoc """
  Regression suite for the legacy `[user|assistant|system]` chat-history
  contract that Phase 2 §2.7 promised to preserve. Both the hot-cache
  (live worker) and cold-cache (Postgres-only) read paths must filter
  out tool/reasoning rows so legacy callers (REPL view, web LiveView,
  channel adapters) keep their existing shape.
  """
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Conversations.Message

  describe "history/2 (hot path — live Session.Worker)" do
    test "returns only :user/:assistant/:system rows from the in-memory cache" do
      %{tenant_id: tenant, external_id: external_id, project_dir: _project_dir, session: session} =
        seed_session_with_history()

      # Boot the worker and bind it to the persisted Session UUID. The
      # set_session_uuid call is what triggers `load_messages/1` to
      # hydrate `state.messages` from Postgres — without it the in-memory
      # cache stays empty regardless of seeded rows.
      {:ok, _pid} =
        JidoClaw.Session.Supervisor.ensure_session(tenant, external_id, actor: actor_for(tenant))

      :ok = JidoClaw.Session.Worker.set_session_uuid(tenant, external_id, session.id)

      msgs = JidoClaw.history(tenant, external_id)

      roles = Enum.map(msgs, & &1.role)

      assert roles == ["user", "assistant", "system"], """
      Expected only chat-role entries from history/2; got #{inspect(roles)}
      """
    end
  end

  describe "history/3 (cold path — Postgres only)" do
    test "filters tool/reasoning rows out of the cold-cache view" do
      %{tenant_id: tenant, external_id: external_id, project_dir: project_dir} =
        seed_session_with_history()

      # `history/3` reads Postgres directly via Conversations.Message.for_session/1
      # and never touches Session.Worker (verified at lib/jido_claw.ex:293-313),
      # so we don't need to bring up — let alone tear down — the worker. The
      # rows seeded by seed_session_with_history/0 are all this test needs.
      msgs =
        JidoClaw.history(tenant, external_id, kind: :api, workspace_id: project_dir)

      roles = Enum.map(msgs, & &1.role)

      assert roles == ["user", "assistant", "system"], """
      Expected the cold-cache view to drop tool/reasoning rows;
      got #{inspect(roles)}
      """
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp seed_session_with_history do
    tenant_id = seed_tenant("hist")
    project_dir = "/tmp/hist-#{System.unique_integer([:positive])}"
    external_id = "ext-hist-#{System.unique_integer([:positive])}"

    {:ok, ws} = seed_workspace(tenant_id, path: project_dir, name: "hist")

    {:ok, session} =
      seed_session(tenant_id, ws.id, kind: :api, external_id: external_id)

    request_id = "req-hist-#{System.unique_integer([:positive])}"
    tool_call_id = "call-hist-#{System.unique_integer([:positive])}"

    # Seed a representative multi-role transcript so we can verify that
    # both filters (worker hydration + cold-path) drop the non-chat rows.
    Message.append!(%{session_id: session.id, role: :user, content: "hello"},
      tenant: tenant_id,
      actor: actor_for(tenant_id)
    )

    Message.append!(
      %{
        session_id: session.id,
        request_id: request_id,
        role: :tool_call,
        content: "ls()",
        tool_call_id: tool_call_id
      },
      tenant: tenant_id,
      actor: actor_for(tenant_id)
    )

    Message.append!(
      %{
        session_id: session.id,
        request_id: request_id,
        role: :tool_result,
        content: "ls() -> ok",
        tool_call_id: tool_call_id
      },
      tenant: tenant_id,
      actor: actor_for(tenant_id)
    )

    Message.append!(
      %{
        session_id: session.id,
        request_id: request_id,
        role: :reasoning,
        content: "thinking..."
      },
      tenant: tenant_id,
      actor: actor_for(tenant_id)
    )

    Message.append!(%{session_id: session.id, role: :assistant, content: "hi back"},
      tenant: tenant_id,
      actor: actor_for(tenant_id)
    )

    Message.append!(%{session_id: session.id, role: :system, content: "system ack"},
      tenant: tenant_id,
      actor: actor_for(tenant_id)
    )

    %{
      tenant_id: tenant_id,
      external_id: external_id,
      project_dir: project_dir,
      workspace: ws,
      session: session
    }
  end
end
