defmodule JidoClaw.Forge.RecoveredSpecTest do
  @moduledoc """
  AR-8b-2 F2 (1.4): the recovered-spec normalizer that re-atomizes a
  jsonb-recovered Forge start spec's known fields before it reaches the Harness
  (which reads atom keys + values), fail-closing on an un-normalizable docker
  spec or an invalid mount.
  """
  use ExUnit.Case, async: true

  alias JidoClaw.Forge.RecoveredSpec

  # The shape jsonb hands back: atom keys AND atom values stringified.
  # Same-path mounts (sbx 0.34.0) — normalize is shape-only; a recovered
  # host≠container mismatch raises at the backend create, not here.
  defp recovered_docker_spec do
    %{
      "sandbox" => "docker_sandbox",
      "sandbox_spec" => %{
        "extra_mounts" => [%{"host" => "/p", "container" => "/p", "mode" => "rw"}],
        "workdir" => "/p",
        "network" => "none",
        "isolate_global_config" => true
      },
      "runner" => "shell",
      "tenant_id" => "t",
      "workspace_id" => "w"
    }
  end

  describe "normalize/1 — F2 docker spec round-trip" do
    test "re-atomizes a recovered docker spec back to a usable shape (not :default/empty)" do
      assert {:ok, n} = RecoveredSpec.normalize(recovered_docker_spec())

      # `resolve_client(:docker_sandbox)` → the Docker backend (not the silent
      # `:default`/HostShell fail-open).
      assert n.sandbox == :docker_sandbox
      assert n.runner == :shell

      # The nested F2 markers are restored: mount + no-egress + global-config opt-out.
      assert n.sandbox_spec.network == :none
      assert n.sandbox_spec.isolate_global_config == true
      assert n.sandbox_spec.workdir == "/p"
      # The mount entry keeps its JSON-safe map shape (1.5 converts map→tuple later).
      assert n.sandbox_spec.extra_mounts ==
               [%{"host" => "/p", "container" => "/p", "mode" => "rw"}]
    end

    test "an already-atom-keyed launch spec passes its known fields through" do
      spec = %{
        sandbox: :docker_sandbox,
        sandbox_spec: %{network: :none, isolate_global_config: true},
        runner: :shell
      }

      assert {:ok, n} = RecoveredSpec.normalize(spec)
      assert n.sandbox == :docker_sandbox
      assert n.runner == :shell
      assert n.sandbox_spec.network == :none
      assert n.sandbox_spec.isolate_global_config == true
    end
  end

  describe "normalize/1 — fail closed" do
    test "an un-normalizable sandbox value is rejected (never silently :default)" do
      assert {:error, {:unrecognized_sandbox, _}} =
               RecoveredSpec.normalize(%{"sandbox" => "f2_nonexistent_backend_qwxz"})
    end

    test "an invalid recovered mount-map shape is rejected" do
      spec = %{
        "sandbox" => "docker_sandbox",
        # missing "container"/"mode"
        "sandbox_spec" => %{"extra_mounts" => [%{"host" => "/p"}]}
      }

      assert {:error, {:invalid_mount_spec, _}} = RecoveredSpec.normalize(spec)
    end

    test "a non-map spec is rejected" do
      assert {:error, :invalid_recovered_spec} = RecoveredSpec.normalize("not a map")
    end

    test "an existing non-runner atom string is rejected (validates a real runner module)" do
      # `Enum` is a loaded atom but not a runner — a blind existing-atom fallback would
      # admit it and crash later at runner_module.init/2; the validator fails closed.
      assert {:error, {:unrecognized_runner, _}} =
               RecoveredSpec.normalize(%{"runner" => "Elixir.Enum"})
    end

    test "an unknown (never-created) runner atom string is rejected" do
      assert {:error, {:unrecognized_runner, _}} =
               RecoveredSpec.normalize(%{"runner" => "f2_nonexistent_runner_qwxz"})
    end

    test "an existing non-sandbox atom string is rejected (validates a real sandbox module)" do
      assert {:error, {:unrecognized_sandbox, _}} =
               RecoveredSpec.normalize(%{"sandbox" => "Elixir.Enum"})
    end
  end

  describe "normalize/1 — allow_network (docker write build)" do
    test "a recovered allow_network list round-trips (string key → atom key)" do
      spec = %{
        "sandbox" => "docker_sandbox",
        "sandbox_spec" => %{
          "allow_network" => ["host.docker.internal:4567", "localhost:4567"]
        }
      }

      assert {:ok, n} = RecoveredSpec.normalize(spec)
      assert n.sandbox_spec.allow_network == ["host.docker.internal:4567", "localhost:4567"]
    end

    test "an already-atom-keyed allow_network passes through" do
      spec = %{sandbox: :docker_sandbox, sandbox_spec: %{allow_network: ["localhost:80"]}}

      assert {:ok, n} = RecoveredSpec.normalize(spec)
      assert n.sandbox_spec.allow_network == ["localhost:80"]
    end

    test "an invalid entry shape fails closed (the values become a policy CSV)" do
      for bad <- [["**"], ["a,b"], [""], ["host x"], [123], "not-a-list"] do
        spec = %{"sandbox" => "docker_sandbox", "sandbox_spec" => %{"allow_network" => bad}}

        assert match?({:error, {:invalid_allow_network, _}}, RecoveredSpec.normalize(spec)),
               "expected #{inspect(bad)} to fail closed"
      end
    end
  end

  describe "normalize/1 — persisted module-atom recovery" do
    test "a persisted runner module atom recovers" do
      assert {:ok, n} =
               RecoveredSpec.normalize(%{"runner" => "Elixir.JidoClaw.Forge.Runners.Shell"})

      assert n.runner == JidoClaw.Forge.Runners.Shell
    end

    test "a persisted sandbox backend module atom recovers" do
      assert {:ok, n} =
               RecoveredSpec.normalize(%{"sandbox" => "Elixir.JidoClaw.Forge.Sandbox.Docker"})

      assert n.sandbox == JidoClaw.Forge.Sandbox.Docker
    end
  end

  describe "normalize/1 — generic (non-F2) specs are not over-broadened" do
    test "a generic spec recovers as-is (runner atomized, no forced isolation)" do
      spec = %{"runner" => "claude_code", "runner_config" => %{"model" => "x"}}

      assert {:ok, n} = RecoveredSpec.normalize(spec)
      assert n.runner == :claude_code
      # No sandbox key ⇒ the Harness defaults to `:default` (its own legitimate path).
      refute Map.has_key?(n, :sandbox)
      # Unknown keys are preserved untouched.
      assert n["runner_config"] == %{"model" => "x"}
    end

    test "a generic Docker spec with a network value is NOT forced to :none" do
      spec = %{"sandbox" => "docker_sandbox", "sandbox_spec" => %{"network" => "bridge"}}

      assert {:ok, n} = RecoveredSpec.normalize(spec)
      assert n.sandbox == :docker_sandbox
      # Passed through (the backend only honors `:none`), never coerced.
      assert n.sandbox_spec.network == "bridge"
    end
  end
end
