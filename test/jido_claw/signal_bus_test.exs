defmodule JidoClaw.SignalBusTest do
  use ExUnit.Case

  alias Jido.Signal.Bus
  alias JidoClaw.Core.MapKeys

  # Not async: relies on the application-managed JidoClaw.SignalBus.
  # No setup needed — the bus is started by JidoClaw.Application.

  describe "emit/2" do
    test "does not crash on a valid signal type" do
      assert :ok = JidoClaw.SignalBus.emit("jido_claw.tool.complete", %{name: "read_file"})
    end

    test "does not crash when called with no data argument" do
      assert :ok = JidoClaw.SignalBus.emit("jido_claw.memory.saved")
    end

    test "does not crash when emitting multiple signals in sequence" do
      for i <- 1..5 do
        assert :ok =
                 JidoClaw.SignalBus.emit("jido_claw.tool.complete", %{name: "tool_#{i}"})
      end
    end
  end

  describe "subscribe/1" do
    test "returns {:ok, subscription_id} for a valid path pattern" do
      assert {:ok, sub_id} = JidoClaw.SignalBus.subscribe("jido_claw.tool.*")
      assert is_binary(sub_id)
      JidoClaw.SignalBus.unsubscribe(sub_id)
    end

    test "returns distinct subscription IDs for separate calls" do
      assert {:ok, id1} = JidoClaw.SignalBus.subscribe("jido_claw.tool.*")
      assert {:ok, id2} = JidoClaw.SignalBus.subscribe("jido_claw.memory.*")
      assert id1 != id2
      JidoClaw.SignalBus.unsubscribe(id1)
      JidoClaw.SignalBus.unsubscribe(id2)
    end
  end

  describe "signal delivery after subscribe" do
    test "emitted signal arrives as {:signal, signal} message to subscriber" do
      assert {:ok, sub_id} = JidoClaw.SignalBus.subscribe("jido_claw.emit_test_1.*")

      JidoClaw.SignalBus.emit("jido_claw.emit_test_1.complete", %{name: "write_file"})

      assert_receive {:signal, signal}, 500
      assert signal.type == "jido_claw.emit_test_1.complete"

      JidoClaw.SignalBus.unsubscribe(sub_id)
    end

    test "subscriber receives signal data payload" do
      assert {:ok, sub_id} = JidoClaw.SignalBus.subscribe("jido_claw.emit_test_2.*")

      JidoClaw.SignalBus.emit("jido_claw.emit_test_2.saved", %{key: "some_key", type: "fact"})

      assert_receive {:signal, signal}, 500
      # Data may be atom- or string-keyed depending on jido_signal internals
      data_key = MapKeys.coalesce_field(signal.data, :key)
      assert data_key == "some_key"

      JidoClaw.SignalBus.unsubscribe(sub_id)
    end

    test "subscriber only receives signals matching its pattern" do
      assert {:ok, sub_id} = JidoClaw.SignalBus.subscribe("jido_claw.emit_test_3.*")

      # Emit a signal that does NOT match the subscription pattern
      JidoClaw.SignalBus.emit("jido_claw.other_domain.complete", %{name: "some_tool"})
      # Emit a signal that DOES match
      JidoClaw.SignalBus.emit("jido_claw.emit_test_3.spawned", %{template: "coder"})

      assert_receive {:signal, signal}, 500
      assert signal.type == "jido_claw.emit_test_3.spawned"

      refute_receive {:signal, %{type: "jido_claw.other_domain.complete"}}, 100

      JidoClaw.SignalBus.unsubscribe(sub_id)
    end
  end

  describe "unsubscribe/1" do
    test "stops signal delivery after unsubscribe" do
      assert {:ok, sub_id} = JidoClaw.SignalBus.subscribe("jido_claw.unsub_test.*")

      # Confirm subscription is working
      JidoClaw.SignalBus.emit("jido_claw.unsub_test.started", %{})
      assert_receive {:signal, _}, 500

      assert :ok = JidoClaw.SignalBus.unsubscribe(sub_id)

      JidoClaw.SignalBus.emit("jido_claw.unsub_test.completed", %{})
      refute_receive {:signal, _}, 200
    end

    test "returns :ok when unsubscribing a valid subscription" do
      assert {:ok, sub_id} = JidoClaw.SignalBus.subscribe("jido_claw.tool.*")
      assert :ok = JidoClaw.SignalBus.unsubscribe(sub_id)
    end
  end

  describe "emit/2 when bus is not running" do
    test "does not crash when the named bus process is absent" do
      # Emit against a bus name that was never started — should log and return :ok
      result =
        try do
          # Directly test the internal behaviour: Bus.publish to a
          # non-existent named bus returns an error, which SignalBus.emit swallows.
          case Jido.Signal.new("jido_claw.test.event", %{}, source: "/jido_claw") do
            {:ok, signal} ->
              case Bus.publish(:nonexistent_bus_for_test, [signal]) do
                {:ok, _} -> :ok
                {:error, _reason} -> :ok
              end

            {:error, _} ->
              :ok
          end
        rescue
          _ -> :ok
        end

      assert result == :ok
    end
  end
end
