defmodule JidoClaw.Agent.PromptTest do
  use ExUnit.Case, async: false

  alias JidoClaw.Agent.Prompt

  # Jido.Signal.Bus uses its own internal naming, not Process.register/2.
  # Attempt the start and treat :already_started as success.
  defp ensure_signal_bus do
    case Jido.Signal.Bus.start_link(name: JidoClaw.SignalBus) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "jido_prompt_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    ensure_signal_bus()

    # Memory and Skills are managed by the Application supervision tree.
    # Clear Memory's four ETS tables between tests to prevent state leakage.
    for table <-
          ~w[jido_claw_memory_records jido_claw_memory_ns_time jido_claw_memory_ns_class_time jido_claw_memory_ns_tag]a do
      if :ets.whereis(table) != :undefined, do: :ets.delete_all_objects(table)
    end

    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, dir: dir}
  end

  describe "ensure/1" do
    test "creates .jido/system_prompt.md when it does not exist", %{dir: dir} do
      path = Prompt.system_prompt_path(dir)
      refute File.exists?(path)

      assert :ok = Prompt.ensure(dir)

      assert File.exists?(path)
      content = File.read!(path)
      assert content =~ "JIDOCLAW"
      assert content =~ "Tool Catalog"
      assert byte_size(content) > 1000
    end

    test "does not overwrite existing system_prompt.md", %{dir: dir} do
      path = Prompt.system_prompt_path(dir)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "# My Custom Prompt\nYou are a pirate.")

      Prompt.ensure(dir)

      assert File.read!(path) == "# My Custom Prompt\nYou are a pirate."
    end

    test "is idempotent — calling twice does not error", %{dir: dir} do
      assert :ok = Prompt.ensure(dir)
      assert :ok = Prompt.ensure(dir)
    end
  end

  describe "build/1 with system_prompt.md" do
    test "uses the file when it exists", %{dir: dir} do
      Prompt.ensure(dir)

      prompt = Prompt.build(dir)
      # Contains content from the file (identity section)
      assert prompt =~ "JIDOCLAW"
      assert prompt =~ "Tool Catalog"
      # Also contains dynamic sections
      assert prompt =~ "Working directory"
    end

    test "uses custom system_prompt.md content", %{dir: dir} do
      path = Prompt.system_prompt_path(dir)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "# Custom Agent\nYou are a helpful pirate coder.")

      prompt = Prompt.build(dir)
      assert prompt =~ "helpful pirate coder"
      # Dynamic sections still appended
      assert prompt =~ "Working directory"
    end

    test "falls back to default when file does not exist", %{dir: dir} do
      # Don't call ensure — no file exists
      prompt = Prompt.build(dir)
      # Should still get the default prompt content
      assert prompt =~ "JIDOCLAW"
      assert prompt =~ "Tool Catalog"
    end

    test "falls back to default when file is empty", %{dir: dir} do
      path = Prompt.system_prompt_path(dir)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "")

      prompt = Prompt.build(dir)
      assert prompt =~ "JIDOCLAW"
    end

    test "should return a binary string", %{dir: dir} do
      assert is_binary(Prompt.build(dir))
    end

    test "should return a non-empty string", %{dir: dir} do
      prompt = Prompt.build(dir)
      assert String.length(prompt) > 100
    end
  end

  describe "environment info" do
    test "should include the working directory path" do
      dir = System.tmp_dir!()
      prompt = Prompt.build(dir)
      assert prompt =~ dir
    end

    test "should label the working directory" do
      dir = System.tmp_dir!()
      prompt = Prompt.build(dir)
      assert prompt =~ "Working directory"
    end

    test "should detect Elixir/OTP project type when mix.exs is present", %{dir: dir} do
      File.write!(Path.join(dir, "mix.exs"), "defmodule Test.MixProject do\nend\n")

      prompt = Prompt.build(dir)
      assert prompt =~ "Elixir/OTP"
    end

    test "should detect JavaScript project type when package.json is present", %{dir: dir} do
      File.write!(Path.join(dir, "package.json"), ~s({"name": "test"}))

      prompt = Prompt.build(dir)
      assert prompt =~ "JavaScript"
    end

    test "should report Unknown project type for empty directory", %{dir: dir} do
      prompt = Prompt.build(dir)
      assert prompt =~ "Unknown"
    end

    test "should include project type label" do
      dir = System.tmp_dir!()
      prompt = Prompt.build(dir)
      assert prompt =~ "Project type"
    end

    test "should include git branch info" do
      dir = System.tmp_dir!()
      prompt = Prompt.build(dir)
      # Either shows a branch name or "not a git repo"
      assert prompt =~ "Git branch" or prompt =~ "git"
    end
  end

  describe "tool documentation sections" do
    test "should document file operation tools" do
      dir = System.tmp_dir!()
      prompt = Prompt.build(dir)

      assert prompt =~ "read_file"
      assert prompt =~ "write_file"
      assert prompt =~ "edit_file"
      assert prompt =~ "list_directory"
    end

    test "should document search tool" do
      dir = System.tmp_dir!()
      prompt = Prompt.build(dir)
      assert prompt =~ "search_code"
    end

    test "should document shell execution tool" do
      dir = System.tmp_dir!()
      prompt = Prompt.build(dir)
      assert prompt =~ "run_command"
    end

    test "should document git tools" do
      dir = System.tmp_dir!()
      prompt = Prompt.build(dir)

      assert prompt =~ "git_status"
      assert prompt =~ "git_diff"
      assert prompt =~ "git_commit"
    end

    test "should document project metadata tool" do
      dir = System.tmp_dir!()
      prompt = Prompt.build(dir)
      assert prompt =~ "project_info"
    end

    test "should document memory tools" do
      dir = System.tmp_dir!()
      prompt = Prompt.build(dir)

      assert prompt =~ "remember"
      assert prompt =~ "recall"
    end

    test "should document swarm/multi-agent tools" do
      dir = System.tmp_dir!()
      prompt = Prompt.build(dir)

      assert prompt =~ "spawn_agent"
      assert prompt =~ "list_agents"
      assert prompt =~ "get_agent_result"
      assert prompt =~ "kill_agent"
    end

    test "should document run_skill tool" do
      dir = System.tmp_dir!()
      prompt = Prompt.build(dir)
      assert prompt =~ "run_skill"
    end
  end

  describe "available templates" do
    test "should mention all 7 agent templates" do
      dir = System.tmp_dir!()
      prompt = Prompt.build(dir)

      assert prompt =~ "coder"
      assert prompt =~ "test_runner"
      assert prompt =~ "reviewer"
      assert prompt =~ "docs_writer"
      assert prompt =~ "researcher"
      assert prompt =~ "refactorer"
      assert prompt =~ "verifier"
    end
  end

  describe "JIDO.md integration" do
    test "should include JIDO.md content when the file exists", %{dir: dir} do
      jido_dir = Path.join(dir, ".jido")
      File.mkdir_p!(jido_dir)

      File.write!(
        Path.join(jido_dir, "JIDO.md"),
        "# Custom Instructions\nAlways write tests first."
      )

      prompt = Prompt.build(dir)

      assert prompt =~ "Custom Instructions"
      assert prompt =~ "Always write tests first"
    end

    test "should not crash when JIDO.md is absent", %{dir: dir} do
      # No .jido/JIDO.md file created — should build without error
      assert is_binary(Prompt.build(dir))
    end

    test "should include project instructions section heading when JIDO.md exists", %{dir: dir} do
      jido_dir = Path.join(dir, ".jido")
      File.mkdir_p!(jido_dir)
      File.write!(Path.join(jido_dir, "JIDO.md"), "some instructions")

      prompt = Prompt.build(dir)
      assert prompt =~ "Project Instructions"
    end
  end

  describe "persistent memory integration" do
    test "should include memory section when memories exist", %{dir: dir} do
      JidoClaw.Memory.remember("test_convention", "prefer GenServer over Agent", "decision")

      prompt = Prompt.build(dir)

      assert prompt =~ "test_convention"
      assert prompt =~ "prefer GenServer over Agent"
    end

    test "should not include memory section when no memories exist", %{dir: dir} do
      prompt = Prompt.build(dir)
      # No memories stored — memory section heading should be absent
      refute prompt =~ "Known Context"
    end
  end
end
