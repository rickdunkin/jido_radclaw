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

  describe "sync/1" do
    test "returns :noop and writes sync stamp on a fresh install", %{dir: dir} do
      assert :ok = Prompt.ensure(dir)
      assert {:ok, :noop} = Prompt.sync(dir)
      assert File.exists?(sync_path(dir))
    end

    test "migrates a pre-0.4 user (no sidecar) sitting on the latest default", %{dir: dir} do
      # Simulate a pre-0.4 install: file present, no sync sidecar.
      body =
        File.read!(
          Path.join([:code.priv_dir(:jido_claw) |> to_string(), "defaults", "system_prompt.md"])
        )

      File.mkdir_p!(Path.join(dir, ".jido"))
      File.write!(Prompt.system_prompt_path(dir), body)

      refute File.exists?(sync_path(dir))
      assert {:ok, :noop} = Prompt.sync(dir)
      assert File.exists?(sync_path(dir))
    end

    test "migrates a pre-0.4 user (no sidecar) with a modified body", %{dir: dir} do
      File.mkdir_p!(Path.join(dir, ".jido"))
      File.write!(Prompt.system_prompt_path(dir), "# My custom prompt\nYou are a pirate.")

      assert {:ok, :sidecar_written} = Prompt.sync(dir)
      assert File.exists?(default_sidecar_path(dir))
      assert File.exists?(sync_path(dir))
    end

    test "overwrites when body was unmodified against an older default", %{dir: dir} do
      old_default = "# Old default\nnothing here"
      old_sha = sha(old_default)
      new_default = "# New default v2\nfresh bytes"
      new_sha = sha(new_default)

      File.mkdir_p!(Path.join(dir, ".jido"))
      File.write!(Prompt.system_prompt_path(dir), old_default)
      write_sync_stamp(dir, old_sha, old_sha)

      assert {:ok, :overwritten} = Prompt.__sync_with__(dir, new_default, new_sha)
      assert File.read!(Prompt.system_prompt_path(dir)) == new_default

      assert %{default_sha: ^new_sha, body_sha: ^new_sha} =
               parse_sync(File.read!(sync_path(dir)))
    end

    test "re-stamps body sha when user edits and bundled hasn't moved", %{dir: dir} do
      default_body = "# Default\nline one"
      default_sha = sha(default_body)
      edited = "# Default\nline one\n# user added"
      edited_sha = sha(edited)

      File.mkdir_p!(Path.join(dir, ".jido"))
      File.write!(Prompt.system_prompt_path(dir), edited)
      write_sync_stamp(dir, default_sha, default_sha)

      assert {:ok, :stamp_only} = Prompt.__sync_with__(dir, default_body, default_sha)

      assert %{default_sha: ^default_sha, body_sha: ^edited_sha} =
               parse_sync(File.read!(sync_path(dir)))
    end

    test "writes .default sidecar when user edits and bundled moved", %{dir: dir} do
      old_default = "# Old default\nA"
      old_sha = sha(old_default)
      edited_body = "# Customized\nhi pirate"
      edited_sha = sha(edited_body)
      new_default = "# New default v2\nfresh"
      new_sha = sha(new_default)

      File.mkdir_p!(Path.join(dir, ".jido"))
      File.write!(Prompt.system_prompt_path(dir), edited_body)
      write_sync_stamp(dir, old_sha, edited_sha)

      assert {:ok, :sidecar_written} = Prompt.__sync_with__(dir, new_default, new_sha)
      assert File.read!(default_sidecar_path(dir)) == new_default
      # original body untouched
      assert File.read!(Prompt.system_prompt_path(dir)) == edited_body
    end

    test "noops when sidecar already offered for same upgrade", %{dir: dir} do
      old_default = "# Old\nbody"
      old_sha = sha(old_default)
      edited_body = "# custom\nedits"
      edited_sha = sha(edited_body)
      new_default = "# New\nlatest"
      new_sha = sha(new_default)

      File.mkdir_p!(Path.join(dir, ".jido"))
      File.write!(Prompt.system_prompt_path(dir), edited_body)
      write_sync_stamp(dir, old_sha, edited_sha)
      File.write!(default_sidecar_path(dir), new_default)

      assert {:ok, :noop} = Prompt.__sync_with__(dir, new_default, new_sha)
    end

    test "malformed sync file is treated as missing", %{dir: dir} do
      File.mkdir_p!(Path.join(dir, ".jido"))
      File.write!(Prompt.system_prompt_path(dir), "body bytes")
      File.write!(sync_path(dir), "garbage: value\nno valid fields")

      assert {:ok, :sidecar_written} = Prompt.sync(dir)
      assert File.exists?(default_sidecar_path(dir))
    end

    test "sync file roundtrips through parse + write", %{dir: dir} do
      File.mkdir_p!(Path.join(dir, ".jido"))
      File.write!(Prompt.system_prompt_path(dir), "body")
      assert {:ok, _} = Prompt.sync(dir)

      parsed = parse_sync(File.read!(sync_path(dir)))
      assert is_binary(parsed.default_sha)
      assert is_binary(parsed.body_sha)
    end

    test "returns :noop when system_prompt.md does not exist", %{dir: dir} do
      assert {:ok, :noop} = Prompt.sync(dir)
    end
  end

  describe "current_default_sha/0" do
    test "returns a lowercase hex SHA-256" do
      sha = Prompt.current_default_sha()
      assert is_binary(sha)
      assert String.length(sha) == 64
      assert String.downcase(sha) == sha
    end
  end

  describe "upgrade/1" do
    test "refuses when no sidecar is present", %{dir: dir} do
      File.mkdir_p!(Path.join(dir, ".jido"))
      File.write!(Prompt.system_prompt_path(dir), "body")
      assert {:error, :no_sidecar} = Prompt.upgrade(dir)
    end

    test "promotes sidecar into place and refreshes stamp", %{dir: dir} do
      File.mkdir_p!(Path.join(dir, ".jido"))
      File.write!(Prompt.system_prompt_path(dir), "old body")
      File.write!(default_sidecar_path(dir), "new body")

      assert {:ok, %{backup: backup}} = Prompt.upgrade(dir)
      assert File.read!(Prompt.system_prompt_path(dir)) == "new body"
      assert File.read!(backup) == "old body"
      refute File.exists?(default_sidecar_path(dir))

      parsed = parse_sync(File.read!(sync_path(dir)))
      assert parsed.default_sha == parsed.body_sha
    end
  end

  defp sync_path(dir), do: Path.join([dir, ".jido", ".system_prompt.sync"])
  defp default_sidecar_path(dir), do: Path.join([dir, ".jido", "system_prompt.md.default"])

  defp write_sync_stamp(dir, default_sha, body_sha) do
    File.write!(
      sync_path(dir),
      "# Managed by JidoClaw. Do not edit.\ndefault_sha: #{default_sha}\nbody_sha: #{body_sha}\n"
    )
  end

  defp sha(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

  defp parse_sync(content) do
    content
    |> String.split("\n")
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(String.trim(line), ":", parts: 2) do
        [k, v] ->
          k = String.trim(k)
          v = String.trim(v)

          cond do
            String.starts_with?(k, "#") -> acc
            k == "default_sha" and v != "" -> Map.put(acc, :default_sha, v)
            k == "body_sha" and v != "" -> Map.put(acc, :body_sha, v)
            true -> acc
          end

        _ ->
          acc
      end
    end)
  end
end
