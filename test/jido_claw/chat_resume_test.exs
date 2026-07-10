defmodule JidoClaw.ChatResumeTest do
  @moduledoc """
  End-to-end pin of the resume path inside `JidoClaw.chat/4`:

    * a FRESH agent process gets the persisted chat transcript restored into
      its LLM context (`Jido.AI.Context`) before the ask,
    * a LIVE agent is never re-restored (its context already carries the
      conversation),
    * a restore failure honors the `:context_restore` opt — `:strict` fails
      the turn, `:best_effort` (default) logs and proceeds.

  The LLM ask is the `:ask_runtime` capture stub and triage is the canned
  `TriageStub` (`:talk` → inline), so no real LLM round-trips happen.
  """
  use JidoClaw.TenantCase, async: false

  alias Jido.Agent.Strategy.State, as: StratState
  alias Jido.AI.Context, as: AIContext
  alias JidoClaw.Agent.Handoff
  alias JidoClaw.Agent.Handoff.Registry, as: HandoffRegistry
  alias JidoClaw.Agent.Templates
  alias JidoClaw.Conversations.Session, as: ConversationsSession
  alias JidoClaw.Session.Supervisor, as: SessionSupervisor
  alias JidoClaw.Session.Worker, as: SessionWorker
  alias JidoClaw.Test.HandoffDispatchCapture

  defmodule FailingRestore do
    @moduledoc false
    @spec restore(pid(), struct(), String.t(), keyword()) :: {:error, :forced_failure}
    def restore(_pid, _session, _project_dir, _opts), do: {:error, :forced_failure}
  end

  defmodule CapturingRestore do
    @moduledoc false
    # Records every restore target pid to the test process; restores nothing.
    @spec restore(pid(), struct(), String.t(), keyword()) :: :ok
    def restore(pid, _session, _project_dir, _opts) do
      send(Application.fetch_env!(:jido_claw, :capturing_restore_target), {:restore_called, pid})
      :ok
    end
  end

  defmodule WorkerOnlyFailingRestore do
    @moduledoc false
    # Fails ONLY for the routed worker pid (the app-env one) so the strict
    # policy is pinned to the WORKER restore — main's restore succeeds.
    @spec restore(pid(), struct(), String.t(), keyword()) :: :ok | {:error, :forced}
    def restore(pid, _session, _project_dir, _opts) do
      if pid == Application.fetch_env!(:jido_claw, :chat_resume_worker_pid) do
        {:error, :forced}
      else
        :ok
      end
    end
  end

  # The router-seam fake worker runtime (repl_test.exs pattern): the worker
  # never pre-exists, so ensure_worker_pid always starts it fresh with the
  # pid stashed in app env.
  defmodule FakeRuntime do
    @moduledoc false

    @spec whereis(String.t()) :: nil
    def whereis(_agent_id), do: nil

    @spec start_subagent(module(), keyword()) :: {:ok, pid()}
    def start_subagent(_module, _opts) do
      {:ok, Application.fetch_env!(:jido_claw, :chat_resume_worker_pid)}
    end
  end

  # Minimal GenServer standing in for a routed worker: replies `{:ok, %{}}`
  # to any agent signal (system-prompt injection) without a real agent boot.
  defmodule SinkWorker do
    @moduledoc false
    use GenServer

    @spec start() :: GenServer.on_start()
    def start, do: GenServer.start(__MODULE__, nil)

    @impl GenServer
    def init(state), do: {:ok, state}

    @impl GenServer
    def handle_call({:signal, _signal}, _from, state), do: {:reply, {:ok, %{}}, state}
  end

  setup do
    tmp = Path.join(System.tmp_dir!(), "chat-resume-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    %{tenant_id: tenant_id, session: session} =
      seed_full(tenant_label: "chat-resume", workspace: [path: tmp], session: [kind: :cli_run])

    rsid = session.external_id
    runtime_id = JidoClaw.runtime_agent_id(session.id)
    actor = actor_for(tenant_id)

    {:ok, _pid} = SessionSupervisor.ensure_session(tenant_id, rsid, actor: actor)
    :ok = SessionWorker.set_session_uuid(tenant_id, rsid, session.id)

    saved =
      Map.new(
        ~w(triage_impl triage_canned_verdict ask_runtime dispatch_capture_target
           dispatch_capture_response context_restore_impl
           jido_runtime chat_resume_worker_pid capturing_restore_target)a,
        &{&1, Application.fetch_env(:jido_claw, &1)}
      )

    Application.put_env(:jido_claw, :triage_impl, JidoClaw.Test.TriageStub)
    Application.put_env(:jido_claw, :triage_canned_verdict, :talk)
    Application.put_env(:jido_claw, :ask_runtime, HandoffDispatchCapture)
    Application.put_env(:jido_claw, :dispatch_capture_target, self())
    Application.put_env(:jido_claw, :dispatch_capture_response, {:ok, "stub answer"})

    on_exit(fn ->
      Enum.each(saved, fn
        {key, :error} -> Application.delete_env(:jido_claw, key)
        {key, {:ok, value}} -> Application.put_env(:jido_claw, key, value)
      end)

      HandoffRegistry.clear(tenant_id, rsid)
      stop_agent(runtime_id)
      File.rm_rf!(tmp)
    end)

    {:ok,
     tenant_id: tenant_id,
     rsid: rsid,
     runtime_id: runtime_id,
     session: session,
     actor: actor,
     tmp: tmp}
  end

  defp chat(ctx, message, extra_opts \\ []) do
    JidoClaw.chat(
      ctx.tenant_id,
      ctx.rsid,
      message,
      Keyword.merge(
        [kind: :cli_run, workspace_id: ctx.tmp, external_id: ctx.rsid, actor: ctx.actor],
        extra_opts
      )
    )
  end

  defp agent_context(runtime_id) do
    pid = Jido.whereis(JidoClaw.Jido, runtime_id)
    assert is_pid(pid)
    {:ok, server_state} = Jido.AgentServer.state(pid)

    server_state.agent
    |> StratState.get(%{})
    |> Map.get(:context)
  end

  # Main/session agents are supervised `restart: :permanent`
  # (`Jido.start_agent/2`), so a plain GenServer.stop is resurrected by the
  # supervisor as a new live pid — the opposite of the fresh-boot scenario
  # resume targets. `Jido.stop_agent/2` terminate_childs it for real.
  defp stop_agent(runtime_id) do
    case Jido.whereis(JidoClaw.Jido, runtime_id) do
      pid when is_pid(pid) ->
        _ = Jido.stop_agent(JidoClaw.Jido, pid)
        await_deregistered(runtime_id, 50)

      nil ->
        :ok
    end
  catch
    :exit, _ -> :ok
  end

  defp await_deregistered(_runtime_id, 0), do: :ok

  defp await_deregistered(runtime_id, attempts) do
    case Jido.whereis(JidoClaw.Jido, runtime_id) do
      nil ->
        :ok

      _pid ->
        Process.sleep(20)
        await_deregistered(runtime_id, attempts - 1)
    end
  end

  test "a fresh agent restores the persisted transcript; a live agent is not re-restored",
       ctx do
    # Turn 1: fresh agent, empty transcript — restore is a no-op.
    assert {:ok, "stub answer"} = chat(ctx, "first question")
    assert_receive {:dispatch_capture, _pid, _query, _opts}, 5_000

    # Turn 1's user+assistant rows are durable (add_message is synchronous).
    # Kill the agent so turn 2 resolves a FRESH process.
    stop_agent(ctx.runtime_id)

    assert {:ok, "stub answer"} = chat(ctx, "second question")
    assert_receive {:dispatch_capture, _pid, _query, _opts}, 5_000

    context = agent_context(ctx.runtime_id)
    assert %AIContext{} = context

    entries = Enum.reverse(context.entries)

    # The restored context carries exactly turn 1's chat rows (turn 2's own
    # user message rides the ask, which the capture stub intercepts).
    assert Enum.map(entries, &{&1.role, &1.content}) == [
             {:user, "first question"},
             {:assistant, "stub answer"}
           ]

    # The restored context carries a system prompt (strategy has no config
    # fallback at ask time — nil would silently drop the prompt).
    assert is_binary(context.system_prompt) and context.system_prompt != ""

    # Turn 3 against the LIVE agent: no re-restore. By now the durable
    # transcript has 4 chat rows (turns 1+2); a buggy re-restore would
    # replace the context with all 4.
    assert {:ok, "stub answer"} = chat(ctx, "third question")
    assert_receive {:dispatch_capture, _pid, _query, _opts}, 5_000

    live_entries = Enum.reverse(agent_context(ctx.runtime_id).entries)

    assert Enum.map(live_entries, &{&1.role, &1.content}) == [
             {:user, "first question"},
             {:assistant, "stub answer"}
           ]
  end

  test "strict mode fails the turn on restore failure; best-effort proceeds", ctx do
    Application.put_env(:jido_claw, :context_restore_impl, FailingRestore)

    # Fresh agent + failing restore + :strict ⇒ the turn fails loud.
    assert {:error, {:context_restore_failed, :forced_failure}} =
             chat(ctx, "resume me", context_restore: :strict)

    # Best-effort (the default) logs and proceeds with an amnesic turn.
    stop_agent(ctx.runtime_id)
    assert {:ok, "stub answer"} = chat(ctx, "resume me anyway")
    assert_receive {:dispatch_capture, _pid, _query, _opts}, 5_000
  end

  # ---- P1 review fix: the routed handoff worker gets the restore too ----

  defp start_sink_worker do
    {:ok, pid} = SinkWorker.start()
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    pid
  end

  defp install_worker_seam(worker_pid) do
    Application.put_env(:jido_claw, :jido_runtime, FakeRuntime)
    Application.put_env(:jido_claw, :chat_resume_worker_pid, worker_pid)
  end

  defp seed_rehydratable_ownership(ctx) do
    {:ok, _} =
      ConversationsSession.set_current_agent_template(ctx.session, "reviewer",
        tenant: ctx.tenant_id,
        actor: ctx.actor
      )

    # Registry EMPTY + durable template metadata IS the cold-resume state the
    # router rehydrates from.
    HandoffRegistry.clear(ctx.tenant_id, ctx.rsid)
  end

  test "a cold resume of a handoff-owned session restores the routed WORKER, not only main",
       ctx do
    # Turn 1 seeds the durable transcript against the real main agent.
    assert {:ok, "stub answer"} = chat(ctx, "first question")
    assert_receive {:dispatch_capture, _pid, _query, _opts}, 5_000

    stop_agent(ctx.runtime_id)
    seed_rehydratable_ownership(ctx)

    worker_pid = start_sink_worker()
    install_worker_seam(worker_pid)
    Application.put_env(:jido_claw, :context_restore_impl, CapturingRestore)
    Application.put_env(:jido_claw, :capturing_restore_target, self())

    assert {:ok, "stub answer"} = chat(ctx, "second question")

    # The ask ran against the routed worker...
    assert_receive {:dispatch_capture, dispatched_pid, _query, _opts}, 5_000
    assert dispatched_pid == worker_pid

    # ...and the restore hit BOTH the fresh main pid (unchanged behavior)
    # AND the freshly-started worker (the review fix).
    main_pid = Jido.whereis(JidoClaw.Jido, ctx.runtime_id)
    assert is_pid(main_pid)
    assert_receive {:restore_called, ^main_pid}
    assert_receive {:restore_called, ^worker_pid}
  end

  test "strict mode fails the turn when the WORKER restore fails", ctx do
    seed_rehydratable_ownership(ctx)

    worker_pid = start_sink_worker()
    install_worker_seam(worker_pid)
    Application.put_env(:jido_claw, :context_restore_impl, WorkerOnlyFailingRestore)

    # Main's restore succeeds (the stub only fails for the worker pid), so
    # this pins the strict policy to the WORKER restore specifically.
    assert {:error, {:context_restore_failed, :forced}} =
             chat(ctx, "resume me", context_restore: :strict)

    # The failed restore aborts the turn before dispatch.
    refute_received {:dispatch_capture, _pid, _query, _opts}
  end

  test "a fresh worker under a LIVE (non-rehydrated) handoff is NOT restored", ctx do
    {:ok, reviewer_tpl} = Templates.get("reviewer")

    # A real handoff (actual message, no rehydration marker) — the class whose
    # combined handoff prompt a restore would clobber.
    handoff =
      Handoff.new(%{
        tenant_id: ctx.tenant_id,
        runtime_session_id: ctx.rsid,
        session_uuid: ctx.session.id,
        from_template: "main",
        to_template: "reviewer",
        to_module: reviewer_tpl.module,
        message: "Please review the diff"
      })

    :ok = HandoffRegistry.put_owner(ctx.tenant_id, ctx.rsid, handoff)

    worker_pid = start_sink_worker()
    install_worker_seam(worker_pid)
    Application.put_env(:jido_claw, :context_restore_impl, CapturingRestore)
    Application.put_env(:jido_claw, :capturing_restore_target, self())

    assert {:ok, "stub answer"} = chat(ctx, "review please")

    assert_receive {:dispatch_capture, dispatched_pid, _query, _opts}, 5_000
    assert dispatched_pid == worker_pid

    # Fresh main may restore; the live-handoff worker must not.
    refute_received {:restore_called, ^worker_pid}
  end
end
