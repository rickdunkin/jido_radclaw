defmodule JidoClaw.Web.WorkflowsChannelTest do
  @moduledoc """
  Join authorization and payload contract for `workflows:run:<id>`:
  canonicalize → subscribe → policy read (uniform `"not_found"` for
  cross-tenant / suspended / nonexistent, `"unavailable"` for infra), the
  authoritative `%{id, status}` join reply, the lifecycle allowlist with
  id binding (the broadcast `info` map never forwarded), the composer
  producer-to-channel publication path (real stub-worker loop,
  durable-then-notify), and the end-to-end route through a real
  `ArgusSocket` connect — the only shape that catches a missing
  `channel("workflows:*", ...)` declaration.
  """
  # async: false — endpoint-starter cohort (see argus_socket_test.exs).
  use JidoClaw.TenantCase, async: false

  import Phoenix.ChannelTest

  alias JidoClaw.Accounts.ApiKey
  alias JidoClaw.Accounts.User
  alias JidoClaw.Orchestration.RunPubSub
  alias JidoClaw.Orchestration.RunRegistry
  alias JidoClaw.Orchestration.WorkflowLog
  alias JidoClaw.Orchestration.WorkflowRun
  alias JidoClaw.RouteComposer
  alias JidoClaw.RouteComposer.TestFixtures
  alias JidoClaw.RouteComposer.TestSupport.StubAgentServer
  alias JidoClaw.RouteComposer.TestSupport.StubStore
  alias JidoClaw.RouteComposer.TestSupport.StubWorker
  alias JidoClaw.Web.ArgusSocket
  alias JidoClaw.Web.WorkflowsChannel

  import JidoClaw.RouteComposer.TestFixtures, only: [base_opts: 1]

  @endpoint JidoClaw.Web.Endpoint
  @composer_supervisor JidoClaw.RouteComposer.Supervisor

  @lifecycle_kinds [:run_started, :run_completed, :run_failed, :run_cancelled, :run_abandoned]

  setup do
    start_supervised!(JidoClaw.Web.Endpoint)
    :ok
  end

  describe "join workflows:run:<id>" do
    test "an owned run joins with the authoritative id + status reply" do
      %{tenant_id: tenant_id, run: run} = seed_run!()

      assert {:ok, reply, socket} = join_run(tenant_id, run.id)
      assert reply == %{id: run.id, status: "pending"}
      assert socket.assigns.run_id == run.id
    end

    test "an uppercase UUID joins and still hears canonical-topic broadcasts" do
      %{tenant_id: tenant_id, run: run} = seed_run!()

      assert {:ok, %{id: canonical_id}, _socket} =
               join_run(tenant_id, String.upcase(run.id))

      assert canonical_id == run.id

      RunPubSub.broadcast(run.id, {:run_completed, run.id, %{}})
      assert_push("run_event", %{id: ^canonical_id, kind: :run_completed})
    end

    test "a cross-tenant run is a uniform not_found" do
      %{run: run} = seed_run!()
      other_tenant = seed_tenant(:workflows_channel_other)

      assert {:error, %{reason: "not_found"}} = join_run(other_tenant, run.id)
    end

    test "nonexistent UUIDs and non-UUID ids are the identical not_found" do
      tenant_id = seed_tenant(:workflows_channel)

      assert {:error, %{reason: "not_found"}} = join_run(tenant_id, Ecto.UUID.generate())
      assert {:error, %{reason: "not_found"}} = join_run(tenant_id, "not-a-uuid")
    end

    test "a tenant suspended after run creation is not_found (policy EXISTS)" do
      %{tenant_id: tenant_id, run: run} = seed_run!()
      {:ok, tenant} = Tenant.by_id(tenant_id)
      {:ok, _} = Tenant.suspend(tenant)

      assert {:error, %{reason: "not_found"}} = join_run(tenant_id, run.id)
    end

    test "workflows:* subtopics other than run are rejected" do
      tenant_id = seed_tenant(:workflows_channel)

      assert {:error, %{reason: "unauthorized topic"}} =
               subscribe_and_join(build_socket(tenant_id), WorkflowsChannel, "workflows:gates")
    end
  end

  describe "run_event push contract" do
    test "the broadcast info map is never forwarded" do
      %{tenant_id: tenant_id, run: run} = seed_run!()
      {:ok, _reply, _socket} = join_run(tenant_id, run.id)

      RunPubSub.broadcast(run.id, {:run_completed, run.id, %{secret: "must-not-leak"}})

      assert_push("run_event", payload)
      assert payload == %{id: run.id, kind: :run_completed}
    end

    test "all five lifecycle kinds proxy" do
      %{tenant_id: tenant_id, run: run} = seed_run!()
      {:ok, _reply, _socket} = join_run(tenant_id, run.id)

      for kind <- @lifecycle_kinds do
        RunPubSub.broadcast(run.id, {kind, run.id, %{}})
        assert_push("run_event", %{id: id, kind: ^kind})
        assert id == run.id
      end
    end

    test "the allowlist is centralized: RunPubSub.lifecycle_kinds/0 is exactly the five" do
      # Name-set pin (never a count): the channel sources its allowlist from
      # RunPubSub, so producers and the channel can't drift apart.
      assert RunPubSub.lifecycle_kinds() == @lifecycle_kinds
    end

    test "non-lifecycle run-topic messages are dropped" do
      %{tenant_id: tenant_id, run: run} = seed_run!()
      {:ok, _reply, _socket} = join_run(tenant_id, run.id)

      RunPubSub.broadcast(run.id, {:gate_requested, run.id, %{}})

      refute_push("run_event", %{})
    end

    test "a poisoned tuple id on the subscribed topic is dropped" do
      %{tenant_id: tenant_id, run: run} = seed_run!()
      {:ok, _reply, _socket} = join_run(tenant_id, run.id)

      RunPubSub.broadcast(run.id, {:run_completed, Ecto.UUID.generate(), %{}})

      refute_push("run_event", %{})
    end
  end

  describe "read_error_reason/1" do
    test "bare and Invalid-wrapped NotFound are not_found" do
      bare = %Ash.Error.Query.NotFound{resource: WorkflowRun}
      wrapped = %Ash.Error.Invalid{errors: [bare]}

      assert WorkflowsChannel.read_error_reason(bare) == "not_found"
      assert WorkflowsChannel.read_error_reason(wrapped) == "not_found"
    end

    test "anything else is unavailable (infra is never absence)" do
      assert WorkflowsChannel.read_error_reason(%DBConnection.ConnectionError{}) == "unavailable"
      assert WorkflowsChannel.read_error_reason(:timeout) == "unavailable"

      assert WorkflowsChannel.read_error_reason(%Ash.Error.Invalid{errors: [:other]}) ==
               "unavailable"
    end
  end

  describe "end-to-end over a real ArgusSocket connect" do
    test "a key-connected socket routes workflows:run:<id> without naming the module" do
      %{key: key, tenant_id: tenant_id} = register_actor!()
      {:ok, _} = Tenant.ensure(tenant_id)

      run =
        WorkflowRun.create!(%{name: "e2e-run"},
          tenant: tenant_id,
          actor: actor_for(tenant_id)
        )

      assert {:ok, socket} = connect(ArgusSocket, %{}, connect_info: %{auth_token: key})

      assert {:ok, %{id: run_id, status: "pending"}, _socket} =
               subscribe_and_join(socket, "workflows:run:#{run.id}")

      assert run_id == run.id
    end
  end

  describe "composer lifecycle publication (producer e2e)" do
    # The real composer loop (stub workers, no LLM) — the composer_durable_test
    # arming template. Direct test broadcasts can't prove F1: the composer
    # parent never rides ReactorMiddleware, so publication must be pinned from
    # the producer itself all the way to the channel push.
    setup do
      StubStore.setup()
      previous_server = Application.get_env(:jido_claw, :step_agent_server)

      Application.put_env(
        :jido_claw,
        :agent_templates_override,
        TestFixtures.phase1_template_override(StubWorker)
      )

      Application.put_env(:jido_claw, :step_agent_server, StubAgentServer)

      Application.put_env(
        :jido_claw,
        :route_composer_stub_outputs,
        TestFixtures.phase1_stub_outputs()
      )

      on_exit(fn ->
        Application.delete_env(:jido_claw, :agent_templates_override)
        Application.delete_env(:jido_claw, :route_composer_stub_outputs)

        case previous_server do
          nil -> Application.delete_env(:jido_claw, :step_agent_server)
          mod -> Application.put_env(:jido_claw, :step_agent_server, mod)
        end

        # Sweep any composer left under the supervisor (terminate_child, not
        # kill — a :transient child would be restarted by a kill).
        for {_, pid, _, _} <- DynamicSupervisor.which_children(@composer_supervisor) do
          DynamicSupervisor.terminate_child(@composer_supervisor, pid)
        end

        drain_run_registry(2_000)
      end)

      %{tenant_id: tenant, workspace: workspace, session: session} =
        seed_full(tenant_label: "wf-channel")

      composer_ctx = %{
        tenant_id: tenant,
        session_id: "wf-channel-sess",
        session_uuid: session.id,
        workspace_id: "wf-channel-ws",
        workspace_uuid: workspace.id,
        project_dir: File.cwd!()
      }

      {:ok, tenant: tenant, actor: actor_for(tenant), context: composer_ctx}
    end

    test "a real composer run pushes its terminal to a joined channel, durably first", ctx do
      {:ok, parent} = RouteComposer.create_parent_run(base_opts(ctx))
      parent_id = parent.id

      {:ok, %{status: "running"}, _socket} = join_run(ctx.tenant, parent_id)

      assert {:ok, _pid} = RouteComposer.ensure_started(base_opts(ctx), parent)

      assert_push("run_event", %{id: ^parent_id, kind: :run_completed}, 30_000)

      # Durable-then-notify: by push time the terminal is already committed.
      {:ok, reloaded} = WorkflowRun.by_id(parent_id, tenant: ctx.tenant, actor: ctx.actor)
      assert reloaded.status == :completed
      assert %DateTime{} = reloaded.completed_at

      # Double-fire guard: the already-terminal short-circuit must not
      # broadcast a second terminal for the same run.
      refute_push("run_event", %{id: ^parent_id, kind: :run_completed}, 500)
    end

    test "create_parent_run broadcasts run_started after the mint commits", ctx do
      :ok = RunPubSub.subscribe_all()

      {:ok, parent} = RouteComposer.create_parent_run(base_opts(ctx))
      parent_id = parent.id

      assert_receive {:run_started, ^parent_id, %{status: :running} = info}, 5_000
      assert info.tenant_id == ctx.tenant
      assert info.workflow_type == "composer"
      assert info.completed_at == nil
    end

    test "a raw WorkflowLog.append broadcasts nothing (publication lives in the composer)",
         ctx do
      run =
        WorkflowRun.create!(%{name: "raw-append"}, tenant: ctx.tenant, actor: ctx.actor)

      :ok = RunPubSub.subscribe(run.id)

      {:ok, _event} =
        WorkflowLog.append(run, :run_started, %{}, tenant: ctx.tenant, actor: ctx.actor)

      refute_receive {:run_started, _id, _info}, 300
    end
  end

  defp drain_run_registry(timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    drain_loop(deadline)
  end

  defp drain_loop(deadline) do
    cond do
      Registry.count(RunRegistry) == 0 ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        :ok

      true ->
        Process.sleep(10)
        drain_loop(deadline)
    end
  end

  defp seed_run!(label \\ :workflows_channel) do
    tenant_id = seed_tenant(label)

    run =
      WorkflowRun.create!(%{name: "run-#{System.unique_integer([:positive])}"},
        tenant: tenant_id,
        actor: actor_for(tenant_id)
      )

    %{tenant_id: tenant_id, run: run}
  end

  defp build_socket(tenant_id) do
    socket(ArgusSocket, "argus_socket:#{tenant_id}", %{current_actor: actor_for(tenant_id)})
  end

  defp join_run(tenant_id, run_id) do
    subscribe_and_join(build_socket(tenant_id), WorkflowsChannel, "workflows:run:#{run_id}")
  end

  defp register_actor! do
    password = "valid-password-123456"

    {:ok, user} =
      User.register_with_password(
        %{
          email: "workflows-channel-#{System.unique_integer([:positive])}@example.com",
          password: password,
          password_confirmation: password
        },
        authorize?: false
      )

    {:ok, api_key} = ApiKey.create(user.id, authorize?: false)
    plaintext = Ash.Resource.get_metadata(api_key, :plaintext_api_key)

    %{user: user, key: plaintext, tenant_id: to_string(user.id)}
  end
end
