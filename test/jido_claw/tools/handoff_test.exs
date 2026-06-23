defmodule JidoClaw.Tools.HandoffTest do
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Agent.Handoff.Registry, as: HandoffRegistry
  alias JidoClaw.Conversations.Message
  alias JidoClaw.Conversations.Session, as: ConversationsSession
  alias JidoClaw.Session.Supervisor, as: SessionSupervisor
  alias JidoClaw.Session.Worker, as: SessionWorker
  alias JidoClaw.Tools.Handoff, as: HandoffTool
  alias JidoClaw.TraceTestHelpers

  setup do
    %{tenant_id: tenant_id, session: session} = seed_full(tenant_label: "handoff")
    runtime_session_id = session.external_id

    # Start a Session.Worker for the runtime session so the tool's
    # best-effort system-message write has somewhere to land.
    actor = actor_for(tenant_id)

    {:ok, _pid} = SessionSupervisor.ensure_session(tenant_id, runtime_session_id, actor: actor)

    :ok = SessionWorker.set_session_uuid(tenant_id, runtime_session_id, session.id)

    on_exit(fn ->
      HandoffRegistry.clear(tenant_id, runtime_session_id)
    end)

    {:ok,
     tenant_id: tenant_id, session: session, runtime_session_id: runtime_session_id, actor: actor}
  end

  defp build_context(t, runtime_session_id, session_uuid, opts \\ []) do
    shape = Keyword.get(opts, :shape, :nested)
    agent_template = Keyword.get(opts, :agent_template, "main")
    request_id = Keyword.get(opts, :request_id, Ecto.UUID.generate())

    actor = if is_binary(t), do: actor_for(t), else: nil

    inner = %{
      tenant_id: t,
      session_id: runtime_session_id,
      session_uuid: session_uuid,
      agent_id: "main",
      agent_template: agent_template,
      actor: actor
    }

    case shape do
      :nested -> %{tool_context: inner, request_id: request_id}
      :flat -> Map.put(inner, :request_id, request_id)
    end
  end

  describe "happy path" do
    test "installs registry, mirrors metadata, writes :system message, emits telemetry",
         %{tenant_id: t, session: session, runtime_session_id: rsid} do
      handler_id = "handoff-#{System.unique_integer([:positive])}"
      test_pid = self()

      :ok =
        :telemetry.attach(
          handler_id,
          [:jido_claw, :handoff, :event],
          fn _event, measurements, metadata, _ ->
            send(test_pid, {:telemetry, measurements, metadata})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      request_id = Ecto.UUID.generate()
      ctx = build_context(t, rsid, session.id, request_id: request_id)

      assert {:ok, payload} =
               HandoffTool.run(
                 %{
                   to_template: "reviewer",
                   message: "Please review the recent diff",
                   summary: "User wants a review"
                 },
                 ctx
               )

      assert payload.status == "handed_off"
      assert payload.to_template == "reviewer"
      assert payload.message == "Please review the recent diff"
      assert payload.conversation_id == session.id

      # Registry has the new owner.
      owner = HandoffRegistry.owner(t, rsid)
      assert owner.template == "reviewer"
      assert owner.handoff.to_template == "reviewer"
      assert owner.handoff.message == "Please review the recent diff"
      assert owner.handoff.summary == "User wants a review"
      assert owner.handoff.from_template == "main"
      assert owner.preamble_consumed? == false

      # Durable metadata mirror.
      assert {:ok, fresh} =
               ConversationsSession.by_id(session.id, tenant: t, actor: actor_for(t))

      assert fresh.metadata["current_agent_template"] == "reviewer"

      # Durable :system message — worker-scoped identity (R2) + enriched body.
      assert {:ok, rows} = Message.for_session(session.id, tenant: t, actor: actor_for(t))

      system_row =
        Enum.find(rows, fn row ->
          row.role == :system and row.content =~ "[HANDOFF main → reviewer]"
        end)

      assert system_row, "expected an enriched handoff :system row"
      # Stamped with the TARGET worker's compaction identity, not main.
      assert system_row.agent_id == "handoff:#{session.id}:reviewer"
      assert system_row.subagent == false
      # Body enriched with reason + summary + message.
      assert system_row.content =~ "Summary: User wants a review"
      assert system_row.content =~ "Message: Please review the recent diff"

      # Telemetry event carries every correlation field.
      assert_receive {:telemetry, _measurements, metadata}, 1_000
      assert metadata.event == :applied
      assert metadata.status == :completed
      assert metadata.handoff == "reviewer"
      assert metadata.to_template == "reviewer"
      assert metadata.from_template == "main"
      assert metadata.conversation_id == session.id
      assert metadata.request_id == request_id
      assert metadata.tenant_id == t
      assert metadata.agent_id == "main"

      # Trace surface picked it up — and the trace is reachable by
      # request_id with strict tenant filter.
      :ok = TraceTestHelpers.sync_collector()

      assert {:ok, trace} =
               JidoClaw.Trace.for_request({:request, request_id}, request_id, tenant_id: t)

      applied_event =
        Enum.find(trace.events, fn ev ->
          ev.category == :handoff and ev.event == :applied
        end)

      assert applied_event,
             "expected :handoff/:applied event in trace, got: #{inspect(trace.events)}"

      assert applied_event.metadata.request_id == request_id
      assert applied_event.metadata.tenant_id == t
      assert applied_event.metadata.conversation_id == session.id
      assert applied_event.metadata.agent_id == "main"
      assert applied_event.metadata.from_template == "main"
      assert applied_event.metadata.to_template == "reviewer"
    end

    test "accepts the flat context shape as well",
         %{tenant_id: t, session: session, runtime_session_id: rsid} do
      ctx = build_context(t, rsid, session.id, shape: :flat, agent_template: "main")

      assert {:ok, _payload} =
               HandoffTool.run(
                 %{to_template: "coder", message: "Implement feature X"},
                 ctx
               )

      owner = HandoffRegistry.owner(t, rsid)
      assert owner.template == "coder"
      assert owner.handoff.from_template == "main"
    end

    test "from_template derives from :agent_template, not :agent_id",
         %{tenant_id: t, session: session, runtime_session_id: rsid} do
      # If a worker (someday) opted in to the handoff tool, agent_id would be
      # the opaque "handoff:<uuid>:<template>" form but agent_template would
      # carry the bare template name. Verify the tool reads the template name.
      base_ctx = build_context(t, rsid, session.id, agent_template: "researcher")
      ctx = put_in(base_ctx, [:tool_context, :agent_id], "handoff:opaque:researcher")

      assert {:ok, _} =
               HandoffTool.run(
                 %{to_template: "reviewer", message: "Switch to review"},
                 ctx
               )

      owner = HandoffRegistry.owner(t, rsid)
      assert owner.handoff.from_template == "researcher"
    end
  end

  describe "validation failures" do
    test "rejects to_template == 'main'", %{
      tenant_id: t,
      session: session,
      runtime_session_id: rsid
    } do
      ctx = build_context(t, rsid, session.id)

      assert {:error, %{message: msg}} =
               HandoffTool.run(
                 %{to_template: "main", message: "Switch back"},
                 ctx
               )

      assert msg =~ "Cannot hand off to 'main'"
      assert HandoffRegistry.owner(t, rsid) == nil
    end

    test "rejects a composer-private (sandboxed) target template (AR-8b)",
         %{tenant_id: t, session: session, runtime_session_id: rsid} do
      ctx = build_context(t, rsid, session.id)

      assert {:error, %{message: msg}} =
               HandoffTool.run(%{to_template: "sketch_build", message: "build it"}, ctx)

      assert msg =~ "composer-private"
      assert HandoffRegistry.owner(t, rsid) == nil
    end

    test "rejects an unknown template",
         %{tenant_id: t, session: session, runtime_session_id: rsid} do
      request_id = Ecto.UUID.generate()
      ctx = build_context(t, rsid, session.id, request_id: request_id)

      assert {:error, %{message: msg}} =
               HandoffTool.run(
                 %{to_template: "nonexistent_template", message: "go"},
                 ctx
               )

      assert msg =~ "Unknown template"
      assert HandoffRegistry.owner(t, rsid) == nil

      # Failure-path telemetry still carries the correlation fields and
      # the *attempted* to_template so the trace is searchable.
      :ok = TraceTestHelpers.sync_collector()

      assert {:ok, trace} =
               JidoClaw.Trace.for_request({:request, request_id}, request_id, tenant_id: t)

      failed_event =
        Enum.find(trace.events, fn ev ->
          ev.category == :handoff and ev.event == :error
        end)

      assert failed_event,
             "expected :handoff/:error event in trace, got: #{inspect(trace.events)}"

      assert failed_event.metadata.request_id == request_id
      assert failed_event.metadata.tenant_id == t
      assert failed_event.metadata.conversation_id == session.id
      assert failed_event.metadata.to_template == "nonexistent_template"
      assert failed_event.metadata.error =~ "Unknown template"
    end

    test "honors :agent_templates_override for unknown-template path",
         %{tenant_id: t, session: session, runtime_session_id: rsid} do
      override = %{
        "stub_template" => %{
          module: JidoClaw.Agent.Workers.Reviewer,
          description: "test stub",
          max_iterations: 5
        }
      }

      original = Application.get_env(:jido_claw, :agent_templates_override, %{})
      Application.put_env(:jido_claw, :agent_templates_override, override)
      on_exit(fn -> Application.put_env(:jido_claw, :agent_templates_override, original) end)

      ctx = build_context(t, rsid, session.id)

      assert {:ok, payload} =
               HandoffTool.run(
                 %{to_template: "stub_template", message: "use stub"},
                 ctx
               )

      assert payload.to_template == "stub_template"
      assert HandoffRegistry.owner(t, rsid).template == "stub_template"
    end

    test "rejects missing session_uuid",
         %{tenant_id: t, runtime_session_id: rsid} do
      ctx = build_context(t, rsid, nil)

      assert {:error, %{message: msg}} =
               HandoffTool.run(
                 %{to_template: "reviewer", message: "go"},
                 ctx
               )

      assert msg =~ "handoff requires an active session"
      assert HandoffRegistry.owner(t, rsid) == nil
    end

    test "rejects missing tenant_id",
         %{session: session, runtime_session_id: rsid} do
      ctx = build_context(nil, rsid, session.id)

      assert {:error, %{message: msg}} =
               HandoffTool.run(
                 %{to_template: "reviewer", message: "go"},
                 ctx
               )

      assert msg =~ "handoff requires an active session"
    end

    test "rejects missing runtime_session_id",
         %{tenant_id: t, session: session} do
      ctx = build_context(t, nil, session.id)

      assert {:error, %{message: msg}} =
               HandoffTool.run(
                 %{to_template: "reviewer", message: "go"},
                 ctx
               )

      assert msg =~ "handoff requires an active session"
    end

    test "rejects empty / nil / whitespace message",
         %{tenant_id: t, session: session, runtime_session_id: rsid} do
      ctx = build_context(t, rsid, session.id)

      for bad <- ["", "   ", nil] do
        assert {:error, %{message: msg}} =
                 HandoffTool.run(
                   %{to_template: "reviewer", message: bad},
                   ctx
                 )

        assert msg =~ "required"
      end

      assert HandoffRegistry.owner(t, rsid) == nil
    end

    test "rejects empty / nil to_template",
         %{tenant_id: t, session: session, runtime_session_id: rsid} do
      ctx = build_context(t, rsid, session.id)

      for bad <- ["", "   ", nil] do
        assert {:error, %{message: msg}} =
                 HandoffTool.run(
                   %{to_template: bad, message: "Switch"},
                   ctx
                 )

        assert msg =~ "required"
      end
    end
  end
end
