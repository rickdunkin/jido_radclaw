defmodule JidoClaw.Forge.ResourceProvisionerTest do
  use ExUnit.Case, async: true

  alias JidoClaw.Forge.ResourceProvisioner
  alias JidoClaw.Forge.Sandbox.Local

  setup do
    {:ok, client, sandbox_id} = Local.create(%{})
    on_exit(fn -> Local.destroy(client, sandbox_id) end)
    %{client: client, sandbox_id: sandbox_id}
  end

  describe "provision_all/2" do
    test "returns :ok for empty list", %{client: client} do
      assert :ok = ResourceProvisioner.provision_all(client, [])
    end

    test "provisions env_vars resources", %{client: client} do
      resources = [
        %{type: :env_vars, values: %{"MY_VAR" => "hello"}}
      ]

      assert :ok = ResourceProvisioner.provision_all(client, resources)

      {output, 0} = Local.exec(client, "echo $MY_VAR", [])
      assert String.trim(output) == "hello"
    end

    test "provisions multiple resources in order", %{client: client} do
      resources = [
        %{type: :env_vars, values: %{"FIRST" => "1"}},
        %{type: :env_vars, values: %{"SECOND" => "2"}}
      ]

      assert :ok = ResourceProvisioner.provision_all(client, resources)

      {output, 0} = Local.exec(client, "echo $FIRST $SECOND", [])
      assert String.trim(output) == "1 2"
    end

    test "stops on first failure", %{client: client} do
      resources = [
        %{type: :git_repo, source: "https://nonexistent.invalid/repo.git", mount_path: "/tmp/nope"},
        %{type: :env_vars, values: %{"SHOULD_NOT" => "reach"}}
      ]

      assert {:error, %{type: :git_repo}, _reason} =
               ResourceProvisioner.provision_all(client, resources)
    end

    test "skips file_mount resources", %{client: client} do
      resources = [
        %{type: :file_mount, source: "/host/path", mount_path: "/container/path"},
        %{type: :env_vars, values: %{"AFTER_MOUNT" => "yes"}}
      ]

      assert :ok = ResourceProvisioner.provision_all(client, resources)

      {output, 0} = Local.exec(client, "echo $AFTER_MOUNT", [])
      assert String.trim(output) == "yes"
    end
  end

  describe "provision/2 for :env_vars" do
    test "injects env vars", %{client: client} do
      assert :ok = ResourceProvisioner.provision(client, %{type: :env_vars, values: %{"KEY" => "val"}})
    end

    test "returns :ok for empty values", %{client: client} do
      assert :ok = ResourceProvisioner.provision(client, %{type: :env_vars, values: %{}})
    end
  end

  describe "provision/2 for :file_mount" do
    test "skips with :handled_at_create", %{client: client} do
      assert {:skip, :handled_at_create} =
               ResourceProvisioner.provision(client, %{
                 type: :file_mount,
                 source: "/host",
                 mount_path: "/container"
               })
    end
  end

  describe "provision/2 for :secrets with vault_keys" do
    test "returns :ok with empty result when no resolver configured", %{client: client} do
      original = Application.get_env(:jido_claw, :secret_resolver)
      Application.delete_env(:jido_claw, :secret_resolver)
      on_exit(fn ->
        if original, do: Application.put_env(:jido_claw, :secret_resolver, original)
      end)

      assert :ok = ResourceProvisioner.provision(client, %{
               type: :secrets,
               vault_keys: ["api_key"],
               env_prefix: "SECRET_"
             })
    end

    test "resolves and injects secrets via function resolver", %{client: client} do
      resolver = fn keys ->
        {:ok, Map.new(keys, fn k -> {k, "resolved_#{k}"} end)}
      end

      Application.put_env(:jido_claw, :secret_resolver, resolver)
      on_exit(fn -> Application.delete_env(:jido_claw, :secret_resolver) end)

      assert :ok = ResourceProvisioner.provision(client, %{
               type: :secrets,
               vault_keys: ["db_pass"],
               env_prefix: "SECRET_"
             })

      {output, 0} = Local.exec(client, "echo $SECRET_DB_PASS", [])
      assert String.trim(output) == "resolved_db_pass"
    end
  end

  describe "provision/2 for :secrets with env_map" do
    test "maps vault keys to exact env var names", %{client: client} do
      resolver = fn keys ->
        {:ok, Map.new(keys, fn k -> {k, "resolved_#{k}"} end)}
      end

      Application.put_env(:jido_claw, :secret_resolver, resolver)
      on_exit(fn -> Application.delete_env(:jido_claw, :secret_resolver) end)

      assert :ok = ResourceProvisioner.provision(client, %{
               type: :secrets,
               env_map: %{
                 "DATABASE_URL" => "database_url",
                 "OPENAI_API_KEY" => "openai_api_key"
               }
             })

      {output, 0} = Local.exec(client, "echo $DATABASE_URL", [])
      assert String.trim(output) == "resolved_database_url"

      {output, 0} = Local.exec(client, "echo $OPENAI_API_KEY", [])
      assert String.trim(output) == "resolved_openai_api_key"
    end

    test "returns error when resolver fails", %{client: client} do
      resolver = fn _keys -> {:error, :vault_unavailable} end

      Application.put_env(:jido_claw, :secret_resolver, resolver)
      on_exit(fn -> Application.delete_env(:jido_claw, :secret_resolver) end)

      assert {:error, {:secret_resolution_failed, :vault_unavailable}} =
               ResourceProvisioner.provision(client, %{
                 type: :secrets,
                 env_map: %{"KEY" => "vault_key"}
               })
    end
  end

  describe "provision/2 for :git_repo" do
    test "returns error for unreachable repo", %{client: client} do
      assert {:error, {:git_clone_failed, _code, _output}} =
               ResourceProvisioner.provision(client, %{
                 type: :git_repo,
                 source: "https://nonexistent.invalid/repo.git",
                 mount_path: "/tmp/repo"
               })
    end
  end

  describe "provision/2 for unknown type" do
    test "returns error", %{client: client} do
      assert {:error, {:unknown_resource_type, :banana}} =
               ResourceProvisioner.provision(client, %{type: :banana})
    end
  end

  describe "file_mount_specs/1" do
    test "extracts file_mount entries as tuples" do
      resources = [
        %{type: :env_vars, values: %{}},
        %{type: :file_mount, source: "/a", mount_path: "/b", mode: :rw},
        %{type: :git_repo, source: "url", mount_path: "/c"},
        %{type: :file_mount, source: "/d", mount_path: "/e"}
      ]

      assert ResourceProvisioner.file_mount_specs(resources) == [
               {"/a", "/b", :rw},
               {"/d", "/e", :ro}
             ]
    end

    test "returns empty list when no file_mounts" do
      assert ResourceProvisioner.file_mount_specs([]) == []

      assert ResourceProvisioner.file_mount_specs([
               %{type: :env_vars, values: %{}}
             ]) == []
    end
  end
end
