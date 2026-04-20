defmodule JidoClaw.Reasoning.PipelineStoreTest do
  # async: false — PipelineStore is a named singleton; parallel tests would
  # race its single instance.
  use ExUnit.Case, async: false

  alias JidoClaw.Reasoning.PipelineStore

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "jido_pipeline_store_test_#{System.unique_integer([:positive])}"
      )

    pipelines_dir = Path.join([tmp_dir, ".jido", "pipelines"])
    File.mkdir_p!(pipelines_dir)

    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    {:ok, tmp_dir: tmp_dir, pipelines_dir: pipelines_dir}
  end

  # The application-supervised PipelineStore runs under the module-name. Tests
  # start their own instance under a different name (by not registering).
  defp start_store(tmp_dir) do
    {:ok, pid} = GenServer.start_link(PipelineStore, project_dir: tmp_dir)

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
    test "parses a well-formed pipeline and returns atom-keyed stages",
         %{tmp_dir: tmp, pipelines_dir: dir} do
      write_yaml(dir, "plan_then_summarize.yaml", """
      name: plan_then_summarize
      description: CoT plan → CoD summary
      stages:
        - strategy: cot
        - strategy: cod
          context_mode: accumulate
          prompt_override: "Summarize the above"
      """)

      pid = start_store(tmp)
      [%PipelineStore{} = entry] = call(pid, :all)
      assert entry.name == "plan_then_summarize"
      assert entry.description == "CoT plan → CoD summary"
      assert length(entry.stages) == 2

      [s1, s2] = entry.stages
      # Normalization actually ran — stages are atom-keyed at load time.
      assert s1.strategy == "cot"
      assert s1.context_mode == "previous"
      assert s1.prompt_override == nil
      assert s2.strategy == "cod"
      assert s2.context_mode == "accumulate"
      assert s2.prompt_override == "Summarize the above"
    end

    test "skips pipelines with missing name", %{tmp_dir: tmp, pipelines_dir: dir} do
      write_yaml(dir, "nameless.yaml", """
      stages:
        - strategy: cot
      """)

      pid = start_store(tmp)
      assert call(pid, :all) == []
    end

    test "skips pipelines with names containing '/'",
         %{tmp_dir: tmp, pipelines_dir: dir} do
      write_yaml(dir, "slashed.yaml", """
      name: foo/bar
      stages:
        - strategy: cot
      """)

      pid = start_store(tmp)
      assert call(pid, :all) == []
    end

    test "skips pipelines with empty stages list",
         %{tmp_dir: tmp, pipelines_dir: dir} do
      write_yaml(dir, "empty_stages.yaml", """
      name: empty
      stages: []
      """)

      pid = start_store(tmp)
      assert call(pid, :all) == []
    end

    test "skips pipelines with missing stages key",
         %{tmp_dir: tmp, pipelines_dir: dir} do
      write_yaml(dir, "no_stages.yaml", """
      name: no_stages
      """)

      pid = start_store(tmp)
      assert call(pid, :all) == []
    end

    test "skips pipelines with a stage that resolves to react",
         %{tmp_dir: tmp, pipelines_dir: dir} do
      write_yaml(dir, "react_stage.yaml", """
      name: react_stage
      stages:
        - strategy: react
      """)

      pid = start_store(tmp)
      assert call(pid, :all) == []
    end

    test "skips pipelines with a selector stage (auto)",
         %{tmp_dir: tmp, pipelines_dir: dir} do
      write_yaml(dir, "auto_stage.yaml", """
      name: auto_stage
      stages:
        - strategy: auto
      """)

      pid = start_store(tmp)
      assert call(pid, :all) == []
    end

    test "skips pipelines with an unknown strategy",
         %{tmp_dir: tmp, pipelines_dir: dir} do
      write_yaml(dir, "unknown_stage.yaml", """
      name: unknown
      stages:
        - strategy: definitely_not_a_strategy
      """)

      pid = start_store(tmp)
      assert call(pid, :all) == []
    end

    test "user-vs-user name collision keeps lexicographically-first",
         %{tmp_dir: tmp, pipelines_dir: dir} do
      write_yaml(dir, "a_first.yaml", """
      name: dupe
      description: first
      stages:
        - strategy: cot
      """)

      write_yaml(dir, "z_second.yaml", """
      name: dupe
      description: second
      stages:
        - strategy: tot
      """)

      pid = start_store(tmp)
      [entry] = call(pid, :all)
      assert entry.description == "first"
      [s1] = entry.stages
      assert s1.strategy == "cot"
    end

    test "tolerates malformed YAML alongside a valid file",
         %{tmp_dir: tmp, pipelines_dir: dir} do
      write_yaml(dir, "bad.yaml", """
      name: [this is not: valid yaml]:
      stages:
        - strategy: cot
      """)

      write_yaml(dir, "good.yaml", """
      name: good
      stages:
        - strategy: cot
      """)

      pid = start_store(tmp)
      [entry] = call(pid, :all)
      assert entry.name == "good"
    end

    test "reload/0 picks up new files", %{tmp_dir: tmp, pipelines_dir: dir} do
      write_yaml(dir, "one.yaml", """
      name: one
      stages:
        - strategy: cot
      """)

      pid = start_store(tmp)
      assert length(call(pid, :all)) == 1

      write_yaml(dir, "two.yaml", """
      name: two
      stages:
        - strategy: tot
      """)

      :ok = GenServer.call(pid, :reload)
      assert length(call(pid, :all)) == 2
    end

    test "get/1 returns :not_found for missing name", %{tmp_dir: tmp} do
      pid = start_store(tmp)
      assert call(pid, {:get, "nope"}) == {:error, :not_found}
    end

    test "get/1 returns the pipeline struct by name",
         %{tmp_dir: tmp, pipelines_dir: dir} do
      write_yaml(dir, "found.yaml", """
      name: found
      stages:
        - strategy: cot
      """)

      pid = start_store(tmp)
      assert {:ok, %PipelineStore{name: "found"}} = call(pid, {:get, "found"})
    end

    test "handles missing pipelines dir gracefully",
         %{tmp_dir: tmp, pipelines_dir: dir} do
      File.rm_rf!(dir)
      pid = start_store(tmp)
      assert call(pid, :all) == []
    end
  end

  describe "max_context_bytes parsing (v0.4.7)" do
    test "parses top-level max_context_bytes",
         %{tmp_dir: tmp, pipelines_dir: dir} do
      write_yaml(dir, "capped.yaml", """
      name: capped
      max_context_bytes: 4096
      stages:
        - strategy: cot
          context_mode: accumulate
      """)

      pid = start_store(tmp)
      [entry] = call(pid, :all)
      assert entry.max_context_bytes == 4096
    end

    test "absent top-level max_context_bytes is nil",
         %{tmp_dir: tmp, pipelines_dir: dir} do
      write_yaml(dir, "uncapped.yaml", """
      name: uncapped
      stages:
        - strategy: cot
      """)

      pid = start_store(tmp)
      [entry] = call(pid, :all)
      assert entry.max_context_bytes == nil
    end

    test "parses per-stage max_context_bytes",
         %{tmp_dir: tmp, pipelines_dir: dir} do
      write_yaml(dir, "stage_cap.yaml", """
      name: stage_cap
      stages:
        - strategy: cot
        - strategy: tot
          context_mode: accumulate
          max_context_bytes: 2048
      """)

      pid = start_store(tmp)
      [entry] = call(pid, :all)
      [s1, s2] = entry.stages
      assert s1.max_context_bytes == nil
      assert s2.max_context_bytes == 2048
    end

    test "skips pipelines with non-positive top-level max_context_bytes",
         %{tmp_dir: tmp, pipelines_dir: dir} do
      write_yaml(dir, "zero.yaml", """
      name: zero
      max_context_bytes: 0
      stages:
        - strategy: cot
      """)

      pid = start_store(tmp)
      assert call(pid, :all) == []
    end

    test "skips pipelines with non-positive per-stage max_context_bytes",
         %{tmp_dir: tmp, pipelines_dir: dir} do
      write_yaml(dir, "negative_stage.yaml", """
      name: neg_stage
      stages:
        - strategy: cot
          max_context_bytes: -1
      """)

      pid = start_store(tmp)
      assert call(pid, :all) == []
    end

    test "skips pipelines with non-integer max_context_bytes",
         %{tmp_dir: tmp, pipelines_dir: dir} do
      write_yaml(dir, "bad_type.yaml", """
      name: bad_type
      max_context_bytes: "4096"
      stages:
        - strategy: cot
      """)

      pid = start_store(tmp)
      assert call(pid, :all) == []
    end
  end
end
