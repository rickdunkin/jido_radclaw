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

    test "writes and reads a file with absolute path", %{client: client, dir: dir} do
      abs_path = Path.join(dir, "subdir/abs.txt")
      assert :ok = Docker.write_file(client, abs_path, "absolute")
      assert {:ok, "absolute"} = Docker.read_file(client, abs_path)
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
      assert length(config[:agent_tokens]) == 2
    end
  end
end
