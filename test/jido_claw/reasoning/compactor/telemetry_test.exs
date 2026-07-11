defmodule JidoClaw.Reasoning.Compactor.TelemetryTest do
  use ExUnit.Case, async: true

  alias JidoClaw.Reasoning.Compactor.Telemetry

  setup do
    test_pid = self()
    handler_id = "compactor-telemetry-test-#{System.unique_integer([:positive])}"
    # Scope key threaded through every base_metadata below: the handler only
    # forwards this test's own events, so concurrent async modules emitting
    # [:jido_claw, :compaction, :event] can't pollute the exact-count drains.
    scope = "compactor-tel-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:jido_claw, :compaction, :event],
        fn _event, measurements, metadata, _ ->
          if metadata[:scope] == scope do
            send(test_pid, {:compaction_event, measurements, metadata})
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    {:ok, scope: scope}
  end

  defp drain_events(acc \\ []) do
    receive do
      {:compaction_event, measurements, metadata} ->
        drain_events([{measurements, metadata} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "with_compaction/4 — :summarized" do
    test "emits start then summarized", %{scope: scope} do
      fake_snapshot = %{id: "cpct_x"}

      result =
        Telemetry.with_compaction(
          "summary",
          %{tenant_id: "t", session_uuid: "s", scope: scope},
          fn ->
            {:ok, :summarized, fake_snapshot, %{compaction_id: "cpct_x", summary_chars: 100}}
          end
        )

      assert {:ok, :summarized, ^fake_snapshot, _} = result

      events = drain_events()
      assert [{m1, md1}, {m2, md2}] = events
      assert md1.event == :start
      assert md1.category == :compaction
      assert m1[:system_time] != nil
      assert md2.event == :summarized
      assert md2.status == :summarized
      assert md2.compaction_id == "cpct_x"
      assert m2[:duration_ms] != nil
    end
  end

  describe "with_compaction/4 — :skipped" do
    test "emits start then skipped with reason in metadata", %{scope: scope} do
      _ =
        Telemetry.with_compaction(
          "summary",
          %{tenant_id: "t", scope: scope},
          fn -> {:ok, :skipped, nil, %{reason: :below_threshold}} end
        )

      [{_, md_start}, {_, md_skipped}] = drain_events()
      assert md_start.event == :start
      assert md_skipped.event == :skipped
      assert md_skipped.reason == :below_threshold
    end
  end

  describe "with_compaction/4 — :error" do
    test "emits start then error with reason as inspected string", %{scope: scope} do
      _ =
        Telemetry.with_compaction(
          "summary",
          %{tenant_id: "t", scope: scope},
          fn -> {:error, :boom} end
        )

      [{_, md_start}, {_, md_error}] = drain_events()
      assert md_start.event == :start
      assert md_error.event == :error
      assert md_error.status == :error
      assert md_error.reason == ":boom"
    end
  end

  describe "with_compaction/4 — exit" do
    test "catches an exit, emits :error, returns {:error, reason}", %{scope: scope} do
      result =
        Telemetry.with_compaction(
          "summary",
          %{scope: scope},
          fn -> exit(:bad) end
        )

      assert {:error, :bad} = result
      [_start, {_, md_error}] = drain_events()
      assert md_error.event == :error
    end
  end
end
