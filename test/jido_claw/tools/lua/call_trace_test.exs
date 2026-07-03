defmodule JidoClaw.Tools.Lua.CallTraceTest do
  use ExUnit.Case, async: true

  alias JidoClaw.Tools.Lua.CallTrace

  setup do
    {:ok, trace} = CallTrace.start_link()
    on_exit(fn -> if Process.alive?(trace), do: Agent.stop(trace) end)
    %{trace: trace}
  end

  describe "reserve/complete/calls" do
    test "reserve records a started call and returns an id", %{trace: trace} do
      assert {:ok, 1} = CallTrace.reserve(trace, "jido.runs", %{"limit" => 5}, 12)

      assert [call] = CallTrace.calls(trace)
      assert call["binding"] == "jido.runs"
      assert call["status"] == "started"
      assert call["output"] == nil
      assert is_binary(call["arguments"])
      refute Map.has_key?(call, :id)
    end

    test "complete updates the matching call's status and output summary", %{trace: trace} do
      {:ok, id} = CallTrace.reserve(trace, "jido.runs", %{}, 12)
      :ok = CallTrace.complete(trace, id, "ok", [%{"run_id" => "a"}, %{"run_id" => "b"}])

      assert [call] = CallTrace.calls(trace)
      assert call["status"] == "ok"
      assert call["output"] == %{"count" => 2}
    end

    test "ids are sequential and calls keep insertion order", %{trace: trace} do
      {:ok, 1} = CallTrace.reserve(trace, "jido.runs", %{}, 12)
      {:ok, 2} = CallTrace.reserve(trace, "jido.cases", %{}, 12)

      assert [%{"binding" => "jido.runs"}, %{"binding" => "jido.cases"}] =
               CallTrace.calls(trace)
    end
  end

  describe "budget refusal" do
    test "refusal at cap+1 returns an error and sets refused?", %{trace: trace} do
      refute CallTrace.refused?(trace)

      {:ok, _} = CallTrace.reserve(trace, "jido.runs", %{}, 2)
      {:ok, _} = CallTrace.reserve(trace, "jido.runs", %{}, 2)

      assert {:error, {:lua_call_budget_exceeded, 2}} =
               CallTrace.reserve(trace, "jido.runs", %{}, 2)

      assert CallTrace.refused?(trace)
      # The refused call is not recorded — it never executed.
      assert [_, _] = CallTrace.calls(trace)
    end

    test "subsequent reserves keep refusing after the first refusal", %{trace: trace} do
      {:ok, _} = CallTrace.reserve(trace, "jido.runs", %{}, 1)

      assert {:error, {:lua_call_budget_exceeded, 1}} =
               CallTrace.reserve(trace, "jido.cases", %{}, 1)

      assert {:error, {:lua_call_budget_exceeded, 1}} =
               CallTrace.reserve(trace, "jido.output", %{}, 1)

      assert CallTrace.refused?(trace)
    end
  end

  describe "bounded records" do
    test "arguments are a bounded preview, never the full data", %{trace: trace} do
      huge = String.duplicate("a", 100_000)
      {:ok, _} = CallTrace.reserve(trace, "jido.output", %{"ref" => huge}, 12)

      assert [call] = CallTrace.calls(trace)
      assert byte_size(call["arguments"]) < 300
    end

    test "output summaries omit the full data", %{trace: trace} do
      huge = String.duplicate("b", 100_000)
      {:ok, id} = CallTrace.reserve(trace, "jido.output", %{}, 12)
      :ok = CallTrace.complete(trace, id, "ok", huge)

      assert [call] = CallTrace.calls(trace)
      assert call["output"] == %{"bytes" => 100_000}
      refute Jason.encode!(CallTrace.calls(trace)) =~ "bbbb"
    end

    test "map output summarizes to approximate bytes", %{trace: trace} do
      {:ok, id} = CallTrace.reserve(trace, "jido.run", %{}, 12)
      :ok = CallTrace.complete(trace, id, "ok", %{"status" => "running"})

      assert [%{"output" => %{"bytes" => bytes}}] = CallTrace.calls(trace)
      assert is_integer(bytes) and bytes > 0
    end
  end
end
