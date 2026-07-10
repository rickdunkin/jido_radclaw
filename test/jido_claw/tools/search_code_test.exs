defmodule JidoClaw.Tools.SearchCodeTest do
  use ExUnit.Case, async: false

  alias JidoClaw.Security.Redaction.Env
  alias JidoClaw.Tools.SearchCode
  alias JidoClaw.VFS.Sandbox
  alias JidoClaw.VFS.Workspace

  setup do
    dir = Path.join(System.tmp_dir!(), "jido_search_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, dir: dir}
  end

  defp write(dir, name, content) do
    path = Path.join(dir, name)
    File.write!(path, content)
    path
  end

  defp context(dir), do: %{tool_context: %{project_dir: dir}}

  describe "run/2 basic matching" do
    test "should find pattern and return matching lines with file paths", %{dir: dir} do
      write(dir, "source.ex", "defmodule Foo do\n  def bar, do: :ok\nend\n")

      assert {:ok, result} = SearchCode.run(%{pattern: "defmodule", path: dir}, context(dir))

      assert result.total_matches >= 1
      assert result.matches =~ "defmodule"
      assert result.matches =~ "source.ex"
    end

    test "should include line numbers in match output", %{dir: dir} do
      write(dir, "numbered.ex", "line one\ntarget line\nline three\n")

      assert {:ok, result} = SearchCode.run(%{pattern: "target", path: dir}, context(dir))

      assert result.matches =~ ":2:"
    end

    test "should return zero matches when pattern is not found in any file", %{dir: dir} do
      write(dir, "nothing.ex", "alpha beta gamma\n")

      assert {:ok, result} =
               SearchCode.run(%{pattern: "zzz_no_match_zzz", path: dir}, context(dir))

      assert result.total_matches == 0
      assert result.matches == ""
    end

    test "should match across multiple files", %{dir: dir} do
      write(dir, "a.ex", "hello from a\n")
      write(dir, "b.ex", "hello from b\n")

      assert {:ok, result} = SearchCode.run(%{pattern: "hello", path: dir}, context(dir))

      assert result.total_matches == 2
      assert result.matches =~ "a.ex"
      assert result.matches =~ "b.ex"
    end

    test "should support regex pattern", %{dir: dir} do
      # Uses basic regex (grep -rn without -E); [0-9][0-9][0-9] is portable across grep variants
      write(dir, "regex.ex", "foo123\nbar456\nbaz789\n")

      assert {:ok, result} =
               SearchCode.run(%{pattern: "[0-9][0-9][0-9]", path: dir}, context(dir))

      assert result.total_matches == 3
    end
  end

  describe "run/2 glob filter" do
    test "should return only matches from files matching glob filter", %{dir: dir} do
      write(dir, "module.ex", "look here\n")
      write(dir, "notes.md", "look here too\n")

      assert {:ok, result} =
               SearchCode.run(%{pattern: "look", path: dir, glob: "*.ex"}, context(dir))

      assert result.matches =~ "module.ex"
      refute result.matches =~ "notes.md"
    end

    test "should return zero matches when glob excludes all relevant files", %{dir: dir} do
      write(dir, "only.txt", "important content\n")

      assert {:ok, result} =
               SearchCode.run(%{pattern: "important", path: dir, glob: "*.ex"}, context(dir))

      assert result.total_matches == 0
    end

    test "should match files with exs extension when glob is *.exs", %{dir: dir} do
      write(dir, "config.exs", "config :app, key: :value\n")
      write(dir, "app.ex", "config :app, key: :value\n")

      assert {:ok, result} =
               SearchCode.run(
                 %{pattern: "config :app", path: dir, glob: "*.exs"},
                 context(dir)
               )

      assert result.matches =~ "config.exs"
      refute result.matches =~ "app.ex"
    end
  end

  describe "run/2 max_results" do
    test "should truncate results exceeding max_results", %{dir: dir} do
      content = Enum.map_join(1..20, "\n", &"match line #{&1}")
      write(dir, "many_matches.txt", content)

      assert {:ok, result} =
               SearchCode.run(%{pattern: "match line", path: dir, max_results: 5}, context(dir))

      lines =
        result.matches
        |> String.split("\n", trim: true)
        |> Enum.reject(&String.contains?(&1, "truncated"))

      assert Enum.count(lines) == 5
      assert result.matches =~ "more matches truncated"
    end

    test "should not add truncation note when results fit within max_results", %{dir: dir} do
      write(dir, "few.txt", "one match\n")

      assert {:ok, result} =
               SearchCode.run(%{pattern: "one match", path: dir, max_results: 50}, context(dir))

      refute result.matches =~ "truncated"
    end

    test "should report total_matches as full count before truncation", %{dir: dir} do
      content = Enum.map_join(1..10, "\n", &"hit #{&1}")
      write(dir, "hits.txt", content)

      assert {:ok, result} =
               SearchCode.run(%{pattern: "hit", path: dir, max_results: 3}, context(dir))

      assert result.total_matches == 10
    end

    test "clamps caller-requested output retention to the hard maximum", %{dir: dir} do
      content = Enum.map_join(1..1_100, "\n", &"bounded hit #{&1}")
      write(dir, "bounded.txt", content)

      assert {:ok, opts} = Sandbox.resolver_opts(%{project_dir: dir})

      assert {:ok, result} =
               SearchCode.search(
                 %{pattern: "bounded hit", path: dir, max_results: 10_000},
                 opts
               )

      assert result.total_matches == 1_100
      assert result.matches =~ "100 more matches truncated"

      retained =
        result.matches
        |> String.split("\n", trim: true)
        |> Enum.reject(&String.contains?(&1, "more matches truncated"))

      assert Enum.count(retained) == 1_000
    end
  end

  describe "hard traversal budgets" do
    test "rejects oversized regex and glob sources before compilation", %{dir: dir} do
      assert {:ok, opts} = Sandbox.resolver_opts(%{project_dir: dir})

      assert {:error, regex_reason} =
               SearchCode.search(%{pattern: String.duplicate("a", 8 * 1024 + 1), path: dir}, opts)

      assert regex_reason =~ "regular expression bytes"

      assert {:error, glob_reason} =
               SearchCode.search(
                 %{pattern: "x", path: dir, glob: String.duplicate("a", 4 * 1024 + 1)},
                 opts
               )

      assert glob_reason =~ "glob bytes"
    end

    test "checks the absolute deadline before compiling even an invalid expression", %{dir: dir} do
      assert {:ok, opts} = Sandbox.resolver_opts(%{project_dir: dir})
      expired = System.monotonic_time(:millisecond) - 1

      assert {:error, "search limit exceeded: deadline"} =
               SearchCode.search(
                 %{pattern: "(", path: dir},
                 Keyword.put(opts, :search_deadline_ms, expired)
               )
    end

    test "uses a configurable local timeout while preserving a tighter Jido deadline" do
      previous = Application.get_env(:jido_claw, :search_code)

      on_exit(fn ->
        if previous == nil,
          do: Application.delete_env(:jido_claw, :search_code),
          else: Application.put_env(:jido_claw, :search_code, previous)
      end)

      Application.put_env(:jido_claw, :search_code, timeout_ms: 60_000)

      configured =
        []
        |> SearchCode.with_deadline(%{})
        |> Keyword.fetch!(:search_deadline_ms)

      assert configured > System.monotonic_time(:millisecond) + 50_000

      jido_deadline = System.monotonic_time(:millisecond) + 250

      assert []
             |> SearchCode.with_deadline(%{__jido_deadline_ms__: jido_deadline})
             |> Keyword.fetch!(:search_deadline_ms) == jido_deadline
    end

    test "kills and drains a compiler task that exceeds the absolute deadline", %{dir: dir} do
      assert {:ok, opts} = Sandbox.resolver_opts(%{project_dir: dir})
      test_pid = self()

      compile_hook = fn
        :regex, fun ->
          fun.()

        :glob, _fun ->
          send(test_pid, {:glob_compile_blocked, self()})

          receive do
            :never -> :unreachable
          end
      end

      deadline = System.monotonic_time(:millisecond) + 250

      search =
        Task.async(fn ->
          SearchCode.search(
            %{pattern: "x", path: dir, glob: "*.ex"},
            opts
            |> Keyword.put(:search_deadline_ms, deadline)
            |> Keyword.put(:search_compile_hook, compile_hook)
          )
        end)

      assert_receive {:glob_compile_blocked, compiler_pid}, 500
      compiler_ref = Process.monitor(compiler_pid)

      assert {:error, "search limit exceeded: deadline"} = Task.await(search, 1_000)
      assert_receive {:DOWN, ^compiler_ref, :process, ^compiler_pid, _reason}, 500
    end

    test "skips an oversized file and preserves matches from searchable files", %{dir: dir} do
      write(dir, "a_match.txt", "x from a searchable file\n")
      write(dir, "huge.txt", String.duplicate("x", 5 * 1024 * 1024 + 1))

      assert {:ok, result} =
               SearchCode.run(%{pattern: "x", path: dir}, context(dir))

      assert result.total_matches == 1
      assert result.matches =~ "a_match.txt"
      assert result.matches =~ "partial search: skipped 1 oversized file"
      assert result.matches =~ "5242880-byte per-file cap"
    end

    test "returns examined matches with an explicit incomplete note at the deadline", %{dir: dir} do
      write(dir, "a_first.txt", "deadline target one\n")
      write(dir, "b_second.txt", "deadline target two\n")
      assert {:ok, opts} = Sandbox.resolver_opts(%{project_dir: dir})
      owner = self()

      visit_hook = fn path ->
        if Path.basename(path) == "b_second.txt" do
          send(owner, {:second_file_reached, self()})

          receive do
            :continue_after_deadline -> :ok
          end
        end
      end

      deadline = System.monotonic_time(:millisecond) + 250

      search =
        Task.async(fn ->
          SearchCode.search(
            %{pattern: "deadline target", path: dir},
            opts
            |> Keyword.put(:search_deadline_ms, deadline)
            |> Keyword.put(:search_visit_hook, visit_hook)
          )
        end)

      assert_receive {:second_file_reached, search_pid}, 500
      Process.sleep(300)
      send(search_pid, :continue_after_deadline)

      assert {:ok, result} = Task.await(search, 1_000)
      assert result.total_matches == 1
      assert result.matches =~ "a_first.txt"
      refute result.matches =~ "b_second.txt"
      assert result.matches =~ "incomplete search: deadline reached"
      assert result.matches =~ "total_matches counts only examined content"
    end

    test "skips a local FIFO without discarding earlier matches or attempting a read", %{dir: dir} do
      write(dir, "a_match.txt", "anything useful\n")
      fifo = Path.join(dir, "blocking.pipe")

      {_output, 0} =
        System.cmd("mkfifo", [fifo], stderr_to_stdout: true, env: Env.scrubbed_cmd_env())

      assert {:ok, opts} = Sandbox.resolver_opts(%{project_dir: dir})
      deadline = System.monotonic_time(:millisecond) + 500

      search =
        Task.async(fn ->
          SearchCode.search(
            %{pattern: "anything", path: dir},
            Keyword.put(opts, :search_deadline_ms, deadline)
          )
        end)

      assert {:ok, result} = Task.await(search, 1_000)
      assert result.total_matches == 1
      assert result.matches =~ "a_match.txt"
      assert result.matches =~ "partial search: skipped 1 non-regular filesystem entry"
      assert result.matches =~ "potentially blocking reads"
    end

    test "fails loudly when a pathological regex exhausts its PCRE work budget", %{dir: dir} do
      write(dir, "redos.txt", String.duplicate("a", 2_000) <> "!\n")
      assert {:ok, opts} = Sandbox.resolver_opts(%{project_dir: dir})

      assert {:error, reason} =
               SearchCode.search(%{pattern: "(a+)+$", path: dir}, opts)

      assert reason =~ "regular expression match_limit"
    end

    test "honors an already-expired absolute search deadline", %{dir: dir} do
      write(dir, "deadline.txt", "match\n")
      assert {:ok, opts} = Sandbox.resolver_opts(%{project_dir: dir})
      expired = System.monotonic_time(:millisecond) - 1

      assert {:error, "search limit exceeded: deadline"} =
               SearchCode.search(
                 %{pattern: "match", path: dir},
                 Keyword.put(opts, :search_deadline_ms, expired)
               )
    end
  end

  describe "AR-8b sketch jail fails closed (review P2)" do
    test "a sandbox context with no project_dir refuses to search the real tree" do
      assert {:error, _} =
               SearchCode.run(
                 %{pattern: "defmodule JidoClaw"},
                 %{tool_context: %{sandbox: :prototype}}
               )
    end

    test "a sandbox context with a non-.prototypes project_dir is rejected", %{dir: dir} do
      write(dir, "f.ex", "defmodule Foo do\nend\n")

      assert {:error, _} =
               SearchCode.run(
                 %{pattern: "defmodule", path: dir},
                 %{tool_context: %{project_dir: dir, sandbox: :prototype}}
               )
    end

    test "a valid .prototypes sandbox root still searches jailed", %{dir: dir} do
      {:ok, %{dir: proto}} = Sandbox.create_prototype_dir(dir)
      write(proto, "src.ex", "defmodule Sketch do\nend\n")

      assert {:ok, result} =
               SearchCode.run(
                 %{pattern: "defmodule", path: proto},
                 %{tool_context: %{project_dir: proto, sandbox: :prototype}}
               )

      assert result.total_matches >= 1
      assert result.matches =~ "src.ex"
    end
  end

  describe "run/2 path routing" do
    test "rejects absolute paths outside the project directory", %{dir: dir} do
      outside =
        Path.join(System.tmp_dir!(), "jido_search_outside_#{System.unique_integer([:positive])}")

      File.mkdir_p!(outside)
      write(outside, "secret.txt", "outside secret\n")

      on_exit(fn -> File.rm_rf!(outside) end)

      assert {:error, %{message: message}} =
               SearchCode.run(%{pattern: "outside secret", path: outside}, context(dir))

      assert message =~ "Cannot search"
      assert message =~ "path_outside_project"
    end

    test "searches a mounted /project path through the VFS resolver", %{dir: dir} do
      workspace_id = "search-code-vfs-#{System.unique_integer([:positive])}"
      write(dir, "mounted.ex", "defmodule Mounted do\nend\n")

      {:ok, _} = Workspace.ensure_started(workspace_id, dir)

      on_exit(fn -> Workspace.teardown(workspace_id) end)

      assert {:ok, result} =
               SearchCode.run(
                 %{pattern: "defmodule", path: "/project"},
                 %{tool_context: %{workspace_id: workspace_id, project_dir: dir}}
               )

      assert result.total_matches == 1
      assert result.matches =~ "/project/mounted.ex:1:defmodule Mounted do"
    end
  end
end
