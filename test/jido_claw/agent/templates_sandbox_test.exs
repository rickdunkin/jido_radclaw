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
end
