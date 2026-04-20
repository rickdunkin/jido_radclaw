defmodule JidoClaw.Reasoning.StrategyStoreTest do
  # async: false — StrategyStore is a named GenServer; parallel tests would
  # race its single instance.
  use ExUnit.Case, async: false

  alias JidoClaw.Reasoning.StrategyStore

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "jido_strategy_store_test_#{System.unique_integer([:positive])}"
      )

    strategies_dir = Path.join([tmp_dir, ".jido", "strategies"])
    File.mkdir_p!(strategies_dir)

    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    {:ok, tmp_dir: tmp_dir, strategies_dir: strategies_dir}
  end

  # The application-supervised StrategyStore is registered under
  # JidoClaw.Reasoning.StrategyStore. Tests start their own instance under a
  # different name by hand-rolling GenServer.start_link/3.
  defp start_store(tmp_dir) do
    {:ok, pid} =
      GenServer.start_link(StrategyStore, project_dir: tmp_dir)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    pid
  end

  defp call(pid, msg), do: GenServer.call(pid, msg)

  defp write_yaml(dir, filename, content) do
    File.write!(Path.join(dir, filename), content)
  end

  describe "loading" do
    test "parses a well-formed YAML alias", %{tmp_dir: tmp, strategies_dir: dir} do
      write_yaml(dir, "deep_debug.yaml", """
      name: deep_debug
      base: react
      display_name: "Deep Debug"
      description: "Aggressive debugging"
      prefers:
        task_types: [debugging]
        complexity: [complex, highly_complex]
      """)

      pid = start_store(tmp)

      assert [%StrategyStore{} = entry] = call(pid, :all)
      assert entry.name == "deep_debug"
      assert entry.base == "react"
      assert entry.display_name == "Deep Debug"
      assert entry.description == "Aggressive debugging"
      assert entry.prefers.task_types == [:debugging]
      assert entry.prefers.complexity == [:complex, :highly_complex]
    end

    test "skips entries with unknown base", %{tmp_dir: tmp, strategies_dir: dir} do
      write_yaml(dir, "bogus.yaml", """
      name: bogus
      base: not_a_real_strategy
      """)

      pid = start_store(tmp)
      assert call(pid, :all) == []
    end

    test "skips entries whose name collides with a built-in",
         %{tmp_dir: tmp, strategies_dir: dir} do
      write_yaml(dir, "shadow_cot.yaml", """
      name: cot
      base: tot
      """)

      pid = start_store(tmp)
      assert call(pid, :all) == []
    end

    test "rejects missing name", %{tmp_dir: tmp, strategies_dir: dir} do
      write_yaml(dir, "nameless.yaml", """
      base: cot
      """)

      pid = start_store(tmp)
      assert call(pid, :all) == []
    end

    test "rejects names containing '/'", %{tmp_dir: tmp, strategies_dir: dir} do
      write_yaml(dir, "path.yaml", """
      name: foo/bar
      base: cot
      """)

      pid = start_store(tmp)
      assert call(pid, :all) == []
    end

    test "whitelists prefers atoms and silently drops unknowns",
         %{tmp_dir: tmp, strategies_dir: dir} do
      write_yaml(dir, "mixed.yaml", """
      name: mixed
      base: cot
      prefers:
        task_types: [debugging, unknown_bucket]
        complexity: [simple, not_a_real_complexity]
      """)

      pid = start_store(tmp)
      [entry] = call(pid, :all)
      assert entry.prefers.task_types == [:debugging]
      assert entry.prefers.complexity == [:simple]
    end

    test "user-vs-user collision keeps lexicographically-first",
         %{tmp_dir: tmp, strategies_dir: dir} do
      write_yaml(dir, "a_first.yaml", """
      name: fast_reviewer
      base: cot
      description: "first"
      """)

      write_yaml(dir, "z_second.yaml", """
      name: fast_reviewer
      base: tot
      description: "second"
      """)

      pid = start_store(tmp)
      [entry] = call(pid, :all)
      assert entry.description == "first"
      assert entry.base == "cot"
    end

    test "tolerates malformed YAML", %{tmp_dir: tmp, strategies_dir: dir} do
      write_yaml(dir, "bad.yaml", """
      name: [this is not: valid yaml]:
      base: cot
      """)

      write_yaml(dir, "good.yaml", """
      name: good
      base: cot
      """)

      pid = start_store(tmp)
      [entry] = call(pid, :all)
      assert entry.name == "good"
    end

    test "reload/0 picks up new files", %{tmp_dir: tmp, strategies_dir: dir} do
      write_yaml(dir, "one.yaml", """
      name: one
      base: cot
      """)

      pid = start_store(tmp)
      assert length(call(pid, :all)) == 1

      write_yaml(dir, "two.yaml", """
      name: two
      base: tot
      """)

      # Use the same GenServer pid, not the global name
      :ok = GenServer.call(pid, :reload)
      assert length(call(pid, :all)) == 2
    end

    test "get/1 returns :not_found for missing name", %{tmp_dir: tmp} do
      pid = start_store(tmp)
      assert call(pid, {:get, "nope"}) == {:error, :not_found}
    end

    test "handles missing strategies dir gracefully", %{tmp_dir: tmp, strategies_dir: dir} do
      File.rm_rf!(dir)
      pid = start_store(tmp)
      assert call(pid, :all) == []
    end
  end

  describe "prompts whitelist" do
    test "cot accepts a system prompt", %{tmp_dir: tmp, strategies_dir: dir} do
      write_yaml(dir, "mathy.yaml", """
      name: mathy
      base: cot
      prompts:
        system: "You are a rigorous mathematician"
      """)

      pid = start_store(tmp)
      [entry] = call(pid, :all)
      assert entry.prompts == %{system: "You are a rigorous mathematician"}
    end

    test "cod accepts a system prompt", %{tmp_dir: tmp, strategies_dir: dir} do
      write_yaml(dir, "short.yaml", """
      name: short
      base: cod
      prompts:
        system: "Be terse"
      """)

      pid = start_store(tmp)
      [entry] = call(pid, :all)
      assert entry.prompts == %{system: "Be terse"}
    end

    test "tot accepts generation + evaluation prompts",
         %{tmp_dir: tmp, strategies_dir: dir} do
      write_yaml(dir, "explorer.yaml", """
      name: explorer
      base: tot
      prompts:
        generation: "Propose diverse branches"
        evaluation: "Rate each branch for soundness"
      """)

      pid = start_store(tmp)
      [entry] = call(pid, :all)

      assert entry.prompts == %{
               generation: "Propose diverse branches",
               evaluation: "Rate each branch for soundness"
             }
    end

    test "got accepts generation + connection + aggregation prompts",
         %{tmp_dir: tmp, strategies_dir: dir} do
      write_yaml(dir, "grapher.yaml", """
      name: grapher
      base: got
      prompts:
        generation: "Seed nodes"
        connection: "Connect related nodes"
        aggregation: "Synthesize the final answer"
      """)

      pid = start_store(tmp)
      [entry] = call(pid, :all)

      assert entry.prompts == %{
               generation: "Seed nodes",
               connection: "Connect related nodes",
               aggregation: "Synthesize the final answer"
             }
    end

    test "absent prompts: block yields empty map", %{tmp_dir: tmp, strategies_dir: dir} do
      write_yaml(dir, "plain.yaml", """
      name: plain
      base: cot
      """)

      pid = start_store(tmp)
      [entry] = call(pid, :all)
      assert entry.prompts == %{}
    end

    test "tot rejects a system prompt — whole file skipped",
         %{tmp_dir: tmp, strategies_dir: dir} do
      write_yaml(dir, "bad_tot.yaml", """
      name: bad_tot
      base: tot
      prompts:
        system: "Not accepted on tot"
      """)

      pid = start_store(tmp)
      assert call(pid, :all) == []
    end

    test "got rejects an evaluation prompt — whole file skipped",
         %{tmp_dir: tmp, strategies_dir: dir} do
      write_yaml(dir, "bad_got.yaml", """
      name: bad_got
      base: got
      prompts:
        evaluation: "Not accepted on got"
      """)

      pid = start_store(tmp)
      assert call(pid, :all) == []
    end

    for base <- ["trm", "aot", "react", "adaptive"] do
      test "base #{base} rejects any known prompt key", %{tmp_dir: tmp, strategies_dir: dir} do
        write_yaml(dir, "bad_#{unquote(base)}.yaml", """
        name: bad_#{unquote(base)}
        base: #{unquote(base)}
        prompts:
          system: "Not accepted on #{unquote(base)}"
        """)

        pid = start_store(tmp)
        assert call(pid, :all) == []
      end
    end

    test "oversized prompt (>5 KB) — whole file skipped",
         %{tmp_dir: tmp, strategies_dir: dir} do
      oversize = String.duplicate("a", 5_001)

      write_yaml(dir, "oversize.yaml", """
      name: oversize
      base: cot
      prompts:
        system: "#{oversize}"
      """)

      pid = start_store(tmp)
      assert call(pid, :all) == []
    end

    test "unknown sub-key is dropped with a warning; siblings kept",
         %{tmp_dir: tmp, strategies_dir: dir} do
      write_yaml(dir, "typo.yaml", """
      name: typo
      base: cot
      prompts:
        sytem: "typo'd — should be dropped"
        system: "correct entry kept"
      """)

      pid = start_store(tmp)
      [entry] = call(pid, :all)
      assert entry.prompts == %{system: "correct entry kept"}
    end

    test "non-String.Chars prompt key is skipped leniently (does not crash the store)",
         %{tmp_dir: tmp, strategies_dir: dir} do
      # YAML explicit-key syntax (`? KEY : VALUE`) lets the key be a non-scalar
      # term. YamlElixir returns it as a term that does not implement
      # String.Chars, so pre-fix the warning interpolation would raise.
      # This test asserts the store survives and siblings are preserved.
      write_yaml(dir, "weird_key.yaml", """
      name: weird_key
      base: cot
      prompts:
        ? nested: key
        : "some value"
        system: "kept"
      """)

      pid = start_store(tmp)
      [entry] = call(pid, :all)
      assert entry.prompts == %{system: "kept"}
    end

    test "empty-string value is treated as unset (dropped)",
         %{tmp_dir: tmp, strategies_dir: dir} do
      write_yaml(dir, "empty.yaml", """
      name: empty
      base: cot
      prompts:
        system: ""
      """)

      pid = start_store(tmp)
      [entry] = call(pid, :all)
      assert entry.prompts == %{}
    end

    test "non-string value — whole file skipped",
         %{tmp_dir: tmp, strategies_dir: dir} do
      write_yaml(dir, "nonstring.yaml", """
      name: nonstring
      base: cot
      prompts:
        system: 42
      """)

      pid = start_store(tmp)
      assert call(pid, :all) == []
    end

    test "non-map prompts: value — whole file skipped",
         %{tmp_dir: tmp, strategies_dir: dir} do
      write_yaml(dir, "nonmap.yaml", """
      name: nonmap
      base: cot
      prompts: "oops"
      """)

      pid = start_store(tmp)
      assert call(pid, :all) == []
    end
  end
end
