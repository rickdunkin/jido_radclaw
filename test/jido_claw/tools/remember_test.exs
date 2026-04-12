defmodule JidoClaw.Tools.RememberTest do
  use ExUnit.Case, async: false

  alias JidoClaw.Tools.Remember

  # Jido.Signal.Bus uses its own internal naming, not Process.register/2.
  # Attempt the start and treat :already_started as success.
  defp ensure_signal_bus do
    case Jido.Signal.Bus.start_link(name: JidoClaw.SignalBus) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "jido_remember_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    ensure_signal_bus()

    # Clear the four ETS tables used by Jido.Memory.Store.ETS (base: :jido_claw_memory).
    # Memory is owned by the Application supervision tree — clear tables directly
    # rather than stopping/restarting the GenServer.
    for table <-
          ~w[jido_claw_memory_records jido_claw_memory_ns_time jido_claw_memory_ns_class_time jido_claw_memory_ns_tag]a do
      if :ets.whereis(table) != :undefined, do: :ets.delete_all_objects(table)
    end

    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, dir: dir}
  end

  describe "run/2 success" do
    test "should return {:ok, result} with the stored key" do
      assert {:ok, result} = Remember.run(%{key: "my_key", content: "some content"}, %{})
      assert result.key == "my_key"
    end

    test "should return status 'remembered'" do
      assert {:ok, result} = Remember.run(%{key: "any_key", content: "value"}, %{})
      assert result.status == "remembered"
    end

    test "should default type to 'fact' when not provided" do
      assert {:ok, result} = Remember.run(%{key: "fact_key", content: "a fact"}, %{})
      assert result.type == "fact"
    end

    test "should use custom type when provided" do
      assert {:ok, result} =
               Remember.run(%{key: "arch_key", content: "use GenServer", type: "decision"}, %{})

      assert result.type == "decision"
    end

    test "should accept 'pattern' as type" do
      assert {:ok, result} =
               Remember.run(
                 %{key: "pattern_key", content: "always read before edit", type: "pattern"},
                 %{}
               )

      assert result.type == "pattern"
    end

    test "should accept 'preference' as type" do
      assert {:ok, result} =
               Remember.run(
                 %{key: "pref_key", content: "prefer short functions", type: "preference"},
                 %{}
               )

      assert result.type == "preference"
    end

    test "should persist memory so it can be recalled" do
      Remember.run(%{key: "persisted_key", content: "persisted content"}, %{})

      results = JidoClaw.Memory.recall("persisted_key")
      assert length(results) > 0
      entry = Enum.find(results, &(&1.key == "persisted_key"))
      assert entry != nil
      assert entry.content == "persisted content"
    end

    test "should overwrite existing memory with same key" do
      Remember.run(%{key: "dup_key", content: "original"}, %{})
      Remember.run(%{key: "dup_key", content: "updated"}, %{})

      results = JidoClaw.Memory.recall("dup_key")
      entry = Enum.find(results, &(&1.key == "dup_key"))
      assert entry.content == "updated"
    end
  end
end
