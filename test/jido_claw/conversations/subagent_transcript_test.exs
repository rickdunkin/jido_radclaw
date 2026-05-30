defmodule JidoClaw.Conversations.SubagentTranscriptTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias JidoClaw.Conversations.{Message, Session, SubagentTranscript}
  alias JidoClaw.Tenants.Tenant
  alias JidoClaw.Workspaces.Workspace

  setup do
    pid = Sandbox.start_owner!(JidoClaw.Repo, shared: true)
    # Keep the (terminal-signal-less) flush from blocking the 30s default.
    prev = Application.get_env(:jido_claw, :recorder_flush_timeout)
    Application.put_env(:jido_claw, :recorder_flush_timeout, 50)

    on_exit(fn ->
      if prev, do: Application.put_env(:jido_claw, :recorder_flush_timeout, prev)
      Sandbox.stop_owner(pid)
    end)

    seed_session("sub")
  end

  defp child_ctx(%{tenant_id: tenant_id, session: session}, tag) do
    %{
      session_uuid: session.id,
      tenant_id: tenant_id,
      agent_id: tag,
      subagent: true,
      actor: actor(tenant_id)
    }
  end

  defp actor(tenant_id), do: %{user_id: tenant_id, tenant_id: tenant_id}

  defp read_all(%{session: session, tenant_id: tenant_id}) do
    {:ok, rows} = Message.for_session(session.id, tenant: tenant_id, actor: actor(tenant_id))
    rows
  end

  describe "record_task/3 + record_result/3" do
    test "persist task (:user) and terminal (:assistant) rows tagged with the sub-agent id",
         seeded do
      tag = "coder_#{System.unique_integer([:positive])}"
      ctx = child_ctx(seeded, tag)
      rid = Ecto.UUID.generate()

      assert :ok = SubagentTranscript.record_task(ctx, rid, "do the thing")
      assert :done = SubagentTranscript.record_result(ctx, rid, {:ok, "all done"})

      rows = read_all(seeded)
      task = Enum.find(rows, &(&1.role == :user))
      terminal = Enum.find(rows, &(&1.role == :assistant))

      assert task.content == "do the thing"
      assert task.agent_id == tag
      assert task.subagent == true

      assert terminal.content == "all done"
      assert terminal.agent_id == tag
      assert terminal.subagent == true

      # Terminal sequence strictly greater than the task sequence.
      assert terminal.sequence > task.sequence
    end

    test "a failed outcome writes a terminal :system row (no dangling :user turn)", seeded do
      tag = "coder_#{System.unique_integer([:positive])}"
      ctx = child_ctx(seeded, tag)
      rid = Ecto.UUID.generate()

      :ok = SubagentTranscript.record_task(ctx, rid, "task")
      assert :error = SubagentTranscript.record_result(ctx, rid, {:error, :boom})

      terminal = Enum.find(read_all(seeded), &(&1.role == :system))

      assert terminal.subagent == true
      assert terminal.agent_id == tag
      assert terminal.content =~ "terminated without a result"
      assert terminal.content =~ "boom"
    end

    test "record_terminal/4 writes an explicit :assistant turn (step path)", seeded do
      tag = "wf_reviewer_#{System.unique_integer([:positive])}"
      ctx = child_ctx(seeded, tag)
      rid = Ecto.UUID.generate()

      :ok = SubagentTranscript.record_task(ctx, rid, "review it")
      assert :ok = SubagentTranscript.record_terminal(ctx, rid, :assistant, "looks good")

      assert Enum.any?(read_all(seeded), &(&1.role == :assistant and &1.content == "looks good"))
    end
  end

  describe "primary-view filter" do
    test "for_session_primary hides sub-agent rows; for_session includes them", seeded do
      tag = "coder_#{System.unique_integer([:positive])}"
      ctx = child_ctx(seeded, tag)
      rid = Ecto.UUID.generate()

      # An owner (main) row written directly, plus a sub-agent turn.
      {:ok, _main} =
        Message.append(
          %{
            session_id: seeded.session.id,
            role: :user,
            content: "main asks",
            agent_id: "main",
            subagent: false
          },
          tenant: seeded.tenant_id,
          actor: actor(seeded.tenant_id)
        )

      :ok = SubagentTranscript.record_task(ctx, rid, "sub task")
      :done = SubagentTranscript.record_result(ctx, rid, {:ok, "sub result"})

      a = actor(seeded.tenant_id)
      {:ok, all} = Message.for_session(seeded.session.id, tenant: seeded.tenant_id, actor: a)

      {:ok, primary} =
        Message.for_session_primary(seeded.session.id, tenant: seeded.tenant_id, actor: a)

      # Full read sees the sub-agent rows.
      assert Enum.any?(all, &(&1.agent_id == tag))
      # Primary view excludes every sub-agent row, keeps the main row.
      refute Enum.any?(primary, & &1.subagent)
      assert Enum.any?(primary, &(&1.content == "main asks"))
      refute Enum.any?(primary, &(&1.agent_id == tag))
    end
  end

  defp seed_session(label) do
    tenant_id = "tenant-sub-#{label}-#{System.unique_integer([:positive])}"
    {:ok, _} = Tenant.ensure(tenant_id)
    actor = actor(tenant_id)

    {:ok, ws} =
      Workspace.register(
        %{path: "/tmp/sub-#{label}-#{System.unique_integer([:positive])}", name: label},
        tenant: tenant_id,
        actor: actor
      )

    {:ok, session} =
      Session.start(
        %{
          workspace_id: ws.id,
          kind: :api,
          external_id: "ext-#{label}-#{System.unique_integer([:positive])}",
          started_at: DateTime.utc_now()
        },
        tenant: tenant_id,
        actor: actor
      )

    {:ok, %{tenant_id: tenant_id, workspace: ws, session: session}}
  end
end
