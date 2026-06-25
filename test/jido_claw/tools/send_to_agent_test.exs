defmodule JidoClaw.Tools.SendToAgentTest do
  use ExUnit.Case, async: false

  alias JidoClaw.Tools.SendToAgent

  @tenant_id "tenant-send-to-agent-test"

  defmodule FakeJido do
    @moduledoc false

    @spec whereis(String.t()) :: pid() | nil
    def whereis("missing"), do: nil
    def whereis(_agent_id), do: self()
  end

  defmodule FakeTracker do
    @moduledoc false

    @spec get_agent(String.t()) :: map() | nil
    def get_agent("docs_writer_123"), do: %{template: "docs_writer"}
    def get_agent("untracked_123"), do: nil
    def get_agent("missing"), do: %{template: "docs_writer"}

    @spec get_agent(String.t(), keyword()) :: map() | nil
    def get_agent("docs_writer_123", opts), do: scoped(opts, %{template: "docs_writer"})
    def get_agent("missing", opts), do: scoped(opts, %{template: "docs_writer"})
    def get_agent(_agent_id, _opts), do: nil

    # send_to_agent now calls update_request_id/2 to overwrite the
    # tracked request_id after each follow-up turn. Default to a no-op
    # for the existing assertions that don't care about the call —
    # CapturingTracker (below) exercises the wired call.
    @spec update_request_id(String.t(), String.t()) :: :ok
    def update_request_id(_agent_id, _request_id), do: :ok

    @spec mark_running(String.t(), pid()) :: {:ok, :reactivated}
    def mark_running(_agent_id, _pid), do: {:ok, :reactivated}

    @spec mark_complete(String.t(), :done | :error) :: :ok
    def mark_complete(_agent_id, _status), do: :ok

    @spec attach_orchestrator(String.t(), pid()) :: :ok
    def attach_orchestrator(_agent_id, _pid), do: :ok

    defp scoped(opts, entry) do
      if Keyword.get(opts, :tenant_id) == "tenant-send-to-agent-test", do: entry
    end
  end

  defmodule CapturingTracker do
    @moduledoc false

    @spec get_agent(String.t()) :: map() | nil
    def get_agent("docs_writer_123"), do: %{template: "docs_writer"}
    def get_agent("untracked_123"), do: nil

    @spec get_agent(String.t(), keyword()) :: map() | nil
    def get_agent("docs_writer_123", opts), do: scoped(opts, %{template: "docs_writer"})
    def get_agent(_agent_id, _opts), do: nil

    @spec update_request_id(String.t(), String.t()) :: :ok
    def update_request_id(agent_id, request_id) do
      send(
        Application.fetch_env!(:jido_claw, :send_to_agent_test_pid),
        {:update_request_id, agent_id, request_id}
      )

      :ok
    end

    @spec mark_running(String.t(), pid()) :: {:ok, :reactivated}
    def mark_running(_agent_id, _pid), do: {:ok, :reactivated}

    @spec mark_complete(String.t(), :done | :error) :: :ok
    def mark_complete(_agent_id, _status), do: :ok

    @spec attach_orchestrator(String.t(), pid()) :: :ok
    def attach_orchestrator(_agent_id, _pid), do: :ok

    defp scoped(opts, entry) do
      if Keyword.get(opts, :tenant_id) == "tenant-send-to-agent-test", do: entry
    end
  end

  defmodule FakeTemplates do
    @moduledoc false

    @spec get(String.t()) :: {:ok, map()} | {:error, {:unknown_template, String.t()}}
    def get("docs_writer"), do: {:ok, %{module: JidoClaw.Tools.SendToAgentTest.FakeWorker}}
    def get(name), do: {:error, {:unknown_template, name}}
  end

  # A tracker whose only registered agent is a composer-private (sandboxed)
  # template — for the AR-8b refusal test.
  defmodule SandboxTracker do
    @moduledoc false

    @spec get_agent(String.t(), keyword()) :: map() | nil
    def get_agent("sketch_agent", opts) do
      if Keyword.get(opts, :tenant_id) == "tenant-send-to-agent-test",
        do: %{template: "sketch_build"}
    end

    def get_agent("docker_agent", opts) do
      if Keyword.get(opts, :tenant_id) == "tenant-send-to-agent-test",
        do: %{template: "docker_stub"}
    end

    def get_agent("sketch_exec_agent", opts) do
      if Keyword.get(opts, :tenant_id) == "tenant-send-to-agent-test",
        do: %{template: "sketch_build_exec"}
    end

    def get_agent(_agent_id, _opts), do: nil

    # Straggler absorbers: an orchestration task from an earlier test can outlive
    # its test (parked on the Recorder flush) and read this swapped-in tracker
    # late — absorb its writes instead of crashing (the TakenTracker convention).
    @spec mark_complete(String.t(), :done | :error) :: :ok
    def mark_complete(_agent_id, _status), do: :ok

    @spec attach_orchestrator(String.t(), pid()) :: :ok
    def attach_orchestrator(_agent_id, _pid), do: :ok

    @spec update_request_id(String.t(), String.t()) :: :ok
    def update_request_id(_agent_id, _request_id), do: :ok
  end

  defmodule RestrictedTemplates do
    @moduledoc false

    @spec get(String.t()) :: {:ok, map()} | {:error, {:unknown_template, String.t()}}
    def get("docs_writer"),
      do: {:ok, %{module: JidoClaw.Tools.SendToAgentTest.FakeWorker, forward_context: :none}}

    def get(name), do: {:error, {:unknown_template, name}}
  end

  defmodule FakeWorker do
    @moduledoc false

    @spec ask_sync(pid(), String.t(), keyword()) :: :ok
    def ask_sync(pid, message, opts) do
      send(Application.fetch_env!(:jido_claw, :send_to_agent_test_pid), {
        :ask_sync,
        __MODULE__,
        pid,
        message,
        opts
      })

      :ok
    end
  end

  defmodule BlockingTemplates do
    @moduledoc false

    @spec get(String.t()) :: {:ok, map()}
    def get("docs_writer"),
      do: {:ok, %{module: JidoClaw.Tools.SendToAgentTest.BlockingWorker}}
  end

  defmodule BlockingWorker do
    @moduledoc false

    # Holds the follow-up dispatch open until the test releases it, so the
    # in-flight tracker state can be asserted deterministically.
    @spec ask_sync(pid(), String.t(), keyword()) :: :ok
    def ask_sync(_pid, message, _opts) do
      test_pid = Application.fetch_env!(:jido_claw, :send_to_agent_test_pid)
      send(test_pid, {:ask_sync_started, self(), message})

      receive do
        :release -> :ok
      after
        5_000 -> :ok
      end
    end
  end

  defmodule RealPidJido do
    @moduledoc false
    @spec whereis(String.t()) :: pid() | nil
    def whereis(_agent_id), do: Application.get_env(:jido_claw, :send_to_agent_real_pid)
  end

  setup do
    original_jido = Application.get_env(:jido_claw, :jido_runtime)
    original_tracker = Application.get_env(:jido_claw, :agent_tracker)
    original_templates = Application.get_env(:jido_claw, :agent_templates)
    original_test_pid = Application.get_env(:jido_claw, :send_to_agent_test_pid)
    original_flush_timeout = Application.get_env(:jido_claw, :recorder_flush_timeout)
    original_task_supervisor = Application.get_env(:jido_claw, :task_supervisor)
    original_mcp_facade = Application.get_env(:jido_claw, :mcp_facade)
    original_mcp_target = Application.get_env(:jido_claw, :mcp_facade_capture_target)

    Application.put_env(:jido_claw, :jido_runtime, FakeJido)
    Application.put_env(:jido_claw, :agent_tracker, FakeTracker)
    Application.put_env(:jido_claw, :agent_templates, FakeTemplates)
    Application.put_env(:jido_claw, :send_to_agent_test_pid, self())
    # The follow-up orchestration's terminal record flushes the Recorder; no
    # ai.* signals flow in these tests, so shrink the wait from the 30s
    # default to keep spawned orchestrators short-lived.
    Application.put_env(:jido_claw, :recorder_flush_timeout, 50)

    on_exit(fn ->
      restore_env(:jido_runtime, original_jido)
      restore_env(:agent_tracker, original_tracker)
      restore_env(:agent_templates, original_templates)
      restore_env(:send_to_agent_test_pid, original_test_pid)
      restore_env(:recorder_flush_timeout, original_flush_timeout)
      restore_env(:task_supervisor, original_task_supervisor)
      restore_env(:mcp_facade, original_mcp_facade)
      restore_env(:mcp_facade_capture_target, original_mcp_target)
    end)

    :ok
  end

  test "uses AgentTracker template metadata for multi-word template ids" do
    assert {:ok, %{status: "message_sent"}} =
             SendToAgent.run(
               %{agent_id: "docs_writer_123", message: "please expand docs"},
               ctx(%{agent_id: "main"})
             )

    assert_receive {:ask_sync, FakeWorker, pid, "please expand docs", opts}

    assert pid == self()
    assert opts[:tool_context].agent_id == "docs_writer_123"
    assert opts[:request_id]
  end

  test "does not touch the runtime when scoped tracker metadata is missing" do
    assert {:error, %{code: :validation_error, message: message, details: details}} =
             SendToAgent.run(%{agent_id: "untracked_123", message: "hello"}, ctx())

    assert message == "Agent 'untracked_123' not found."
    assert details.reason == :not_found
    assert details.value == "untracked_123"
  end

  test "requires tenant scope before resolving tracker or runtime state" do
    assert {:error, %{code: :tenant_required}} =
             SendToAgent.run(%{agent_id: "docs_writer_123", message: "hello"}, %{})
  end

  test "refuses a follow-up to a composer-private (sandboxed) agent (AR-8b)" do
    # Real Templates so `sketch_build` resolves to the genuine sandboxed template.
    Application.put_env(:jido_claw, :agent_tracker, SandboxTracker)
    Application.put_env(:jido_claw, :agent_templates, JidoClaw.Agent.Templates)

    assert {:error, %{code: :execution_error, details: details}} =
             SendToAgent.run(%{agent_id: "sketch_agent", message: "more"}, ctx())

    assert details.reason == :composer_private
    assert details.template == "sketch_build"
    # The guard fires before dispatch, so the worker is never invoked.
    refute_receive {:ask_sync, _mod, _pid, _msg, _opts}, 200
  end

  test "refuses a follow-up to a composer-private :docker agent too (AR-8b-2 F2)" do
    Application.put_env(:jido_claw, :agent_tracker, SandboxTracker)
    Application.put_env(:jido_claw, :agent_templates, JidoClaw.Agent.Templates)

    override = %{"docker_stub" => %{module: JidoClaw.Agent.Workers.Coder, sandbox: :docker}}
    Application.put_env(:jido_claw, :agent_templates_override, override)
    on_exit(fn -> Application.delete_env(:jido_claw, :agent_templates_override) end)

    assert {:error, %{code: :execution_error, details: details}} =
             SendToAgent.run(%{agent_id: "docker_agent", message: "more"}, ctx())

    assert details.reason == :composer_private
    assert details.template == "docker_stub"
    refute_receive {:ask_sync, _mod, _pid, _msg, _opts}, 200
  end

  test "refuses a follow-up to the REAL sketch_build_exec agent (AR-8b-2 F2)" do
    Application.put_env(:jido_claw, :agent_tracker, SandboxTracker)
    Application.put_env(:jido_claw, :agent_templates, JidoClaw.Agent.Templates)

    assert {:error, %{code: :execution_error, details: details}} =
             SendToAgent.run(%{agent_id: "sketch_exec_agent", message: "more"}, ctx())

    assert details.reason == :composer_private
    assert details.template == "sketch_build_exec"
    refute_receive {:ask_sync, _mod, _pid, _msg, _opts}, 200
  end

  test "returns error when the agent process is missing" do
    assert {:error, %{message: "Agent 'missing' not found."}} =
             SendToAgent.run(%{agent_id: "missing", message: "hello"}, ctx())
  end

  test "returns not_found when the agent exists but in another tenant" do
    # docs_writer_123 is tracked under @tenant_id; a caller in another tenant
    # must see it as not_found (the fake tracker tenant-gates get_agent/2).
    assert {:error, %{code: :validation_error, details: details}} =
             SendToAgent.run(
               %{agent_id: "docs_writer_123", message: "hello"},
               ctx(%{tenant_id: "intruder-tenant"})
             )

    assert details.reason == :not_found
    assert details.value == "docs_writer_123"
  end

  test "re-applies the template's forward_context policy on every follow-up" do
    Application.put_env(:jido_claw, :agent_templates, RestrictedTemplates)

    # No tenant_id → register_child_correlation skips the DB write.
    tool_context = %{
      tenant_id: @tenant_id,
      agent_id: "main",
      session_id: "s",
      user_id: "u",
      workspace_uuid: "w",
      actor: %{kind: :system}
    }

    assert {:ok, %{status: "message_sent"}} =
             SendToAgent.run(
               %{agent_id: "docs_writer_123", message: "follow-up"},
               %{tool_context: tool_context}
             )

    assert_receive {:ask_sync, FakeWorker, _pid, "follow-up", opts}

    child_ctx = opts[:tool_context]
    assert child_ctx.user_id == nil
    assert child_ctx.workspace_uuid == nil
    assert child_ctx.actor == nil
    assert child_ctx.session_id == "s"
  end

  test "ensure_attaches the tracked template's external MCP tools onto the running child" do
    Application.put_env(:jido_claw, :mcp_facade, JidoClaw.Test.MCPFacadeCapture)
    Application.put_env(:jido_claw, :mcp_facade_capture_target, self())

    assert {:ok, %{status: "message_sent"}} =
             SendToAgent.run(
               %{agent_id: "docs_writer_123", message: "follow-up"},
               ctx(%{agent_id: "main"})
             )

    # The follow-up orchestration task bounds-attaches the child pid (FakeJido
    # returns self()) under its tracked template before the turn.
    assert_receive {:mcp_ensure_attached, pid, "docs_writer", 8_000}, 2_000
    assert pid == self()
  end

  test "sets :agent_template from the tracked entry's template on the follow-up child" do
    assert {:ok, %{status: "message_sent"}} =
             SendToAgent.run(
               %{agent_id: "docs_writer_123", message: "follow-up"},
               ctx(%{agent_id: "main"})
             )

    assert_receive {:ask_sync, FakeWorker, _pid, "follow-up", opts}

    # child/3 clears it; the tool restores it from entry.template so the
    # per-template approval policy applies to every follow-up turn.
    assert opts[:tool_context].agent_template == "docs_writer"
  end

  test "updates AgentTracker with the follow-up request_id" do
    Application.put_env(:jido_claw, :agent_tracker, CapturingTracker)

    assert {:ok, %{status: "message_sent"}} =
             SendToAgent.run(
               %{agent_id: "docs_writer_123", message: "follow-up"},
               ctx(%{agent_id: "main"})
             )

    assert_receive {:ask_sync, FakeWorker, _pid, "follow-up", opts}
    request_id = opts[:request_id]
    assert is_binary(request_id)

    assert_receive {:update_request_id, "docs_writer_123", ^request_id}
  end

  describe "re-engagement of a finished agent (real tracker)" do
    setup do
      Application.put_env(:jido_claw, :agent_tracker, JidoClaw.AgentTracker)
      JidoClaw.AgentTracker.reset()

      on_exit(fn -> JidoClaw.AgentTracker.reset() end)

      :ok
    end

    test "marks the entry running for the dispatch and completes it with the outcome" do
      alias JidoClaw.AgentTracker

      Application.put_env(:jido_claw, :agent_templates, BlockingTemplates)

      # FakeJido.whereis returns self(), so track the test process as the
      # child pid to satisfy mark_running's pid-identity check.
      assert :ok =
               AgentTracker.register("docs_writer_123", self(), "docs_writer", "initial task",
                 tenant_id: @tenant_id
               )

      AgentTracker.mark_complete("docs_writer_123", :done)
      _ = AgentTracker.get_state()
      assert AgentTracker.child_count(tenant_id: @tenant_id) == 0

      assert {:ok, %{status: "message_sent"}} =
               SendToAgent.run(%{agent_id: "docs_writer_123", message: "round two"}, ctx())

      assert_receive {:ask_sync_started, worker_pid, "round two"}, 1_000

      # While the follow-up is in flight the entry is running again and
      # re-consumes the spawn cap.
      assert %{status: :running} = AgentTracker.get_agent("docs_writer_123")
      assert AgentTracker.child_count(tenant_id: @tenant_id) == 1

      send(worker_pid, :release)

      wait_until(fn ->
        match?(%{status: :done}, AgentTracker.get_agent("docs_writer_123"))
      end)

      assert AgentTracker.child_count(tenant_id: @tenant_id) == 0
    end

    test "a killed follow-up orchestration forces the entry terminal and frees the cap (M17)" do
      alias JidoClaw.AgentTracker

      Application.put_env(:jido_claw, :agent_templates, BlockingTemplates)

      assert :ok =
               AgentTracker.register("docs_writer_123", self(), "docs_writer", "initial task",
                 tenant_id: @tenant_id
               )

      AgentTracker.mark_complete("docs_writer_123", :done)
      _ = AgentTracker.get_state()

      assert {:ok, %{status: "message_sent"}} =
               SendToAgent.run(%{agent_id: "docs_writer_123", message: "round two"}, ctx())

      # `self()` inside BlockingWorker.ask_sync is the orchestration task.
      assert_receive {:ask_sync_started, task_pid, "round two"}, 1_000
      assert %{status: :running} = AgentTracker.get_agent("docs_writer_123")

      # Kill the orchestrator (uncatchable — the in-task try/catch never
      # runs). The monitor backstop must release the re-activated entry; the
      # agent pid (the test process) stays alive throughout.
      Process.exit(task_pid, :kill)

      wait_until(fn ->
        match?(%{status: :error}, AgentTracker.get_agent("docs_writer_123"))
      end)

      assert %{error: error} = AgentTracker.get_agent("docs_writer_123")
      assert error =~ "orchestrator died"
      assert AgentTracker.child_count(tenant_id: @tenant_id) == 0
    end

    test "leaves the entry terminal when the template lookup fails" do
      alias JidoClaw.AgentTracker

      # The tracked template is unknown to the templates module, so the
      # follow-up fails before the mark_running gate.
      assert :ok =
               AgentTracker.register("docs_writer_123", self(), "mystery_template", "initial",
                 tenant_id: @tenant_id
               )

      AgentTracker.mark_complete("docs_writer_123", :done)
      _ = AgentTracker.get_state()

      assert {:error, %{code: :execution_error, details: %{phase: :template_lookup}}} =
               SendToAgent.run(%{agent_id: "docs_writer_123", message: "hi"}, ctx())

      assert %{status: :done} = AgentTracker.get_agent("docs_writer_123")
      assert AgentTracker.child_count(tenant_id: @tenant_id) == 0
    end

    test "a start failure on a busy agent leaves the in-flight run intact (P2-1 regression)" do
      alias JidoClaw.AgentTracker

      Application.put_env(:jido_claw, :agent_templates, BlockingTemplates)

      assert :ok =
               AgentTracker.register("docs_writer_123", self(), "docs_writer", "initial task",
                 tenant_id: @tenant_id
               )

      AgentTracker.mark_complete("docs_writer_123", :done)
      _ = AgentTracker.get_state()

      # First follow-up engages the agent for real and is held open by the
      # blocking worker.
      assert {:ok, %{status: "message_sent"}} =
               SendToAgent.run(%{agent_id: "docs_writer_123", message: "round two"}, ctx())

      assert_receive {:ask_sync_started, task1, "round two"}, 1_000
      assert %{status: :running} = AgentTracker.get_agent("docs_writer_123")

      # Second follow-up hits the busy agent and its orchestration fails to
      # start: the in-flight run must be left untouched — still running,
      # still consuming the cap, task1's monitor still armed.
      start_supervised!({Task.Supervisor, name: __MODULE__.CrampedTaskSup, max_children: 0})

      Application.put_env(:jido_claw, :task_supervisor, __MODULE__.CrampedTaskSup)

      assert {:error, %{code: :execution_error, details: %{phase: :dispatch}}} =
               SendToAgent.run(%{agent_id: "docs_writer_123", message: "round three"}, ctx())

      assert %{status: :running} = AgentTracker.get_agent("docs_writer_123")
      assert AgentTracker.child_count(tenant_id: @tenant_id) == 1

      # The kept-monitor proof: killing the in-flight orchestrator must
      # still force the entry terminal instead of stranding it :running.
      Process.exit(task1, :kill)

      wait_until(fn ->
        match?(%{status: :error}, AgentTracker.get_agent("docs_writer_123"))
      end)

      assert %{error: error} = AgentTracker.get_agent("docs_writer_123")
      assert error =~ "orchestrator died"
      assert AgentTracker.child_count(tenant_id: @tenant_id) == 0
    end

    test "a start failure on a re-engaged terminal entry forces it back terminal" do
      alias JidoClaw.AgentTracker

      Application.put_env(:jido_claw, :agent_templates, BlockingTemplates)

      assert :ok =
               AgentTracker.register("docs_writer_123", self(), "docs_writer", "initial task",
                 tenant_id: @tenant_id
               )

      AgentTracker.mark_complete("docs_writer_123", :done)
      _ = AgentTracker.get_state()

      start_supervised!({Task.Supervisor, name: __MODULE__.CrampedTaskSup, max_children: 0})

      Application.put_env(:jido_claw, :task_supervisor, __MODULE__.CrampedTaskSup)

      assert {:error, %{code: :execution_error, details: %{phase: :dispatch}}} =
               SendToAgent.run(%{agent_id: "docs_writer_123", message: "round two"}, ctx())

      # This call's mark_running re-activated the terminal entry; with no
      # orchestration behind it, the failure path must force it back
      # terminal — cap free, agent (the test process) alive and
      # re-engageable.
      assert %{status: :error} = AgentTracker.get_agent("docs_writer_123")
      assert AgentTracker.child_count(tenant_id: @tenant_id) == 0
    end

    @tag :capture_log
    test "injects the AR-5 doctrine prompt before the follow-up turn (real worker pid)" do
      alias JidoClaw.AgentTracker

      tag = "docs_writer_ar5_#{System.unique_integer([:positive])}"

      # The turn runs through BlockingWorker (observable, never hits an LLM)
      # while set_system_prompt targets the real DocsWriter pid — template.module
      # and the injected pid are independent in the dispatch task. RealPidJido
      # decouples whereis from Registry lookup mechanics.
      Application.put_env(:jido_claw, :agent_templates, BlockingTemplates)
      Application.put_env(:jido_claw, :jido_runtime, RealPidJido)
      Application.put_env(:jido_claw, :send_to_agent_test_pid, self())

      # The flag is OFF globally, so a deleted inject call would never fire —
      # that is exactly the regression this test pins.
      original_doctrine = Application.get_env(:jido_claw, :doctrine)
      Application.put_env(:jido_claw, :doctrine, enabled?: true)

      {:ok, pid} = JidoClaw.Jido.start_subagent(JidoClaw.Agent.Workers.DocsWriter, id: tag)
      Application.put_env(:jido_claw, :send_to_agent_real_pid, pid)

      on_exit(fn ->
        if Process.alive?(pid), do: JidoClaw.Jido.stop_agent(pid)
        Application.delete_env(:jido_claw, :send_to_agent_real_pid)

        case original_doctrine do
          nil -> Application.delete_env(:jido_claw, :doctrine)
          val -> Application.put_env(:jido_claw, :doctrine, val)
        end

        AgentTracker.reset()
      end)

      # Flush to a terminal entry so the follow-up cleanly reactivates it.
      assert :ok =
               AgentTracker.register(tag, pid, "docs_writer", "initial", tenant_id: @tenant_id)

      AgentTracker.mark_complete(tag, :done)
      _ = AgentTracker.get_state()

      handler_id = "ar5-send-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:jido_claw, :agent, :prompt_injected],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:injected, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      # ctx is tenant-only → correlation is cache-only, no DB.
      assert {:ok, %{status: "message_sent"}} =
               SendToAgent.run(%{agent_id: tag, message: "follow-up"}, ctx())

      # Ordering proof: the dispatch task injects (firing the telemetry) BEFORE
      # SubagentTranscript.run reaches BlockingWorker.ask_sync. So by the time
      # the worker signals its turn, {:injected} is already enqueued — the
      # no-wait assert_received succeeds in the fixed code and would fail if the
      # inject call ran after the turn.
      assert_receive {:ask_sync_started, worker_pid, "follow-up"}, 10_000
      assert_received {:injected, metadata}
      assert metadata.source == :doctrine
      assert metadata.template == "docs_writer"

      send(worker_pid, :release)
    end
  end

  defp wait_until(fun, timeout_ms \\ 2_000) do
    wait_until_deadline(fun, System.monotonic_time(:millisecond) + timeout_ms)
  end

  defp wait_until_deadline(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("condition not met within timeout")

      true ->
        Process.sleep(20)
        wait_until_deadline(fun, deadline)
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:jido_claw, key)
  defp restore_env(key, value), do: Application.put_env(:jido_claw, key, value)

  defp ctx(extra \\ %{}) do
    %{tool_context: Map.merge(%{tenant_id: @tenant_id}, extra)}
  end
end
