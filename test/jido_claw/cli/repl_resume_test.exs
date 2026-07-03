defmodule JidoClaw.CLI.ReplResumeTest do
  @moduledoc """
  Pins `JidoClaw.CLI.Repl.resolve_boot_session/3` — the REPL's
  `--resume <uuid>` / `--continue` selection logic, extracted so it is
  testable without driving the IO loop. Every failure mode falls back to a
  fresh mint with a printed warning (interactive surface: stay usable).

  Also pins the P1 review fix on `resolve_owner_and_attach/1`: a
  cold-resumed handoff-owned session restores the persisted transcript onto
  the freshly-started worker (warn-and-proceed on failure).
  """
  use JidoClaw.TenantCase, async: false

  import ExUnit.CaptureIO

  alias JidoClaw.Agent.Handoff.Registry, as: HandoffRegistry
  alias JidoClaw.CLI.Repl
  alias JidoClaw.Conversations.Session, as: ConversationsSession

  defmodule CapturingRestore do
    @moduledoc false
    # Records every restore target pid to the test process; restores nothing.
    @spec restore(pid(), struct(), String.t(), keyword()) :: :ok
    def restore(pid, _session, _project_dir, _opts) do
      send(
        Application.fetch_env!(:jido_claw, :repl_resume_restore_target),
        {:restore_called, pid}
      )

      :ok
    end
  end

  defmodule FailingRestore do
    @moduledoc false
    @spec restore(pid(), struct(), String.t(), keyword()) :: {:error, :forced_failure}
    def restore(_pid, _session, _project_dir, _opts), do: {:error, :forced_failure}
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
      {:ok, Application.fetch_env!(:jido_claw, :repl_resume_worker_pid)}
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
    tmp = Path.join(System.tmp_dir!(), "repl-resume-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    tenant_id = seed_tenant("repl-resume")
    {:ok, ws} = seed_workspace(tenant_id, path: tmp)

    on_exit(fn -> File.rm_rf!(tmp) end)

    {:ok, tenant_id: tenant_id, ws: ws, tmp: tmp}
  end

  test "resume-by-uuid returns the row's external_id and record", ctx do
    {:ok, session} = seed_session(ctx.tenant_id, ctx.ws.id, kind: :repl)

    assert {session_id, record} =
             Repl.resolve_boot_session(ctx.tenant_id, ctx.tmp, resume: session.id)

    assert session_id == session.external_id
    assert record.id == session.id
  end

  test "an unknown uuid warns and falls back to a fresh mint", ctx do
    bogus = Ecto.UUID.generate()

    {result, output} =
      with_io(fn -> Repl.resolve_boot_session(ctx.tenant_id, ctx.tmp, resume: bogus) end)

    assert {session_id, nil} = result
    assert String.starts_with?(session_id, "session_")
    assert output =~ "not found"
  end

  test "a cross-workspace uuid warns with the owning path and falls back fresh", ctx do
    other_path =
      Path.join(System.tmp_dir!(), "repl-resume-other-#{System.unique_integer([:positive])}")

    File.mkdir_p!(other_path)
    on_exit(fn -> File.rm_rf!(other_path) end)

    {:ok, other_ws} = seed_workspace(ctx.tenant_id, path: other_path)
    {:ok, foreign} = seed_session(ctx.tenant_id, other_ws.id, kind: :repl)

    {result, output} =
      with_io(fn -> Repl.resolve_boot_session(ctx.tenant_id, ctx.tmp, resume: foreign.id) end)

    assert {session_id, nil} = result
    assert String.starts_with?(session_id, "session_")
    assert output =~ other_path
    assert output =~ "FRESH session"
  end

  test "--continue picks the workspace's most recent open CLI session", ctx do
    {:ok, _older} = seed_session(ctx.tenant_id, ctx.ws.id, kind: :repl)
    {:ok, newest} = seed_session(ctx.tenant_id, ctx.ws.id, kind: :cli_run)
    {:ok, _api} = seed_session(ctx.tenant_id, ctx.ws.id, kind: :api)

    assert {session_id, record} =
             Repl.resolve_boot_session(ctx.tenant_id, ctx.tmp, continue: true)

    assert session_id == newest.external_id
    assert record.id == newest.id
  end

  test "--continue in an empty workspace warns and falls back fresh", ctx do
    {result, output} =
      with_io(fn -> Repl.resolve_boot_session(ctx.tenant_id, ctx.tmp, continue: true) end)

    assert {session_id, nil} = result
    assert String.starts_with?(session_id, "session_")
    assert output =~ "no open CLI session"
  end

  test "no resume opts mint a fresh session id", ctx do
    assert {session_id, nil} = Repl.resolve_boot_session(ctx.tenant_id, ctx.tmp, [])
    assert String.starts_with?(session_id, "session_")
  end

  describe "resolve_owner_and_attach/1 restores the cold-resumed handoff worker" do
    setup ctx do
      {:ok, session} = seed_session(ctx.tenant_id, ctx.ws.id, kind: :repl)
      actor = actor_for(ctx.tenant_id)

      # Cold-resume state: durable ownership at "reviewer", registry EMPTY —
      # the router synthesizes the rehydrated owner on the first turn.
      {:ok, _} =
        ConversationsSession.set_current_agent_template(session, "reviewer",
          tenant: ctx.tenant_id,
          actor: actor
        )

      {:ok, worker_pid} = SinkWorker.start()
      main_pid = spawn(fn -> Process.sleep(:infinity) end)

      saved =
        Map.new(
          ~w(jido_runtime repl_resume_worker_pid repl_resume_restore_target
             context_restore_impl)a,
          &{&1, Application.fetch_env(:jido_claw, &1)}
        )

      Application.put_env(:jido_claw, :jido_runtime, FakeRuntime)
      Application.put_env(:jido_claw, :repl_resume_worker_pid, worker_pid)
      Application.put_env(:jido_claw, :repl_resume_restore_target, self())

      on_exit(fn ->
        Enum.each(saved, fn
          {key, :error} -> Application.delete_env(:jido_claw, key)
          {key, {:ok, value}} -> Application.put_env(:jido_claw, key, value)
        end)

        HandoffRegistry.clear(ctx.tenant_id, session.external_id)
        if Process.alive?(worker_pid), do: GenServer.stop(worker_pid)
        Process.exit(main_pid, :kill)
      end)

      state = %Repl{
        agent_pid: main_pid,
        agent_id: "main",
        tenant_id: ctx.tenant_id,
        session_id: session.external_id,
        session_uuid: session.id,
        cwd: ctx.tmp
      }

      {:ok, state: state, worker_pid: worker_pid}
    end

    test "the freshly-started worker gets the restore", ctx do
      Application.put_env(:jido_claw, :context_restore_impl, CapturingRestore)
      worker_pid = ctx.worker_pid

      assert {^worker_pid, "reviewer", _agent_id, false, true, _owner} =
               Repl.resolve_owner_and_attach(ctx.state)

      assert_receive {:restore_called, ^worker_pid}
    end

    test "a failed worker restore warns and still returns the routed tuple", ctx do
      Application.put_env(:jido_claw, :context_restore_impl, FailingRestore)
      worker_pid = ctx.worker_pid

      {routed, output} = with_io(fn -> Repl.resolve_owner_and_attach(ctx.state) end)

      assert {^worker_pid, "reviewer", _agent_id, false, true, _owner} = routed
      assert output =~ "history NOT restored"
      assert output =~ "forced_failure"
    end
  end
end
