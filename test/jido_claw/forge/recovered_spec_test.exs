defmodule JidoClaw.Forge.RecoveredSpecTest do
  @moduledoc """
  AR-8b-2 F2 (1.4): the recovered-spec normalizer that re-atomizes a
  jsonb-recovered Forge start spec's known fields before it reaches the Harness
  (which reads atom keys + values), fail-closing on an un-normalizable docker
  spec or an invalid mount.
  """
  use ExUnit.Case, async: true

  alias JidoClaw.Forge.RecoveredSpec
  alias JidoClaw.Forge.Runners.ClaudeCode
  alias JidoClaw.Forge.Runners.Codex

  # jsonb round-trip simulation: atom keys and atom values stringify exactly
  # as AshPostgres :map persistence does.
  defp jsonb_round_trip(map), do: Jason.decode!(Jason.encode!(map))

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
      # An UNSTAMPED runner_config is the legacy/non-vendor lane and passes
      # through untouched (key form included) — vendor sessions are stamped
      # at session start via materialize_config/1, where materialization is
      # enforced; only a config_codec stamp engages the typed codec below.
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

  # ---------------------------------------------------------------------------
  # Versioned runner-config codec (forge-session-resume): materialize →
  # persist (jsonb) → decode. The codec contract is the seam under test, so
  # the runners' materialize_config/1 implementations produce the inputs.
  # ---------------------------------------------------------------------------

  describe "runner_config/1 — materialize → persist → decode round-trip" do
    test "the consolidator claude shape (access omitted) keeps :full through recovery" do
      # `RunServer.base_runner_config(:claude_code, _)` omits :access,
      # :config_sync, and :allowed_mcp_tools — materialization writes them
      # explicitly, so a recovered session re-inits :full with its MCP reach
      # intact. A defaulting decode (or a dropped string key) would flip it.
      materialized =
        ClaudeCode.materialize_config(%{
          prompt: "consolidate memory",
          model: "claude-opus-4-7",
          max_turns: 60,
          timeout_ms: 600_000,
          thinking_effort: "xhigh"
        })

      assert materialized.access == :full
      assert materialized.config_sync == :full
      assert materialized.strict_mcp == false
      assert materialized.allowed_mcp_tools == []
      assert materialized.resume == :off

      assert {:ok, decoded} =
               RecoveredSpec.runner_config(jsonb_round_trip(materialized))

      assert decoded.access == :full
      assert decoded.config_sync == :full
      assert decoded.strict_mcp == false
      assert decoded.allowed_mcp_tools == []
      assert decoded.model == "claude-opus-4-7"
      assert decoded.max_turns == 60
      assert decoded.timeout_ms == 600_000
      assert decoded.thinking_effort == "xhigh"
      assert decoded.prompt == "consolidate memory"
      assert decoded.resume == :off
    end

    test "a read-only executor claude shape keeps its MCP tools through recovery" do
      materialized =
        ClaudeCode.materialize_config(%{
          access: :read_only,
          allowed_mcp_tools: ["mcp__jido__deposit"],
          strict_mcp: true,
          config_sync: :auth_only,
          add_dirs: ["/repo"]
        })

      assert {:ok, decoded} =
               RecoveredSpec.runner_config(jsonb_round_trip(materialized))

      assert decoded.access == :read_only
      assert decoded.allowed_mcp_tools == ["mcp__jido__deposit"]
      assert decoded.strict_mcp == true
      assert decoded.config_sync == :auth_only
      assert decoded.add_dirs == ["/repo"]
    end

    test "the codex shape round-trips typed" do
      materialized =
        Codex.materialize_config(%{
          prompt: "consolidate",
          model: "gpt-5-codex",
          forge_home: "/tmp/run-1",
          mcp_server_name: "jido_deposit"
        })

      assert materialized.access == :full
      assert materialized.config_sync == :full
      assert materialized.codex_home == "/tmp/run-1/.codex"
      assert materialized.cwd == "/tmp/run-1"

      assert {:ok, decoded} =
               RecoveredSpec.runner_config(jsonb_round_trip(materialized))

      assert decoded.access == :full
      assert decoded.config_sync == :full
      assert decoded.codex_home == "/tmp/run-1/.codex"
      assert decoded.cwd == "/tmp/run-1"
      assert decoded.mcp_server_name == "jido_deposit"
      assert decoded.resume == :off
    end

    test "a double round-trip (recover → re-persist → recover) stays typed and stamped" do
      # The recovery claim re-persists the decoded (typed) config; the NEXT
      # recovery must decode it again — the stamp survives decoding.
      materialized = ClaudeCode.materialize_config(%{model: "m"})

      assert {:ok, once} = RecoveredSpec.runner_config(jsonb_round_trip(materialized))
      assert {:ok, twice} = RecoveredSpec.runner_config(jsonb_round_trip(once))

      assert twice == once
      assert twice.config_codec == %{runner: "claude_code", v: 1}
    end

    test "attempt-scoped values never survive the codec" do
      # Even if a bug persisted them, the whitelist drops capability material:
      # tokenized endpoint URLs and per-attempt config paths ride
      # run_iteration opts only.
      leaked =
        ClaudeCode.materialize_config(%{model: "m"})
        |> jsonb_round_trip()
        |> Map.merge(%{
          "mcp_config_path" => "/tmp/attempt-1.json",
          "mcp_config_json" => "{}",
          "mcp_server_url" => "http://127.0.0.1:4567/t0k3n"
        })

      assert {:ok, decoded} = RecoveredSpec.runner_config(leaked)

      refute Map.has_key?(decoded, :mcp_config_path)
      refute Map.has_key?(decoded, :mcp_config_json)
      refute Map.has_key?(decoded, :mcp_server_url)
      refute Map.has_key?(decoded, "mcp_config_path")
    end

    test "an unstamped runner_config passes through unchanged" do
      config = %{"model" => "x", "access" => "read_only"}

      assert {:ok, ^config} = RecoveredSpec.runner_config(config)
    end
  end

  describe "runner_config/1 — refuse-on-missing/invalid (security-critical fields)" do
    test "a stamped claude config missing a security-critical field refuses recovery" do
      wire = jsonb_round_trip(ClaudeCode.materialize_config(%{}))

      for field <- ["access", "config_sync", "strict_mcp", "allowed_mcp_tools"] do
        assert {:error, {:missing_runner_config_field, "claude_code", _}} =
                 RecoveredSpec.runner_config(Map.delete(wire, field)),
               "expected missing #{field} to refuse"
      end
    end

    test "a stamped codex config missing a security-critical field refuses recovery" do
      wire = jsonb_round_trip(Codex.materialize_config(%{}))

      for field <- ["access", "config_sync"] do
        assert {:error, {:missing_runner_config_field, "codex", _}} =
                 RecoveredSpec.runner_config(Map.delete(wire, field)),
               "expected missing #{field} to refuse"
      end
    end

    test "an invalid security-critical value refuses (never silently re-defaults)" do
      wire = jsonb_round_trip(ClaudeCode.materialize_config(%{}))

      assert {:error, {:invalid_runner_config_field, "claude_code", :access}} =
               RecoveredSpec.runner_config(Map.put(wire, "access", "fullish"))

      assert {:error, {:invalid_runner_config_field, "claude_code", :allowed_mcp_tools}} =
               RecoveredSpec.runner_config(Map.put(wire, "allowed_mcp_tools", [1, 2]))
    end

    test "an invalid NON-critical present value also refuses (absence falls to defaults)" do
      wire = jsonb_round_trip(ClaudeCode.materialize_config(%{}))

      assert {:error, {:invalid_runner_config_field, "claude_code", :max_turns}} =
               RecoveredSpec.runner_config(Map.put(wire, "max_turns", -1))

      # Absent non-critical field: decodes fine, field simply omitted.
      assert {:ok, decoded} = RecoveredSpec.runner_config(Map.delete(wire, "max_turns"))
      refute Map.has_key?(decoded, :max_turns)
    end

    test "an unknown codec version or runner refuses" do
      wire = jsonb_round_trip(ClaudeCode.materialize_config(%{}))

      assert {:error, {:unsupported_config_codec, "claude_code", 2}} =
               RecoveredSpec.runner_config(put_in(wire, ["config_codec", "v"], 2))

      assert {:error, {:unsupported_config_codec, "gemini", 1}} =
               RecoveredSpec.runner_config(put_in(wire, ["config_codec", "runner"], "gemini"))
    end

    test "a malformed stamp refuses" do
      assert {:error, {:invalid_config_codec, "banana"}} =
               RecoveredSpec.runner_config(%{"config_codec" => "banana"})
    end
  end

  describe "normalize/1 — stamped runner_config decodes through the spec pipeline" do
    test "a recovered vendor spec emerges with typed runner_config at the atom key" do
      spec = %{
        "runner" => "claude_code",
        "runner_config" => jsonb_round_trip(ClaudeCode.materialize_config(%{model: "m"})),
        "tenant_id" => "t"
      }

      assert {:ok, n} = RecoveredSpec.normalize(spec)
      assert n.runner == :claude_code
      assert n.runner_config.access == :full
      assert n.runner_config.model == "m"
      refute Map.has_key?(n, "runner_config")
      # Unrelated keys still preserved untouched.
      assert n["tenant_id"] == "t"
    end

    test "an undecodable stamped runner_config refuses the whole spec (fail closed)" do
      broken =
        ClaudeCode.materialize_config(%{})
        |> jsonb_round_trip()
        |> Map.delete("access")

      spec = %{"runner" => "claude_code", "runner_config" => broken}

      assert {:error, {:missing_runner_config_field, "claude_code", :access}} =
               RecoveredSpec.normalize(spec)
    end
  end
end
