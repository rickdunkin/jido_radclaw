defmodule JidoClaw.Tools.GetAgentResultTest do
  use ExUnit.Case, async: false

  alias JidoClaw.Tools.GetAgentResult

  @tenant_id "tenant-get-agent-result-test"

  defmodule FakeJido do
    @moduledoc false

    @spec whereis(String.t()) :: pid() | nil
    def whereis("missing"), do: nil
    def whereis(_agent_id), do: self()
  end

  defmodule FakeAwait do
    @moduledoc false

    @spec completion(pid(), timeout()) :: term()
    def completion(_pid, _timeout) do
      case Process.get(:fake_await_result) do
        {:raise, exception} -> raise exception
        result -> result
      end
    end

    @spec completion(pid(), timeout(), keyword()) :: term()
    def completion(_pid, _timeout, _opts) do
      # 3-arity branch is used when the tracker carries a request_id and
      # request-scoped paths are passed in. Drive it from the same
      # process-dictionary slot the 2-arity stub uses so tests stay
      # backwards-compatible while opting in to the typed-output path.
      case Process.get(:fake_await_result_3) do
        nil ->
          case Process.get(:fake_await_result) do
            {:raise, exception} -> raise exception
            result -> result
          end

        {:raise, exception} ->
          raise exception

        result ->
          result
      end
    end
  end

  defmodule FakeTracker do
    @moduledoc false
    @spec get_agent(String.t()) :: map() | nil
    def get_agent(_agent_id), do: Process.get(:fake_tracker_entry)

    @spec get_agent(String.t(), keyword()) :: map() | nil
    def get_agent(_agent_id, opts) do
      if Keyword.get(opts, :tenant_id) == "tenant-get-agent-result-test" do
        Process.get(:fake_tracker_entry) || %{}
      end
    end
  end

  setup do
    original_jido = Application.get_env(:jido_claw, :jido_runtime)
    original_await = Application.get_env(:jido_claw, :jido_await)
    original_tracker = Application.get_env(:jido_claw, :agent_tracker)

    Application.put_env(:jido_claw, :jido_runtime, FakeJido)
    Application.put_env(:jido_claw, :jido_await, FakeAwait)
    Application.put_env(:jido_claw, :agent_tracker, FakeTracker)

    on_exit(fn ->
      restore_env(:jido_runtime, original_jido)
      restore_env(:jido_await, original_await)
      restore_env(:agent_tracker, original_tracker)
      Process.delete(:fake_await_result)
      Process.delete(:fake_await_result_3)
      Process.delete(:fake_tracker_entry)
    end)

    :ok
  end

  test "returns ok only for completed agents" do
    Process.put(:fake_await_result, {:ok, %{status: :completed, last_answer: "done"}})

    assert {:ok, %{status: "completed", result: "done"}} =
             GetAgentResult.run(%{agent_id: "agent-1"}, ctx())
  end

  test "returns error when the agent is still running" do
    Process.put(:fake_await_result, {:error, :timeout})

    assert {:error, %{code: :execution_error, message: message, details: details}} =
             GetAgentResult.run(%{agent_id: "agent-1", timeout: 1}, ctx())

    assert message =~ "hasn't finished"
    assert details.agent_id == "agent-1"
    assert details.status == "still_running"
    assert details.code == :still_running
    assert details.phase == :timeout
  end

  test "returns error for agent failure tuples" do
    Process.put(:fake_await_result, {:error, :crashed})

    assert {:error, %{code: :execution_error, message: "Agent failed.", details: details}} =
             GetAgentResult.run(%{agent_id: "agent-1"}, ctx())

    assert details.agent_id == "agent-1"
    assert details.status == "failed"
    assert details.code == :failed
    assert details.error == ":crashed"
  end

  test "returns error when await reports terminal failed status" do
    Process.put(:fake_await_result, {:ok, %{status: :failed, error: :tool_failed}})

    assert {:error, %{code: :execution_error, message: "Agent failed.", details: details}} =
             GetAgentResult.run(%{agent_id: "agent-1"}, ctx())

    assert details.agent_id == "agent-1"
    assert details.status == "failed"
    assert details.code == :failed
    assert details.error == ":tool_failed"
  end

  test "returns error when awaiting raises" do
    Process.put(:fake_await_result, {:raise, RuntimeError.exception("boom")})

    assert {:error, %{code: :execution_error, message: "boom", details: details}} =
             GetAgentResult.run(%{agent_id: "agent-1"}, ctx())

    assert details.agent_id == "agent-1"
    assert details.status == "error"
    assert details.code == :error
  end

  test "returns error when agent is not found" do
    assert {:error, %{code: :validation_error, message: message, details: details}} =
             GetAgentResult.run(%{agent_id: "missing"}, ctx(%{tenant_id: "other-tenant"}))

    assert message =~ "not found"
    assert details.field == :agent
    assert details.value == "missing"
  end

  test "returns not_found when the agent exists but in another tenant" do
    # Entry exists in @tenant_id, but the fake tracker tenant-gates get_agent/2,
    # so a caller in another tenant must see it as not_found.
    Process.put(:fake_tracker_entry, %{template: "coder"})

    assert {:error, %{code: :validation_error, details: details}} =
             GetAgentResult.run(%{agent_id: "agent-1"}, ctx(%{tenant_id: "intruder-tenant"}))

    assert details.reason == :not_found
    assert details.value == "agent-1"
  end

  test "requires tenant scope before resolving tracker or runtime state" do
    assert {:error, %{code: :tenant_required}} =
             GetAgentResult.run(%{agent_id: "agent-1"}, %{})
  end

  describe "request-scoped path (tracker carries :request_id)" do
    test "surfaces typed result + meta from completed request map" do
      request_id = "req-typed"

      typed = %{verdict: :pass, confidence: :high, reasoning: "all green"}
      meta = %{status: :validated, schema_kind: :zoi, attempt: 0}

      request = %{
        status: :completed,
        result: typed,
        meta: %{output: meta}
      }

      Process.put(:fake_tracker_entry, %{request_id: request_id})

      Process.put(
        :fake_await_result_3,
        {:ok, %{status: :completed, result: request}}
      )

      assert {:ok, response} = GetAgentResult.run(%{agent_id: "agent-1"}, ctx())
      assert response.agent_id == "agent-1"
      assert response.status == "completed"
      assert response.result == typed
      assert response.output_meta == meta
    end

    test "falls back to text result when meta status is not :validated/:repaired" do
      request_id = "req-untyped"

      request = %{
        status: :completed,
        result: "free-form answer",
        meta: %{}
      }

      Process.put(:fake_tracker_entry, %{request_id: request_id})

      Process.put(
        :fake_await_result_3,
        {:ok, %{status: :completed, result: request}}
      )

      assert {:ok, response} = GetAgentResult.run(%{agent_id: "agent-1"}, ctx())
      assert response.result == "free-form answer"
      refute Map.has_key?(response, :output_meta)
    end

    test "translates failed request to execution error" do
      request_id = "req-failed"
      Process.put(:fake_tracker_entry, %{request_id: request_id})

      Process.put(
        :fake_await_result_3,
        {:ok, %{status: :failed, result: :crashed}}
      )

      assert {:error, %{code: :execution_error, details: details}} =
               GetAgentResult.run(%{agent_id: "agent-1"}, ctx())

      assert details.status == "failed"
      assert details.error =~ ":crashed"
    end

    test "fallback path (no request_id) still works via 2-arity completion" do
      # Tracker entry has no request_id → 2-arity completion path.
      Process.put(:fake_tracker_entry, %{})
      Process.put(:fake_await_result, {:ok, %{status: :completed, last_answer: "legacy"}})

      assert {:ok, %{result: "legacy"}} =
               GetAgentResult.run(%{agent_id: "legacy-agent"}, ctx())
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:jido_claw, key)
  defp restore_env(key, value), do: Application.put_env(:jido_claw, key, value)

  defp ctx(extra \\ %{}) do
    %{tool_context: Map.merge(%{tenant_id: @tenant_id}, extra)}
  end
end
