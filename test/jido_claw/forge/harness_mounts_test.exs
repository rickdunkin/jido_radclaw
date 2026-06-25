defmodule JidoClaw.Forge.HarnessMountsTest do
  @moduledoc """
  AR-8b-2 F2 (1.5): `Harness.build_sandbox_spec/2` normalizes JSON-safe map mounts
  (`%{"host"=>,"container"=>,"mode"=>}` — the PERSISTED, jsonb-safe shape) to the
  `{host, container, mode}` tuples the Docker backend's `add_spec_mounts/2`
  destructures, at this single harness boundary. Total + idempotent; a malformed
  entry raises a descriptive `ArgumentError`.
  """
  use ExUnit.Case, async: true

  alias JidoClaw.Forge.Harness
  alias JidoClaw.Forge.Sandbox.Docker

  # A minimal harness state with no declared resources (the F2 exec session shape).
  defp state, do: %Harness{spec: %{resources: []}}

  defp mounts(args) do
    args
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.filter(fn [flag, _] -> flag == "--mount" end)
    |> Enum.map(fn [_, value] -> value end)
  end

  test "a JSON-safe map mount becomes a {h,c,m} tuple (no-resource-mounts case)" do
    spec =
      Harness.build_sandbox_spec(state(), %{
        extra_mounts: [%{"host" => "/p", "container" => "/proto", "mode" => "rw"}]
      })

    assert spec.extra_mounts == [{"/p", "/proto", "rw"}]
  end

  test "the converted tuple reaches Docker.add_spec_mounts via build_create_args" do
    spec =
      Harness.build_sandbox_spec(state(), %{
        extra_mounts: [%{"host" => "/p", "container" => "/proto", "mode" => "rw"}]
      })

    args = Docker.build_create_args("forge-x", "shell", "/tmp/ws", spec)
    assert "/p:/proto:rw" in mounts(args)
  end

  test "an already-tuple mount passes through unchanged (idempotent; resource-mount regression)" do
    spec = Harness.build_sandbox_spec(state(), %{extra_mounts: [{"/a", "/b", "ro"}]})
    assert spec.extra_mounts == [{"/a", "/b", "ro"}]
  end

  test "a resource-mount tuple with an ATOM mode passes through (file_mount_specs yields :ro)" do
    # `ResourceProvisioner.file_mount_specs/1` produces `{host, container, :ro}`
    # (atom mode), which `add_spec_mounts/2` interpolates — must NOT be rejected.
    spec = Harness.build_sandbox_spec(state(), %{extra_mounts: [{"/a", "/mnt/data", :ro}]})
    assert spec.extra_mounts == [{"/a", "/mnt/data", :ro}]
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
