defmodule JidoClaw.Forge.HarnessMountsTest do
  @moduledoc """
  AR-8b-2 F2 (1.5): `Harness.build_sandbox_spec/2` normalizes JSON-safe map mounts
  (`%{"host"=>,"container"=>,"mode"=>}` — the PERSISTED, jsonb-safe shape) to the
  `{host, container, mode}` tuples the Docker backend destructures, at this single
  harness boundary. Total + idempotent; a malformed entry raises a descriptive
  `ArgumentError`. Shape-only: the same-path requirement (sbx 0.34.0 workspace
  positionals) is the BACKEND's validation, not this normalizer's.
  """
  use ExUnit.Case, async: true

  alias JidoClaw.Forge.Harness
  alias JidoClaw.Forge.Sandbox.Docker

  # A minimal harness state with no declared resources (the F2 exec session shape).
  defp state, do: %Harness{spec: %{resources: []}}

  # The mount POSITIONALS — everything after `create --name NAME AGENT WORKSPACE`
  # (sbx 0.34.0: same-path workspace paths, `:ro` suffix, no `--mount` flag).
  defp mounts(["create", "--name", _name, _agent, _workspace | mount_positionals]),
    do: mount_positionals

  test "a JSON-safe map mount becomes a {h,c,m} tuple (no-resource-mounts case)" do
    spec =
      Harness.build_sandbox_spec(state(), %{
        extra_mounts: [%{"host" => "/p", "container" => "/p", "mode" => "rw"}]
      })

    assert spec.extra_mounts == [{"/p", "/p", "rw"}]
  end

  test "the converted tuple reaches the Docker workspace positionals via build_create_args" do
    spec =
      Harness.build_sandbox_spec(state(), %{
        isolate_global_config: true,
        extra_mounts: [%{"host" => "/p", "container" => "/p", "mode" => "rw"}]
      })

    args = Docker.build_create_args("forge-x", "shell", "/tmp/ws", spec)
    assert mounts(args) == ["/p"]
  end

  test "an already-tuple mount passes through unchanged (idempotent; resource-mount regression)" do
    spec = Harness.build_sandbox_spec(state(), %{extra_mounts: [{"/a", "/a", "ro"}]})
    assert spec.extra_mounts == [{"/a", "/a", "ro"}]
  end

  test "a resource-mount tuple with an ATOM mode passes through (file_mount_specs yields :ro)" do
    # `ResourceProvisioner.file_mount_specs/1` produces `{host, container, :ro}`
    # (atom mode), which the backend's mount positional accepts — must NOT be rejected.
    spec = Harness.build_sandbox_spec(state(), %{extra_mounts: [{"/mnt/data", "/mnt/data", :ro}]})
    assert spec.extra_mounts == [{"/mnt/data", "/mnt/data", :ro}]
  end

  test "a spec with no :extra_mounts passes through untouched" do
    spec = Harness.build_sandbox_spec(state(), %{network: :none})
    refute Map.has_key?(spec, :extra_mounts)
  end

  test "a malformed map mount raises a descriptive ArgumentError (not a FunctionClauseError)" do
    assert_raise ArgumentError, ~r/invalid mount spec entry/, fn ->
      Harness.build_sandbox_spec(state(), %{extra_mounts: [%{"host" => "/p"}]})
    end
  end
end
