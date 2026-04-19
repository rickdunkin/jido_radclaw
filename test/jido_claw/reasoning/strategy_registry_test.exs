defmodule JidoClaw.Reasoning.StrategyRegistryTest do
  # async: false — StrategyRegistry resolves names against the singleton
  # StrategyStore; parallel tests that add/remove aliases would see each
  # other's state.
  use ExUnit.Case, async: false

  alias JidoClaw.Reasoning.StrategyRegistry

  # Convenience: write a YAML into the live project's .jido/strategies/ and
  # reload the registry. The path is deterministic so we can remove it on
  # exit. Requires StrategyStore to be running (supervised by the app).
  defp with_user_strategy(yaml, fun) do
    project_dir = Application.get_env(:jido_claw, :project_dir, File.cwd!())
    dir = Path.join([project_dir, ".jido", "strategies"])
    File.mkdir_p!(dir)

    path =
      Path.join(
        dir,
        "strategy_registry_test_alias_#{System.unique_integer([:positive])}.yaml"
      )

    File.write!(path, yaml)

    try do
      JidoClaw.Reasoning.StrategyStore.reload()
      fun.()
    after
      File.rm(path)
      JidoClaw.Reasoning.StrategyStore.reload()
    end
  end

  describe "built-in resolution" do
    test "plugin_for/1 returns the built-in module" do
      assert {:ok, Jido.AI.Reasoning.ChainOfThought} = StrategyRegistry.plugin_for("cot")
      assert {:ok, Jido.AI.Reasoning.ReAct} = StrategyRegistry.plugin_for("react")
    end

    test "atom_for/1 returns the built-in atom" do
      assert {:ok, :cot} = StrategyRegistry.atom_for("cot")
      assert {:ok, :react} = StrategyRegistry.atom_for("react")
    end

    test "prefers_for/1 returns the built-in prefers map" do
      prefers = StrategyRegistry.prefers_for("cot")
      assert :qa in prefers.task_types
    end

    test "valid?/1 recognizes all built-ins" do
      for name <- ~w(react cot cod tot got aot trm adaptive) do
        assert StrategyRegistry.valid?(name), "expected #{name} to be valid"
      end
    end

    test "list/0 includes built-ins with display_name: nil" do
      entries = StrategyRegistry.list()
      assert Enum.any?(entries, fn e -> e.name == "cot" and e.display_name == nil end)
    end

    test "unknown names return :unknown_strategy" do
      assert {:error, :unknown_strategy} =
               StrategyRegistry.plugin_for("definitely_not_a_strategy")

      assert {:error, :unknown_strategy} = StrategyRegistry.atom_for("definitely_not_a_strategy")
      assert StrategyRegistry.prefers_for("definitely_not_a_strategy") == nil
      refute StrategyRegistry.valid?("definitely_not_a_strategy")
    end
  end

  describe "user alias resolution" do
    test "plugin_for/1 resolves alias to base module" do
      with_user_strategy(
        """
        name: fast_reviewer
        base: cot
        description: "CoT tuned for reviews"
        """,
        fn ->
          assert {:ok, Jido.AI.Reasoning.ChainOfThought} =
                   StrategyRegistry.plugin_for("fast_reviewer")
        end
      )
    end

    test "plugin_for/1 returns the react module for a react alias" do
      with_user_strategy(
        """
        name: deep_debug
        base: react
        """,
        fn ->
          assert {:ok, Jido.AI.Reasoning.ReAct} = StrategyRegistry.plugin_for("deep_debug")
        end
      )
    end

    test "atom_for/1 returns the base atom" do
      with_user_strategy(
        """
        name: fast_reviewer
        base: cot
        """,
        fn ->
          assert {:ok, :cot} = StrategyRegistry.atom_for("fast_reviewer")
        end
      )
    end

    test "prefers_for/1 returns the user-supplied map" do
      with_user_strategy(
        """
        name: fast_reviewer
        base: cot
        prefers:
          task_types: [qa, verification]
          complexity: [simple, moderate]
        """,
        fn ->
          prefers = StrategyRegistry.prefers_for("fast_reviewer")
          assert prefers.task_types == [:qa, :verification]
          assert prefers.complexity == [:simple, :moderate]
        end
      )
    end

    test "valid?/1 recognizes a user alias" do
      with_user_strategy(
        """
        name: fast_reviewer
        base: cot
        """,
        fn ->
          assert StrategyRegistry.valid?("fast_reviewer")
        end
      )
    end

    test "list/0 includes user aliases with display_name" do
      with_user_strategy(
        """
        name: fast_reviewer
        base: cot
        display_name: "Fast Reviewer"
        description: "Quick"
        """,
        fn ->
          entries = StrategyRegistry.list()

          alias_entry = Enum.find(entries, &(&1.name == "fast_reviewer"))
          assert alias_entry
          assert alias_entry.display_name == "Fast Reviewer"
          assert alias_entry.description == "Quick"
        end
      )
    end
  end

  describe "graceful degradation when StrategyStore is down" do
    setup do
      pid = Process.whereis(JidoClaw.Reasoning.StrategyStore)

      if pid do
        # Unregister (not stop) so supervisor doesn't restart it on us;
        # we rename and let the test run, then restore.
        Process.unregister(JidoClaw.Reasoning.StrategyStore)
        on_exit(fn -> maybe_re_register(pid) end)
      end

      :ok
    end

    defp maybe_re_register(pid) do
      cond do
        !Process.alive?(pid) ->
          :ok

        Process.whereis(JidoClaw.Reasoning.StrategyStore) ->
          # Supervisor already restarted something under the name — kill the
          # orphaned pid to avoid a process leak.
          Process.exit(pid, :kill)

        true ->
          Process.register(pid, JidoClaw.Reasoning.StrategyStore)
      end
    end

    test "built-ins still resolve when StrategyStore is absent" do
      assert {:ok, Jido.AI.Reasoning.ChainOfThought} = StrategyRegistry.plugin_for("cot")
      assert StrategyRegistry.valid?("cot")
      assert is_map(StrategyRegistry.prefers_for("cot"))
      assert Enum.any?(StrategyRegistry.list(), fn e -> e.name == "cot" end)
    end
  end
end
