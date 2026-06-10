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

    @spec mark_running(String.t(), pid()) :: :ok
    def mark_running(_agent_id, _pid), do: :ok

    @spec mark_complete(String.t(), :done | :error) :: :ok
    def mark_complete(_agent_id, _status), do: :ok

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

    @spec mark_running(String.t(), pid()) :: :ok
    def mark_running(_agent_id, _pid), do: :ok

    @spec mark_complete(String.t(), :done | :error) :: :ok
    def mark_complete(_agent_id, _status), do: :ok

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

  setup do
    original_jido = Application.get_env(:jido_claw, :jido_runtime)
    original_tracker = Application.get_env(:jido_claw, :agent_tracker)
    original_templates = Application.get_env(:jido_claw, :agent_templates)
    original_test_pid = Application.get_env(:jido_claw, :send_to_agent_test_pid)
    original_flush_timeout = Application.get_env(:jido_claw, :recorder_flush_timeout)

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
