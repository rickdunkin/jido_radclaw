defmodule JidoClaw.Agent.Handoff.RouterTest do
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Agent.Handoff
  alias JidoClaw.Agent.Handoff.Registry, as: HandoffRegistry
  alias JidoClaw.Agent.Handoff.Router, as: HandoffRouter
  alias JidoClaw.Conversations.Session, as: ConversationsSession

  setup do
    %{tenant_id: tenant_id, session: session} = seed_full(tenant_label: "router")
    runtime_session_id = session.external_id
    actor = actor_for(tenant_id)

    on_exit(fn -> HandoffRegistry.clear(tenant_id, runtime_session_id) end)

    {:ok,
     tenant_id: tenant_id, session: session, runtime_session_id: runtime_session_id, actor: actor}
  end

  # Stub worker for the seam-runtime re-injection tests: captures the
  # set_system_prompt signal the Startup injection path issues, forwarding
  # `{:injected_prompt, worker_pid, prompt}` to the test (the
  # coherence_test.exs CapturingAgent pattern).
  defmodule CapturingWorker do
    @moduledoc false
    use GenServer

    @spec start(pid()) :: GenServer.on_start()
    def start(test_pid), do: GenServer.start(__MODULE__, test_pid)

    @impl GenServer
    def init(test_pid), do: {:ok, test_pid}

    @impl GenServer
    def handle_call(
          {:signal, %{type: "ai.react.set_system_prompt", data: %{system_prompt: prompt}}},
          _from,
          test_pid
        ) do
      send(test_pid, {:injected_prompt, self(), prompt})
      {:reply, {:ok, %{}}, test_pid}
    end

    def handle_call({:signal, _signal}, _from, state), do: {:reply, {:ok, %{}}, state}
  end

  # Seam-scoped runtime: the only way to observe injection per worker pid AND
  # control worker recreation (the real runtime can't do either). Workers are
  # unlinked CapturingWorkers tabled in app env by agent id; `whereis` reports
  # only live pids, mirroring the real registry after a worker death.
  defmodule SeamRuntime do
    @moduledoc false

    alias JidoClaw.Agent.Handoff.RouterTest.CapturingWorker

    @spec whereis(String.t()) :: pid() | nil
    def whereis(agent_id) do
      case Map.get(seam_workers(), agent_id) do
        pid when is_pid(pid) -> if Process.alive?(pid), do: pid
        _ -> nil
      end
    end

    @spec start_subagent(module(), keyword()) :: {:ok, pid()}
    def start_subagent(_module, opts) do
      agent_id = Keyword.fetch!(opts, :id)
      test_pid = Application.fetch_env!(:jido_claw, :router_seam_test_pid)
      {:ok, pid} = CapturingWorker.start(test_pid)

      Application.put_env(
        :jido_claw,
        :router_seam_workers,
        Map.put(seam_workers(), agent_id, pid)
      )

      {:ok, pid}
    end

    defp seam_workers, do: Application.get_env(:jido_claw, :router_seam_workers, %{})
  end

  defp default_pid do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    on_exit_cleanup(pid)
    pid
  end

  defp on_exit_cleanup(pid) do
    test_pid = self()

    spawn(fn ->
      ref = Process.monitor(test_pid)

      receive do
        {:DOWN, ^ref, :process, _, _} -> Process.exit(pid, :kill)
      end
    end)

    pid
  end

  defp install_handoff(tenant_id, runtime_session_id, session_uuid, template_name, module) do
    handoff =
      Handoff.new(%{
        tenant_id: tenant_id,
        runtime_session_id: runtime_session_id,
        session_uuid: session_uuid,
        from_template: "main",
        to_template: template_name,
        to_module: module,
        message: "Please handle"
      })

    :ok = HandoffRegistry.put_owner(tenant_id, runtime_session_id, handoff)
    handoff
  end

  describe "resolve_session_owner/6 — default path" do
    test "no owner returns the default pid, 'main', default agent_id, false, nil",
         %{tenant_id: t, session: session, runtime_session_id: rsid, actor: actor} do
      pid = default_pid()

      assert {^pid, "main", "main", false, nil} =
               HandoffRouter.resolve_session_owner(
                 t,
                 rsid,
                 session.id,
                 pid,
                 actor,
                 project_dir: File.cwd!(),
                 session_record: session,
                 default_agent_id: "main"
               )
    end

    test "missing :default_agent_id raises KeyError",
         %{tenant_id: t, session: session, runtime_session_id: rsid, actor: actor} do
      pid = default_pid()

      assert_raise KeyError, fn ->
        HandoffRouter.resolve_session_owner(
          t,
          rsid,
          session.id,
          pid,
          actor,
          project_dir: File.cwd!(),
          session_record: session
        )
      end
    end
  end

  describe "resolve_session_owner/6 — routed path" do
    test "with installed owner, returns the worker pid + first_post_handoff? true",
         %{tenant_id: t, session: session, runtime_session_id: rsid, actor: actor} do
      install_handoff(t, rsid, session.id, "reviewer", JidoClaw.Agent.Workers.Reviewer)
      default = default_pid()

      assert {worker_pid, "reviewer", agent_id, true, owner} =
               HandoffRouter.resolve_session_owner(
                 t,
                 rsid,
                 session.id,
                 default,
                 actor,
                 project_dir: File.cwd!(),
                 session_record: session,
                 default_agent_id: "main"
               )

      assert is_pid(worker_pid)
      assert worker_pid != default
      assert agent_id == "handoff:#{session.id}:reviewer"
      assert owner.template == "reviewer"
    end

    test "mark_preamble_consumed flips first_post_handoff? on the next call",
         %{tenant_id: t, session: session, runtime_session_id: rsid, actor: actor} do
      install_handoff(t, rsid, session.id, "reviewer", JidoClaw.Agent.Workers.Reviewer)
      default = default_pid()

      {_, _, _, first_a, _} =
        HandoffRouter.resolve_session_owner(t, rsid, session.id, default, actor,
          project_dir: File.cwd!(),
          session_record: session,
          default_agent_id: "main"
        )

      assert first_a == true

      :ok = HandoffRegistry.mark_preamble_consumed(t, rsid)

      {_, _, _, first_b, _} =
        HandoffRouter.resolve_session_owner(t, rsid, session.id, default, actor,
          project_dir: File.cwd!(),
          session_record: session,
          default_agent_id: "main"
        )

      assert first_b == false
    end

    test "system-prompt injection happens once per session+template",
         %{tenant_id: t, session: session, runtime_session_id: rsid, actor: actor} do
      install_handoff(t, rsid, session.id, "reviewer", JidoClaw.Agent.Workers.Reviewer)

      handler_id = "router-prompt-#{System.unique_integer([:positive])}"
      test_pid = self()

      :ok =
        :telemetry.attach(
          handler_id,
          [:jido_claw, :agent, :prompt_injected],
          fn _event, _measurements, metadata, _ ->
            send(test_pid, {:prompt_injected, metadata})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      default = default_pid()

      # First resolve — injects.
      {_, _, _, _, _} =
        HandoffRouter.resolve_session_owner(t, rsid, session.id, default, actor,
          project_dir: File.cwd!(),
          session_record: session,
          default_agent_id: "main"
        )

      assert_receive {:prompt_injected, _}, 2_000
      assert is_pid(HandoffRegistry.owner(t, rsid).prompt_injected_pid)

      # Drain any additional events first
      flush_prompt_events()

      # Second resolve — must not re-inject.
      {_, _, _, _, _} =
        HandoffRouter.resolve_session_owner(t, rsid, session.id, default, actor,
          project_dir: File.cwd!(),
          session_record: session,
          default_agent_id: "main"
        )

      refute_receive {:prompt_injected, _}, 500
    end

    test "stale template clears registry+metadata and falls back to default",
         %{tenant_id: t, session: session, runtime_session_id: rsid, actor: actor} do
      # Install a handoff naming a template that doesn't exist (skip the
      # tool's Templates.get/1 check by going through the registry directly).
      handoff =
        Handoff.new(%{
          tenant_id: t,
          runtime_session_id: rsid,
          session_uuid: session.id,
          to_template: "legacy_gone",
          to_module: JidoClaw.Agent.Workers.Reviewer,
          from_template: "main",
          message: "stale"
        })

      :ok = HandoffRegistry.put_owner(t, rsid, handoff)

      # And mirror that into metadata so we can verify it gets cleared.
      {:ok, s} = ConversationsSession.by_id(session.id, tenant: t, actor: actor)

      {:ok, _} =
        ConversationsSession.set_current_agent_template(s, "legacy_gone",
          tenant: t,
          actor: actor
        )

      default = default_pid()

      assert {^default, "main", "main", false, nil} =
               HandoffRouter.resolve_session_owner(t, rsid, session.id, default, actor,
                 project_dir: File.cwd!(),
                 session_record: session,
                 default_agent_id: "main"
               )

      assert HandoffRegistry.owner(t, rsid) == nil

      {:ok, fresh} = ConversationsSession.by_id(session.id, tenant: t, actor: actor)
      refute Map.has_key?(fresh.metadata || %{}, "current_agent_template")
    end
  end

  describe "AR-8b — composer-private (sandboxed) owners can't own a session" do
    test "a sandboxed registry owner is cleared and falls back to main (route_with_owner)",
         %{tenant_id: t, session: session, runtime_session_id: rsid, actor: actor} do
      install_handoff(t, rsid, session.id, "sketch_build", JidoClaw.Agent.Workers.SketchBuild)

      {:ok, s} = ConversationsSession.by_id(session.id, tenant: t, actor: actor)

      {:ok, _} =
        ConversationsSession.set_current_agent_template(s, "sketch_build",
          tenant: t,
          actor: actor
        )

      default = default_pid()

      assert {^default, "main", "main", false, nil} =
               HandoffRouter.resolve_session_owner(t, rsid, session.id, default, actor,
                 project_dir: File.cwd!(),
                 session_record: session,
                 default_agent_id: "main"
               )

      assert HandoffRegistry.owner(t, rsid) == nil
      {:ok, fresh} = ConversationsSession.by_id(session.id, tenant: t, actor: actor)
      refute Map.has_key?(fresh.metadata || %{}, "current_agent_template")
    end

    test "a sandboxed metadata-only owner is treated as stale → main (fetch_metadata_template)",
         %{tenant_id: t, session: session, runtime_session_id: rsid, actor: actor} do
      # No registry entry — only the metadata mirror points at the sandbox template.
      {:ok, s} = ConversationsSession.by_id(session.id, tenant: t, actor: actor)

      {:ok, _} =
        ConversationsSession.set_current_agent_template(s, "sketch_build",
          tenant: t,
          actor: actor
        )

      assert HandoffRegistry.owner(t, rsid) == nil

      default = default_pid()

      assert {^default, "main", "main", false, nil} =
               HandoffRouter.resolve_session_owner(t, rsid, session.id, default, actor,
                 project_dir: File.cwd!(),
                 session_record: session,
                 default_agent_id: "main"
               )

      {:ok, fresh} = ConversationsSession.by_id(session.id, tenant: t, actor: actor)
      refute Map.has_key?(fresh.metadata || %{}, "current_agent_template")
    end
  end

  describe "resolve_session_owner/6 — cold-start" do
    test "metadata-only owner is re-seeded with preamble_consumed?: true",
         %{tenant_id: t, session: session, runtime_session_id: rsid, actor: actor} do
      # No registry entry exists yet — only metadata.
      {:ok, s} = ConversationsSession.by_id(session.id, tenant: t, actor: actor)

      {:ok, _} =
        ConversationsSession.set_current_agent_template(s, "reviewer",
          tenant: t,
          actor: actor
        )

      assert HandoffRegistry.owner(t, rsid) == nil

      default = default_pid()

      assert {worker_pid, "reviewer", agent_id, false, owner} =
               HandoffRouter.resolve_session_owner(t, rsid, session.id, default, actor,
                 project_dir: File.cwd!(),
                 session_record: session,
                 default_agent_id: "main"
               )

      assert is_pid(worker_pid)
      assert worker_pid != default
      assert agent_id == "handoff:#{session.id}:reviewer"
      assert owner.template == "reviewer"
      assert owner.preamble_consumed? == true
    end

    test "stale metadata is cleared and falls back to default",
         %{tenant_id: t, session: session, runtime_session_id: rsid, actor: actor} do
      {:ok, s} = ConversationsSession.by_id(session.id, tenant: t, actor: actor)

      {:ok, _} =
        ConversationsSession.set_current_agent_template(s, "legacy_gone",
          tenant: t,
          actor: actor
        )

      default = default_pid()

      assert {^default, "main", "main", false, nil} =
               HandoffRouter.resolve_session_owner(t, rsid, session.id, default, actor,
                 project_dir: File.cwd!(),
                 session_record: session,
                 default_agent_id: "main"
               )

      {:ok, fresh} = ConversationsSession.by_id(session.id, tenant: t, actor: actor)
      refute Map.has_key?(fresh.metadata || %{}, "current_agent_template")
    end
  end

  describe "prompt injection keyed by worker pid (seam runtime)" do
    setup do
      orig_runtime = Application.get_env(:jido_claw, :jido_runtime)
      Application.put_env(:jido_claw, :jido_runtime, SeamRuntime)
      Application.put_env(:jido_claw, :router_seam_test_pid, self())
      Application.put_env(:jido_claw, :router_seam_workers, %{})

      on_exit(fn ->
        for {_id, pid} <- Application.get_env(:jido_claw, :router_seam_workers, %{}),
            Process.alive?(pid) do
          GenServer.stop(pid)
        end

        Application.delete_env(:jido_claw, :router_seam_workers)
        Application.delete_env(:jido_claw, :router_seam_test_pid)

        if orig_runtime,
          do: Application.put_env(:jido_claw, :jido_runtime, orig_runtime),
          else: Application.delete_env(:jido_claw, :jido_runtime)
      end)

      :ok
    end

    test "a recreated worker (new pid) is re-injected; an unchanged live worker is not",
         %{tenant_id: t, session: session, runtime_session_id: rsid, actor: actor} do
      install_handoff(t, rsid, session.id, "reviewer", JidoClaw.Agent.Workers.Reviewer)
      default = default_pid()

      opts = [project_dir: File.cwd!(), session_record: session, default_agent_id: "main"]

      # First route: worker created and primed at pid1.
      {pid1, "reviewer", _, _, _} =
        HandoffRouter.resolve_session_owner(t, rsid, session.id, default, actor, opts)

      assert_receive {:injected_prompt, ^pid1, _prompt}, 2_000
      assert HandoffRegistry.owner(t, rsid).prompt_injected_pid == pid1

      # Same live worker: the pid-keyed marker skips re-injection.
      {^pid1, _, _, _, _} =
        HandoffRouter.resolve_session_owner(t, rsid, session.id, default, actor, opts)

      refute_receive {:injected_prompt, _, _}, 300

      # Worker dies (`:temporary` — no supervisor resurrection); the next
      # route lazily recreates it and MUST inject the fresh, empty-state pid.
      ref = Process.monitor(pid1)
      Process.exit(pid1, :kill)
      assert_receive {:DOWN, ^ref, :process, _, _}

      {pid2, "reviewer", _, _, _} =
        HandoffRouter.resolve_session_owner(t, rsid, session.id, default, actor, opts)

      assert pid2 != pid1
      assert_receive {:injected_prompt, ^pid2, _prompt}, 2_000
      assert HandoffRegistry.owner(t, rsid).prompt_injected_pid == pid2
    end
  end

  describe "build_preamble/3" do
    test "returns empty string for nil owner" do
      assert "" = HandoffRouter.build_preamble("t", "s", nil)
    end

    test "includes handoff message, summary, and reason",
         %{tenant_id: t, session: session, runtime_session_id: rsid} do
      handoff =
        Handoff.new(%{
          tenant_id: t,
          runtime_session_id: rsid,
          session_uuid: session.id,
          from_template: "main",
          to_template: "reviewer",
          to_module: JidoClaw.Agent.Workers.Reviewer,
          message: "Please review the diff",
          summary: "User asked for review",
          reason: "Specialist needed"
        })

      owner = %{handoff: handoff, template: "reviewer"}

      preamble = HandoffRouter.build_preamble(t, rsid, owner)

      assert preamble =~ "HANDOFF CONTEXT"
      assert preamble =~ "Please review the diff"
      assert preamble =~ "User asked for review"
      assert preamble =~ "Specialist needed"
      assert preamble =~ "END HANDOFF CONTEXT"
    end

    test "is bounded by max_preamble_bytes even with a huge message and summary",
         %{tenant_id: t, session: session, runtime_session_id: rsid} do
      huge = String.duplicate("x", 50_000)

      handoff =
        Handoff.new(%{
          tenant_id: t,
          runtime_session_id: rsid,
          session_uuid: session.id,
          from_template: "main",
          to_template: "reviewer",
          to_module: JidoClaw.Agent.Workers.Reviewer,
          message: huge,
          summary: huge
        })

      owner = %{handoff: handoff, template: "reviewer"}

      preamble = HandoffRouter.build_preamble(t, rsid, owner)

      assert byte_size(preamble) <= HandoffRouter.max_preamble_bytes(),
             "preamble was #{byte_size(preamble)} bytes"

      assert preamble =~ "truncated"
      assert String.ends_with?(preamble, "END HANDOFF CONTEXT]\n\n")
    end

    test "is bounded by max_preamble_bytes even with a huge reason",
         %{tenant_id: t, session: session, runtime_session_id: rsid} do
      huge = String.duplicate("x", 50_000)

      handoff =
        Handoff.new(%{
          tenant_id: t,
          runtime_session_id: rsid,
          session_uuid: session.id,
          from_template: "main",
          to_template: "reviewer",
          to_module: JidoClaw.Agent.Workers.Reviewer,
          message: "Please review",
          summary: "User asked for review",
          reason: huge
        })

      owner = %{handoff: handoff, template: "reviewer"}

      preamble = HandoffRouter.build_preamble(t, rsid, owner)

      assert byte_size(preamble) <= HandoffRouter.max_preamble_bytes(),
             "preamble was #{byte_size(preamble)} bytes"

      assert preamble =~ "truncated"
      assert String.ends_with?(preamble, "END HANDOFF CONTEXT]\n\n")
    end

    test "is bounded by max_preamble_bytes when message, summary, and reason are all huge",
         %{tenant_id: t, session: session, runtime_session_id: rsid} do
      huge = String.duplicate("x", 50_000)

      handoff =
        Handoff.new(%{
          tenant_id: t,
          runtime_session_id: rsid,
          session_uuid: session.id,
          from_template: "main",
          to_template: "reviewer",
          to_module: JidoClaw.Agent.Workers.Reviewer,
          message: huge,
          summary: huge,
          reason: huge
        })

      owner = %{handoff: handoff, template: "reviewer"}

      preamble = HandoffRouter.build_preamble(t, rsid, owner)

      assert byte_size(preamble) <= HandoffRouter.max_preamble_bytes(),
             "preamble was #{byte_size(preamble)} bytes"

      assert preamble =~ "truncated"
      assert String.ends_with?(preamble, "END HANDOFF CONTEXT]\n\n")
    end

    test "is bounded by max_preamble_bytes when from_template is huge",
         %{tenant_id: t, session: session, runtime_session_id: rsid} do
      handoff =
        Handoff.new(%{
          tenant_id: t,
          runtime_session_id: rsid,
          session_uuid: session.id,
          from_template: String.duplicate("a", 50_000),
          to_template: "reviewer",
          to_module: JidoClaw.Agent.Workers.Reviewer,
          message: "go",
          summary: "go"
        })

      owner = %{handoff: handoff, template: "reviewer"}

      preamble = HandoffRouter.build_preamble(t, rsid, owner)

      assert byte_size(preamble) <= HandoffRouter.max_preamble_bytes(),
             "preamble was #{byte_size(preamble)} bytes"

      assert String.ends_with?(preamble, "END HANDOFF CONTEXT]\n\n")
    end

    test "truncated fields produce valid UTF-8 when the cap lands inside a multi-byte codepoint",
         %{tenant_id: t, session: session, runtime_session_id: rsid} do
      # "🎉" is 4 bytes. Repeating it past the @max_handoff_message_bytes cap
      # guarantees the byte limit lands mid-codepoint at least once.
      emoji_payload = String.duplicate("🎉", 500)

      handoff =
        Handoff.new(%{
          tenant_id: t,
          runtime_session_id: rsid,
          session_uuid: session.id,
          from_template: "main",
          to_template: "reviewer",
          to_module: JidoClaw.Agent.Workers.Reviewer,
          message: emoji_payload,
          summary: emoji_payload,
          reason: emoji_payload
        })

      owner = %{handoff: handoff, template: "reviewer"}

      preamble = HandoffRouter.build_preamble(t, rsid, owner)

      assert String.valid?(preamble),
             "preamble must be valid UTF-8 even when caps land mid-codepoint"

      assert byte_size(preamble) <= HandoffRouter.max_preamble_bytes()
    end
  end

  defp flush_prompt_events do
    receive do
      {:prompt_injected, _} -> flush_prompt_events()
    after
      0 -> :ok
    end
  end
end
