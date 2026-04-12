defmodule JidoClaw.Forge.HarnessResourcesTest do
  @moduledoc """
  Tests for the resource validation and provisioning integration.
  """
  use ExUnit.Case, async: true

  alias JidoClaw.Forge.ResourceProvisioner

  describe "file_mount_specs/1" do
    test "extracts file_mount entries as mount tuples for Docker" do
      resources = [
        %{type: :file_mount, source: "/data/models", mount_path: "/workspace/models", mode: :ro},
        %{type: :file_mount, source: "/config", mount_path: "/etc/app"},
        %{type: :env_vars, values: %{"KEY" => "val"}}
      ]

      mounts = ResourceProvisioner.file_mount_specs(resources)

      assert length(mounts) == 2
      assert {"/data/models", "/workspace/models", :ro} in mounts
      assert {"/config", "/etc/app", :ro} in mounts
    end
  end

  describe "validate_resources/1" do
    test "accepts non-secret env_vars" do
      resources = [
        %{type: :env_vars, values: %{"NODE_ENV" => "production", "PORT" => "3000"}}
      ]

      assert :ok = ResourceProvisioner.validate_resources(resources)
    end

    test "accepts secrets with env_map" do
      resources = [
        %{type: :secrets, env_map: %{"DATABASE_URL" => "database_url", "API_KEY" => "openai_key"}}
      ]

      assert :ok = ResourceProvisioner.validate_resources(resources)
    end

    test "accepts secrets with vault_keys and env_prefix" do
      resources = [
        %{type: :secrets, vault_keys: ["api_key"], env_prefix: "SECRET_"}
      ]

      assert :ok = ResourceProvisioner.validate_resources(resources)
    end

    test "accepts git_repo and file_mount" do
      resources = [
        %{type: :git_repo, source: "https://github.com/org/repo", mount_path: "/ws"},
        %{type: :file_mount, source: "/host", mount_path: "/container"}
      ]

      assert :ok = ResourceProvisioner.validate_resources(resources)
    end

    test "accepts empty list" do
      assert :ok = ResourceProvisioner.validate_resources([])
    end

    test "rejects env_vars with sensitive key names" do
      resources = [
        %{
          type: :env_vars,
          values: %{
            "DB_PASSWORD" => "hunter2",
            "NODE_ENV" => "production"
          }
        }
      ]

      assert {:error, reasons} = ResourceProvisioner.validate_resources(resources)
      assert length(reasons) == 1
      assert hd(reasons) =~ "DB_PASSWORD"
      assert hd(reasons) =~ ":secrets"
    end

    test "rejects multiple sensitive keys with individual errors" do
      resources = [
        %{
          type: :env_vars,
          values: %{
            "SECRET_KEY_BASE" => "abc",
            "AUTH_TOKEN" => "xyz",
            "PORT" => "3000"
          }
        }
      ]

      assert {:error, reasons} = ResourceProvisioner.validate_resources(resources)
      assert length(reasons) == 2
      key_names = Enum.join(reasons, " ")
      assert key_names =~ "SECRET_KEY_BASE"
      assert key_names =~ "AUTH_TOKEN"
    end

    test "rejects env_vars with token-shaped values" do
      api_key = "sk-" <> String.duplicate("a", 30)

      resources = [
        %{type: :env_vars, values: %{"OPENAI_URL" => api_key}}
      ]

      assert {:error, reasons} = ResourceProvisioner.validate_resources(resources)
      assert hd(reasons) =~ "OPENAI_URL"
      assert hd(reasons) =~ "secret"
    end

    test "rejects env_vars with credentialed URLs" do
      resources = [
        %{
          type: :env_vars,
          values: %{
            "REPO_URL" => "postgres://admin:s3cret@db.example.com/mydb"
          }
        }
      ]

      assert {:error, reasons} = ResourceProvisioner.validate_resources(resources)
      assert hd(reasons) =~ "REPO_URL"
      assert hd(reasons) =~ "credentials"
    end

    test "rejects unknown resource types" do
      resources = [%{type: :banana}]

      assert {:error, reasons} = ResourceProvisioner.validate_resources(resources)
      assert hd(reasons) =~ "unknown resource type"
    end

    test "rejects resources missing :type" do
      resources = [%{source: "something"}]

      assert {:error, reasons} = ResourceProvisioner.validate_resources(resources)
      assert hd(reasons) =~ "missing :type"
    end

    test "collects errors across multiple resources" do
      resources = [
        %{type: :env_vars, values: %{"DB_PASSWORD" => "x"}},
        %{type: :banana},
        %{type: :env_vars, values: %{"PORT" => "3000"}}
      ]

      assert {:error, reasons} = ResourceProvisioner.validate_resources(resources)
      assert length(reasons) == 2
    end

    # Shape validation — required fields per type

    test "rejects :env_vars missing :values" do
      assert {:error, reasons} = ResourceProvisioner.validate_resources([%{type: :env_vars}])
      assert hd(reasons) =~ ":values"
    end

    test "rejects :env_vars with non-map :values" do
      assert {:error, reasons} =
               ResourceProvisioner.validate_resources([%{type: :env_vars, values: "not a map"}])

      assert hd(reasons) =~ ":values"
    end

    test "rejects :git_repo missing :source" do
      assert {:error, reasons} = ResourceProvisioner.validate_resources([%{type: :git_repo}])
      assert hd(reasons) =~ ":source"
    end

    test "rejects :file_mount missing :source and :mount_path" do
      assert {:error, reasons} = ResourceProvisioner.validate_resources([%{type: :file_mount}])
      assert length(reasons) == 2
      joined = Enum.join(reasons, " ")
      assert joined =~ ":source"
      assert joined =~ ":mount_path"
    end

    test "rejects :secrets without :env_map or :vault_keys" do
      assert {:error, reasons} = ResourceProvisioner.validate_resources([%{type: :secrets}])
      assert hd(reasons) =~ ":env_map"
      assert hd(reasons) =~ ":vault_keys"
    end

    test "rejects :secrets with empty :env_map and no :vault_keys" do
      assert {:error, _} =
               ResourceProvisioner.validate_resources([%{type: :secrets, env_map: %{}}])
    end

    test "accepts :git_repo with only :source" do
      assert :ok =
               ResourceProvisioner.validate_resources([
                 %{type: :git_repo, source: "https://example.com/repo"}
               ])
    end

    test "accepts :file_mount with :source and :mount_path" do
      assert :ok =
               ResourceProvisioner.validate_resources([
                 %{type: :file_mount, source: "/a", mount_path: "/b"}
               ])
    end
  end
end
