defmodule JidoClaw.Forge.Sandbox.DockerIntegrationTest do
  use ExUnit.Case

  @moduletag :docker_sandbox

  alias JidoClaw.Forge.Sandbox.Docker

  setup_all do
    case System.cmd("sbx", ["version"], stderr_to_stdout: true) do
      {_version, 0} ->
        :ok

      _ ->
        raise ExUnit.DocTest.Error,
              "sbx CLI not available — skipping Docker Sandbox integration tests"
    end
  end

  setup do
    # Each test gets a fresh sandbox
    spec = %{runner: :shell}

    case Docker.create(spec) do
      {:ok, client, sandbox_id} ->
        on_exit(fn -> Docker.destroy(client, sandbox_id) end)
        %{client: client, sandbox_id: sandbox_id}

      {:error, reason} ->
        raise "Failed to create sandbox: #{inspect(reason)}"
    end
  end

  describe "full lifecycle" do
    test "create, exec, and destroy", %{client: client} do
      {output, 0} = Docker.exec(client, "echo hello", [])
      assert String.trim(output) == "hello"
    end

    test "exec returns non-zero exit code on failure", %{client: client} do
      {_output, code} = Docker.exec(client, "exit 42", [])
      assert code == 42
    end

    test "exec runs shell commands", %{client: client} do
      {output, 0} = Docker.exec(client, "echo $((2 + 3))", [])
      assert String.trim(output) == "5"
    end
  end

  describe "file operations" do
    test "write_file and read_file round-trip", %{client: client} do
      content = "integration test content #{System.unique_integer()}"
      assert :ok = Docker.write_file(client, "test.txt", content)
      assert {:ok, ^content} = Docker.read_file(client, "test.txt")
    end

    test "files are visible inside sandbox via exec", %{client: client} do
      Docker.write_file(client, "visible.txt", "from host")
      {output, 0} = Docker.exec(client, "cat #{client.workspace_dir}/visible.txt", [])
      assert String.trim(output) == "from host"
    end
  end

  describe "environment injection" do
    test "inject_env makes vars available in exec", %{client: client} do
      assert :ok = Docker.inject_env(client, %{"TEST_VAR" => "hello_world"})
      {output, 0} = Docker.exec(client, "echo $TEST_VAR", [])
      assert String.trim(output) == "hello_world"
    end

    test "inject_env merges multiple calls", %{client: client} do
      assert :ok = Docker.inject_env(client, %{"VAR_A" => "a"})
      assert :ok = Docker.inject_env(client, %{"VAR_B" => "b"})
      {output, 0} = Docker.exec(client, "echo $VAR_A $VAR_B", [])
      assert String.trim(output) == "a b"
    end
  end

  describe "timeout handling" do
    test "exec with timeout returns 124 on timeout", %{client: client} do
      {output, code} = Docker.exec(client, "sleep 30", timeout: 1_000)
      assert code == 124
      assert output =~ "timeout"
    end
  end

  describe "destroy idempotency" do
    test "destroy on already-destroyed sandbox does not crash", %{
      client: client,
      sandbox_id: sandbox_id
    } do
      assert :ok = Docker.destroy(client, sandbox_id)
      # Second destroy should also return :ok (sandbox already gone)
      assert :ok = Docker.destroy(client, sandbox_id)
    end
  end

  describe "spawn" do
    test "spawn returns a port", %{client: client} do
      assert {:ok, port} = Docker.spawn(client, "echo", ["spawn_test"], [])
      assert is_port(port)

      # Collect output
      receive do
        {^port, {:data, data}} -> assert data =~ "spawn_test"
      after
        5_000 -> flunk("Timed out waiting for port output")
      end

      # Wait for exit
      receive do
        {^port, {:exit_status, 0}} -> :ok
      after
        5_000 -> flunk("Timed out waiting for port exit")
      end
    end
  end
end
