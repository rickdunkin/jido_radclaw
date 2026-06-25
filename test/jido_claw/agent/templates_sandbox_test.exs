defmodule JidoClaw.Agent.TemplatesSandboxTest do
  # async: false — the malformed/absent-policy tests mutate the global
  # :agent_templates_override app env. (A distinct module from the
  # async:true JidoClaw.Agent.TemplatesTest in test/jido_claw/templates_test.exs.)
  use ExUnit.Case, async: false

  alias JidoClaw.Agent.Templates
  alias JidoClaw.Agent.Workers.Coder

  describe "sandbox/1 + external_tools?/1 (AR-8b)" do
    test "the sketch_build template is sandboxed; normal templates are not" do
      assert Templates.sandbox("sketch_build") == :prototype
      assert Templates.sandbox("coder") == :none
    end

    test "the AR-8b-2 sketch_reviewer template is sandboxed too" do
      assert Templates.sandbox("sketch_reviewer") == :prototype
      refute Templates.external_tools?("sketch_reviewer")
    end

    test "external_tools?/1 is false only for a sandboxed template" do
      refute Templates.external_tools?("sketch_build")
      assert Templates.external_tools?("coder")
      # "main" is not in the registry → :none → external tools allowed.
      assert Templates.external_tools?("main")
    end

    test "a malformed :sandbox value hydrates fail-closed to :prototype" do
      override = %{"bad_sandbox" => %{module: Coder, sandbox: :wat}}
      Application.put_env(:jido_claw, :agent_templates_override, override)
      on_exit(fn -> Application.delete_env(:jido_claw, :agent_templates_override) end)

      assert Templates.sandbox("bad_sandbox") == :prototype
      refute Templates.external_tools?("bad_sandbox")
    end

    test "an absent :sandbox key defaults to :none (zero behavior change)" do
      override = %{"no_sandbox" => %{module: Coder}}
      Application.put_env(:jido_claw, :agent_templates_override, override)
      on_exit(fn -> Application.delete_env(:jido_claw, :agent_templates_override) end)

      assert Templates.sandbox("no_sandbox") == :none
      assert {:ok, %{sandbox: :none}} = Templates.get("no_sandbox")
    end
  end

  describe "the :docker tier (AR-8b-2 F2)" do
    setup do
      override = %{"docker_stub" => %{module: Coder, sandbox: :docker}}
      Application.put_env(:jido_claw, :agent_templates_override, override)
      on_exit(fn -> Application.delete_env(:jido_claw, :agent_templates_override) end)
      :ok
    end

    test ":docker is a valid, first-class policy (not coerced)" do
      assert Templates.sandbox("docker_stub") == :docker
      assert {:ok, %{sandbox: :docker}} = Templates.get("docker_stub")
    end

    test "a :docker template forbids external (MCP) tools, like :prototype" do
      refute Templates.external_tools?("docker_stub")
    end

    test ":wat still coerces to :prototype — :docker did not widen the valid set to all atoms" do
      override = %{"bad_sandbox" => %{module: Coder, sandbox: :wat}}
      Application.put_env(:jido_claw, :agent_templates_override, override)

      assert Templates.sandbox("bad_sandbox") == :prototype
    end

    test "the real sketch_build_exec template carries the :docker policy" do
      # The `docker_stub` override above proves the POLICY mechanics; this pins the
      # actual shipped template (no override — the static registry).
      Application.delete_env(:jido_claw, :agent_templates_override)
      assert Templates.sandbox("sketch_build_exec") == :docker
      refute Templates.external_tools?("sketch_build_exec")
    end
  end
end
