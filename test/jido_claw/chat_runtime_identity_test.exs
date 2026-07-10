defmodule JidoClaw.ChatRuntimeIdentityTest do
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Agent.StatelessCompletion
  alias JidoClaw.Conversations.EphemeralCleanup
  alias JidoClaw.Conversations.RequestCorrelation
  alias JidoClaw.Conversations.RequestCorrelation.Cache, as: CorrelationCache
  alias JidoClaw.Conversations.Session, as: ConversationSession
  alias JidoClaw.Conversations.ToolOutput
  alias JidoClaw.Jido, as: Runtime
  alias JidoClaw.Reasoning.Compactor.RequestTransformer
  alias JidoClaw.Repo
  alias JidoClaw.Session.Supervisor, as: SessionSupervisor
  alias JidoClaw.Session.Worker, as: SessionWorker
  alias JidoClaw.SessionRegistry
  alias JidoClaw.Shell.SessionManager, as: ShellSessionManager
  alias JidoClaw.Test.HandoffDispatchCapture
  alias JidoClaw.Test.MCPFacadeCapture
  alias JidoClaw.Test.TriageStub
  alias JidoClaw.VFS.Workspace, as: VFSWorkspace
  alias JidoClaw.VFS.WorkspaceRegistry
  alias JidoClaw.Workspaces.Workspace, as: WorkspaceResource

  defmodule FailingCleanup do
    @moduledoc false

    @spec delete(String.t(), String.t()) :: {:error, :forced_cleanup_failure}
    def delete(_tenant_id, _session_uuid), do: {:error, :forced_cleanup_failure}
  end

  setup do
    saved =
      Map.new(
        ~w(triage_impl triage_canned_verdict triage_capture ask_runtime dispatch_capture_target
           dispatch_capture_response ephemeral_cleanup_impl chat_session_runtime_acquire
           mcp_facade mcp_facade_capture_target)a,
        &{&1, Application.fetch_env(:jido_claw, &1)}
      )

    Application.put_env(:jido_claw, :triage_impl, TriageStub)
    Application.put_env(:jido_claw, :triage_canned_verdict, :talk)
    Application.put_env(:jido_claw, :ask_runtime, HandoffDispatchCapture)
    Application.put_env(:jido_claw, :dispatch_capture_target, self())
    Application.put_env(:jido_claw, :dispatch_capture_response, {:ok, "captured"})

    on_exit(fn ->
      Enum.each(saved, fn
        {key, :error} -> Application.delete_env(:jido_claw, key)
        {key, {:ok, value}} -> Application.put_env(:jido_claw, key, value)
      end)
    end)

    :ok
  end

  test "the same client session id in two tenants resolves to different live agents" do
    raw_id = "shared-main"
    left = seed_context("runtime-left", raw_id)
    right = seed_context("runtime-right", raw_id)

    on_exit(fn ->
      stop_runtime(left.session.id)
      stop_runtime(right.session.id)
      SessionSupervisor.stop_session(left.tenant_id, raw_id)
      SessionSupervisor.stop_session(right.tenant_id, raw_id)
      File.rm_rf!(left.path)
      File.rm_rf!(right.path)
    end)

    assert {:ok, "captured"} = chat(left, raw_id, ephemeral_runtime: false)
    assert_receive {:dispatch_capture, left_pid, _query, _opts}, 5_000

    assert {:ok, "captured"} = chat(right, raw_id, ephemeral_runtime: false)
    assert_receive {:dispatch_capture, right_pid, _query, _opts}, 5_000

    refute left_pid == right_pid
    assert Jido.whereis(Runtime, JidoClaw.runtime_agent_id(left.session.id)) == left_pid
    assert Jido.whereis(Runtime, JidoClaw.runtime_agent_id(right.session.id)) == right_pid
    assert Jido.whereis(Runtime, raw_id) == nil
  end

  test "an ephemeral API turn removes its agent and Session worker" do
    raw_id = "one-shot"
    ctx = seed_context("runtime-ephemeral", raw_id, %{"api_stateless" => true})
    runtime_id = JidoClaw.runtime_agent_id(ctx.session.id)
    on_exit(fn -> File.rm_rf!(ctx.path) end)

    # Tool calls use the raw request/session id as their shell/VFS workspace
    # key. Seed both caches to prove the one-shot bracket removes tool-created
    # runtime state too (including the VFS-only path).
    assert {:ok, _workspace_pid} = VFSWorkspace.ensure_started(raw_id, ctx.path)

    assert {:ok, %{exit_code: 0}} =
             ShellSessionManager.run(raw_id, "true", 1_000, project_dir: ctx.path)

    assert {:ok, "captured"} = chat(ctx, raw_id, ephemeral_runtime: true)
    assert_receive {:dispatch_capture, dispatched_pid, _query, _opts}, 5_000

    refute Process.alive?(dispatched_pid)
    assert Jido.whereis(Runtime, runtime_id) == nil

    worker_name = {:via, Registry, {SessionRegistry, {ctx.tenant_id, raw_id}}}
    assert GenServer.whereis(worker_name) == nil
    assert {:error, :no_session} = ShellSessionManager.cwd(raw_id, :host)
    assert Registry.lookup(WorkspaceRegistry, raw_id) == []

    assert {:error, _} =
             ConversationSession.by_id(ctx.session.id,
               tenant: ctx.tenant_id,
               actor: ctx.actor
             )
  end

  test "an unmarked durable session refuses ephemeral dispatch without starting processes" do
    raw_id = "durable-session"
    ctx = seed_context("runtime-durable", raw_id)
    runtime_id = JidoClaw.runtime_agent_id(ctx.session.id)
    on_exit(fn -> File.rm_rf!(ctx.path) end)

    assert {:error, :ephemeral_runtime_requires_stateless_session} =
             chat(ctx, raw_id, ephemeral_runtime: true)

    refute_received {:dispatch_capture, _, _, _}
    assert Jido.whereis(Runtime, runtime_id) == nil

    worker_name = {:via, Registry, {SessionRegistry, {ctx.tenant_id, raw_id}}}
    assert GenServer.whereis(worker_name) == nil

    assert {:ok, _session} =
             ConversationSession.by_id(ctx.session.id,
               tenant: ctx.tenant_id,
               actor: ctx.actor
             )
  end

  test "invalid ephemeral options are rejected before workspace or session persistence" do
    tenant_id = seed_tenant("runtime-prevalidate")
    actor = actor_for(tenant_id)
    raw_id = "invalid-ephemeral"

    path =
      Path.join(
        System.tmp_dir!(),
        "runtime-prevalidate-#{System.unique_integer([:positive])}"
      )

    refute File.exists?(path)

    assert {:error, :ephemeral_runtime_requires_stateless_session} =
             JidoClaw.chat(tenant_id, raw_id, "hello",
               kind: :api,
               workspace_id: path,
               external_id: raw_id,
               actor: actor,
               ephemeral_runtime: true
             )

    assert {:ok, []} = WorkspaceResource.list(tenant: tenant_id, actor: actor)
    assert {:ok, []} = ConversationSession.list(tenant: tenant_id, actor: actor)
    refute File.exists?(path)
    refute_received {:dispatch_capture, _, _, _}
  end

  test "a durable cleanup failure is returned after live processes are still torn down" do
    raw_id = "cleanup-failure"
    ctx = seed_context("runtime-cleanup-failure", raw_id, %{"api_stateless" => true})
    runtime_id = JidoClaw.runtime_agent_id(ctx.session.id)
    Application.put_env(:jido_claw, :ephemeral_cleanup_impl, FailingCleanup)

    on_exit(fn ->
      Application.delete_env(:jido_claw, :ephemeral_cleanup_impl)
      EphemeralCleanup.delete(ctx.tenant_id, ctx.session.id)
      File.rm_rf!(ctx.path)
    end)

    assert {:error,
            {:ephemeral_cleanup_failed,
             %{process: :ok, database: {:error, :forced_cleanup_failure}}}} =
             chat(ctx, raw_id, ephemeral_runtime: true)

    assert_receive {:dispatch_capture, dispatched_pid, _query, _opts}, 5_000
    refute Process.alive?(dispatched_pid)
    assert Jido.whereis(Runtime, runtime_id) == nil

    worker_name = {:via, Registry, {SessionRegistry, {ctx.tenant_id, raw_id}}}
    assert GenServer.whereis(worker_name) == nil
  end

  test "an ephemeral acquisition error after starting the Session worker tears everything down" do
    raw_id = "acquire-error"
    ctx = seed_context("runtime-acquire-error", raw_id, %{"api_stateless" => true})
    runtime_id = JidoClaw.runtime_agent_id(ctx.session.id)

    Application.put_env(:jido_claw, :chat_session_runtime_acquire, fn
      tenant_id, session_id, actor, session_uuid ->
        {:ok, _pid} =
          SessionSupervisor.ensure_session(tenant_id, session_id, actor: actor)

        :ok = SessionWorker.set_session_uuid(tenant_id, session_id, session_uuid)
        {:error, :forced_acquire_failure}
    end)

    on_exit(fn -> File.rm_rf!(ctx.path) end)

    assert {:error, :forced_acquire_failure} = chat(ctx, raw_id, ephemeral_runtime: true)
    refute_received {:dispatch_capture, _, _, _}
    assert Jido.whereis(Runtime, runtime_id) == nil
    assert_runtime_and_row_removed(ctx, raw_id)
  end

  test "a thrown acquisition term still runs the complete ephemeral cleanup bracket" do
    raw_id = "acquire-throw"
    ctx = seed_context("runtime-acquire-throw", raw_id, %{"api_stateless" => true})

    Application.put_env(:jido_claw, :chat_session_runtime_acquire, fn
      tenant_id, session_id, actor, session_uuid ->
        {:ok, _pid} =
          SessionSupervisor.ensure_session(tenant_id, session_id, actor: actor)

        :ok = SessionWorker.set_session_uuid(tenant_id, session_id, session_uuid)
        throw(:forced_acquire_throw)
    end)

    on_exit(fn -> File.rm_rf!(ctx.path) end)

    assert {:error, {:throw, :forced_acquire_throw}} =
             chat(ctx, raw_id, ephemeral_runtime: true)

    refute_received {:dispatch_capture, _, _, _}
    assert_runtime_and_row_removed(ctx, raw_id)
  end

  test "stateless code-shaped API prompts complete on a zero-tool agent without composing" do
    raw_id = "stateless-code-completion"
    ctx = seed_context("runtime-stateless-code", raw_id, %{"api_stateless" => true})
    Application.put_env(:jido_claw, :triage_canned_verdict, :code)
    Application.put_env(:jido_claw, :triage_capture, self())
    Application.put_env(:jido_claw, :mcp_facade, MCPFacadeCapture)
    Application.put_env(:jido_claw, :mcp_facade_capture_target, self())

    on_exit(fn -> File.rm_rf!(ctx.path) end)

    assert StatelessCompletion.tool_modules() == []
    refute File.exists?(Path.join(ctx.path, ".jido"))

    assert {:ok, "captured"} =
             chat(ctx, raw_id,
               ephemeral_runtime: true,
               stateless_completion: true,
               stateless_completion_model: "test:completion-model"
             )

    assert_receive {:dispatch_capture, dispatched_pid, _query, opts}, 5_000
    assert get_in(opts, [:tool_context, :agent_template]) == "stateless_completion"
    assert opts[:request_transformer] == RequestTransformer

    assert {:ok, %{model: "test:completion-model"}} =
             opts[:request_transformer].transform_request(
               %{messages: []},
               nil,
               nil,
               opts[:tool_context]
             )

    refute_receive {:triage_classify, _, _}, 100
    refute_receive {:mcp_ensure_attached, _, _, _}, 100
    refute Process.alive?(dispatched_pid)
    refute File.exists?(Path.join(ctx.path, ".jido"))
    assert_runtime_and_row_removed(ctx, raw_id)
  end

  test "stateless completion cannot be enabled on a durable runtime" do
    raw_id = "durable-stateless-completion"
    ctx = seed_context("runtime-durable-stateless", raw_id, %{"api_stateless" => true})

    on_exit(fn -> File.rm_rf!(ctx.path) end)

    assert {:error, :stateless_completion_requires_ephemeral_runtime} =
             chat(ctx, raw_id, ephemeral_runtime: false, stateless_completion: true)

    refute_received {:dispatch_capture, _, _, _}
  end

  test "cleanup validates tenant and stateless marker before detaching artifacts" do
    raw_id = "cleanup-validation"
    ctx = seed_context("runtime-cleanup-validation", raw_id, %{"api_stateless" => true})
    ref = "out_cleanup_#{System.unique_integer([:positive])}"

    {:ok, output} =
      ToolOutput.store(
        %{ref: ref, session_id: ctx.session.id, tool: "test", content: "kept"},
        tenant: ctx.tenant_id,
        actor: ctx.actor
      )

    on_exit(fn ->
      EphemeralCleanup.delete(ctx.tenant_id, ctx.session.id)
      File.rm_rf!(ctx.path)
    end)

    assert {:error, :not_ephemeral_session} =
             EphemeralCleanup.delete("wrong-tenant", ctx.session.id)

    assert {:ok, reloaded} = ToolOutput.by_id_global(output.id)
    assert reloaded.session_id == ctx.session.id

    assert {:ok, _session} =
             ConversationSession.by_id(ctx.session.id,
               tenant: ctx.tenant_id,
               actor: ctx.actor
             )
  end

  test "ephemeral cleanup registry covers every conversation FK and soft session reference" do
    %{detach: detach_targets, delete: delete_targets} = EphemeralCleanup.targets()
    detach = MapSet.new(detach_targets)
    delete = MapSet.new(delete_targets)
    cleanup = MapSet.union(detach, delete)

    # These session_id columns belong to Forge execution sessions, not
    # Conversations.Session. Keeping the exclusion explicit means a newly
    # introduced session_id/session_uuid column fails this contract until its
    # ownership and cleanup disposition are reviewed.
    non_conversation =
      MapSet.new([
        {"forge_checkpoints", "session_id"},
        {"forge_events", "session_id"},
        {"forge_exec_sessions", "session_id"}
      ])

    %{rows: rows} =
      Repo.query!("""
      SELECT
        c.table_name,
        c.column_name,
        c.is_nullable,
        EXISTS (
          SELECT 1
          FROM information_schema.table_constraints tc
          JOIN information_schema.key_column_usage kcu
            ON kcu.constraint_schema = tc.constraint_schema
           AND kcu.constraint_name = tc.constraint_name
           AND kcu.table_schema = tc.table_schema
           AND kcu.table_name = tc.table_name
          JOIN information_schema.constraint_column_usage ccu
            ON ccu.constraint_schema = tc.constraint_schema
           AND ccu.constraint_name = tc.constraint_name
          WHERE tc.constraint_type = 'FOREIGN KEY'
            AND tc.table_schema = c.table_schema
            AND tc.table_name = c.table_name
            AND kcu.column_name = c.column_name
            AND ccu.table_schema = 'public'
            AND ccu.table_name = 'conversation_sessions'
            AND ccu.column_name = 'id'
        ) AS conversation_fk
      FROM information_schema.columns c
      WHERE c.table_schema = 'public'
        AND c.column_name IN ('session_id', 'session_uuid')
      ORDER BY c.table_name, c.column_name
      """)

    metadata =
      Map.new(rows, fn [table, column, nullable, conversation_fk] ->
        {{table, column}, %{nullable: nullable == "YES", conversation_fk: conversation_fk}}
      end)

    assert MapSet.new(Map.keys(metadata)) == MapSet.union(cleanup, non_conversation)
    assert MapSet.disjoint?(detach, delete)

    for target <- detach do
      assert %{nullable: true} = metadata[target],
             "detach target #{inspect(target)} must remain nullable"
    end

    for target <- delete do
      assert %{nullable: false, conversation_fk: true} = metadata[target],
             "delete target #{inspect(target)} must remain a required conversation FK"
    end

    for {target, %{conversation_fk: true}} <- metadata do
      assert MapSet.member?(cleanup, target),
             "conversation FK #{inspect(target)} needs an explicit cleanup disposition"
    end
  end

  test "ephemeral cleanup evicts every durable request correlation from the hot cache" do
    raw_id = "cleanup-correlation-cache"
    ctx = seed_context("runtime-correlation-cache", raw_id, %{"api_stateless" => true})
    request_id = "req_#{Ecto.UUID.generate()}"
    cache_only_request_id = "req_cache_only_#{Ecto.UUID.generate()}"

    assert {:ok, _correlation} =
             RequestCorrelation.register(
               %{
                 request_id: request_id,
                 session_id: ctx.session.id,
                 tenant_id: ctx.tenant_id,
                 workspace_id: ctx.workspace.id,
                 agent_id: "main",
                 subagent: false,
                 sanitize_sensitive_context: false
               },
               authorize?: false
             )

    scope = %{
      session_id: ctx.session.id,
      tenant_id: ctx.tenant_id,
      workspace_id: ctx.workspace.id
    }

    assert :ok = CorrelationCache.put(request_id, scope)
    assert :ok = CorrelationCache.put(cache_only_request_id, scope)
    assert {:ok, ^scope} = CorrelationCache.lookup(request_id)
    assert {:ok, ^scope} = CorrelationCache.lookup(cache_only_request_id)

    on_exit(fn -> File.rm_rf!(ctx.path) end)

    assert :ok = EphemeralCleanup.delete(ctx.tenant_id, ctx.session.id)
    assert :error = CorrelationCache.lookup(request_id)
    assert :error = CorrelationCache.lookup(cache_only_request_id)
    assert {:error, _reason} = RequestCorrelation.lookup(request_id, authorize?: false)

    # A resolver that read the durable row before cleanup may enqueue its cache
    # rehydrate after the post-commit purge. The per-session tombstone must make
    # that late put a no-op rather than resurrecting a cache-only scope.
    assert :ok = CorrelationCache.put(request_id, scope)
    assert :error = CorrelationCache.lookup(request_id)
  end

  defp seed_context(label, raw_id, metadata \\ %{}) do
    path = Path.join(System.tmp_dir!(), "#{label}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)

    %{tenant_id: tenant_id, workspace: workspace, session: session} =
      seed_full(
        tenant_label: label,
        workspace: [path: path],
        session: [kind: :api, external_id: raw_id, metadata: metadata]
      )

    %{
      tenant_id: tenant_id,
      workspace: workspace,
      session: session,
      actor: actor_for(tenant_id),
      path: path
    }
  end

  defp chat(ctx, raw_id, opts) do
    opts =
      if Keyword.get(opts, :ephemeral_runtime, false) do
        Keyword.put_new(opts, :metadata, %{"api_stateless" => true})
      else
        opts
      end

    JidoClaw.chat(
      ctx.tenant_id,
      raw_id,
      "hello",
      Keyword.merge(
        [kind: :api, workspace_id: ctx.path, external_id: raw_id, actor: ctx.actor],
        opts
      )
    )
  end

  defp assert_runtime_and_row_removed(ctx, raw_id) do
    worker_name = {:via, Registry, {SessionRegistry, {ctx.tenant_id, raw_id}}}
    assert GenServer.whereis(worker_name) == nil

    assert {:error, _} =
             ConversationSession.by_id(ctx.session.id,
               tenant: ctx.tenant_id,
               actor: ctx.actor
             )
  end

  defp stop_runtime(session_uuid) do
    case Jido.whereis(Runtime, JidoClaw.runtime_agent_id(session_uuid)) do
      pid when is_pid(pid) -> Runtime.stop_agent(pid)
      nil -> :ok
    end
  end
end
