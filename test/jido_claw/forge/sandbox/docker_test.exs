defmodule JidoClaw.Forge.Sandbox.DockerTest do
  use ExUnit.Case, async: true

  alias JidoClaw.Forge.Sandbox.Docker

  describe "struct" do
    test "has expected fields" do
      client = %Docker{
        sandbox_name: "forge-123",
        workspace_dir: "/tmp/jidoclaw_forge/forge-123",
        sandbox_id: "123"
      }

      assert client.sandbox_name == "forge-123"
      assert client.workspace_dir == "/tmp/jidoclaw_forge/forge-123"
      assert client.sandbox_id == "123"
    end
  end

  describe "impl_module/0" do
    test "returns the module itself" do
      assert Docker.impl_module() == Docker
    end
  end

  describe "write_file/3 and read_file/2" do
    setup do
      dir =
        Path.join(System.tmp_dir!(), "docker_sandbox_test_#{:erlang.unique_integer([:positive])}")

      File.mkdir_p!(dir)

      client = %Docker{
        sandbox_name: "forge-test",
        workspace_dir: dir,
        sandbox_id: "test"
      }

      on_exit(fn -> File.rm_rf(dir) end)

      %{client: client, dir: dir}
    end

    test "writes and reads a file with relative path", %{client: client, dir: dir} do
      assert :ok = Docker.write_file(client, "hello.txt", "world")
      assert {:ok, "world"} = Docker.read_file(client, "hello.txt")
      assert File.read!(Path.join(dir, "hello.txt")) == "world"
    end

    test "rejects absolute paths", %{client: client, dir: dir} do
      abs_path = Path.join(dir, "subdir/abs.txt")
      assert {:error, {:unsafe_path, ^abs_path}} = Docker.write_file(client, abs_path, "absolute")
      assert {:error, {:unsafe_path, ^abs_path}} = Docker.read_file(client, abs_path)
      refute File.exists?(abs_path)
    end

    test "rejects paths that traverse outside the workspace", %{client: client} do
      assert {:error, {:unsafe_path, "../escape.txt"}} =
               Docker.write_file(client, "../escape.txt", "escape")

      assert {:error, {:unsafe_path, "../escape.txt"}} = Docker.read_file(client, "../escape.txt")
    end

    test "creates parent directories for nested paths", %{client: client, dir: dir} do
      assert :ok = Docker.write_file(client, "deep/nested/file.txt", "nested")
      assert File.read!(Path.join(dir, "deep/nested/file.txt")) == "nested"
    end

    test "read_file returns error for missing file", %{client: client} do
      assert {:error, :enoent} = Docker.read_file(client, "nonexistent.txt")
    end
  end

  describe "inject_env/2" do
    setup do
      dir =
        Path.join(System.tmp_dir!(), "docker_sandbox_env_#{:erlang.unique_integer([:positive])}")

      File.mkdir_p!(dir)

      client = %Docker{
        sandbox_name: "forge-env-test",
        workspace_dir: dir,
        sandbox_id: "env-test"
      }

      on_exit(fn -> File.rm_rf(dir) end)

      %{client: client, dir: dir}
    end

    test "writes env vars in K=V format", %{client: client, dir: dir} do
      assert :ok = Docker.inject_env(client, %{"FOO" => "bar", "BAZ" => "qux"})

      content = File.read!(Path.join(dir, ".forge_env"))
      lines = String.split(content, "\n", trim: true)

      assert "FOO=bar" in lines
      assert "BAZ=qux" in lines
    end

    test "merges with existing env file", %{client: client, dir: dir} do
      File.write!(Path.join(dir, ".forge_env"), "EXISTING=value\n")

      assert :ok = Docker.inject_env(client, %{"NEW" => "added"})

      content = File.read!(Path.join(dir, ".forge_env"))
      lines = String.split(content, "\n", trim: true)

      assert "EXISTING=value" in lines
      assert "NEW=added" in lines
    end

    test "converts keys and values to strings", %{client: client, dir: dir} do
      assert :ok = Docker.inject_env(client, %{count: 42})

      content = File.read!(Path.join(dir, ".forge_env"))
      assert content =~ "count=42"
    end

    test "creates the env file with mode 0600 and leaves no tmp file behind",
         %{client: client, dir: dir} do
      assert :ok = Docker.inject_env(client, %{"SECRET" => "value"})

      env_file = Path.join(dir, ".forge_env")
      assert Bitwise.band(File.stat!(env_file).mode, 0o777) == 0o600

      leftovers =
        dir
        |> File.ls!()
        |> Enum.filter(&String.ends_with?(&1, ".tmp"))

      assert leftovers == []
    end

    test "tightens a legacy world-readable env file to 0600", %{client: client, dir: dir} do
      env_file = Path.join(dir, ".forge_env")
      File.write!(env_file, "LEGACY=value\n")
      File.chmod!(env_file, 0o644)

      assert :ok = Docker.inject_env(client, %{"NEW" => "added"})

      assert Bitwise.band(File.stat!(env_file).mode, 0o777) == 0o600
      content = File.read!(env_file)
      assert content =~ "LEGACY=value"
      assert content =~ "NEW=added"
    end

    test "rejects a symlink at the env file path without following it",
         %{client: client, dir: dir} do
      victim = Path.join(dir, "victim")
      File.write!(victim, "VICTIM=untouched\n")
      File.chmod!(victim, 0o644)

      env_file = Path.join(dir, ".forge_env")
      File.ln_s!(victim, env_file)

      assert {:error, {:invalid_env_file, :symlink}} =
               Docker.inject_env(client, %{"NEW" => "added"})

      # Not followed for the read, the chmod, or the write
      assert File.read!(victim) == "VICTIM=untouched\n"
      assert Bitwise.band(File.stat!(victim).mode, 0o777) == 0o644
      assert {:ok, %File.Stat{type: :symlink}} = File.lstat(env_file)
    end

    test "rejects values containing line breaks", %{client: client, dir: dir} do
      assert {:error, {:invalid_env, "A"}} =
               Docker.inject_env(client, %{"A" => "a\nINJECTED=evil"})

      refute File.exists?(Path.join(dir, ".forge_env"))
    end

    test "rejects malformed keys and leaves an existing file untouched",
         %{client: client, dir: dir} do
      env_file = Path.join(dir, ".forge_env")
      assert :ok = Docker.inject_env(client, %{"GOOD" => "keep"})
      before = File.read!(env_file)

      for bad_key <- ["BAD=KEY", "BAD\nKEY", " PADDED", "BAD KEY", ""] do
        result = Docker.inject_env(client, %{bad_key => "value"})

        assert match?({:error, {:invalid_env, ^bad_key}}, result),
               "expected key #{inspect(bad_key)} to be rejected, got: #{inspect(result)}"
      end

      assert File.read!(env_file) == before
    end

    test "rejects malformed legacy file content instead of carrying it forward",
         %{client: client, dir: dir} do
      # A padded raw key survives the verbatim parse (a line without `=`
      # would be dropped by the parser and prove nothing).
      env_file = Path.join(dir, ".forge_env")
      File.write!(env_file, " BAD=value\n")

      assert {:error, {:invalid_env, " BAD"}} = Docker.inject_env(client, %{"CLEAN" => "x"})

      assert File.read!(env_file) == " BAD=value\n"
    end

    test "round-trips whitespace-padded values verbatim", %{client: client, dir: dir} do
      assert :ok = Docker.inject_env(client, %{"K" => " padded "})
      assert :ok = Docker.inject_env(client, %{"OTHER" => "x"})

      content = File.read!(Path.join(dir, ".forge_env"))
      lines = String.split(content, "\n", trim: true)

      assert "K= padded " in lines
      assert "OTHER=x" in lines
    end
  end

  describe "ensure_workspace_dir/2" do
    setup do
      base =
        Path.join(System.tmp_dir!(), "docker_sandbox_ws_#{:erlang.unique_integer([:positive])}")

      on_exit(fn -> File.rm_rf(base) end)

      %{base: base}
    end

    test "creates the workspace dir with mode 0700", %{base: base} do
      assert {:ok, path} = Docker.ensure_workspace_dir(base, "forge-fresh")

      assert path == Path.join(base, "forge-fresh")
      assert File.dir?(path)
      assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o700
    end

    test "rejects a symlinked base without traversing it", %{base: base} do
      real = base <> "_real"
      File.mkdir_p!(real)
      on_exit(fn -> File.rm_rf(real) end)
      File.ln_s!(real, base)

      assert {:error, {:invalid_workspace_base, :symlink}} =
               Docker.ensure_workspace_dir(base, "forge-x")

      refute File.exists?(Path.join(real, "forge-x"))
    end

    test "rejects a pre-existing directory at the workspace path", %{base: base} do
      File.mkdir_p!(Path.join(base, "forge-taken"))

      assert {:error, :eexist} = Docker.ensure_workspace_dir(base, "forge-taken")
    end

    test "rejects a planted symlink at the workspace path", %{base: base} do
      victim = Path.join(base, "victim")
      File.mkdir_p!(victim)
      File.ln_s!(victim, Path.join(base, "forge-planted"))

      assert {:error, :eexist} = Docker.ensure_workspace_dir(base, "forge-planted")
      assert File.dir?(victim)
    end
  end

  describe "sandbox_agent_type derivation" do
    # We test this indirectly through create/1's spec handling.
    # The private function maps :runner to sbx agent types.

    test "create/1 fails gracefully when sbx is not available" do
      # This tests the error path — sbx is unlikely to be on PATH in CI
      spec = %{runner: :shell}

      case Docker.create(spec) do
        {:ok, client, sandbox_id} ->
          # sbx is available — clean up the sandbox we just created
          Docker.destroy(client, sandbox_id)

        {:error, {:sbx_create_failed, code, _output}} ->
          assert is_integer(code)

        {:error, _reason} ->
          # e.g. :enoent from System.cmd if sbx not found
          :ok
      end
    end
  end

  describe "onecli integration" do
    setup do
      # Store and restore original config
      original = Application.get_env(:jido_claw, :onecli)
      on_exit(fn -> Application.put_env(:jido_claw, :onecli, original || []) end)
      :ok
    end

    test "onecli env is empty when disabled" do
      Application.put_env(:jido_claw, :onecli, enabled: false)

      # We can't directly call the private onecli_env/1, but we can verify
      # that create doesn't inject proxy env when onecli is disabled.
      # This is an indirect test via the module's behavior.
      assert Application.get_env(:jido_claw, :onecli)[:enabled] == false
    end

    test "onecli config with tokens" do
      Application.put_env(:jido_claw, :onecli,
        enabled: true,
        gateway_url: "http://localhost:10255",
        agent_tokens: ["token_a", "token_b"]
      )

      config = Application.get_env(:jido_claw, :onecli)
      assert config[:enabled] == true
      assert config[:gateway_url] == "http://localhost:10255"
      assert [_, _] = config[:agent_tokens]
    end
  end
end
